# ─── nix/lib/mk-microvm-node.nix ───────────────────────────────────────
# Shared MicroVM node generator. Both cache and client VMs are the same
# hardened boot+SSH+networkd+ZFS+observability scaffold; they differ ONLY
# in role (resources/ZFS sizing), the composed feature modules, and the
# secret-dependent activation scripts. This function builds that common
# nixosSystem once; ../microvm-cache.nix and ../microvm-client.nix are thin
# role descriptors that supply the deltas via `extraModules` + `extraConfig`.
#
# Arguments:
#   role          "cache" | "client" — selects vmResources + ZFS layout.
#   nodeName      e.g. "cache0" / "client0"; keys network/console/hostId maps.
#   hostKey       path to the baked SSH host key (null on a fresh dev box →
#                 boot fails loud; run `nix run .#cache-gen-secrets`).
#   sshPubKey     authorized root key (null → no key installed).
#   extraModules  role-specific NixOS modules (nginx-cache/zot-oracle vs
#                 nginx-client/docker-client/mitm/ca-injector).
#   extraConfig   a NixOS module carrying the role's secret-dependent
#                 activation scripts (cache-tls vs cache-ca/mitm-*).
#
# Returns the microvm declaredRunner, exactly as the old per-role files did.
{ lib, microvm, nixpkgs, system, role, nodeName,
  hostKey ? null, sshPubKey ? null,
  extraModules ? [], extraConfig ? {} }:
let
  constants    = import ../constants.nix;
  hostname     = constants.getHostname nodeName;
  res          = constants.getVmResources role;
  consolePorts = constants.getConsolePorts nodeName;
  nodeIp4      = constants.network.ipv4.${nodeName};
  nodeIp6      = constants.network.ipv6.${nodeName};
  mac          = constants.network.macs.${nodeName};
  tap          = constants.network.taps.${nodeName};

  # Per-workload ZFS cache pools (focus-design §18.6): one extra raw volume
  # per pool, identified by a stable virtio serial, with no mountPoint so
  # microvm leaves it untouched for zfs-cache-pools.nix to manage.
  zfs = constants.mkZfsLayout role;
  zfsVolumes = map (p: {
    image = "${hostname}-${p.shortName}.img";
    serial = p.serial;
    size = p.sizeGiB * 1024;
    mountPoint = null;
  }) zfs.pools;

  vmConfig = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      microvm.nixosModules.microvm
      ../modules/sysctls.nix
      ../modules/observability.nix
      ../modules/zfs-cache-pools.nix
      ({ config, pkgs, ... }: {
        system.stateVersion  = "26.05";
        nixpkgs.hostPlatform = system;
        networking.hostName  = hostname;

        # Per-workload ZFS cache pools (focus-design §18.6).
        cacheZfs = {
          enable       = true;
          hostId       = constants.hostIds.${nodeName};
          pools        = zfs.pools;
          datasets     = zfs.datasets;
          # ARC / L2ARC / ZIL tuning (focus-design §18.7).
          arcMaxBytes  = constants.getZfsArcMaxBytes role;
          l2arc.enable = constants.zfsTuning.l2arc.enable;
          slog.enable  = constants.zfsTuning.slog.enable;
        };

        microvm = {
          hypervisor = "qemu";
          mem  = res.mem;     # cache 8192 (power of two — drop to 8191 if QEMU hangs); client 6144
          vcpu = res.vcpu;    # 4 (matches multi_queue TAP queue count)
          shares = [{
            tag = "ro-store"; source = "/nix/store";
            mountPoint = "/nix/.ro-store"; proto = "9p";
          }];
          volumes = [{
            image = "${hostname}-data.img";
            mountPoint = "/var/lib"; size = res.dataGiB * 1024;
          }] ++ zfsVolumes;
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

        networking.firewall.enable = false;   # trusted lab subnet
      })
      extraConfig
    ] ++ extraModules;
  };
in
vmConfig.config.microvm.declaredRunner
