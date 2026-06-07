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

---

## 19. Observability (Prometheus)

Every machine is scrapable. Exporters and endpoints:

| target                         | where                  | port / path        | what it shows                                  |
|--------------------------------|------------------------|--------------------|------------------------------------------------|
| **node_exporter**              | ALL 6 machines         | `:9100/metrics`    | CPU, mem, disk, net — the host-level cost      |
| **nginx-prometheus-exporter**  | all 4 clients + both cache VMs | `:9113/metrics` | requests, status codes (cache hit/miss via log)|
| **Zot built-in (oracle)**      | both cache VMs ×5      | `:505x/metrics`    | per-registry pulls, sync, storage — oracle diff |

Beyond the exporters, every nginx writes a **custom access-log format** carrying the cache status and per-hop latency, so hit-rate and tail-latency analysis (and the future Grafana panels, [§23](08-operations.md#23-future-work)) work straight off the logs — the same fields exposed as response headers in [§11.1](04-client.md#111-the-two-tiers) / [§13](05-cache-vms.md#13-cache-vms-nginx-primary-and-zot-oracle):

```nginx
log_format cache '$remote_addr "$request" $status '
                 'cs=$upstream_cache_status rt=$request_time '
                 'uct=$upstream_connect_time urt=$upstream_response_time '
                 'bytes=$body_bytes_sent ns=$arg_ns';
access_log /var/log/nginx/access.log cache;
```

Install method:

- **NixOS** (`client0`, `cache0`, `cache1`): `services.prometheus.exporters.node` and `services.prometheus.exporters.nginx` (with `stub_status`) on every machine — clients *and* cache VMs both run nginx now. Zot (oracle) metrics via the config `extensions.metrics` block ([§13.1](05-cache-vms.md#131-zot-verification-oracle)). All in `nix/modules/observability.nix`.
- **Ubuntu** (`ubuntu22/24/2604`): `apt install prometheus-node-exporter` via the `node_exporter` Ansible role; the nginx exporter from its role.

Cache-VM and host *liveness* (is a node actually down and in need of repair?) is covered by node_exporter and ordinary host monitoring — not by the cache fabric. The client's in-process Lua health-check ([§11.3](04-client.md#113-health-checking-passive-and-in-process-active)) only steers traffic off a dead peer; it deliberately exposes no metrics of its own.

A Prometheus server + Grafana (scraping all of the above) runs on the host or a small extra VM — wired as `nix run .#cache-observability-up`. Dashboards are future work ([§23](08-operations.md#23-future-work)); the v1 deliverable is that **all the metrics exist and are scrapable**.

---
