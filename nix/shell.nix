# ─── nix/shell.nix ─────────────────────────────────────────────────────
# devShells.default — tools for poking the lab by hand (nix-design §11).
{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [
    openresty       # nginx + lua (matches the VMs' nginx package)
    curl
    jq
    regctl          # OCI registry client
    crane           # OCI image tool
    step-cli        # CA / leaf cert minting
    nftables
    qemu
  ];

  shellHook = ''
    echo "object-caching-experiments dev shell"
    echo "  apps: nix run .#cache-check-host | cache-network-setup | cache-gen-secrets"
    echo "        cache-start-all | cache-vm-ssh -- --node=cache0 -- uptime"
  '';
}
