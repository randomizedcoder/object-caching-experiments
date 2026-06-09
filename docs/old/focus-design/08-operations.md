[← Contents](README.md)

**Build, measurement, alternatives, and future work.** Part of the [focused design](README.md).

---

## 20. Build and run workflow

```bash
# one-time host prep
nix run .#cache-check-host             # verify tun, vhost-net, bridge, sudo
sudo nix run .#cache-network-setup     # cachebr0 + 3 TAPs + NAT
nix run .#cache-gen-secrets            # ssh host + user keys
nix run .#cache-gen-ca                 # per-client MITM CA + per-FQDN certs (§14), AND the
                                       #   cache CA + one shared cache server cert (§11.5)
nix run .#cache-distribute-trust       # SSH: push cache CA → every client's /etc/nginx/cache-ca.crt,
                                       #   push shared server cert+key → both cache VMs (§11.5)

# bring everything up
nix run .#cache-start-all              # build + boot client0, cache0, cache1 (also runs distribute-trust)
nix run .#ubuntu-start-all             # vagrant up ubuntu 2204/2404/2604 + ansible apply

# pick the health-check mode under test (passive backstop only, or + active lua)
nix run .#cache-set-hc -- --client=client0 --mode=passive   # or --mode=active

# exercise containers (unmodified Dockerfiles)
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull alpine"
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull gcr.io/distroless/static-debian12"
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull registry.k8s.io/pause:3.10"
nix run .#cache-vm-ssh -- --node=client0 -- "docker pull mcr.microsoft.com/dotnet/runtime:9.0"  # → nginx wildcard
nix run .#ubuntu-vm-ssh -- --version=2404 -- "docker pull alpine"

# exercise apt (HTTP repos → nginx apt cache) + docker-ce HTTPS repo (→ MITM)
nix run .#ubuntu-vm-ssh -- --version=2404 -- "sudo apt update && sudo apt install -y jq"

# exercise LLM model stores (HTTPS → MITM → nginx model vhosts)
nix run .#cache-vm-ssh -- --node=client0 -- \
    "docker run --rm python:3.12 bash -c 'pip install -q huggingface_hub && huggingface-cli download TinyLlama/TinyLlama-1.1B-Chat-v1.0'"
nix run .#ubuntu-vm-ssh -- --version=2404 -- "ollama pull llama3.2:1b"
nix run .#ubuntu-vm-ssh -- --version=2404 -- \
    "python3 -c 'import torch; torch.hub.load(\"pytorch/vision\", \"resnet18\", weights=\"DEFAULT\")'"

# observe
nix run .#cache-vm-ssh -- --node=client0 -- "curl -s localhost:9113/metrics | grep nginx_"
nix run .#cache-vm-ssh -- --node=client0 -- "curl -sI localhost:8088/v2/library/alpine/manifests/latest?ns=docker.io | grep -i x-cache"
nix run .#cache-vm-ssh -- --node=cache0  -- "curl -s localhost:8100/health"  # HF model vhost

# induced-failure drill: kill a cache, watch the failover window
nix run .#cache-vm-stop -- --node=cache0
# ... re-run the pull corpus; in passive mode the FIRST post-failure pull
#     eats a connect timeout then succeeds on cache1; in active mode the
#     lua checker has already marked cache0 down in shared memory, so the
#     pull never selects it. Read the window off X-Cache-Time / the access log ...
nix run .#cache-start -- --node=cache0   # bring it back; observe re-add

# differential test: nginx serving path vs Zot oracle (§7.4)
nix run .#cache-diff-test               # pull corpus via nginx AND zot, assert
                                        # manifest/blob digests + status/headers match

# tear down
nix run .#cache-vm-stop && nix run .#ubuntu-vm-stop-all
sudo nix run .#cache-network-teardown
```

Helpers: `cache-vm-wipe` (delete `*-data.img` for a cold run), `cache-render` (render all configs into `rendered/` for `git diff`), `cache-pull-corpus` (fixed pull list for repeatable warm/cold runs), `cache-model-corpus` (fixed model-download list across all four stores), `cache-set-hc` (toggle the active lua health-check on/off — passive backstop stays either way), `cache-diff-test` (nginx-vs-Zot equivalence assertion), `cache-gen-ca` (mint a per-client MITM CA + per-FQDN certs, plus the lab-wide cache CA + one shared cache server cert, §11.5), `cache-distribute-trust` (SSH the cache CA to every client and the shared server cert+key to both cache VMs), `ubuntu-render` (export `constants.nix` as JSON for Ansible).

---

## 21. What we measure

The lab exists to validate the nginx-only fabric against the requirements in [§5](01-overview.md#5-requirements), with metrics from [§19](07-tuning-observability.md#19-observability-prometheus):

1. **Local hot-tier value (Requirement #3).** Re-pull the same corpus on one client. Expect the client nginx's hot tier to serve the warm pull with **zero cache-VM traffic** (`nginx_*` on the client shows the local hit; the cache-VM nginx counters stay flat). Quantifies what the small local tier buys, and confirms `proxy_cache_min_uses` keeps big cold blobs from churning it.
2. **Shared-cache utilization + cross-client (Requirement #2).** Pull on `client0`, then pull the same image on `ubuntu2404`. The **shared nginx layer** serves the second client (cache-VM `nginx` hit) even though its *local* tier is cold — proving the consistent hash makes one large shared cache. Confirm each blob digest is stored **once** fleet-wide (digest-keyed dedup, [§7.2](02-caching-design.md#72-what-nginx-only-must-replicate-by-hand) / [§11.2](04-client.md#112-consistent-hash-router-and-cache-keys)).
3. **Consistent-hash correctness + blast radius (Requirement #2).** Confirm a given digest always lands on the same cache VM, and measure remap on failure: with `n=2`, killing one cache should remap ~50% of keys (the survivor misses-then-fills); note this is the worst case vs the `n≥3` recommendation.
4. **Passive vs active (lua) failover window (Requirement #1).** The headline comparison. Run the induced-failure drill ([§20](#20-build-and-run-workflow)) in **both** modes and measure the **outage window** — time/requests from cache death to recovered pulls, read off the pull latency (`X-Cache-Time` header / access-log `$request_time`, [§19](07-tuning-observability.md#19-observability-prometheus)):
   - *Passive only:* the first post-failure request eats a connect timeout (~`fail_timeout`-bounded) before `proxy_next_upstream` retries the survivor; subsequent requests skip the dead node.
   - *Active (lua):* the in-process checker marks the dead peer down within ~`interval`, so a client pull arriving after that never selects it — no reload, no daemon. Also confirm containerd's `server=` fallthrough covers a *total* cache outage in both modes.
5. **nginx-vs-Zot equivalence ([§7.4](02-caching-design.md#74-the-committed-design-nginx-cache-zot-as-verification-oracle)).** Run `cache-diff-test`: pull the corpus through the nginx serving path and through the Zot oracle and assert manifest bytes/digests, the blob digest set, and status/headers match. This is the ongoing correctness gate on the hand-written rules.
6. **apt hit rate.** `apt install` the same package on two Ubuntu clients; the second should be a shared-nginx cache hit (`X-Cache-Status: HIT`).
7. **Model-store hit rate + MITM correctness.** Download the same HF / Ollama / ModelScope / PyTorch model twice; confirm the second is an nginx hit (`X-Cache-Status: HIT`) and that the client tools accept **that client's own** minted certs without TLS errors (proves [§14](06-mitm-and-content.md#14-https-interception-internal-ca--mitm) per-client trust insertion, including inside containers via the runc hook).
8. **H3 vs H2 on owned listeners.** On the `:443` model-store listeners, compare HTTP/3 vs HTTP/2 transfer time for the multi-GB model files (toggle `Alt-Svc` / force the client) — the one place we control both ends and can actually run QUIC ([§11.4](04-client.md#114-transport--http-versions), [§18.3](07-tuning-observability.md#183-quic--http3-tuning)).

### 21.1 Soak / hit-rate driver (`cache-load-loop`)

To watch the hit ratio climb across the tiers over time, `nix run .#cache-load-loop` drives a client over SSH on a cadence: per cycle it **pulls** a small corpus, **runs** each image detached for the dwell window, **tears down** (`docker rm -f` + `docker rmi` — the `rmi` is what forces the next cycle's re-pull, since docker keeps layers locally otherwise), **pauses**, then repeats, printing a per-store cumulative `cs=HIT`/`cs=MISS` tally from the [§19](07-tuning-observability.md#19-observability-prometheus) split access logs after each cycle.

```sh
nix run .#cache-load-loop -- \
  --node=client0 --run-secs=300 --pause-secs=30 --cycles=0 \
  --images="registry.k8s.io/pause:3.9 alpine:latest" \
  --report-nodes=client0,cache0,cache1
```

Flags: `--node` (driving client, default `client0`), `--run-secs` (dwell, 300), `--pause-secs` (idle gap, 30), `--cycles` (`0` = loop until Ctrl-C, with a clean teardown trap), `--images` (space-separated corpus, default a small public set spanning all five upstreams), `--report-nodes` (nginx layers to summarize). **Expected story:** cycle 1 misses at `client0` *and* the cache VMs (cold fill); cycles 2+ **HIT** at `client0`'s local hot tier (the `rmi` clears docker's content store, not nginx's cache), with little new cache-VM traffic. To exercise *shared-cache* (cache-VM) hits instead, point a second cold client at the same corpus (measurement #2 above) — its local tier misses but the shared tier HITs. This automates the warm/cold drills in [§20](#20-build-and-run-workflow).

---

## 22. Alternatives considered: client-side proxy

The earlier draft of this design ran HAProxy *or* Varnish on the clients. We collapsed to nginx-only ([§5](01-overview.md#5-requirements), Requirement #4) once we confirmed nginx already does consistent hashing and local caching — the only thing stock nginx OSS lacks is *active* health checks, which on OpenResty [§11.3](04-client.md#113-health-checking-passive-and-in-process-active) supplies in-process. For the record, why each alternative lost:

| Option | What it offered | Why it lost here |
|--------|-----------------|------------------|
| **HAProxy** | Pure L7 LB: consistent hash (`balance uri`) + **active** health checks. | A *second* technology on the clients for the *only* thing nginx lacks (active HC). No local cache, so we'd still need nginx anyway. Active HC is now supplied in-process by lua ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)). |
| **Varnish** | Consistent hash (`directors.shard()`) + active probes **plus** a local cache tier. | A second *caching* technology (its own VCL, tuning, exporter) duplicating nginx's `proxy_cache`. The whole point of [§5](01-overview.md#5-requirements) #4 is one cache tech; nginx's local hot tier ([§11.1](04-client.md#111-the-two-tiers)) covers the same need. |
| **Standalone Go health-check daemon** | Active HC *we first designed*: a small Go agent HEAD-probing each cache, then symlink-swapping a pre-generated upstream include and running `nginx -s reload`, with Prometheus metrics on `:9114`. | A separate process/technology to build, package (NixOS module + Ansible role) and operate. Each flip is an `nginx -s reload` (worker churn, flap-storm risk), and pre-generating subsets is `2^n` files at scale. **OpenResty's in-process [`lua-resty-upstream-healthcheck`](https://github.com/openresty/lua-resty-upstream-healthcheck) does the same active checking with no daemon, no reload, and native `n≥3`** — so the daemon was dropped in favour of it ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)). |
| **Envoy** | `ring_hash`/`maglev` consistent hashing, active HC, native **HTTP/3**. | Powerful but heavy for a 2-backend lab — control-plane/xDS surface and operational weight we don't need. Already rejected in `design.md` §10 for the same reason. |
| **IPVS + keepalived** | Kernel L4 load balancing with health checks (keepalived), Maglev (`mh`) scheduler. | **L4 only** — it can't read the containerd `ns=` param or the OCI digest, so it can't hash on the keys this design needs ([§11.2](04-client.md#112-consistent-hash-router-and-cache-keys)). Needs keepalived bolted on for HC. Wrong layer. |

In every case the deciding factor is the same: nginx is **already** the cache (client hot tier *and* shared layer), so adding any of these is a *second* component justified solely by active health-checking — which OpenResty's in-process lua checker ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)) delivers without a new technology or a reload. See `design.md` §10 for the fuller exploration these are distilled from.

---

## 23. Future work

- Grafana dashboards over the Prometheus data (cache hit rate, upstream bytes saved, p50/p99 pull/download latency, passive-vs-active failover window).
- **Node-to-node HTTP/3** (client nginx → cache nginx): blocked today because nginx cannot originate H3 upstream ([§11.4](04-client.md#114-transport--http-versions)); would need an H3-capable originator or a different cache-hop proxy.
- Promote Ollama from the nginx path to a Zot instance if its OCI dialect proves compatible ([§15.3](06-mitm-and-content.md#153-ollama)).
- Replace `/etc/hosts` MITM redirection with a proper `dnsmasq` so we can also enforce an egress allowlist and make the lab safe on a restricted network.
- A two-cache **parent-child** hierarchy so a miss on one cache VM consults its sibling before going upstream. This is **drop-in precisely because the cache VMs already run OpenResty** ([§13](05-cache-vms.md#13-cache-vms-nginx-primary-and-zot-oracle)): the cache tier gains an upstream pool and reuses the *same* in-process Lua health-check + consistent-hash failover the clients use ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)) — no new component.
- **Scale-out test at `n≥3`** to confirm the reduced failure blast radius ([§5](01-overview.md#5-requirements) #2); the in-process lua checker tracks each peer independently, so `n≥3` needs no extra config ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)).
- Add more model stores (Civitai, GitHub LFS) by adding entries to `constants.modelStores` — the nginx vhosts generate automatically.

---

## 24. Local container-image lifecycle on cache clients

[§3.1](01-overview.md#31-background-container-images-live-on-the-host-and-they-pile-up) established the problem: containerd stores every pulled image locally and **never** evicts it (no LRU, no size cap — only reference-based GC), so hosts grow until the disk fills. This section answers the natural follow-up: **once the multi-tier cache exists, what happens to those local images?**

**The key clarification: a pull-through cache does *not* eliminate local images.** The cache sits between containerd and the upstream registry — it makes the *fetch* a deduplicated LAN hit instead of a WAN pull, but containerd on the client still downloads the image, unpacks it into a snapshot, and roots it permanently exactly as before ([§3.1](01-overview.md#31-background-container-images-live-on-the-host-and-they-pile-up)). So "containerd always pulls from nginx, therefore no local images" is **not** what a standard cache gives you. Bounding the local store is a *separate* decision, and the cache changes the cost/benefit of every option below — because it makes re-fetching a discarded image cheap. The options, in increasing ambition:

1. **Do nothing — cache-accelerated re-pull (baseline).** Accept local growth; keep relying on host disk and whatever occasional manual `prune` happens today. The cache still earns its keep: after a prune, a disk wipe, an autoscale event, or a fresh host, the re-pull of the canonical base set ([§18.8](07-tuning-observability.md#188-recommended-cache-sizes-grounded-in-the-fleet-image-audit)) is a LAN hit, not a WAN pull. Simplest, but does **not** bound local disk.

2. **Scheduled / threshold pruning (recommended PoC baseline).** A systemd timer running `docker image prune` (or a small agent replicating kubelet's `High`/`LowThresholdPercent` LRU) bounds the local store. The synergy with the cache is the point: LRU-pruning is normally a tradeoff (evicted images cost a full re-pull) but **with the cache backing every re-pull, aggressive pruning becomes cheap and safe**. This gives bounded local disk *today*, with no containerd/runtime changes.

3. **Discard unpacked layers in containerd.** containerd can drop the compressed layer blobs from the content store after they're unpacked into the runnable snapshot (`discard_unpacked_layers` — `internal/cri/config/config.go`; `client.WithDiscardUnpackedLayers()`), keeping only the rootfs. Roughly halves footprint. The usual hesitation is that re-pushing/re-pulling then needs to refetch the blob — but, again, **the cache makes that refetch a cheap LAN hit**, so the cache makes this option materially safer than it is on a bare host. A config flag, not a new component.

4. **Lazy-pulling via a remote snapshotter (the closest thing to "no local image").** Stargz/eStargz ([containerd stargz-snapshotter](https://github.com/containerd/stargz-snapshotter)), SOCI, or Nydus let a container **start before the image is downloaded**, fetching only the chunks actually read, on demand, from the registry — i.e. from *our cache* (`docs/snapshotters/remote-snapshotter.md`: "prepare these remote snapshots without pulling layers from registries"). Local footprint collapses to the working set actually touched rather than the whole image, and the cache is the ideal lazy-fetch backend: LAN-local, already deduplicated by digest. This is the genuine answer to "can containerd avoid storing whole images locally?" — **yes, but only with a remote snapshotter**, not with the cache alone. Cost: images must be in a lazy format (stargz conversion) or carry a SOCI index, plus the snapshotter plugin; coverage isn't universal. Aspirational — strongest once the cache itself is proven.

**Recommendation.** For the production PoC, combine **(1)+(2)**: the cache for cheap fetches plus a prune policy for bounded local disk — this needs no runtime changes and the two reinforce each other. Evaluate **(3)** as an easy follow-on (one containerd flag, de-risked by the cache) and **(4)** as the higher-ceiling direction once the cache is trusted, since both lean on the cache to be safe and effective.

### 24.1 Background: the SOCI snapshotter (lazy image loading)

Option (4) above is the only one that genuinely shrinks the *local* image footprint to the working set actually read, so it's worth understanding in detail. The leading implementation is the **SOCI snapshotter** (Seekable OCI, pronounced "so-CHEE") from AWS Labs. This section is background only — the design for integrating it with *our* cache follows separately.

References:
- AWS deep-dive: <https://aws.amazon.com/blogs/containers/under-the-hood-lazy-loading-container-images-with-seekable-oci-and-aws-fargate/>
- Source / docs: <https://github.com/awslabs/soci-snapshotter> (the file/line citations below are from this repo)

**The core idea (and the user's intuition is right).** SOCI does **not** convert or repackage the image — it leaves the OCI/Docker image byte-for-byte **unmodified** and instead adds *a second artifact alongside it*: the **SOCI index**. That index is what lets containerd mount a layer and start the container *before* the layer is downloaded, fetching file contents on demand. So yes — it is "another index that makes image loading faster," and the precise mechanism is below. (The glossary deliberately avoids the term "SOCI image": there is no such thing — the image is unmodified, the index is a separate object — `docs/glossary.md`.)

**What's in the index — the two-level data model** (`docs/index.md`):
- **SOCI index manifest** — an OCI image manifest with a `subject` reference back to the image digest (so it's discoverable via the OCI **Referrers API**, `/v2/<name>/referrers/<digest>`), an empty config of mediaType `application/vnd.amazon.soci.index.v1+json`, and a `layers` array of **zTOC** descriptors (one per indexed image layer). Because it's a normal OCI artifact it lives in the **same registry** as the image, stored and distributed like any manifest.
- **zTOC** ("z-table-of-contents", one per layer) — has two parts:
  - **TOC**: per-file metadata + each file's **offset in the *uncompressed* tar** of the layer.
  - **zInfo**: a set of compression **checkpoints**, each marking a **span** — a chunk of the gzip stream that can be decompressed independently (default **span size 4 MiB**, `soci/soci_index.go:81`).

  Together these are what make a gzipped layer *seekable*: to read one file, SOCI maps file→tar-offset (TOC), finds which span(s) cover that offset (zInfo), fetches just those spans, and decompresses only them — instead of streaming and inflating the whole layer.

**How a lazy pull works at runtime** (`docs/pull-modes.md`):
1. The puller either passes `--soci-index-digest` or the snapshotter **discovers** the index through the Referrers API (with the tag-scheme fallback when a registry lacks Referrers).
2. On first layer mount it fetches the SOCI manifest + zTOCs. If that fails, it **falls back to the default snapshotter** (overlayfs) and pulls normally — lazy loading is best-effort, never a hard dependency.
3. Each **indexed** layer is mounted as a **FUSE** filesystem and loaded lazily; **un-indexed** layers are downloaded synchronously as normal overlay layers. Indices can be **"sparse"**: by default only layers above `--min-layer-size` get a zTOC (`cmd/soci/commands/create.go`), so tiny layers just download normally and only the big ones are lazily loaded.

**The integration-critical detail: on-demand reads are HTTP `Range` GETs.** When the FUSE layer needs a span, the snapshotter issues a byte-range request against the layer's blob URL —
`req.Header.Set("Range", "bytes=<lo>-<hi>")` (`fs/remote/resolver.go:307`) — with a **single-range fallback** for registries/CDNs that don't honour multi-range (`fs/remote/resolver.go:362,417`). This is the hook into our design: a SOCI client in front of our cache would pull (a) the **SOCI index artifacts** (manifest + zTOCs, via Referrers) and (b) **ranged slices of layer blobs** — both of which the nginx cache and the Zot oracle would need to serve and cache correctly. That's the substance of the integration design to follow.

**Deployment shape.** SOCI runs as a separate daemon, `soci-snapshotter-grpc`, wired into containerd as a **proxy (remote) snapshotter** over a socket, started `Before=containerd.service` (`soci-snapshotter.service`). On the client side it's an extra service + a containerd config stanza, not a containerd patch.

**Two operating modes + prefetch.** Beyond classic lazy loading, recent SOCI adds a **parallel-pull-unpack** mode (`docs/parallel-mode.md`): an *upfront* load like the default snapshotter, but with concurrent HTTP range-GET downloads and parallel unpacking — aimed at I/O-bound workloads that want the whole rootfs fast, and notably it also exposes `discard_unpacked_layers` (ties back to option (3)). There's also an experimental **prefetch** feature (`docs/prefetch.md`) to warm a targeted set of files/spans at startup. For our purpose the classic lazy mode is the one that minimises local storage.

**Why this is attractive here.** Combined with the cache, lazy loading means a client fetches only the spans a container actually reads, from a LAN-local, digest-deduplicated cache — collapsing both the *startup wait* and the *local footprint* (§3.1) toward the real working set rather than the full image. The catch is that it requires **SOCI indices to exist** for the images (someone must run `soci create`/push, or the cache layer must produce/serve them) and the **registry path to support Referrers + ranged blob reads** — which is exactly what the integration design needs to work out next.
