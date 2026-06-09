# ─── nix/modules/observability.nix ─────────────────────────────────────
# Prometheus exporters (focus-design §19). Every machine is scrapable.
#   - node_exporter   (:9100) — host-level cost, all machines.
#   - nginx exporter  (:9113) — request/status counters, scraped from a
#     localhost-only stub_status endpoint. Both VM roles run nginx (cache
#     vhosts and client vhosts), so this is shared scaffolding here.
# Zot's own :505x/metrics is exposed by zot-oracle.nix, not here.
{ config, lib, ... }:
let
  constants = import ../constants.nix;
  statusPort = constants.ports.nginxStatus;
in
{
  # §19 cache access-log format, defined once here (log_format is http-context
  # and this module is imported by BOTH nginx roles — microvm-cache.nix and
  # microvm-client.nix). The per-store `access_log <store>.log cache;` lines
  # that USE this format live next to each proxy_cache zone in nginx-cache.nix /
  # nginx-client.nix, so hits are read split-by-store the same way storage is
  # split into per-workload ZFS pools (§18.6). Default OFF here → only the cache
  # locations log; health probes and the localhost stub_status vhost stay quiet.
  #
  # MUST be commonHttpConfig, not appendHttpConfig: NixOS emits commonHttpConfig
  # *before* the server blocks but appendHttpConfig *after* them, and nginx
  # rejects a `log_format` referenced (by the per-store access_log lines in the
  # vhosts) before it is defined — "unknown log format cache" → emerg on start.
  services.nginx.commonHttpConfig = ''
    log_format cache '$remote_addr "$request" $status '
                     'cs=$upstream_cache_status rt=$request_time '
                     'uct=$upstream_connect_time urt=$upstream_response_time '
                     'bytes=$body_bytes_sent ns=$arg_ns';
    access_log off;
  '';

  services.prometheus.exporters.node = {
    enable = true;
    port   = constants.ports.nodeExporter;   # 9100
    # Defaults cover CPU / mem / disk / net — the host-level cost.
  };

  # stub_status served on loopback only; the exporter scrapes it and
  # re-exposes Prometheus metrics on :9113.
  services.nginx.virtualHosts."nginx-status" = {
    listen    = [{ addr = "127.0.0.1"; port = statusPort; }];
    locations."/nginx_status".extraConfig = ''
      stub_status;
      access_log off;
    '';
  };

  services.prometheus.exporters.nginx = {
    enable    = true;
    port      = constants.ports.nginxExporter;   # 9113
    scrapeUri = "http://127.0.0.1:${toString statusPort}/nginx_status";
  };
}
