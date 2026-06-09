# 03 — The client cache

The client is where locality is won or lost. It runs one OpenResty instance
([`nginx-client.nix`](../nix/modules/nginx-client.nix)) that is simultaneously a **small local
hot cache** and, on a miss, a **consistent-hash router** to the shared cache VMs. Below it, the
container runtime is wired so that *unmodified* pulls flow through nginx without anyone editing a
Dockerfile.

## 3.1 Why two tiers on one box

A repeat fetch that a machine already pulled should never leave the machine — that is the cheapest
possible hit. But each client only has room for a small hot set, so on a local miss we do **not**
go straight to the WAN: we route to the shared tier, where the fleet keeps one copy per blob. One
nginx does both jobs: it serves from its local `proxy_cache`, and on a miss `proxy_pass`es to a
consistent-hash upstream of the cache VMs.

## 3.2 Local hot tiers

Four `proxy_cache_path` zones, deliberately small (R3), split by workload so each maps onto its
own ZFS dataset (the on-disk paths *are* the dataset mountpoints — see [07](07-tuning-observability.md)):

| Zone | `max_size` | Backing pool | Holds |
|------|-----------|--------------|-------|
| `oci_hot_manifests` | 1 GiB | cache-manifests | OCI manifests/tags |
| `oci_hot_blobs` | 8 GiB | cache-blobs | OCI layer blobs |
| `model_hot` | 4 GiB | cache-http | model-store payloads (via `:443`) |
| `apt_hot` | 2 GiB | cache-http | apt indices + `.deb`s |

All zones use `inactive=24h` and `use_temp_path=off`. The cache lives under `/var/lib/cache` on
the data disk so the small writable root never fills with blobs.

## 3.3 Keying: digest-addressed blobs vs short-TTL manifests

The OCI frontend (`:8088`, the containerd `hosts.toml` target) splits on URL shape:

- **Blobs** (`~ ^/v2/.+/blobs/sha256:`) are immutable and content-addressed, so they are keyed
  **purely on the digest** (`blob:$oci_digest`) — the same layer dedups across every repo and
  namespace. TTL 30d, `proxy_cache_min_uses 2` (cache on the second use), `proxy_cache_lock on`.
- **Manifests** (`~ ^/v2/.+/manifests/`) are by-tag and can move, so they are keyed on
  `$oci_ns:$uri` with a short 5m TTL.

`$oci_digest` is extracted from the path by a `map`, and `$oci_ns` from the `?ns=` argument
containerd attaches (defaulting to `_default`). The apt frontend (`:8090`) keys on
`$http_host$request_uri` with a short 5m local TTL — the shared tier holds the long-lived copy.

The cache key drives **two** things at once: the local `proxy_cache_key` (hot-tier dedup) and the
`hash $cache_key consistent` upstream selection (which cache VM owns this blob).

## 3.4 Consistent-hash routing to the shared tier

On a local miss, nginx hashes `$cache_key` (ketama) across the cache VMs and `proxy_pass`es over
a **TLS hop verified against the cache CA** (see [05](05-trust-and-mitm.md)):

- `shared_caches` → cache VMs `:8085` (OCI wildcard)
- `shared_caches_apt` → cache VMs `:8086` (apt)
- `shared_model_<store>` / `shared_model_extra` → the model/extra vhosts (`:8100–8104`), used by
  the `:443` MITM frontends

Because the hash is on the content key, a given blob always lands on the same cache VM regardless
of which client asks — that is what gives the fleet one shared copy per blob (R2). The TLS
settings (`proxy_ssl_verify on`, `proxy_ssl_trusted_certificate /etc/nginx/cache-ca.crt`,
`proxy_ssl_name caches.cache.lab`) are set once at `http{}` scope and inherited by every
`proxy_pass`.

## 3.5 High availability: passive + active health-checks

Two layers keep a dead cache VM from stalling pulls, satisfying the fail-open requirement (R4):

- **Passive** — every upstream `server` carries `max_fails=1 fail_timeout=10s`, and the cache
  locations set `proxy_next_upstream error timeout http_502 http_503 http_504`, so a failed
  request retries the other peer.
- **Active** — an in-process Lua prober (`lua-resty-upstream-healthcheck`, bundled with
  OpenResty) probes each peer over TLS from every worker (`HEAD /v2/` for OCI, `GET /health` for
  apt) and marks dead peers down *before* ketama selects one. No extra daemon, no reload. Tunables
  (interval 2000 ms, timeout 1000 ms, fall 3, rise 2, valid statuses 200/401/404) live in
  [`nix/constants/app.nix`](../nix/constants/app.nix).

The active prober has a **runtime kill-switch**: `nix run .#cache-set-hc -- --state=off` touches
`/run/nginx-hc-disabled` and reloads; `init_worker` then skips spawning the probers while the
passive backstop stays in force. The probe only checks *liveness* (`ssl_verify = false`); serving
traffic is still authenticated against the cache CA.

## 3.6 Wiring the container runtime for unmodified pulls

`docker pull gcr.io/foo/bar` must stay exactly that ([01](01-overview.md) R1). The primary
mechanism is containerd's per-registry `certs.d/<reg>/hosts.toml`
([`docker-client.nix`](../nix/modules/docker-client.nix)):

```toml
server = "https://gcr.io"            # final fallback: cache down → pull direct

[host."http://127.0.0.1:8088"]       # the client nginx OCI frontend
  capabilities = ["pull", "resolve"]
```

When containerd pulls through this mirror it encodes the original registry as `?ns=gcr.io`, which
the client nginx routes on. One `hosts.toml` is generated per Tier-1 upstream plus a `_default`
wildcard, so **every** registry is covered, not just docker.io. `nerdctl` reads `certs.d`
directly. Docker Engine is enabled too (containerd-snapshotter image store, with a docker.io
`registry-mirror` pointing at `:8088`), but per-registry mirroring of arbitrary registries is a
containerd feature — the registry-mirror only accelerates docker.io, the demoted path.

The `server =` line is the safety net: if the cache is unreachable containerd silently pulls
direct, so a broken cache never breaks a pull — it just stops accelerating it.

Model-store and other MITM'd HTTPS fetches take the `:443` path instead; that machinery is
covered in [05](05-trust-and-mitm.md) and the per-source detail in [06](06-content-sources.md).
