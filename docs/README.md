# Design docs — object-caching-experiments

This folder is the **canonical design** for the lab: why it exists, how it is shaped, and —
above all — **what is actually built today**. Each part leads with the reasoning behind a
decision and then describes the as-built implementation. Anything not yet built is collected and
clearly fenced in the final part.

## The problem, in one paragraph

Picture a datacenter of **~500 client machines** all running AI/LLM container workloads. Every
job start pulls the same large things off the public internet — multi-GiB container images
(CUDA, PyTorch, vLLM), `apt` packages, and model weights (Hugging Face, Ollama, ModelScope,
PyTorch Hub) that run to tens of GiB. Done naively that is 500× the WAN egress and 500× the
exposure to a slow or rate-limited origin. The fix is **caching with the right locality**:
serve a repeat fetch from a **per-client local hot cache** (best), else from a small set of
**shared in-datacenter cache machines** over the LAN (good), and only let a true fleet-wide
first-touch reach the **WAN** (last resort). This repository is a **scaled-down, end-to-end
working model** of that target — one NixOS client + three Ubuntu clients against two shared
cache machines on an isolated virtual network — so the whole design can be built, booted, and
tested on a single host.

## The parts

| Part | What it covers |
|------|----------------|
| [01 — Overview & flows](01-overview.md) | The problem, the two-tier goal, end-to-end fetch flows (OCI / apt / model), and the requirements that drove the design. |
| [02 — Architecture & topology](02-architecture.md) | The fleet, the `cachebr0` network, the IP/MAC/port map, and the repo/module layout. |
| [03 — The client cache](03-client.md) | The per-client nginx: local hot tiers, consistent-hash routing, digest-keyed blobs, health-checking, and container-runtime wiring. |
| [04 — The shared cache VMs](04-cache-vms.md) | The shared nginx pull-through cache, the ZFS pool split, and the Zot verification oracle. |
| [05 — Trust & MITM](05-trust-and-mitm.md) | The two CAs, per-FQDN leaf certs, host redirection, and the runc CA-injector that makes *unmodified* pulls work. |
| [06 — Content sources](06-content-sources.md) | What is cached and how each is keyed: OCI registries, apt mirrors, and the four model stores. |
| [07 — Tuning & observability](07-tuning-observability.md) | Kernel/nginx tuning, the unified access-log format, and the Prometheus exporters. |
| [08 — Operations & future work](08-operations-and-future.md) | Build/run/deploy workflow, the differential-test correctness gate, and a fenced list of work not yet built. |

## See also

- **[`container-mitm-arbitrary-origins.md`](container-mitm-arbitrary-origins.md)** — a
  forward-looking **exploration** (not built): how the curated-FQDN container MITM of §05 *could* be
  generalised to arbitrary origins via nftables DNAT + on-the-fly certs.
- **[`../README.md`](../README.md)** — the repository landing page (problem statement, headline
  diagram, repo map).
- **[`../nix/README.md`](../nix/README.md)** — the operational run guide: the full set of
  `nix run .#cache-*` apps, flake wiring, and troubleshooting.
- **[`../nix/constants/`](../nix/constants/)** — the single source of truth for IPs, ports, MACs,
  upstreams, and resources that every number in these docs is drawn from.
