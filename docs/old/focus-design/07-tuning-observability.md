[← Contents](README.md)

**Performance tuning and observability.** Part of the [focused design](README.md).

---

## 18. Performance tuning

Maximum-caching is only useful if the cache layer can saturate the link on a hit. This section is the per-component tuning we apply; the values are starting points to be validated with the [§21](08-operations.md#21-what-we-measure) measurements, not gospel. All of it is declarative — NixOS modules for `client0`/cache VMs, Ansible-templated for the Ubuntu clients — driven from `constants.nix` so the two paths stay in sync.

### 18.1 Kernel / network sysctls (all machines)

Container/model pulls are many large, long-lived TCP flows. The defaults throttle throughput on the LAN and stall big LFS/blob transfers. Applied via `boot.kernel.sysctl` on NixOS (`nix/modules/sysctls.nix`) and a `/etc/sysctl.d/90-cache-lab.conf` Ansible template on Ubuntu:

```ini
# ── socket / TCP buffers (big buffers for fat, long flows) ──────────────
net.core.rmem_max            = 134217728      # 128 MiB
net.core.wmem_max            = 134217728
net.ipv4.tcp_rmem            = 4096 131072 134217728
net.ipv4.tcp_wmem            = 4096 16384  134217728
net.ipv4.tcp_mtu_probing     = 1              # cope with mixed MTUs to CDNs
net.core.default_qdisc       = fq             # pacing; pairs with BBR
net.ipv4.tcp_congestion_control = bbr         # throughput on lossy WAN to upstreams
net.ipv4.tcp_slow_start_after_idle = 0        # keep cwnd for keep-alive cache conns

# ── connection table / backlog (many concurrent pulls) ──────────────────
net.core.somaxconn           = 65535
net.core.netdev_max_backlog  = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535     # proxy makes many outbound conns
net.ipv4.tcp_tw_reuse        = 1
net.ipv4.tcp_fin_timeout     = 15

# ── file descriptors (each cached object + conn = fds) ──────────────────
fs.file-max                  = 2097152
fs.nr_open                   = 2097152
```

Plus a matching `LimitNOFILE=1048576` on the nginx / health-agent / Zot systemd units (NixOS `serviceConfig`, Ubuntu drop-ins), and `nofile` raised in `/etc/security/limits.d/`. On the microvms, give the NICs `multi_queue` TAPs (already set in [§9](03-architecture.md#9-network-topology)) and enable `vhost-net` so the qemu virtio path isn't the bottleneck.

### 18.2 nginx tuning

The same knobs apply to the **client nginx** (local hot tier + router) and the **cache-VM nginx** (shared cache):

```nginx
worker_processes auto;                 # = vCPU
worker_rlimit_nofile 1048576;
events { worker_connections 65536; multi_accept on; }
http {
    sendfile on; tcp_nopush on; tcp_nodelay on;
    keepalive_timeout 75s;
    aio threads;                        # offload disk reads from workers
    output_buffers 4 256k;
    proxy_buffering on;
    proxy_buffers 16 256k;
    proxy_busy_buffers_size 512k;
    proxy_max_temp_file_size 0;        # don't spill huge bodies to temp; stream
    proxy_request_buffering off;       # stream uploads/range requests through
    proxy_cache_lock on;               # collapse concurrent misses for same key
    proxy_cache_use_stale updating error timeout;
}
# In each upstream{}: `keepalive 32;` pools conns — on the client this is
# the client→cache hop (§11.4), on the cache VM it's the conn to the CDN.
```

`proxy_cache_lock on` is the most important caching lever — without it, N parallel first-pulls of the same blob all become upstream fetches. Size each `proxy_cache_path` `keys_zone` and `max_size` per store: the **client hot tier is deliberately small** (Requirement #3) while the **cache-VM** dirs need hundreds of GB; keep them on the `/var/lib` data disk. On the client→cache hop, `proxy_cache_use_stale ... error timeout` plus `keepalive` is what makes passive failover ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)) cheap. That hop is now TLS ([§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)), but the cost is negligible on a hit: `proxy_ssl_session_reuse on;` + TLS 1.3 + the upstream `keepalive` pool mean the LAN handshake is amortised across many requests — a warm connection carries cached bytes with no per-request asymmetric crypto.

### 18.3 QUIC / HTTP3 tuning

HTTP/3 runs only on the **listeners we own** (`:443` MITM / model stores, [§14.3](06-mitm-and-content.md#143-dns-redirection--tls-termination-at-the-client-nginx)) — not on the containerd or client→cache hops ([§11.4](04-client.md#114-transport--http-versions)). To make QUIC perform:

```nginx
listen 443 quic reuseport;             # reuseport: spread UDP flows across workers
listen 443 ssl; http2 on;              # H2 fallback on the same port
http3 on;
quic_retry on;                         # cheap anti-amplification
add_header Alt-Svc 'h3=":443"; ma=86400';   # advertise H3 to clients on first H2 hit
```

```ini
# sysctl additions (§18.1) for QUIC's UDP path:
net.core.rmem_max = 134217728          # already set; QUIC leans on big UDP buffers
net.core.wmem_max = 134217728
net.core.netdev_max_backlog = 65535
```

Also enable **UDP GSO/GRO** on the NICs (`ethtool -K <if> tx-udp-segmentation on`) so QUIC's many small datagrams batch in the kernel. `reuseport` is the key nginx lever — without it a single worker serializes all QUIC connections.

### 18.4 Lua health-check tuning

The in-process checker ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)) is light — a single timer per worker — but two knobs matter under churn:

- **`interval` vs failover window.** The worst-case proactive-failover detection is ~`interval`, so the lab's `2000ms` trades probe load against detection latency; lower it for a tighter window. There is no reload, so the only cost of a short interval is probe traffic. Passive failover ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)) is independent of this and always available as the in-band backstop.
- **Flap suppression.** Hysteresis (`fall`/`rise`, [§10](03-architecture.md#10-constants-module-nixconstantsnix)) keeps a single blip from toggling a backend out and back. Because state lives in `lua_shared_dict` and there is no config rewrite, a flapping backend never triggers a reload storm — the failure mode the old daemon had to guard against.

### 18.5 Zot tuning

- **Storage**: enable dedup (`storage.dedupe = true`) so identical layers shared across repos/tags are stored once; keep `gc = true` with a generous `gcDelay`/`retention` so a warm corpus isn't GC'd mid-test.
- **Concurrency**: Zot is Go — give the VM enough vCPU and set `GOMAXPROCS` = vCPU. The sync extension's HTTP client pools connections; raise the process `LimitNOFILE` ([§18.1](#181-kernel--network-sysctls-all-machines)) so many concurrent layer fetches don't exhaust fds.
- **On-demand vs scheduled**: we run `onDemand: true` (pull-through). For a repeatable warm-cache benchmark, optionally pre-warm with a scheduled sync of the test corpus so cold-start variance doesn't pollute results.
- **Metrics overhead**: the Prometheus extension is cheap; leave it on.

### 18.6 Storage and filesystem tuning (ZFS cache pools)

nginx caches to the local filesystem, so the filesystem *is* a tuning surface. There are three
distinct OCI/HTTP workloads with opposite storage characteristics, so we back each with its own
**ZFS pool** — on the cache VMs (cache0/cache1) and on the client hot tier (client0). Splitting the
pools means each can be tuned, and grown/shrunk, independently for the workload it actually sees.

| Pool | nginx zone(s) | dataset(s) | dedup | primarycache | recordsize | compression | sync | Rationale |
|------|---------------|-----------|-------|--------------|-----------|-------------|------|-----------|
| `cache-manifests` | `cache_manifests` (cache VM), `oci_hot_manifests` (client) | `manifests` | **off** | **all** | 16K | lz4 | disabled | Manifests are tiny and latency-critical → keep the whole working set in ARC (RAM). They're small JSON, dedup would only cost a DDT. |
| `cache-blobs` | `cache_blobs` (cache VM), `oci_hot_blobs` (client) | `blobs` | **on (measured)** | **metadata** | 1M | off | disabled | Layers are large and mostly cold → don't let them evict the manifest ARC (metadata-only). 1M records suit big sequential objects; layers are already gzipped so compression is wasted. |
| `cache-http` | `cache_apt`, `cache_<model>`, `cache_extra` (cache VM); `apt_hot`, `model_hot` (client) | `apt`, `huggingface`, `modelscope`, `pytorch`, `ollama`, `extra` (cache VM); `apt`, `model` (client) | **on** | all | 128K | lz4 | disabled | apt/model/extra content is **not** content-addressed by nginx, so block-level dedup can genuinely collapse duplicates (e.g. the same `.deb` under different suites). |

**Why `sync=disabled` everywhere.** This is a *cache*: every object is re-fetchable from the origin.
Trading the ZIL for async writes gives the high-performance writes we want when a cold pull streams a
new image in from upstream, at zero durability cost we care about — a power-loss just re-warms the
cache.

**The dedup caveat (and why blobs dedup is an experiment, not a feature).** nginx already
content-addresses OCI blobs: the cache key is `blob:<digest>` ([§7.2](02-caching-design.md#72-consistent-hash-blob-dedup)),
so each unique layer is stored exactly once *before* it ever reaches ZFS. ZFS block-dedup on
`cache-blobs` should therefore find almost nothing — we expect a ratio near **1.0x**. We enable it
anyway purely to **measure** that hypothesis (`zpool get dedupratio cache-blobs`); if it really is
~1.0x we'd disable it in production to reclaim the DDT RAM. The HTTP pool is the opposite case:
apt/model payloads aren't digest-keyed, so dedup there can pay off and we keep it on.

**How the pools are created.** Each pool lives on its own dedicated raw microvm volume
(`<host>-{manifests,blobs,http}.img`), identified by a stable virtio serial
(`/dev/disk/by-id/virtio-z{manifests,blobs,http}`), with **no** microvm mountPoint so microvm.nix
leaves it untouched. Because NixOS can import but not declaratively *create* pools — and these lab
VMs are ephemeral — a oneshot (`modules/zfs-cache-pools.nix`) runs **before nginx** and does
`zpool import || zpool create -f` then `zfs create` for each dataset, applying the table above and
setting `mountpoint` to the nginx cache dir. The dataset spec is data in `constants.nix`
(`mkZfsLayout`); see the cache-VM build in [§13](05-cache-vms.md). `cache-vm-wipe` deletes the pool
images alongside the data disk, so a wipe truly resets dedup/usage state and the next boot recreates
empty pools.

**Production note.** In production the `cache-blobs` pool is where NVMe matters
(large sequential layer I/O); `cache-manifests` wants RAM over disk; `cache-http` is the elastic
middle. Because they're separate pools you can put each on the right device class and resize them on
diverging growth curves without disturbing the others.

### 18.7 ARC, L2ARC and ZIL strategy

The pool table in §18.6 fixes the *per-dataset* cache policy (`primarycache`, `recordsize`, `sync`).
This section covers the three pool-/host-level ZFS caching mechanisms — the in-RAM read cache (ARC),
the on-SSD read cache (L2ARC) and the synchronous-write log (ZIL/SLOG) — and records which we use,
which we deliberately don't, and why. **Now configured:** the one new knob (`zfs_arc_max`) is wired
through `constants.zfsTuning` / `getZfsArcMaxBytes` into the `cacheZfs` module (see "config" below).

| Mechanism | What it is | Lab decision | Rationale |
|-----------|-----------|--------------|-----------|
| **ARC** | In-RAM adaptive read cache; per-dataset shape via `primarycache` | **Use, with an explicit `zfs_arc_max` cap** | ARC *is* the cache-for-the-cache and the whole reason manifests stay hot. But cap it: dedup is on for two pools and the DDT lives in ARC, competing with the manifest working set on small-RAM VMs. |
| **L2ARC** | Second-level read cache on a *faster* device, fed from ARC eviction; per-dataset `secondarycache` | **Not used in the lab** | Every virtio disk here shares one host backing store, so an L2ARC vdev is no faster than the pool it fronts — and its in-ARC headers (~80 B/record) *steal* the very RAM we're rationing. Net negative. |
| **ZIL / SLOG** | Intent log for synchronous writes; a SLOG is a dedicated ZIL device | **Not used** | Every dataset is `sync=disabled` (§18.6), which bypasses the ZIL, so a SLOG would sit idle. |

**ARC — the per-dataset shape is already set; the missing piece is a cap.** `primarycache` from the
§18.6 table is the ARC policy: `manifests=all` (keep the tiny, hot manifest set fully in RAM),
`blobs=metadata` (cache only block pointers — large cold layers must not evict manifests),
`http=all`. What §18.6 does *not* set is the **total** ARC ceiling. ZFS defaults `zfs_arc_max` to
~50 % of RAM (~4 GiB on the 8 GiB cache VMs, ~3 GiB on the 6 GiB client). That default is risky here
because **dedup is on for `cache-blobs` and `cache-http`, and the dedup table (DDT) is counted as ARC
metadata** — under memory pressure the DDT and the manifest data cache fight over the same budget,
and an oversized ARC can also starve nginx itself. The design therefore sets an explicit cap:

- **cache VMs (8 GiB):** `zfs_arc_max ≈ 4 GiB`, leaving ~4 GiB for nginx workers, the page cache and
  DDT spill — set via `boot.kernelParams = [ "zfs.zfs_arc_max=4294967296" ]`.
- **client0 (6 GiB):** `zfs_arc_max ≈ 2 GiB` — its hot tier is smaller and it runs the MITM listener.

These are starting points to refine against `arc_summary` / `arcstat` once the pools are warm; the
point of the explicit value is *predictability*, not a final number.

**L2ARC — why we skip it (and when prod would want it).** L2ARC only helps when the cache device is
materially faster than the pool it fronts. In this virtualized lab all disks are files on the same
host store, so an L2ARC vdev would be equal-or-slower than the pool, while still consuming scarce ARC
RAM for its header entries — a strict loss. The natural prod home would be `cache-blobs` (whose data
is `primarycache=metadata`, i.e. deliberately *not* in ARC): if that pool ever lives on slow bulk
disk with a spare NVMe, set `secondarycache=all` on the blobs dataset and `zpool add cache-blobs
cache <nvme>`. But in the planned prod layout `cache-blobs` is *already* NVMe, so even there L2ARC is
unlikely to pay — revisit only if a pool lands on HDD.

**ZIL / SLOG — moot by construction, and that's correct.** `sync=disabled` routes every write
through the async path, so the ZIL is never exercised and a dedicated SLOG would be idle hardware.
This is the right call for a re-fetchable cache: ZFS remains **crash-consistent on-disk via
transaction-group (txg) commits regardless of the sync setting** — `sync=disabled` only forfeits the
last txg interval (≤5 s) of writes on power loss, never pool integrity. nginx compounds this: it
writes cache entries to a temp file and `rename()`s into place *without* an intervening `fsync`, so
even under `sync=standard` the ZIL would be nearly idle for this workload. A SLOG only becomes
worth designing if a future dataset holds **non**-rebuildable data and is switched to
`sync=standard` — not the case for any cache pool here.

**What this means for config (now wired).** The only setting this design introduces is the
`zfs_arc_max` kernel parameter above. It is sourced from `constants.nix` alongside the existing
`zfsSizesGiB`/`zfsProps`: `zfsTuning.arcMaxGiB = { cache = 4; client = 2; }` and the
`getZfsArcMaxBytes role` helper (GiB → bytes). The `cacheZfs` module
([`nix/modules/zfs-cache-pools.nix`](../../nix/modules/zfs-cache-pools.nix)) takes `arcMaxBytes` and
emits `boot.kernelParams = [ "zfs.zfs_arc_max=<bytes>" ]` (list-merged with the console params), with
the microvm generators passing `getZfsArcMaxBytes "cache"` / `"client"`. The L2ARC and SLOG levers
are present too — `zfsTuning.{l2arc,slog}.enable` feed `cacheZfs.{l2arc,slog}.enable` — but are
`false` and **assertion-guarded**: flipping one on is a build-time error pointing back here, not a
silent no-op, because each needs a real dedicated fast vdev that the lab doesn't have. No
`secondarycache` change either (`secondarycache=all` is harmless with no cache vdev present). See
[§13](05-cache-vms.md) for the cache-VM build and §18.6 for the per-dataset table this layers on top of.

### 18.8 Recommended cache sizes (grounded in the fleet image audit)

The §18.6 pool sizes (`constants.nix:zfsSizesGiB`) are deliberately *tiny* — they exist to make the
ephemeral lab VMs cheap. This section sizes the pools for the **production PoC**, grounded in a real
fleet snapshot used here as the **worked example dataset** — one operator's published snapshot
(RunPod's: `runpod/fleet-snapshots/.../analysis/images.md`, snapshot `2026-06-06`, 3769 hosts
across 37 DCs). The method is what matters; any operator runs the same audit against their own
fleet. Treat these as starting points: the whole reason the stores are separate pools
(§18.6) is that you grow each on its own observed curve.

**The one insight that makes sizing tractable.** The audit reports **2.13 PB** of fleet image
storage with **73.7 % reclaimable** — but that figure is summed *per host with duplication*: the
same base layers are counted once per host that pulled them. At the cache that duplication
collapses. Blobs are keyed `blob:<digest>` and routed by consistent hash
([§7.2](02-caching-design.md#72-consistent-hash-blob-dedup)), so each unique layer is stored
**once** regardless of how many hosts pull it. A cache therefore needs to hold only the DC's
**distinct working set**, which is one-to-two orders of magnitude smaller than the summed-host total.
The fleet has **18,444 distinct images** (mean 21.15 GB) — ≈390 TB of distinct *images* fleet-wide
before even counting shared base layers, spread across 37 DCs.

**Fleet facts that drive each store's size:**

- **A small "canonical base set" dominates pulls.** `runpod/flash` (19.8 GB), the `runpod/pytorch`
  variants (13–19 GB) and `runpod/comfyui` (8–10 GB) are each pulled on **2,000–3,640 of 3,617
  hosts** — i.e. nearly every host pulls the *same* ~30-image, **~0.6–1 TB** set. Caching just that
  set captures the dominant hit rate. **This is the blob-pool floor.**
- **Per-image size is large and long-tailed.** P50 16.3 GB, P90 44.9 GB, P99 99.9 GB, **max 426 GB**
  (model-laden ComfyUI images). The blob pool must comfortably hold many tens-of-GB objects
  (`recordsize=1M` already suits this), and a single big customer image can be 200–426 GB.
- **Per-host accumulation is big but mostly cold.** Per-host image storage P50 235 GB, P90 1.65 TB,
  max 10.75 TB — but 73.7 % is reclaimable, so a host's *active* set is a handful of images, not its
  whole disk. This sizes the **client hot tier**: hold the few images this host actually runs, not
  its accumulated history.
- **Manifests are trivial.** 21,274 distinct `repo:tag` strings; even at a generous ~100 KB each
  (index + per-arch + referrers) the entire fleet manifest corpus is **~2 GB**. A few GB makes the
  whole corpus RAM-resident (ARC, §18.7) → ~100 % manifest hit.

**Per-store sizing logic:**

| Pool | Lab now (cache/client) | Client hot tier (prod) | Small DC cache (≤60 hosts) | Medium DC (60–250) | Large DC (eu-ro-1, ~1400) | Sizing basis |
|------|------------------------|------------------------|----------------------------|--------------------|---------------------------|--------------|
| `cache-manifests` | 4 / 2 GiB | 2 GiB | 8 GiB | 8 GiB | 16 GiB | Whole corpus ~2 GB; size for RAM residency, not disk. |
| `cache-blobs` | 40 / 8 GiB | **256 GiB** (≤1 TiB for model-image hosts) | **4–8 TiB** | **8–20 TiB** | **20–50 TiB** (cluster total ÷ N nodes) | Floor = ~1 TB base set; grow to cover the DC's distinct image tail (P90 image 45 GB). |
| `cache-http` | 20 / 6 GiB | apt ~50 GiB + model 0.1–0.5 TiB | 0.5–2 TiB | 1–4 TiB | 4–10 TiB | apt = focused mirror of pulled packages (tens of GB); model stores (HF/modelscope/ollama direct pulls) are the elastic, multi-TB part. |

Notes on the table:

- **Blobs is the dominant, elastic pool** and the one to watch. Start a DC cache at the base-set
  floor (~1 TiB gives most of the win) and grow toward the working-set figures above as
  `zfs list -o name,used cache-blobs/blobs` climbs. For a multi-node cache cluster the figures are
  the **aggregate**; consistent hashing spreads distinct blobs across nodes, so per-node ≈ total ÷ N.
- **`cache-http` model stores are the wildcard.** Individual model checkpoints rival the largest OCI
  images (10s–100s of GB). If direct HF/modelscope/ollama caching is in PoC scope, expect this pool
  to grow fastest after blobs; if it's apt-only, it stays in the tens-of-GB range. Size to observed
  pulls, not a full upstream mirror.
- **Client hot tier holds *active* images, not history.** Default ~256 GiB blobs holds ~3–5 of the
  P95-sized images a host runs concurrently; bump to 0.5–1 TiB only for hosts that run the 200–426 GB
  model images. The shared DC cache behind it (warmed by every other host's pulls) absorbs the rest,
  so the hot tier can stay small.

These are PoC starting points, not capacity guarantees — re-derive them per target DC from a fresh
`image-audit` run, since the canonical base set and the heavy-model tail both shift over time.

---

## 19. Observability (Prometheus)

Every machine is scrapable. Exporters and endpoints:

| target                         | where                  | port / path        | what it shows                                  |
|--------------------------------|------------------------|--------------------|------------------------------------------------|
| **node_exporter**              | ALL 6 machines         | `:9100/metrics`    | CPU, mem, disk, net — the host-level cost      |
| **nginx-prometheus-exporter**  | all 4 clients + both cache VMs | `:9113/metrics` | requests, status codes (cache hit/miss via log)|
| **Zot built-in (oracle)**      | both cache VMs ×5      | `:505x/metrics`    | per-registry pulls, sync, storage — oracle diff |

Beyond the exporters, every nginx writes a **custom access-log format** carrying the cache status and per-hop latency, so hit-rate and tail-latency analysis (and the future Grafana panels, [§23](08-operations.md#23-future-work)) work straight off the logs — the same fields exposed as response headers in [§11.1](04-client.md#111-the-two-tiers) / [§13](05-cache-vms.md#13-cache-vms-nginx-primary-and-zot-oracle). The `log_format` is defined once (http context) in `nix/modules/observability.nix`, which is imported by both nginx roles; access logging defaults **off** there:

```nginx
log_format cache '$remote_addr "$request" $status '
                 'cs=$upstream_cache_status rt=$request_time '
                 'uct=$upstream_connect_time urt=$upstream_response_time '
                 'bytes=$body_bytes_sent ns=$arg_ns';
access_log off;
```

The log is then **split per cache store** — one file per `proxy_cache` zone — mirroring the way storage is split by request type into separate ZFS pools ([§18.6](#186-storage-and-filesystem-tuning-zfs-cache-pools)). Each cache-serving `location` turns its own log on beside its `add_header X-Cache-Status` line (`nginx-cache.nix` / `nginx-client.nix`), so hits read split the same way they store: `manifests.log`, `blobs.log`, `apt.log`, per-model `<store>.log`, `extra.log`. Health probes and the localhost `stub_status` vhost inherit the `off` default and stay quiet. To tally hits per store:

```sh
for f in /var/log/nginx/*.log; do
  echo "$f"; grep -hoE 'cs=[A-Z_]+' "$f" | sort | uniq -c
done
```

(`cs=[A-Z_]+` requires at least one letter, so the client's lua active health-check HEAD `/v2/` 404s — logged as `cs=-` in `manifests.log` — are excluded from hit counts.)

The soak driver that exercises this — `nix run .#cache-load-loop` — is documented in [§21](08-operations.md#21-measurement-plan).

Install method:

- **NixOS** (`client0`, `cache0`, `cache1`): `services.prometheus.exporters.node` and `services.prometheus.exporters.nginx` (with `stub_status`) on every machine — clients *and* cache VMs both run nginx now. Zot (oracle) metrics via the config `extensions.metrics` block ([§13.1](05-cache-vms.md#131-zot-verification-oracle)). All in `nix/modules/observability.nix`.
- **Ubuntu** (`ubuntu22/24/2604`): `apt install prometheus-node-exporter` via the `node_exporter` Ansible role; the nginx exporter from its role.

Cache-VM and host *liveness* (is a node actually down and in need of repair?) is covered by node_exporter and ordinary host monitoring — not by the cache fabric. The client's in-process Lua health-check ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)) only steers traffic off a dead peer; it deliberately exposes no metrics of its own.

A Prometheus server + Grafana (scraping all of the above) runs on the host or a small extra VM — wired as `nix run .#cache-observability-up`. Dashboards are future work ([§23](08-operations.md#23-future-work)); the v1 deliverable is that **all the metrics exist and are scrapable**.

---
