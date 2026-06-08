# ─── nix/ubuntu-client.nix ─────────────────────────────────────────────
# system-manager config for the Ubuntu clients (Phase 4, focus-design §16).
# Applied IN-GUEST on a stock Ubuntu after Nix is installed:
#   system-manager switch --flake <repo>#ubuntu-client
#
# system-manager only reliably supports a SUBSET of NixOS options
# (environment.systemPackages / environment.etc, systemd.services /
# systemd.tmpfiles, nix.settings). It does NOT give us the high-level
# `services.nginx` / `virtualisation.docker` NixOS modules — so on Ubuntu
# nginx is a plain systemd.services.nginx pointing at a nix-rendered
# OpenResty config, docker installs via apt, and the CA/hosts/sysctls
# bits land as environment.etc. The real config arrives in Phase 4b; this
# is the minimal "prove the mechanism" stub.
{ pkgs, lib, ... }:
let
  c = import ./constants.nix;
in
{
  nixpkgs.hostPlatform = "x86_64-linux";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Stub marker so we can confirm a switch actually took effect in-guest.
  environment.etc."cache-ubuntu-client-stub".text =
    "ubuntu-client system-manager stub (Phase 4a)\nuserAgent=${c.userAgent}\n";

  environment.systemPackages = with pkgs; [ htop curl jq ];
}
