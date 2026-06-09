# 08 — Operations & future work

## 8.1 Build & run

The lab is driven entirely by `nix run .#cache-*` apps. The operational guide — every app, the
flake wiring, CA distribution, the Ubuntu path, the soak loop, and troubleshooting — lives in
**[`../nix/README.md`](../nix/README.md)** and is **not** duplicated here. The short version:

```sh
nix run .#cache-check-host      # 1. verify host can run MicroVMs (KVM / bridge / sudo)
nix run .#cache-network-setup   # 2. create the bridge, TAPs, and NAT (needs sudo)
nix run .#cache-gen-secrets     # 3. mint SSH host + user keys, cache CA, per-client MITM CAs
nix run .#cache-start-all       # 4. build + boot cache0, cache1, then client0
nix run .#cache-diff-test       # 5. prove nginx cache == upstream (byte-identical)
```

Other apps cover the Ubuntu clients (`cache-ubuntu-up` / `-deploy` / `-ssh` / `-down`), trust
distribution (`cache-distribute-trust`), the health-check kill-switch (`cache-set-hc`), a load
loop (`cache-load-loop`), and VM lifecycle (`cache-vm-ssh` / `-stop` / `-wipe`). See
`nix/README.md` for the full table.

## 8.2 The correctness gate

The serving path is hand-written nginx, so correctness is **proven, not assumed**:
`nix run .#cache-diff-test` pulls the same artifact through the nginx cache and through the
matching off-path Zot oracle ([04](04-cache-vms.md) §4.5) and asserts the bytes are identical.
This is the contract that lets the cache hand-roll its rules — any divergence from the OCI
Distribution Spec shows up as a failing diff. Treat a green diff-test as the bar for any change to
the caching rules.

## 8.3 Two client platforms, one config

The same NixOS modules and the same [`nix/constants/`](../nix/constants/) drive two client
platforms: **NixOS MicroVMs** (via [microvm.nix](https://github.com/astro/microvm.nix)) and
**stock/bare-metal Ubuntu** (via [system-manager](https://github.com/numtide/system-manager),
which applies the same modules where it can and renders data files — e.g. sysctls — where it
can't). Topology, ports, and trust material all come from one source, so both paths stay in
lock-step. This is what proves the client config is portable off the lab and onto a real box.

---

## 8.4 Future work — *not yet built*

Everything below is **deliberately not implemented**. It is recorded here so the boundary between
the working lab and the roadmap is unambiguous. Do not read these as present-tense behaviour.

- **SOCI / lazy-loading snapshotter.** Today a pull still transfers whole layers. A lazy-loading
  snapshotter (SOCI) would let containers start before every byte lands, fetching layer ranges on
  demand through the same cache. **Not built.**
- **Local image garbage collection.** A policy for evicting cold images from the client's local
  store to bound disk use. **Not built.**
- **Node-to-node HTTP/3 on the client→cache hop.** The cache hop is HTTP/2 over TLS today; HTTP/3
  on the owned listeners is a tuning follow-up. **Not built.**
- **Zot in the serving path.** Zot is strictly an off-path verification oracle. Putting a registry
  implementation on the serving path (instead of, or beside, the nginx rules) is an option that has
  **not** been taken.
- **ZFS L2ARC / SLOG.** The tuning levers exist in `constants.zfsTuning` but are guarded off by a
  build-time assertion: in the lab every virtio disk shares one host backing store, so an L2ARC
  vdev can't be faster and a SLOG would sit idle (all datasets are `sync=disabled`). Enable either
  only with a real dedicated fast device on production hardware. **Not enabled.**
