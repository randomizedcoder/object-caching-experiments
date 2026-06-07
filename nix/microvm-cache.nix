# ─── nix/microvm-cache.nix ─────────────────────────────────────────────
# Generator for the cache VMs (cache0 / cache1, interchangeable). Thin
# wrapper around nixpkgs.lib.nixosSystem returning microvm.declaredRunner,
# mirroring ceph-on-k8s/nix/microvm-client.nix.
#
# Phase 1: shared scaffolding only (boot + SSH + networkd + sysctls +
# node_exporter). The nginx-cache / zot-oracle modules and the cache
# server-cert activation land in Phase 2.
{ pkgs, lib, microvm, nixpkgs, system, nodeName,
  hostKey ? null, sshPubKey ? null, cacheServer ? null }:
let
  constants    = import ./constants.nix;
  hostname     = constants.getHostname nodeName;
  res          = constants.getVmResources "cache";
  consolePorts = constants.getConsolePorts nodeName;
  nodeIp4      = constants.network.ipv4.${nodeName};
  nodeIp6      = constants.network.ipv6.${nodeName};
  mac          = constants.network.macs.${nodeName};
  tap          = constants.network.taps.${nodeName};

  vmConfig = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      microvm.nixosModules.microvm
      ./modules/sysctls.nix
      ./modules/observability.nix
      ({ config, pkgs, ... }: {
        system.stateVersion  = "26.05";
        nixpkgs.hostPlatform = system;
        networking.hostName  = hostname;

        microvm = {
          hypervisor = "qemu";
          mem  = res.mem;     # 8192 (power of two — drop to 8191 if QEMU hangs)
          vcpu = res.vcpu;    # 4 (matches multi_queue TAP queue count)
          shares = [{
            tag = "ro-store"; source = "/nix/store";
            mountPoint = "/nix/.ro-store"; proto = "9p";
          }];
          volumes = [{
            image = "${hostname}-data.img";
            mountPoint = "/var/lib"; size = res.dataGiB * 1024;
          }];
          interfaces = [{ type = "tap"; id = tap; mac = mac; }];
          qemu = {
            serialConsole = false;
            extraArgs = [
              "-name" "${hostname},process=${hostname}"
              "-serial" "tcp:127.0.0.1:${toString consolePorts.serial},server,nowait"
              "-device" "virtio-serial-pci"
              "-chardev" "socket,id=virtcon,port=${toString consolePorts.virtio},host=127.0.0.1,server=on,wait=off"
              "-device" "virtconsole,chardev=virtcon"
            ];
          };
        };

        boot.kernelParams = [ "console=ttyS0,115200" "console=hvc0" ];

        # ── static dual-stack via systemd-networkd ────────────────────
        networking.useDHCP = false;
        systemd.network = {
          enable = true;
          networks."10-tap" = {
            matchConfig.Name = "enp*";
            networkConfig = {
              Address = [ "${nodeIp4}/24" "${nodeIp6}/64" ];
              Gateway = constants.network.gateway4;
              DHCP = "no";
              IPv6AcceptRA = false;
            };
            routes = [ { Gateway = constants.network.gateway4; } ];
          };
        };

        # ── hardened sshd (key-only) ──────────────────────────────────
        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = lib.mkForce false;
            KbdInteractiveAuthentication = lib.mkForce false;
            PermitRootLogin = lib.mkForce "prohibit-password";
          };
          hostKeys = [ { type = "ed25519"; path = "/etc/ssh/ssh_host_ed25519_key"; } ];
        };
        users.users.root = {
          hashedPassword = "!";
          openssh.authorizedKeys.keys = lib.optional (sshPubKey != null) sshPubKey;
        };

        # ── build-time SSH host key (fail loud if secrets absent) ──────
        system.activationScripts.ssh-host-key = ''
          ${if hostKey == null then ''
            echo "ERROR: no SSH host key supplied. Run 'nix run .#cache-gen-secrets' first." >&2
            exit 1
          '' else ''
            install -d -m 0755 /etc/ssh
            install -m 0600 ${hostKey}     /etc/ssh/ssh_host_ed25519_key
            install -m 0644 ${hostKey}.pub /etc/ssh/ssh_host_ed25519_key.pub
          ''}'';

        # ── shared cache server cert (Phase 2; no-op while null) ───────
        system.activationScripts.cache-tls = lib.optionalString (cacheServer != null) ''
          install -d -m 0755 /etc/nginx/cache
          install -m 0644 ${cacheServer.crt} /etc/nginx/cache/cache-server.crt
          install -m 0600 ${cacheServer.key} /etc/nginx/cache/cache-server.key
        '';

        networking.firewall.enable = false;   # trusted lab subnet
      })
    ];
  };
in
vmConfig.config.microvm.declaredRunner
