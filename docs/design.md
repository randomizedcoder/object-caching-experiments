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
10. [Client-side HAProxy: health checks and consistent hashing](#10-client-side-haproxy-health-checks-and-consistent-hashing)
11. [Client-side Docker daemon configuration](#11-client-side-docker-daemon-configuration)
    1. [`registry-mirrors` vs `insecure-registries`](#111-registry-mirrors-vs-insecure-registries)
    2. [Switching the cache under test](#112-switching-the-cache-under-test)
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
13. [Build and run workflow](#13-build-and-run-workflow)
14. [Design choices to validate](#14-design-choices-to-validate)
15. [Future work](#15-future-work)

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

**Cache backend ports — one per `(cache_type, upstream)` pair.**
This lets HAProxy expose every combination independently for measurement:

| port | cache              | upstream         |
|------|--------------------|------------------|
| 5000 | distribution proxy | `docker.io`      |
| 5001 | distribution proxy | `gcr.io`         |
| 5050 | Zot                | `docker.io`      |
| 5051 | Zot                | `gcr.io`         |
| 8080 | nginx proxy_cache  | `docker.io`      |
| 8081 | nginx proxy_cache  | `gcr.io`         |
| 8082 | nginx proxy_cache  | `huggingface.co` |

> A single Zot instance *could* serve both upstreams (its `extensions.sync`
> block supports a list of `registries`), but running two listeners keeps
> the port table symmetric across the three cache implementations and
> lets us swap in path-rewriting later without restructuring.

**Client-side HAProxy ports**: HAProxy listens on a single TCP port on
each client (default **`8088`**) and uses **Host-header ACLs** to route to
the correct upstream backend pool. See §9.

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

  # ── Cache backends (cache_type × upstream) ─────────────────────────────
  # Used by:
  #   nix/modules/registry-proxy.nix, zot-proxy.nix, nginx-cache.nix → bind
  #   nix/modules/haproxy-client.nix                                 → upstream pool
  upstreams = {
    docker = {
      url  = "https://registry-1.docker.io";
      v2   = "/v2/";
    };
    gcr = {
      url  = "https://gcr.io";
      v2   = "/v2/";
    };
    huggingface = {
      url  = "https://huggingface.co";
      # nginx-only; not an OCI registry
    };
  };

  cacheBackends = {
    "distribution-docker" = { port = 5000; impl = "distribution"; upstream = "docker"; healthPath = "/v2/"; };
    "distribution-gcr"    = { port = 5001; impl = "distribution"; upstream = "gcr";    healthPath = "/v2/"; };
    "zot-docker"          = { port = 5050; impl = "zot";          upstream = "docker"; healthPath = "/v2/"; };
    "zot-gcr"             = { port = 5051; impl = "zot";          upstream = "gcr";    healthPath = "/v2/"; };
    "nginx-docker"        = { port = 8080; impl = "nginx";        upstream = "docker"; healthPath = "/health"; };
    "nginx-gcr"           = { port = 8081; impl = "nginx";        upstream = "gcr";    healthPath = "/health"; };
    "nginx-huggingface"   = { port = 8082; impl = "nginx";        upstream = "huggingface"; healthPath = "/health"; };
  };

  # ── HAProxy on the clients ─────────────────────────────────────────────
  haproxy = {
    frontendPort = 8088;
    statsPort    = 8404;
    # Local hostnames the docker daemon talks to. All resolve to 127.0.0.1
    # via /etc/hosts (declared in nix/modules/docker-client.nix).
    # HAProxy ACLs on req.hdr(host) pick the cache_type × upstream pair.
    routes = {
      "registry-docker.local"    = "distribution-docker";
      "registry-gcr.local"       = "distribution-gcr";
      "zot-docker.local"         = "zot-docker";
      "zot-gcr.local"            = "zot-gcr";
      "nginx-docker.local"       = "nginx-docker";
      "nginx-gcr.local"          = "nginx-gcr";
      "nginx-huggingface.local"  = "nginx-huggingface";
    };
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
| `cache-client0`| `dockerd`, `haproxy` (frontend `:8088` + 7 backends), `regctl`/`crane` for ad-hoc pulls |
| `cache-client1`| same as `client0`                                                   |
| `cache-cache0` | `distribution` ×2 (`:5000` docker, `:5001` gcr), `zot` ×2 (`:5050`, `:5051`), `nginx` ×3 (`:8080`, `:8081`, `:8082`) |
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

---

## 10. Client-side HAProxy: health checks and consistent hashing

The HAProxy on each client implements the routing pattern lifted from
the `moby-image-pull-analysis.md` recommendations: **`balance uri whole`
+ `hash-type consistent sdbm avalanche`**, with `/v2/` health checks that
accept `200,401` as healthy.

Single listener, Host-header routing to seven backend pools. Sketch:

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

# ─────────────────────────── frontend ──────────────────────────────────
frontend caches
    bind *:8088

    # Route by Host header to the (cache_type, upstream) pair.
    acl host_dist_docker hdr(host) -i registry-docker.local
    acl host_dist_gcr    hdr(host) -i registry-gcr.local
    acl host_zot_docker  hdr(host) -i zot-docker.local
    acl host_zot_gcr     hdr(host) -i zot-gcr.local
    acl host_ngx_docker  hdr(host) -i nginx-docker.local
    acl host_ngx_gcr     hdr(host) -i nginx-gcr.local
    acl host_ngx_hf      hdr(host) -i nginx-huggingface.local

    use_backend be_dist_docker if host_dist_docker
    use_backend be_dist_gcr    if host_dist_gcr
    use_backend be_zot_docker  if host_zot_docker
    use_backend be_zot_gcr     if host_zot_gcr
    use_backend be_ngx_docker  if host_ngx_docker
    use_backend be_ngx_gcr     if host_ngx_gcr
    use_backend be_ngx_hf      if host_ngx_hf

# ──────────────────────────── backends ─────────────────────────────────
# One backend per (cache_type, upstream). All have the SAME shape; only
# port and health path differ. Generated from constants.cacheBackends.

backend be_dist_docker
    balance uri whole
    hash-type consistent sdbm avalanche
    option httpchk GET /v2/
    http-check expect status 200,401
    option redispatch
    retries 2
    server cache0 10.44.44.20:5000 check inter 2s fall 3 rise 2
    server cache1 10.44.44.21:5000 check inter 2s fall 3 rise 2

# … be_dist_gcr (5001), be_zot_docker (5050), be_zot_gcr (5051),
#   be_ngx_docker (8080), be_ngx_gcr (8081), be_ngx_hf (8082) follow
#   the same shape with `check expect status 200` for the nginx backends.
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

---

## 11. Client-side Docker daemon configuration

### 11.1 `registry-mirrors` vs `insecure-registries`

These two `daemon.json` keys are often confused, and the example in your
notes (`{"registry-mirrors": [...], "insecure-registries": [...]}` with
the same host in both) shows why: they answer two different questions
and you usually need both when the mirror is HTTP-only.

**`registry-mirrors`** — *"Where should I go first for `docker.io` pulls?"*

- A list of URLs that dockerd consults **before** going to Docker Hub for
  anything in the `docker.io` namespace.
- They are tried **in list order**; if a mirror responds with anything
  other than success, dockerd falls back to the next mirror, and finally
  to Docker Hub itself.
- **Applies only to `docker.io`**. Pulls of `gcr.io/foo/bar` or
  `quay.io/baz` are sent direct to the named registry, regardless of this
  list.
- Default scheme is `https`. dockerd does not by default speak HTTP to a
  mirror.

**`insecure-registries`** — *"Which registry hosts am I allowed to talk
to over plain HTTP / with a self-signed cert?"*

- A list of `host[:port]` (or CIDR) entries that:
  1. Allow plain HTTP if HTTPS is not reachable.
  2. Skip TLS verification if HTTPS is reachable but the cert is invalid.
- It is **not** a routing directive — it does not redirect pulls. It only
  relaxes TLS rules for the listed hosts.
- The two lists are independent; they have overlap **only** because most
  internal mirrors happen to be both "the registry I want to use" and
  "not behind a real TLS cert".

**Recommendation for this lab.**

Because HAProxy on each client listens on `http://127.0.0.1:8088` (no
TLS), we need **both**:

```json
{
  "registry-mirrors": ["http://registry-docker.local:8088"],
  "insecure-registries": [
    "registry-docker.local:8088",
    "registry-gcr.local:8088",
    "zot-docker.local:8088",
    "zot-gcr.local:8088",
    "nginx-docker.local:8088",
    "nginx-gcr.local:8088",
    "nginx-huggingface.local:8088"
  ]
}
```

- The single `registry-mirrors` entry is the *currently selected* cache
  for the `docker.io` namespace — you change this one line to swap caches
  (see §10.2).
- The `insecure-registries` list is the **full menu** of HTTP endpoints
  the daemon is allowed to talk to. Listing all of them up front means
  swapping `registry-mirrors` doesn't require any other daemon edit, and
  also unlocks explicit-tag pulls for the `gcr.io` and Hugging Face cases
  where `registry-mirrors` doesn't help (see below).

> **TLS alternative.** If we later want to drop `insecure-registries`,
> generate a self-signed CA in `secrets/`, mint a cert with all seven
> `*.local` SANs, deploy it on HAProxy, and add the CA to
> `/etc/docker/certs.d/<host>:<port>/ca.crt` on each client. This is
> mechanically identical to the `certs/` pattern in `nix-k8s-examples`
> and `ceph-on-k8s`. For v1 we accept the simpler HTTP-only setup since
> the bridge is private.

### 11.2 Switching the cache under test

`registry-mirrors` only ever affects `docker.io`, so the main switching
story is: *which cache backend handles the `docker.io` workload?*

We make this a one-token change. `daemon.json` is templated from
`/etc/cache-experiment/active-mirror`:

```
# /etc/cache-experiment/active-mirror
registry-docker.local
```

A flake app `cache-set-mirror` swaps the file, regenerates
`daemon.json`, and runs `systemctl reload docker`:

```
nix run .#cache-set-mirror -- --client=client0 --backend=zot-docker
nix run .#cache-set-mirror -- --client=client0 --backend=nginx-docker
nix run .#cache-set-mirror -- --client=client0 --backend=distribution-docker
```

Internally that just rewrites the file to `zot-docker.local`,
`nginx-docker.local`, or `registry-docker.local` respectively — all of
which resolve to `127.0.0.1` via the `/etc/hosts` entries baked into the
client VMs by `nix/modules/docker-client.nix`. HAProxy then sees the
matching Host header and routes to the corresponding backend pool.

For **gcr.io** and **Hugging Face**, `registry-mirrors` doesn't help (it
only covers `docker.io`). You exercise those caches with explicit pulls:

```
docker pull registry-gcr.local:8088/google-containers/pause:3.9
curl  http://nginx-huggingface.local:8088/bert-base-uncased/resolve/main/pytorch_model.bin
```

This is intentionally manual — those are not the primary workload, but
the harness supports them.

---

## 12. Alternative: transparent HTTPS MITM via HAProxy (full-control mode)

The design in §10–§11 routes traffic through HAProxy by *configuring*
dockerd (`registry-mirrors` + `insecure-registries`). It works, but it
inherits two limitations of dockerd's mirror plumbing:

1. `registry-mirrors` covers **only `docker.io`**. Pulls of
   `gcr.io/foo/bar` skip the mirror entirely and go direct to upstream.
2. Hugging Face downloads aren't OCI pulls at all, so dockerd's mirror
   config doesn't help them either.

This section explores a stronger alternative: **transparent HTTPS
interception** at HAProxy, where dockerd makes vanilla HTTPS calls and
HAProxy terminates the TLS on the fly using certs we minted. With our
own CA installed in the client trust store, **every** upstream pull
(docker.io, gcr.io, anything) is intercepted with no per-namespace
client config — and HAProxy gets to see the decrypted URI for
consistent hashing. The user has explicitly signed off on breaking the
HTTPS end-to-end guarantee because the host, both VMs, and both CAs
are all under our control.

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
    └── upstream/                           # one cert per upstream FQDN
        ├── registry-1.docker.io.crt
        ├── registry-1.docker.io.key
        ├── gcr.io.crt
        ├── gcr.io.key
        ├── huggingface.co.crt
        ├── huggingface.co.key
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
    "registry-1.docker.io"
    "gcr.io"
    "huggingface.co"
    "cdn-lfs.huggingface.co"
  ];
  # NOTE: client0's own IP is 10.44.44.10; client1 swaps in .11
  #       (the local HAProxy listens on the client's own address)
};
```

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
    acl sni_docker_io  ssl_fc_sni -i registry-1.docker.io
    acl sni_gcr_io     ssl_fc_sni -i gcr.io
    acl sni_hf         ssl_fc_sni -i huggingface.co
    acl sni_hf_lfs     ssl_fc_sni -i cdn-lfs.huggingface.co

    use_backend be_oci_docker if sni_docker_io
    use_backend be_oci_gcr    if sni_gcr_io
    use_backend be_hf         if sni_hf
    use_backend be_hf_lfs     if sni_hf_lfs

# crt-list /etc/haproxy/upstream-certs.list contains:
#   /var/lib/haproxy/certs/registry-1.docker.io.pem
#   /var/lib/haproxy/certs/gcr.io.pem
#   /var/lib/haproxy/certs/huggingface.co.pem
#   /var/lib/haproxy/certs/cdn-lfs.huggingface.co.pem
# Each .pem is the per-FQDN cert concatenated with its private key
# (HAProxy's combined PEM format).
```

The backends are exactly the same backends already defined in §10 —
nothing changes from the cache's perspective. The caches still see
OCI Distribution `/v2/...` requests on their existing ports, still
return blob bytes keyed by digest, still dereference CDN redirects
internally.

### 12.7 Switching between caches in MITM mode

The Host-header switching trick from §11.2 doesn't work here, because
the SNI is fixed to the upstream FQDN. Two options:

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

## 13. Build and run workflow

Mirrors the apps exposed by `nix-k8s-examples`/`ceph-on-k8s`:

```bash
# one-time host prep
nix run .#cache-check-host             # verify tun, vhost-net, bridge support, sudo
sudo nix run .#cache-network-setup     # create cachebr0 + 4 TAPs + NAT

# offline secret generation (ssh keys only for this project)
nix run .#cache-gen-secrets

# bring everything up
nix run .#cache-start-all              # build + boot all 4 microvms

# pick the cache under test on a client
nix run .#cache-set-mirror -- --client=client0 --backend=zot-docker

# pull something through the chosen cache
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull alpine && docker pull nginx"

# watch what HAProxy is doing
nix run .#cache-vm-ssh -- --node=client0 -- "curl -s localhost:8404/stats\;csv"

# tear down
nix run .#cache-vm-stop
sudo nix run .#cache-network-teardown
```

Additional helpers we will add:

- `cache-vm-wipe` — delete all `*-data.img` for a cold run.
- `cache-render` — render every config file (HAProxy, Distribution, Zot,
  nginx, `daemon.json` template) into `rendered/` so we can `git diff`
  expected output without booting a VM.
- `cache-pull-corpus` — run a fixed list of pulls from a client; useful
  for repeatable warm/cold cache measurements.

---

## 14. Design choices to validate

A few decisions in this doc are reasonable defaults but worth poking at
before implementing:

1. **Host-header routing on a single HAProxy port** vs **one HAProxy port
   per cache type**. Host-header routing keeps a clean single bind and
   makes "switch caches" a one-string change. The downside is that
   experiments that mix two caches concurrently (e.g. half-traffic to
   Zot, half to Distribution) require two daemons or two clients. If
   that turns out to be a common need, we move to one port per cache.

2. **Path-prefix routing (`/r/`, `/z/`, `/n/`) instead of Host headers.**
   This was your original suggestion. We chose Host headers because
   Docker's `registry-mirrors` historically keeps only scheme+host from
   the URL and appends `/v2/...` itself, which means a configured
   `http://localhost:8088/r` is likely to become
   `http://localhost:8088/v2/...` in flight (no `/r/` prefix to ACL on).
   If we find a moby release where path prefixes survive, switching to
   path ACLs is a small HAProxy edit + a one-line `daemon.json` change.

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

---

## 15. Future work

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
