# `nix/` — the NixOS-microvm caching lab

This directory holds the Nix implementation of the object-caching-experiments
lab: a small [`../flake.nix`](../flake.nix) plus the modular `nix/` tree that
deterministically **builds and boots three NixOS MicroVMs** which do
pull-through caching of OCI images, apt packages, and LLM model files.

| VM        | role   | what it runs                                                     |
|-----------|--------|------------------------------------------------------------------|
| `client0` | client | dockerd + containerd, client OpenResty (two-tier cache), exporters |
| `cache0`  | cache  | shared OpenResty (OCI/apt/model vhosts) + Zot ×5 oracle + exporters |
| `cache1`  | cache  | identical to `cache0` (interchangeable)                          |

> **Status:** the lab boots and serves. The three MicroVMs build, boot, and accept
> key-only SSH; the serving path (nginx two-tier caching, Zot oracle, client→cache
> TLS hop), MITM/model-store interception, and **bare-metal Ubuntu clients** (via
> [numtide/system-manager](https://github.com/numtide/system-manager)) are all
> implemented. See [`../docs/nix-design.md`](../docs/nix-design.md) for the full
> design and [`../docs/focus-design/`](../docs/focus-design/) for *what* the fabric does.

---

## Quick start

You need: **Linux with KVM**, **Nix with flakes enabled**, and **sudo** (for
host networking only). All commands run from the repo root.

```bash
# 0. (optional) drop into the dev shell with all the poking tools
nix develop

# 1. verify the host can run MicroVMs (tun / vhost-net / bridge / sudo)
nix run .#cache-check-host

# 2. create the host bridge, TAPs, and NAT (needs sudo — networking only)
sudo nix run .#cache-network-setup

# 3. mint SSH host + user keys into ./secrets/ (required before any boot)
nix run .#cache-gen-secrets

# 4. build + boot all three VMs (caches first, then the client)
nix run .#cache-start-all

# 5. SSH into a VM (key-only, baked known_hosts)
nix run .#cache-vm-ssh -- --node=cache0 -- uptime
```

Teardown:

```bash
nix run .#cache-vm-stop -- --node=cache0       # stop one VM
nix run .#cache-vm-wipe -- --node=cache0       # stop + delete its data disk (cold next boot)
sudo nix run .#cache-network-teardown          # remove bridge + TAPs + NAT
```

> **What runs where:** steps 1–5 are safe to run as your normal user; only
> `cache-network-setup` / `-teardown` need `sudo` (they touch host kernel
> networking). Secrets are generated locally into `./secrets/` and are
> **gitignored** — private keys never leave your machine.

> **Why two `--` ?** `nix run .#cache-vm-ssh -- --node=cache0 -- uptime`: the
> *first* `--` ends Nix's own arguments and starts the app's; the *second* ends
> the app's flags (`--node=…`) and starts the command to run on the VM (`uptime`).

---

## How a pull flows (the 30-second mental model)

A `docker pull` on a client never talks to the upstream registry directly:

```
docker/containerd  →  /etc/containerd/certs.d/<registry>/hosts.toml  (mirror rewrite)
                   →  client nginx :8088   (local hot tier — LRU on the client)
                   →  consistent-hash      (which shared cache owns this object?)
                   →  cache0 / cache1 nginx (shared warm tier, TLS hop under the cache CA)
                   →  upstream registry     (only on a cold miss)
```

The same fan-out serves apt packages and LLM model files (HuggingFace, ModelScope,
PyTorch, Ollama) on their own nginx vhosts. HTTPS origins the lab needs to cache are
**MITM-terminated** at a local listener (per-node CA, trusted into the system store);
[`modules/`](modules/) holds one file per role in that path. Everything above is driven
by [`constants.nix`](constants.nix) — change a port or upstream there, never in a module.

---

## How the flake is wired

[`../flake.nix`](../flake.nix) is deliberately small: it declares inputs,
imports the modular `nix/` tree, and exposes three kinds of output.

```
inputs:  nixpkgs (nixos-unstable) · flake-utils · microvm (astro/microvm.nix)

outputs (per system):
  packages.<system>.cache-microvm-<name>   ← one bootable runner per VM
  devShells.<system>.default               ← the dev shell (nix/shell.nix)
  apps.<system>.cache-*                     ← lifecycle / setup commands (Linux only)
```

The flake walks [`nodes.nix`](nodes.nix) with `lib.mapAttrs'`, sending each
`cacheDefinitions` entry through the **cache generator** and each
`clientDefinitions` entry through the **client generator**, emitting one
`cache-microvm-<name>` package each. Add a VM by adding a line to `nodes.nix` —
never by editing the flake.

Everything is driven from [`constants.nix`](constants.nix), the single source
of truth for IPs, MACs, ports, upstreams, model-store FQDNs, and VM sizes.

---

## Targets reference

### Packages (`nix build .#<name>`)

| target                  | builds                                              |
|-------------------------|-----------------------------------------------------|
| `cache-microvm-cache0`  | bootable runner for the `cache0` VM                 |
| `cache-microvm-cache1`  | bootable runner for the `cache1` VM                 |
| `cache-microvm-client0` | bootable runner for the `client0` VM                |

Each builds a `microvm.declaredRunner`; run it directly with
`./result/bin/microvm-run`, or let `cache-start-all` build and launch all three.

### Dev shell (`nix develop`)

`devShells.default` ([`shell.nix`](shell.nix)) provides `openresty`, `curl`,
`jq`, `regctl`, `crane`, `step-cli`, `nftables`, and `qemu` for inspecting the
lab by hand.

### Apps (`nix run .#<name>`)

Apps are Linux-only (gated on `pkgs.stdenv.isLinux`).

| app                      | needs sudo | what it does                                                     |
|--------------------------|:----------:|-----------------------------------------------------------------|
| `cache-check-host`       |     no     | verify `/dev/net/tun`, vhost-net, bridge module, sudo access     |
| `cache-network-setup`    |   **yes**  | create `cachebr0` + `cachetap0..2` (multi_queue + vhost-net) + NAT |
| `cache-network-teardown` |   **yes**  | remove the bridge, TAPs, and NAT table                          |
| `cache-gen-secrets`      |     no     | mint SSH host + user keys + `known_hosts` into `./secrets/`      |
| `cache-gen-ca`           |     no     | mint the cache CA + per-client MITM trees into `./secrets/`; `-- --force` rotates; `-- --mitm-only --node=<name>` mints just one node's MITM tree (see below) |
| `cache-start-all`        |     no     | build + boot `cache0`, `cache1`, then `client0` (skips running VMs) |
| `cache-distribute-trust` |     no     | push the public cache CA cert to all clients over SSH and reload nginx |
| `cache-vm-ssh`           |     no     | key-only SSH into a VM: `-- --node=<name> [-- <command>]`        |
| `cache-vm-stop`          |     no     | stop one VM: `-- --node=<name>`                                  |
| `cache-vm-wipe`          |     no     | stop a VM and delete its data disks (cold next boot): `-- --node=<name>` |
| `cache-set-hc`           |     no     | toggle client active health-checking: `-- --state=on\|off`      |
| `cache-diff-test`        |     no     | three-way probe (upstream vs nginx cache vs Zot oracle) asserting digests match |
| `cache-load-loop`        |     no     | soak/hit-rate loop (pull → run → teardown → re-pull); tallies per-store `cs=HIT/MISS` from the §19 split access logs |

`<name>` is one of `client0`, `cache0`, `cache1`.

> **`cache-gen-ca --mitm-only --node=<name>`** mints **only** a single node's MITM
> tree, reusing a copied-in public `cache-CA.crt` (and never touching the cache CA
> private key) — this is what the bare-metal Ubuntu bootstrap runs on the box. The
> cache CA is lab-global (clients receive only its *public* cert, for the client→cache
> TLS verify); each node's MITM CA is per-box and self-signed, so a box mints its own
> offline. Re-run with `--force` to rotate; both paths are idempotent otherwise.

### Ubuntu clients (libvirt VMs + bare metal)

| app                    | what it does                                                       |
|------------------------|-------------------------------------------------------------------|
| `cache-ubuntu-up`      | boot a pinned Ubuntu cloud image under libvirt: `-- --node=ubuntu2404` |
| `cache-ubuntu-ssh`     | SSH into an Ubuntu VM: `-- --node=<name> [-- <command>]`          |
| `cache-ubuntu-down`    | destroy an Ubuntu VM: `-- --node=<name> [--purge]`               |
| `cache-ubuntu-deploy`  | rsync this repo to a **real** Ubuntu box (excludes `secrets/`, copies only the public `cache-CA.crt`) and run `ubuntu/bootstrap.sh`: `-- --host=user@<box>` |

Ubuntu clients reuse the same Nix modules as `client0` via
[numtide/system-manager](https://github.com/numtide/system-manager). The verb that
**applies** the config is `system-manager switch --flake .#ubuntu-client`, **not**
`nix build` (which only realizes a store path and writes nothing to `/etc`). On a
bare-metal box, `ubuntu/bootstrap.sh` does the full sequence (ensure Nix+Docker,
`cache-gen-ca --mitm-only`, `system-manager switch`, restart docker); see
[§16](../docs/focus-design/06-mitm-and-content.md#16-ubuntu-clients).

---

## File map

| file                          | purpose                                                        |
|-------------------------------|----------------------------------------------------------------|
| `constants.nix`               | single source of truth: merges `constants/*.nix` into one flat namespace (a lazy `self` fixpoint) |
| `constants/network.nix`       | node sets, dual-stack IP/MAC/tap topology, upstream OCI registries |
| `constants/images.nix`        | pinned Ubuntu cloud-image releases (isolated — the only time-sensitive data) |
| `constants/app.nix`           | port map, upstream User-Agent, health-check tunables, apt mirrors, model stores |
| `constants/security.nix`      | cache-CA TLS config + per-client MITM cert groups (derived from model stores) |
| `constants/resources.nix`     | console ports, vcpu/mem, full ZFS pool layout + ARC/L2ARC/ZIL tuning |
| `sysctl-values.nix`           | kernel/network tuning *data* (shared by the NixOS module + the Ubuntu drop-in) |
| `nodes.nix`                   | node registry → which generator the flake uses per VM           |
| `lib/mk-microvm-node.nix`     | shared MicroVM scaffold (boot/SSH/networkd/ZFS/observability) both roles build on |
| `lib/mitm-hosts.nix`          | the one builder for the MITM `/etc/hosts` block (NixOS + Ubuntu agree by construction) |
| `lib/render-sysctl.nix`       | renders `sysctl-values.nix` to `/etc/sysctl.d` drop-in text (Ubuntu path) |
| `lib/sh-helpers.nix`          | shared shell snippets for the lifecycle apps (`requireKey`/`sshOpts`/`noKnownHosts`) |
| `microvm-cache.nix`           | cache-VM role descriptor (feature modules + cache-cert install) → `mk-microvm-node` |
| `microvm-client.nix`          | client-VM role descriptor (feature modules + cache-CA/MITM activation) → `mk-microvm-node` |
| `ubuntu-vm.nix`               | Ubuntu client apps (`up`/`ssh`/`down`/`deploy`) — libvirt VMs + bare-metal deploy |
| `ubuntu-client.nix`           | system-manager config for Ubuntu clients (imports `modules/nginx-client.nix`) |
| `secrets.nix`                 | null-able reads of `./secrets/` (flake evaluates if absent)     |
| `secrets-gen.nix`             | offline secret generators (`cache-gen-secrets`, `cache-gen-ca`) |
| `network-setup.nix`           | host bridge + TAP + NAT apps (`cache-check-host`/`-network-setup`/`-teardown`) |
| `microvm-scripts.nix`         | VM lifecycle + ops apps (start-all, vm-ssh/stop/wipe, distribute-trust, set-hc, diff-test, load-loop) |
| `ca-injector-wrapper.nix`     | shared runc-wrapper derivation that bind-mounts the MITM CA into containers (used by NixOS + Ubuntu) |
| `shell.nix`                   | the dev shell                                                   |
| `modules/nginx-cache.nix`     | shared cache nginx: OCI/apt/model vhosts, proxy_cache zones, `@follow_*` LFS/CDN |
| `modules/nginx-client.nix`    | client nginx: local hot tier + consistent-hash to the caches + in-process HC lua |
| `modules/docker-client.nix`   | dockerd + containerd config: registry mirror + `certs.d` hosts.toml routing |
| `modules/mitm.nix`            | `/etc/hosts` poisoning so host tools hit the local MITM listener |
| `modules/ca-injector.nix`     | wires the runc CA-injector wrapper into the docker daemon (per-container CA trust) |
| `modules/zot-oracle.nix`      | the ×5 Zot registries used as the cache-transparency oracle    |
| `modules/observability.nix`   | Prometheus node_exporter + nginx exporter; §19 `log_format cache` (per-store access logs) |
| `modules/sysctls.nix`         | applies `sysctl-values.nix` via `boot.kernel.sysctl` (NixOS only) |
| `modules/zfs-cache-pools.nix` | the one proper NixOS module (`options.cacheZfs`): hot/warm ZFS pool layout |

---

## Notes & troubleshooting

- **Secrets are required before boot.** Each VM's activation script fails loudly
  (`run 'nix run .#cache-gen-secrets' first`) if `./secrets/` is missing. Re-run
  with `--force` to regenerate: `nix run .#cache-gen-secrets -- --force`.
- **Power-of-two memory.** `vmResources.cache.mem = 8192` is an exact power of
  two; QEMU hangs at boot on some hosts with power-of-two MiB. If a cache VM
  hangs, drop it to `8191` in `constants.nix` (a comment flags this).
- **`vcpu` matches the TAP queues.** The multi_queue TAPs are created to match
  `vmResources.*.vcpu = 4`; keep them in sync if you change one.
- **Network isolation.** This lab uses `cachebr0` / `10.44.44.0/24` so it does
  not collide with the sister `ceph-on-k8s` / `nix-k8s-examples` labs on
  `10.33.33.0/24`. Console ports start at `25600` for the same reason.
- **Never commit `./secrets/`.** It is gitignored; only public certs are ever
  distributed (over SSH, in later phases). CA private keys stay local.
