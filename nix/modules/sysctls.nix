# ─── nix/modules/sysctls.nix ───────────────────────────────────────────
# Kernel / network tuning shared by client + cache VMs (focus-design §18.1).
# Container/model pulls are many large, long-lived TCP flows; the defaults
# throttle throughput and stall big LFS/blob transfers.
{ config, lib, ... }:
{
  boot.kernel.sysctl = {
    # ── socket / TCP buffers (big buffers for fat, long flows) ─────────
    "net.core.rmem_max"                = 134217728;   # 128 MiB
    "net.core.wmem_max"                = 134217728;
    "net.ipv4.tcp_rmem"                = "4096 131072 134217728";
    "net.ipv4.tcp_wmem"                = "4096 16384 134217728";
    "net.ipv4.tcp_mtu_probing"         = 1;            # cope with mixed MTUs to CDNs
    "net.core.default_qdisc"           = "fq";         # pacing; pairs with BBR
    "net.ipv4.tcp_congestion_control"  = "bbr";        # throughput on lossy WAN
    "net.ipv4.tcp_slow_start_after_idle" = 0;          # keep cwnd for keep-alive conns

    # ── connection table / backlog (many concurrent pulls) ────────────
    "net.core.somaxconn"               = 65535;
    "net.core.netdev_max_backlog"      = 65535;
    "net.ipv4.tcp_max_syn_backlog"     = 65535;
    "net.ipv4.ip_local_port_range"     = "1024 65535"; # proxy makes many outbound conns
    "net.ipv4.tcp_tw_reuse"            = 1;
    "net.ipv4.tcp_fin_timeout"         = 15;

    # ── file descriptors (each cached object + conn = fds) ────────────
    "fs.file-max"                      = 2097152;
    "fs.nr_open"                       = 2097152;
  };
}
