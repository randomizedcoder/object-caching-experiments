# Moby image pull / unpack: code map, perf review, parallelization ideas

All GitHub links are pinned to commit
[`ad6b80a888`](https://github.com/moby/moby/commit/ad6b80a888d3248fba66ce149f1f072487f7697b)
(tag `v2.0.0-beta.15-28-gad6b80a888`) so line numbers stay stable.

## TL;DR

- **Yes**, this repo (`moby/moby`, which becomes the `dockerd` daemon) owns
  registry-mirror config, image pull, blob storage, and layer unpack.
- There are **two pull backends** in-tree:
  1. The legacy graphdriver-based pipeline in
     `daemon/internal/distribution/` + `daemon/internal/layer/` +
     `daemon/graphdriver/`.
  2. A newer containerd-backed pipeline in `daemon/containerd/` that
     delegates to `github.com/containerd/containerd` for fetch + unpack.
- **Downloads are parallel** (default 3); **unpack is single-threaded per
  layer, and serialized along the layer chain** because each layer is laid
  down on top of its parent. That ordering is fundamental to overlay-style
  filesystems, but the *single-threaded tar extract* is an implementation
  cost we can attack.
- **No io_uring anywhere**. Everything goes through standard `os.File` /
  `syscall`-style read/write and tar streaming.
- **NFS for a shared image store across a cluster is possible but lousy** -
  overlayfs cannot use NFS as an `upperdir`/`lowerdir` directly, and the
  metadata sqlite/boltdb files in containerd's content store don't tolerate
  cross-host writers. A read-only shared *content* mount + per-host
  snapshotter is the realistic shape.

---

## Executive summary: top 10 recommendations

Ranked by expected impact on the actual RunPod workload (huge AI/ML
images, GPU nodes, 1 TB+ image working sets), as observed on
`run-pod-65` (Docker 29.3.0, legacy `overlay2` graphdriver, `userns-remap:
default`, no `containerd-snapshotter` flag set).

Ordered for sequencing: #1-#2 are operational wins deployable in days,
#3 is the cold-start killer (requires #2), #4 is the structural long-
term win, #5-#7 are tuning and bandwidth, #8-#9 are fleet-internal
strategies, #10 is the engineering investment with the longest payback.
Every recommendation links into the detailed section further down.

| # | Recommendation | Effort | Cold-start win | Code changes |
|---|---|---|---|---|
| 1 | [Per-DC pull-through mirror + HAProxy](#1---per-dc-pull-through-mirror-behind-haproxy) | Days | 3-10x for cache-hot pulls | None |
| 2 | [Migrate to containerd image store](#2---migrate-to-the-containerd-image-store) | Days per host + 2× disk | Modest standalone; unlocks #3 | Config only |
| 3 | [Lazy-loading snapshotter (stargz/SOCI)](#3---lazy-loading-snapshotter-stargz--soci--nydus) | Weeks | **10-100x** for huge AI images | Per-image repacking |
| 4 | [Externalize model weights from images](#4---externalize-model-weights-from-images) | Months (cultural) | 5-10x via smaller images | App-level refactor |
| 5 | [klauspost/compress fork (gzip ~3x)](#5---klauspostcompress-fork-3x-faster-gzip-decompress) | Days (Go work) | ~50-70 s saved per huge gzip layer | Fork moby/go-archive |
| 6 | [Range-chunked parallel single-blob download](#6---range-chunked-parallel-single-blob-download) | Weeks (Go work) | 2-4x faster fetch for huge blobs | New `DownloadDescriptor` |
| 7 | [Tune `max-concurrent-downloads` with measurement](#7---tune-max-concurrent-downloads-with-measurement) | Hours | Maybe 1.2-1.5x; bounded by NIC | Config only |
| 8 | [Pre-warm images at node provisioning](#8---pre-warm-images-at-node-provisioning) | Days (Ansible) | **∞x** for prewarmed images (zero cold start) | None |
| 9 | [P2P content distribution within DC (Dragonfly / Spegel / Kraken)](#9---p2p-content-distribution-within-the-dc) | Weeks | 2-5x at fleet scale | Adds a daemon |
| 10 | [io_uring batch extract + parallel tar workers](#10---io_uring-batch-extract--parallel-tar-workers) | Months (Go work) | 2-4x extract for small-file base layers | Fork moby/go-archive |

### #1 - Per-DC pull-through mirror behind HAProxy

**Detail:** [§1 Alternative](#alternative-front-mirrors-with-haproxy-or-nginx).

**What to change.** Deploy a registry in proxy/cache mode on 2-3 nodes
per DC. Front them with HAProxy doing active health-checked load
balancing - the exact config (including the critical "accept HTTP 401 as
healthy" trick) is in
[§1 Alternative](#alternative-front-mirrors-with-haproxy-or-nginx). Set
`"registry-mirrors": ["https://registry-proxy.dc.example.net"]` on every
dockerd via `daemon.json` and SIGHUP-reload
([`daemon/reload.go reloadRegistryConfig`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/reload.go#L118)).

**Top 5 proxy/cache options for the registry tier:**

| Option | License | Why pick it |
|---|---|---|
| [`distribution/distribution`](https://github.com/distribution/distribution) (a.k.a. `registry:2` in `proxy:` mode) | Apache 2.0, CNCF | Reference implementation, smallest moving parts. Supports `proxy.remoteurl` to any upstream. Storage on local FS, S3, GCS, Azure, OSS. **Default pick.** |
| [Harbor](https://goharbor.io) | Apache 2.0, CNCF graduated | If you want vuln scanning, RBAC, replication, multi-tenancy in the same product. Heavier but production-grade. |
| [Spegel](https://github.com/spegel-org/spegel) | MIT | Kubernetes-native peer-to-peer: every k8s node becomes a mirror for every other via the existing CRI runtime. Zero new central infra. If your fleet is k8s-managed, this is the lowest-ops option. Overlaps with #9 below. |
| [Sonatype Nexus Repository OSS](https://www.sonatype.com/products/sonatype-nexus-repository) | EPL, free OSS tier | If you already run Nexus for Maven / npm / PyPI - one product covers them all. Docker proxy works fine. |
| [Zot](https://zotregistry.dev) | Apache 2.0, CNCF sandbox | Modern OCI-native, single static binary, no DB. Newer than `distribution` but well-maintained and good for greenfield. |

For RunPod specifically, **`distribution` in `proxy:` mode** is the
right starting point. It's the reference impl, the storage tiers are
boringly stable, and the only "feature" you need is the cache. You can
add Harbor later if you want vuln scanning or replication; you can
adopt Spegel if you move heavily to Kubernetes.

**Expected win.** First pull of an image into a DC traverses the WAN
once; every subsequent host pulls over the LAN. For a fleet that
repeatedly pulls the same `runpod/pytorch:*`, `vllm/vllm-openai:*` and
similar base images, expect 3-10x faster cold starts on cache-hot
pulls. Stacks with every other recommendation.

**Downsides and risks.**
- One more service to operate (HAProxy + 2-3 mirror instances).
- Cache disk sized to your hot working set: realistically 1-2 TB SSD
  per mirror given your image sizes.
- Cache invalidation when upstream re-tags `:latest` requires explicit
  purge or TTL expiry.
- Misconfigured HAProxy health checks (treating 401 as unhealthy) can
  black-hole healthy mirrors - the §1 config explicitly handles this.

**Migration plan.**
1. Deploy 2 mirror instances + HAProxy on a staging VLAN.
2. Canary one production node by adding the mirror to its `daemon.json`,
   SIGHUP, time a cold pull of 5 representative images vs baseline.
3. Roll across the fleet via config-mgmt; no daemon restart needed -
   mirror changes are live-reloaded.
4. Monitor HAProxy stats endpoint and mirror cache hit rate. Iterate
   on cache size and TTL.

### #2 - Migrate to the containerd image store

**Detail:** [§3 The containerd-backed path](#3-the-containerd-backed-path),
[§10 Enabling the containerd image store](#10-enabling-the-containerd-image-store-how-and-tradeoffs).

**What to change.** Set `"features": {"containerd-snapshotter": true}`
in `daemon.json` and restart dockerd. On first boot dockerd runs
[`MigrateTocontainerd`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/containerd/migration/migration.go#L62),
which walks `/var/lib/docker/100000.100000/overlay2/` and re-registers
each layer into the containerd content store.

**Expected win - be honest about what this actually gives you.**

Standalone, the wins are **modest**:

- Native handling of zstd-compressed layers (both paths already use
  `klauspost/compress/zstd`, so no speedup, but the containerd
  *content store* can hold zstd directly without re-encoding to gzip).
- OCI artifact handling (signatures, SBOMs, attestations) as first-
  class objects.
- Active-development codepath; the legacy graphdriver path is in
  maintenance mode.
- Shared content store with BuildKit (one cache, not two).

**It does NOT give you faster gzip decompression for free.** I checked:
containerd's vendored
[`pkg/archive/compression/compression.go`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/vendor/github.com/containerd/containerd/v2/pkg/archive/compression/compression.go)
imports `compress/gzip` (stdlib), just like moby's
[`vendor/github.com/moby/go-archive/compression/compression.go`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/vendor/github.com/moby/go-archive/compression/compression.go).
The 3x faster gzip is recommendation **#5** - a separate fork.

**The real strategic win** of #2 is that it is the **prerequisite for
#3** (lazy-loading snapshotters), which is the actual cold-start
killer. Do #2 now to get the migration disk-usage spike out of the
way before #3 layers on top.

**Downsides and risks.**
- One-way migration in practice; rollback loses anything pulled after
  the switch.
- Briefly needs **~2 TB free** on data-root (current usage is ~1 TB).
- `userns-remap: default` (which you have) is a less-tested migration
  path; verify uid-100000 file ownership survives.
- Tools that read `/var/lib/docker/overlay2/<id>/diff` directly will
  break.
- `docker info` reports `Storage Driver: overlayfs` not `overlay2`;
  monitoring filters need updating.

**Migration plan.**
1. Canary one node with the fewest images; verify ≥2× data-root free
   space.
2. Set flag, restart, watch `Migrated image <name> to <digest>` log
   lines, validate top 10 images pull and run.
3. Specifically test userns-remap behavior on uid 100000 ownership.
4. Stage rollout: 5% → 25% → 100% of fleet with 24-72h soak between
   phases.
5. After 2 weeks confidence, decommission the legacy tree.

### #3 - Lazy-loading snapshotter (stargz / SOCI / nydus)

**Detail:** [§8 What you can do, option D](#what-you-can-do).

**What is stargz and how does it actually help?**

Today, pulling a 78 GB image means: (a) download all 78 GB, (b) extract
all 78 GB onto local disk, (c) overlay-mount, (d) start the container.
Steps (a) and (b) are sequential and take minutes. The container then
maybe touches 5 GB of files during its actual run.

**stargz = Seekable Tar GZip.** It is a *backwards-compatible* tar.gz
with extra metadata:

- The tar is augmented with a JTOC (JSON Table of Contents) footer
  describing every file's path, size, and **byte offset in the
  compressed stream**.
- Each file's compressed bytes are aligned so that a single file can
  be fetched via HTTP `Range:` request without decompressing the rest.
- Standard `docker pull` clients see a normal tar.gz; stargz-aware
  clients (the `containerd-stargz-grpc` snapshotter) see a virtual
  filesystem.

**SOCI** (Seekable OCI, AWS-led) takes a different approach: it doesn't
modify the image, it just builds an index for the *existing* tar.gz blob
and stores it as a separate OCI artifact in the same registry. Pro: no
image rebuild. Con: per-image index generation step.

**Nydus** (Alibaba/Dragonfly) rewrites the image into a chunk-addressed
format entirely. More invasive, also more sophisticated (deduplication
across images at sub-file granularity).

**The mechanism in all three:**

1. Container start does NOT pull the layer body.
2. Snapshotter mounts the layer as a FUSE filesystem backed by the JTOC.
3. When the application opens a file, FUSE intercepts the read, issues
   an HTTP `Range:` request to the registry for *just that file's
   bytes*, decompresses, returns the data, and caches it locally.
4. Files never opened are never downloaded.

For a 78 GB image where only 5 GB is actually accessed at runtime,
this means: container starts in seconds, ~5 GB faulted in over the
duration of the run (vs the current 78 GB up-front).

**What to change.**
- Install the `containerd-stargz-grpc` (or SOCI, or Nydus) snapshotter
  daemon on every node.
- Add `proxy_plugins` to `/etc/containerd/config.toml` to register it.
- Build a one-shot conversion pipeline: `nerdctl image convert
  --estargz` (or `soci create`) per source image; push converted tag
  alongside the original (e.g. `myimage:v1.0` and `myimage:v1.0-estargz`).
- Workloads update their image reference to the converted tag.

**Expected win.**

For your 78 GB image example today: roughly 10-15 minutes from `docker
pull` to "container ready" on a cold node (uncached, WAN pull). With #3:
roughly **5-15 seconds**.

**Combined #2 + #3 win (the headline number):**

| Stage | Today (overlay2, no mirror) | With #2 only | With #1 + #2 + #3 |
|---|---|---|---|
| Pull (78 GB → disk) | ~7-12 min (WAN) | ~7-12 min | ~5 s (only JTOC + metadata) |
| Extract | ~3-5 min (single-thread untar) | ~3-5 min | 0 s (skipped) |
| Container start | seconds | seconds | seconds |
| **Total cold start** | **~10-17 min** | ~10-17 min | **~5-15 s** |
| Lazy fetch during run | n/a | n/a | ~5 GB amortized over run lifetime |

That's a **60-100x speedup** for the cold-start path on this image
size. Even better, you stop paying disk for files you never read.

**Downsides and risks.**
- Requires #2 first.
- Per-image conversion work. For 50-100 images that's a 50-100-step
  CI/CD pipeline (idempotent and cacheable).
- First-access latency on lazy pages can spike, surfacing as jitter
  on cold caches. Usually acceptable but measure under your real
  workload.
- Some `--privileged` or unusual kernel-module patterns may not
  interact well; test before promoting.
- Adds another daemon to operate (`containerd-stargz-grpc` or the
  Nydus/SOCI equivalent).
- If the registry doesn't support HTTP Range (rare), falls back to
  full-blob fetch and you've added complexity for no gain. Check
  your registry.

**Migration plan.**
1. One test node, one image. Pick `comfyui-worker-poc:all-models-v5-cuda-13.0`
   (78 GB). Convert to estargz, push, pull, run, time first byte to
   model-loaded.
2. Build CI/CD: every registry push produces a parallel estargz tag
   automatically.
3. Opt-in canary: a subset of workloads switches to the estargz tag
   for a week.
4. Fleet-wide snapshotter rollout.
5. Encourage / require estargz tags for new builds in
   `registry.runpod.net`.
6. Sunset non-estargz tags for popular images after deprecation window.

### #4 - Externalize model weights from images

**Detail:** [§9 Why these images are huge](#why-these-images-are-huge),
[§9 Pre-warming as a tactic](#pre-warming-as-a-tactic).

**What to change.** Stop baking model weights into images. The image
holds the runtime (CUDA, PyTorch, deps, app code); weights are *data*
loaded at container start from S3/GCS/MinIO in the same DC. Provide a
base-image entrypoint pattern (`runpod-fetch-weights` style) so this is
as ergonomic as `COPY` was.

**Expected win.** Image sizes drop from 50-90 GB to 5-15 GB; pull and
extract drop proportionally even *without* any other change. Image
churn shrinks: a new checkpoint becomes an S3 object update, not a
multi-GB image rebuild. Layer dedup actually works because every
workload shares a small set of base layers.

**Downsides and risks.**
- **Cultural change.** Image authors are used to `COPY models/`.
- Cold start for a *brand-new* model on a *fresh node* is bounded by
  the model store's egress; need fast same-DC object storage.
- Legitimate exception cases (air-gapped, single-binary, signing).
- Initial refactor cost across every workload.

**Migration plan.**
1. Publish a reference Dockerfile + entrypoint script in `runpod/base`.
2. Refactor the 5 most-pulled large images; push as new versions.
3. A/B compare cold-start times; share numbers with image authors.
4. Provide tooling (`runpod-fetch-weights` with S3 + SHA + NVMe cache).
5. Gradual adoption with perf consulting for largest existing images.
6. (Optional, long term) build-time policy capping image size.

### #5 - klauspost/compress fork (~3x faster gzip decompress)

**Detail:** [§5.2 Decompression is on the hot path](#52-decompression-is-on-the-hot-path-and-single-threaded).

**What to change.** Fork `github.com/moby/go-archive`, edit
[`compression/compression.go`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/vendor/github.com/moby/go-archive/compression/compression.go):
swap `import "compress/gzip"` → `import kgzip "github.com/klauspost/
compress/gzip"`. Same API, no caller changes. For zstd, the file
already imports `klauspost/compress/zstd`; add
`WithDecoderConcurrency(runtime.GOMAXPROCS(0))` to enable multi-
threaded zstd decode. Full before/after code is in
[§5.2 "Concrete code change for klauspost/compress"](#52-decompression-is-on-the-hot-path-and-single-threaded).

This is the change you thought was free with #2 but isn't - **both**
moby's legacy path and containerd's path call stdlib `compress/gzip`,
so you have to fork either way.

**Expected win.**
- ~3x faster gzip decompress thanks to klauspost's hand-tuned
  deflate (AVX2 on amd64).
- On a 25 GB compressed-gzip model-weight layer: today ~80-100 s of
  single-core CPU; after, ~25-30 s. Saves **~50-70 s per huge layer**
  in the chain.
- Stacks per-layer along the layer-chain serialization.
- For zstd-encoded layers, `WithDecoderConcurrency` parallelizes the
  decode across cores - ~2-3x throughput on multi-frame zstd blobs.

**Downsides and risks.**
- Maintaining a vendored fork of moby/go-archive (mitigated by
  upstreaming the change as a PR).
- The Go version of `compress/gzip` is the API stdlib `compress/gzip`
  implements; klauspost matches the API exactly, so no functional
  surface change. Low risk.
- Output bytes from decompress are bit-identical; no correctness
  surface.

**Migration plan.**
1. Fork `moby/go-archive`, make the two-line gzip swap.
2. `go mod replace` it into moby's go.mod, rebuild dockerd.
3. Deploy to one canary node, benchmark cold pull of 5 representative
   images. Compare wall clock.
4. If wins are real, propose the swap as a PR to upstream moby/go-archive
   (this has been raised in their issue tracker before).
5. Roll out fleet-wide.

### #6 - Range-chunked parallel single-blob download

**Detail:** [§7 (2) Multiple chunks of one layer in parallel](#2-multiple-chunks-of-one-layer-in-parallel---not-done-today).

**What to change.** Today moby downloads each blob with one HTTP GET
on one TCP connection ([`pull_v2.go layerDescriptor.Download`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L169)).
Implement a new `DownloadDescriptor` that, for blobs above ~64 MB, does:

```
HEAD /v2/.../blobs/<digest>     → Content-Length L, Accept-Ranges: bytes
fallocate(L)
spawn K workers, each GET with Range: bytes=START-END
workers pwrite() into the preallocated tempfile
once last worker finishes: hash + verify + hand to unpack
```

Hooks straight into the existing `transferManager`; no scheduler change.

**Expected win.** Huge model-weight blobs (single 25 GB layer) get
**2-4x faster network fetch** when the bottleneck is per-connection BDP
or CDN per-stream caps, which it often is on cross-region pulls. For
images with many small layers, no benefit (chunking under ~64 MB is pure
loss).

This is the most direct answer to "the user already bumped
`max-concurrent-downloads` to 9 but the image only has 3 layers" - it
gets you parallelism *within* a layer, which is exactly what's missing.

**Downsides and risks.**
- Real engineering work in Go; new descriptor implementation.
- Range stitching bugs are silent (hole in tempfile → digest fail →
  retry storm); need careful per-chunk retry.
- TLS handshake cost × K (mitigate with HTTP/2 single connection +
  multiple streams).
- Some registries rate-limit per-connection; very aggressive
  chunking can trip them.

**Migration plan.**
1. Prototype as a wrapper around the existing `layerDescriptor`,
   gated by `if Content-Length > 64 MB`.
2. Benchmark cold pull of one 78 GB image at K=1, 2, 4, 8.
3. Add a `daemon.json` flag (e.g.
   `"max-concurrent-blob-chunks": 4`) so it's tunable in production.
4. Land behind a feature flag; soak.
5. Default-enable once stable.

### #7 - Tune `max-concurrent-downloads` with measurement

**Detail:** [§2 Concurrency knobs](#concurrency-knobs),
[§9 Your current settings](#your-current-settings).

**What to change.** You said you set `max-concurrent-downloads: 9` and
`max-concurrent-uploads: 15`. On `run-pod-65` that file actually shows
none of those settings - either applied elsewhere, reverted, or set
via `dockerd` flags in the systemd unit. Verify with:

```
systemctl cat docker | grep -i max-concurrent
ps -o args= -p $(pidof dockerd)
docker info | grep -i 'concurrent'
```

Then measure whether the current value buys anything. For an image
with ≤4 layers, `max-concurrent-downloads` above the layer count does
nothing.

**Expected win.** Bounded by NIC saturation. On a 10 GbE NIC pulling
from an in-DC mirror, **2-3 connections already saturate**. The 4th-9th
add CPU + TLS handshake cost without bytes/sec. Realistic wall-clock
improvement: 0-50% depending on workload, with a sweet spot usually
around 4-8. Going higher than 12 is almost always a loss for AI images
(huge per-layer state in flight, NIC bound).

**Downsides and risks.**
- Going too high: TLS handshake CPU, more in-flight tempfile disk
  churn (12 concurrent 25 GB layers = ~300 GB of in-flight disk
  write), registry rate-limit trips.
- Going too low (back to default 3): for fleets that pull multiple
  images at once, slot starvation across pulls.

**Migration plan.**
1. Run `iftop -i <iface>` during cold pull of your 5 representative
   images at the current setting.
2. If you're under ~80% NIC saturation, lower has no penalty.
3. Drop to 6 on a canary, repeat, compare wall clock and `docker
   info` reported throughput.
4. Settle on 4-8 for typical AI workloads; 9 is plausible but
   bordering on diminishing returns; 15 uploads is fine since uploads
   are rare.

### #8 - Pre-warm images at node provisioning

**Detail:** [§9 Pre-warming as a tactic](#pre-warming-as-a-tactic).

**What to change.** Bake the top N most-used images into the node OS
image / cloud-init / Packer build, or pre-pull them on first boot via a
systemd unit. For a known catalog of images deployed to a known fleet,
this turns cold-start into zero start.

**Expected win.** For the prewarmed image set: ∞x (zero cold start).
For everything else: nothing. So the win scales with how concentrated
your image popularity distribution is - if 10 images account for 80%
of starts (likely the case for RunPod's worker images), prewarming
those 10 covers 80% of cold-start latency.

**Downsides and risks.**
- Node provisioning takes longer (gotta pull the images at AMI bake
  time or first-boot).
- Stale prewarmed images get out of date; need a cron pull or a
  prewarm refresh job.
- Disk consumed by images you may not use on every node.

**Migration plan.**
1. Identify the top 10 most-pulled images (Prometheus metrics, log
   aggregation, or just registry pull counters).
2. Build an Ansible role / Packer step that pulls them at node-bake
   time or first-boot.
3. Add a daily cron to refresh: `docker pull <list>`.
4. Verify storage planning: 10 images × ~30 GB avg = ~300 GB of
   prewarm disk per node.
5. Combines cleanly with #1 (the prewarm pulls go through the local
   mirror) and #3 (prewarming the *index* of a stargz image is
   essentially free; the JTOC is tiny).

### #9 - P2P content distribution within the DC

**Detail:** [§9 Pre-warming as a tactic](#pre-warming-as-a-tactic) (final paragraph),
[§8 What you can do, option B](#what-you-can-do).

**What to change.** Deploy a peer-to-peer content distribution system
across your fleet. The good options:

- **[Dragonfly](https://d7y.io)** (CNCF graduated, originally Alibaba):
  every host runs a peer; a central scheduler coordinates piece
  exchange. Mature, integrates with containerd via a snapshotter,
  works alongside #3 (nydus).
- **[Spegel](https://github.com/spegel-org/spegel)**: Kubernetes-native;
  uses CRI to discover existing image layers on each node and serves
  them to peers. Almost zero new infra; assumes k8s.
- **[Kraken](https://github.com/uber/kraken)** (Uber-built, OSS):
  BitTorrent-style; designed for HD-image fan-out across thousands of
  hosts. Heavier ops than Spegel.

This is option B from [§8](#what-you-can-do) done with real tooling. It
effectively turns the fleet into a CDN: when host A finishes pulling a
layer, hosts B-Z fetch from host A instead of the upstream mirror.

**Expected win.** For fleet-wide deployments (e.g. "roll a new pytorch
image to 500 nodes"), wall-clock time to last-node-ready drops by
2-5x because origin bandwidth is no longer the bottleneck. For
individual node cold starts on already-deployed images, similar effect
to #1 (mirror in same DC), but without the central infrastructure
investment - peers self-serve.

**Downsides and risks.**
- Adds a peer daemon to every node.
- Bandwidth between peers must be plentiful (usually true in same-DC
  east-west).
- Some implementations need a central tracker (Dragonfly scheduler),
  some don't (Spegel uses Kubernetes APIs).
- Security: peer-to-peer traffic must be in your trust boundary.
- Overlaps with #1 - you typically don't run both. Pick mirror+HAProxy
  *or* P2P, not usually both.

**Migration plan.**
1. Pick the implementation that matches your orchestrator (Spegel if
   k8s-driven, Dragonfly if not).
2. Stand up on a test cluster, validate fan-out behavior with a fresh
   image push.
3. Compare wall-clock to-last-node time vs the #1 (mirror) approach
   on the same scenario.
4. Pick the winner for your scale. For ≤100 nodes, mirror+HAProxy is
   simpler. For 1000+ nodes, P2P starts paying off.

### #10 - io_uring batch extract + parallel tar workers

**Detail:** [§5.7 No io_uring anywhere](#57-no-io_uring-anywhere---and-how-gosrts-pattern-would-map),
[§2 Per-entry batching](#per-entry-batching-is-there-an-opportunity-inside-one-layer).

**What to change.** In the forked `moby/go-archive` from #5:
- Replace the per-file `openat/write/setxattr/close` loop in
  `chrootarchive/` with an `io_uring` SQE batch using `IOSQE_IO_LINK`
  chains, modeled on `gosrt`'s `submitRecvRequestBatch` +
  `PeekBatchCQE` patterns.
- Optionally add a parallel worker pool inside `UnpackLayer` per
  [§2 batching design](#per-entry-batching-is-there-an-opportunity-inside-one-layer)
  (single tar reader, N file-write workers, deferred hardlink pass).

**Expected win.**
- 2-4x faster extract for small-file-heavy base layers (CUDA, Python,
  OS). Stacks across the layer chain.
- Diminishing returns for the model-weight layers themselves (those
  are decompression / I/O bound, not syscall bound).
- Best paired with #5 (klauspost gzip) - one cuts CPU on decompress,
  the other cuts syscall overhead on writes.

**Downsides and risks.**
- Most engineering-intensive item on this list.
- io_uring bugs are nasty; gosrt's
  `documentation/IO_Uring*.md` catalogs the ones they hit.
- Requires Linux ≥ 5.6 for `openat2`; gate behind a feature probe.
- The chrootarchive re-exec boundary doesn't play well with io_uring
  ring inheritance; either move ring creation inside the chroot
  child or adopt `openat2(RESOLVE_BENEATH)` and drop chroot entirely.
- Long maintenance tail for the vendored fork.

**Migration plan.**
1. **Phase A:** prototype `UnpackRing` as a standalone CLI that
   untars to a directory using io_uring. Validate correctness against
   `tar -xf` and performance against current chrootarchive.
2. **Phase B:** integrate into chrootarchive behind a feature flag.
   Long soak (1-2 months) on a small subset of nodes.
3. **Phase C:** graduate from flag to default; drop the syscall
   fallback path.
4. **Phase D (optional):** parallel worker pool inside the unpack
   loop, only if Phase C wins are insufficient.

### How these add up

The big-picture composition for your workload:

- **#1 + #2 + #3** is the headline transformation: pull-and-start a
  78 GB image goes from ~10-17 minutes to ~5-15 seconds. **This is
  the 60-100x cold-start cliff.**
- **#4** makes that gain durable as the image catalog grows.
- **#8 + #9** make hot-path repeated starts effectively free.
- **#5 + #6 + #10** are the engineering work that wins back the
  remaining wall-clock for the cases lazy loading can't cover
  (workloads that genuinely need all bytes up front).
- **#7** is just hygiene - measure what you've already changed.

If you could only do one thing: **#3**. But #3 depends on #2 and is
multiplied by #1, so the actual minimum-viable bundle is **#1 + #2 +
#3**.

---

## Table of contents

- [Executive summary: top 10 recommendations](#executive-summary-top-10-recommendations)
  - [#1 - Per-DC pull-through mirror behind HAProxy](#1---per-dc-pull-through-mirror-behind-haproxy)
  - [#2 - Migrate to the containerd image store](#2---migrate-to-the-containerd-image-store)
  - [#3 - Lazy-loading snapshotter (stargz / SOCI / nydus)](#3---lazy-loading-snapshotter-stargz--soci--nydus)
  - [#4 - Externalize model weights from images](#4---externalize-model-weights-from-images)
  - [#5 - klauspost/compress fork (~3x faster gzip decompress)](#5---klauspostcompress-fork-3x-faster-gzip-decompress)
  - [#6 - Range-chunked parallel single-blob download](#6---range-chunked-parallel-single-blob-download)
  - [#7 - Tune `max-concurrent-downloads` with measurement](#7---tune-max-concurrent-downloads-with-measurement)
  - [#8 - Pre-warm images at node provisioning](#8---pre-warm-images-at-node-provisioning)
  - [#9 - P2P content distribution within the DC](#9---p2p-content-distribution-within-the-dc)
  - [#10 - io_uring batch extract + parallel tar workers](#10---io_uring-batch-extract--parallel-tar-workers)
  - [How these add up](#how-these-add-up)
- [1. `registry-mirrors`](#1-registry-mirrors)
  - [Where it lives](#where-it-lives)
  - [Configuration options](#configuration-options)
  - [Perf notes](#perf-notes)
  - [Alternative: front mirrors with HAProxy or nginx](#alternative-front-mirrors-with-haproxy-or-nginx)
- [2. The pull pipeline (legacy / graphdriver path)](#2-the-pull-pipeline-legacy--graphdriver-path)
  - [Configuration options - which path runs?](#configuration-options---which-path-runs)
  - [Top-level flow](#top-level-flow)
  - [Concurrency knobs](#concurrency-knobs)
  - [How `transferManager` actually works](#how-transfermanager-actually-works)
  - [Per-entry batching: is there an opportunity inside one layer?](#per-entry-batching-is-there-an-opportunity-inside-one-layer)
  - [Why unpack is "serial"](#why-unpack-is-serial)
- [3. The containerd-backed path](#3-the-containerd-backed-path)
  - [Configuration options](#configuration-options-1)
- [4. Storage / unpack internals](#4-storage--unpack-internals)
  - [Configuration options](#configuration-options-2)
- [5. Performance review](#5-performance-review)
  - [5.1 Single-threaded per-layer tar extract (biggest win)](#51-single-threaded-per-layer-tar-extract-biggest-win)
  - [5.2 Decompression is on the hot path and single-threaded](#52-decompression-is-on-the-hot-path-and-single-threaded)
  - [5.3 Tempfile double-write](#53-tempfile-double-write)
  - [5.4 Tar-split JSON sidecar overhead](#54-tar-split-json-sidecar-overhead)
  - [5.5 Allocator / GC churn](#55-allocator--gc-churn)
  - [5.6 Syscall hygiene during untar](#56-syscall-hygiene-during-untar)
  - [5.7 No io_uring anywhere - and how gosrt's pattern would map](#57-no-io_uring-anywhere---and-how-gosrts-pattern-would-map)
- [6. How docker image pulls actually work (with code refs)](#6-how-docker-image-pulls-actually-work-with-code-refs)
  - [Important detail: "register" depends on parent, "download" does not](#important-detail-register-depends-on-parent-download-does-not)
- [7. Parallelizing a single pull](#7-parallelizing-a-single-pull)
  - [(1) Multiple layers in parallel - already done](#1-multiple-layers-in-parallel---already-done)
  - [(2) Multiple chunks of one layer in parallel - not done today](#2-multiple-chunks-of-one-layer-in-parallel---not-done-today)
  - [(3) Pipelined download → decompress → untar within one layer](#3-pipelined-download--decompress--untar-within-one-layer)
  - [Combined headroom estimate](#combined-headroom-estimate)
- [8. Sharing image storage across machines via NFS](#8-sharing-image-storage-across-machines-via-nfs)
  - [What you can't naively share](#what-you-cant-naively-share)
  - [What you *can* do](#what-you-can-do)
  - [What I'd actually do for a same-DC fleet](#what-id-actually-do-for-a-same-dc-fleet)
- [9. Production context: very large AI/ML images and what that changes](#9-production-context-very-large-aiml-images-and-what-that-changes)
  - [Why these images are huge](#why-these-images-are-huge)
  - [What that does to the recommendations](#what-that-does-to-the-recommendations)
  - [Your current settings](#your-current-settings)
  - [Where the 1 TB on disk really lives](#where-the-1-tb-on-disk-really-lives)
  - [Pre-warming as a tactic](#pre-warming-as-a-tactic)
- [10. Enabling the containerd image store: how, and tradeoffs](#10-enabling-the-containerd-image-store-how-and-tradeoffs)
  - [How to enable](#how-to-enable)
  - [What happens to your existing images](#what-happens-to-your-existing-images)
  - [Rollback](#rollback)
  - [Tradeoffs - what you gain](#tradeoffs---what-you-gain)
  - [Tradeoffs - what you lose / pay attention to](#tradeoffs---what-you-lose--pay-attention-to)
  - [Concrete enablement plan for the RunPod fleet](#concrete-enablement-plan-for-the-runpod-fleet)
  - [Pre-flight checklist](#pre-flight-checklist)
- [11. Where I'd benchmark first](#11-where-id-benchmark-first)

---

## 1. `registry-mirrors`

### Where it lives

- Config struct: [`daemon/pkg/registry/config.go#L25`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/pkg/registry/config.go#L25) -
  `Mirrors []string \`json:"registry-mirrors,omitempty"\``
- Load + dedupe: [`config.go#L110-L141`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/pkg/registry/config.go#L110-L141) - `loadMirrors()`
- URL validation: [`config.go#L265-L290`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/pkg/registry/config.go#L265-L290) - `ValidateMirror()`
- SIGHUP reload: [`daemon/reload.go#L118`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/reload.go#L118), [`reload.go#L162-L190`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/reload.go#L162-L190)
- Mirrors are consumed when picking endpoints in the legacy path
  (`daemon/internal/distribution/registry.go`) and through the resolver in the
  containerd path (`daemon/containerd/resolver.go`).

### Configuration options

All set in `/etc/docker/daemon.json`, picked up at start and on `SIGHUP`:

```json
{
  "registry-mirrors": [
    "https://mirror-a.dc.example.net",
    "https://mirror-b.dc.example.net"
  ],
  "insecure-registries": ["mirror-a.dc.example.net:5000"]
}
```

- Order matters. Endpoints are tried top-to-bottom in
  [`registry.go LookupPullEndpoints`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/pkg/registry/registry.go)
  via the `ServiceConfig.Mirrors` slice.
- Reloadable live via `kill -HUP $(pidof dockerd)` - see
  [`reload.go reloadRegistryConfig`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/reload.go#L118).
- Per-registry mirror overrides (different mirror per upstream) are **not
  supported**. The `Mirrors` field is global for Docker Hub only; other
  registries are contacted directly. To mirror a private registry you must
  use the registry's own pull-through config.
- CLI equivalent: `dockerd --registry-mirror=https://mirror-a ...`. Pass
  the flag multiple times for multiple mirrors.

### Perf notes

- `loadMirrors` does an O(N²) dedupe with `slices.Contains` on a
  presumed-small list; fine for ~tens of mirrors, never a bottleneck.
- Validation is per-URL string work, runs only at daemon start / reload.
- **There is no health-check or latency-ranking of mirrors.** They are tried
  in order until one returns success. If you run multiple mirrors for
  HA/locality, dockerd will keep hammering a slow one before falling over.

### Alternative: front mirrors with HAProxy or nginx

dockerd's mirror logic is dumb (in-order, no health checks). The pragmatic
fix today is to **put a real reverse proxy in front of your mirrors** and
configure dockerd with a single endpoint pointing at the proxy.

**HAProxy** (mode `http`, with active health checks and **consistent
hashing on the URI** so the same blob digest always routes to the same
cache node):

```haproxy
frontend registry_mirror
    bind *:443 ssl crt /etc/haproxy/registry.pem alpn h2,http/1.1
    mode http
    default_backend registry_backends

backend registry_backends
    mode http

    # --- Consistent-hash routing keyed on the request URI ---
    # Docker blob URLs look like /v2/<name>/blobs/sha256:<digest>.
    # Hashing on the URI sends the same digest to the same cache node,
    # so cache hit rate scales with the number of mirrors instead of
    # 1/N as it would with round-robin/leastconn.
    balance uri whole
    hash-type consistent sdbm avalanche

    # --- Health checks ---
    option httpchk GET /v2/
    http-check expect status 200,401   # 401 is a healthy unauth response

    # --- Resilience ---
    option redispatch                  # retry on a different node if one fails
    retries 2
    timeout server 30m                 # large blobs may take minutes

    # --- Cache nodes (all primary - consistent hash partitions keys
    # across them). The `backup` node only takes traffic if every
    # primary is down.
    server mirror-a 10.0.1.10:5000 ssl verify none check inter 2s fall 3 rise 2
    server mirror-b 10.0.1.11:5000 ssl verify none check inter 2s fall 3 rise 2
    server mirror-c 10.0.1.12:5000 ssl verify none check inter 2s fall 3 rise 2
    server mirror-d 10.0.1.13:5000 ssl verify none check inter 2s fall 3 rise 2 backup
```

**How the consistent-hashing pieces fit together:**

- **`balance uri whole`** hashes the full request URI (including the
  digest portion of `/v2/<name>/blobs/sha256:<digest>`). The `whole`
  keyword extends hashing past the first `?`; without it HAProxy stops
  at the query string, which doesn't matter for blob GETs but is the
  safe default for manifest URLs with optional query params.
- **`hash-type consistent`** switches from the default modulo hash to a
  Karger-style consistent-hash ring. This is the key property: when one
  cache node drops out, only ~1/N of the keys (the ones that hashed to
  that node) need to remap; the other N-1 nodes keep all their
  previously-cached blobs. With the default modulo hash, *every* key
  remaps when N changes - cache cold-start across the entire fleet.
- **`sdbm`** is the hash function (HAProxy's default for `consistent`).
  Other choices: `djb2`, `wt6`, `crc32`, `none`. `sdbm` is fine for
  URLs; `wt6` (whirlpool-truncated) gives slightly more even
  distribution at small cost.
- **`avalanche`** runs an extra bit-mixing pass on the hash output to
  reduce clustering when the input keys share common prefixes (which
  Docker URIs absolutely do - they all start with `/v2/`).

**Why this beats `leastconn` for a cache tier specifically:**

- `leastconn` distributes *load* evenly, but the same blob digest can
  hit different cache nodes on successive pulls. Two pulls of the same
  78 GB image from two hosts may each miss cache and fetch upstream
  separately - **N× upstream bandwidth wasted**.
- `balance uri whole` + `hash-type consistent` ensures the second pull
  of any blob hits the same node that cached it the first time - the
  cache works as designed.
- The cost is uneven *connection* load if a few blobs are
  disproportionately popular (a "hot key" lands on one node). For
  Docker registries this is usually OK because the cache nodes are
  serving from local SSD and the load asymmetry is small relative to
  the avoided upstream miss cost.

**Other key points for a Docker registry backend:**

- The health check must hit `/v2/` and accept HTTP **401** as healthy
  (the registry returns 401 when unauthenticated, which means it's up).
  Treating only 200 as healthy will mark everything down.
- `option http-keep-alive` (default in modern HAProxy) is critical to
  reuse TLS connections across the dozens of blob GETs in one image
  pull.
- HTTP/2 on the frontend (`alpn h2,http/1.1` on the `bind` line) lets
  dockerd pipeline manifest + blob fetches over one TCP connection per
  client.
- `option redispatch` + `retries 2` ensures a failed request on one
  node is retried on a different node before HAProxy reports failure to
  dockerd. Combined with consistent hashing this is the "graceful
  failover" property: same-digest requests *normally* land on cache
  node X, but if X is down they reroute to cache node Y and keep working.
- `timeout server 30m` because the default 50s will kill a slow large-
  blob fetch.

**When NOT to use consistent hashing:**

- If your "cache" is actually a stateless reverse proxy with no local
  storage (just an authentication/rewrite layer), stick with
  `leastconn` - there's nothing to gain from locality.
- If you have only 2 cache nodes and uneven blob popularity, the hot-key
  problem can pin most traffic to one node. Add more nodes (4+) to
  spread the ring better, or fall back to `leastconn`.
- If cache nodes are heterogeneous (different disk sizes), HAProxy's
  `weight` parameter influences ring slot count proportionally, so
  bigger nodes can hold more of the hash space:
  `server mirror-a ... weight 200` (default weight is 1).

**nginx** is fine too, but its active health checks are commercial
(`nginx-plus`) - in OSS nginx you only get passive (failure-counted)
checks via `max_fails` / `fail_timeout`, which is strictly worse than
HAProxy for this purpose. If you must use OSS nginx, the pattern is:

```nginx
upstream registry_mirrors {
    least_conn;
    server 10.0.1.10:5000 max_fails=3 fail_timeout=30s;
    server 10.0.1.11:5000 max_fails=3 fail_timeout=30s;
    server 10.0.1.12:5000 backup;
    keepalive 32;
}

server {
    listen 443 ssl http2;
    location /v2/ {
        proxy_pass https://registry_mirrors;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;          # blobs are big; don't double-buffer
        proxy_request_buffering off;
    }
}
```

With either proxy, `daemon.json` collapses to:

```json
{ "registry-mirrors": ["https://registry-proxy.dc.example.net"] }
```

You now get: health-checked failover, even load distribution, observable
mirror health (HAProxy stats / nginx status), and a single TLS endpoint to
rotate. The downside is one extra hop and one more thing to operate -
worth it for any fleet > ~5 hosts.

A second approach worth mentioning: **run a pull-through cache** (the
upstream `distribution/distribution` registry has `proxy:` mode) on each
host or each rack, and put HAProxy in front of *those*. Cache hits stay
local; cache misses fall through to upstream. This is what most
production fleets eventually land on.

---

## 2. The pull pipeline (legacy / graphdriver path)

### Configuration options - which path runs?

**Since moby v25 / engine v2 the containerd image store is the DEFAULT.**
The legacy graphdriver path described in this section only runs in two
cases:

1. You explicitly disabled the snapshotter, or
2. The daemon detects an existing pre-containerd
   `/var/lib/docker/overlay2/` tree from a prior install and refuses to
   silently abandon those images.

The decision is made at start time in
[`daemon/image_store_choice.go determineImageStoreChoice`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/image_store_choice.go#L94-L153).
The relevant cases:

| `daemon.json` / env | Result |
|---|---|
| `{}` (default) on a fresh install | **containerd** (this is the new default) |
| `"features": {"containerd-snapshotter": true}` | **containerd**, explicit |
| `"features": {"containerd-snapshotter": false}` | **graphdriver**, explicit |
| Default + existing `/var/lib/docker/overlay2/` from older daemon | **graphdriver-prior** (i.e. legacy, to preserve data) |
| `DOCKER_DRIVER=overlay2` env var | Picks overlay2 specifically, implies graphdriver unless containerd is explicit |
| `--storage-driver overlay2` flag | Same as the env var |
| Windows | graphdriver (`windowsfilter`) by default |

To check what your daemon picked: `docker info | grep -E 'Storage|Snapshotter'`.
The same info is in `Info.UsesSnapshotter` returned by the engine API.

**To force the legacy path** (e.g. for debugging or to keep an existing
overlay2 store):

```json
{
  "features": { "containerd-snapshotter": false },
  "storage-driver": "overlay2",
  "max-concurrent-downloads": 6,
  "max-concurrent-uploads": 8
}
```

**Available `storage-driver` values** (Linux):
[`daemon/graphdriver/`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/graphdriver)
- `overlay2` - default and recommended on Linux
- `fuse-overlayfs` - rootless mode on kernels without unprivileged overlayfs
- `btrfs`, `zfs` - native CoW filesystems
- `vfs` - no CoW, copies every layer; testing only
- Windows: `windowsfilter`

You cannot mix-and-match: one driver per daemon, chosen at start.

**`storage-opts`** ([config.go#L199](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/config/config.go#L199))
takes driver-specific options like:
- `overlay2.size=20G` - per-container rootfs quota (needs xfs `pquota`)
- `overlay2.override_kernel_check=true` - bypass kernel version check
- `dm.basesize=20G` for the (now removed) devicemapper driver

### Top-level flow

`docker pull` → HTTP API → `daemon/server/router/image/...` →
`ImageService.PullImage` → `distribution.Pull` →
[`pull_v2.go puller.pull`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L74-L89).

1. **Resolve registry endpoint(s)** with mirror list applied.
2. **Fetch manifest** (manifest list / index → platform-specific manifest).
3. **Fetch config blob** ([`pullSchema2Config` at pull_v2.go#L778](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L778)).
4. **Schedule layer downloads** through `LayerDownloadManager`:
   [`xfer/download.go#L113`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/download.go#L113).
5. **Per-layer goroutine** in
   [`makeDownloadFunc`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/download.go#L230-L385):
   a. Open registry blob (`layerDescriptor.Download` at
      [pull_v2.go#L169](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L169)).
   b. **Download the compressed blob to a tempfile** (`io.Copy(tmpFile, …)`
      at [pull_v2.go#L249](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L249))
      while computing the SHA256 with a `digest.Verifier`.
   c. **Wait for parent layer to finish registering** (the serialization
      bottleneck) at
      [download.go#L320-L336](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/download.go#L320-L336).
   d. **Decompress + register** via
      [`layerStore.Register`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/layer/layer_store.go#L258),
      which calls `applyTar`:
      [layer_store.go#L218-L256](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/layer/layer_store.go#L218-L256).
   e. `applyTar` hands the decompressed stream to the graphdriver's
      `ApplyDiff`:
      [layer_store.go#L236](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/layer/layer_store.go#L236).
   f. Graphdriver does the actual untar -
      [`graphdriver/fsdiff.go#L135-L155`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/graphdriver/fsdiff.go#L135-L155)
      calls `ApplyUncompressedLayer` from
      `github.com/moby/go-archive/chrootarchive`.

### Concurrency knobs

- `DefaultMaxConcurrentDownloads = 3`, `DefaultMaxConcurrentUploads = 5`:
  [`daemon/config/config.go#L29-L36`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/config/config.go#L29-L36).
- Tunable via `max-concurrent-downloads` / `max-concurrent-uploads` in
  `daemon.json`; live-reloadable.
- The scheduler is `transferManager` at
  [xfer/transfer.go#L285-L400](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/transfer.go#L285-L400) -
  a slot pool plus a FIFO `waitingTransfers []chan struct{}` queue.
- `maxDownloadAttempts = 5` retries with linear backoff:
  [xfer/download.go#L19](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/download.go#L19).

### How `transferManager` actually works

`transferManager` is a small handwritten scheduler living in
[`daemon/internal/distribution/xfer/transfer.go`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/transfer.go).
It does **three** jobs:

1. **Deduplicate** in-flight transfers by key (e.g. two `docker pull`s of
   the same image at the same time share one network fetch).
2. **Cap concurrency** at `concurrencyLimit` (3 by default).
3. **Multiplex progress events** to multiple watchers (CLI clients
   listening to the same pull stream).

Internal state ([transfer.go#L285-L300](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/transfer.go#L285-L300)):

```go
type transferManager struct {
    mu               sync.Mutex
    concurrencyLimit int                          // 3 by default
    activeTransfers  int                          // currently running
    transfers        map[string]transfer          // dedupe by key
    waitingTransfers []chan struct{}              // FIFO of pending starts
}
```

**Submission path** ([`transfer.go#L312-L383`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/transfer.go#L312-L383)):

1. Caller invokes `transferManager.transfer(key, xferFunc, progressOutput)`.
2. **Dedup check**: if `transfers[key]` exists and isn't cancelled, attach
   the caller as a watcher and return - no new download.
3. **Slot allocation**: each transfer gets a `start chan struct{}` and an
   `inactive chan struct{}`.
   - If `activeTransfers < concurrencyLimit`: close `start` immediately
     (the worker proceeds), increment `activeTransfers`.
   - Otherwise: append `start` to `waitingTransfers` and the worker
     blocks on `<-start` until promoted.
4. Spawn a goroutine to broadcast progress on `mainProgressChan` to all
   watchers, and a second goroutine that waits for `<-inactive` or
   `<-xfer.done()`:
   - `inactive` is closed by the worker once it stops actively pushing
     data (e.g. it's waiting for a parent layer's registration). This
     **frees the slot for a waiting transfer** without waiting for the
     worker to fully finish.
   - `done` is closed when the worker exits. At that point the entry is
     removed from `transfers[]` and the `xfer.close()` releases watchers.

**Slot accounting** ([`transfer.go#L386-L400`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/transfer.go#L386-L400)):
when a transfer becomes inactive *and* the start channel was already
closed, `inactivate()` either promotes the head of `waitingTransfers`
(closing its `start` channel) or decrements `activeTransfers`. This is
the key reason concurrent pulls of overlapping images don't deadlock:
parent-waiting layers stop consuming a slot.

**Progress broadcast** ([`transfer.go#L106-L210`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/transfer.go#L106-L210))
is a hand-rolled fan-out: a single broadcaster goroutine reads from
`mainProgressChan` and pings each watcher's `signalChan`. Watchers read
`lastProgress` under `t.mu`. This is roughly equivalent to a
`broadcast()` on a condition variable but implemented with channels.

**The `inactive` hand-off is subtle and important.** Without it, all
slots would block on parent-waiting children while the actual fetch is
done, and you'd get worse concurrency than `concurrencyLimit`. See
`makeDownloadFunc`
[`download.go#L318`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/download.go#L318):
`close(inactive)` happens right after the network fetch finishes and
before waiting on `parentDownload.done()`.

### Per-entry batching: is there an opportunity inside one layer?

When I said earlier that the untar processes "one entry at a time", I was
describing the structure of
[`vendor/github.com/moby/go-archive/diff.go UnpackLayer`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/vendor/github.com/moby/go-archive/diff.go#L22-L196):

```go
for {
    hdr, err := tr.Next()   // (1) read next tar header from the stream
    if errors.Is(err, io.EOF) { break }
    // ... whiteout handling, hardlink retargeting ...
    if err := createTarFile(path, dest, srcHdr, srcData, options); err != nil {
        return 0, err       // (2) open + write + setxattr + close on disk
    }
    // ... append to dirs[] for end-of-layer mtime fixup ...
}
```

The serial part is **step (1)**: tar is a sequential stream format. You
cannot ask for "entry 5" without having read entries 0-4, because the
length of each entry is in its header and entries are variable-size.

But **step (2) is parallelizable** with care. Here's the design:

| Tar entry type | Can run in parallel? | Why / why not |
|---|---|---|
| `TypeReg` (regular file, full path resolvable) | **Yes** | Independent file create + write. The body bytes are owned by the parent tar reader, so workers must copy or stream into their own buffers before yielding back to the reader. |
| `TypeDir` | **Yes** with care | Implied-parent dirs must already exist before any file is created in them. `createImpliedDirectories` already handles this; you'd dispatch directory creates first, then files under them. |
| `TypeSymlink` | **Yes** | Just an `lsymlinkat` syscall, no body. |
| `TypeLink` (hardlink) | **No** until target file is committed | Linkname must exist. Defer to a 2nd pass after all regular files are done. |
| `TypeChar`, `TypeBlock`, `TypeFifo` | Yes | Tiny syscalls, no body. |
| AUFS whiteouts | Sequential with surrounding ops | They imply deletes; safer to leave in-order. |
| AUFS `.wh..wh.plnk` hardlink-store | Sequential | Used as a hardlink source for later entries; needs to be on disk first. |
| End-of-layer dir mtime fixup | Sequential | Must be after all file creation. |

A worker-pool design that respects these constraints:

1. **Single reader goroutine** drains `tr.Next()` + reads the body.
   For small files (< 64 KB say), buffer the body inline; for large
   files, hand off an `io.LimitReader` and block until the worker says
   "done reading body". The reader does not return to `tr.Next()` until
   the body has been consumed - tar's nature.
2. **N worker goroutines** consume jobs from a channel.
   Job = `{header, body []byte or io.Reader, destPath}`.
3. **Hardlink deferral queue**: workers see `TypeLink` and push it onto
   a side slice instead of trying to materialize it. After the main
   loop ends, do a final pass (still parallel) over the link queue.
4. **Directory mtime fixup**: unchanged, do it last as today.

Theoretical wins:

- For typical Python/ML layers with thousands of small regular files
  (no body-streaming bottleneck), N workers reduce wall time roughly
  `min(N, num_files / (CPU_throughput / syscall_cost))`. On a 16-core
  machine with 50k small files, expect 6-10x speedup on the extract
  step.
- For a few huge files (model weights), parallelism inside one file
  doesn't help (you're disk-bandwidth bound and the tar reader is
  single-threaded for body bytes anyway). Multiple files in flight
  still helps because while file A is writing, file B can be calling
  `setxattr` etc.

Practical pitfalls:

- The reader can't release a `srcData` reader until the worker is done
  with it, so the channel needs back-pressure (bounded depth).
- `chrootarchive`'s re-exec model assumes a single `archive.Unpack`
  call. The worker pool has to live inside the re-exec'd child or you
  need to redesign the chroot boundary (probably move to `openat2` per
  worker; see §5.1).
- Hardlink targets must be resolvable; if a layer ships `linkname`
  pointing to a path that wasn't seen yet in the tar, you fall back
  to a serial second pass, which is what the AUFS code already does
  via `aufsHardlinks` map ([diff.go#L36](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/vendor/github.com/moby/go-archive/diff.go#L36)).

This is the single largest unpack speedup short of switching to a remote
snapshotter. It's also a substantial patch to `moby/go-archive`. See
§9 for how I'd benchmark it.

### Why unpack is "serial"

The per-layer goroutine starts the *download* as soon as a slot is free, but
registration blocks on `parentDownload.done()` and only then sets
`parentLayer = l.ChainID()` before calling `Register`
([download.go#L320-L336](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/download.go#L320-L336)).
That is because each new layer is created with `driver.Create(cacheID, pid, …)`
on top of the *parent's* cache ID
([layer_store.go#L307](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/layer/layer_store.go#L307)),
so the parent must exist on disk first.

Within a single layer, the untar inside chrootarchive is **one goroutine
streaming a tar reader and creating files/dirs/symlinks/xattrs one entry at
a time** - see
[`vendor/github.com/moby/go-archive/chrootarchive/diff.go#L14-L22`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/vendor/github.com/moby/go-archive/chrootarchive/diff.go#L14-L22).

---

## 3. The containerd-backed path

`daemon/containerd/image_pull.go` is much shorter because the heavy lifting
sits in vendored `containerd`:

- Entry point: [`PullImage`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/containerd/image_pull.go#L43).
- The actual work is `i.client.Pull(...)` at
  [image_pull.go#L240](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/containerd/image_pull.go#L240).
  `containerd.WithPullUnpack` ([image_pull.go#L226](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/containerd/image_pull.go#L226))
  tells containerd to download to the **content store** and then **unpack
  into a snapshotter** (`overlayfs` by default, also `native`, `btrfs`,
  `zfs`, or remote ones like `stargz`/`nydus`).
- Image-level metadata, snapshot creation, and lease handling are in this
  file; the bytes flow lives in containerd's `core/remotes/docker` and
  `core/snapshots/overlay`.

Important: even in this path **the per-layer ordering constraint still
applies**. Containerd's unpacker also walks layers in chain order because
the snapshotter mounts diff N over the committed snapshot of N-1.

### Configuration options

Selecting and tuning the containerd path:

```json
{
  "features": { "containerd-snapshotter": true },
  "max-concurrent-downloads": 6,
  "max-concurrent-uploads": 8,
  "data-root": "/var/lib/docker"
}
```

- **`features.containerd-snapshotter`** is the master switch. Default is
  now `true` (containerd is on); set to `false` to force the legacy path
  ([`image_store_choice.go#L115`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/image_store_choice.go#L115)).

- **Snapshotter selection** is done at engine start. There is no
  `daemon.json` field for "which snapshotter" today; dockerd defaults to
  `overlayfs`. To use a remote snapshotter (stargz/nydus) you must
  configure it on the underlying containerd:
  - `/etc/containerd/config.toml` registers the snapshotter plugin and
    its proxy address.
  - Then dockerd inherits whatever the user-configured containerd offers.
  - The wire-up call is `containerd.WithPullSnapshotter(i.snapshotter)`
    at [`image_pull.go#L228`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/containerd/image_pull.go#L228).

- **`max-concurrent-downloads` / `-uploads`** apply to **both** backends.
  In the containerd path they're forwarded to the `transferService` that
  drives `core/remotes/docker`.

- The containerd **content store** lives under
  `/var/lib/docker/containerd/io.containerd.content.v1.content/` when
  dockerd is in containerd-snapshotter mode (a separate namespace from
  the system-level containerd if you have one).

- Switching backends after-the-fact is not reversible without manual data
  surgery; the daemon refuses to silently migrate.
  [`image_store_choice.go#L130-L134`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/image_store_choice.go#L130-L134)
  detects prior overlay2 data and downgrades the choice.

- For **lazy-loading snapshotters** (stargz, nydus, soci), additional
  client-side configuration goes in containerd's config, not dockerd's:
  ```toml
  # /etc/containerd/config.toml
  [proxy_plugins]
    [proxy_plugins.stargz]
      type = "snapshot"
      address = "/run/containerd-stargz-grpc/containerd-stargz-grpc.sock"
  ```
  Then start dockerd with `--containerd /run/containerd/containerd.sock`
  and ensure the `stargz` snapshotter is selectable by your tooling.

---

## 4. Storage / unpack internals

| Component | File | What it does |
|---|---|---|
| Layer store (legacy) | [`daemon/internal/layer/layer_store.go`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/layer/layer_store.go) | Tracks `chainID` → `roLayer`, owns metadata transactions, calls graphdriver. |
| Tar-split sidecar | [`layer_store.go#L218-L256`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/layer/layer_store.go#L218-L256) | While untarring, also writes a `tar-split` JSON stream so the *exact* tar bytes can be re-derived later for `docker save` / push. |
| Graphdriver dispatch | [`daemon/graphdriver/fsdiff.go`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/graphdriver/fsdiff.go) | "Naive" diff driver; wraps any driver that doesn't implement Diff/Apply itself. |
| overlay2 driver | [`daemon/graphdriver/overlay2/overlay.go`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/graphdriver/overlay2/overlay.go) | Lays out `diff/`, `link`, `lower`, `merged`, `work`; mounts overlayfs. |
| Untar in a chroot | [`vendor/github.com/moby/go-archive/chrootarchive/`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/vendor/github.com/moby/go-archive/chrootarchive) | Re-execs itself inside `chroot()` so a malicious tar can't escape the layer dir via `..` symlinks. |

### Configuration options

Storage location and quota controls:

```json
{
  "data-root": "/mnt/fast-ssd/docker",
  "exec-root": "/var/run/docker",
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.size=50G"
  ]
}
```

- **`data-root`** (default `/var/lib/docker`): the entire image + container
  + volume tree lives here. Defined at
  [`daemon/config/config.go Root`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/config/config.go).
  Put this on the fastest local SSD you have; this is where unpack writes
  go. **Do not** put it on NFS (see §8).

- **`storage-driver`** for the graphdriver path (overlay2, fuse-overlayfs,
  btrfs, zfs, vfs, windowsfilter). Only applies when
  `containerd-snapshotter` is false or graphdriver-prior. See §2 config
  table.

- **`storage-opts`** (string array) is driver-specific. For overlay2:
  - `overlay2.size=N` - per-layer quota (requires XFS with `pquota`).
  - `overlay2.override_kernel_check=true` - bypass the kernel version
    sanity check at start.
  - `overlay2.mountopt=...` - extra options passed to the overlayfs
    mount syscall (e.g. `metacopy=on`).

- **Layer depth limit**: `maxLayerDepth = 250` ([`layer_store.go`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/layer/layer_store.go))
  for the legacy path; overlay2 itself caps at 128 lower dirs
  ([`overlay.go#L76`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/graphdriver/overlay2/overlay.go#L76)).
  Both are hard limits; an image with more layers than this won't pull.

- **`builder.gc`** (the build cache GC) is in the same config file and
  also touches `data-root` — sized too small, it will evict layers you
  pulled. Default is uncapped.

- **`--default-runtime`** doesn't affect pulls but does affect what
  unpacks-to-rootfs looks like for OCI runtime hooks.

There is **no configuration** to:
- Skip xattr application on unpack (it's hardcoded "best effort").
- Choose tar-split on/off (always on in the legacy path).
- Pin layer extraction to specific CPUs (single-threaded, no GOMAXPROCS-style knob).
- Use io_uring (not wired in at all).

Those are all candidates for future flags - see §5.

---

## 5. Performance review

Below: real candidates ranked by likely impact on a fast NIC / fast SSD.

### 5.1 Single-threaded per-layer tar extract (biggest win)

**What:** Each layer goes through one goroutine that reads the tar header,
creates the file, writes its bytes, then moves on.
**Where:** chrootarchive `applyLayerHandler` → `archive.Unpack` in the
vendored `moby/go-archive`. The driver entry is
[`fsdiff.go#L149`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/graphdriver/fsdiff.go#L149).
**Why it hurts:** A typical Python / ML image has tens of thousands of
small files plus a handful of large ones. Wall time is dominated by
`openat() + write() + close() + (l)setxattr()` syscall storms on the small
files and a single CPU's memcpy on the large ones.

**Possible wins:**

- **Fan out file writes across N worker goroutines** with a bounded
  channel. The tar reader stays single-threaded (tar is inherently
  sequential), but the worker pool can parallelize `open/write/close` and
  `setxattr`. You need ordering only for hard-link targets and rename
  semantics - those can be handled by deferring "link" entries to a second
  pass. Containerd has done similar experiments (see the `unpack`
  goroutine pattern in `core/snapshots/overlay`).
- **`io_uring` for the file-write side.** Linux >= 5.6 lets you batch
  `openat2`, `write`, `close`, `fsetxattr`, and `fdatasync` as a single
  submission queue. There is **zero io_uring in moby/moby today**
  (`grep io_uring` → 0 hits). A drop-in replacement for the per-file
  `write` loop using `liburing`-style batching (via
  `github.com/iceber/iouring-go` or `github.com/godzie44/go-uring`) would
  cut syscall + scheduler overhead by ~50% on small-file-heavy layers.
- **Skip the chroot re-exec** when the destination is already a private
  mount-namespaced path (e.g. when running unprivileged or with a known
  safe driver). The `reexec` adds a `fork+exec` per layer:
  [`archive_unix_nolinux.go#L71`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/vendor/github.com/moby/go-archive/chrootarchive/archive_unix_nolinux.go#L71).
  On Linux the safer modern approach is `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS)`
  per entry, which avoids both the chroot and the re-exec while keeping the
  symlink-escape guarantee. This is a meaningful change but the syscall is
  stable since kernel 5.6.

### 5.2 Decompression is on the hot path and single-threaded

`compression.DecompressStream` is called inside the per-layer goroutine at
[`download.go#L341`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/download.go#L341).
For gzip blobs that's `compress/gzip` (pure Go, ~200 MB/s on one core).

**Possible wins:**

- Swap `compress/gzip` for `klauspost/compress/gzip` - drop-in,
  ~3x faster, already used elsewhere in the Docker ecosystem.
- For zstd-compressed blobs (OCI media type
  `application/vnd.oci.image.layer.v1.tar+zstd`), use
  `klauspost/compress/zstd` with `WithDecoderConcurrency`.
- Better yet: hand the compressed file to an external `pigz`-style
  multi-threaded decoder once the blob hits disk; only practical if the
  blob is large enough to amortize the process startup.

#### Concrete code change for klauspost/compress

The decompression entry is in
[`vendor/github.com/moby/go-archive/compression/compression.go`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/vendor/github.com/moby/go-archive/compression).
Today (approximate) it looks like:

```go
// compression.go - current
import (
    "compress/gzip"
    "io"
    // ...
)

func DecompressStream(archive io.Reader) (io.ReadCloser, error) {
    buf := bufio.NewReader(archive)
    bs, err := buf.Peek(10)
    if err != nil && err != io.EOF {
        return nil, err
    }
    switch compression := Detect(bs); compression {
    case Gzip:
        return gzip.NewReader(buf)
    case Zstd:
        return zstd.NewReader(buf)
    // ...
    }
}
```

After (drop-in, no API change for callers):

```go
// compression.go - proposed
import (
    kgzip "github.com/klauspost/compress/gzip"
    kzstd "github.com/klauspost/compress/zstd"
    "io"
    "runtime"
    // ...
)

func DecompressStream(archive io.Reader) (io.ReadCloser, error) {
    buf := bufio.NewReader(archive)
    bs, err := buf.Peek(10)
    if err != nil && err != io.EOF {
        return nil, err
    }
    switch compression := Detect(bs); compression {
    case Gzip:
        // klauspost/compress/gzip is ~3x faster than stdlib on amd64
        // and uses AVX2 if present.
        return kgzip.NewReader(buf)
    case Zstd:
        // Multi-threaded decode if the blob has independent frames
        // (most registry zstd blobs do). Falls back to 1 worker
        // gracefully otherwise.
        dec, err := kzstd.NewReader(buf,
            kzstd.WithDecoderConcurrency(runtime.GOMAXPROCS(0)),
            kzstd.WithDecoderLowmem(false),
        )
        if err != nil {
            return nil, err
        }
        return dec.IOReadCloser(), nil
    // ...
    }
}
```

That's the entire change for decode. `klauspost/compress/gzip` is API-
compatible with `compress/gzip` (same `NewReader` / `NewWriter`
signatures), so callers don't need to change. The `go.mod` already
transitively depends on `klauspost/compress` (containerd pulls it in),
so you don't add a new direct dep weight - just import it.

For **encode** (push side - `daemon/internal/distribution/push_v2.go`
and the `pkg/archive` `CompressStream`):

```go
// Was:
gz, _ := gzip.NewWriterLevel(buf, gzip.DefaultCompression)

// To:
gz, _ := kgzip.NewWriterLevel(buf, kgzip.DefaultCompression)
```

Same level constants, same write semantics. Klauspost's encoder is also
~2x faster on amd64 thanks to a hand-written deflate.

**Expected wall-clock impact** on a 200 MB compressed gzip layer: today
~1 s of CPU; after, ~0.3 s. Modest in isolation but it stacks with the
serial-layer-chain constraint - every layer in the chain saves that
time.

### 5.3 Tempfile double-write

The pull path writes the compressed blob to a tempfile
([`pull_v2.go#L249`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L249)),
then re-reads it, decompresses, and untars. That's **2× the disk write
volume** of the compressed blob, plus a full re-read.

**Possible wins:**

- Stream decompress + untar inline with download (no tempfile) when the
  layer has no parent yet to depend on. The tempfile exists today to allow
  resuming a failed download and to honor the chain-order serialization,
  but for a *first* pull of an image where the parent is ready, you can
  pipe HTTP body → gunzip → tar reader directly.
- Use `O_TMPFILE` + `linkat` for the staging file - skips a directory
  entry and lets the kernel free the inode automatically on failure.
- On modern kernels, use `copy_file_range` between the staged tempfile and
  the final destination - zero-copy in the kernel.

#### Concrete code: `O_TMPFILE` + `linkat` for the staging file

`createDownloadFile` ([pull_v2.go createDownloadFile](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go))
today does roughly `os.CreateTemp(dir, "GetImageBlob*")`. That creates a
named entry in the directory, which has to be deleted on cleanup. The
modern Linux pattern:

```go
// daemon/internal/distribution/pull_v2_unix.go (proposed addition)
//go:build linux

package distribution

import (
    "os"
    "golang.org/x/sys/unix"
)

// createDownloadFile creates an unnamed file in dir using O_TMPFILE.
// The file has no directory entry; it's pinned by the returned *os.File.
// On close (or daemon crash) the inode is freed automatically.
// If we want to keep the contents, call linkat(2) with AT_SYMLINK_FOLLOW
// to give it a name.
func createDownloadFile(dir string) (*os.File, error) {
    fd, err := unix.Open(dir,
        unix.O_TMPFILE|unix.O_RDWR|unix.O_CLOEXEC,
        0o600)
    if err != nil {
        if err == unix.EOPNOTSUPP || err == unix.EISDIR {
            // Filesystem doesn't support O_TMPFILE (older tmpfs, NFS).
            // Fall back to old behavior.
            return os.CreateTemp(dir, "GetImageBlob")
        }
        return nil, err
    }
    return os.NewFile(uintptr(fd), "[O_TMPFILE]"), nil
}
```

Tradeoff: resume across daemon restarts becomes impossible because the
file disappears on close. So this is only safe for the "fresh download"
case; the resume code at
[pull_v2.go#L182-L198](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L182-L198)
needs to be gated on whether the prior tempfile is a "real" named file.

#### Concrete code: `copy_file_range` for tempfile → layer dir handoff

If you keep the tempfile + decompress design but want to avoid one
re-read pass through userspace, `copy_file_range(2)` lets the kernel
copy directly between file descriptors. Useful when you're staging a
decompressed tar to one place and want to deliver it to another (e.g.
for the tar-split sidecar or for a layer-blob cache):

```go
// pkg/ioutils/copy_file_range_linux.go (new file)
//go:build linux

package ioutils

import (
    "io"
    "os"
    "golang.org/x/sys/unix"
)

// FastFileCopy copies from src to dst using copy_file_range(2) which
// can offload to the filesystem (reflinks on btrfs/xfs+reflink) or
// stay entirely in the kernel page cache (zero-copy on others).
// Falls back to io.Copy on EXDEV (cross-FS) or older kernels.
func FastFileCopy(dst, src *os.File) (int64, error) {
    var total int64
    for {
        // copy_file_range returns the number of bytes copied.
        // Pass len=1<<30 to ask the kernel to copy as much as it can.
        n, err := unix.CopyFileRange(int(src.Fd()), nil,
            int(dst.Fd()), nil, 1<<30, 0)
        if err != nil {
            if total == 0 && (err == unix.ENOSYS || err == unix.EXDEV ||
                              err == unix.EINVAL) {
                // Pre-4.5 kernel, cross-FS, or unsupported pair.
                // Reset positions and fall back.
                if _, e := src.Seek(0, io.SeekStart); e != nil {
                    return 0, e
                }
                return io.Copy(dst, src)
            }
            return total, err
        }
        if n == 0 {
            return total, nil
        }
        total += int64(n)
    }
}
```

Where this applies:

- **The blob → tar-split sidecar path** doesn't need it (the JSON
  metadata stream is small and incidental to the file write).
- **The layer-blob caching path** in containerd's content store
  (`core/content/local/store.go`) is where this matters - they want to
  reflink on btrfs and that's exactly what `copy_file_range` does on
  CoW filesystems.
- On overlay2, where every "create file in layer dir" is just a
  filesystem create, this doesn't speed anything up; the tar entry
  body is the only thing being written, and it's coming from a
  decompressed stream that doesn't have a source fd.

So `copy_file_range` is a smaller win than the previous suggestions; I'd
prioritize it only if you're also touching the content-store layout.

### 5.4 Tar-split JSON sidecar overhead

For every file written to disk, `layer_store.applyTar`
([line 231](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/layer/layer_store.go#L231))
also writes a JSON record into a gzip stream via `tar-split`. That doubles
the tar entry's per-file CPU cost. It exists so `docker save` / push can
recreate the *exact* original tar layout (gzip metadata, ordering, padding).

**Possible wins:**

- Make tar-split optional. If the daemon is "pull-only" (which is the case
  for most production hosts), tar-split is dead weight. A daemon config
  flag `--skip-tar-split` saves ~15-25% CPU on extraction.
- The containerd path can avoid this entirely by storing the original
  compressed blob in the content store and reusing it on push.

### 5.5 Allocator / GC churn

Spots I'd profile first:

- `progress.NewProgressReader` wraps the read stream and emits messages
  through a channel (`mainProgressChan`) per write
  ([download.go#L338](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/download.go#L338)).
  The reader allocates a small struct per `Progress` event. On a 1 GB/s
  pull you can get tens of thousands of these per second. Rate-limit to
  e.g. one update every 100 ms.
- `ioutils.NewCancelReadCloser` adds a goroutine per layer that blocks on
  `ctx.Done()`. Cheap but ×N layers ×N images concurrent matters under
  load.
- `transferManager.waitingTransfers []chan struct{}` is a sliced FIFO:
  [`transfer.go#L386-L399`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/transfer.go#L386-L399).
  It re-slices on every dequeue, which causes a hidden O(N) amortized
  reallocation pattern; under heavy parallel `docker pull` it's not a hot
  spot, but the right structure here is a real ring or `container/list`.
- `referrersList.readFrom` in the containerd path uses
  `slices.DeleteFunc` on each manifest insertion
  ([image_pull.go#L444](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/containerd/image_pull.go#L444)).
  O(N) per insertion; fine for typical referrer counts, would be a smell
  if image-signing artifacts get huge.

#### Where `sync.Pool` would help

A `sync.Pool` is a no-op unless you can:
1. Get pool-able value reuse on a hot path (objects allocated thousands
   of times per second), and
2. Pool objects that have a fixed (or bounded) size so the runtime
   doesn't trim pool entries between GCs uselessly.

Three concrete candidates in moby's pull path, each modeled on
[`gosrt/buffers.go PayloadBufferPool`](https://github.com/randomizedcoder/gosrt/blob/main/buffers.go):

**(a) The HTTP-body read buffer per layer.** Today `io.Copy(tmpFile,
io.TeeReader(reader, ld.verifier))` at
[pull_v2.go#L249](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L249)
uses Go's `io.Copy` internal 32 KiB buffer. With high `max-concurrent-
downloads` and many small layers, this is allocated and discarded
constantly. A pool:

```go
// daemon/internal/distribution/xfer/pools.go (new)

package xfer

import "sync"

// CopyBufferSize is sized to amortize gzip block boundaries and HTTP
// chunk reads. 64 KiB is the sweet spot for net/http response bodies.
const CopyBufferSize = 64 * 1024

var copyBufPool = sync.Pool{
    New: func() any {
        b := make([]byte, CopyBufferSize)
        return &b
    },
}

// GetCopyBuffer returns a 64 KiB buffer for io.CopyBuffer. Caller must
// return it via PutCopyBuffer.
func GetCopyBuffer() *[]byte { return copyBufPool.Get().(*[]byte) }
func PutCopyBuffer(b *[]byte) { copyBufPool.Put(b) }
```

Then in `pull_v2.go`:

```go
bufPtr := xfer.GetCopyBuffer()
defer xfer.PutCopyBuffer(bufPtr)
_, err = io.CopyBuffer(tmpFile, io.TeeReader(reader, ld.verifier), *bufPtr)
```

Note the gosrt pattern: store `*[]byte` not `[]byte` in the pool. This
avoids the slice header being heap-escaped on each `Put`/`Get` and is
the textbook fix for the "sync.Pool[[]byte] has no effect" footgun.

**(b) The tar header / `createTarFile` scratch buffer.** During unpack,
each regular file's body is read into the destination via `io.Copy`,
which again uses the implicit 32 KiB buffer. For 50k files per layer
that's 50k allocations of 32 KiB each (1.5 GB of garbage). A pool of
file-body buffers keyed off `MaxPayloadBufferSize`-style constants would
cut GC pressure dramatically. Same shape as (a).

**(c) The `transferManager` start/done channels.** Each transfer
allocates `start`, `inactive`, `releasedChan`, `running`,
`broadcastSyncChan`. Pooling channels is generally a bad idea (their
internal state varies), but the `*xfer` struct itself is
pool-candidate:

```go
var xferPool = sync.Pool{
    New: func() any { return new(xfer) },
}

func newTransfer() transfer {
    t := xferPool.Get().(*xfer)
    t.watchers = make(map[chan struct{}]*watcher)
    t.running = make(chan struct{})
    t.releasedChan = make(chan struct{})
    t.broadcastSyncChan = make(chan struct{})
    t.hasLastProgress = false
    t.broadcastDone = false
    t.closed = false
    t.ctx, t.cancel = context.WithCancel(context.Background())
    return t
}

// And in close()/Released(): xferPool.Put(t) once safe.
```

This is **only** worth it if you actually measure the transfer struct
showing up in heap profiles - it's modest churn (one per layer) vs the
copy buffers (one per write).

**Pattern to copy from gosrt:** the
[`buffers.go`](https://github.com/randomizedcoder/gosrt/blob/main/buffers.go)
single global pool with `GetBuffer()`/`PutBuffer()` helpers and a
`panic` if the pool ever gets the wrong type back is good defensive
hygiene; copy it as-is.

**One sharp edge.** gosrt uses fixed 1500-byte buffers because every
packet is sized to Ethernet MTU. moby's read buffers have less uniform
sizes (32 KiB? 64 KiB? configurable?). If you pool *variable* sizes you
end up with a `map[int]*sync.Pool` and lose the simplicity. Best to
pick one size for the io.Copy hot path (64 KiB) and a separate pool for
any rarer larger size if needed.

### 5.6 Syscall hygiene during untar

The per-file pattern is roughly: `mkdirat`, `openat`, `fchown`, `fchmod`,
one or more `fsetxattr`, optional `futimesat`, `write…`, `close`. That's
6-8 syscalls per file. On a layer with 50k tiny files that is **300k-400k
syscalls per layer, all on one CPU**. This is the single biggest reason
"unpack feels slow."

**Possible wins:**

- `io_uring` batch as described above.
- Skip `fsync` until end of layer; commit once. This is already roughly
  what overlay2 does, but verify under `strace -c`.
- Set xattrs in batch with a vectorized helper. Linux doesn't have a
  vectored `xattr` syscall, but you can avoid `fsetxattr` for every
  file: `BestEffortXattrs` already short-circuits failures
  ([fsdiff.go#L146](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/graphdriver/fsdiff.go#L146));
  it does *not* skip the syscall on success. A "are we writing to a
  filesystem that supports user xattrs?" precheck would let you elide them
  entirely for tmpfs/NFS/etc.

### 5.7 No io_uring anywhere - and how gosrt's pattern would map

Confirmed by `grep -r io_uring daemon/ pkg/ vendor/` → **zero hits**. All
network I/O is `net/http` (epoll under the hood, which is fine), but all
file I/O is `os.File`/syscall. Anywhere we are syscall-bound rather than
CPU-bound is a candidate.

The good news: there is a working, vendored, in-house io_uring library
already shipped in another randomizedcoder project -
[`gosrt`](https://github.com/randomizedcoder/gosrt) - that we can lift
the patterns from wholesale. The library is `github.com/randomizedcoder/
giouring`, a maintained fork of `iceber/iouring-go` with a fix for ring
shutdown safety, vendored under
`~/Downloads/srt/gosrt/vendor/github.com/randomizedcoder/giouring/`.

#### Patterns to reuse from gosrt

**1. Batch submit, single-syscall.** gosrt's
[`submitRecvRequestBatch`](https://github.com/randomizedcoder/gosrt/blob/main/listen_linux.go#L827)
is the canonical pattern:

```go
// gosrt: collect N SQEs without submitting, then one ring.Submit() call
func (ln *listener) submitRecvRequestBatch(count int) {
    ring, _ := ln.recvRing.(*giouring.Ring)
    var sqes []*giouring.SubmissionQueueEntry
    var compInfos []*recvCompletionInfo
    var requestIDs []uint64

    for i := 0; i < count; i++ {
        bufferPtr, _ := GetRecvBufferPool().Get().(*[]byte)
        // ... build iovec/msghdr from pool buffer ...

        var sqe *giouring.SubmissionQueueEntry
        for j := 0; j < maxRetries; j++ {
            sqe = ring.GetSQE()
            if sqe != nil { break }
            time.Sleep(100 * time.Microsecond)
        }
        if sqe == nil { /* ring full, clean up */ break }

        sqe.PrepareRecvMsg(ln.recvRingFd, msg, 0)
        sqe.SetData64(requestID)
        sqes = append(sqes, sqe)
        // ...
    }

    if len(sqes) > 0 {
        _, err := ring.Submit()   // ONE syscall for the whole batch
        // ...
    }
}
```

The key idea is: `GetSQE()` returns a slot in the shared submission
ring without entering the kernel. The actual `io_uring_enter(2)` only
happens on `ring.Submit()`. So **N preparations + 1 submission = 1
syscall** instead of N.

**2. Buffer pool keyed off fixed size, `*[]byte` in pool.** From
[`buffers.go`](https://github.com/randomizedcoder/gosrt/blob/main/buffers.go):

```go
var PayloadBufferPool = &sync.Pool{
    New: func() any {
        buf := make([]byte, MaxPayloadBufferSize)
        return &buf
    },
}
```

The `*[]byte` indirection avoids the heap-escape footgun and lets the
runtime's per-P pool slot hold a fixed pointer.

**3. Decouple completion processing from resubmission.** From
[`recvCompletionHandler`](https://github.com/randomizedcoder/gosrt/blob/main/listen_linux.go#L932):

```go
batchSize := 256
pendingResubmits := 0
for {
    cqe, compInfo := ln.getRecvCompletion(ctx, ring)   // one at a time
    if cqe == nil { /* flush + continue */ continue }

    ln.processRecvCompletion(ring, cqe, compInfo)       // app-side work
    pendingResubmits++

    if pendingResubmits >= batchSize {
        ln.submitRecvRequestBatch(pendingResubmits)     // refill in batch
        pendingResubmits = 0
    }
}
```

Completions are consumed one at a time for low latency, but
resubmissions are amortized in batches of 256.

#### Mapping the pattern onto the moby unpack hot path

The unpack pattern we discussed in §5.6 was: `mkdirat`, `openat`,
`fchown`, `fchmod`, `fsetxattr`, `write`, `close`. Six to eight
syscalls per file. The io_uring equivalent:

```go
// daemon/internal/distribution/xfer/uring_unpack_linux.go (proposed)
//go:build linux

package xfer

import (
    "sync"
    "syscall"
    "github.com/randomizedcoder/giouring"
)

const (
    // Same shape as gosrt: a single global pool of fixed-size scratch
    // buffers for tar entry payloads up to 1 MiB. Larger files spill
    // to a second pool or direct allocation.
    UnpackBufferSize = 1 << 20
)

var unpackBufPool = sync.Pool{
    New: func() any { b := make([]byte, UnpackBufferSize); return &b },
}

// UnpackRing wraps a giouring.Ring sized for a single unpack worker.
// Held per goroutine; not shared (avoids the SQ contention gosrt
// already learned about in multi_iouring_design.md).
type UnpackRing struct {
    ring         *giouring.Ring
    pendingSubmit int
    batchSize    int
}

func NewUnpackRing(ringSize uint32) (*UnpackRing, error) {
    r, err := giouring.CreateRing(ringSize)
    if err != nil { return nil, err }
    return &UnpackRing{ring: r, batchSize: 64}, nil
}

// SubmitFile enqueues the create + write + xattr + close for one tar
// entry. The actual io_uring_enter happens when batchSize is reached
// or Flush is called explicitly (at end-of-layer).
func (u *UnpackRing) SubmitFile(dirFd int, hdr *TarHeader, body []byte) error {
    // OpenAt with O_CREAT|O_TRUNC|O_WRONLY
    sqe := u.ring.GetSQE()
    if sqe == nil {
        // Flush, then retry once.
        if _, err := u.ring.Submit(); err != nil { return err }
        u.pendingSubmit = 0
        sqe = u.ring.GetSQE()
        if sqe == nil { return syscall.EAGAIN }
    }
    sqe.PrepareOpenat(dirFd, hdr.Name,
        syscall.O_CREAT|syscall.O_TRUNC|syscall.O_WRONLY|syscall.O_CLOEXEC,
        uint32(hdr.Mode))
    sqe.SetFlags(giouring.SqeIoLink)   // chain to next op on same fd
    sqe.SetData64(makeUserData(opOpen, hdr.id))

    // Write the body. The "fd" used here is the result of the previous
    // OpenAt - the linked SQE gets it automatically when the kernel
    // chains operations.
    sqe = u.ring.GetSQE()
    sqe.PrepareWrite(-1 /* IOSQE_FIXED_FILE_LATER */, body, 0)
    sqe.SetFlags(giouring.SqeIoLink)
    sqe.SetData64(makeUserData(opWrite, hdr.id))

    // setxattr per attr in hdr.Xattrs (each its own SQE, also chained)
    for k, v := range hdr.Xattrs {
        sqe = u.ring.GetSQE()
        sqe.PrepareSetxattr(-1, k, v, 0)
        sqe.SetFlags(giouring.SqeIoLink)
        sqe.SetData64(makeUserData(opXattr, hdr.id))
    }

    // Close terminates the chain.
    sqe = u.ring.GetSQE()
    sqe.PrepareClose(-1)
    sqe.SetData64(makeUserData(opClose, hdr.id))

    u.pendingSubmit++
    if u.pendingSubmit >= u.batchSize {
        if _, err := u.ring.Submit(); err != nil { return err }
        u.pendingSubmit = 0
    }
    return nil
}

func (u *UnpackRing) Flush() error {
    if u.pendingSubmit > 0 {
        if _, err := u.ring.SubmitAndWait(uint32(u.pendingSubmit)); err != nil {
            return err
        }
        u.pendingSubmit = 0
    }
    return u.drainCompletions()
}

// drainCompletions reads N CQEs in batch via PeekBatchCQE.
func (u *UnpackRing) drainCompletions() error {
    var cqes [256]*giouring.CompletionQueueEvent
    for {
        n := u.ring.PeekBatchCQE(cqes[:])
        if n == 0 { return nil }
        for i := uint32(0); i < n; i++ {
            cqe := cqes[i]
            if cqe.Res < 0 {
                // Track error per entry via user_data.
                // ...
            }
            u.ring.CQESeen(cqe)
        }
    }
}
```

A few notes on this sketch:

- **`IOSQE_IO_LINK`** is the magic ingredient: chained SQEs run in
  order, each implicitly inheriting the fd from the previous successful
  open. The whole `open/write/setxattr×N/close` per file becomes one
  submission unit.
- **Batch size of 64-256.** gosrt landed on 256 for single-ring mode
  and 32 for multi-ring; for unpack I'd start at 64 because the average
  syscall is more expensive than a UDP recvmsg, so the latency cost of
  waiting for a full batch is comparable to a few syscalls.
- **One ring per unpack worker.** Two reasons: (a) `GetSQE`/`Submit`
  is not cleanly safe under high contention, see gosrt's
  `multi_iouring_design.md`; (b) one ring per worker pairs naturally
  with the worker-pool design from §2's "per-entry batching" section.
- **`PeekBatchCQE`** ([giouring/queue.go#L175](https://github.com/randomizedcoder/giouring/blob/main/queue.go#L175))
  drains the completion queue in one call, complementing the SQE batch.
- **The chrootarchive boundary**. Today the unpack runs inside a
  re-exec'd chroot child. io_uring rings created in the parent are not
  inherited across `execve` unless you pass the ring fd explicitly. You
  either (a) move the ring creation into the chroot child, or (b)
  abandon chroot in favor of `openat2(RESOLVE_BENEATH)` which gives the
  same escape-prevention guarantee without the re-exec.
- **Hardlinks** (`TypeLink`) cannot be chained because the kernel needs
  the target file fully visible; defer them to a second batch as in §2.

**Expected impact.** A pessimistic estimate using gosrt's measured
gains (~50-70% reduction in syscall overhead on the recv path):
on a 50k-file layer where syscall cost is dominant, expect 2-4x speedup
on the unpack stage. Combined with the worker-pool parallelism from §2,
a 5-10x overall improvement on small-file-heavy layers is realistic.

**Risks.**
- io_uring SQE/CQE ordering bugs are nasty; gosrt's
  `documentation/IO_Uring*.md` series catalogs the ones they hit.
  Reuse their test-matrix strategy (table-driven tests of recv reorder
  cases) for unpack.
- Older Linux (< 5.6) won't have `openat2`, and < 5.1 has no io_uring
  at all. Gate behind `unix.Statx` or a feature probe at start and
  fall back to the syscall path - same pattern as
  [`gosrt/io_uring_check.go`](https://github.com/randomizedcoder/gosrt/blob/main/io_uring_check.go).

---

## 6. How docker image pulls actually work (with code refs)

A pull of `docker.io/library/python:3.12` walks this state machine:

1. **CLI** posts `POST /images/create?fromImage=...&tag=...`.
2. **API router** lands in `daemon/server/router/image/image_routes.go`
   `postImagesCreate`.
3. **ImageService.PullImage** branches on the backend:
   - graphdriver backend: `daemon/internal/distribution/pull.go` `Pull()`
     → endpoint loop → `puller.pull` →
     [`pullTag`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L91).
   - containerd backend: [`daemon/containerd/image_pull.go PullImage`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/containerd/image_pull.go#L43).
4. **Manifest descent**: `GET /v2/<name>/manifests/<tag>`. If it's a
   manifest list / OCI index, pick the platform-matching manifest, then
   `GET` that.
5. **Config blob**: `GET /v2/<name>/blobs/sha256:<configDigest>`. Verified
   against the digest:
   [`pullSchema2Config`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L778).
6. **Layer descriptors** built into a `[]DownloadDescriptor`. Submit them
   to
   [`LayerDownloadManager.Download`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/download.go#L113).
7. **Per-layer worker** (concurrent, capped at `max-concurrent-downloads`):
   - `GET /v2/<name>/blobs/sha256:<layerDigest>` to tempfile, computing
     digest as it streams.
   - **Wait for parent** to finish registering.
   - Decompress + tee through `tar-split` + `ApplyDiff` into the
     graphdriver layer dir.
8. **Image record commit** through the reference store and image store
   (`daemon/internal/image/*` + `daemon/internal/refstore/*`).

### Important detail: "register" depends on parent, "download" does not

Look closely at `makeDownloadFunc`
([download.go#L230-L385](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/xfer/download.go#L230-L385)).
The HTTP fetch is unconditional. The block at line 320 is what serializes
the *registration* step. So layer N can be **fully downloaded to a
tempfile** while layer N-1 is still extracting; only the unpack step
waits.

---

## 7. Parallelizing a single pull

There are three orthogonal axes of parallelism. Today moby uses #1 only.

### (1) Multiple layers in parallel - already done

`max-concurrent-downloads = 3` by default. Bump it for fat pipes. The HTTP
side scales linearly with this until you saturate the registry or NIC.

### (2) Multiple chunks of one layer in parallel - **not done today**

The Docker Registry HTTP API v2 spec *does* let you do
`Range: bytes=START-END` on blob `GET`s. Most registries (Docker Hub, ECR,
GCR, ACR, Harbor, distribution/registry) implement it, because they have
to support resumable downloads. Today moby uses it only on retry, not for
parallel chunking
([pull_v2.go#L209](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/internal/distribution/pull_v2.go#L209)).

A real chunked design would look like:

```
- HEAD /v2/.../blobs/<digest>  → Content-Length L, accept-ranges: bytes
- Spawn K workers, each fetching L/K bytes with Range headers
- Workers pwrite() into a single preallocated tempfile (fallocate(L))
- Once last worker finishes: hash the file, verify, hand off to unpack
```

Tradeoffs and gotchas:

- **Hash verification still has to read the whole blob sequentially.**
  That's CPU bound on SHA256, ~500 MB/s/core in pure Go, ~2 GB/s with
  `crypto/sha256` AVX2 paths. You can parallelize this too via Merkle-ish
  schemes only if the registry supports per-chunk digests - it doesn't.
- **TLS connection setup cost ×K.** Use HTTP/2 (one TCP connection, many
  streams) to amortize.
- **Range stitching errors are silent.** Worker A returns 5 fewer bytes
  than asked; tempfile has a hole; final digest fails; everyone retries.
  Need careful per-worker retry with checksum-on-completion.
- **Registry rate limiting and CDN cache shape.** S3-backed CDNs love
  range requests; some private registries don't.
- For very small layers (< ~16 MB) chunking is pure loss; only worthwhile
  for the giant ones - exactly the layers users complain about. A simple
  policy: chunk only blobs > 64 MB into 4-8 chunks.

This would slot in as a new `DownloadDescriptor` implementation that
replaces the body of `layerDescriptor.Download`. Nothing in the registration
pipeline needs to change.

### (3) Pipelined download → decompress → untar within one layer

Already done implicitly via `io.Pipe`-style readers, but the *tar extract*
itself is single-threaded. See §5.1.

### Combined headroom estimate

On a 10 Gbit link pulling a 4 GB image of mostly-large layers:
- Today, 3-way concurrency at ~1 Gbit/s/connection ≈ 3 Gbit/s effective.
- With (2) at K=4 per layer: saturate the link.
- Without fixing (3), the unpack stage will dominate the wall clock for
  small-file-heavy layers and you'll see GBs of download finish in
  seconds, followed by minutes of "Extracting" messages. **The visible
  "slowness" users complain about is almost always the extract.**

---

## 8. Sharing image storage across machines via NFS

Short answer: **read-only sharing is feasible, read-write sharing is a
trap**.

### What you can't naively share

- The **overlay2 graphdriver layer tree** (`/var/lib/docker/overlay2/`)
  cannot live on NFS as a read-write upperdir or lowerdir of overlayfs.
  Overlayfs requires features (whiteouts via `0,0` char devices, redirect
  xattrs, opaque-dir xattrs) that NFS does not support reliably.
- The **boltdb / sqlite metadata** under `/var/lib/docker/image/.../` and
  containerd's `/var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db`
  is a single-writer file format. Two daemons opening it concurrently
  corrupts it.
- **Image store ref counting** (`refstore`) and layer cache IDs are
  per-host; cross-mounting them silently mis-counts references and
  triggers spurious deletes.

### What you *can* do

A. **Read-only content-blob mirror, per-host snapshotter:**
  - Run a shared registry/cache (e.g. `distribution` or a pull-through
    cache) on an NFS-backed object store, *or* point all daemons at the
    same `registry-mirrors` URL.
  - Each host keeps its own `/var/lib/docker/overlay2` (local SSD) but
    fetches from the shared cache. This is the standard "registry mirror
    in your DC" pattern, supported by today's moby with no patches.
  - Mirror perf wins are entirely in §1: faster network locality.

B. **Shared content store, per-host snapshotter (containerd path):**
  - containerd separates **content** (immutable, addressable by digest)
    from **snapshots** (mutable per-host overlay trees). The content
    store *could* be a shared read-only mount; snapshotters always must
    be local.
  - Today the content store assumes single-writer; you'd need either an
    NFS-backed object store driver (does not exist in containerd v2) or a
    coordinator daemon. The right primitive here is an OCI content store
    backed by S3/MinIO, not raw NFS.

C. **Pre-extracted image rootfs over NFS, no overlay:**
  - This is what some HPC clusters do: pre-extract images to NFS once,
    bind-mount the rootfs read-only into containers, lose copy-on-write
    semantics.
  - You give up layer dedupe and overlayfs semantics; you gain instant
    startup with no extract cost.
  - Doesn't fit naturally into the moby/Docker workflow but pairs well
    with `runc` directly or with `crun`'s `--rootfs` mode.

D. **Stargz / Nydus lazy-loading snapshotters:**
  - Containerd supports `stargz` and `nydus` remote snapshotters that
    expose layers as a virtual filesystem and fetch byte ranges on demand
    from a registry. Eliminates "extract" entirely. Containers start
    before the layer is fully on disk; missing pages fault in.
  - moby's containerd-backed pipeline can drive these out of the box;
    see `containerd.WithPullSnapshotter(i.snapshotter)` at
    [image_pull.go#L228](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/containerd/image_pull.go#L228).
  - For a fleet of machines on a fast in-DC network this is often the
    best answer: keep the registry close, skip the extract entirely.

### What I'd actually do for a same-DC fleet

1. Stand up a **pull-through registry mirror** in the same rack (or
   `distribution` with an S3/MinIO storage backend). Configure
   `registry-mirrors` on every daemon.
2. Switch dockerd to the **containerd image store** and enable a remote
   snapshotter (`stargz` or `nydus`). Layers stream lazily, no NFS, no
   correctness pitfalls.
3. Only reach for a shared NFS image tree if (1) and (2) are off the
   table - and then only via option C, accepting the loss of overlay
   semantics.

---

## 9. Production context: very large AI/ML images and what that changes

Sample from a real RunPod GPU host (`run-pod-65`, 2026-06):

```
$ docker system df
TYPE       TOTAL  ACTIVE  SIZE      RECLAIMABLE
Images     59     13      1.002 TB  277.5 GB (27%)
Containers 13     13      17.01 GB  0 B (0%)
```

Notable per-image sizes from `docker image list` on the same host:

| Image | Disk usage |
|---|---|
| `stephaudi/comfyui-worker-poc:all-models-v5-cuda-13.0` | 78.4 GB |
| `glamservices/comfyui-klein:f915d8d` | 90.0 GB |
| `glamservices/klein_finetune:03d091f` | 68.9 GB |
| `yatus13/rps-yvo-texg:v2.5.1` | 65.1 GB |
| `wlsdml1114-infinitetalk-...` | 55.0 GB |
| `aloukikaditya/realestate:flashvsr_v72` | 49.6 GB |
| `yourdev2023/vgf-video:serverless1.2` | 41.7 GB |
| `teknasyonlisa/lisa-upscale:0.0.2` | 38.5 GB |
| `runpod-workers-worker-comfyui-...` | 34.1 GB |
| `runpod/worker-v1-vllm:v2.11.1` | 25.3 GB |

This is a fundamentally different workload than "pull a typical webapp
image" and every recommendation in this doc needs to be re-weighted.

### Why these images are huge

These images bundle **model weights inside the image**:
PyTorch / CUDA / cuDNN base (~10 GB) plus one or more model checkpoints
(10-50 GB each). The compressed layers in the registry are usually 40-60%
of the on-disk size, so a 78 GB image is ~35-45 GB on the wire.

The relevant structural fact is:

- **Few but enormous layers.** A typical AI image has 5-15 layers
  rather than the 30+ of a typical webapp. The model-weights layer is
  often *one single 20-50 GB blob*.
- **Most disk usage is in 1-3 big files** (e.g. `*.safetensors`,
  `*.bin`). The "many small files" problem from §5.1 only applies to
  the base image layers.
- **Decompression is significant** because the blobs are huge: a 25 GB
  gzip-compressed layer is ~80-100 seconds of single-core
  `compress/gzip` work, ~25-30 seconds with `klauspost/compress`.

### What that does to the recommendations

| Recommendation | Typical webapp images | These AI images |
|---|---|---|
| Bump `max-concurrent-downloads` | Big win (30+ layers) | **Diminishing returns past ~4** (few layers, often serial chain) |
| Parallel tar extract (§2 batching) | Huge win (50k small files) | Helps base layers only; model-weight layer is a few big files |
| Faster gzip (klauspost, §5.2) | Modest win | **Big win** (saves 50-70s per huge layer) |
| io_uring extract (§5.7) | Huge win | Helps base layers only |
| Range-chunked single-blob download (§7.2) | Small win | **Huge win** - one 25 GB blob into 8×3 GB chunks across one HTTP/2 connection |
| Lazy-loading snapshotter (§8 D) | Marginal | **The single biggest possible win** |

### Your current settings

You mentioned you've already tuned:

```json
{ "max-concurrent-downloads": 9, "max-concurrent-uploads": 15 }
```

That's reasonable for a node that pulls *multiple images at once*, but
think about whether it's actually buying anything for a single-image
pull. Concretely:

- An image like `comfyui-worker-poc` has ~8 layers. Setting
  `max-concurrent-downloads=9` lets all of them fetch in parallel.
  Whether the wall clock improves depends on whether your NIC is
  saturated by 3-4 connections already.
- For a 10 GbE NIC pulling from an in-DC mirror that can serve at line
  rate, **2-3 parallel TCP connections already saturate the pipe** at
  typical congestion-control efficiency. The 4th-9th connections share
  the same pipe; you don't get more bytes/sec, you just get more CPU
  context-switching and more TLS handshake cost.
- For a 1 GbE NIC pulling from a distant CDN, more connections help
  hide per-connection latency, but you're capped at the NIC.

**Practical tuning advice:**

1. **Measure first.** `iftop -i eth0` during a cold pull. If you're
   not at ~80%+ of NIC capacity with `max-concurrent-downloads=4`,
   *the network is not the bottleneck* and adding more downloads won't
   help.
2. **Don't go above ~12.** Each in-flight download holds a tempfile, a
   decompression goroutine, and roughly `Content-Length` bytes of disk
   churn. Twelve concurrent 25 GB layer fetches = 300 GB of in-flight
   disk write before extract even starts.
3. **Watch the registry side.** Many registries throttle per-IP
   connection count. ECR is 10 concurrent per repo by default; GCR is
   higher; Docker Hub has rate limits orthogonal to connections.
4. **Watch the extract stage instead.** For these images, even with
   downloads done, you're staring at minutes of "Extracting" because
   §5.1 and §5.6 still apply layer-by-layer.

For your fleet I'd actually drop `max-concurrent-downloads` back to **6
or 8** and instead spend the engineering effort on §11 (containerd) +
lazy-load snapshotters. The marginal value of 9→15 is approximately
zero; the value of stargz / SOCI on a 78 GB image is "container starts
in seconds instead of minutes."

### Where the 1 TB on disk really lives

`docker system df` shows 1.002 TB across 59 images, of which only 27%
is reclaimable. That means **most of those layers are shared between
images** (e.g. the CUDA base layers are deduped). Lessons:

- **Image hygiene matters a lot.** Putting model weights into a Docker
  image instead of a volume means every model-version bump = a new
  multi-GB layer push/pull/store. Mounting weights from a separate
  blob store (S3, NFS, IPFS) costs you cold-start latency but saves
  TB of image churn.
- **Layer dedup works.** The fact that 1 TB of images consume only
  ~730 GB of disk-after-dedup suggests good base-layer reuse. Don't
  break this by adding `ADD` or `COPY` lines that change layer
  ordering between images.
- **Local Volumes 1.012 TB / 924.8 GB reclaimable** in your
  `system df` is a separate issue - volumes that outlived their
  containers. Worth a `docker volume prune --filter "label!=keep"` cron.

### Pre-warming as a tactic

For a known set of images deployed to a known set of nodes, the
fastest "cold start" is **no cold start**. Approaches:

1. **Bake the image into the node OS** at provisioning time (e.g.
   in your AMI / cloud-init / Packer build). For RunPod's predictable
   workloads this is realistic; pre-pull the top 10 most-used images.
   Cold-start time drops to zero.
2. **Pre-pull from a node-local daemon** at boot:
   `systemd-run --on-boot docker pull runpod/pytorch:...`.
3. **DaemonSet / privileged sidecar** that warms images on node
   provisioning. Used heavily in k8s shops.
4. **Replicate the content store** between fleet members via
   peer-to-peer (Dragonfly, Kraken). This is option B from §8 done
   right; effectively a CDN inside the DC.

---

## 10. Enabling the containerd image store: how, and tradeoffs

The containerd image store is the default in modern moby (since v25 on
Linux), but on existing hosts that pre-date that default, dockerd will
have stuck with the legacy graphdriver path to avoid abandoning prior
images. To deliberately move to containerd:

### How to enable

```jsonc
// /etc/docker/daemon.json
{
  "features": { "containerd-snapshotter": true },
  "max-concurrent-downloads": 6,
  "max-concurrent-uploads": 8
}
```

Then `systemctl restart docker`. Verify with `docker info`:

```
Storage Driver: overlayfs
 driver-type: io.containerd.snapshotter.v1
```

(Note `overlayfs` not `overlay2` - the snapshotter, not the graphdriver.)

The selection logic is in
[`daemon/image_store_choice.go#L94-L153`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/image_store_choice.go#L94-L153).

### What happens to your existing images

Three scenarios at first start after enabling:

1. **Fresh node, no prior graphdriver tree.** containerd starts clean;
   no migration. Existing pull behavior the same, snapshotter is
   overlayfs.

2. **Existing `/var/lib/docker/overlay2/` from prior daemon.** dockerd
   sees prior driver data and runs
   [`daemon/containerd/migration/migration.go MigrateTocontainerd`](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/containerd/migration/migration.go#L62)
   at start, which walks the layer store and re-registers each layer
   into containerd's content store + snapshotter. Logs `Migrated image
   <name> to <digest>` per image
   ([migration.go#L277](https://github.com/moby/moby/blob/ad6b80a888d3248fba66ce149f1f072487f7697b/daemon/containerd/migration/migration.go#L277)).
   This **doubles disk usage temporarily** (legacy + containerd copies
   both exist until you `docker image prune` and remove the legacy
   tree).

3. **Explicit `"containerd-snapshotter": false`** keeps the legacy path
   regardless.

For a 1 TB image library this means migration time and **briefly
needing ~2 TB free**. Plan accordingly.

### Rollback

Setting `"containerd-snapshotter": false` and restarting will:

- Use the legacy graphdriver path going forward.
- *Not* automatically reverse-migrate images that were pulled while in
  containerd mode. Those layers stay in `/var/lib/docker/containerd/`
  and become invisible to dockerd until you re-enable containerd or
  re-pull.

So this is **practically one-way for any images pulled after the
switch**. Rollback is possible but loses recent images.

### Tradeoffs - what you gain

| Feature | graphdriver path | containerd path |
|---|---|---|
| Multi-platform images | Pulls only the host's platform | Stores all platforms, can run any platform via emulation |
| OCI artifacts (sigs, SBOMs, attestations) | Ignored | First-class |
| zstd-compressed layers | Decoded via `klauspost/compress` shim | Native, faster path |
| Image encryption | No | Yes, via containerd plugin |
| Lazy-loading snapshotters (stargz/nydus/SOCI) | **No** | **Yes** |
| Shared content store with system containerd | No | Yes (if you point dockerd at the same containerd socket) |
| Image GC granularity | Per-image | Per-content-blob (better dedup of partial pulls) |
| Build cache integration with BuildKit | Two parallel caches | Single shared content store |
| Future-proofing | Frozen feature set | Active development |

**The killer feature for your workload is row 5: lazy-loading
snapshotters.** Switching to containerd is the prerequisite for
stargz / nydus / SOCI - which is the only design that solves
"78 GB image, 5 GB actually read at runtime" without changing how
your images are built.

### Tradeoffs - what you lose / pay attention to

| Concern | Detail |
|---|---|
| `storage-opts` change | `overlay2.size=` (per-rootfs quota), `overlay2.mountopt=` no longer apply. Containerd's overlay snapshotter has different options. |
| `docker save` / `load` format | Still works, but the on-disk content store layout is different. Tooling that walked `/var/lib/docker/overlay2/` directly will break. |
| Dangling-image listing | Containerd path shows them by digest by default; some scripts that parse `docker images` for `<none>:<none>` may need updating. |
| Driver name reported by `docker info` | Changes from `overlay2` to `overlayfs`. Monitoring dashboards filtering on the old name need updates. |
| Bind-mounting `/var/lib/docker/overlay2/<id>/diff` paths | Anything reading layer dirs directly (some debugging tools, some k8s rootfs probes) needs to be redirected to the containerd content store. |
| BuildKit cache key changes | Cache hits across the migration may be a one-time miss. |
| Subtle differences in image listing | The two image stores have slightly different semantics around "image" vs "manifest digest". Mostly invisible. |
| Restart required | Cannot toggle live, requires `dockerd` restart and may run migration on first boot. |

### Concrete enablement plan for the RunPod fleet

Given the production state you described, I'd do this in phases:

1. **One canary node.** Pick a host with relatively few images.
   Enable `"containerd-snapshotter": true`, restart, watch the
   migration logs, validate that running containers stay healthy.
2. **Verify image pulls and runs** for the top 5-10 images. Pay
   attention to:
   - Pull wall-clock time (should be similar or slightly better).
   - Disk usage during/after migration.
   - Any tooling that monitors `/var/lib/docker/overlay2/` directly.
3. **Stage a stargz / SOCI pilot** on one node alongside the
   containerd switch:
   - Install `containerd-stargz-grpc` snapshotter.
   - Pick one of your large images (e.g. `comfyui-worker-poc`).
   - Convert it to estargz format with `ctr-remote image
     optimize` or `nerdctl image convert --estargz`.
   - Push the converted image to your registry.
   - Pull on the test node and observe: container should be
     `Running` within seconds, with `Extracting` skipped entirely.
4. **Roll out** to the rest of the fleet over a maintenance window
   that allows the per-host migration time + 2× disk headroom.
5. **Decommission** the legacy graphdriver tree after a soak period
   (1-2 weeks) once you're confident nothing else reads it.

For the lazy-loading work, the **biggest blocker is not the dockerd
side - it's repacking the source images**. estargz / SOCI requires
the image to be re-pushed with a different layout. If your images are
built by users and you don't control the registry, you'll need to run
a one-shot conversion job per image (idempotent and digest-preserving
on most snapshotters).

### Pre-flight checklist

Before flipping the switch:

- [ ] Free disk: at least `du -sh /var/lib/docker` again, so 2×
      current usage. On your sample host that's ~2 TB - a real
      constraint.
- [ ] Docker version: containerd image store is supported on engine
      v25 and stable on v26+. You're on a v2 build (good).
- [ ] Containerd version: pinned to the bundled one if you use
      `dockerd`'s embedded containerd; otherwise the system
      containerd's version determines snapshotter capabilities.
- [ ] Backup `/etc/docker/daemon.json`.
- [ ] Document the rollback (set false, restart, accept loss of
      post-migration pulls).
- [ ] Drain the node's workloads to a sibling.

---

## 11. Where I'd benchmark first

Two orthogonal experiments, ranked by likely impact on the production
workload described in §9:

**#1: Lazy-loading snapshotter on one of your largest images.**

> Take `comfyui-worker-poc:all-models-v5-cuda-13.0` (78 GB). Convert
> to estargz with `nerdctl image convert --estargz`. Push to a test
> registry. On a node with `containerd-snapshotter: true` and the
> stargz proxy plugin installed, time `docker run` from cold cache.
> Expected: tens of seconds end-to-end instead of minutes.

This requires §10 (containerd switch) but **no moby/go-archive
changes**. It's the single fastest path to a "container starts in
seconds" outcome for AI workloads, and it doesn't depend on any of the
io_uring / klauspost / worker-pool work in §5.

**#2: io_uring batch extract for the syscall-bound layers.**

> Replace the per-file `open/write/close/fsetxattr` loop in
> `chrootarchive.applyLayerHandler` with an `io_uring` SQE batch of
> size 64-256 using `IOSQE_IO_LINK` chains, modeled on gosrt's
> `submitRecvRequestBatch` + `PeekBatchCQE` pattern. Self-contained
> to `vendor/github.com/moby/go-archive/chrootarchive/` (you'd fork
> or upstream to `moby/go-archive`).

This targets exactly the syscall storm in §5.6. It primarily helps
the base layers (CUDA, Python, OS) which are small-file-heavy; the
model-weight layer is bandwidth/decompression bound and benefits
less. Still a 2-4x speedup on extract for those base layers, which
stack with #1 if you can't use lazy loading for every image.

Everything else in this document is downstream of one of these two.
