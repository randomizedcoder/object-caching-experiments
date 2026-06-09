# ─── nix/modules/sysctls.nix ───────────────────────────────────────────
# Kernel / network tuning shared by client + cache VMs (focus-design §18.1).
# Values live in ../sysctl-values.nix so the Ubuntu clients (system-manager,
# no boot.kernel.sysctl) can render the same set to /etc/sysctl.d.
{ config, lib, ... }:
{
  boot.kernel.sysctl = import ../sysctl-values.nix;
}
