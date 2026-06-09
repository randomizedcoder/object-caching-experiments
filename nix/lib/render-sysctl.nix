# ─── nix/lib/render-sysctl.nix ─────────────────────────────────────────
# Render a sysctl attrset (the shared ../sysctl-values.nix data) to
# /etc/sysctl.d drop-in text ("key = value" per line). The NixOS VMs feed
# the same attrset straight into boot.kernel.sysctl (../modules/sysctls.nix);
# the Ubuntu clients have no boot.kernel.sysctl, so ../ubuntu-client.nix
# renders it to a drop-in through this helper — same data, one renderer.
{ lib, values }:
lib.concatStringsSep "\n"
  (lib.mapAttrsToList (k: v: "${k} = ${toString v}") values) + "\n"
