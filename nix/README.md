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

> **Status:** Phase 1 (boot-first scaffolding) is implemented — the three VMs
> build, boot, and accept key-only SSH. The serving path (nginx caching, Zot
> oracle, TLS hop) and MITM/model-store interception land in later phases. See
> [`../docs/nix-design.md`](../docs/nix-design.md) for the full design and
> [`../docs/focus-design/`](../docs/focus-design/) for *what* the fabric does.

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
| `cache-start-all`        |     no     | build + boot `cache0`, `cache1`, then `client0` (skips running VMs) |
| `cache-vm-ssh`           |     no     | key-only SSH into a VM: `-- --node=<name> [-- <command>]`        |
| `cache-vm-stop`          |     no     | stop one VM: `-- --node=<name>`                                  |
| `cache-vm-wipe`          |     no     | stop a VM and delete its `*-data.img` (cold next boot): `-- --node=<name>` |

`<name>` is one of `client0`, `cache0`, `cache1`.

> More apps (`cache-gen-ca`, `cache-distribute-trust`, `cache-set-hc`,
> `cache-render`, `cache-diff-test`, `cache-pull-corpus`,
> `cache-observability-up`) arrive with the serving-path and MITM phases.

---

## File map

| file                          | purpose                                                        |
|-------------------------------|----------------------------------------------------------------|
| `constants.nix`               | single source of truth: IPs/MACs/ports/upstreams/sizes + helpers |
| `nodes.nix`                   | node registry → which generator the flake uses per VM           |
| `microvm-cache.nix`           | cache-VM generator (`nixosSystem` → `declaredRunner`)          |
| `microvm-client.nix`          | client-VM generator (same scaffolding, client resources)       |
| `secrets.nix`                 | null-able reads of `./secrets/` (flake evaluates if absent)     |
| `secrets-gen.nix`             | offline secret generators (the `cache-gen-secrets` app)         |
| `network-setup.nix`           | host bridge + TAP + NAT apps                                    |
| `microvm-scripts.nix`         | VM lifecycle apps (start/ssh/stop/wipe)                         |
| `shell.nix`                   | the dev shell                                                   |
| `modules/sysctls.nix`         | kernel / network tuning (shared by client + cache)             |
| `modules/observability.nix`   | Prometheus node_exporter                                        |

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
