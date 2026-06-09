# 07 — Tuning & observability

Container and model pulls are many large, long-lived TCP flows feeding a disk cache. Two things
have to keep up: the network stack (so fat WAN transfers don't stall) and the cache filesystem (so
hot manifests stay in RAM while large blobs stream from disk). Both are tuned from shared data
files so the NixOS and Ubuntu clients stay identical.

## 7.1 Kernel / network tuning

Values live in [`nix/sysctl-values.nix`](../nix/sysctl-values.nix), applied on NixOS via
[`sysctls.nix`](../nix/modules/sysctls.nix) (`boot.kernel.sysctl`) and rendered to
`/etc/sysctl.d/` on Ubuntu (system-manager has no `boot.kernel.sysctl`). Highlights and why:

- **Big socket buffers** — `rmem_max`/`wmem_max` 128 MiB and matching `tcp_rmem`/`tcp_wmem`, so a
  single fat blob/LFS transfer can fill a high-bandwidth-delay WAN path.
- **BBR + fq** — `tcp_congestion_control=bbr` with `default_qdisc=fq` for throughput on a lossy
  WAN with paced sends; `tcp_mtu_probing=1` copes with mixed MTUs to CDNs;
  `tcp_slow_start_after_idle=0` keeps the congestion window across keep-alive idle.
- **Large connection tables** — `somaxconn`, `netdev_max_backlog`, `tcp_max_syn_backlog` at 65535
  and a wide `ip_local_port_range`, because the proxy opens many concurrent outbound connections.
- **File descriptors** — `fs.file-max` / `fs.nr_open` at ~2M: each cached object and connection
  costs fds.

nginx itself uses roomier proxy header buffers (16k/8×16k/32k busy) on both roles, because
big-header origins like `github.com` overflow the default 4k/8k and 502.

## 7.2 Cache filesystem tuning

The three ZFS pools each carry per-workload tuning so the cache filesystem matches the access
pattern: tiny latency-critical manifests kept entirely in ARC, large immutable blobs streamed from
disk with metadata-only ARC, and a mixed http pool with block dedup. The full table and rationale
are in [04](04-cache-vms.md) §4.4; the values are in
[`nix/constants/resources.nix`](../nix/constants/resources.nix).

## 7.3 Observability

Every node is scrapable ([`observability.nix`](../nix/modules/observability.nix)):

- **`node_exporter` (:9100)** — host-level CPU / memory / disk / network, on all machines.
- **`nginx-exporter` (:9113)** — request/status counters, scraped from a **localhost-only**
  `stub_status` endpoint on `:8099`. Both nginx roles run it.
- **Zot metrics** — each oracle exposes Prometheus metrics on its own `:505x/metrics` (exposed by
  [`zot-oracle.nix`](../nix/modules/zot-oracle.nix), not the observability module).

### The unified access-log format

A single `log_format cache` is defined once (in `commonHttpConfig`, so it is emitted before the
server blocks that reference it) and used by every per-store `access_log … cache;` line:

```
$remote_addr "$request" $status cs=$upstream_cache_status rt=$request_time
uct=$upstream_connect_time urt=$upstream_response_time bytes=$body_bytes_sent ns=$arg_ns
```

`access_log` defaults **off**, so only the cache locations log — health probes and the
`stub_status` vhost stay quiet. Because each `proxy_cache` zone writes its own log
(`blobs.log`, `manifests.log`, `apt.log`, `<store>.log`), hit/miss is readable split-by-store, the
same way storage is split into per-workload ZFS pools. Responses also carry `X-Cache-*` headers
(`X-Cache-Hot`/`X-Cache-Status` for HIT/MISS, `X-Cache-Time`/`X-Cache-Upstream-Time` for latency)
so a single `curl -I` shows which tier served a request.
