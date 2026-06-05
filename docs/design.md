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
6. [Constants Module (`nix/constants.nix`)](#6-constants-module-nixconstantsnix)
7. [MicroVM Definitions](#7-microvm-definitions)
8. [Cache Services on the Cache MicroVMs](#8-cache-services-on-the-cache-microvms)
   1. [Docker Distribution registry (proxy mode)](#81-docker-distribution-registry-proxy-mode)
   2. [Zot](#82-zot)
   3. [Nginx as an HTTP proxy cache](#83-nginx-as-an-http-proxy-cache)
9. [Client-side HAProxy: health checks and consistent hashing](#9-client-side-haproxy-health-checks-and-consistent-hashing)
10. [Client-side Docker daemon configuration](#10-client-side-docker-daemon-configuration)
    1. [`registry-mirrors` vs `insecure-registries`](#101-registry-mirrors-vs-insecure-registries)
    2. [Switching the cache under test](#102-switching-the-cache-under-test)
11. [Build and run workflow](#11-build-and-run-workflow)
12. [Design choices to validate](#12-design-choices-to-validate)
13. [Future work](#13-future-work)

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

## 6. Constants Module (`nix/constants.nix`)

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

## 7. MicroVM Definitions

### 7.1 Common shape

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

### 7.2 What each VM runs

| VM             | NixOS modules                                                       |
|----------------|---------------------------------------------------------------------|
| `cache-client0`| `dockerd`, `haproxy` (frontend `:8088` + 7 backends), `regctl`/`crane` for ad-hoc pulls |
| `cache-client1`| same as `client0`                                                   |
| `cache-cache0` | `distribution` ×2 (`:5000` docker, `:5001` gcr), `zot` ×2 (`:5050`, `:5051`), `nginx` ×3 (`:8080`, `:8081`, `:8082`) |
| `cache-cache1` | same as `cache0` (identical config — they are intentionally interchangeable so consistent hashing makes sense) |

The two clients are also identical to each other. A second client exists
so we can demonstrate cache locality (same image, two clients → second
pull should hit the warm cache regardless of which client requested first).

### 7.3 Data disks

Each VM gets a single `<hostname>-data.img` mounted at `/var/lib`:

- Client VMs: `/var/lib/docker` (image layers), `/var/lib/haproxy`.
- Cache VMs: `/var/lib/cache/{distribution,zot,nginx}`.

We do **not** need the second raw disk that `ceph-on-k8s` uses for OSDs.
A flake app `cache-vm-wipe` deletes the `.img` files for a clean run, the
same way `k8s-vm-wipe` does in the sister repos.

---

## 8. Cache Services on the Cache MicroVMs

### 8.1 Docker Distribution registry (proxy mode)

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

### 8.2 Zot

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

### 8.3 Nginx as an HTTP proxy cache

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

---

## 9. Client-side HAProxy: health checks and consistent hashing

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

## 10. Client-side Docker daemon configuration

### 10.1 `registry-mirrors` vs `insecure-registries`

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

### 10.2 Switching the cache under test

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

## 11. Build and run workflow

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

## 12. Design choices to validate

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

---

## 13. Future work

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
