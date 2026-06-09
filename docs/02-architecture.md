# 02 — Architecture & topology

## 2.1 The fleet

The lab is a handful of VMs on one isolated bridge, sized to prove the design end-to-end rather
than to store the real fleet corpus:

- **`client0`** — a NixOS MicroVM. Runs Docker + containerd and one OpenResty instance that is
  both the local hot cache and the consistent-hash router. The pattern the 500 production clients
  would follow.
- **`ubuntu2204` / `ubuntu2404` / `ubuntu2604`** — stock Ubuntu clients that apply the *same*
  NixOS modules via [system-manager](https://github.com/numtide/system-manager), proving the
  client config is portable to bare-metal/cloud hosts.
- **`cache0` / `cache1`** — the shared cache VMs. Each runs the pull-through nginx cache plus
  five off-path Zot oracles. The two are interchangeable; the client hashes across both.

## 2.2 Network

All nodes sit on a dedicated dual-stack bridge `cachebr0`, NAT'd to the WAN. A separate subnet
from the operator's other labs keeps them isolated.

```
                  Linux host  ──  bridge cachebr0  10.44.44.1/24  ·  fd44:44:44::1
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  CLIENTS  (each runs ONE nginx: local hot cache + consistent-hash router)      │
  │                                                                                │
  │   client0      ubuntu2204     ubuntu2404     ubuntu2604                         │
  │   .10 (NixOS)  .30            .31            .32                                │
  │   docker + nginx  ·  OCI :8088  ·  apt :8090  ·  MITM TLS :443                  │
  └───────────────┬────────────────────────────────────────────────────────────────┘
                  │  local miss → consistent hash on  sha256:<digest> / ns:uri
                  ▼
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  SHARED CACHES                                                                  │
  │   cache0 .20                            cache1 .21                              │
  │   nginx  OCI :8085 · apt :8086 · models :8100–8103 · extra :8104  (all TLS)     │
  │   zot ×5 oracle :5050–5054   (off the serving path — verification only)         │
  └───────────────┬────────────────────────────────────────────────────────────────┘
                  │  cache miss
                  ▼   NAT → WAN
   docker.io · gcr.io · ghcr.io · quay.io · registry.k8s.io
   archive.ubuntu.com · security.ubuntu.com · ports.ubuntu.com
   huggingface.co · registry.ollama.ai · modelscope.cn · download.pytorch.org
```

### Address table

| Node | IPv4 | IPv6 | MAC | TAP |
|------|------|------|-----|-----|
| client0 | 10.44.44.10 | fd44:44:44::10 | 02:00:0a:2c:2c:10 | cachetap0 |
| cache0 | 10.44.44.20 | fd44:44:44::20 | 02:00:0a:2c:2c:20 | cachetap1 |
| cache1 | 10.44.44.21 | fd44:44:44::21 | 02:00:0a:2c:2c:21 | cachetap2 |
| ubuntu2204 | 10.44.44.30 | fd44:44:44::30 | 02:00:0a:2c:2c:30 | — |
| ubuntu2404 | 10.44.44.31 | fd44:44:44::31 | 02:00:0a:2c:2c:31 | — |
| ubuntu2604 | 10.44.44.32 | fd44:44:44::32 | 02:00:0a:2c:2c:32 | — |

Gateway `10.44.44.1` / `fd44:44:44::1`; subnets `10.44.44.0/24` and `fd44:44:44::/64`.

## 2.3 Port map

| Port | Role | Where |
|------|------|-------|
| 8088 | OCI frontend (containerd `hosts.toml` target) | client |
| 8090 | apt frontend (`Acquire::http::Proxy` target) | client |
| 443 | MITM HTTPS termination (model stores + extra) | client |
| 8085 | OCI wildcard cache (TLS) | cache VMs |
| 8086 | apt cache (TLS) | cache VMs |
| 8100–8103 | model-store vhosts: HF 8100 · ModelScope 8101 · PyTorch 8102 · Ollama 8103 (TLS) | cache VMs |
| 8104 | generic MITM-extra vhost (e.g. download.docker.com) (TLS) | cache VMs |
| 8099 | localhost-only `stub_status` (scraped by nginx-exporter) | both nginx roles |
| 9100 | `node_exporter` | all |
| 9113 | `nginx-exporter` | both nginx roles |
| 5050–5054 | Zot oracles (docker.io / gcr.io / ghcr.io / quay.io / registry.k8s.io) | cache VMs |

All numbers above come from [`nix/constants/network.nix`](../nix/constants/network.nix) and
[`nix/constants/app.nix`](../nix/constants/app.nix); nothing is hard-coded elsewhere.

## 2.4 Repository & module layout

The whole lab is Nix. The single source of truth lives in `nix/constants/`, and the reusable
behaviour lives in `nix/modules/`:

| Module | Responsibility |
|--------|----------------|
| [`nginx-client.nix`](../nix/modules/nginx-client.nix) | Client two-tier nginx: hot tiers, consistent-hash upstreams, Lua active health-check, the `:443` MITM frontends. → [03](03-client.md) |
| [`nginx-cache.nix`](../nix/modules/nginx-cache.nix) | Shared-cache nginx: wildcard OCI, apt, model/extra vhosts, CDN redirect-following. → [04](04-cache-vms.md) |
| [`zot-oracle.nix`](../nix/modules/zot-oracle.nix) | The five off-path Zot verification oracles. → [04](04-cache-vms.md) |
| [`zfs-cache-pools.nix`](../nix/modules/zfs-cache-pools.nix) | Runtime import/create of the per-workload ZFS cache pools. → [04](04-cache-vms.md), [07](07-tuning-observability.md) |
| [`mitm.nix`](../nix/modules/mitm.nix) + [`ca-injector.nix`](../nix/modules/ca-injector.nix) | Host redirection, leaf-cert plumbing, and the runc CA-injector shim. → [05](05-trust-and-mitm.md) |
| [`docker-client.nix`](../nix/modules/docker-client.nix) | containerd `certs.d` + Docker Engine wiring for unmodified pulls. → [03](03-client.md) |
| [`sysctls.nix`](../nix/modules/sysctls.nix) + [`observability.nix`](../nix/modules/observability.nix) | Kernel/network tuning and the Prometheus exporters. → [07](07-tuning-observability.md) |

The same modules drive both client platforms: NixOS MicroVMs and Ubuntu via system-manager,
keyed off the shared constants. Build and run are covered in
[`nix/README.md`](../nix/README.md) and summarised in [08](08-operations-and-future.md).
