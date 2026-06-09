# 04 — The shared cache VMs

The two cache VMs (`cache0`, `cache1`) are the datacenter tier: they do the heavy pull-through
work, hold the fleet corpus, and fan out to the upstreams. Each runs one OpenResty cache
([`nginx-cache.nix`](../nix/modules/nginx-cache.nix)) backed by per-workload ZFS pools, plus five
off-path Zot oracles ([`zot-oracle.nix`](../nix/modules/zot-oracle.nix)) used only to verify
correctness. The two VMs are interchangeable — the client hashes content keys across both.

## 4.1 Why nginx is the cache, not a registry

The serving path is hand-written nginx, not a full registry implementation, because the cache
only needs to do three things well: proxy to an origin chosen at request time, follow CDN
redirects, and store the bytes under a content-addressed key. nginx's `proxy_cache` does exactly
this with mature LRU/locking, and keeping one technology on every hop keeps the design small. The
risk — that hand-written rules diverge from spec — is bought back by the Zot oracle (§4.4) and the
differential test ([08](08-operations-and-future.md)).

## 4.2 The OCI wildcard cache (`:8085`)

A single TLS catch-all vhost serves every registry. The client passes the original registry as
`?ns=<reg>`; a `map` turns that into the real upstream host (identity for most, but
`docker.io → registry-1.docker.io`), which becomes both the `Host` and the SNI for the
`proxy_pass`. Requests without `ns=` return 404 so containerd falls through to a direct pull.

- **Blobs** (`~ ^/v2/.+/blobs/sha256:`) → keyed `blob:$blob_digest`, 30d TTL, into the
  `cache_blobs` zone. The digest is pulled out of the path by a `map`, so identical layers dedup
  to one entry across every repo and namespace.
- **Manifests / everything else** → keyed `$arg_ns:$request_method:$uri`, 30d, into
  `cache_manifests`.

### Following CDN redirects ourselves

Registries increasingly answer blob requests with a 30x to a signed CDN URL. If the cache merely
forwarded the redirect, every client would fetch from the CDN with a *different* signed query
string and nothing would ever cache. So the cache **follows the redirect itself**
(`proxy_intercept_errors on` + `error_page 301 302 303 307 308 = @follow_cdn`) and stores the
fetched body **under the same key the entry location set** (`$ckey`), dropping the per-pull signed
query args. The result is one cached entry per digest regardless of how many distinct signed URLs
the CDN hands out.

## 4.3 The apt cache (`:8086`)

apt packages are individually GPG-signed, so plain-HTTP proxy caching to the origin is safe. apt
sends absolute-form requests to a proxy, so the cache forwards by `Host` header. Indices
(`InRelease`/`Release`/`Packages`/`Sources`) get a short 5m TTL; `.deb`s are content-addressed by
version and get 30d. Everything keyed `$http_host$request_uri` in the `cache_apt` zone.

Model-store and extra vhosts (`:8100–8104`) live on these same VMs; their per-source behaviour
(X-Orig-Host forwarding, LFS/OSS redirect-following) is detailed in [06](06-content-sources.md).
All cache vhosts listen TLS, presenting the shared cache-server cert ([05](05-trust-and-mitm.md)).

## 4.4 The ZFS pool split

nginx's filesystem cache is split across **three** per-workload ZFS pools
([`zfs-cache-pools.nix`](../nix/modules/zfs-cache-pools.nix),
[`nix/constants/resources.nix`](../nix/constants/resources.nix)) so each can be tuned, measured,
and grown independently. The on-disk cache paths *are* the dataset mountpoints, created and
`chown`ed before nginx starts.

| Pool | `recordsize` | `primarycache` | `dedup` | `compression` | Rationale |
|------|-------------|----------------|---------|---------------|-----------|
| `cache-manifests` | 16K | all | off | lz4 | tiny, latency-critical; keep it all in ARC |
| `cache-blobs` | 1M | metadata | on | off | large immutable layers; dedup ON only to *measure* (nginx already digest-dedups → expect ~1.0×) |
| `cache-http` | 128K | all | on | lz4 | apt + model stores + extra; not digest-addressed, so block dedup can genuinely help |

All datasets are `atime=off` and `sync=disabled` (the writes are a regenerable cache; a crash just
re-fetches). Pool sizes are starting points (cache VMs: 4/40/20 GiB; client: 2/8/6 GiB) — the
point of separating them is that they can diverge per workload. These pools are created at runtime
because NixOS can import but not declaratively *create* pools, and the lab's data disks are
ephemeral. ARC is capped below the ZFS default (cache 4 GiB, client 2 GiB) so the dedup tables
don't crowd out the manifest working set on these small-RAM VMs. L2ARC and SLOG are deliberately
**not** used here — see [08](08-operations-and-future.md).

## 4.5 The Zot verification oracle

Five Zot registries (one per Tier-1 upstream, `:5050–5054`) run on the cache VMs in onDemand
pull-through mode ([`zot-oracle.nix`](../nix/modules/zot-oracle.nix), Zot v2.1.17, vendored static
release with the sync + metrics extensions). They are **not on the serving path** — no client ever
talks to them.

Their sole job is to be a **spec-correct ground truth**. The differential test
(`nix run .#cache-diff-test`) pulls the same artifact through the nginx cache and through the
matching Zot oracle and proves the bytes are identical — buying back the risk taken in §4.1 of
hand-writing the caching rules. Adding a registry to `constants.upstreams` automatically adds an
oracle. Each oracle stores under `/var/lib/cache/zot/<ns>` on the data disk and exposes Prometheus
metrics.
