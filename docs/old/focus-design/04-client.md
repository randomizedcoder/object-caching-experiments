[← Contents](README.md)

**Client architecture and containerd config.** Part of the [focused design](README.md).

---

## 11. Client architecture: nginx two-tier cache

This is the heart of the design. **One nginx** runs on every client and plays two roles in a single daemon:

1. a **local hot-cache tier** (`proxy_cache`, small LRU), and
2. a **consistent-hash router** to the shared nginx caches on the cache VMs.

There is no separate load balancer. nginx already does everything the old HAProxy/Varnish pair did — consistent hashing (`hash … consistent`, ketama) and local caching (`proxy_cache`) — and the one capability stock nginx OSS lacks, **active** health checks, is supplied by passive checks plus in-process Lua health-checks on OpenResty in [§11.3](#113-health-checking-passive-and-in-process-active). (HAProxy/Varnish/Envoy/IPVS and the earlier standalone Go daemon, and *why* they lost, are in [§22](08-operations.md#22-alternatives-considered-client-side-proxy).)

### 11.1 The two tiers

A request from containerd (OCI) or apt arrives at the client nginx, which tries its **local hot cache** first and only consults the **shared cache layer** on a local miss:

```nginx
# /etc/nginx/nginx.conf (client) — OpenResty, OCI frontend, condensed.
# OpenResty (nginx + LuaJIT) so active health-checks run in-process (§11.3).

# Override the User-Agent on every upstream request (constants.userAgent),
# so the cache layer and origins see one dedicated string we control.
proxy_set_header User-Agent "Custom Nginx Proxy/caching";

# Local hot tier: small on purpose (Requirement #3, §5). It must NOT
# mirror the whole shared cache — just keep very hot objects local.
proxy_cache_path /var/cache/nginx/oci levels=1:2 keys_zone=oci_hot:64m
                 max_size=8g inactive=24h use_temp_path=off;

# Extract the digest so blobs key on it (cross-repo dedup), and the ns=.
map $uri $oci_digest      { ~/blobs/(?<d>sha256:[0-9a-f]+)$  $d; default ""; }
map $arg_ns $oci_ns       { "" "_default"; default $arg_ns; }

upstream shared_caches {
    hash $cache_key consistent;          # ketama; key set per-location below
    server 10.44.44.20:8085 max_fails=1 fail_timeout=10s;   # cache0 nginx
    server 10.44.44.21:8085 max_fails=1 fail_timeout=10s;   # cache1 nginx
    keepalive 32;
}

server {
    listen 8088;                         # containerd hosts.toml → here (HTTP/1.1)

    # Per-tier cache + latency headers (inherited by both locations below).
    add_header X-Cache-Hot  $upstream_cache_status;   # local hot-tier HIT/MISS
    add_header X-Cache-Time $request_time;            # total time at this nginx

    # Blobs: immutable, key purely on the digest (dedup across repos & ns).
    location ~ ^/v2/.+/blobs/sha256: {
        set $cache_key "blob:$oci_digest";
        proxy_cache oci_hot;
        proxy_cache_valid 200 206 30d;
        proxy_cache_min_uses 2;          # don't let one big cold blob evict the hot set
        proxy_cache_lock on;             # request coalescing
        proxy_buffering off;             # stream large blobs
        proxy_next_upstream error timeout http_502 http_503 http_504 non_idempotent;
        proxy_pass https://shared_caches;     # TLS to the cache layer (§11.5)
    }

    # Manifests: per-name, key on ns:uri. By-tag = short TTL, by-digest = long.
    location ~ ^/v2/.+/manifests/ {
        set $cache_key "$oci_ns:$uri";
        proxy_cache oci_hot;
        proxy_cache_valid 200 5m;        # by-tag mutable; by-digest handled by Cache-Control
        proxy_cache_lock on;
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_pass https://shared_caches;     # TLS to the cache layer (§11.5)
    }
}
```

The apt frontend (`:8090`) and the MITM/model-store frontend (`:443`, [§14](06-mitm-and-content.md#14-https-interception-internal-ca--mitm)–14) are additional `server {}` blocks on the same nginx, each with its own small `proxy_cache_path` and the same `shared_caches` upstream (apt hashes to `:8086`, models to their per-store vhosts). `nix/modules/ nginx-client.nix` generates them all from `constants.upstreams` / `constants.modelStores`; the Ubuntu equivalent is one Ansible template fed the same data (`ubuntu-render`).

> **Why the hot tier is small.** Requirement #3 ([§5](01-overview.md#5-requirements)): the shared layer is the big volume; the local tier is just a latency shortcut for the hottest objects. `proxy_cache_min_uses 2` keeps one-off large blob pulls from churning it, and a modest `max_size` lets the LRU evict cold blobs.

**Cache + latency headers.** Every response carries four headers so a HIT/MISS and the time spent are visible end to end without parsing logs: `X-Cache-Hot` is the **client hot-tier** status (`HIT`/`MISS`/`EXPIRED`/…) and `X-Cache-Time` is `$request_time` at the client nginx; the **shared layer** adds `X-Cache-Status` (its own `$upstream_cache_status`) and `X-Cache-Upstream-Time` (`$upstream_response_time`, the origin fetch on a shared miss, [§13](05-cache-vms.md#13-cache-vms-nginx-primary-and-zot-oracle)), both of which propagate up through the client. The same fields are also written to the access log ([§19](07-tuning-observability.md#19-observability-prometheus)).

### 11.2 Consistent-hash router and cache keys

On a local miss, `proxy_pass https://shared_caches` ([TLS, §11.5](#115-encrypted-client-to-cache-hop-tls)) hashes the request onto the cache VMs with **`hash $cache_key consistent`** (ketama). The key is chosen per-location so the hash is **stable and dedup-friendly**:

- **Blobs → `blob:sha256:<digest>`.** Content-addressed, so the *same* blob lands on the *same* cache VM regardless of repo or `ns=`, and is stored **once** fleet-wide (cross-repo dedup, [§7.2](02-caching-design.md#72-what-nginx-only-must-replicate-by-hand)). This is the key property that makes the shared layer one large logical cache.
- **Manifests → `ns:uri`.** Manifests are per-name (by-tag is mutable), so they key on the namespace + path, not a digest.
- **apt → request URI**; **model stores → store-specific key** ([§15](06-mitm-and-content.md#15-llm-model-store-caching)).

Because the key derives from the containerd-appended `ns=` param plus the path, two different upstreams never collide on a shared blob digest by coincidence — `ns=` keeps registries distinct where it matters (manifests) while blobs intentionally converge on the digest. (See `containerd_ns_query_routing` for the `ns=` mechanism.)

**Blast radius (Requirement #2, [§5](01-overview.md#5-requirements)).** With ketama and `n=2` cache VMs, losing one remaps ~50% of keys to the survivor (which then misses-and-fills from upstream once). At `n=4`, a single loss remaps only ~25%. The lab runs `n=2` as the deliberate worst case; production should use `n≥3`.

### 11.3 Health-checking: passive and in-process active

Stock nginx OSS has no *active* upstream health checks (an nginx Plus feature). Because every node runs **OpenResty** (nginx + LuaJIT), we get active checks in-process with no extra component. We provide HA two ways and **measure both** ([§21](08-operations.md#21-what-we-measure)):

**Passive (always-on in-band backstop).** The `max_fails=1 fail_timeout=10s` on each `server` plus `proxy_next_upstream` means: when a cache VM stops answering, the *failing request itself* is retried on the survivor, and the dead server is taken out of rotation for `fail_timeout`. No daemon, no reload. The cost: the **first** request to hit the dead node after it fails eats a connect timeout before failing over, and nginx periodically re-probes by sending a real request. This stays enabled even with active checks on.

**Active (default, in-process): [`lua-resty-upstream-healthcheck`](https://github.com/openresty/lua-resty-upstream-healthcheck).** A LuaJIT timer inside the nginx workers probes each cache VM proactively and marks dead peers `down` in shared memory, so the consistent-hash balancer skips them *before* a client request ever selects them — no daemon, no config rewrite, no reload:

```nginx
# http{} context (client)
lua_shared_dict healthcheck 1m;

init_worker_by_lua_block {
    local hc = require "resty.upstream.healthcheck"
    hc.spawn_checker {
        shm          = "healthcheck",
        upstream     = "shared_caches",          # the §11.1 upstream, unchanged
        type         = "https",                  # serving listener is TLS now (§11.5)
        http_req     = "HEAD /v2/ HTTP/1.0\r\nHost: cache\r\n\r\n",  # /health for apt/wildcard
        interval     = 2000,                     # ms between probes (constants.healthcheck.interval)
        timeout      = 1000,                      # ms per probe
        fall         = 3,                         # consecutive fails → down (hysteresis)
        rise         = 2,                         # consecutive oks → up
        valid_statuses = { 200, 401, 404 },      # registry liveness answers
    }
}
```

- The `upstream { hash $cache_key consistent; … }` block from [§11.1](#111-the-two-tiers) is **unchanged** — the checker only flips peer up/down state. When a peer is marked down, ketama redistributes just its share (~1/n of keys) to the survivors, exactly as with passive failover, but *ahead of* the request.
- **The probe rides TLS** (`type = "https"`) because the serving listener is now TLS ([§11.5](#115-encrypted-client-to-cache-hop-tls)); it only checks liveness, while serving traffic is *authenticated* against the cache CA via `proxy_ssl_verify`.
- **Hysteresis** (`fall`/`rise`) prevents a single blip from flapping a backend out and back.
- **`n≥3` is native** — the checker tracks every peer in the `upstream` independently, so there are no pre-generated upstream subsets to manage.
- **No status endpoint / no metrics.** The checker's only job is to keep traffic off dead peers; whether a host is *actually* down (and needs paging/repair) is the job of the existing host monitoring (node_exporter, [§19](07-tuning-observability.md#19-observability-prometheus)), not the cache fabric.

**Why active given passive works?** Passive failover is *reactive* — a client pull pays the timeout on the first post-failure request. The in-process checker makes failover *proactive*: by the time a pull arrives, the dead node is already out of rotation. With OpenResty this costs nothing but config, so it ships **on**; disabling the checker (falling back to pure passive) is the comparison [§21](08-operations.md#21-what-we-measure) measures under an induced failure.

> **Why not the standalone daemon we first designed?** The earlier draft used a small Go agent that HEAD-probed the caches, symlink-swapped a pre-generated upstream include, and ran `nginx -s reload`. The in-process Lua checker does the same active checking with **no separate process to operate, no reload (so no worker churn or flap-storms), and native `n≥3`** (no `2^n` include explosion). The Go daemon is kept only as a considered-and-rejected alternative ([§22](08-operations.md#22-alternatives-considered-client-side-proxy)).

### 11.4 Transport / HTTP versions

- **containerd → client nginx (`:8088`): HTTP/1.1, TCP.** containerd's mirror client speaks **only** HTTP/1.1 over TCP — no unix sockets, no HTTP/2/3 ([§12](#12-containerd-client-config-unmodified-dockerfiles)). We cannot optimise this hop away or upgrade it.
- **client nginx → shared cache (`:8085/8086`): HTTP/1.1 over TLS.** nginx `proxy_pass` originates HTTP/1.1, now encrypted **and verified against the cache CA** ([§11.5](#115-encrypted-client-to-cache-hop-tls)); **nginx cannot originate HTTP/3 upstream** (H3 is a downstream-listener feature only). `keepalive` + `proxy_ssl_session_reuse` pool the connection and session so the per-request cost is just framing, not a new TLS handshake.
- **listeners we own (`:443` MITM / model stores): HTTP/3 + HTTP/2.** Here both ends are ours, so nginx offers QUIC/H3 with H2 fallback ([§14](06-mitm-and-content.md#14-https-interception-internal-ca--mitm)–14, tuning in [§18.3](07-tuning-observability.md#183-quic--http3-tuning)).
- **Honest caveat:** true node-to-node HTTP/3 (client nginx → cache nginx) is **future work** — it would require an H3-capable upstream originator, which nginx is not. We do not claim it.

### 11.5 Encrypted client-to-cache hop (TLS)

The client→cache hop crosses `cachebr0`. The bridge is ours, but we still **encrypt and authenticate** that hop rather than ship cache traffic in clear — belt-and-braces, and it keeps the design honest if the lab is ever stretched onto a less-trusted segment. Every client→cache `proxy_pass` is therefore `https://` ([§11.1](#111-the-two-tiers)), terminating on the cache VMs' TLS listeners ([§13](05-cache-vms.md#13-cache-vms-nginx-primary-and-zot-oracle)).

**Trust model: a dedicated *cache CA*.** One lab-wide cache CA signs a **single shared cache server cert** (SAN = `caches.cache.lab` + both cache IPs, [`constants.cacheTls`](03-architecture.md#10-constants-module-nixconstantsnix)). Because the two cache VMs are interchangeable ([§13](05-cache-vms.md#13-cache-vms-nginx-primary-and-zot-oracle)) they present the **same** cert, so the consistent-hash upstream verifies against one stable name regardless of which peer ketama selects. The cache CA's **public** cert is copied to every client over SSH (the keys `cache-gen-secrets` already mints, [§20](08-operations.md#20-build-and-run-workflow)); the CA key and the server key never leave `secrets/` / the cache VMs.

Set once at `http{}` scope on the client, inherited by every `proxy_pass`:

```nginx
proxy_ssl_trusted_certificate /etc/nginx/cache-ca.crt;  # the cache CA (SSH-copied)
proxy_ssl_verify        on;                             # reject anything it didn't sign
proxy_ssl_verify_depth  2;
proxy_ssl_name          caches.cache.lab;               # constants.cacheTls.serverName, matches SAN
proxy_ssl_server_name   on;                             # send SNI so the cache selects the cert
proxy_ssl_session_reuse on;                             # amortise handshakes (keepalive stays)
```

**Two separate CAs — don't conflate them.** This design now has *two* internal trust systems, each on a different hop:

| trust anchor | signs | presented by | trusted by | hop |
|---|---|---|---|---|
| **per-client MITM CA** ([§14.2](06-mitm-and-content.md#142-the-internal-ca-and-per-fqdn-certs), one per client) | forged per-FQDN origin leaves | client nginx `:443` | local tools + containers on that client | client tool → client nginx |
| **cache CA** (one, lab-wide, this section) | one shared cache server cert | both cache VMs | every client nginx | client nginx → cache nginx |

The MITM CA lets the client *impersonate* HTTPS origins so it can read and cache them; the cache CA only *authenticates the cache layer*. A container pull touches the cache CA on the cachebr0 hop but **never** the MITM CA ([§4.1](01-overview.md#41-oci-container-pull-docker-pull)).

**Trust install path.** NixOS `client0` writes the cache CA to `/etc/nginx/cache-ca.crt`; the Ubuntu `mitm-trust` role drops the same file. It goes **only** into nginx's `proxy_ssl_trusted_certificate` — not the system trust store — since it validates nothing but the cache hop.

---

## 12. Containerd client config (unmodified Dockerfiles)

The hard constraint (from `design.md` §11, preserved here): **users' Dockerfiles must work unchanged** — `FROM gcr.io/foo/bar` keeps saying exactly that. We achieve this with containerd per-registry mirror config, which works because modern moby defaults to the containerd image store.

### 12.1 hosts.toml per Tier-1 registry

Generated into each client's `/etc/containerd/certs.d/`. Example (`docker.io`; `:8088` is the client nginx OCI frontend, [§11](#11-client-architecture-nginx-two-tier-cache)):

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"

[host."http://127.0.0.1:8088"]
  capabilities = ["pull", "resolve"]
```

- `server = ...` is the **final fallback** — if our LB/cache is down, containerd silently falls through to the real upstream, so a broken cache never breaks a pull, it just stops accelerating it.
- `http://` scheme **must** be explicit (containerd otherwise tries HTTPS first).
- `capabilities = ["pull","resolve"]` — `push`/`referrers` correctly stay on the real upstream.
- containerd does the `docker.io` → `registry-1.docker.io` rewrite internally, so we keep the friendly directory name.

### 12.2 The ns= routing key

When containerd pulls through a mirror it encodes the *original* registry in a `ns=` query param (the `Host:` header is just our LB). So `docker pull gcr.io/foo/bar` becomes:

```
GET http://127.0.0.1:8088/v2/foo/bar/manifests/latest?ns=gcr.io
```

The client nginx routes on this `ns=` value (`$arg_ns`) — both to pick the cache key ([§11.2](#112-consistent-hash-router-and-cache-keys)) and, on the shared layer, to dispatch to the right upstream ([§13.2](05-cache-vms.md#132-nginx-wildcard-oci-catch-all)). This is the single mechanism that lets one mirror endpoint serve every registry.

### 12.3 The _default wildcard

For registries outside Tier 1 (`mcr.microsoft.com`, `public.ecr.aws`, `nvcr.io`, …):

```toml
# /etc/containerd/certs.d/_default/hosts.toml
server = ""                           # implicit upstream is the fallback
[host."http://127.0.0.1:8088"]
  capabilities = ["pull", "resolve"]
```

The client nginx hashes unknown-`ns=` pulls into the shared nginx wildcard ([§13.2](05-cache-vms.md#132-nginx-wildcard-oci-catch-all)), which dispatches dynamically on `ns=`. Unknown registry pulls are best-effort: on a cache 404/5xx, containerd's silent fallthrough sends the pull direct to the real upstream and the user's `FROM` line still works.

### 12.4 Switching cache mode

There is no cache-implementation switch: **nginx is the one cache**, end to end (client hot tier + shared layer). The only HA-related knob is *passive vs active health-checking* ([§11.3](#113-health-checking-passive-and-in-process-active)), which is a property of the client nginx itself (the in-process Lua checker on/off), not a different cache. Zot runs only as the out-of-band oracle ([§7](02-caching-design.md#7-oci-caching-nginx-primary-zot-oracle), [§13.1](05-cache-vms.md#131-zot-verification-oracle)).

---
