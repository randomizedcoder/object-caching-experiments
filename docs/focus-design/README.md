# object-caching-experiments — Focused Design

> This is the **focused, single-design** document. It distils the broad exploration in [`design.md`](../design.md) down to the **one design we want to build and measure**. Where this doc and `design.md` disagree, **this doc wins**. `design.md` is kept as the rationale archive — read it for the alternatives we considered and rejected (Distribution, ATS, Squid/Envoy/Traefik, the HTTPS-MITM PKI deep-dive, etc.).

## 1. Introduction

A small, fully-`flake.nix`-driven NixOS test harness for a **single-cache- technology** pull-through caching fabric. One technology — **nginx** — does the job end to end:

- **On every client**, one nginx serves a **two-tier cache**: a small **local hot-cache** for very hot objects, backed by a **consistent-hash router** that spreads everything else across the shared cache layer.
- **On every cache VM**, nginx is the **shared cache** that the clients hash into (plus apt and model-store vhosts).

There is no second caching proxy. The earlier draft put **HAProxy or Varnish** on the clients purely because nginx OSS lacks *active* health checks — but nginx OSS already does **consistent hashing** (`hash … consistent;`, ketama) and **local caching** (`proxy_cache`), so the only missing piece is health-checking. We solve that with nginx's own **passive** checks (`max_fails`/`fail_timeout` + `proxy_next_upstream`) as the always-on in-band backstop, plus **in-process active** checks via **OpenResty's [`lua-resty-upstream-healthcheck`](https://github.com/openresty/lua-resty-upstream-healthcheck)** — no daemon, no reload. (We first designed a standalone Go agent for this; it's now a *considered-and-rejected* alternative, [§22](08-operations.md#22-alternatives-considered-client-side-proxy).) HAProxy and Varnish are likewise demoted to *alternatives considered* ([§22](08-operations.md#22-alternatives-considered-client-side-proxy)). **OpenResty runs on the cache VMs too** — not only for uniformity, but for headroom: arbitrary Lua logic and a future **hierarchical cache tier** ([§23](08-operations.md#23-future-work)) that would health-check and fail over with the very same in-process mechanism. The **client→cache hop is encrypted and authenticated** with a dedicated internal cache CA ([§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)).

> *The headline question this lab now answers: how well does a single nginx fabric — local hot tier + consistent-hash to a shared cache layer, made highly available by health-checking — serve a mixed OCI / apt / model-store workload, and how do passive vs in-process active (lua) health checks compare under an induced cache failure?*

Behind the clients sit **two cache VMs**, each running:

- **nginx** — the primary shared cache for OCI blobs/manifests, apt packages, model stores, and a `_default` wildcard catch-all.
- **Zot** — an OCI-native registry kept **only as a verification oracle** ([§7](02-caching-design.md#7-oci-caching-nginx-primary-zot-oracle)): a spec-correct ground truth we diff nginx against, not part of the steady-state serving path.

Everything is observable: **node_exporter on every machine**, **nginx-prometheus-exporter** on clients *and* cache VMs, and **Zot's built-in metrics** (oracle). The in-process lua health-check exposes no metrics of its own — host-down alerting is left to existing host monitoring (node_exporter).

### 1.1 What changed vs `design.md`

| Dimension              | `design.md` (broad)                              | This doc (focused)                                            |
|------------------------|--------------------------------------------------|--------------------------------------------------------------|
| NixOS clients          | 2 (`client0`, `client1`)                         | **1** (`client0`)                                            |
| Ubuntu clients         | 3 (22.04 / 24.04 / 26.04)                        | 3 (unchanged)                                                |
| Cache VMs              | 2 (`cache0`, `cache1`)                           | 2 (unchanged)                                                |
| Client-side proxy      | HAProxy only (Varnish was a *cache-VM* backend) | **nginx only** — local hot tier + consistent-hash router (HAProxy/Varnish → [§22](08-operations.md#22-alternatives-considered-client-side-proxy) alternatives) |
| Container cache        | Distribution + Zot + nginx + Varnish + ATS      | **nginx (primary); Zot kept as verification oracle**        |
| HTTP / apt cache       | nginx + apt-cacher-ng                            | **nginx only**                                               |
| High availability      | active health checks (Plus / HAProxy / Varnish) | **passive backstop + in-process lua active HC (OpenResty)**  |
| Client interception    | containerd `hosts.toml` (primary) + MITM + legacy| **containerd `hosts.toml` (containers) + HTTPS MITM (model stores / HTTPS repos)** |
| LLM model stores       | not covered                                      | **Hugging Face, Ollama, ModelScope, PyTorch Hub — cached & tested** |
| Transport              | not specified                                    | **HTTP/3+H2 on listeners we own; containerd hop is HTTP/1.1 (forced); nginx→cache hop HTTP/1.1** |
| Performance tuning     | not covered                                      | **per-component (nginx / Zot) + QUIC/HTTP3 + kernel sysctls** |
| Observability          | mentioned as future work                         | **first-class: exporters everywhere, metrics enabled**       |

### 1.2 Scope

- Container image caching for five Tier-1 OCI registries + a wildcard catch-all, all via the containerd `hosts.toml` mechanism (so users' Dockerfiles stay **unmodified**).
- OS-package caching for **apt** (Debian/Ubuntu HTTP repos) through nginx.
- **LLM model store caching** for **Hugging Face**, **Ollama**, **ModelScope**, and **PyTorch Hub** ([§15](06-mitm-and-content.md#15-llm-model-store-caching)).
- **HTTPS interception (internal CA / MITM)** so the HTTPS-only model stores and HTTPS third-party repos (`download.docker.com`) are cacheable ([§14](06-mitm-and-content.md#14-https-interception-internal-ca--mitm)). We own all hosts, so breaking E2E TLS on the lab subnet is acceptable. TLS now terminates at the **client nginx**.
- **High availability via health-checking** — passive nginx checks as the in-band backstop, plus in-process active checks via OpenResty's `lua-resty-upstream-healthcheck` ([§11](04-client.md#11-client-architecture-nginx-two-tier-cache)).
- **Encrypted client→cache transport** — the client nginx→cache nginx hop runs TLS, verified against a dedicated internal **cache CA** (separate from the per-client MITM CA), distributed to clients over SSH ([§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)).
- **Per-component performance tuning** (nginx, Zot) plus **QUIC/HTTP3 tuning** and **kernel network sysctls** ([§18](07-tuning-observability.md#18-performance-tuning)).
- Full Prometheus-shaped observability.

### 1.3 Non-goals (deferred to `design.md`)

- Distribution, Apache Traffic Server, Squid, Envoy, and the Varnish/ATS *cache-VM* backends — the focused cache is **nginx**, with **Zot kept only as a verification oracle**.
- **HAProxy / Varnish / Envoy / IPVS as the client-side proxy** — these were considered and rejected for the steady-state design; see [§22](08-operations.md#22-alternatives-considered-client-side-proxy).
- Legacy `daemon.json registry-mirrors` mode (docker.io-only; kept in `design.md` §11.3 as a comparison baseline).
- Statistically rigorous benchmarking — we want reproducible *qualitative* comparisons first, with metrics hooks for later.

---

## 2. Table of Contents

The focused design is split across the documents below. Section numbers are preserved end to end (§1–§2 live here; the sub-documents start at §3).

**[Overview, end-to-end flows, and requirements](01-overview.md)**

- [§3 Overview](01-overview.md#3-overview)
- [§4 End-to-end flows](01-overview.md#4-end-to-end-flows)
  - [§4.1 OCI container pull (`docker pull`)](01-overview.md#41-oci-container-pull-docker-pull)
  - [§4.2 apt update and apt install](01-overview.md#42-apt-update-and-apt-install)
  - [§4.3 Hugging Face model pull](01-overview.md#43-hugging-face-model-pull)
- [§5 Requirements](01-overview.md#5-requirements)

**[What to cache and the OCI caching design](02-caching-design.md)**

- [§6 What needs to be cached](02-caching-design.md#6-what-needs-to-be-cached)
  - [§6.1 Manifests vs blobs](02-caching-design.md#61-manifests-vs-blobs)
  - [§6.2 The OCI Distribution Specification](02-caching-design.md#62-the-oci-distribution-specification)
  - [§6.3 Caching best practices, per cache](02-caching-design.md#63-caching-best-practices-per-cache)
- [§7 OCI caching: nginx primary, Zot oracle](02-caching-design.md#7-oci-caching-nginx-primary-zot-oracle)
  - [§7.1 What Zot gives for free](02-caching-design.md#71-what-zot-gives-for-free)
  - [§7.2 What nginx-only must replicate by hand](02-caching-design.md#72-what-nginx-only-must-replicate-by-hand)
  - [§7.3 Why nginx-only is still attractive](02-caching-design.md#73-why-nginx-only-is-still-attractive)
  - [§7.4 The committed design: nginx cache, Zot as verification oracle](02-caching-design.md#74-the-committed-design-nginx-cache-zot-as-verification-oracle)

**[Repository layout, network topology, and constants](03-architecture.md)**

- [§8 Repository Layout](03-architecture.md#8-repository-layout)
- [§9 Network Topology](03-architecture.md#9-network-topology)
  - [§9.1 Port map](03-architecture.md#91-port-map)
- [§10 Constants Module (`nix/constants.nix`)](03-architecture.md#10-constants-module-nixconstantsnix)

**[Client architecture and containerd config](04-client.md)**

- [§11 Client architecture: nginx two-tier cache](04-client.md#11-client-architecture-nginx-two-tier-cache)
  - [§11.1 The two tiers](04-client.md#111-the-two-tiers)
  - [§11.2 Consistent-hash router and cache keys](04-client.md#112-consistent-hash-router-and-cache-keys)
  - [§11.3 Health-checking: passive and in-process active](04-client.md#113-health-checking-passive-and-in-process-active)
  - [§11.4 Transport / HTTP versions](04-client.md#114-transport--http-versions)
- [§12 Containerd client config (unmodified Dockerfiles)](04-client.md#12-containerd-client-config-unmodified-dockerfiles)
  - [§12.1 hosts.toml per Tier-1 registry](04-client.md#121-hoststoml-per-tier-1-registry)
  - [§12.2 The ns= routing key](04-client.md#122-the-ns-routing-key)
  - [§12.3 The _default wildcard](04-client.md#123-the-_default-wildcard)
  - [§12.4 Switching cache mode](04-client.md#124-switching-cache-mode)

**[Cache VMs: nginx primary and Zot oracle](05-cache-vms.md)**

- [§13 Cache VMs: nginx primary and Zot oracle](05-cache-vms.md#13-cache-vms-nginx-primary-and-zot-oracle)
  - [§13.1 Zot (verification oracle)](05-cache-vms.md#131-zot-verification-oracle)
  - [§13.2 nginx wildcard OCI catch-all](05-cache-vms.md#132-nginx-wildcard-oci-catch-all)
  - [§13.3 nginx apt cache](05-cache-vms.md#133-nginx-apt-cache)
  - [§13.4 Docker Hub CDN handling](05-cache-vms.md#134-docker-hub-cdn-handling)

**[HTTPS interception, model stores, Ubuntu clients, apt](06-mitm-and-content.md)**

- [§14 HTTPS interception (internal CA / MITM)](06-mitm-and-content.md#14-https-interception-internal-ca--mitm)
  - [§14.1 Why MITM is required here](06-mitm-and-content.md#141-why-mitm-is-required-here)
  - [§14.2 The internal CA and per-FQDN certs](06-mitm-and-content.md#142-the-internal-ca-and-per-fqdn-certs)
  - [§14.3 DNS redirection + TLS termination at the client nginx](06-mitm-and-content.md#143-dns-redirection--tls-termination-at-the-client-nginx)
  - [§14.4 Trust insertion on hosts and inside containers](06-mitm-and-content.md#144-trust-insertion-on-hosts-and-inside-containers)
- [§15 LLM model store caching](06-mitm-and-content.md#15-llm-model-store-caching)
  - [§15.1 The four sources and their shapes](06-mitm-and-content.md#151-the-four-sources-and-their-shapes)
  - [§15.2 Hugging Face](06-mitm-and-content.md#152-hugging-face)
  - [§15.3 Ollama](06-mitm-and-content.md#153-ollama)
  - [§15.4 ModelScope and PyTorch Hub](06-mitm-and-content.md#154-modelscope-and-pytorch-hub)
- [§16 Ubuntu clients](06-mitm-and-content.md#16-ubuntu-clients)
- [§17 apt caching](06-mitm-and-content.md#17-apt-caching)

**[Performance tuning and observability](07-tuning-observability.md)**

- [§18 Performance tuning](07-tuning-observability.md#18-performance-tuning)
  - [§18.1 Kernel / network sysctls (all machines)](07-tuning-observability.md#181-kernel--network-sysctls-all-machines)
  - [§18.2 nginx tuning](07-tuning-observability.md#182-nginx-tuning)
  - [§18.3 QUIC / HTTP3 tuning](07-tuning-observability.md#183-quic--http3-tuning)
  - [§18.4 Lua health-check tuning](07-tuning-observability.md#184-lua-health-check-tuning)
  - [§18.5 Zot tuning](07-tuning-observability.md#185-zot-tuning)
- [§19 Observability (Prometheus)](07-tuning-observability.md#19-observability-prometheus)

**[Build, measurement, alternatives, and future work](08-operations.md)**

- [§20 Build and run workflow](08-operations.md#20-build-and-run-workflow)
- [§21 What we measure](08-operations.md#21-what-we-measure)
- [§22 Alternatives considered: client-side proxy](08-operations.md#22-alternatives-considered-client-side-proxy)
- [§23 Future work](08-operations.md#23-future-work)
