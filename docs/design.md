# object-caching-experiments — Design

## 1. Introduction

This repository builds a small, reproducible test harness for **comparing
pull-through container image caches** (and one HTTP object cache) under a
realistic Docker workload. It uses NixOS [MicroVMs](https://github.com/astro/microvm.nix)
to spin up:

- **2 client microvms** that run Docker and pull images through a local
  HAProxy load-balancer; and
- **2 cache microvms** that run several candidate caches side-by-side on
  distinct ports (Docker Distribution registry, Zot, and nginx as a generic
  HTTP proxy cache).

The goal is to make it easy to swap the cache under test, exercise it from
both clients in parallel, and observe behaviour (hit rate, latency,
upstream bandwidth, failover) so we can pick the right cache for our
production workloads.

The repository follows the same modular Nix conventions used in our sister
projects
[`nix-k8s-examples`](../../nix-k8s-examples) and
[`ceph-on-k8s`](../../ceph-on-k8s):
a single `flake.nix` at the root, all reusable infrastructure under `nix/`,
and a single `nix/constants.nix` as the source of truth for every IP, MAC,
hostname, port, and resource size.

### 1.1 Scope

- Image / object caching only. **No Kubernetes**, no etcd, no PKI for K8s.
- Two upstream container registries are in scope: **`docker.io`** and
  **`gcr.io`**.
- One additional HTTP upstream is in scope for the nginx cache only:
  **`huggingface.co`** model mirrors.
- **Maximum caching is an explicit goal.** Every design choice below
  optimises for "second pull of the same blob/object never reaches
  upstream", including the design of the cache key and how each cache
  handles Docker Hub's new CloudFront/Cloudflare CDN architecture
  (see §6).
- The harness is for **local experimentation** on a single Linux host. It
  is not a production deployment.

### 1.2 Non-goals

- Not a benchmark suite with statistically rigorous methodology; we want
  reproducible *qualitative* comparisons first, with hooks for adding
  measurement later.
- Not a TLS / cert story. All in-VM traffic is HTTP unless explicitly noted;
  we rely on the experiment subnet being private.
- Not a Kubernetes mirror story; the
  [containerd `hosts.toml`](https://github.com/containerd/containerd/blob/main/docs/hosts.md)
  per-registry mirror pattern (which is strictly more flexible than Docker's
  `daemon.json`) is out of scope.

---

## 2. Table of Contents

1. [Introduction](#1-introduction)
2. [Table of Contents](#2-table-of-contents)
3. [Overview](#3-overview)
4. [Repository Layout](#4-repository-layout)
5. [Network Topology](#5-network-topology)
6. [Docker Hub's CDN architecture (and what it means for caching)](#6-docker-hubs-cdn-architecture-and-what-it-means-for-caching)
   1. [The blob-fetch flow](#61-the-blob-fetch-flow)
   2. [Why this matters for caching](#62-why-this-matters-for-caching)
   3. [Egress allowlist on the experiment subnet](#63-egress-allowlist-on-the-experiment-subnet)
7. [Constants Module (`nix/constants.nix`)](#7-constants-module-nixconstantsnix)
8. [MicroVM Definitions](#8-microvm-definitions)
9. [Cache Services on the Cache MicroVMs](#9-cache-services-on-the-cache-microvms)
   1. [Docker Distribution registry (proxy mode)](#91-docker-distribution-registry-proxy-mode)
   2. [Zot](#92-zot)
   3. [Nginx as an HTTP proxy cache](#93-nginx-as-an-http-proxy-cache)
   4. [Varnish](#94-varnish)
   5. [Apache Traffic Server](#95-apache-traffic-server)
   6. [Considered alternatives we did not pick](#96-considered-alternatives-we-did-not-pick)
10. [Client-side HAProxy: health checks and consistent hashing](#10-client-side-haproxy-health-checks-and-consistent-hashing)
    1. [Considered alternatives we did not pick](#101-considered-alternatives-we-did-not-pick)
11. [Client-side: per-registry transparent mirroring](#11-client-side-per-registry-transparent-mirroring)
    1. [Mode 1 (primary): containerd `hosts.toml` per-registry mirrors](#111-mode-1-primary-containerd-hoststoml-per-registry-mirrors)
        1. [Why this works today](#1111-why-this-works-today)
        2. [The `ns=` query parameter — the routing key HAProxy needs](#1112-the-ns-query-parameter--the-routing-key-haproxy-needs)
        3. [Tier 1: dedicated cache instances per upstream](#1113-tier-1-dedicated-cache-instances-per-upstream)
        4. [Per-registry `hosts.toml` files](#1114-per-registry-hoststoml-files)
        5. [The `_default` wildcard with a dynamic nginx catch-all](#1115-the-_default-wildcard-with-a-dynamic-nginx-catch-all)
        6. [Switching the cache type under test](#1116-switching-the-cache-type-under-test)
    2. [Mode 2: HTTPS MITM via HAProxy (see §12)](#112-mode-2-https-mitm-via-haproxy-see-12)
    3. [Mode 3: legacy `daemon.json` registry-mirrors (comparison baseline)](#113-mode-3-legacy-daemonjson-registry-mirrors-comparison-baseline)
12. [Alternative: transparent HTTPS MITM via HAProxy (full-control mode)](#12-alternative-transparent-https-mitm-via-haproxy-full-control-mode)
    1. [Why a vanilla HTTPS_PROXY doesn't help](#121-why-a-vanilla-https_proxy-doesnt-help)
    2. [The MITM solution: own the CA, mint certs, terminate TLS at HAProxy](#122-the-mitm-solution-own-the-ca-mint-certs-terminate-tls-at-haproxy)
    3. [PKI design](#123-pki-design)
    4. [Trust insertion on the client VMs](#124-trust-insertion-on-the-client-vms)
    5. [DNS poisoning (just `/etc/hosts` for v1)](#125-dns-poisoning-just-etchosts-for-v1)
    6. [HAProxy frontend with SNI termination](#126-haproxy-frontend-with-sni-termination)
    7. [Switching between caches in MITM mode](#127-switching-between-caches-in-mitm-mode)
    8. [Trade-offs vs the `registry-mirrors` mode](#128-trade-offs-vs-the-registry-mirrors-mode)
    9. [Why we keep both modes available](#129-why-we-keep-both-modes-available)
13. [OS package caching (apt / dnf / yum) — Layer 2](#13-os-package-caching-apt--dnf--yum--layer-2)
    1. [The cache target](#131-the-cache-target)
    2. [Topology](#132-topology)
    3. [Network-layer interception (iptables REDIRECT)](#133-network-layer-interception-iptables-redirect)
    4. [The CA-trust-in-containers problem](#134-the-ca-trust-in-containers-problem)
    5. [Implementation: the `cache-ca-injector` runc prestart hook](#135-implementation-the-cache-ca-injector-runc-prestart-hook)
    6. [What this does and doesn't catch](#136-what-this-does-and-doesnt-catch)
    7. [Trade-offs and risk](#137-trade-offs-and-risk)
14. [Build and run workflow](#14-build-and-run-workflow)
15. [Design choices to validate](#15-design-choices-to-validate)
16. [Future work](#16-future-work)

---

## 3. Overview

```
                                 ┌──────────────────────────────────────────┐
                                 │           Linux host (this machine)      │
                                 │                                          │
                                 │   bridge: cachebr0    10.44.44.1/24      │
                                 │                       fd44:44:44::1/64   │
                                 │   ┌──────────────┬──────────────┐        │
                                 │   │              │              │        │
                                 │ ┌─┴────────┐ ┌───┴──────┐ ┌─────┴─────┐  │
                                 │ │ client0  │ │ client1  │ │  cache0   │  │
                                 │ │ .10      │ │ .11      │ │  .20      │  │
                                 │ │ docker + │ │ docker + │ │  registry │  │
                                 │ │ haproxy  │ │ haproxy  │ │  zot      │  │
                                 │ └────┬─────┘ └────┬─────┘ │  nginx    │  │
                                 │      │            │       └─────┬─────┘  │
                                 │      │            │             │        │
                                 │      │            │       ┌─────┴─────┐  │
                                 │      │            │       │  cache1   │  │
                                 │      │            │       │  .21      │  │
                                 │      │            │       │  registry │  │
                                 │      │            │       │  zot      │  │
                                 │      │            │       │  nginx    │  │
                                 │      │            │       └───────────┘  │
                                 └──────┼────────────┼─────────────────────-┘
                                        │ NAT        │ NAT
                                        ▼            ▼
                                  docker.io / gcr.io / huggingface.co
```

**Flow of a pull from `client0`:**

1. `docker pull foo` on `client0`.
2. Docker daemon resolves the host of its configured `registry-mirrors`
   entry (e.g. `registry-r.local`) to `127.0.0.1` and connects to local
   HAProxy.
3. HAProxy uses the `Host:` header to pick the cache backend (Distribution
   vs Zot vs nginx) and **consistently hashes on the request URI** to pick
   between `cache0` and `cache1`. This way the same image blob always lands
   on the same cache, so hit rate scales with cache count rather than
   collapsing to `1/N`.
4. The picked cache (e.g. `cache0` running Distribution on `:5000`) checks
   its local store; on miss it fetches from the configured upstream
   (`docker.io` or `gcr.io`), stores, and returns to the client.

**What's variable across experiments:**

- Which cache (Distribution / Zot / nginx) handles the traffic — changed
  by editing one line in `/etc/docker/daemon.json` and reloading dockerd.
- Whether one or both cache VMs are up (cache miss penalty after failover).
- Image / model corpus used for the workload.

---

## 4. Repository Layout

The layout mirrors `nix-k8s-examples` and `ceph-on-k8s`:

```
object-caching-experiments/
├── flake.nix                       # all inputs + flake apps + microvm packages
├── flake.lock
├── README.md
├── CLAUDE.md                       # short project guide for Claude / contributors
├── LICENSE
├── docs/
│   └── design.md                   # this file
├── nix/
│   ├── constants.nix               # single source of truth (IPs, MACs, ports, sizes)
│   ├── nodes.nix                   # node registry → consumed by flake.nix mapAttrs'
│   ├── microvm-client.nix          # client0/client1 microvm generator (docker + haproxy)
│   ├── microvm-cache.nix           # cache0/cache1 microvm generator (registry + zot + nginx)
│   ├── network-setup.nix           # host-side bridge + TAPs + NAT (apps)
│   ├── microvm-scripts.nix         # vm lifecycle apps (start/stop/ssh/wipe)
│   ├── modules/
│   │   ├── docker-client.nix       # NixOS module: dockerd config with switchable mirror
│   │   ├── haproxy-client.nix      # NixOS module: HAProxy frontend + 6 backends
│   │   ├── registry-proxy.nix      # NixOS module: distribution proxy → upstream
│   │   ├── zot-proxy.nix           # NixOS module: Zot with two syncOnDemand upstreams
│   │   └── nginx-cache.nix         # NixOS module: nginx with three proxy_cache vhosts
│   └── shell.nix                   # dev shell (haproxy, curl, jq, regctl, crane)
├── secrets/                        # offline-generated (SSH host + user keys), git-staged
├── rendered/                       # generated config snapshots for inspection
└── <hostname>-data.img             # per-VM data disk, created at first boot
```

The two distinct microvm generators (`microvm-client.nix`, `microvm-cache.nix`)
mirror the two generators in `ceph-on-k8s` (`microvm.nix` for cluster nodes,
`microvm-client.nix` for the external Ceph client). Each generator is a
small parametric function that returns a microvm runner — `flake.nix`
walks `nodes.nix` and produces one `packages.x86_64-linux.cache-microvm-<name>`
attribute per VM.

---

## 5. Network Topology

A dedicated bridge isolates this lab from the bridges used by
`nix-k8s-examples` and `ceph-on-k8s` (both of which use `10.33.33.0/24`),
so all three labs can run on the same host concurrently.

| name      | value                          |
|-----------|--------------------------------|
| bridge    | `cachebr0`                     |
| IPv4 net  | `10.44.44.0/24`                |
| IPv4 gw   | `10.44.44.1` (bridge)          |
| IPv6 net  | `fd44:44:44::/64` (ULA)        |
| IPv6 gw   | `fd44:44:44::1` (bridge)       |

Per-VM addresses, MACs and TAPs (defined once in `nix/constants.nix`):

| VM        | TAP            | IPv4           | IPv6                | MAC                  |
|-----------|----------------|----------------|---------------------|----------------------|
| `client0` | `cachetap0`    | `10.44.44.10`  | `fd44:44:44::10`    | `02:00:0a:2c:2c:10`  |
| `client1` | `cachetap1`    | `10.44.44.11`  | `fd44:44:44::11`    | `02:00:0a:2c:2c:11`  |
| `cache0`  | `cachetap2`    | `10.44.44.20`  | `fd44:44:44::20`    | `02:00:0a:2c:2c:20`  |
| `cache1`  | `cachetap3`    | `10.44.44.21`  | `fd44:44:44::21`    | `02:00:0a:2c:2c:21`  |

Host setup (run once per boot via `sudo nix run .#cache-network-setup`):

1. `ip link add cachebr0 type bridge` + assign gateway IPs.
2. `ip tuntap add cachetap{0..3} mode tap multi_queue user $REAL_USER` and
   enslave each to the bridge.
3. nftables masquerade for `10.44.44.0/24` and `fd44:44:44::/64` so VMs can
   reach the upstream registries.
4. Enable `net.ipv4.ip_forward` and the equivalent IPv6 sysctl.

The pattern is copied verbatim from
[`nix/network-setup.nix`](../../nix-k8s-examples/nix/network-setup.nix) in
`nix-k8s-examples`; the only differences are the bridge / TAP / subnet
names and the **absence** of the apiserver HAProxy section (we don't need
it).

**Cache backend ports — one per `(cache_type, upstream)` pair.** Five
Tier-1 OCI upstreams (§11.1.3) × **five** cache implementations
(Distribution, Zot, nginx, Varnish, Apache Traffic Server — §9) = 25
OCI backends, plus a wildcard nginx for `_default` (§11.1.5) and a
non-OCI nginx for Hugging Face:

| port band     | cache type                            | upstream                                                             |
|---------------|---------------------------------------|----------------------------------------------------------------------|
| `5000`–`5004` | Distribution proxy                    | one port per Tier-1 upstream (`docker.io`, `gcr.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`) |
| `5050`–`5054` | Zot                                   | same five Tier-1 upstreams                                           |
| `5100`–`5104` | Varnish (with hitch sidecar for TLS)  | same five Tier-1 upstreams (§9.4)                                    |
| `5150`–`5154` | Apache Traffic Server                 | same five Tier-1 upstreams (§9.5)                                    |
| `8080`–`8084` | nginx (Option-1 §9.3)                 | same five Tier-1 upstreams                                           |
| `8085`        | nginx wildcard                        | `_default` — dynamic `proxy_pass https://$arg_ns;` for any other reg |
| `8090`        | nginx                                 | `huggingface.co` — HTTP, not OCI                                     |

> A single Zot / Varnish / ATS instance *could* serve multiple
> upstreams via its own multi-backend config, but running
> per-upstream listeners keeps the port table symmetric across the
> five cache implementations and gives us per-upstream isolation for
> measurement. Catch-all-via-{Varnish, ATS, Zot} is on the §16
> future-work list — the v1 wildcard is nginx-only because the
> `proxy_pass https://$arg_ns` trick is dead simple to write.

**Client-side HAProxy ports.** One frontend port per cache type, all
on each client:

| port  | cache type            |
|-------|-----------------------|
| `8088`| Distribution          |
| `8089`| Zot                   |
| `8090`| nginx                 |
| `8091`| Varnish               |
| `8092`| Apache Traffic Server |

Each frontend has ACLs on the containerd-added `ns=` query parameter
routing to the matching per-upstream backend pool, with a fallback to
the `nginx-default` wildcard backend for anything unrecognised. See
§10 for the HAProxy config and §11.1 for how the client gets steered
toward these ports.

---

## 6. Docker Hub's CDN architecture (and what it means for caching)

In May 2026 Docker Hub split blob distribution off the registry API host
and started serving the actual blob bytes from a set of CDN endpoints.
References:
[Docker Hub release notes (2026-05-20)](https://docs.docker.com/docker-hub/release-notes/),
[Docker Desktop allowlist](https://docs.docker.com/desktop/setup/allow-list/).

A Docker Hub pull now talks to **three** classes of host:

| Class    | Hostname(s)                                                                                                                                                                                                                  | Role                                                                                                                                       |
|----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| API      | `registry-1.docker.io`                                                                                                                                                                                                       | OCI Distribution v2 endpoint: `GET /v2/`, manifest GETs, initial blob GET that returns the redirect                                        |
| Auth     | `auth.docker.io`, `auth.docker.com`, `login.docker.com`, `cdn.auth0.com`                                                                                                                                                     | Bearer-token minting in response to a `401 + WWW-Authenticate: Bearer realm=...` challenge from the API host                              |
| Blob CDN | `production.cloudfront.docker.com` (AWS CloudFront) <br> `production.cloudflare.docker.com` (Cloudflare) <br> `docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com` (Cloudflare R2 — anonymous tier) | The actual blob bytes, served from a CDN edge close to the client. Which of the three you land on depends on plan tier and edge geography. |

### 6.1 The blob-fetch flow

A blob pull is **two HTTP round trips**, not one:

```
client ──► registry-1.docker.io
           GET /v2/library/nginx/blobs/sha256:abc123…
client ◄── 307 Temporary Redirect
           Location: https://production.cloudfront.docker.com/registry-v2/docker/registry/v2/blobs/sha256/ab/abc123…/data
                     ?Expires=…&Signature=…&X-Amz-Algorithm=…

client ──► production.cloudfront.docker.com
           GET /…/abc123…/data?Expires=…&Signature=…
client ◄── 200 OK, <blob bytes>
```

The `Location:` URL is a **short-lived signed URL** with query
parameters (`Expires`, `Signature`, `X-Amz-Algorithm`, …). The
signature ties the URL to one blob digest with an expiry on the order
of minutes.

### 6.2 Why this matters for caching

The signed URL is a transport detail — the **content identity is still
the sha256 digest in the original `/v2/…/blobs/sha256:<digest>` path**.
The question for each of our three caches is:

> When upstream returns the 307, **who follows the redirect**, and what
> **cache key** is the blob stored under?

There are three possible answers, with very different consequences:

| Behaviour                                                                                  | Where blob bytes flow                                                                                  | Cache hit on second pull?                                          |
|--------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------|
| **A.** Cache follows redirect server-side, stores by sha256                                | client → cache → upstream API (→ 307) → cache fetches from CDN → cache stores → client                 | ✅ second pull served entirely by cache, no upstream traffic       |
| **B.** Cache forwards redirect to client                                                   | client → cache → ← 307 ← cache; client → CDN → client                                                  | ❌ blob bytes never touched the cache; every pull hits upstream CDN |
| **C.** Cache configured directly against the CDN host, normalises signed query params away | client → cache → CDN → client                                                                          | ✅ but requires careful cache-key normalisation, signature drift is a footgun |

**Behaviour A** is what every OCI-aware proxy does (Distribution proxy
mode, Zot sync mode): they speak the OCI Distribution protocol, issue
`/v2/…` requests themselves, follow upstream redirects with their HTTP
client, and store the result keyed by digest. The CDN change is
transparent to them — this is the maximum-caching baseline.

**Behaviour B** is what a *naïve* generic HTTP reverse proxy (raw nginx
`proxy_pass`) does. Without extra config, nginx forwards the 307 to the
client unchanged. nginx then sees no blob bytes to cache; on every
subsequent pull the client just receives a fresh 307 and goes straight
to the CDN. **The cache hit rate on actual blob payload is zero.** This
is the anti-pattern this design must explicitly avoid.

**Behaviour C** is a deliberate nginx-only escape hatch for cases where
A is impossible (e.g. Hugging Face has no OCI surface): proxy directly
at the CDN with `proxy_cache_key` set to strip signed query parameters
so the same blob digest collapses to one cache entry regardless of
signature drift.

**Implication for HAProxy:** our HAProxy hashing is **unaffected** by
the CDN split. Every cache exposes the OCI Distribution surface on its
frontend port; the redirect happens *inside* the cache, never on the
HAProxy hop. `balance uri whole` continues to hash on
`/v2/…/blobs/sha256:<digest>` exactly as before, and the same digest
keeps landing on the same cache backend → same cache file.

### 6.3 Egress allowlist on the experiment subnet

For cache misses to succeed, the cache VMs must reach **all** of the
upstream host classes above. nftables masquerade on `cachebr0` lets the
VMs out unconditionally; we explicitly do **not** add DNS-based egress
control in v1 (a `dnsmasq` allowlist is future work).

If this is ever moved to a restricted network, the egress allowlist is
the union of:

- All three rows in the table above (Docker Hub).
- `gcr.io` itself and `storage.googleapis.com` (gcr.io's blob layer
  follows the same redirect-to-cloud-storage pattern).
- `huggingface.co` and `cdn-lfs.huggingface.co` (LFS-hosted model
  files redirect to a Cloudflare-backed LFS host).

This list is wired into `constants.nix` as `upstreams.<name>.egressHosts`
so the same data feeds a future allowlist module.

---

## 7. Constants Module (`nix/constants.nix`)

Centralising everything in one file is what makes the other repos easy to
read and modify; we follow the same pattern. Sketch (final file will be
expanded with helpers):

```nix
# nix/constants.nix
rec {
  # ── Hosts ──────────────────────────────────────────────────────────────
  clientNames = [ "client0" "client1" ];
  cacheNames  = [ "cache0"  "cache1"  ];
  allNames    = clientNames ++ cacheNames;
  getHostname = node: "cache-${node}";   # so VM hostnames are cache-client0, etc.

  # ── Network ────────────────────────────────────────────────────────────
  network = {
    bridge      = "cachebr0";
    gateway4    = "10.44.44.1";
    gateway6    = "fd44:44:44::1";
    subnet4     = "10.44.44.0/24";
    subnet6     = "fd44:44:44::/64";

    taps = {
      client0 = "cachetap0";
      client1 = "cachetap1";
      cache0  = "cachetap2";
      cache1  = "cachetap3";
    };

    ipv4 = {
      client0 = "10.44.44.10";
      client1 = "10.44.44.11";
      cache0  = "10.44.44.20";
      cache1  = "10.44.44.21";
    };

    ipv6 = {
      client0 = "fd44:44:44::10";
      client1 = "fd44:44:44::11";
      cache0  = "fd44:44:44::20";
      cache1  = "fd44:44:44::21";
    };

    macs = {
      client0 = "02:00:0a:2c:2c:10";
      client1 = "02:00:0a:2c:2c:11";
      cache0  = "02:00:0a:2c:2c:20";
      cache1  = "02:00:0a:2c:2c:21";
    };
  };

  # ── Upstream registries (Tier 1 = dedicated cache instances) ──────────
  # Used by:
  #   nix/modules/registry-proxy.nix, zot-proxy.nix, nginx-cache.nix → bind
  #   nix/modules/haproxy-client.nix                                 → ns= ACLs
  #   nix/modules/containerd-mirrors.nix                             → hosts.toml gen
  # See §11.1.3 for the rationale on this Tier-1 list.
  ociUpstreams = {
    docker  = { ns = "docker.io";        url = "https://registry-1.docker.io"; portIndex = 0; };
    gcr     = { ns = "gcr.io";           url = "https://gcr.io";               portIndex = 1; };
    ghcr    = { ns = "ghcr.io";          url = "https://ghcr.io";              portIndex = 2; };
    quay    = { ns = "quay.io";          url = "https://quay.io";              portIndex = 3; };
    k8s     = { ns = "registry.k8s.io";  url = "https://registry.k8s.io";      portIndex = 4; };
  };

  # Non-OCI upstreams (nginx-only; consumed by the HF vhost and any future
  # generic HTTP upstreams)
  httpUpstreams = {
    huggingface = { url = "https://huggingface.co"; port = 8090; };
  };

  # Generated programmatically by lib.mapAttrs in the constants module;
  # shown enumerated here for clarity. 5 cache impls × 5 Tier-1 upstreams
  # = 25 OCI backends + nginx wildcard + nginx HF special = 27 backends.
  ociCacheImpls = {
    distribution = { basePort = 5000; healthPath = "/v2/";    };
    zot          = { basePort = 5050; healthPath = "/v2/";    };
    varnish      = { basePort = 5100; healthPath = "/v2/";    };  # see §9.4
    ats          = { basePort = 5150; healthPath = "/v2/";    };  # see §9.5
    nginx        = { basePort = 8080; healthPath = "/health"; };  # Option-1 §9.3
  };

  cacheBackends =
    # 25 per-upstream OCI backends: 5 impls × 5 Tier-1 upstreams
    builtins.foldl' (acc: implName: acc //
      (lib.mapAttrs' (upName: u: lib.nameValuePair "${implName}-${upName}" {
         impl = implName; upstream = upName;
         port = ociCacheImpls.${implName}.basePort + u.portIndex;
         healthPath = ociCacheImpls.${implName}.healthPath;
       }) ociUpstreams)
    ) {} (lib.attrNames ociCacheImpls)
    // {
      # Wildcard catch-all (§11.1.5) — dynamic ns=-based dispatch.
      # v1 is nginx-only; Varnish/ATS wildcard equivalents are §16 future work.
      "nginx-default"     = { impl = "nginx"; upstream = "_default";    port = 8085; healthPath = "/health"; };
      # Hugging Face (HTTP, not OCI)
      "nginx-huggingface" = { impl = "nginx"; upstream = "huggingface"; port = 8090; healthPath = "/health"; };
    };

  # ── HAProxy on the clients ─────────────────────────────────────────────
  # One frontend port per cache type; switching = `cache-set-mirror` flips
  # which port the hosts.toml files target. See §11.1.6.
  haproxy = {
    statsPort = 8404;
    frontends = {
      distribution = { port = 8088; impl = "distribution"; };
      zot          = { port = 8089; impl = "zot";          };
      nginx        = { port = 8090; impl = "nginx";        };  # OCI nginx, not HF
      varnish      = { port = 8091; impl = "varnish";      };
      ats          = { port = 8092; impl = "ats";          };
    };
    # ns=<value> → backend pool name (one per Tier-1 upstream).
    # Generated by lib.mapAttrs over ociUpstreams.
    # Fallback for unmatched ns= → nginx-default wildcard backend.
    defaultBackend = "nginx-default";
  };

  # ── VM sizing ──────────────────────────────────────────────────────────
  vmResources = {
    client = { vcpus = 2; memoryMB = 2048; dataDiskMB = 10240; };  # client also runs dockerd cache
    cache  = { vcpus = 4; memoryMB = 4096; dataDiskMB = 40960; };  # bigger for cache content
  };

  # ── Cache storage layout (inside cache VMs) ────────────────────────────
  cacheStore = {
    root           = "/var/lib/cache";
    distribution   = "/var/lib/cache/distribution";  # one subdir per upstream
    zot            = "/var/lib/cache/zot";
    nginxKeyZone   = "cache_keys:50m";
    nginxMaxSizeGB = 20;
    nginxInactive  = "30d";
  };
}
```

Every other module imports this and reaches for `constants.network.ipv4.cache0`,
`constants.cacheBackends."zot-docker".port`, etc. There is **no hard-coded
IP or port anywhere else** in the tree.

---

## 8. MicroVM Definitions

### 8.1 Common shape

Both generators follow the
[`nix/microvm.nix`](../../ceph-on-k8s/nix/microvm.nix) pattern from
`ceph-on-k8s`. Each is a parametric function:

```nix
# pseudocode for nix/microvm-client.nix
{ pkgs, lib, microvm, nixpkgs, constants, dockerClientModule, haproxyClientModule, sshPubKey, ... }:
{ nodeName }:
let
  hostname = constants.getHostname nodeName;   # → "cache-client0"
  ip4      = constants.network.ipv4.${nodeName};
  ip6      = constants.network.ipv6.${nodeName};
  mac      = constants.network.macs.${nodeName};
  tap      = constants.network.taps.${nodeName};
  res      = constants.vmResources.client;
in
nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    microvm.nixosModules.microvm
    dockerClientModule
    haproxyClientModule
    ({ config, pkgs, ... }: {
      networking.hostName = hostname;
      microvm = {
        hypervisor = "qemu";
        mem    = res.memoryMB;
        vcpu   = res.vcpus;
        volumes = [{
          image      = "${hostname}-data.img";
          mountPoint = "/var/lib";
          size       = res.dataDiskMB;
        }];
        interfaces = [{
          type = "tap";
          id   = tap;
          inherit mac;
        }];
      };
      systemd.network = {
        enable = true;
        networks."10-tap" = {
          matchConfig.Name = "enp*";
          networkConfig = {
            Address = [ "${ip4}/24" "${ip6}/64" ];
            Gateway = constants.network.gateway4;
            DHCP = "no";
            IPv6AcceptRA = false;
          };
        };
      };
      users.users.root.openssh.authorizedKeys.keys = [ sshPubKey ];
      services.openssh.enable = true;
    })
  ];
}
```

`microvm-cache.nix` is structurally identical but imports
`registryProxyModule`, `zotProxyModule`, and `nginxCacheModule` instead of
the client modules, and uses `vmResources.cache`.

### 8.2 What each VM runs

| VM             | NixOS modules                                                       |
|----------------|---------------------------------------------------------------------|
| `cache-client0`| `dockerd` (containerd-snapshotter), `haproxy` (5 frontends `:8088`–`:8092` + 27 backends), `regctl`/`crane` for ad-hoc pulls |
| `cache-client1`| same as `client0`                                                   |
| `cache-cache0` | 25 OCI cache processes (`distribution` ×5, `zot` ×5, `varnish` ×5, `ats` ×5, `nginx` ×5 — one per Tier-1 upstream) + `nginx` wildcard `:8085` + `nginx` HF `:8090` |
| `cache-cache1` | same as `cache0` (identical config — they are intentionally interchangeable so consistent hashing makes sense) |

The two clients are also identical to each other. A second client exists
so we can demonstrate cache locality (same image, two clients → second
pull should hit the warm cache regardless of which client requested first).

### 8.3 Data disks

Each VM gets a single `<hostname>-data.img` mounted at `/var/lib`:

- Client VMs: `/var/lib/docker` (image layers), `/var/lib/haproxy`.
- Cache VMs: `/var/lib/cache/{distribution,zot,nginx}`.

We do **not** need the second raw disk that `ceph-on-k8s` uses for OSDs.
A flake app `cache-vm-wipe` deletes the `.img` files for a clean run, the
same way `k8s-vm-wipe` does in the sister repos.

---

## 9. Cache Services on the Cache MicroVMs

### 9.1 Docker Distribution registry (proxy mode)

[`distribution/distribution`](https://github.com/distribution/distribution)
is the reference OCI registry; in *proxy mode* it acts as a pull-through
cache for a single upstream. Two instances run per cache VM, one per
upstream:

```yaml
# rendered config for the docker.io instance (port 5000) — generated from nix
version: 0.1
log:
  level: info
storage:
  filesystem:
    rootdirectory: /var/lib/cache/distribution/docker
  cache:
    blobdescriptor: inmemory
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
proxy:
  remoteurl: https://registry-1.docker.io
# username/password are anonymous for public images
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
```

The `gcr.io` instance is the same config with `rootdirectory:
.../distribution/gcr`, `addr: :5001`, and `remoteurl: https://gcr.io`.

`/v2/` returns 200 OK for both anonymous and authenticated configurations
when the upstream is reachable, which is what we use for HAProxy health
checks.

Notes:

- Distribution-as-proxy supports **only one upstream per process**. This
  is why we need two instances per upstream.
- Storage is filesystem-backed; nothing fancy. Garbage collection has to
  be triggered manually (`registry garbage-collect` CLI). For experiments
  we just wipe the data disk.

**Behaviour against the Docker Hub CDN (post 2026-05-20).**
Distribution-in-proxy-mode implements **behaviour A** from §6.2.
When upstream `registry-1.docker.io` answers a blob GET with a 307 to
`production.cloudfront.docker.com`, Distribution's internal HTTP client
follows the redirect, downloads the blob bytes from the CDN, stores
them under `rootdirectory` keyed by the original `sha256:<digest>`, and
returns them to our HAProxy / docker client. The signed query
parameters never leak past Distribution, and the next pull of the same
digest never leaves the cache subnet. **This is the maximum-caching
baseline that the other two caches are measured against.**

### 9.2 Zot

[Zot](https://github.com/project-zot/zot) is an OCI-native registry that
supports multi-upstream sync (`extensions.sync.registries`). Like
Distribution, we still run two instances (one per upstream) for symmetry
and per-upstream isolation:

```json
{
  "storage": { "rootDirectory": "/var/lib/cache/zot/docker", "gc": true },
  "http":    { "address": "0.0.0.0", "port": "5050" },
  "log":     { "level": "info" },
  "extensions": {
    "sync": {
      "enable": true,
      "registries": [{
        "urls": ["https://registry-1.docker.io"],
        "onDemand": true,
        "tlsVerify": true,
        "content": [{ "prefix": "**" }]
      }]
    }
  }
}
```

Zot's `onDemand: true` mode is the equivalent of Distribution's proxy
mode: on a `/v2/<name>/manifests/<ref>` request, Zot fetches from upstream
if absent, stores locally, then serves. Health: `GET /v2/` returns 200.

**Behaviour against the Docker Hub CDN (post 2026-05-20).**
Zot's sync extension uses the `containers-image` Go library, which
transparently follows 3xx redirects to CloudFront / Cloudflare / R2,
pins the blob locally under `rootDirectory` keyed by digest, and serves
subsequent pulls from disk. Same caching profile as Distribution — no
upstream traffic for a warm digest. In practice Zot's logs are more
verbose about which CDN edge it fetched from (look for
`production.cloudfront` or `cloudflarestorage` in `/var/log/zot/zot.log`),
which is useful when debugging cache-miss latency variance.

### 9.3 Nginx as an HTTP proxy cache

For Hugging Face, where we want to cache **arbitrary HTTP downloads**
rather than OCI blobs, nginx with `proxy_cache` is the standard tool. We
also run nginx in front of `docker.io` and `gcr.io` so we have a like-for-like
comparison (same workload, different cache implementation).

Per-upstream `server` block (sketch for the `docker.io` instance, port 8080):

```nginx
proxy_cache_path /var/lib/cache/nginx/docker
                 levels=1:2
                 keys_zone=cache_docker:50m
                 max_size=20g
                 inactive=30d
                 use_temp_path=off;

server {
    listen 8080;
    server_name _;

    location = /health { return 200 "ok\n"; }

    location / {
        proxy_pass https://registry-1.docker.io;
        proxy_ssl_server_name on;

        proxy_cache cache_docker;
        proxy_cache_key "$scheme$proxy_host$request_uri";
        proxy_cache_valid 200 206 30d;
        proxy_cache_valid any 1m;
        proxy_cache_use_stale error timeout updating http_5xx;
        proxy_cache_lock on;

        # Forward auth challenges so the docker client can re-issue with
        # a bearer token from auth.docker.io (we do NOT proxy /token).
        proxy_pass_header WWW-Authenticate;

        add_header X-Cache-Status $upstream_cache_status;
    }
}
```

Caveats nginx specifically gives us:

- **Auth bounce works for anonymous public images**: nginx forwards the
  `401 + WWW-Authenticate` to the client, dockerd fetches a bearer from
  `auth.docker.io` directly, then re-requests with `Authorization:`. We
  use `proxy_cache_key` excluding the bearer so cache entries are shared
  across clients.
- **It does not understand OCI semantics**: manifest mutability, blob
  deduplication across repos, and orphan-GC are all your problem. For our
  experiments that's fine.
- For Hugging Face (`:8082`) the same template applies with
  `proxy_pass https://huggingface.co;` and a different cache zone /
  directory.

**Behaviour against the Docker Hub CDN (post 2026-05-20) — this is the
hard one.** Naïvely configured nginx falls into **behaviour B** from
§6.2: `proxy_pass https://registry-1.docker.io;` forwards the 307 to
dockerd unchanged, dockerd opens its own connection straight to
CloudFront, and **nginx never sees the blob bytes — cache hit rate on
payload is zero**. This is exactly the anti-pattern this design must
avoid.

There are two ways to make nginx serve as a real cache for
CDN-redirected blob traffic, and we will implement both in
`nix/modules/nginx-cache.nix` to compare them:

**Option 1 — Make nginx follow the redirect itself, key by digest
(recommended).**
Use `proxy_intercept_errors` + an internal redirect to a `@cdn`
location that fetches the body from the CDN host. Sketch:

```nginx
proxy_cache_path /var/lib/cache/nginx/docker
                 levels=1:2 keys_zone=cache_docker:50m
                 max_size=200g inactive=30d use_temp_path=off;

server {
    listen 8080;
    resolver 1.1.1.1 ipv6=off;   # for dynamic Location: host lookups

    location / {
        proxy_pass https://registry-1.docker.io;
        proxy_intercept_errors on;
        recursive_error_pages on;
        # Trap the 307 from upstream and dispatch internally
        error_page 301 302 303 307 308 = @follow_cdn;
        proxy_cache cache_docker;
        # Cache manifests + small responses keyed on the request URI
        proxy_cache_key "$request_method:$uri";
        proxy_cache_valid 200 30d;
    }

    location @follow_cdn {
        # Pull the Location: header out of the upstream 307
        set $cdn_url $upstream_http_location;
        proxy_pass $cdn_url;
        proxy_cache cache_docker;
        # KEY POINT: cache key is the ORIGINAL request URI (which still
        # contains /v2/<name>/blobs/sha256:<digest>), with the signed
        # CDN query params deliberately excluded. Same digest → same
        # cache entry, regardless of signature drift.
        proxy_cache_key "blob:$uri";
        proxy_cache_valid 200 30d;
        proxy_cache_lock on;
        # CDN edge may differ between pulls; do not 502 on hostname change
        proxy_next_upstream error timeout http_502 http_504;
    }
}
```

The load-bearing trick is `proxy_cache_key "blob:$uri"` in the
`@follow_cdn` block: `$uri` is still `/v2/<name>/blobs/sha256:<digest>`
from the *original* request because nginx preserves the request URI
across the internal redirect. The signed query string lives in `$args`
on the upstream side but is excluded from our cache key. **Same digest
→ same cache entry, regardless of which CDN edge served it or what the
signature was.**

**Option 2 — Point nginx directly at the CDN with a custom path
prefix.** Expose `/cdn/<digest>` on nginx and rewrite to the CDN host.
Sidesteps the redirect dance, but requires the client to know that
blobs come from `/cdn/<digest>` instead of `/v2/<name>/blobs/<digest>`.
`dockerd` will not do this. Works only for `curl`-driven Hugging Face
downloads where we control the URL the CLI uses. We use **Option 1 for
the dockerhub / gcr.io nginx instances** and **Option 2 only for the
Hugging Face instance**.

**Cache-key normalisation rule.** For every nginx instance the cache
key MUST be:

```nginx
proxy_cache_key "$request_method:$uri";
```

with `$args` explicitly **omitted**. This is the single knob that makes
the signed-URL CDN model behave under maximum-caching assumptions.
Including `$args` would generate a fresh cache key on every pull
because the signature differs each time — exactly the anti-caching
footgun.

**Why we still bother with nginx at all.** Distribution and Zot are
*better* for `docker.io` / `gcr.io` because they understand OCI. The
point of also testing nginx for OCI is:

1. **Hugging Face is HTTP, not OCI** — we need a generic HTTP cache,
   and nginx is the canonical one.
2. We want a head-to-head between a *generic* and *OCI-aware* cache
   when both are tuned for maximum caching. Option 1 above is the fair
   comparison; the naïve config is the cautionary tale.

### 9.4 Varnish

[Varnish](https://varnish-cache.org/) is a purpose-built HTTP cache
whose configuration language (VCL) is more expressive than nginx's
directive-based config for the kind of "strip the signed query params,
key on this exact thing" surgery that CDN-fronted blob caching needs.
The most useful feature for us is `vcl_hash` — we control exactly
what goes into the cache lookup key, so signed-URL drift simply can
**not** cause a miss.

Per-Tier-1-upstream instance (sketch for the `docker.io` instance
listening on `:5100`):

```vcl
vcl 4.1;

import std;

backend upstream {
    .host = "registry-1.docker.io";
    .port = "443";
    .ssl = 1;
    .probe = {
        .url = "/v2/";
        .interval = 5s;
        .timeout = 2s;
        .window = 3;
        .threshold = 2;
        .expected_response = 401;  # OCI registries answer 401 unauth on /v2/
    };
}

sub vcl_recv {
    # Strip ns= from cache key derivation but keep it for upstream routing.
    # The digest in $url already uniquely identifies the blob.
    if (req.url ~ "\?ns=") {
        set req.http.X-Original-NS = regsub(req.url, "^.*\?ns=([^&]+).*$", "\1");
        set req.url = regsub(req.url, "\?ns=[^&]+&?", "?");
        set req.url = regsub(req.url, "\?$", "");
    }
    return (hash);
}

sub vcl_hash {
    # Hash on URL only. Signed query params on upstream redirects are
    # not part of the request that reaches us, so this is sufficient.
    hash_data(req.url);
    return (lookup);
}

sub vcl_backend_response {
    # CDN responses have short TTLs; override for blob digests (immutable)
    if (bereq.url ~ "/blobs/sha256:") {
        set beresp.ttl = 30d;
        set beresp.grace = 7d;
    } else {
        set beresp.ttl = 5m;
    }
}

sub vcl_deliver {
    set resp.http.X-Cache = obj.hits > 0 ? "HIT" : "MISS";
    set resp.http.X-Cache-Hits = obj.hits;
}
```

Notes:

- **TLS.** Varnish is HTTP-only on its listen side; on the upstream
  side it speaks both HTTP and HTTPS. For our case the listener is
  HTTP (`:5100` on the experiment subnet), so no `hitch` sidecar is
  needed.
- **CDN redirects.** Varnish follows them automatically when
  `backend.host` answers with `301/302/307/308`. Same caching
  semantics as Distribution / Zot — blob bytes stored by digest.
- **Storage.** `malloc,4G` for memory-only (fastest) or
  `file,/var/lib/cache/varnish/docker,40G` for disk-backed
  persistence across restarts. We use the file backend so cache
  survives `cache-vm-restart`.
- **Cache hit logging.** `X-Cache: HIT|MISS` headers feed straight
  into the per-pull metrics future-work (§16).

### 9.5 Apache Traffic Server

[Apache Traffic Server](https://trafficserver.apache.org/) (ATS) is a
caching HTTP proxy designed for CDN-scale workloads — it actually
*runs* large CDNs (Yahoo, Apple, Comcast historically). It has
first-class support for **parent-child cache hierarchies** that map
naturally to our two-cache-VM topology: `cache1` can be configured to
treat `cache0` as its parent, so a miss on `cache1` consults `cache0`
before going to the real upstream. That's a stronger consistency
property than HAProxy's consistent hashing alone, which is purely
client-side.

Per-Tier-1-upstream instance (sketch for the `docker.io` instance
listening on `:5150`):

```
# records.config — global tuning
CONFIG proxy.config.http.server_ports STRING 5150
CONFIG proxy.config.cache.ram_cache.size INT 268435456              # 256MB RAM cache
CONFIG proxy.config.http.cache.required_headers INT 0               # cache responses without Cache-Control
CONFIG proxy.config.http.cache.heuristic_min_lifetime INT 2592000   # 30d
CONFIG proxy.config.http.cache.heuristic_max_lifetime INT 7776000   # 90d
CONFIG proxy.config.http.parent_proxy.retry_time INT 30
CONFIG proxy.config.http.parent_proxy.fail_threshold INT 3
```

```
# remap.config — per-upstream rewrite
map http://_/v2/ https://registry-1.docker.io/v2/  \
    @plugin=cachekey.so @pparam=--include-params=ns
```

```
# parent.config — cache0 ↔ cache1 hierarchy (on cache1, inverted on cache0)
dest_domain=registry-1.docker.io parent="10.44.44.20:5150" round_robin=consistent_hash go_direct=true
```

Notes:

- **Why parent-child matters.** With HAProxy consistent hashing, a
  blob is owned by one cache. If that cache is wiped (`cache-vm-wipe
  --node=cache0`) the next pull is a miss. With ATS parent-child,
  `cache1` would consult its sibling `cache0` first before going
  upstream, so the wipe is cheaper. We can measure this advantage.
- **Cache-key plugin (`cachekey.so`).** Bundled with ATS. We use it
  to **include only the meaningful query params** (`ns=`) in the
  cache key, mirroring the Varnish / nginx Option-1 normalisation.
- **`go_direct=true`** means "if all parents fail, fall back to the
  real upstream directly" — same graceful degradation as containerd's
  hosts.toml fallthrough.
- **TLS termination** is native to ATS (`ssl_multicert.config`); no
  sidecar required.

### 9.6 Considered alternatives we did not pick

For completeness, here's why we didn't pick other plausible
candidates. Most can be added later if a specific characteristic
turns out to matter:

| Tool | Why we didn't include it in v1 |
|------|--------------------------------|
| **Squid** | Excellent at HTTPS forward-proxying with SSL bumping (and we'll use it that way in §12 future work). Not as strong as Varnish/ATS for content caching with custom keying — its cache-key control is config-flag-driven, not programmable. |
| **Caddy** | Caching is plugin-only (`souin`), less mature than Varnish/ATS. Cleaner config than nginx, but doesn't bring a unique capability to the comparison. |
| **HAProxy as cache** | HAProxy is a load balancer; it has no native HTTP cache. It would just be "another way to spell nginx" with worse caching semantics. |
| **Cloudflare Pingora** | Modern Rust, fast, but no off-the-shelf "deploy and configure" surface — you write a Pingora-based proxy as Rust code. Out of scope for an experiment harness. |
| **Polipo / Privoxy / Tinyproxy** | Either unmaintained or scoped to privacy/filtering rather than caching. |

The five we picked (Distribution, Zot, Varnish, ATS, nginx) give us:

- Two **OCI-protocol-native** caches (Distribution, Zot) — the
  baseline for "the right tool for the job".
- Three **generic HTTP caches** (Varnish, ATS, nginx) tuned to handle
  OCI semantics — answers the question "if you had to use a generic
  cache, which one is least bad?".
- All five exercise the same HAProxy + consistent-hashing front-end
  and the same containerd `hosts.toml` client config, so the only
  variable across runs is the cache implementation itself.

---

## 10. Client-side HAProxy: health checks and consistent hashing

The HAProxy on each client implements the routing pattern lifted from
the `moby-image-pull-analysis.md` recommendations: **`balance uri whole`
+ `hash-type consistent sdbm avalanche`**, with `/v2/` health checks that
accept `200,401` as healthy.

**Routing dimension depends on which client-side mode is active (§11):**

- **Mode 1 (hosts.toml)** routes on the `ns=` query parameter that
  containerd appends — the original registry's hostname. ACL uses
  `urlp(ns)`.
- **Mode 2 (MITM)** routes on `ssl_fc_sni` — see §12.6.
- **Mode 3 (legacy registry-mirrors)** routes on `hdr(host)` — used
  only for the comparison-baseline benchmark.

All three modes share the same backend pools (one per
`(cache_type × Tier-1 upstream)` pair, plus the nginx wildcard) so
swapping mode is a pure frontend concern.

One HAProxy frontend port per cache type (`8088` Distribution,
`8089` Zot, `8090` nginx). Sketch for the Distribution frontend:

```haproxy
global
    log /dev/log local0
    maxconn 4096

defaults
    mode http
    option httplog
    option http-keep-alive
    timeout client  30m
    timeout server  30m
    timeout connect 5s

# ──────────────────────────── stats ────────────────────────────────────
frontend stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 5s

# ─────────────────────────── Mode 1 frontend (Distribution) ────────────
frontend dist_mirror
    bind *:8088

    # Mode 1 (hosts.toml): route on the ns= query parameter containerd
    # appends. See §11.1.2; ns=<registry> tells us the original upstream
    # despite Host: being our own mirror.
    acl ns_docker urlp(ns) -i docker.io
    acl ns_gcr    urlp(ns) -i gcr.io
    acl ns_ghcr   urlp(ns) -i ghcr.io
    acl ns_quay   urlp(ns) -i quay.io
    acl ns_k8s    urlp(ns) -i registry.k8s.io

    use_backend be_dist_docker if ns_docker
    use_backend be_dist_gcr    if ns_gcr
    use_backend be_dist_ghcr   if ns_ghcr
    use_backend be_dist_quay   if ns_quay
    use_backend be_dist_k8s    if ns_k8s

    # No ns= match → bounce to the nginx wildcard catch-all on :8085.
    # This handles the case where some tool other than containerd (or
    # an older containerd) forgot to include ns=, so we don't black-hole.
    default_backend be_ngx_default

# Mirrors for Zot (:8089) and nginx (:8090) follow the same shape with
# their respective be_zot_* / be_ngx_* backend pools.

# ──────────────────────────── backends ─────────────────────────────────
# One backend per (cache_type, upstream). All have the SAME shape; only
# port differs. Generated from constants.cacheBackends.

backend be_dist_docker
    balance uri whole
    hash-type consistent sdbm avalanche
    option httpchk GET /v2/
    http-check expect status 200,401
    option redispatch
    retries 2
    server cache0 10.44.44.20:5000 check inter 2s fall 3 rise 2
    server cache1 10.44.44.21:5000 check inter 2s fall 3 rise 2

backend be_ngx_default
    # The nginx wildcard catch-all from §11.1.5 — handles any registry
    # not in Tier 1, dispatching dynamically on ns= internally.
    balance uri whole
    hash-type consistent sdbm avalanche
    option httpchk GET /health
    server cache0 10.44.44.20:8085 check inter 2s fall 3 rise 2
    server cache1 10.44.44.21:8085 check inter 2s fall 3 rise 2

# … be_dist_gcr/ghcr/quay/k8s (5001-5004), be_zot_* (5050-5054),
#   be_ngx_* (8080-8084) follow the same shape with `expect status 200`
#   for the nginx OCI backends. Generated by lib.mapAttrs in
#   nix/modules/haproxy-client.nix from constants.cacheBackends.
```

Why these knobs (citing the moby analysis):

- **`balance uri whole`** — Docker pulls use URLs like
  `/v2/<name>/blobs/sha256:<digest>`. Hashing the URI sends the same
  digest to the same cache, so cache hit rate scales with cache count
  instead of degrading to `1/N`.
- **`hash-type consistent sdbm avalanche`** — `sdbm` is HAProxy's default
  hash function for consistent mode; `avalanche` reduces clustering when
  every key shares a common prefix like `/v2/`.
- **`http-check expect status 200,401`** — Distribution/Zot return `401`
  on `/v2/` when an auth realm is configured but unauthenticated; that
  still means "the registry is up". Accepting only `200` would mark
  healthy registries down. For the nginx backends we expose an
  unauthenticated `/health` and check for `200`.
- **`option redispatch` + low `inter`** — fast failover from a dead
  cache; with two backends, a stalled `cache0` redirects to `cache1` on
  the next attempt.

`nix/modules/haproxy-client.nix` generates this config from
`constants.cacheBackends` + `constants.haproxy.routes` with `lib.mapAttrs`
so adding a new cache type is "add an entry in `constants.nix`, rebuild".

### 10.1 Considered alternatives we did not pick

HAProxy is the client-side L7 router/load-balancer of record for this
lab. We deliberately did not pick the alternatives below — the table
captures *why*, so a future contributor can revisit if any of the
"why not" assumptions stop holding.

| Tool | Native consistent hash | Native active health checks | Native HTTP cache | Why not for v1 |
|------|------------------------|-----------------------------|-------------------|----------------|
| **Varnish** | yes (`shard director`, Rendezvous/CARP) | yes (`probes`) | **yes** | The biggest temptation — Varnish adds a *second* tier of cache on each client, which would materially raise hit rate on hot blobs. But it conflates the LB and cache layers, which we explicitly want separate so that "cache implementation under test" is a single variable. We keep Varnish as a *cache-VM* backend (§9.4) where the comparison is fair. Future work in §16 to add a "Varnish-as-client-LB" mode for the two-tier measurement. |
| **Envoy** | yes (`ring_hash` / `maglev`) | yes | limited (HTTP cache filter is experimental) | Heavier resource footprint and steeper config than we need for two upstream cache VMs. Maglev hashing is theoretically nicer than HAProxy's sdbm-consistent under churn, but with only two backends the difference is negligible. |
| **Traefik** | partial (hash by source IP; URI hashing requires plugin) | yes | yes (plugin) | The URI-based consistent hashing story is the weakest of any candidate here, which is the exact thing we depend on. |
| **Nginx as LB** | yes (`hash $uri consistent;`) | mainline is passive-only; active health needs `nginx-plus` ($) or the `nginx_upstream_check_module` patch | yes (`proxy_cache`) | Active health checking is the dealbreaker: we want fast failover from a stalled cache, and HAProxy gives us `inter 2s fall 3 rise 2` out of the box. Patching nginx to get the same behaviour is operationally ugly. |
| **Apache Traffic Server (parent_proxy)** | yes (`parent_proxy consistent_hash`) | yes | yes | Same conflation concern as Varnish — would mix LB and cache. We keep ATS as a *cache-VM* backend (§9.5) for the same reason. |
| **Cloudflare Pingora** | yes | yes | yes | No off-the-shelf binary; you write a Pingora-based proxy in Rust. Out of scope for an experiment harness. |

The decision criteria, in priority order, were:

1. **URI-based consistent hashing** is non-negotiable (CDN-served
   blob caching only works if the same digest lands on the same
   backend).
2. **Active health checks with fast failover** are non-negotiable
   (a stalled cache must not block the next pull).
3. **No native caching** is *positively desirable* on this layer —
   we want the cache layer to be a single, swappable variable.
4. **Single static binary, declarative config** so the Nix module
   that generates it is trivial.

HAProxy is the only candidate that's a clean win on all four.

---

## 11. Client-side: per-registry transparent mirroring

This is the section that defines the **user-facing constraint** of the
lab: external users hand us a Dockerfile that uses *unmodified* image
references — `FROM nginx`, `FROM gcr.io/google_containers/pause:3.9`,
`FROM ghcr.io/someorg/someimage:v1`, even
`FROM registry.k8s.io/etcd:3.6.0` — and we have to intercept and cache
those pulls without ever touching the Dockerfile.

The cache topology (HAProxy + Distribution + Zot + nginx on the cache
VMs) is **identical across all three modes** below. Only the mechanism
that steers dockerd / containerd toward HAProxy changes:

| Mode | Mechanism                                                              | Upstreams covered                  | Touches Dockerfile? | Trust impact |
|------|------------------------------------------------------------------------|------------------------------------|---------------------|--------------|
| **1** (primary) | `/etc/containerd/certs.d/<host>/hosts.toml` per-registry mirrors | **every registry** (Tier 1 + `_default` wildcard) | no                  | none — plain mirror, no MITM |
| **2** (alt — see §12) | DNS-poison + HAProxy SNI termination with our CA           | every registry (bounded cert list) | no                  | high — we own the trust |
| **3** (legacy / comparison baseline) | `daemon.json registry-mirrors` + `insecure-registries` | **docker.io only**                 | no                  | low |

**Mode 1 is the recommended primary** because it is the only one that
both (a) requires zero Dockerfile changes from the user and (b) covers
arbitrary registry hostnames without breaking TLS trust. Mode 2 is the
escape hatch when Mode 1 is unavailable (e.g. dockerd is configured
with the legacy graphdriver image store, or userns remapping). Mode 3
is kept around purely so we can A/B it against Modes 1 and 2 in
benchmarks.

### 11.1 Mode 1 (primary): containerd `hosts.toml` per-registry mirrors

#### 11.1.1 Why this works today

Modern `dockerd` defaults to the **containerd image store** rather
than its legacy graphdriver-based puller. See
[`daemon/image_store_choice.go:105,117-118`](../../moby/daemon/image_store_choice.go) — the default is `imageStoreChoiceContainerd`,
and explicit `"containerd-snapshotter": true` in `daemon.json` now logs
a warning that *"`containerd-snapshotter` is now the default and no
longer needed to be set"*. The only Linux carve-out is userns
remapping ([`daemon/command/daemon_linux.go:30-40`](../../moby/daemon/command/daemon_linux.go)).

Once the image store is containerd, **every image pull goes through
containerd's resolver**, and that resolver reads per-registry mirror
configuration from `/etc/containerd/certs.d/<registry>/hosts.toml`
(walker: [`containerd/core/remotes/docker/config/config_unix.go:25-37`](../../containerd/core/remotes/docker/config/config_unix.go),
loader: [`containerd/core/remotes/docker/config/hosts.go:293-304`](../../containerd/core/remotes/docker/config/hosts.go)).

This is the *only* mechanism in the stack that:

1. Is per-registry (`docker.io`, `gcr.io`, `ghcr.io`, … all configured
   independently), and
2. Supports a true catch-all (`_default` directory: same file
   `config_unix.go:32-33`), and
3. Has built-in graceful fallback to the real upstream on cache
   failure (mirror walk:
   [`containerd/core/remotes/docker/resolver.go:287-349`](../../containerd/core/remotes/docker/resolver.go) — non-final mirrors fall
   through silently on error; only the last host gets retries).

#### 11.1.2 The `ns=` query parameter — the routing key HAProxy needs

When containerd pulls `gcr.io/foo/bar:latest` through a mirror at
`http://10.44.44.10:8088`, the actual HTTP request it sends is:

```
GET http://10.44.44.10:8088/v2/foo/bar/manifests/latest?ns=gcr.io
Host: 10.44.44.10:8088
```

The `Host:` header is the mirror's host (not the original registry's),
**but the original registry is encoded in the `ns=` query parameter**
(`resolver.go:591-598`, gated by `registry.go:85-91` so it's only added
when mirror host ≠ upstream host).

This is what makes HAProxy able to route to the correct per-upstream
cache backend in mirror mode: ACL on `urlp(ns)`. Without `ns=` we'd
have no way to tell a `docker.io` pull from a `gcr.io` pull once both
arrive at `localhost:8088`. See §10 for the HAProxy ACL set.

#### 11.1.3 Tier 1: dedicated cache instances per upstream

We run dedicated Distribution / Zot / nginx instances for the **five
most common public OCI registries** we expect to see in real
Dockerfiles:

| `ns` value          | upstream URL                | rationale                                       |
|---------------------|-----------------------------|-------------------------------------------------|
| `docker.io`         | `https://registry-1.docker.io` | Default; the vast majority of `FROM x` lines    |
| `gcr.io`            | `https://gcr.io`            | Legacy Google images; still very common         |
| `ghcr.io`           | `https://ghcr.io`           | GitHub-hosted projects; rapidly growing share   |
| `quay.io`           | `https://quay.io`           | Red Hat / CoreOS ecosystem; many CNCF images    |
| `registry.k8s.io`   | `https://registry.k8s.io`   | All Kubernetes control-plane images since 2023  |

Each cache VM runs one process per (cache type × Tier-1 upstream) =
**15 cache processes per cache VM**: 5 Distribution proxies, 5 Zot
instances, 5 nginx vhosts. Port allocation (final layout in
`constants.nix`):

| port band      | cache type            |
|----------------|-----------------------|
| `5000`–`5004`  | Distribution proxies (one per Tier-1 upstream, indexed by upstream) |
| `5050`–`5054`  | Zot instances         |
| `8080`–`8084`  | nginx vhosts (Option 1 redirect-following config from §9.3) |
| `8085`         | nginx wildcard catch-all (see §11.1.5) |
| `8090`         | nginx Hugging Face vhost (HTTP, not OCI) |

The `constants.nix.upstreams` table grows to enumerate the five Tier-1
upstreams, and `cacheBackends` is generated programmatically by
`lib.mapAttrs` from it. Adding a sixth upstream is "add one entry in
`constants.nix` and `nix run .#cache-render`".

#### 11.1.4 Per-registry `hosts.toml` files

Generated by Nix into each client VM's `/etc/containerd/certs.d/`.
The file for `docker.io` (other Tier 1 upstreams are identical with
the upstream URL and HAProxy port swapped):

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"

[host."http://127.0.0.1:8088"]
  capabilities = ["pull", "resolve"]
  # No TLS knobs needed; explicit http:// scheme is enough.
  # Verified: hosts.go:430-449 keeps the scheme as-is when explicit.
```

Notes:

- `server = "https://registry-1.docker.io"` is the **final fallback**
  containerd uses if every mirror entry above it fails. Containerd's
  silent-fallthrough semantics (`resolver.go:329 continue`) means a
  dead cache never breaks a pull — it just degrades to direct upstream.
- `capabilities = ["pull", "resolve"]` matches what mirrors are good
  at; `push` and `referrers` correctly stay on the upstream
  (`hosts.go:453-470`, `registry.go:28-44`).
- The `http://` scheme **must** be explicit — without it,
  containerd tries HTTPS first and falls back to HTTP only on certain
  errors, with an unhelpful warning (`hosts.go:221-227`).
- Containerd handles the `docker.io` → `registry-1.docker.io` rewrite
  internally (`hosts.go:102-104`), so we use the friendly directory
  name `docker.io/`.

#### 11.1.5 The `_default` wildcard with a dynamic nginx catch-all

Tier 1 covers the common cases. For anything else
(`mcr.microsoft.com`, `public.ecr.aws`, `nvcr.io`,
`registry.gitlab.com`, `registry.redhat.io`, …) we use containerd's
`_default` wildcard pointed at a **dynamic nginx instance** on
`:8085`. The trick: nginx reads the `ns=` query parameter and uses it
as the `proxy_pass` upstream, so one nginx vhost serves an unbounded
number of upstream registries:

```toml
# /etc/containerd/certs.d/_default/hosts.toml
server = ""   # let the implicit upstream (the original registry) be the fallback

[host."http://127.0.0.1:8085"]
  capabilities = ["pull", "resolve"]
```

```nginx
# nix/modules/nginx-cache.nix — wildcard catch-all on :8085
proxy_cache_path /var/lib/cache/nginx/default
                 levels=1:2 keys_zone=cache_default:100m
                 max_size=200g inactive=30d use_temp_path=off;

server {
    listen 8085;
    resolver 1.1.1.1 ipv6=off valid=300s;

    location / {
        # ns= is supplied by containerd (resolver.go:591-598). Without
        # it we have no upstream to dispatch to → let the pull fall
        # through to direct upstream.
        set $ns $arg_ns;
        if ($ns = "") { return 404; }

        proxy_pass https://$ns;
        proxy_ssl_server_name on;

        proxy_cache cache_default;
        # Key by (upstream, request URI). Strips ns= and any other
        # query args — the digest is in $uri.
        proxy_cache_key "$ns:$request_method:$uri";
        proxy_cache_valid 200 30d;
        proxy_cache_lock on;

        # Same Option-1 redirect-following pattern as §9.3 for CDN 307s
        proxy_intercept_errors on;
        recursive_error_pages on;
        error_page 301 302 303 307 308 = @follow_cdn;
    }

    location @follow_cdn {
        set $cdn_url $upstream_http_location;
        proxy_pass $cdn_url;
        proxy_cache cache_default;
        # Cache key is the ORIGINAL (ns, uri) pair — signed CDN query
        # params on the upstream URL are excluded
        proxy_cache_key "$arg_ns:blob:$uri";
        proxy_cache_valid 200 30d;
        proxy_cache_lock on;
    }
}
```

This single vhost catches any registry containerd encounters. A pull
of `mcr.microsoft.com/dotnet/runtime:9.0` becomes
`http://127.0.0.1:8085/v2/dotnet/runtime/manifests/9.0?ns=mcr.microsoft.com`
→ nginx → `https://mcr.microsoft.com/v2/dotnet/runtime/manifests/9.0`,
cached under key `mcr.microsoft.com:GET:/v2/dotnet/runtime/manifests/9.0`.

If a wildcard pull *fails* at our cache (returns 404 or 5xx),
containerd's silent fallthrough sends the pull direct to the real
upstream and the user's `FROM` line still works. **The user never
sees a difference; the cache is best-effort.**

#### 11.1.6 Switching the cache type under test

Each cache type lives on a different HAProxy frontend port on each
client:

| HAProxy port | cache type   | backend pools (one per Tier-1 upstream + wildcard) |
|--------------|--------------|----------------------------------------------------|
| `8088`       | Distribution | `be_dist_docker`, `be_dist_gcr`, `be_dist_ghcr`, `be_dist_quay`, `be_dist_k8s`, `be_dist_default` (which redirects unknown `ns=` to the nginx wildcard) |
| `8089`       | Zot          | `be_zot_*` — same structure                        |
| `8090`       | nginx (OCI)  | `be_ngx_*` — same structure                        |

Switching = a `cache-set-mirror` flake app that rewrites every
per-Tier-1 `hosts.toml` to point at the new port, then `systemctl
reload containerd`:

```bash
nix run .#cache-set-mirror -- --client=client0 --cache=zot
# → rewrites /etc/containerd/certs.d/{docker.io,gcr.io,ghcr.io,quay.io,registry.k8s.io}/hosts.toml
#   to point at http://127.0.0.1:8089, then systemctl reload containerd
```

containerd's hot-reload of `hosts.toml` is in-process (no restart);
in-flight pulls finish on the old cache, new pulls hit the new cache.
The `_default/hosts.toml` always points at the nginx wildcard on
`:8085`, so unknown registries are always cacheable regardless of
which OCI cache type is the Tier 1 target.

### 11.2 Mode 2: HTTPS MITM via HAProxy (see §12)

The trust-breaking alternative. Detailed in §12. Use when Mode 1 is
unavailable (e.g. dockerd is pinned to the graphdriver image store, or
the containerd image puller is bypassed by some downstream tooling),
or to compare cache hit rates under MITM vs hosts.toml for the same
workload.

### 11.3 Mode 3: legacy `daemon.json` registry-mirrors (comparison baseline)

Kept around so we can benchmark legacy-mode pulls side-by-side with
Mode 1. **Do not use as the primary client config** — it only mirrors
`docker.io`, so any `FROM gcr.io/...` or `FROM ghcr.io/...` in a user
Dockerfile silently bypasses the cache.

How it works (recap of the two relevant `daemon.json` keys):

- **`registry-mirrors`** — list of URLs dockerd consults *before*
  Docker Hub for anything in the `docker.io` namespace. Tried in list
  order; falls back to Docker Hub if no mirror responds. **Applies
  only to `docker.io`.**
- **`insecure-registries`** — list of `host[:port]` entries where
  dockerd is allowed to speak plain HTTP or skip TLS verification.
  Pure trust relaxation; not a routing directive.

For HTTP-only HAProxy on the experiment bridge, you need both:

```json
{
  "registry-mirrors": ["http://127.0.0.1:8088"],
  "insecure-registries": ["127.0.0.1:8088"]
}
```

The same `cache-set-mirror` flake app from §11.1.6 can re-target this
to a different HAProxy port (`8089` for Zot, `8090` for nginx) when
running Mode 3 benchmarks.

> Why we keep this at all: the same cache topology can be exercised
> via two different client-side mechanisms, which lets us isolate
> "what is the *protocol* cost of containerd vs dockerd-distribution
> pulls" from "what is the *cache implementation* cost". Without Mode
> 3 we'd be measuring both at once.

---

## 12. Alternative: transparent HTTPS MITM via HAProxy (full-control mode)

This is **Mode 2** from the table in §11. It exists as an alternative
to Mode 1 (containerd `hosts.toml`, §11.1) and as the only viable
path when Mode 1 is unavailable.

**When Mode 1 already works (most cases), prefer Mode 1.** It is
strictly simpler — no PKI to maintain, no DNS poisoning, no broken
TLS trust — and covers the same set of registries. Mode 2 is the
right choice when:

- dockerd is configured with the legacy graphdriver image store (so
  `hosts.toml` isn't consulted) — e.g. userns remapping forces this
  per
  [`daemon/command/daemon_linux.go:30-40`](../../moby/daemon/command/daemon_linux.go).
- Some downstream tooling bypasses containerd's resolver entirely
  (rare, but observed in some BuildKit configurations).
- You want a comparison benchmark of "interception at the network
  layer" vs "interception at the protocol layer".

The architecture below stands on its own and shares all the same
cache-side infrastructure (Distribution, Zot, nginx, HAProxy
backends) as Mode 1 and Mode 3 — only the HAProxy frontend changes.

### 12.1 Why a vanilla HTTPS_PROXY doesn't help

dockerd's distribution HTTP client uses
`http.ProxyFromEnvironment`, see
[`daemon/internal/distribution/registry.go:87`](../../moby/daemon/internal/distribution/registry.go)
and [`daemon/pkg/registry/registry.go:137`](../../moby/daemon/pkg/registry/registry.go).
It also explicitly forwards `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`
from daemon config to its child processes
([`daemon/command/daemon.go:1121-1125`](../../moby/daemon/command/daemon.go)),
so a NixOS systemd drop-in like:

```nix
systemd.services.docker.environment.HTTPS_PROXY = "http://127.0.0.1:3128";
```

makes dockerd route every HTTPS pull through `127.0.0.1:3128`. Good
news — but for HTTPS the proxy protocol is:

```
client ──► proxy   CONNECT registry-1.docker.io:443 HTTP/1.1
client ◄── proxy   HTTP/1.1 200 Connection established
client ◄═══════════════════════════════════════════════════►  upstream
                  (TLS handshake + encrypted HTTP, end-to-end)
```

The proxy opens a TCP tunnel and copies bytes blindly in both
directions. **The TLS handshake and all subsequent HTTP requests are
encrypted between the client and the real upstream** — the proxy
cannot see `/v2/<name>/blobs/sha256:<digest>`, cannot route on it,
cannot consistent-hash on it, and cannot cache it. HTTPS_PROXY alone
gets us nothing for caching.

### 12.2 The MITM solution: own the CA, mint certs, terminate TLS at HAProxy

Because we control the clients, we can give them a custom root CA and
then have HAProxy present certificates that *appear* to be the
upstream's. From dockerd's perspective the TLS handshake succeeds
normally; from HAProxy's perspective the traffic is decrypted HTTP
ready for routing and caching.

Two implementation routes lead to the same outcome, with different
trade-offs.

#### Route A — Explicit proxy + CONNECT + SSL bumping

Keep `HTTPS_PROXY=http://localhost:3128` on the client and have the
proxy do "SSL bumping": instead of opening a tunnel on receipt of
`CONNECT registry-1.docker.io:443`, the proxy *itself* mints a cert
for `registry-1.docker.io` (signed by our CA), presents it to the
client, completes the TLS handshake locally, then reads the decrypted
HTTP request.

- **HAProxy alone cannot do this.** SSL bumping for arbitrary SNI
  requires dynamic cert minting, which is squid (`ssl_bump`) or
  mitmproxy territory.
- Architecturally that means: `dockerd → squid (SSL bump) → HAProxy
  (consistent hashing) → cache backend`. An extra component, but the
  cert list is **unbounded** (squid mints whatever SNI the client
  asks for).
- **Pros:** truly transparent to dockerd; no DNS or `/etc/hosts`
  surgery; survives new CDN hostnames appearing.
- **Cons:** introduces squid (or mitmproxy); two TLS terminations per
  connection (client→squid, squid→upstream); operationally heavier.

#### Route B — DNS poisoning + SNI-based static cert selection at HAProxy (recommended)

Skip the proxy env var entirely. Make all intercepted upstream FQDNs
resolve to the local HAProxy IP via `/etc/hosts` on the client. HAProxy
listens on `:443` with a **pre-minted cert per upstream FQDN** loaded
via `crt-list`, and selects the matching cert from the client's SNI.

- **Pure HAProxy.** No squid, no mitmproxy.
- HAProxy's `bind ... ssl crt-list /etc/haproxy/upstream-certs.list`
  + `ssl_fc_sni` ACLs is a well-trodden path.
- The list of FQDNs is finite, known (see §6), and already
  centralised in `constants.nix` under `upstreams.*.egressHosts`.
- **Pros:** one fewer component, fits the existing HAProxy-centric
  design, lets HAProxy do the consistent hashing directly on the
  decrypted URI just like in §10.
- **Cons:** an upfront FQDN allowlist must be maintained; if Docker
  rotates to a new CDN hostname we'd have to mint a new cert (but
  see §12.6 — the caches dereference CDN redirects internally, so
  this concern is far smaller than it looks).

**We recommend Route B for v1.** Route A remains available as a v2
escape hatch if list maintenance becomes painful.

### 12.3 PKI design

A new flake app `cache-gen-ca` creates the lab CA, modelled on
`secrets-gen.nix` in `ceph-on-k8s`. Layout:

```
secrets/
├── ssh/...                                 # existing
└── ca/
    ├── root-ca.key                         # 4096-bit RSA, only used to sign
    ├── root-ca.crt                         # self-signed, 10y validity
    ├── intermediate.key                    # for day-to-day signing (kept around for rotation)
    ├── intermediate.crt                    # signed by root-ca, 5y validity
    └── upstream/                           # one cert per Tier-1 upstream FQDN
        ├── registry-1.docker.io.{crt,key}  # docker.io
        ├── gcr.io.{crt,key}
        ├── ghcr.io.{crt,key}
        ├── quay.io.{crt,key}
        ├── registry.k8s.io.{crt,key}
        ├── huggingface.co.{crt,key}
        └── cdn-lfs.huggingface.co.{crt,key}
```

`step-cli` is the right tool for this (already a dev-shell dep in
`nix-k8s-examples`); it can mint per-FQDN certs in one line. The
upstream list is read from `constants.nix.mitm.upstreamHosts`, so
adding an FQDN is one entry + `nix run .#cache-gen-ca`.

### 12.4 Trust insertion on the client VMs

In `nix/microvm-client.nix`, the root CA is added to the system trust
store via NixOS's built-in mechanism:

```nix
security.pki.certificateFiles = [ ../secrets/ca/root-ca.crt ];
```

That single line installs `root-ca.crt` into `/etc/ssl/certs/ca-bundle.crt`
and the per-format directories Docker and Go look at. Go's
`crypto/x509.SystemCertPool` (which `net/http` uses) picks it up
automatically.

We deliberately do **not** install the CA on the cache VMs — they need
to validate *real* upstream certs when fetching content for cache
misses. This asymmetry is the load-bearing trick that prevents the
MITM loop closing in on itself.

### 12.5 DNS poisoning (just `/etc/hosts` for v1)

In `nix/microvm-client.nix`:

```nix
networking.hosts = {
  "10.44.44.10" = [
    # Tier-1 OCI registries (§11.1.3)
    "registry-1.docker.io"
    "gcr.io"
    "ghcr.io"
    "quay.io"
    "registry.k8s.io"
    # Hugging Face (non-OCI)
    "huggingface.co"
    "cdn-lfs.huggingface.co"
  ];
  # NOTE: client0's own IP is 10.44.44.10; client1 swaps in .11
  #       (the local HAProxy listens on the client's own address)
};
```

Any registry **not** in this poison list (e.g. `mcr.microsoft.com`,
`public.ecr.aws`) goes direct to upstream from the client in Mode 2.
Mode 1 catches those via the `_default` wildcard (§11.1.5); Mode 2
doesn't have an equivalent because we can't MITM a host without a
cert for it. The §15 future-work item on Route A (squid SSL bumping)
would close this gap with dynamic cert minting.

**Critically, the auth hosts and CDN hosts are NOT poisoned:**

- `auth.docker.io`, `auth.docker.com`, `login.docker.com` —
  not intercepted. dockerd talks to the real Docker Hub auth servers
  to mint bearer tokens. Those calls are short, infrequent, and
  uncacheable (signed JWTs).
- `production.cloudfront.docker.com`,
  `production.cloudflare.docker.com`,
  `docker-images-prod.<hash>.r2.cloudflarestorage.com` —
  not intercepted from the client either. **The cache backends
  (Distribution / Zot) dereference these redirects internally as
  described in §6.2 / §9.1 / §9.2**, so dockerd never sees a 307 in
  this mode and never connects to a CDN host. If we ever switch to
  nginx Option 1 (which itself follows 307s server-side) the same
  property holds.

This is a happy outcome: the MITM allowlist shrinks to just the OCI
API hosts plus Hugging Face's own hostnames — **three or four FQDNs
total**, not the dozen-plus you'd need if MITM also had to cover the
CDN edges.

For v2, replace `/etc/hosts` with a `dnsmasq` instance on the client
VM that does the same poisoning but supports wildcards (useful if
Hugging Face starts using `*.cdn-lfs.huggingface.co`).

### 12.6 HAProxy frontend with SNI termination

```haproxy
frontend mitm
    bind 10.44.44.10:443 ssl crt-list /etc/haproxy/upstream-certs.list alpn h2,http/1.1
    mode http

    # Route on SNI to the upstream-specific backend pool. Same
    # balance uri whole + consistent hashing as the registry-mirrors
    # path in §10 — HAProxy now sees the decrypted URI, so the hash
    # input is exactly /v2/<name>/blobs/sha256:<digest>.
    # SNI ACLs for the Tier-1 OCI registries (§11.1.3) plus HF
    acl sni_docker     ssl_fc_sni -i registry-1.docker.io
    acl sni_gcr        ssl_fc_sni -i gcr.io
    acl sni_ghcr       ssl_fc_sni -i ghcr.io
    acl sni_quay       ssl_fc_sni -i quay.io
    acl sni_k8s        ssl_fc_sni -i registry.k8s.io
    acl sni_hf         ssl_fc_sni -i huggingface.co
    acl sni_hf_lfs     ssl_fc_sni -i cdn-lfs.huggingface.co

    # Reuses the SAME backend pools as Mode 1 (§10) — be_dist_*, be_zot_*,
    # be_ngx_*. Which cache type those resolve to is controlled by the
    # per-cache MITM listener address (§12.7), not by SNI.
    use_backend be_dist_docker if sni_docker
    use_backend be_dist_gcr    if sni_gcr
    use_backend be_dist_ghcr   if sni_ghcr
    use_backend be_dist_quay   if sni_quay
    use_backend be_dist_k8s    if sni_k8s
    use_backend be_ngx_huggingface if sni_hf or sni_hf_lfs

    # Anything else (registry we forgot to mint a cert for) → wildcard
    default_backend be_ngx_default

# crt-list /etc/haproxy/upstream-certs.list contains one combined PEM
# per Tier-1 OCI FQDN + the two HF FQDNs (7 entries). The exact list
# is generated by `cache-gen-ca` from constants.ociUpstreams +
# constants.httpUpstreams; see §12.3.
```

The backends are exactly the same backends already defined in §10 —
nothing changes from the cache's perspective. The caches still see
OCI Distribution `/v2/...` requests on their existing ports, still
return blob bytes keyed by digest, still dereference CDN redirects
internally.

### 12.7 Switching between caches in MITM mode

The per-cache-type frontend ports trick from §11.1.6 doesn't work
directly here, because the client is connecting to `:443` on the
poisoned FQDN — there is no port number for `cache-set-mirror` to
flip. Two options:

**(a) Per-cache MITM listen addresses.** Bind HAProxy on three
loopback aliases: `127.0.0.10` for Distribution, `127.0.0.11` for
Zot, `127.0.0.12` for nginx. The `networking.hosts` entry for
`registry-1.docker.io` points at one of them; switching =
`cache-set-mirror --cache=zot` rewrites `/etc/hosts` and triggers
`systemctl reload network`. dockerd needs no restart because Go's
resolver re-reads `/etc/hosts` on each lookup.

**(b) Dynamic backend selection at HAProxy.** A single MITM listener
with a runtime-switchable backend via a HAProxy stick-table key or a
file map (`http-request set-var(req.cache_choice) … if { … }`).
Switching is `echo zot > /etc/haproxy/active-cache && systemctl
reload haproxy`. Heavier reload but no DNS resolver caching
concerns.

Recommend (a) — same UX as the registry-mirrors mode (`cache-set-mirror`
swaps a config file and reloads one service), no HAProxy reload.

### 12.8 Trade-offs vs the `registry-mirrors` mode

| Property                                       | registry-mirrors mode (§10–§11) | MITM mode (this section)                                           |
|------------------------------------------------|---------------------------------|--------------------------------------------------------------------|
| Upstreams covered transparently                | docker.io only                  | docker.io + gcr.io + huggingface.co + anything we mint a cert for  |
| Client-side config burden                      | `daemon.json` (one file)        | Trust the CA + `/etc/hosts` entries                                |
| Cache routing                                  | HAProxy ACL on `Host:` header   | HAProxy ACL on `ssl_fc_sni`                                        |
| HAProxy hashing input                          | decrypted URI                   | decrypted URI (same)                                               |
| Number of FQDNs needing cert/poison entries    | 0                               | ~3–4 (just OCI API hosts; CDN hosts handled by caches)             |
| Visible to existing tooling (`docker pull foo`) | yes, unchanged                  | yes, unchanged                                                     |
| Visible to `gcr.io/...` and `huggingface.co/...` pulls | no                       | **yes** — this is the headline win                                 |
| Risk surface                                   | low (only `docker.io` redirected) | medium (we are spoofing real-internet hosts; restricted to the lab subnet) |
| Survives upstream changing CDN host            | yes (caches handle it)          | yes (caches still handle it; no client cert touches CDN)           |

### 12.9 Why we keep both modes available

Both modes share **all** the cache-side infrastructure (Distribution,
Zot, nginx, their on-disk stores) and the HAProxy backend pools. They
differ only in the listener: an HTTP frontend with Host-header ACLs
(registry-mirrors mode) vs a TLS-terminating frontend with SNI ACLs
(MITM mode). Both are useful experiments:

- **registry-mirrors mode** is what a docker-only shop would deploy
  in production without breaking trust. It's the comparison baseline.
- **MITM mode** is what a homelab / restricted-network operator who
  trusts their internal infrastructure can deploy to cache
  **everything**, not just `docker.io`. It's the upper bound of how
  much upstream traffic we can avoid.

A flake app `cache-set-mode` flips a client between the two by
toggling whether HAProxy's HTTP frontend (port `8088`) or its TLS
frontend (port `443`) is the one dockerd is steered toward. Both can
even run simultaneously; we just don't recommend it for clean
measurements.

---

## 13. OS package caching (apt / dnf / yum) — Layer 2

Everything in §9–§12 caches the **container image** (Layer 1). But a
container image is just the starting point; what often dominates build
time and bandwidth is the OS package operations *inside* the container:

```dockerfile
FROM debian:bookworm
RUN apt-get update && apt-get install -y build-essential cmake ninja-build  # ~200 MB
```

```dockerfile
FROM redhat/ubi9
RUN dnf install -y gcc make python3-pip                                      # ~300 MB
```

Every layer cache miss re-downloads those packages from
`http://deb.debian.org/`, `https://cdn.redhat.com/`, etc. This section
adds a **Layer 2** cache for those downloads, again transparently
(unmodified Dockerfile constraint from §11 still applies).

### 13.1 The cache target

| Distro family | Default protocol | Default repos                                                                 | Cacheable surface     |
|---------------|------------------|------------------------------------------------------------------------------|------------------------|
| Debian / Ubuntu | HTTP            | `deb.debian.org`, `security.debian.org`, `archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com` | `.deb`, `Packages.gz`, `InRelease`, `Sources.gz` |
| Alpine        | HTTPS            | `dl-cdn.alpinelinux.org`                                                     | `.apk`, `APKINDEX.tar.gz` |
| RHEL / UBI / Fedora | HTTPS      | `cdn.redhat.com`, `cdn-ubi.redhat.com`, `mirrors.fedoraproject.org`, `download.fedoraproject.org` | `.rpm`, `repomd.xml`, `*.xml.gz`/`*.xml.zst` |
| Misc dev      | HTTPS            | `download.docker.com`, `apt.releases.hashicorp.com`, `nodesource.com`, `pypi.org`, `files.pythonhosted.org` (pip wheels) | varies              |

**The HTTP/HTTPS split is the key design constraint.** Debian/Ubuntu
default to HTTP because Debian packages are individually GPG-signed
(the cache cannot tamper undetected). Alpine / RHEL / most "third
party" repos default to HTTPS, where TLS is the integrity story.

This means **OS package caching needs both an HTTP path (easy) and an
HTTPS path (requires MITM)**. The HTTPS path forces the CA-injection
question, addressed in §13.4.

### 13.2 Topology

The OS-package cache lives on **the same cache VMs** that host the
container-image caches (`cache0`, `cache1`). Reusing the cache VMs
keeps the disk hot-set in one place and lets HAProxy's consistent
hashing apply uniformly. Two new processes per cache VM:

| port  | service                                  | role                                                           |
|-------|------------------------------------------|----------------------------------------------------------------|
| `3142`| **apt-cacher-ng**                        | Distro-aware caching proxy for `.deb` / `.rpm` / `Packages*` / `repomd*` (handles per-mirror, per-distro idiosyncrasies natively) |
| `8086`| **nginx — generic HTTP/S cache for everything else** | Catch-all for any other HTTP(S) traffic from containers: pip wheels, `download.docker.com`, etc. Same Option-1 redirect-following config as §9.3, but cache key includes `Host:`. |

On the client VMs we add an iptables REDIRECT rule that intercepts
outbound HTTP(S) traffic from container network namespaces and
redirects to a local HAProxy frontend (which then forwards to the
cache VMs with consistent hashing on URI). New HAProxy frontend ports
on each client:

| port  | role                                                                             |
|-------|----------------------------------------------------------------------------------|
| `3142`| Transparent proxy for HTTP/3142-style apt traffic — forwards to apt-cacher-ng on cache VMs |
| `8080`| Transparent HTTP proxy — forwards generic HTTP to nginx generic on cache VMs     |
| `8443`| **MITM** TLS proxy — terminates TLS using minted certs from §12, forwards decrypted HTTP to nginx generic |

### 13.3 Network-layer interception (iptables REDIRECT)

Each client VM has an nftables rule chain that watches outbound
traffic *originating in container namespaces* (uid match, since
dockerd by default doesn't change uid; or cgroup match for the
`docker.slice` cgroup):

```bash
# nix/modules/docker-client.nix → networking.firewall.extraCommands
nft add table inet pkg-intercept
nft add chain inet pkg-intercept output { type nat hook output priority dstnat \; }

# Container traffic only — match on cgroup membership of dockerd's slice.
# Uses nftables's cgroupv2 path matching (kernel ≥ 5.4).
nft add rule inet pkg-intercept output \
    socket cgroupv2 level 2 "system.slice/docker.service" \
    tcp dport 80 redirect to :8080

nft add rule inet pkg-intercept output \
    socket cgroupv2 level 2 "system.slice/docker.service" \
    tcp dport 443 redirect to :8443
```

Two carve-outs we add as explicit rules above these:

- **Container-image traffic** (to ports `8088`–`8092` on the loopback)
  is *not* intercepted — those are our own mirror endpoints from §11.
  The `accept` rule for `daddr 127.0.0.0/8` precedes the redirect.
- **Egress to our own bridge gateway** (`10.44.44.1`) is not
  intercepted either, so HAProxy's outbound calls to the cache VMs
  don't loop back.

The HTTP rule (`:8080`) is straightforward — HAProxy proxies the
plain HTTP request to the cache VMs, hashes on URI for consistency,
nginx-generic caches by `Host: + $uri`. **apt repos that use HTTP just
work** with no further surgery.

The HTTPS rule (`:8443`) is where the MITM machinery from §12 has to
extend down into the container's view of the world — addressed in
§13.4.

### 13.4 The CA-trust-in-containers problem

Containers don't share the host's `/etc/ssl/certs/`. A `debian:bookworm`
container has its own `ca-certificates` package and its own trust
bundle at `/etc/ssl/certs/ca-certificates.crt`. For HTTPS MITM to
work, **our internal CA (from §12.3) must appear in the trust bundle
of every container at runtime**, without modifying any Dockerfile.

Three approaches we considered:

| Approach | How it works | Verdict |
|----------|--------------|---------|
| Ask users to add the CA to their Dockerfile | `COPY ca.crt /usr/local/share/ca-certificates/ && update-ca-certificates` | ❌ **violates the §11 constraint** |
| BuildKit `--build-context` injection | Inject a synthetic build context with the CA into every `docker build` | ⚠️ works for builds, *not for* `docker run` of pre-built images. Partial coverage. |
| **OCI runtime prestart hook** | Custom `runc` wrapper that bind-mounts the CA into every container at the default trust paths | ✅ **chosen approach.** Truly transparent; covers `docker build` and `docker run` equally. |

### 13.5 Implementation: the `cache-ca-injector` runc prestart hook

The hook is a tiny binary (Go, ~100 LOC) installed at
`/usr/local/bin/cache-ca-injector` on each client VM. We register it
as the default OCI runtime via `daemon.json`:

```json
{
  "default-runtime": "runc-with-ca",
  "runtimes": {
    "runc-with-ca": {
      "path": "/usr/local/bin/runc-with-ca-wrapper"
    }
  }
}
```

`runc-with-ca-wrapper` is a shell that prepends our prestart hook to
the OCI spec's `hooks.prestart` array, then `exec`s real `runc`:

```bash
#!/bin/sh
# Wraps runc, injecting our CA prestart hook before exec.
# Reads the OCI bundle spec, adds the hook, writes it back.
set -e
BUNDLE=$(awk '{for(i=1;i<=NF;i++) if($i=="--bundle") print $(i+1)}' <<< "$*")
if [ -f "$BUNDLE/config.json" ]; then
    jq '.hooks.prestart = ((.hooks.prestart // []) +
        [{"path": "/usr/local/bin/cache-ca-injector"}])' \
        "$BUNDLE/config.json" > "$BUNDLE/config.json.tmp" \
        && mv "$BUNDLE/config.json.tmp" "$BUNDLE/config.json"
fi
exec /usr/bin/runc "$@"
```

The prestart hook itself (`cache-ca-injector.go`) reads the container
PID from stdin (per the OCI hook protocol), enters its mount
namespace, and writes the CA into every known trust-bundle location:

```go
// Pseudocode — actual implementation in nix/modules/ca-injector.nix
hookState := struct{ Pid int }{}
json.NewDecoder(os.Stdin).Decode(&hookState)

paths := []string{
    "/etc/ssl/certs/ca-certificates.crt",         // Debian/Ubuntu/Alpine
    "/etc/pki/tls/certs/ca-bundle.crt",           // RHEL/Fedora/UBI
    "/etc/pki/ca-trust/source/anchors/cache.crt", // RHEL update-ca-trust
    "/etc/ssl/cert.pem",                          // Alpine (libressl)
}

unix.Setns(...mntNsOf(hookState.Pid)...)
for _, p := range paths {
    if _, err := os.Stat(filepath.Dir(p)); err == nil {
        appendCAToFile(p, "/etc/cache-experiment/ca/root-ca.crt")
    }
}
```

Each path gets the CA *appended* to the existing trust bundle, so the
container's own CA set still works (containers can still verify real
upstream TLS — important for the HAProxy fallback path on cache miss).

### 13.6 What this does and doesn't catch

| Workload                                          | Caught by              | Notes |
|---------------------------------------------------|------------------------|-------|
| `apt-get install foo` in a Debian/Ubuntu container | apt-cacher-ng (HTTP)   | The common case. Pure HTTP, no MITM needed. |
| `dnf install foo` in a RHEL/UBI container          | apt-cacher-ng (HTTPS via MITM) | apt-cacher-ng's `rpm-cache` mode also handles RPM. CA injection required. |
| `apk add foo` in an Alpine container               | nginx generic (HTTPS via MITM) | CA injection required. |
| `pip install foo` (wheels)                         | nginx generic (HTTPS via MITM) | Wheel files are content-addressed; cache hit rate is high. |
| `curl https://download.docker.com/...`             | nginx generic (HTTPS via MITM) | Anything else that's just an HTTPS GET. |
| **Application-level mTLS** (e.g. `gcloud auth`)    | **NOT** caught         | If the app pins certificates or uses mTLS with a client cert, the MITM fails. The container falls back to direct upstream (works, but doesn't cache). |
| **DoH / DoT in the container**                     | **NOT** caught         | Encrypted DNS bypasses our cache hostname routing. Cache miss → direct upstream. |
| **Privileged containers** that override the trust bundle from `/proc/self/exe` paths | partial | Custom apps that re-init their own TLS configs may bypass the appended CA. |

### 13.7 Trade-offs and risk

This is the most invasive single change in the design. Specifically:

- **Every container started on our lab clients has a CA from our PKI
  in its trust bundle.** A container that exfiltrates the trust
  bundle (e.g. malware in a base image) would see our CA. The blast
  radius is bounded to "things signed by our CA can MITM that
  container's later HTTPS calls" — which is exactly what we're doing
  on purpose, but worth understanding.
- **Trust bundle mutation breaks reproducibility checks.** Some tools
  hash the trust bundle (e.g. `update-ca-certificates --verbose`
  output); they'll see drift. Document; don't fix.
- **Cache misroute risk is higher than for OCI caches.** With OCI,
  the `ns=` param lets HAProxy route to the correct upstream-aware
  cache. With generic HTTP, the cache key includes `Host:` — if two
  upstreams happen to use the same path under different hostnames,
  they don't collide (good), but a misconfigured cache that ignored
  `Host:` would silently cross-contaminate (bad). The nginx-generic
  config explicitly keys on `$http_host:$request_method:$uri` to
  avoid this.
- **The runc wrapper is invasive.** Every container start now goes
  through our shell + jq + runc instead of just runc. Latency cost is
  ~10ms per container start; acceptable for an experiment lab,
  arguably not for a production node.

The §15 design-choices section adds explicit validation items for
this design (CA presence in started containers, no breakage of
container TLS to external destinations the cache doesn't intercept,
nftables rule correctness under restart).

---

## 14. Build and run workflow

Mirrors the apps exposed by `nix-k8s-examples`/`ceph-on-k8s`:

```bash
# one-time host prep
nix run .#cache-check-host             # verify tun, vhost-net, bridge support, sudo
sudo nix run .#cache-network-setup     # create cachebr0 + 4 TAPs + NAT

# offline secret generation (ssh keys; also CA + per-FQDN MITM certs for §12)
nix run .#cache-gen-secrets
nix run .#cache-gen-ca                 # only needed if you plan to use Mode 2

# bring everything up
nix run .#cache-start-all              # build + boot all 4 microvms

# ── pick the client-side mode and cache under test ───────────────────────
# Mode 1 (primary): containerd hosts.toml
nix run .#cache-set-mode   -- --client=client0 --mode=hosts-toml
nix run .#cache-set-mirror -- --client=client0 --cache=zot   # one of: distribution, zot, nginx
# → rewrites /etc/containerd/certs.d/{docker.io,gcr.io,ghcr.io,quay.io,
#   registry.k8s.io}/hosts.toml to point at the new HAProxy port,
#   then `systemctl reload containerd` (in-process hot reload).

# Mode 2 (alt, MITM):
nix run .#cache-set-mode   -- --client=client0 --mode=mitm
nix run .#cache-set-mirror -- --client=client0 --cache=zot   # repoints the
# /etc/hosts MITM loopback alias to the right per-cache listener (§12.7)

# Mode 3 (legacy, comparison only):
nix run .#cache-set-mode   -- --client=client0 --mode=registry-mirrors
nix run .#cache-set-mirror -- --client=client0 --cache=zot   # rewrites daemon.json
# only mirrors docker.io; other registries bypass the lab — for benchmarks only

# ── exercise the chosen mode ─────────────────────────────────────────────
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull alpine"               # docker.io
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull gcr.io/distroless/static-debian12"
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull ghcr.io/astral-sh/uv:latest"
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull registry.k8s.io/pause:3.10"
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull quay.io/prometheus/prometheus:latest"
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull mcr.microsoft.com/dotnet/runtime:9.0"
# ↑ the mcr.microsoft.com pull exercises the _default nginx wildcard (§11.1.5)

# watch what HAProxy is doing
nix run .#cache-vm-ssh -- --node=client0 -- "curl -s localhost:8404/stats\;csv"

# tear down
nix run .#cache-vm-stop
sudo nix run .#cache-network-teardown
```

Additional helpers we will add:

- `cache-vm-wipe` — delete all `*-data.img` for a cold run.
- `cache-render` — render every config file (HAProxy, Distribution, Zot,
  nginx vhosts, `hosts.toml` per Tier-1 registry, `daemon.json`
  template for Mode 3) into `rendered/` so we can `git diff` expected
  output without booting a VM.
- `cache-pull-corpus` — run a fixed list of pulls from a client; useful
  for repeatable warm/cold cache measurements across all three modes.

---

## 15. Design choices to validate

A few decisions in this doc are reasonable defaults but worth poking at
before implementing:

1. **One HAProxy frontend port per cache type** (current design) vs
   **single port with internal switching.** We landed on per-port
   because it makes the "currently active cache" visible to
   `containerd config dump` and HAProxy stats simultaneously, with no
   global mutex. Downside: experiments that mix two cache types
   concurrently (e.g. half-traffic Zot, half Distribution) need two
   clients. If that becomes a common need we add a runtime-switching
   HAProxy variant.

2. **`urlp(ns)` ACL relies on containerd always appending `ns=`.**
   Confirmed in source ([`resolver.go:591-598`](../../containerd/core/remotes/docker/resolver.go); gated by
   `registry.go:85-91`). For the `docker.io` → `registry-1.docker.io`
   special case the gate fires only when the mirror host differs from
   `registry-1.docker.io` — which it always does in our setup (mirror
   is `localhost:8088`). The fallback in HAProxy is
   `default_backend be_ngx_default` so a missing `ns=` doesn't
   black-hole.

3. **Two Zot instances vs one with multiple sync registries.** One
   instance per upstream is symmetric with Distribution; one instance
   serving both is "more Zot-native". The symmetric layout makes the
   per-upstream measurement story simpler — we keep it unless it costs
   us something noticeable.

4. **Cache identity = `cache0` vs `cache1` for consistent hashing.**
   With only two backends, the failure-mode story for consistent hashing
   is "the entire cache half goes cold on failover". For real experiments
   we may want to bring up `cache2`/`cache3` to see the more graceful
   `1/N` remap behaviour. The `nodes.nix` design makes that trivial.

5. **HTTP-only across the lab.** Acceptable on a private bridge for now.
   If we want to test how clients behave against a TLS-fronted cache
   we'll add a build-time CA generation step modelled on `certs.nix`
   from the sister repos.

6. **Hugging Face caching via nginx only.** We deliberately scoped Zot
   and Distribution to OCI registries; they are not designed for
   generic HTTP. nginx is the right tool for HF blob caching, and the
   HF CLI is happy to talk to an arbitrary URL.

7. **Nginx redirect-following config (Option 1 in §9.3).** Relies on
   `error_page 307 = @follow_cdn` + `$upstream_http_location` — verify
   this actually traps the 307 across the nginx versions we pin, and
   that the CDN response is cached under the digest-only key. A
   misconfiguration here turns nginx-for-dockerhub into a pure
   passthrough with zero hit rate — exactly the anti-pattern we are
   trying to avoid.

8. **CDN affinity over time.** Repeat pulls of the same blob may land
   on different CDN edges (CloudFront vs Cloudflare vs R2 depending on
   plan tier and geography). Distribution / Zot are insulated because
   they store by digest, but nginx Option 1 needs to tolerate
   `Location:` URLs whose hostname changes between pulls. Confirm by
   counting distinct upstream hosts in nginx access logs across N
   pulls of the same image.

9. **Authenticated vs anonymous Docker Hub pulls.** v1 is anonymous
   pulls, which land on
   `docker-images-prod.<hash>.r2.cloudflarestorage.com` (Cloudflare
   R2). If we extend to authenticated pulls we will mostly land on
   `production.cloudfront.docker.com` instead. Cache behaviour should
   be identical from the digest-keyed perspective, but worth measuring
   end-to-end.

10. **MITM mode SNI list completeness.** Route B in §12 only mints
    certs for OCI API hosts (and HF). The reasoning is that CDN
    redirects are handled inside the cache backends and the client
    never connects to a CDN host. Verify this empirically by tracing
    a fresh pull from `client0` and confirming no traffic leaves the
    bridge to a `*.cloudfront.docker.com` / `*.cloudflarestorage.com`
    destination from the client's IP. If anything does leak, mint a
    cert for that host too.

11. **MITM-mode cache switching mechanism.** §12.7 sketches two
    options (loopback-alias listeners vs runtime HAProxy backend
    switch). Pick one in implementation and validate that switching
    is fast (<1s) and visible (e.g. `docker info` or HAProxy stats
    reflects it). Mismatch between selected cache and observed
    behaviour is the most likely source of measurement confusion.

12. **Trust-store rotation.** The CA in `secrets/ca/` is long-lived
    (10y root, 5y intermediate). Per-FQDN certs are shorter (e.g.
    1y). A flake app `cache-rotate-mitm-certs` should be able to
    re-mint every per-FQDN cert from the existing intermediate and
    hot-reload HAProxy. Validate before we end up wedged at expiry.

13. **containerd-snapshotter is actually active on our client VMs.**
    Mode 1 is silently a no-op if dockerd ends up on the graphdriver
    image store. Check on each client boot:
    ```bash
    docker info --format '{{.DriverStatus}}'   # expect "io.containerd.snapshotter.v1.overlayfs" or similar
    docker info --format '{{json .ContainerdCommit.ID}}'
    ```
    The `nix/modules/docker-client.nix` module should fail the build
    if `virtualisation.docker.daemon.settings.features` ever sets
    `containerd-snapshotter = false`, and a startup oneshot on
    `client0`/`client1` should `journalctl --grep` for the
    "containerd-snapshotter is now the default" warning as positive
    confirmation.

14. **Mode 1 falls back to upstream on cache failure, not on cache
    misroute.** containerd's silent fallthrough
    ([`resolver.go:287-349`](../../containerd/core/remotes/docker/resolver.go)) only triggers on connection
    errors and select HTTP statuses on non-final mirrors. If a
    misconfigured cache returns a *200 with wrong content* (e.g. a
    Distribution proxy hardcoded for `docker.io` happily serves a
    request meant for `gcr.io` because we routed wrong), containerd
    will accept and store the wrong image. Mitigation: the HAProxy
    `urlp(ns)` ACL must never send a request to a backend hardcoded
    for a different upstream. Validate by sending a deliberately
    misrouted request in CI and checking that the backend returns
    404, not 200.

15. **Wildcard catch-all coverage.** The `_default/hosts.toml`
    nginx-wildcard path is the *only* mechanism that caches Tier-2
    registries (mcr.microsoft.com, public.ecr.aws, etc.). Validate
    that a `docker pull mcr.microsoft.com/dotnet/runtime:9.0`:
    (a) actually goes through the wildcard nginx (not direct
    upstream), (b) leaves a cache entry on disk on the cache VM, and
    (c) a second pull from the *other* client gets a cache hit
    despite consistent hashing.

16. **Tier 1 list growth.** Today: 5 upstreams. Six months from now
    when `quay.io` migration to `quay-prod.io` lands, or some new
    common registry pops up in user Dockerfiles, the Tier 1 list
    grows. Validate that adding a sixth upstream is one entry in
    `constants.nix.ociUpstreams` + `nix run .#cache-render` + redeploy
    — no manual port plumbing, no hand-written HAProxy ACLs.

---

## 16. Future work

- **Workload generator.** A reproducible pull corpus (top-50 docker.io
  images, a fixed set of gcr.io k8s images, a couple of HF models) so we
  can produce comparable warm/cold numbers.
- **Per-pull metrics.** Per-image `time docker pull`, plus parsing
  HAProxy's CSV stats and the per-cache logs into a small ClickHouse or
  even SQLite for queries.
- **Cache GC.** Currently we wipe data disks; a real measurement story
  needs Distribution `garbage-collect`, Zot's built-in GC, and nginx
  `proxy_cache_purge` (or just the `inactive=` knob).
- **More backends.** [`harbor`](https://goharbor.io/) (proxy project),
  [`crane`](https://github.com/google/go-containerregistry) as a
  measurement client, [`spegel`](https://github.com/spegel-org/spegel)
  for peer-to-peer comparison.
- **containerd `hosts.toml` path.** Once we want to compare what
  containerd's per-registry mirror config does differently to dockerd's
  global mirror, we add a second client variant.
- **Per-CDN cache-miss accounting.** Now that blobs come from one of
  three CDN endpoints, log which CDN host the cache fetched from on a
  miss and whether that affects miss latency. Hook into Distribution
  middleware / Zot's structured logs / nginx access logs to record
  `$upstream_addr`.
- **DNS-based egress allowlist.** A `dnsmasq` allowlist on `cachebr0`
  that permits only the hosts in §6.3, so accidental traffic to other
  upstreams during experiments is visible.
- **MITM Route A (HTTPS_PROXY + SSL bumping)** as a v2 option, using
  squid or mitmproxy in front of HAProxy. Worth doing if the v1
  per-FQDN cert list in §12.3 turns out to be painful to maintain.
- **Wildcard DNS poisoning via `dnsmasq`** on the client VMs, replacing
  the static `networking.hosts` list in §12.5. Useful if any of our
  upstreams move to a wildcard-CDN pattern like `*.cdn-lfs.huggingface.co`.
- **Zot as the `_default` wildcard cache** instead of nginx. Zot's
  sync extension supports a list of upstream registries; if it also
  honors the containerd `ns=` query parameter for dynamic dispatch
  (worth verifying with a small spike), we could move the catch-all
  from nginx to an OCI-aware cache. Cleaner protocol semantics, but
  loses the "any HTTP upstream" flexibility nginx has.
- **Tier-2 promotion path.** Currently anything outside Tier 1 lives
  on the nginx wildcard. If telemetry shows a specific Tier-2
  registry (e.g. `nvcr.io`, `public.ecr.aws`) becomes a hot path,
  promote it to Tier 1 with its own Distribution/Zot/nginx
  instances. Promotion = `constants.nix` edit + redeploy.
