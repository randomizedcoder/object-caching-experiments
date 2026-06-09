[← Contents](README.md)

**Overview, end-to-end flows, and requirements.** Part of the [focused design](README.md).

---

## 3. Overview

```
                          ┌──────────────────────────────────────────────────────┐
                          │                 Linux host (this machine)             │
                          │   bridge: cachebr0   10.44.44.1/24  fd44:44:44::1/64  │
                          │                                                       │
                          │  CLIENTS (each runs ONE nginx: local cache + router)  │
                          │  ┌──────────┐ ┌────────────┐ ┌────────────┐ ┌───────┐ │
                          │  │ client0  │ │ ubuntu2204 │ │ ubuntu2404 │ │ u2604 │ │
                          │  │ NixOS .10│ │   .30      │ │   .31      │ │  .32  │ │
                          │  │ docker   │ │ docker     │ │ docker     │ │docker │ │
                          │  │ nginx    │ │ nginx      │ │ nginx      │ │nginx  │ │
                          │  │ +hot LRU │ │ +hot LRU   │ │ +hot LRU   │ │+hotLRU│ │
                          │  │ +hc-agent│ │ +hc-agent  │ │ +hc-agent  │ │+agent │ │
                          │  └────┬─────┘ └─────┬──────┘ └─────┬──────┘ └───┬───┘ │
                          │       │ local miss → consistent hash on key:    │     │
                          │       └────────── blobs sha256:<digest>, ───────┘     │
                          │                    manifests ns:uri                   │
                          │                    ┌───────────────┴───────────────┐  │
                          │                ┌───┴──────┐                  ┌──────┴─┐│
                          │                │  cache0  │                  │ cache1 ││
                          │                │  .20     │                  │  .21   ││
                          │                │  nginx   │  (primary cache) │ nginx  ││
                          │                │  zot×5   │  (oracle, §7)    │ zot×5  ││
                          │                └────┬─────┘                  └────┬───┘│
                          └─────────────────────┼─────────────────────────────┼───┘
                                          NAT   ▼                         NAT  ▼
                              docker.io / gcr.io / ghcr.io / quay.io / registry.k8s.io
                                       archive.ubuntu.com / security.ubuntu.com
```

**In one line:** containers, apt, and model pulls all hit the per-client nginx first (local hot tier → consistent-hash to the shared cache → origin on a miss). What differs between the three is **where TLS lives and which CA validates each hop** — the full per-hop walkthroughs, with diagrams, are in [§4](#4-end-to-end-flows).

**High availability:** if a cache VM is down, nginx fails over to the survivor — **passively** in-band (`max_fails`/`fail_timeout` + `proxy_next_upstream`) as the always-on backstop, and **proactively** via OpenResty's in-process `lua-resty-upstream-healthcheck`, which marks a dead peer down in shared memory so the consistent-hash balancer routes around it (no daemon, no reload) ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)).

**Transport:** the containerd→local-nginx hop is **HTTP/1.1** (containerd speaks nothing else — [§12](04-client.md#12-containerd-client-config-unmodified-dockerfiles)). On the listeners we own (the MITM / model-store `:443` frontends) nginx offers **HTTP/3 + HTTP/2**. The nginx→cache hop is **HTTP/1.1 over TLS** (encrypted + verified against the internal cache CA, [§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)); nginx cannot originate H3 upstream, so node-to-node H3 is future work.

### 3.1 Background: container images live on the host, and they pile up

Before the cache changes anything, it helps to be precise about where container images live **today** and why hosts accumulate so much of them — because the cache (below) changes how images are *fetched*, not whether they are *stored locally*.

Every `docker pull` lands the image on the host twice over: the **content store** keeps the compressed layer blobs + manifest + config, and the **snapshotter** keeps the *unpacked* rootfs that the container actually runs from. Both persist on local disk after the pull.

**Crucially, there is no LRU and no size cap on that local store.** containerd's only lifecycle mechanism is **reference-based mark-and-sweep garbage collection** (tri-color reachability — `pkg/gc/gc.go`), and it is driven entirely by *references*, never by disk usage:

- A pulled, tagged image is a **permanent GC root that never expires** (`core/metadata/gc.go`: "image objects are root objects that never expire"). Its blobs and snapshots are reachable, so GC will never touch them as long as the image exists.
- GC reclaims only content that has become **unreferenced** — e.g. the unique layers orphaned when a tag is overwritten, or a container's rootfs snapshot after the container is removed. That orphaned remainder is the "reclaimable" figure in `docker system df`.
- GC is **triggered by metadata churn, not disk pressure** (`plugins/gc/scheduler.go`: a mutation/deletion count threshold + a manual trigger — there is no high-water-mark or size knob anywhere).

Docker layers nothing on top of this — it has no automatic eviction either. Reclamation requires an explicit `docker image prune` / `rmi` / `system prune`. (The one place LRU eviction *does* exist is **Kubernetes kubelet** image GC, with its `High`/`LowThresholdPercent` disk-based LRU — but these are plain-docker hosts that don't run it.)

**The consequence is unbounded growth until the disk fills.** This is exactly what the fleet audit ([§18.8](07-tuning-observability.md#188-recommended-cache-sizes-grounded-in-the-fleet-image-audit)) measures: **2.13 PB** of fleet image storage, **73.7 % of it reclaimable** — the steady state of a fleet that pulls constantly and prunes rarely. Introducing the cache does **not** by itself change this: containerd still downloads, unpacks, and permanently roots every image locally. What to do about the local store once the cache exists is its own design question — see [§24](08-operations.md#24-local-container-image-lifecycle-on-cache-clients).

---

## 4. End-to-end flows

This section traces the three workloads hop by hop. They share the same shape (per-client nginx → shared cache → origin), but they differ in the one thing that confuses people most: **where TLS is, and which CA validates each encrypted hop.** There are **three** trust anchors in play — the **public CA** (real origins), the **per-client MITM CA** (the client forging origin certs on its `:443`, [§14.2](06-mitm-and-content.md#142-the-internal-ca-and-per-fqdn-certs)), and the **cache CA** (authenticating the cache layer on the client→cache hop, [§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)). The short version:

- **The client→cache hop is always TLS under the cache CA** — in every flow below; it never carries the per-client MITM CA.
- **Container pulls never use the MITM CA** — beyond the cache hop, the only other TLS is cache→origin, against the public CA store.
- **Default apt adds no *origin* TLS** — integrity comes from GPG package signatures; the only TLS on the path is the cache-CA client→cache hop.
- **Model pulls (and the one HTTPS apt repo) are the only flows that use the MITM CA**, on *exactly one* hop (client tool→client nginx); the nginx→origin hop still uses the public CA.

Legend used in every diagram below:

```
── HTTP   plaintext, no TLS, no certificate on this hop
══ HTTPS  TLS on this hop;  [CA: …] = which trust store validates the cert
```

### 4.1 OCI container pull (`docker pull`)

`docker pull nginx` from Docker Hub on any client:

```
docker pull nginx
  │  unix socket — local containerd API, no network, no cert
  ▼
dockerd / containerd            reads certs.d/docker.io/hosts.toml
  │                             → mirror = http://127.0.0.1:8088
  │  ── HTTP/1.1 · plaintext · NO TLS / NO cert ──
  │     GET /v2/library/nginx/manifests/…?ns=docker.io
  │     (containerd loopback hop is TCP-only: no unix socket, no H2/H3 — §12)
  ▼
client nginx :8088 ── local hot tier ──┐
  │                                     └─ HIT → served locally, no network hop
  │  MISS → consistent-hash: manifests = ns:uri, blobs = blob:sha256:<digest>
  │  ══ HTTP/1.1 · HTTPS · [CA: internal cache CA] ══  (over cachebr0, §11.5)
  ▼
cache nginx :8085 (cache0 / cache1) ────┐
  │                                      └─ HIT → served from disk
  │  MISS ↓
  │  ══ HTTPS · [CA: public / system bundle] ══   (Docker Hub's REAL cert)
  │     nginx follows the CDN 307 itself; stores the blob keyed by digest
  ▼
registry-1.docker.io  →  Docker Hub CDN
```

> **Where are the certs?** Two encrypted hops, two anchors: the **client→cache hop** is TLS under the **internal cache CA** ([§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)), and the final **cache→origin hop** is validated against the **public/system CA bundle** (the registry's genuine certificate). The **per-client MITM CA is not involved anywhere in a container pull** — only containerd's loopback hop is plaintext, and only because it never leaves the box. Zot runs beside the cache nginx as a verification oracle ([§7](02-caching-design.md#7-oci-caching-nginx-primary-zot-oracle)), never in this path.

### 4.2 apt update and apt install

apt splits into two very different cases.

**Default Ubuntu repos** (`archive.ubuntu.com`, `security.ubuntu.com`) — these are plain-HTTP repos, so the whole flow is plaintext:

```
apt update ; apt install jq
  │  Acquire::http::Proxy = http://127.0.0.1:8090
  │  ── HTTP · plaintext · NO TLS ──
  ▼
client nginx :8090 ── local hot tier ──┐
  │                                     └─ HIT → served locally
  │  MISS → consistent-hash on the request URI
  │  ══ HTTPS · [CA: internal cache CA] ══  (over cachebr0, §11.5)
  ▼
cache nginx :8086 (cache0 / cache1) ────┐
  │                                      └─ HIT → served
  │  MISS ↓ ── HTTP · plaintext · NO TLS ──   (apt origin is plain HTTP)
  ▼
archive.ubuntu.com / security.ubuntu.com
```

> **No *origin* certificate validates anything here.** apt verifies the **GPG signature** on the `Release`/`Packages` indexes itself (via its `signed-by` keyring); trust lives in the package signature, not the transport. Caching plain-HTTP debs is therefore safe — a tampered byte stream fails apt's signature check on the client. The only TLS on the path is the **client→cache hop under the cache CA** ([§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)); the cache→`archive.ubuntu.com` hop stays plain HTTP.

**The docker-ce repo** (`download.docker.com`) is HTTPS-only, so it rides the **MITM path** instead ([§14](06-mitm-and-content.md#14-https-interception-internal-ca--mitm)):

```
apt update   (deb [signed-by=…] https://download.docker.com/… )
  │  /etc/hosts → download.docker.com = 127.0.0.1
  │  ══ HTTPS · [CA: this client's INTERNAL CA] ══  (nginx presents a forged leaf)
  ▼
client nginx :443  (terminates TLS, SNI = download.docker.com)
  │  hot tier → MISS → consistent-hash
  │  ══ HTTPS · [CA: internal cache CA] ══  (over cachebr0, §11.5)
  ▼
cache nginx :8104 ──┐
  │                  └─ HIT → served
  │  MISS ↓ ══ HTTPS · [CA: public] ══   (download.docker.com REAL cert)
  ▼
download.docker.com
```

> `download.docker.com` is the **one apt source that touches the internal CA**, and only because it refuses plain HTTP. apt *still* GPG-verifies the docker-ce packages on top of the TLS.

### 4.3 Hugging Face model pull

`huggingface-cli download …`, here run inside a container (the hardest case — the CA must reach inside the container too):

```
docker run python … huggingface-cli download TinyLlama/TinyLlama-1.1B-Chat-v1.0
  │  runc ca-injector has ALREADY bind-mounted THIS HOST's CA + /etc/hosts
  │  into the container → huggingface.co resolves to 127.0.0.1 (§14.4)
  ▼
huggingface-cli  (inside the container)
  │  ══ HTTPS · [CA: this client's INTERNAL CA] ══
  │     SNI = huggingface.co; client nginx presents a forged per-FQDN leaf
  ▼
client nginx :443   (terminates TLS — the deliberate MITM)
  │  hot tier → MISS → consistent-hash on hf:<uri>
  │  ══ HTTPS · [CA: internal cache CA] ══  (over cachebr0, §11.5)
  ▼
cache nginx :8100  (HF vhost, cache0 / cache1)
  │  metadata / manifest → served from cache
  │  LFS weight file → 302 to cdn-lfs*.huggingface.co; nginx follows:
  │  ══ HTTPS · [CA: public] ══   (HF CDN's REAL cert)
  │     cached by content-addressed path; signed CDN query args stripped (§15.2)
  ▼
huggingface.co  →  cdn-lfs*.huggingface.co
```

> **Three TLS legs, three different trust anchors.** client tool→nginx uses the **per-client MITM CA** (we forge the `huggingface.co` cert so we can read and cache the request); nginx→cache uses the **cache CA** ([§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)) so the decrypted bytes are re-encrypted across `cachebr0`, not sent in clear; cache→CDN uses the **public CA** (the real upstream cert). Ollama, ModelScope, and PyTorch Hub follow the same shape ([§15](06-mitm-and-content.md#15-llm-model-store-caching)).

---

## 5. Requirements

These are the properties the caching fabric must have. They are the *why* behind every design choice that follows, and they are what drove the collapse from "HAProxy/Varnish on clients + nginx on caches" down to a single nginx technology.

1. **High availability.** A single cache failure must not break image pulls or apt/model downloads. Clients **health-check** the cache layer and route around a dead backend. (Note: only *pulls* are affected by a cache outage — already-running containers keep running.) We document and measure **two** health-check strategies:
   - *Passive* (the zero-extra-component default): nginx `max_fails`/`fail_timeout` marks a backend down after in-band failures, and `proxy_next_upstream` retries the request on the survivor. Failover happens *on the failing request*.
   - *Active* (the proactive upgrade): OpenResty's in-process `lua-resty-upstream-healthcheck` HEAD-checks each backend on a fixed interval and marks a dead peer down in shared memory **before** a client request ever hits it — no daemon, no reload ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)).

2. **Consistent hashing.** We want to **maximize shared-cache utilization**: each object should be cached **once** across the fleet, not duplicated per-client. A consistent hash (ketama) spreads objects roughly evenly across the cache VMs in steady state, and — crucially — when a backend is **added, removed, or fails**, only ~`1/n` of keys remap rather than the whole keyspace. This lets us **scale the shared cache by adding VMs** while keeping it a single large logical cache.
   - **Blast radius scales with `n`.** This lab uses **`n=2`** for simplicity, where losing one cache remaps ~**50%** of keys. In production we **recommend `n≥3` (ideally 4)**: at `n=4` a single failure remaps only ~**25%**. The lab is deliberately the worst-case `n` so failure behaviour is easy to observe.

3. **Local hot-cache tier.** Each client keeps a **small** local `proxy_cache` so very hot objects (popular base-image manifests, small hot blobs) serve **with no network hop at all**. This tier is deliberately **small** — it must *not* try to mirror the whole shared cache; it favours hot manifests and small/hot blobs and LRU-evicts large cold blobs (we use `proxy_cache_min_uses` so one-off large pulls don't churn the hot set). The big shared volume lives on the cache VMs.

4. **A single cache technology.** One proxy — **nginx** — does the local hot cache, the consistent-hash routing, *and* the OCI/apt/model-store caching at the shared layer. Fewer technologies means one tuning story, one observability story, one mental model. The earlier two-proxy draft (nginx caches + Varnish/HAProxy clients) existed only because nginx OSS lacks *active* health checks — requirement #1 removes that need. **Zot** is retained, but only as a spec-correct **verification oracle** ([§7](02-caching-design.md#7-oci-caching-nginx-primary-zot-oracle)), never on the serving path.

5. **Unmodified client tooling.** `docker` / `containerd` / `apt` and the model CLIs (`huggingface-cli`, `ollama`, `modelscope`, `torch.hub`) must work **as-is** — caching is wired in via containerd `hosts.toml`, the apt proxy drop-in, and MITM ([§14](06-mitm-and-content.md#14-https-interception-internal-ca--mitm)), never by asking users to edit Dockerfiles or client code. This is a hard constraint inherited from `design.md` §11.

---
