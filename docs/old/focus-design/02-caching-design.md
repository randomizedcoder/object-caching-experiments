[← Contents](README.md)

**What to cache and the OCI caching design.** Part of the [focused design](README.md).

---

## 6. What needs to be cached

Before the mechanics, it's worth being precise about *what* this lab caches and why the cache configs look the way they do. Almost everything we pull — container images, LLM model weights, even Ollama models — decomposes into the same two object classes, and the **OCI Distribution Specification** is the canonical description of that shape.

### 6.1 Manifests vs blobs

Two kinds of objects, with very different caching properties:

**Manifests** — small JSON documents listing the layers (blobs) that make up an image, plus its config. Fetched with:

```
GET /v2/<name>/manifests/<reference>
```

`<reference>` is **either a tag or a digest**, and that distinction is the whole caching story:

- **By tag** (`:latest`, `:1.28`) → **mutable**. A tag can be re-pushed to point at a new digest at any time, so a by-tag manifest must be cached with a **short TTL and/or revalidated** on each use — otherwise clients pin to a stale image.
- **By digest** (`@sha256:…`) → **immutable**. The digest *is* the content hash, so the response can be cached effectively forever.

**Blobs** — the actual bytes: layer tarballs and the image config. Fetched with:

```
GET /v2/<name>/blobs/<digest>
```

Blobs are **always content-addressed by digest → immutable forever**. They are also **large** and dominate bytes-on-the-wire, so they are the real reason the cache exists. The spec supports **Range requests** (HTTP `206`) for resumable blob downloads, which the cache must pass through and ideally cache.

**Why content-addressability is the whole game.** Because a blob is named by its sha256, the *same* blob legitimately appears under many different repository names (a shared base layer pulled as `library/alpine`, `myorg/app`, …). An ideal cache stores that blob **once, keyed on its digest**, regardless of the repo path it arrived under. Zot does this natively (storage-layer dedup, `storage.dedupe=true`); a naive nginx cache keyed on the full request path stores one copy *per repo* and misses the dedup. This gap is the crux of the analysis in [§7](#7-oci-caching-nginx-primary-zot-oracle).

The same manifest/blob split applies beyond containers: **Hugging Face / ModelScope LFS objects** are content-addressed sha256 files (blob-like, immutable), and **Ollama** uses an OCI-style manifest + digest-keyed layers — see [§15](06-mitm-and-content.md#15-llm-model-store-caching).

### 6.2 The OCI Distribution Specification

The pull protocol above is standardised by the **OCI Distribution Specification**:

> https://github.com/opencontainers/distribution-spec/blob/main/spec.md

What the spec does and does **not** say about proxying / caching — stated precisely so we don't over-claim:

- **It is content-addressable by design.** Digest-addressed manifests and blobs are immutable; this is the property every cache layer here leans on for long TTLs — the spec's strongest gift to a cache.
- **Pull is a small, fixed set of `GET`/`HEAD` endpoints** (`/v2/`, `…/manifests/<ref>`, `…/blobs/<digest>`), which is what makes a dumb HTTP proxy cache (nginx) viable at all — there's very little surface to model.
- **The `ns` query parameter is defined but OPTIONAL / advisory.** Containerd appends `?ns=<registry>` when pulling through a mirror so the mirror can tell which upstream a request is for, but the spec marks this as something a registry *MAY* honour and *MAY* ignore. Our routing relies on `ns` by **convention** (it is how containerd behaves), not by guarantee — see [§12.2](04-client.md#122-the-ns-routing-key).
- **Range / resumable pulls** (`Range:` → `206 Partial Content`) are supported; caches should handle, and ideally store, partial responses.
- **Authentication is explicitly out of scope.** The spec defers auth to the standard Bearer-token / `WWW-Authenticate` flow. The practical consequence for a cache: it must **forward auth headers upstream** and must **not blindly cache authenticated `200`s** as if public — a private blob cached and served to an unauthenticated client is a security bug. (The Tier-1 registries we mirror here are public pulls, but the design must not assume that.)
- **ETag / conditional caching exists mainly on the push path**; for pull, revalidation of mutable by-tag manifests is the relevant lever.

### 6.3 Caching best practices, per cache

How those properties map onto the caches in this design (full configs in [§11](04-client.md#11-client-architecture-nginx-two-tier-cache) / [§13](05-cache-vms.md#13-cache-vms-nginx-primary-and-zot-oracle)):

- **nginx (the cache, both tiers)** — split cache policy by URL: treat `/blobs/<digest>` and by-digest manifests as immutable (long TTL, e.g. 30d); treat by-tag manifests as short-TTL/revalidate. Use `proxy_cache_lock on` so a thundering herd of identical pulls collapses to **one** upstream fetch (request coalescing). Use `proxy_buffering off` for large blobs so they stream rather than buffer to disk first. Follow CDN `301/302/307/308` redirects and cache the **redirected body keyed on the digest**, dropping signed query args so re-signed URLs still hit ([§13.4](05-cache-vms.md#134-docker-hub-cdn-handling), the `@follow_cdn` rule). The **client-local hot tier** uses the same policy with a small `max_size` and `proxy_cache_min_uses` ([§11.1](04-client.md#111-the-two-tiers)).
- **Zot (oracle only)** — purpose-built OCI registry: it understands manifests/blobs/digests natively, dedups blobs at the storage layer across repos, runs as a native pull-through **mirror**, and handles upstream auth — it gets all of the above *for free*. We keep it precisely so we can diff nginx's hand-written rules against a conformant implementation ([§7](#7-oci-caching-nginx-primary-zot-oracle)).

---

## 7. OCI caching: nginx primary, Zot oracle

Given [§6](#6-what-needs-to-be-cached), a natural question: do we need Zot at all, or could **nginx alone** cache OCI images and give us a single cache technology to master? This section weighs that explicitly. **The decision is made: nginx is the cache** (at both the client hot tier and the shared layer), and **Zot is retained only as a verification oracle** — see [§7.4](#74-the-committed-design-nginx-cache-zot-as-verification-oracle). The rest of this document is written to that decision; [§7.1](#71-what-zot-gives-for-free)–6.3 record *why*.

The tradeoff in one line: **Zot gives correct OCI semantics for free; nginx trades that for hand-written config, in exchange for a single cache technology to learn, tune, and operate (Requirement #4, [§5](01-overview.md#5-requirements)).** We accept that trade and use Zot to keep the hand-written rules honest.

### 7.1 What Zot gives for free

Dropping Zot would mean giving up — and re-implementing in nginx:

- **Native OCI route + digest understanding** — Zot speaks `/v2/` and treats digests as first-class; no regex parsing of URLs to classify blob vs manifest.
- **Storage-layer dedup across repos** (`storage.dedupe=true`) — the same blob digest pulled under many repo names is stored **once** ([§6.1](#61-manifests-vs-blobs)).
- **Native pull-through mirror mode** with upstream auth handling — including the token dance the OCI spec leaves out of scope ([§6.2](#62-the-oci-distribution-specification)).
- **OCI conformance + built-in Prometheus metrics** (`extensions.metrics`, [§19](07-tuning-observability.md#19-observability-prometheus)).

### 7.2 What nginx-only must replicate by hand

To match the above with nginx we would write (much of which **already exists** in [§13.2](05-cache-vms.md#132-nginx-wildcard-oci-catch-all) / [§15](06-mitm-and-content.md#15-llm-model-store-caching)):

- **Per-route cache policy** — distinguish `/blobs/<digest>` (immutable) from `/manifests/<tag>` (short TTL) from `/manifests/<digest>` (immutable), via `location` / `map` rules on the request URI.
- **CDN redirect follow + cache** — the `@follow_cdn` handler that chases the `307` to CloudFront/R2 and caches the body keyed on digest ([§13.4](05-cache-vms.md#134-docker-hub-cdn-handling)).
- **Request coalescing** — `proxy_cache_lock on` to stand in for Zot's waiting list.
- **Auth pass-through** — forward `Authorization` / `WWW-Authenticate`, and *not* cache private `200`s ([§6.2](#62-the-oci-distribution-specification)). For public Tier-1 pulls this is light, but it's the most spec-subtle part to get right.
- **Cross-repo blob dedup — the real gap.** nginx keyed on `$ns:$uri` stores the same blob once *per repo path*, missing Zot's digest-level dedup. **Mitigation:** key the blob cache **purely on the `sha256:<digest>`** extracted from the URI (e.g. `proxy_cache_key "blob:$digest"` for `/blobs/` locations) so identical blobs collapse to a single entry regardless of repo or `ns`. Manifests stay keyed by `ns:uri` (they are per-name).

### 7.3 Why nginx-only is still attractive

- **One technology to get good at** — a single config language, one set of tuning knobs (workers, cache zones, `open_file_cache`), one mental model for blob/manifest/apt/model-store caching alike.
- **One tuning + sysctl story** ([§18](07-tuning-observability.md#18-performance-tuning)) rather than tuning Zot *and* nginx.
- **One observability surface** — nginx-prometheus-exporter only ([§19](07-tuning-observability.md#19-observability-prometheus)).
- **We already run nginx anyway** for apt ([§17](06-mitm-and-content.md#17-apt-caching)) and the model stores ([§15](06-mitm-and-content.md#15-llm-model-store-caching)), and the OCI configs largely exist ([§13.2](05-cache-vms.md#132-nginx-wildcard-oci-catch-all)). The "more nginx config" cost is mostly one-time and already paid.

Fewer moving parts everywhere — one technology on the clients *and* the cache VMs — is the core simplification this design is built around (Requirement #4, [§5](01-overview.md#5-requirements)).

### 7.4 The committed design: nginx cache, Zot as verification oracle

**Decision:** **nginx is the single cache** for OCI, apt, and model stores — both the client-local hot tier ([§11.1](04-client.md#111-the-two-tiers)) and the shared cache layer ([§13](05-cache-vms.md#13-cache-vms-nginx-primary-and-zot-oracle)) — and **Zot is kept wired into the lab permanently as a verification oracle**, not merely as a one-off comparison baseline.

Rationale: hand-written OCI rules in nginx are easy to get *subtly* wrong (a mis-keyed blob, an over-cached by-tag manifest, a leaked private `200`). Zot is a **conformant OCI implementation**, so it is an ideal ground-truth reference to check nginx against. Concretely:

- **Automated differential testing.** Pull the same images through the nginx path and through Zot and **assert equivalence** — manifest bytes/digests match, the layer/blob digest set is identical, returned status/headers agree. Wire this as a scripted check (a flake app / test target alongside the [§20](08-operations.md#20-build-and-run-workflow) workflow) so nginx behaviour is **continuously verified against Zot** rather than trusted blind.
- **Live debugging aid.** If a caching bug appears in the nginx path, pulling the same reference through Zot gives an immediate correct-vs-broken comparison to localise it.

So Zot earns a permanent place in the design as the **reference**, while nginx is the **cache in production**. Zot sits **off** the client→cache serving path: the clients consistent-hash into the **nginx** shared caches ([§11.2](04-client.md#112-consistent-hash-router-and-cache-keys)), and the differential test pulls the same references through Zot **out of band** to assert equivalence. Zot only ever re-enters the serving path if a measurement ([§21](08-operations.md#21-what-we-measure)) shows nginx diverging on **cache-hit ratio**, **disk usage** (with digest-keyed blob dedup, [§7.2](#72-what-nginx-only-must-replicate-by-hand)), or **auth correctness** — at which point the diff localises the bug to fix in the nginx rules.

This is why the remainder of this document describes **nginx as the cache with Zot as the oracle**: both are built, but only nginx serves clients.

> **Differential-test caveat.** The "manifest bytes/digests match" assertion above only holds when Zot is run with `PreserveDigest` + `docker2s2` compat (see [§7.5](#75-revisit-would-zot-in-path-be-better) and [§13.1.1](05-cache-vms.md#1311-what-zots-sync-rewrites-and-why-it-matters)). In Zot's *default* mode the oracle's manifest/config/index digests legitimately differ from the origin (Docker→OCI conversion), so the test must either run the oracle in PreserveDigest mode or compare only the **layer-blob digest set** (which is preserved either way), not the manifest digest.

### 7.5 Revisit: would Zot-in-path be better?

*Exploratory — this subsection does **not** change the committed design in [§7.4](#74-the-committed-design-nginx-cache-zot-as-verification-oracle); it records the analysis behind keeping it.*

A reasonable alternative is to make **Zot the ingest tier**: Zot pulls and normalizes images from the origins, and nginx caches Zot's *output* downstream (clients → nginx → Zot → origin) instead of nginx fetching origins directly. The appeal is that Zot is a conformant OCI implementation that gives, for free, the things nginx replicates by hand ([§7.1](#71-what-zot-gives-for-free), [§7.2](#72-what-nginx-only-must-replicate-by-hand)): a canonical content-addressed store, GC, cross-repo dedup, and Prometheus metrics. The blocker is what Zot does to images on the way in — see [§13.1.1](05-cache-vms.md#1311-what-zots-sync-rewrites-and-why-it-matters): by default it transcodes Docker schema2 → OCI and **recomputes the manifest, index, and config digests**.

| Criterion | Zot-in-path (default convert) | Zot-in-path (`PreserveDigest`) | nginx-primary / Zot-oracle (§7.4) |
|---|---|---|---|
| **Digest fidelity to origin** | Broken — manifest/index/config recomputed | Preserved (byte-for-byte) | Preserved (byte-exact pass-through) |
| **Unmodified-pull rule** (`image@sha256:<origin>`) | **Violated** — 404 on origin digest | Holds | Holds |
| **Foreign-layer images** | Skipped (`destination.go:204-207`) | Skipped | Pass through (nginx caches the bytes) |
| **Config coupling** | none extra | requires `http.compat: ["docker2s2"]` | none |
| **Serving-path availability surface** | Zot becomes a hard serving dependency (HA story needed) | same | Zot off path; nginx is the only critical serving tech ([§13](05-cache-vms.md#13-cache-vms-nginx-primary-and-zot-oracle)) |
| **Cross-repo blob dedup** | Zot's store (rethink the consistent-hash key story, [§7.2](#72-what-nginx-only-must-replicate-by-hand)) | same | nginx, digest-keyed (already designed) |
| **Free OCI policy/GC/metrics** | yes | yes | no — nginx hand-rolls policy |

The decisive constraint is the project's hard rule that **unmodified pulls and Dockerfiles must work as-is**, including digest pins. That eliminates default-mode Zot-in-path outright. `PreserveDigest` mode survives the rule, but it (a) couples the cache to schema2-compat mode, (b) still drops foreign-layer images, and (c) turns Zot into a serving-path dependency whose HA we'd then have to engineer — whereas today nginx is the only critical serving tech and Zot's failure is invisible to clients.

**Recommendation: keep [§7.4](#74-the-committed-design-nginx-cache-zot-as-verification-oracle).** The experiment below was run and **confirms the digest-divergence prediction**: default-mode Zot-in-path changes the client-visible image digest and 404s on origin-digest pins (and docker then silently falls back to the origin, so the cache is bypassed for pinned pulls). `PreserveDigest` mode avoids that but couples the cache to schema2-compat, still drops foreign-layer images, and makes Zot a serving-path dependency — buying nothing nginx's byte-exact pass-through doesn't already give us, while costing availability surface. So Zot stays the off-path oracle; it would only move in-path if a future measurement showed nginx materially diverging on hit-ratio/disk/auth.

**Experiment (results).** Run on `ubuntu2204` against `cache0`, pointing docker's `registry-mirrors` at each path in turn (A = client nginx `:8088` → cache nginx `:8085`; B = Zot default `:5050`; C = a scratch Zot on `:5060` with `preserveDigest:true` + `http.compat:["docker2s2"]`). Test image: **`library/alpine:3.9`** — chosen deliberately because it is still served by Docker Hub as a **Docker schema2 manifest list** (`application/vnd.docker.distribution.manifest.list.v2+json`); note that most *current* Docker Hub library images (`alpine:3.20`, `ubuntu:22.04`, `nginx:1.25`, …) are **already OCI** and so pass through Zot unconverted — the conversion only bites legacy schema2 images.

| | Path A — nginx | Path B — Zot default | Path C — Zot `PreserveDigest` | origin |
|---|---|---|---|---|
| top-level media type | `docker …list.v2` (pass-through) | `oci.image.index.v1` | `docker …list.v2` | `docker …list.v2` |
| **index digest (client `RepoDigest`)** | `…414e0518` (= origin) | **`…4ef57e7d` (≠ origin)** | `…414e0518` (= origin) | `…414e0518` |
| amd64 sub-manifest media type | docker v2 | `oci.image.manifest.v1` | docker v2 | docker v2 |
| amd64 sub-manifest digest | = origin | **≠ origin** (`…27437c` vs `…65b3a8`) | = origin | `…65b3a8` |
| config blob digest | `…78a2ce` | `…78a2ce` (same) | `…78a2ce` | `…78a2ce` |
| layer blob digests | `…316035` | `…316035` (same) | `…316035` | `…316035` |
| **origin-digest pin** (`curl` by `@sha256:<origin>`) | 200 | **404** | 200 | — |
| `docker run` start (warm) | ~0.8–1.2 s | ~0.5–0.6 s | ~0.5–0.6 s | — |

The prediction held exactly: **Path B (default Zot) changes the manifest and index digests** — the client records `RepoDigest …4ef57e7d`, *not* the origin's `…414e0518` — and a by-digest pull of the origin digest **404s** against Zot. Paths A and C preserve the origin digest and accept the pin. Across *all three* paths the **config blob and layer blob digests are identical** (`…78a2ce` / `…316035`): Zot only rewrites the manifest/index encoding, never the content blobs (see [§13.1.1](05-cache-vms.md#1311-what-zots-sync-rewrites-and-why-it-matters)). `docker run` start-times were within noise of each other (identical layers), so the rewrite costs nothing at *run* time — its only effect is the digest identity. (Pull wall-times are **not** a clean benchmark here: each upstream tier was warmed to a different degree during the run, and since the layer bytes are identical, steady-state pull cost is dominated by cache warmth, not by the path.) The route change was temporary and isolated to the one client; teardown restored the nginx-only mirror and a clean by-tag pull. A practical corollary: because docker's `registry-mirrors` **falls back to the origin** when the mirror 404s, digest-pinned pulls through default-mode Zot silently bypass the cache entirely — so default Zot-in-path gives *zero* cache benefit for exactly the pulls that pin a digest. (Workflow lives alongside [§20](08-operations.md#20-build-and-run-workflow).)

---
