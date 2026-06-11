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
loop (`cache-load-loop`), the MITM cert-minter gate (`cache-mitm-test`), and VM lifecycle
(`cache-vm-ssh` / `-stop` / `-wipe`). See `nix/README.md` for the full table.

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

- **SOCI / lazy-loading snapshotter.** Today the client runs the eager **overlayfs** containerd
  snapshotter (`features.containerd-snapshotter = true`,
  [`docker-client.nix`](../nix/modules/docker-client.nix)): a pull transfers and unpacks *whole*
  layers before the container starts. A **lazy-loading** snapshotter would instead mount each layer
  as a FUSE filesystem and fetch only the spans a container actually reads, on demand, through the
  same cache — collapsing both startup wait and local footprint toward the real working set. The
  leading fit is **SOCI** (Seekable OCI, AWS Labs): it leaves the image **byte-for-byte unmodified**
  and adds a *separate* index artifact (discovered via the Referrers API
  `/v2/<name>/referrers/<digest>`), so digest-dedup and the byte-identical guarantee survive — the
  decisive advantage over **eStargz/stargz**, which repackage layers, change digests, and break both.
  SOCI is also fail-safe: no index → it falls back to overlayfs and pulls normally.

  The challenges that make this a real project, not a config flip:
  - **Range-blob caching is new serving surface.** SOCI's on-demand reads are HTTP `Range` GETs
    against blob URLs (`fs/remote/resolver.go`), so the nginx cache must serve and cache `206`
    partial content correctly (`slice` module, range-aware cache keys) without caching partials
    wrong or thrashing — and the Zot oracle's byte-identical check must extend to ranged reads.
  - **Index availability is the binding constraint for a typical workload.** Lazy loading only helps
    images that *have* a SOCI index. The third-party AI images an operator pulls (public Docker Hub
    images, a GPU-cloud platform's own images such as RunPod's) almost certainly ship none → eager
    fallback → zero benefit. Closing that gap means either upstream runs
    `soci create`/push (out of our control) or **the cache synthesizes indices on ingest** — itself
    a substantial feature.
  - **Registry-path requirements.** The path must support the Referrers API (or the tag-scheme
    fallback) and honour ranged blob reads, end to end through the cache.
  - **Operational surface.** An extra `soci-snapshotter-grpc` daemon per client plus a containerd
    config stanza.

  Mostly **orthogonal to the MITM design**: lazy delivery doesn't change CA injection (bind mounts
  are honoured regardless of snapshotter), but it does make any *create-time* rootfs inspection even
  less viable (the FUSE rootfs materializes on access) — see
  [`container-mitm-arbitrary-origins.md`](container-mitm-arbitrary-origins.md). **Not built.**
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

## 8.5 Next phases — the arbitrary-origin roadmap

The runtime per-SNI cert minter ([§05.3](05-trust-and-mitm.md)) is now shipped, which removes the
cert half of the "MITM only a curated FQDN list" ceiling. The remaining phases generalise
interception to origins we can't enumerate up front; the full design and trade-offs live in
[`container-mitm-arbitrary-origins.md`](container-mitm-arbitrary-origins.md). In rough dependency
order:

1. **`ssl_preread` stream-passthrough** — a `stream{}` front that peeks the ClientHello SNI and
   passes flows we don't cache (or that pin certs) straight through, MITM'ing only the rest. The
   minter's no-SNI branch is already the seam this attaches to. It is both the second filter stage
   and the mandatory escape hatch, so it lands **before** packet-layer redirection.
2. **nftables DNAT at the docker bridge** — replace the `/etc/hosts` redirection (the last
   hostname-keyed half) with a `dstnat` rule in [`network-setup.nix`](../nix/network-setup.nix),
   gated on a named `@cdn_origins` interval set so only cached origin/CDN ranges are intercepted and
   all other egress passes untouched.
3. **IP-range updater daemon** — populate `@cdn_origins` from published feeds (AWS `ip-ranges.json`,
   GitHub `meta`, Cloudflare, Fastly, GCP). This is a failure-mode-heavy design of its own
   (rate-cap the churn, persist last-known-good, validate-before-apply atomically) — treat it as a
   separate workstream, not a script.
4. **Delegated auth for private registries** — an `access_by_lua` gate on the serving path that
   replays the client's own credential against the origin (`HEAD`/token handshake) before serving
   cached private content, with a short-TTL `(client-identity, repo)` authz cache and an optional
   `lua-resty-jwt` fast path. Required the moment interception includes a registry that answers
   `401` (e.g. `registry.runpod.net`).
5. **Accelerator config-redirect** — for surfaces with a protocol-native mirror (PyPI via
   `PIP_INDEX_URL`/`pip.conf`, dnf), inject the redirect through the existing runc shim instead of
   MITM'ing. Cheaper and preferred wherever a mirror + config knob exists; MITM stays the exception
   for GitHub release-asset wheels and git clones.

Phases 1–2 are the critical path to "arbitrary origins"; 3 hardens 2; 4 and 5 are independent and
can land in any order once 1–2 exist.
