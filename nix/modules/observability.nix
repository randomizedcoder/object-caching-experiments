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
