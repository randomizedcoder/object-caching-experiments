# Nix design

This document describes **how the `object-caching-experiments` repository is built in
Nix** — the `flake.nix`, the modular `./nix/` tree, the two NixOS-microvm generators, and
the host-side networking + VM-lifecycle apps that let us deterministically build and boot
the lab from cold.

It does **not** re-explain the caching fabric itself. For *what* the system does (the nginx
two-tier cache, the cache-VM nginx + Zot oracle, MITM/TLS, model stores, tuning) read the
[focused design](focus-design/README.md). Where this doc and the focused design disagree on
names/paths/ports, the [focused design §8–§10](focus-design/03-architecture.md) wins — this
doc is downstream of that contract.

The structure mirrors the sister repos [`ceph-on-k8s`](../../ceph-on-k8s) and
[`nix-k8s-examples`](../../nix-k8s-examples): a small `flake.nix` that imports a modular
`nix/`, parametric microvm generators driven by a single `nix/constants.nix`, host
bridge/TAP setup and VM lifecycle exposed as `nix run .#…` apps.

## Scope

This first cut targets the **three NixOS microvms only**:

| VM        | role     | what it runs                                                           |
|-----------|----------|-----------------------------------------------------------------------|
| `client0` | client   | dockerd + containerd, client OpenResty (two-tier cache + lua HC + :443 MITM), exporters |
| `cache0`  | cache    | shared OpenResty (OCI/apt/model vhosts, all TLS) + Zot ×5 oracle + exporters |
| `cache1`  | cache    | identical to `cache0` (interchangeable)                                |

The **Ubuntu clients (Vagrant + libvirt + Ansible) are deferred** — see
[§14, "What's deferred"](#14-whats-deferred). Get the NixOS client and the two caches
building, booting, and passing the differential test first; the Ubuntu roles reuse the same
`constants.nix` and become much easier once the NixOS path is proven.

## 1. Goals and constraints

- **Reproducible VM images.** Each microvm is a Nix derivation: given the same flake inputs,
  the same bits come out. No imperative provisioning on the VM after boot — config is baked
  in at build time (nginx configs, certs, containerd `hosts.toml`, sysctls).
- **`nix/constants.nix` is the single source of truth.** Every IP, MAC, hostname, port,
  upstream, model-store FQDN, and resource size is defined once (see
  [focused design §10](focus-design/03-architecture.md#10-constants-module-nixconstantsnix)).
  The same data later feeds the Ubuntu/Ansible path via a `nix eval --json` export, so both
  worlds derive from one place.
- **Small `flake.nix`.** The flake declares inputs/outputs and wires generators + apps; all
  real logic lives under `nix/`. Mirrors `ceph-on-k8s/flake.nix`.
- **Dual-generator pattern.** One generator per machine *role* (`microvm-client.nix`,
  `microvm-cache.nix`), each a thin `nixosSystem` returning `microvm.declaredRunner`. New
  VMs are added by appending to `nix/nodes.nix`, never by editing the flake.
- **Secrets generated offline, never committed.** SSH keys and both CA trees are minted into
  `./secrets/` by dedicated apps; `secrets/` is gitignored. Only **public** certs are
  SSH-distributed to peers; private keys never leave `secrets/` (or, for the cache server
  key, the cache VMs).
- **One-command bring-up.** `nix run .#cache-start-all` builds and boots all three VMs from
  cold, the same UX as the sister repos' `*-start-all`.

## 2. Repository layout

The skeleton is prescribed by
[focused design §8](focus-design/03-architecture.md#8-repository-layout); reproduced here
with the Nix-specific (gitignored) working dirs:

```
object-caching-experiments/
├── flake.nix                       # inputs + outputs: generators + apps + devShell
├── flake.lock
├── docs/
│   ├── design.md                   # broad exploration / rationale archive
│   ├── nix-design.md               # THIS FILE — how the repo is built in Nix
│   ├── moby-image-pull-analysis.md # reference: moby pull/unpack behaviour
│   └── focus-design/               # the design we build (the "what")
├── nix/
│   ├── constants.nix               # single source of truth (IPs, MACs, ports, sizes)
│   ├── nodes.nix                   # node registry → flake.nix mapAttrs'
│   ├── microvm-client.nix          # client0 generator
│   ├── microvm-cache.nix           # cache0/cache1 generator
│   ├── secrets.nix                 # null-able reads of ./secrets/ (graceful when absent)
│   ├── secrets-gen.nix             # offline secret/CA generators (apps)
│   ├── network-setup.nix           # host bridge + TAPs + NAT (apps)
│   ├── microvm-scripts.nix         # vm lifecycle apps (start/stop/ssh/wipe/set-hc)
│   ├── modules/
│   │   ├── docker-client.nix       # dockerd (containerd-snapshotter) + hosts.toml
│   │   ├── nginx-client.nix        # client OpenResty: hot tier + hash router + :443 MITM + lua HC
│   │   ├── mitm.nix                # per-client CA trust, /etc/hosts redirection
│   │   ├── ca-injector.nix         # runc prestart hook: CA + /etc/hosts into containers
│   │   ├── zot-oracle.nix          # Zot ×5 (verification oracle, off serving path) + metrics
│   │   ├── nginx-cache.nix         # shared OpenResty: OCI + apt + model vhosts (all TLS)
│   │   ├── sysctls.nix             # kernel network tuning (shared by client + cache)
│   │   └── observability.nix       # node_exporter + nginx exporter
│   └── shell.nix                   # dev shell (openresty, curl, jq, regctl, crane, step-cli)
├── ansible/                        # DEFERRED — ubuntu roles (§14)
├── secrets/                        # GITIGNORED — ssh keys + CAs (secrets/<client>/, secrets/cache/)
└── rendered/                       # GITIGNORED — generated config snapshots for inspection
```

`.gitignore` adds `secrets/`, `rendered/`, and `*-data.img` (the per-VM writable disks the
runner creates in `$PWD`).

## 3. `flake.nix` (small, by design)

Inputs match the sister repos: `nixpkgs` (nixos-unstable), `flake-utils`, and
`astro/microvm.nix` with its nixpkgs pinned to follow ours. Outputs delegate to `nix/`. The
flake walks `nodes.nix` with `lib.mapAttrs'` and emits one
`packages.x86_64-linux.cache-microvm-<name>` per VM; apps are gated on
`pkgs.stdenv.isLinux` (the VMs and host networking are Linux-only).

```nix
{
  description = "object-caching-experiments: pull-through caching fabric on NixOS MicroVMs";

  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url  = "github:numtide/flake-utils";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, microvm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        nixDir    = ./nix;
        pkgs      = nixpkgs.legacyPackages.${system};
        lib       = pkgs.lib;

        constants = import (nixDir + "/constants.nix");
        nodes     = import (nixDir + "/nodes.nix") { inherit constants; };

        # Null-able reads of ./secrets/ — flake still evaluates if absent,
        # the build-time activation scripts fail loudly at boot instead.
        secrets   = import (nixDir + "/secrets.nix") { inherit pkgs lib; };

        # ── One generator per machine role ──────────────────────────────
        mkCacheNode = { nodeName }:
          import (nixDir + "/microvm-cache.nix") {
            inherit pkgs lib microvm nixpkgs system nodeName;
            hostKey     = secrets.hostKeyPath nodeName;   # path|null
            sshPubKey   = secrets.sshPubKey;
            cacheServer = secrets.cacheServer;            # {crt,key} for cacheTls
          };

        mkCacheClient = { nodeName }:
          import (nixDir + "/microvm-client.nix") {
            inherit pkgs lib microvm nixpkgs system nodeName;
            hostKey   = secrets.hostKeyPath nodeName;
            sshPubKey = secrets.sshPubKey;
            mitm      = secrets.clientMitm nodeName;      # per-client CA + per-FQDN leaves
            cacheCa   = secrets.cacheCaCert;              # cache CA public cert (§11.5)
          };

        cachePackages  = lib.mapAttrs' (name: _:
          lib.nameValuePair "cache-microvm-${name}" (mkCacheNode  { nodeName = name; })
        ) nodes.cacheDefinitions;

        clientPackages = lib.mapAttrs' (name: _:
          lib.nameValuePair "cache-microvm-${name}" (mkCacheClient { nodeName = name; })
        ) nodes.clientDefinitions;
      in {
        packages = cachePackages // clientPackages;

        devShells.default = import (nixDir + "/shell.nix") { inherit pkgs; };

        apps = lib.optionalAttrs pkgs.stdenv.isLinux (
          let
            net     = import (nixDir + "/network-setup.nix")  { inherit pkgs constants; };
            vm      = import (nixDir + "/microvm-scripts.nix") { inherit pkgs constants secrets; };
            secgen  = import (nixDir + "/secrets-gen.nix")     { inherit pkgs constants; };
            mkApp   = drv: bin: { type = "app"; program = "${drv}/bin/${bin}"; };
          in {
            cache-check-host       = mkApp net.check       "cache-check-host";
            cache-network-setup    = mkApp net.setup       "cache-network-setup";
            cache-network-teardown = mkApp net.teardown    "cache-network-teardown";
            cache-gen-secrets      = mkApp secgen.secrets  "cache-gen-secrets";
            cache-gen-ca           = mkApp secgen.ca       "cache-gen-ca";
            cache-distribute-trust = mkApp secgen.distrib  "cache-distribute-trust";
            cache-start-all        = mkApp vm.startAll     "cache-start-all";
            cache-vm-ssh           = mkApp vm.ssh          "cache-vm-ssh";
            cache-vm-stop          = mkApp vm.stop         "cache-vm-stop";
            cache-vm-wipe          = mkApp vm.wipe         "cache-vm-wipe";
            cache-set-hc           = mkApp vm.setHc        "cache-set-hc";
            cache-render           = mkApp vm.render       "cache-render";
            cache-diff-test        = mkApp vm.diffTest     "cache-diff-test";
            cache-pull-corpus      = mkApp vm.pullCorpus   "cache-pull-corpus";
            cache-observability-up = mkApp vm.obsUp        "cache-observability-up";
          });
      });
}
```

This is intentionally close to `ceph-on-k8s/flake.nix` — same input set, same `mapAttrs'`
package generation, same `isLinux`-gated apps block, same `declaredRunner` packages.

## 4. `nix/constants.nix` — single source of truth

The full shape is specified in
[focused design §10](focus-design/03-architecture.md#10-constants-module-nixconstantsnix);
this file *is* that block. Highlights the Nix code reads:

- `clientNames = [ "client0" ]`, `cacheNames = [ "cache0" "cache1" ]`,
  `ubuntuNames = [ … ]` (consumed later), `getHostname = node: "cache-${node}"`.
- `network` — `bridge = "cachebr0"`, `gateway4 = "10.44.44.1"`, `gateway6 = "fd44:44:44::1"`,
  `subnet4 = "10.44.44.0/24"`, `subnet6 = "fd44:44:44::/64"`, and the per-node
  `taps`/`ipv4`/`ipv6`/`macs` maps (`client0`=`.10`/`cachetap0`, `cache0`=`.20`/`cachetap1`,
  `cache1`=`.21`/`cachetap2`; MACs `02:00:0a:2c:2c:{10,20,21}`).
- `upstreams` — the five Tier-1 registries → `{ url; zotPort; }` (5050–5054).
- `ports` — `clientOci=8088`, `clientApt=8090`, `clientMitm=443`, `nginxWildcard=8085`,
  `nginxApt=8086`, `nodeExporter=9100`, `nginxExporter=9113`.
- `userAgent`, `cacheTls` (serverName/caCert/serverCert/serverKey), `healthcheck`
  (interval/timeout/fall/rise/probePath/validStatuses), `aptUpstreams`, `modelStores`
  (huggingface/modelscope/pytorch/ollama → kind/nginxPort/fqdns), `mitmExtraHosts`.
- `vmResources = { client = {vcpu=4; mem=6144; dataGiB=80;}; cache = {vcpu=4; mem=8192; dataGiB=300;}; }`.

Following the sister-repo convention, add small helper functions next to the data so modules
don't re-derive lookups, e.g.:

```nix
  # Per-node QEMU console ports (serial + virtio), unique blocks so two VMs
  # never collide on 127.0.0.1. Mirrors ceph-on-k8s/nix/constants.nix.
  getConsolePorts = node:
    let base = 25500 + 10 * (constants.nodeIndex.${node}); in
    { serial = base; virtio = base + 1; };
  getVmResources = role: constants.vmResources.${role};
```

## 5. `nix/nodes.nix` — node registry

A thin map from name → role, split so the flake can pick the right generator (mirrors
`ceph-on-k8s/nix/nodes.nix`'s `definitions` / `clientDefinitions`):

```nix
{ constants }:
{
  cacheDefinitions  = { cache0 = { role = "cache"; }; cache1 = { role = "cache"; }; };
  clientDefinitions = { client0 = { role = "client"; }; };
}
```

Adding `client1` later (or more caches) is a one-line edit here — the flake's `mapAttrs'`
picks it up automatically.

## 6. Microvm generators

Both generators are thin wrappers around `nixpkgs.lib.nixosSystem` that return
`vmConfig.config.microvm.declaredRunner`, exactly like `ceph-on-k8s/nix/microvm-client.nix`.
The **shared scaffolding is identical** between the two (and to the sister template):

- `microvm.hypervisor = "qemu"`; `mem`/`vcpu` from `vmResources` (set `vcpu` to match the
  multi-queue TAP queue count, and avoid exact powers of two — QEMU hangs on some hosts);
- a 9p read-only `/nix/store` share (`tag = "ro-store"`);
- one writable `${hostname}-data.img` volume mounted at `/var/lib` (sized from
  `vmResources.*.dataGiB`);
- a single `tap` interface with `id`/`mac` from `constants.network`;
- serial + virtio consoles on the per-node `getConsolePorts` block;
- a build-time SSH host-key activation script that **fails loudly** if `./secrets/` is
  missing ("run `nix run .#cache-gen-secrets` first");
- static dual-stack addressing via `systemd-networkd` (no DHCP, no IPv6 RA);
- hardened `sshd` (key-only); `networking.firewall.enable = false` (trusted lab subnet).

They differ only in **resources, which NixOS modules they compose, and which secrets they
bake in.**

### 6.1 `nix/microvm-cache.nix`

```nix
{ pkgs, lib, microvm, nixpkgs, system, nodeName, hostKey ? null,
  sshPubKey ? null, cacheServer ? null }:        # cacheServer = { crt; key; } or null
let
  constants = import ./constants.nix;
  hostname  = constants.getHostname nodeName;
  res       = constants.getVmResources "cache";
  nodeIp4   = constants.network.ipv4.${nodeName};
  nodeIp6   = constants.network.ipv6.${nodeName};
  mac       = constants.network.macs.${nodeName};
  tap       = constants.network.taps.${nodeName};

  vmConfig = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      microvm.nixosModules.microvm
      ./modules/nginx-cache.nix       # :8085/:8086/:8100-8104, all TLS (§13, §15)
      ./modules/zot-oracle.nix        # Zot ×5 :5050-5054 (§13.1)
      ./modules/sysctls.nix           # §18.1
      ./modules/observability.nix     # node + nginx exporter (§19)
      ({ config, pkgs, ... }: {
        system.stateVersion   = "26.05";
        nixpkgs.hostPlatform  = system;
        networking.hostName   = hostname;

        microvm = {
          hypervisor = "qemu";
          mem  = res.mem;            # 8192
          vcpu = res.vcpu;           # 4 (matches multi_queue TAP)
          shares  = [{ tag = "ro-store"; source = "/nix/store";
                       mountPoint = "/nix/.ro-store"; proto = "9p"; }];
          volumes = [{ image = "${hostname}-data.img";
                       mountPoint = "/var/lib"; size = res.dataGiB * 1024; }];
          interfaces = [{ type = "tap"; id = tap; mac = mac; }];
          qemu.extraArgs = [ "-name" "${hostname},process=${hostname}" /* + consoles */ ];
        };

        systemd.network.networks."10-tap" = {
          matchConfig.Name = "enp*";
          networkConfig = { Address = [ "${nodeIp4}/24" "${nodeIp6}/64" ];
                            Gateway = constants.network.gateway4;
                            DHCP = "no"; IPv6AcceptRA = false; };
        };

        # Shared cache server cert (same on BOTH cache VMs) — cacheTls (§11.5).
        system.activationScripts.cache-tls = lib.mkIf (cacheServer != null) ''
          install -d -m 0755 /etc/nginx/cache
          install -m 0644 ${cacheServer.crt} /etc/nginx/cache/cache-server.crt
          install -m 0600 ${cacheServer.key} /etc/nginx/cache/cache-server.key
        '';

        # + shared SSH host-key activation, hardened sshd, firewall off
      })
    ];
  };
in vmConfig.config.microvm.declaredRunner
```

### 6.2 `nix/microvm-client.nix`

Same scaffolding; composes the client module set and installs the **per-client MITM CA +
per-FQDN leaves** (`secrets/client0/{ca,mitm}/`) plus the **cache CA public cert**
(`/etc/nginx/cache-ca.crt`, §11.5) at build time:

```nix
  modules = [
    microvm.nixosModules.microvm
    ./modules/docker-client.nix      # dockerd + containerd hosts.toml (§12)
    ./modules/nginx-client.nix       # two-tier + lua HC + :443 MITM (§11)
    ./modules/mitm.nix               # per-client CA trust + /etc/hosts (§14)
    ./modules/ca-injector.nix        # runc prestart hook (§14.4)
    ./modules/sysctls.nix
    ./modules/observability.nix
    ({ ... }: { /* res = getVmResources "client" → 4/6144/80; networkd; sshd; firewall off */
       # mitm.ca → security.pki.certificateFiles; cacheCa → /etc/nginx/cache-ca.crt
    })
  ];
```

## 7. NixOS modules (`nix/modules/`)

Each module is an ordinary NixOS module that reads `constants.nix` and renders config from
it. One subsection each; load-bearing ones get a snippet.

### 7.1 `nginx-cache.nix` → [§13.2](focus-design/05-cache-vms.md#132-nginx-wildcard-oci-catch-all)/[§13.3](focus-design/05-cache-vms.md#133-nginx-apt-cache)/[§15](focus-design/06-mitm-and-content.md#15-llm-model-store-caching)

OpenResty (`services.nginx.package = pkgs.openresty`) serving the shared cache. The wildcard
`:8085`, apt `:8086`, and the four model vhosts `:8100–8104` are all `listen … ssl`
presenting the shared cache cert. The model vhosts are **generated** from
`constants.modelStores` so HF/ModelScope/PyTorch share one template:

```nix
{ config, pkgs, lib, ... }:
let c = import ../constants.nix; in {
  services.nginx = {
    enable = true;
    package = pkgs.openresty;
    appendHttpConfig = ''
      proxy_cache_path /var/lib/cache/nginx/default levels=1:2
        keys_zone=cache_default:100m max_size=100g inactive=30d use_temp_path=off;
      map $uri $blob_digest { ~/blobs/(?<d>sha256:[0-9a-f]+)$ $d; default ""; }
    '';
    virtualHosts = {
      "oci" = {
        listen = [{ addr = "0.0.0.0"; port = c.ports.nginxWildcard; ssl = true; }];
        sslCertificate    = "/etc/nginx/cache/cache-server.crt";
        sslCertificateKey = "/etc/nginx/cache/cache-server.key";
        # locations: blobs key "blob:$blob_digest", manifests key "$ns:$uri",
        #            @follow_cdn for 307s, X-Cache-Status/-Upstream-Time headers
      };
      # apt vhost (:8086) + model vhosts generated from c.modelStores:
    } // lib.mapAttrs' (name: store:
      lib.nameValuePair "model-${name}" {
        listen = [{ addr = "0.0.0.0"; port = store.nginxPort; ssl = true; }];
        sslCertificate    = "/etc/nginx/cache/cache-server.crt";
        sslCertificateKey = "/etc/nginx/cache/cache-server.key";
        # redirect-following + host:path key (kind=http) or digest key (kind=oci)
      }) c.modelStores;
  };
}
```

### 7.2 `zot-oracle.nix` → [§13.1](focus-design/05-cache-vms.md#131-zot-verification-oracle)

Five Zot instances, **one per `constants.upstreams` entry**, on 5050–5054, each `onDemand`
pull-through with `gc = true` and `extensions.metrics.enable = true`. Off the serving path —
only the differential test (`cache-diff-test`) hits them. Generated with `mapAttrs` over
`upstreams` so adding a registry adds an oracle automatically.

### 7.3 `nginx-client.nix` → [§11.1–§11.4](focus-design/04-client.md#11-client-architecture-nginx-two-tier-cache)

The client OpenResty: a small local hot-tier `proxy_cache` in front of a consistent-hash
`upstream { hash $cache_key consistent; server cache0; server cache1; keepalive 32; }`; the
in-process active health-check in `init_worker_by_lua_block` (params from
`constants.healthcheck`, `type = "https"` since the cache listeners are TLS); the
`proxy_ssl_*` block (cache CA trust + `proxy_ssl_name = constants.cacheTls.serverName`); the
`proxy_set_header User-Agent constants.userAgent`; the `X-Cache-Hot`/`X-Cache-Time`
response headers; and the `:443` MITM frontend (H3+H2, per-FQDN certs, SNI-routed to the
cache model vhosts). The OCI `:8088` and apt `:8090` frontends are the containerd /
`Acquire::http::Proxy` targets.

### 7.4 `docker-client.nix` → [§12](focus-design/04-client.md#12-containerd-client-config-unmodified-dockerfiles)

`virtualisation.docker` on the containerd image store, plus
`/etc/containerd/certs.d/<registry>/hosts.toml` generated from `constants.upstreams` (one
per Tier-1) and a `_default` wildcard, each pointing at the client nginx `:8088` with the
`ns=` capability — so users' Dockerfiles stay unmodified.

### 7.5 `mitm.nix` / `ca-injector.nix` → [§14](focus-design/06-mitm-and-content.md#14-https-interception-internal-ca--mitm)

`mitm.nix` installs the **per-client** root CA into `security.pki.certificateFiles` and
writes `/etc/hosts` entries mapping every `modelStores.*.fqdns` + `mitmExtraHosts` host to
`127.0.0.1`. `ca-injector.nix` registers a runc prestart hook that bind-mounts *this host's*
CA and `/etc/hosts` into every container, so in-container pulls trust the same MITM. (This
per-client MITM CA is **distinct** from the cache CA of §11.5.)

### 7.6 `sysctls.nix` → [§18.1](focus-design/07-tuning-observability.md#181-kernel--network-sysctls-all-machines) · `observability.nix` → [§19](focus-design/07-tuning-observability.md#19-observability-prometheus)

`sysctls.nix` sets the TCP-buffer / bbr / connection-table / fd-limit knobs via
`boot.kernel.sysctl` (shared by client and cache). `observability.nix` enables
`services.prometheus.exporters.node` and `…exporters.nginx` (with `stub_status`) on every
machine.

## 8. Secrets & CA (offline + build-time)

Two independent trust trees, both minted offline and read **null-ably** by `nix/secrets.nix`
(the flake evaluates fine when `./secrets/` is absent; the VM's activation script fails
loudly at boot, the sister-repo pattern):

| tree | path | minted by | distributed |
|---|---|---|---|
| per-client **MITM CA** + per-FQDN leaves | `secrets/<client>/{ca,mitm}/` | `cache-gen-ca` | baked into that client's image only |
| **cache CA** + shared server cert/key | `secrets/cache/{ca,server}/` | `cache-gen-ca` | CA cert → every client; server cert+key → both cache VMs |

Apps (in `nix/secrets-gen.nix`):

- **`cache-gen-secrets`** — SSH host + user keys into `secrets/` (prereq for any VM boot).
- **`cache-gen-ca`** — mints the per-client MITM CA + per-FQDN leaves (from the union of
  `modelStores.*.fqdns` and `mitmExtraHosts`) **and** the lab-wide cache CA + one shared
  cache server cert (SAN = `cacheTls.serverName` + both cache IPs).
- **`cache-distribute-trust`** — over SSH, pushes the **cache CA public cert** to each
  client's `/etc/nginx/cache-ca.crt` and the **server cert+key** to both cache VMs. Private
  keys never leave `secrets/` / the cache VMs. Runs as part of `cache-start-all`.

## 9. Host networking (`nix/network-setup.nix`)

Lifted from `nix-k8s-examples/nix/network-setup.nix` **minus** the apiserver-HAProxy
section (we have no HA control plane). Creates `cachebr0` with the gateway IPs, three
`cachetap{0..2}` with `multi_queue` (+ `vhost-net`), nftables masquerade for the v4/v6
subnets, and enables IP forwarding. Exposed as three apps:

- `cache-check-host` — verify `/dev/net/tun`, vhost-net, bridge module, sudo.
- `cache-network-setup` — create bridge + TAPs + NAT (needs sudo).
- `cache-network-teardown` — remove them.

Ubuntu VMs attach to `cachebr0` directly via libvirt (no host TAP) when that path lands.

## 10. VM lifecycle (`nix/microvm-scripts.nix`)

Sister-repo script pattern (build the package → run `microvm-run` in the background →
`pgrep` to check/stop). Apps:

- `cache-start-all` — build + boot `client0`, `cache0`, `cache1` (caches first), then run
  `cache-distribute-trust`.
- `cache-vm-ssh -- --node=cache0 -- <cmd>` — sshpass/known-hosts into a VM and run a command.
- `cache-vm-stop -- --node=…` / `cache-vm-wipe -- --node=…` — stop one VM / delete its
  `*-data.img` for a cold run.
- `cache-set-hc -- --client=… --mode=passive|active` — toggle the active lua health-check
  ([§11.3](focus-design/04-client.md#113-health-checking-passive-and-in-process-active)).
- `cache-render` — render all configs into `rendered/` for `git diff`; `cache-diff-test` —
  the nginx-vs-Zot equivalence assertion
  ([§20](focus-design/08-operations.md#20-build-and-run-workflow)).
- `cache-pull-corpus` — pre-warm the caches with the test corpus (container images, model
  blobs, apt) so a benchmark runs against a warm store; `cache-observability-up` — bring up
  the Prometheus + Grafana scrape stack
  ([§19](focus-design/07-tuning-observability.md#19-observability-prometheus)).

## 11. Dev shell (`nix/shell.nix`)

`devShells.default` with the tools for poking the lab by hand: `openresty`, `curl`, `jq`,
`regctl`/`crane` (OCI), `step-cli` (certs), `nftables`, `qemu`.

## 12. Build & run flow (happy path)

```bash
nix run .#cache-check-host             # verify tun / vhost-net / bridge
sudo nix run .#cache-network-setup     # cachebr0 + cachetap0..2 + NAT
nix run .#cache-gen-secrets            # SSH host + user keys → ./secrets/
nix run .#cache-gen-ca                 # per-client MITM CA + cache CA + shared server cert
nix run .#cache-start-all              # build + boot client0, cache0, cache1 (+ distribute-trust)
nix run .#cache-vm-ssh -- --node=cache0 -- systemctl status nginx
nix run .#cache-diff-test              # nginx vs Zot oracle equivalence
# teardown:
nix run .#cache-vm-stop -- --node=cache0
sudo nix run .#cache-network-teardown
```

## 13. What's done by Nix vs. baked at build time

Everything the VM needs is in its Nix closure: the nginx/OpenResty config, containerd
`hosts.toml`, sysctls, the CA trust, and the server/leaf certs (installed by activation
scripts from `./secrets/`). There is **no runtime provisioning** — a booted VM is fully
configured. The only post-boot step is `cache-distribute-trust`, which copies *public* certs
between already-running peers over SSH (it can't be baked because it crosses machines).

## 14. What's deferred

The **Ubuntu clients** (`ubuntu2204`/`ubuntu2404`/`ubuntu2604`) are out of scope for this
first cut. They will be provisioned by **Vagrant + libvirt** (attached to `cachebr0`) and
configured by **Ansible roles** under `ansible/roles/` (`docker`, `nginx-client` (OpenResty),
`mitm-trust`, containerd `hosts.toml`, `sysctls`, `node_exporter`) — the same logical config
as `client0`, expressed as Ansible instead of NixOS modules, and fed the **same**
`constants.nix` via a `nix eval --json` export (the `ubuntu-render` app). The two paths must
produce semantically-equivalent end state; see
[focused design §16](focus-design/06-mitm-and-content.md#16-ubuntu-clients). Tackling this
after the NixOS path is proven is deliberate — the constants, certs, and config shapes will
already be settled, so the Ansible roles are mostly translation.
