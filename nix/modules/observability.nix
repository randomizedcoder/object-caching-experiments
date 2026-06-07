# ─── nix/modules/observability.nix ─────────────────────────────────────
# Prometheus exporters (focus-design §19). Every machine is scrapable.
# Phase 1: node_exporter (host-level cost) on all VMs. The nginx exporter
# (with stub_status) is added in Phase 2 once nginx exists.
{ config, lib, ... }:
let
  constants = import ../constants.nix;
in
{
  services.prometheus.exporters.node = {
    enable = true;
    port   = constants.ports.nodeExporter;   # 9100
    # Defaults cover CPU / mem / disk / net — the host-level cost.
  };
}
