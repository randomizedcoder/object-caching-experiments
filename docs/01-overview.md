# 01 — Overview & flows

## 1.1 The problem

A datacenter of ~500 client machines runs AI/LLM container workloads. Each job start
independently pulls the same artifacts off the public internet:

- **container images** — often many GiB (CUDA, PyTorch, vLLM, …),
- **`apt` packages** — base-image updates and build dependencies,
- **model weights** — Hugging Face / Ollama / ModelScope / PyTorch Hub, frequently tens of GiB.

Naively, that is 500× the WAN egress, 500× the latency, and 500× the chance a slow or
rate-limited origin (Docker Hub especially) stalls a cold start.

This design is **workload-agnostic**: any operator of a datacenter full of container hosts can
adopt it. Throughout these docs RunPod's images serve as one concrete **example** fleet — a
representative large AI/ML container workload — but they are illustrative, not the target. An
operator substitutes their own images and origins and the same two-tier caching applies.

## 1.2 The goal: caching with the right locality

The design pushes every fetch to the cheapest tier that can satisfy it:

1. **Best — local hit.** Each client runs its own on-box cache; a repeat fetch never leaves the
   machine.
2. **Good — datacenter hit.** On a local miss, the client asks a small set of **shared cache
   machines** over the LAN. The WAN is touched once for the whole fleet.
3. **Last resort — WAN.** Only a fleet-wide first-touch reaches the public origin, and the
   result is cached at both tiers on the way back.

The aim is to maximise tier-1 hit-rate, catch the rest at tier-2, and drive WAN egress toward
zero — so container cold-start approaches local-disk speed.

This repository is a **scaled-down working model** of that target: instead of 500 clients it
runs a handful (one NixOS client + three Ubuntu clients) against **two** shared cache machines
on an isolated virtual network, so the whole design builds, boots, and tests on a single host.

## 1.3 The shape of the solution

Every hop is `nginx` (OpenResty). There are two cache tiers:

- **Client tier** — a small local hot cache on each client. On a miss it acts as a
  **consistent-hash router**, hashing the content key onto one of the shared cache VMs so the
  fleet keeps **one shared copy per blob**.
- **Shared tier** — the cache VMs do the heavy lifting: they pull through to the upstreams,
  follow CDN redirects themselves, and cache the bytes keyed by content digest.

```
   client job ──▶ client nginx ──hit──▶ client job
                       │
                     miss
                       │  consistent hash on  sha256:<digest> / ns:uri
                       ▼
            ┌─────── shared cache VMs ───────┐
            │  cache0 nginx      cache1 nginx │
            └───────┬──────────────┬──────────┘
                  hit│            │miss
                     ▼            ▼  NAT → WAN
              client job     upstream registries / apt mirrors / model stores
```

## 1.4 End-to-end fetch flows

### OCI image pull

```
docker/nerdctl pull gcr.io/foo/bar
  └─ containerd certs.d hosts.toml  →  client nginx :8088  (?ns=gcr.io)
       ├─ manifest  /v2/.../manifests/<ref>   key = ns:uri        (5m TTL, local)
       └─ blob      /v2/.../blobs/sha256:<d>   key = blob:<digest> (30d TTL, local)
            └─ local miss → hash($cache_key) → cache VM :8085 (TLS)
                 ├─ blob  key = blob:<digest>   (30d)  ─┐
                 └─ manifest key = ns:method:uri (30d)  ├─ miss → upstream (ns→host)
                      └─ 30x to CDN → cache VM follows it, caches body under the SAME key
```

### apt

```
apt-get update / install     (Acquire::http::Proxy → client nginx :8090)
  └─ client nginx :8090   key = host+request_uri   (5m TTL, local)
       └─ miss → cache VM :8086 (TLS)   key = host+request_uri
            ├─ indices (InRelease/Packages/…)  5m TTL
            └─ .deb (content-addressed)         30d TTL
                 └─ miss → archive/security/ports.ubuntu.com  (plain HTTP; .debs are GPG-signed)
```

### Model download (Hugging Face shown; MITM'd HTTPS)

```
curl/huggingface_hub  https://huggingface.co/...   (/etc/hosts → client nginx :443)
  └─ client nginx :443  terminates TLS with a forged leaf (per-client MITM CA)
       set X-Orig-Host: huggingface.co ; hash → cache VM model vhost :8100 (TLS)
            └─ cache VM proxies to the real origin, follows the 302→CDN (cdn-lfs)
                 caches the content-addressed payload, signed query args dropped
```

## 1.5 Requirements that drove the design

- **R1 — Unmodified clients.** An external user's Dockerfile and `docker pull` must work
  **as-is**: no edits, no `-k`, no baked-in CA. This is the hard constraint that forces
  transparent interception (containerd `hosts.toml`, `/etc/hosts` redirection, and the MITM
  CA + runc injector in [05](05-trust-and-mitm.md)).
- **R2 — Fleet-wide single copy.** A blob fetched by any client should be served from the shared
  tier to every other client. Consistent hashing on the content key gives one shared copy per
  blob ([03](03-client.md)).
- **R3 — Small client footprint.** The client hot tier is deliberately small (a few GiB per
  workload); the shared tier holds the corpus.
- **R4 — Fail-open.** A down cache must never break a pull — it only stops accelerating it.
  Passive + active health-checks and containerd's `server =` fallback enforce this.
- **R5 — Provably correct.** The hand-written nginx caching rules must return byte-identical
  content to a spec-correct registry. A differential test against an off-path Zot oracle proves
  this ([04](04-cache-vms.md), [08](08-operations-and-future.md)).
- **R6 — One source of truth.** Topology, ports, and trust material come from
  [`nix/constants/`](../nix/constants/) so the NixOS and Ubuntu client paths stay in lock-step
  ([02](02-architecture.md)).
