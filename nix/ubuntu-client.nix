# ─── nix/ubuntu-client.nix ─────────────────────────────────────────────
# system-manager config for the Ubuntu clients (Phase 4, focus-design §16).
# Applied IN-GUEST on a stock Ubuntu after Nix is installed:
#   system-manager switch --flake <repo>#ubuntu-client
#
# system-manager reuses a useful SUBSET of upstream NixOS modules — notably
# the full services.nginx, services.openssh, users/userborn, nix.settings —
# but does NOT carry virtualisation.* (docker/containerd), the prometheus
# exporter modules, security.pki, or boot.kernel.sysctl (`boot` is a raw
# stub it ignores). So on Ubuntu those land as plain systemd.services +
# environment.etc, while constants.nix stays the single source of truth
# across NixOS and Ubuntu.
#
# Phase 4b-1 (this stage): sysctl tuning + node_exporter. The serving path
# (nginx) and container plumbing (docker/containerd/ca-injector) arrive in
# 4b-2 / 4b-3.
{ pkgs, lib, ... }:
let
  c = import ./constants.nix;

  # Same tuning the NixOS VMs get via boot.kernel.sysctl (modules/sysctls.nix),
  # rendered to a drop-in since system-manager ignores boot.kernel.sysctl.
  sysctlValues = import ./sysctl-values.nix;
  sysctlConf = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "${k} = ${toString v}") sysctlValues) + "\n";
in
{
  nixpkgs.hostPlatform = "x86_64-linux";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Stub marker so we can confirm a switch actually took effect in-guest.
  environment.etc."cache-ubuntu-client-stub".text =
    "ubuntu-client system-manager stub (Phase 4b-1)\nuserAgent=${c.userAgent}\n";

  environment.systemPackages = with pkgs; [ htop curl jq ];

  # ── sysctl tuning (§18.1) ─────────────────────────────────────────────
  # Drop-in read by systemd-sysctl at boot; the oneshot below re-applies it
  # on every `system-manager switch` (no reboot needed). bbr/fq need the
  # tcp_bbr module, which setting the sysctl autoloads on Ubuntu generic.
  environment.etc."sysctl.d/60-cache-lab.conf".text = sysctlConf;

  systemd.services.cache-sysctl = {
    description = "Apply cache-lab sysctl tuning";
    wantedBy   = [ "multi-user.target" ];
    after      = [ "systemd-sysctl.service" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart       = "${pkgs.procps}/bin/sysctl --system";
    };
  };

  # ── node_exporter (:9100, §19) ────────────────────────────────────────
  # services.prometheus.exporters.* isn't in system-manager, so run the
  # store binary directly under a DynamicUser systemd unit.
  systemd.services.node-exporter = {
    description = "Prometheus node exporter";
    wantedBy   = [ "multi-user.target" ];
    after      = [ "network.target" ];
    serviceConfig = {
      ExecStart   = "${pkgs.prometheus-node-exporter}/bin/node_exporter "
                  + "--web.listen-address=:${toString c.ports.nodeExporter}";
      DynamicUser = true;
      Restart     = "on-failure";
      RestartSec  = 2;
    };
  };
}
