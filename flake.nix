{
  description = "object-caching-experiments: pull-through caching fabric on NixOS MicroVMs";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, microvm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        nixDir = ./nix;
        pkgs   = nixpkgs.legacyPackages.${system};
        lib    = pkgs.lib;

        constants = import (nixDir + "/constants.nix");
        nodes     = import (nixDir + "/nodes.nix") { inherit constants; };

        # Null-able reads of ./secrets/ — flake still evaluates if absent;
        # the build-time activation scripts fail loudly at boot instead.
        secrets = import (nixDir + "/secrets.nix") { inherit pkgs lib; };

        # ── One generator per machine role ──────────────────────────────
        mkCacheNode = { nodeName }:
          import (nixDir + "/microvm-cache.nix") {
            inherit pkgs lib microvm nixpkgs system nodeName;
            hostKey     = secrets.hostKeyPath nodeName;   # path | null
            sshPubKey   = secrets.sshPubKey;
            cacheServer = secrets.cacheServer;            # {crt;key;} | null (Phase 2)
          };

        mkCacheClient = { nodeName }:
          import (nixDir + "/microvm-client.nix") {
            inherit pkgs lib microvm nixpkgs system nodeName;
            hostKey   = secrets.hostKeyPath nodeName;
            sshPubKey = secrets.sshPubKey;
            mitm      = secrets.clientMitm nodeName;       # per-client MITM | null (Phase 3)
            cacheCa   = secrets.cacheCaCert;               # cache CA cert | null (Phase 2)
          };

        cachePackages = lib.mapAttrs' (name: _:
          lib.nameValuePair "cache-microvm-${name}" (mkCacheNode { nodeName = name; })
        ) nodes.cacheDefinitions;

        clientPackages = lib.mapAttrs' (name: _:
          lib.nameValuePair "cache-microvm-${name}" (mkCacheClient { nodeName = name; })
        ) nodes.clientDefinitions;
      in {
        packages = cachePackages // clientPackages;

        devShells.default = import (nixDir + "/shell.nix") { inherit pkgs; };

        # Apps are Linux-only (the VMs + host networking are Linux). Phase 1
        # wires the boot subset; Phase 2/3 grow this block.
        apps = lib.optionalAttrs pkgs.stdenv.isLinux (
          let
            net    = import (nixDir + "/network-setup.nix")   { inherit pkgs constants; };
            vm     = import (nixDir + "/microvm-scripts.nix") { inherit pkgs constants secrets; };
            secgen = import (nixDir + "/secrets-gen.nix")     { inherit pkgs constants; };
            mkApp  = drv: bin: { type = "app"; program = "${drv}/bin/${bin}"; };
          in {
            cache-check-host       = mkApp net.check      "cache-check-host";
            cache-network-setup    = mkApp net.setup      "cache-network-setup";
            cache-network-teardown = mkApp net.teardown   "cache-network-teardown";
            cache-gen-secrets      = mkApp secgen.secrets "cache-gen-secrets";
            cache-start-all        = mkApp vm.startAll    "cache-start-all";
            cache-vm-ssh           = mkApp vm.ssh         "cache-vm-ssh";
            cache-vm-stop          = mkApp vm.stop        "cache-vm-stop";
            cache-vm-wipe          = mkApp vm.wipe        "cache-vm-wipe";
          });
      });
}
