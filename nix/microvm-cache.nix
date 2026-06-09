# ─── nix/microvm-cache.nix ─────────────────────────────────────────────
# Cache-VM role descriptor (cache0 / cache1, interchangeable). All the
# shared boot/SSH/networkd/ZFS/observability scaffold lives in
# ./lib/mk-microvm-node.nix; this file only declares what makes a cache VM
# a cache VM: the cache feature modules and the shared-server-cert install.
{ pkgs, lib, microvm, nixpkgs, system, nodeName,
  hostKey ? null, sshPubKey ? null, cacheServer ? null }:
import ./lib/mk-microvm-node.nix {
  inherit lib microvm nixpkgs system nodeName hostKey sshPubKey;
  role = "cache";

  extraModules = [
    ./modules/nginx-cache.nix
    ./modules/zot-oracle.nix
  ];

  # ── shared cache server cert (no-op while cacheServer == null) ─────────
  # Owned by the nginx user: nginx-pre-start runs `nginx -t` as that user,
  # so a root-only 0600 key fails the config test (Permission denied).
  # deps=["users"] guarantees the nginx user exists first.
  extraConfig = {
    system.activationScripts.cache-tls = {
      deps = [ "users" ];
      text = lib.optionalString (cacheServer != null) ''
        install -d -m 0755 /etc/nginx/cache
        install -o nginx -g nginx -m 0644 ${cacheServer.crt} /etc/nginx/cache/cache-server.crt
        install -o nginx -g nginx -m 0600 ${cacheServer.key} /etc/nginx/cache/cache-server.key
      '';
    };
  };
}
