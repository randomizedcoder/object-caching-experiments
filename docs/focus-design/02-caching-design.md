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

---
