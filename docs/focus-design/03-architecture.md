[← Contents](README.md)

**Repository layout, network topology, and constants.** Part of the [focused design](README.md).

---

## 8. Repository Layout

```
object-caching-experiments/
├── flake.nix                       # inputs + flake apps + microvm packages
├── flake.lock
├── docs/
│   ├── design.md                   # broad exploration / rationale archive
│   └── focused-design.md           # THIS FILE — the design we build
├── nix/
│   ├── constants.nix               # single source of truth (IPs, MACs, ports, sizes)
│   ├── nodes.nix                   # node registry → consumed by flake.nix mapAttrs'
│   ├── microvm-client.nix          # client0 generator (docker + openresty + exporters)
│   ├── microvm-cache.nix           # cache0/cache1 generator (openresty + zot-oracle + exporters)
│   ├── network-setup.nix           # host bridge + TAPs + NAT (apps)
│   ├── microvm-scripts.nix         # vm lifecycle apps (start/stop/ssh/wipe)
│   ├── modules/
│   │   ├── docker-client.nix       # dockerd (containerd-snapshotter) + hosts.toml
│   │   ├── nginx-client.nix        # client OpenResty: local hot tier + hash router + :443 MITM/H3 + lua healthcheck
│   │   ├── mitm.nix                # internal CA trust, /etc/hosts redirection
│   │   ├── ca-injector.nix         # runc prestart hook: CA + /etc/hosts into containers
│   │   ├── zot-oracle.nix          # Zot ×5 (verification oracle, off serving path) + metrics
│   │   ├── nginx-cache.nix         # shared OpenResty: OCI + apt + model-store vhosts + stub_status
│   │   ├── sysctls.nix             # kernel network tuning (shared by client + cache)
│   │   └── observability.nix       # node_exporter + nginx exporter
│   └── shell.nix                   # dev shell (openresty, curl, jq, regctl, crane)
├── ansible/
│   └── roles/                      # ubuntu: docker, nginx-client (openresty), mitm-trust, node_exporter, hosts.toml, sysctls
├── secrets/                        # ssh keys + per-client internal CA + per-FQDN certs (secrets/<client>/{ca,mitm}/)
└── rendered/                       # generated config snapshots for inspection
```

Two microvm generators (`microvm-client.nix`, `microvm-cache.nix`) mirror the dual-generator pattern in `ceph-on-k8s`. `flake.nix` walks `nodes.nix` and emits one `packages.x86_64-linux.cache-microvm-<name>` per VM. The Ubuntu clients are provisioned by Vagrant+libvirt and configured by Ansible (see [§16](06-mitm-and-content.md#16-ubuntu-clients)); the same logical config (containerd `hosts.toml`, client OpenResty with in-process Lua health-checks, MITM trust, sysctls, node_exporter) is expressed twice — NixOS modules for `client0`, Ansible roles for the Ubuntu boxes — and must produce semantically equivalent end state.

The detailed Nix implementation design — the small `flake.nix`, every `nix/` module, the two microvm generators, and the secrets/CA + host-networking + VM-lifecycle apps — lives in [`../nix-design.md`](../nix-design.md). This section is the contract it realizes; that doc is the how.

---

## 9. Network Topology

A dedicated bridge isolates this lab from `nix-k8s-examples` / `ceph-on-k8s` (both on `10.33.33.0/24`).

| name      | value                          |
|-----------|--------------------------------|
| bridge    | `cachebr0`                     |
| IPv4 net  | `10.44.44.0/24`                |
| IPv4 gw   | `10.44.44.1` (bridge)          |
| IPv6 net  | `fd44:44:44::/64` (ULA)        |
| IPv6 gw   | `fd44:44:44::1` (bridge)       |

| VM           | attach                                | IPv4          | IPv6              | MAC                 |
|--------------|---------------------------------------|---------------|-------------------|---------------------|
| `client0`    | `cachetap0` (microvm)                 | `10.44.44.10` | `fd44:44:44::10`  | `02:00:0a:2c:2c:10` |
| `cache0`     | `cachetap1` (microvm)                 | `10.44.44.20` | `fd44:44:44::20`  | `02:00:0a:2c:2c:20` |
| `cache1`     | `cachetap2` (microvm)                 | `10.44.44.21` | `fd44:44:44::21`  | `02:00:0a:2c:2c:21` |
| `ubuntu2204` | bridge (Vagrant libvirt `:dev=>cachebr0`) | `10.44.44.30` | `fd44:44:44::30` | `02:00:0a:2c:2c:30` |
| `ubuntu2404` | bridge (Vagrant libvirt)              | `10.44.44.31` | `fd44:44:44::31`  | `02:00:0a:2c:2c:31` |
| `ubuntu2604` | bridge (Vagrant libvirt)              | `10.44.44.32` | `fd44:44:44::32`  | `02:00:0a:2c:2c:32` |

> Note: with only one NixOS client, the TAP numbering compacts — `client0=cachetap0`, `cache0=cachetap1`, `cache1=cachetap2` (three TAPs instead of the broad doc's four). Ubuntu VMs attach to `cachebr0` directly via libvirt — no host-side TAP.

Host setup (once per boot, `sudo nix run .#cache-network-setup`): create `cachebr0` + assign gateway IPs; create `cachetap{0..2}`; nftables masquerade for the v4/v6 subnets; enable IP forwarding. Pattern lifted verbatim from `nix-k8s-examples/nix/network-setup.nix` minus the apiserver-HAProxy section.

### 9.1 Port map

**Client-side (identical on `client0` and all 3 Ubuntu clients):**

| port  | service                  | role                                                   |
|-------|--------------------------|--------------------------------------------------------|
| `8088`| nginx (client)           | OCI frontend — containerd `hosts.toml` target (local hot tier + hash router) |
| `8090`| nginx (client)           | apt-proxy frontend — `Acquire::http::Proxy` target (local hot tier + hash router) |
| `443` | nginx (client)           | **HTTPS MITM frontend** — SNI-routed model stores + HTTPS repos, H3+H2 ([§14](06-mitm-and-content.md#14-https-interception-internal-ca--mitm)) |
| `9100`| node_exporter            | host metrics                                           |
| `9113`| nginx-prometheus-exporter| client nginx metrics (scrapes `stub_status`)          |

> The `:443` MITM frontend is reached because `/etc/hosts` on each client (and inside each container, via the runc hook) maps the model-store / HTTPS-repo FQDNs to `127.0.0.1`. The **client nginx** terminates TLS with a per-FQDN cert (internal CA) and routes by SNI — there is no separate `crt-list`/hitch sidecar anymore; one nginx does TLS termination, the local hot cache, and the hash to the shared layer. See [§14.3](06-mitm-and-content.md#143-dns-redirection--tls-termination-at-the-client-nginx).

**Cache-VM-side (identical on `cache0` and `cache1`).** The client-facing nginx ports below (`8085`/`8086`/`8100`–`8104`) are **TLS listeners** presenting the shared cache server cert (cache CA, [§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)); the Zot/exporter ports are unchanged.

| port          | service                     | upstream / role                                          |
|---------------|-----------------------------|---------------------------------------------------------|
| `5050`–`5054` | Zot (one per Tier-1)        | `docker.io`, `gcr.io`, `ghcr.io`, `quay.io`, `registry.k8s.io` |
| `8085`        | nginx wildcard              | `_default` OCI catch-all — dynamic `proxy_pass https://$arg_ns` |
| `8086`        | nginx apt cache             | `archive.ubuntu.com`, `security.ubuntu.com` (HTTP)      |
| `8100`        | nginx model store           | `huggingface.co` + `cdn-lfs*.huggingface.co` ([§15.2](06-mitm-and-content.md#152-hugging-face))    |
| `8101`        | nginx model store           | `modelscope.cn` + its file CDN ([§15.4](06-mitm-and-content.md#154-modelscope-and-pytorch-hub))                  |
| `8102`        | nginx model store           | `download.pytorch.org` + GitHub release assets ([§15.4](06-mitm-and-content.md#154-modelscope-and-pytorch-hub))  |
| `8103`        | nginx model store (OCI)     | `registry.ollama.ai` — OCI-style, digest-keyed ([§15.3](06-mitm-and-content.md#153-ollama))  |
| `8104`        | nginx MITM HTTP repos       | `download.docker.com` and other `mitmExtraHosts` ([§14](06-mitm-and-content.md#14-https-interception-internal-ca--mitm))  |
| `9100`        | node_exporter               | host metrics                                            |
| `9113`        | nginx-prometheus-exporter   | scrapes nginx `stub_status`                             |
| (`/metrics`)  | Zot built-in                | per-Zot-instance Prometheus metrics (same listen port)  |

The model-store traffic is decrypted of its *origin* TLS at the client nginx ([§14](06-mitm-and-content.md#14-https-interception-internal-ca--mitm)) and then re-encrypted to the cache VMs under the **cache CA** ([§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)), consistent-hashed by the client nginx exactly like OCI/apt traffic, so the same model file always lands on the same cache VM.

---

## 10. Constants Module (`nix/constants.nix`)

Single source of truth. Sketch:

```nix
rec {
  clientNames = [ "client0" ];                 # only one NixOS client now
  cacheNames  = [ "cache0" "cache1" ];
  ubuntuNames = [ "ubuntu2204" "ubuntu2404" "ubuntu2604" ];
  getHostname = node: "cache-${node}";

  network = {
    bridge   = "cachebr0";
    gateway4 = "10.44.44.1";  gateway6 = "fd44:44:44::1";
    subnet4  = "10.44.44.0/24"; subnet6 = "fd44:44:44::/64";
    taps     = { client0 = "cachetap0"; cache0 = "cachetap1"; cache1 = "cachetap2"; };
    ipv4 = {
      client0 = "10.44.44.10";
      cache0  = "10.44.44.20"; cache1 = "10.44.44.21";
      ubuntu2204 = "10.44.44.30"; ubuntu2404 = "10.44.44.31"; ubuntu2604 = "10.44.44.32";
    };
    # ipv6/macs analogous
  };

  # The five Tier-1 OCI registries + their cache port offset
  upstreams = {
    "docker.io"       = { url = "https://registry-1.docker.io"; zotPort = 5050; };
    "gcr.io"          = { url = "https://gcr.io";               zotPort = 5051; };
    "ghcr.io"         = { url = "https://ghcr.io";              zotPort = 5052; };
    "quay.io"         = { url = "https://quay.io";              zotPort = 5053; };
    "registry.k8s.io" = { url = "https://registry.k8s.io";      zotPort = 5054; };
  };

  ports = {
    clientOci  = 8088;                            # client nginx OCI frontend
    clientApt  = 8090;                            # client nginx apt frontend
    clientMitm = 443;                             # §14 HTTPS termination (H3+H2)
    nginxWildcard = 8085;  nginxApt = 8086;       # shared cache layer (TLS, §11.5)
    nodeExporter  = 9100;  nginxExporter = 9113;
  };

  # User-Agent the client nginx sends on every upstream request (§11.1).
  # Single point of change; cache VMs pass it through so origins see it too.
  userAgent = "Custom Nginx Proxy/caching";

  # TLS on the client→cache hop (§11.5). A dedicated *cache CA* signs ONE
  # shared cache server cert deployed to BOTH (interchangeable) cache VMs;
  # every client trusts the cache CA and verifies (proxy_ssl_verify on).
  # NB: this is a SEPARATE trust system from the per-client MITM CA (§14.2) —
  # the cache CA only authenticates the cache layer, it never forges origins.
  cacheTls = {
    enable     = true;
    serverName = "caches.cache.lab";                       # shared SAN; proxy_ssl_name
    caCert     = "secrets/cache/ca/cache-CA.crt";          # public; SSH-copied to every client
    serverCert = "secrets/cache/server/cache-server.crt";  # same cert on both cache VMs
    serverKey  = "secrets/cache/server/cache-server.key";  # cache VMs only; never leaves them
    # SAN also covers both cache IPs (network.ipv4.cache0/cache1) so a by-IP
    # upstream peer still validates against the stable serverName.
  };

  # In-process active health-check (lua-resty-upstream-healthcheck, §11.3).
  healthcheck = {
    interval     = 2000;                   # ms between probes
    timeout      = 1000;                   # ms per probe
    fall         = 3;                      # consecutive failures → down (hysteresis)
    rise         = 2;                      # consecutive successes → up
    probePath    = "/v2/";                 # OCI liveness; "/health" for apt/wildcard vhosts
    validStatuses = [ 200 401 404 ];       # registry liveness answers
  };

  # apt mirrors to cache (HTTP only — see §17)
  aptUpstreams = [ "archive.ubuntu.com" "security.ubuntu.com" "ports.ubuntu.com" ];

  # LLM model stores (§15). `kind`=http → MITM + nginx HTTP cache;
  # kind=oci → MITM + nginx OCI/digest-keyed cache. `fqdns` are the hosts
  # we /etc/hosts-redirect and mint MITM certs for. `nginxPort` is the
  # cache-VM vhost that serves it.
  modelStores = {
    huggingface = { kind = "http"; nginxPort = 8100;
      fqdns = [ "huggingface.co" "cdn-lfs.huggingface.co" "cdn-lfs-us-1.huggingface.co" ]; };
    modelscope  = { kind = "http"; nginxPort = 8101;
      fqdns = [ "modelscope.cn" "www.modelscope.cn" "modelscope.oss-cn-beijing.aliyuncs.com" ]; };
    pytorch     = { kind = "http"; nginxPort = 8102;
      fqdns = [ "download.pytorch.org" "github.com" "objects.githubusercontent.com" ]; };
    ollama      = { kind = "oci";  nginxPort = 8103;
      fqdns = [ "registry.ollama.ai" ]; };
  };

  # Everything we MITM = model-store fqdns + HTTPS third-party repos.
  mitmExtraHosts = [ "download.docker.com" ];

  vmResources = {
    client = { vcpu = 4; mem = 6144; dataGiB = 80; };   # docker + openresty local hot cache
    cache  = { vcpu = 4; mem = 8192; dataGiB = 300; };  # nginx cache + zot oracle (model files are large)
  };
}
```

Both the NixOS modules and the Ansible templating read the **same** `upstreams` / `ports` / `modelStores` data (Ansible via a small `nix eval --json` export in the `ubuntu-render` app), so every host list is defined exactly once. The `secrets/` CA + per-FQDN certs ([§14](06-mitm-and-content.md#14-https-interception-internal-ca--mitm)) are minted from the union of `modelStores.*.fqdns` and `mitmExtraHosts`.

---
