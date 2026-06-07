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
