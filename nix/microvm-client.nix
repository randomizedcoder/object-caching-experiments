# ─── nix/microvm-client.nix ────────────────────────────────────────────
# Generator for the NixOS client (client0). Identical shared scaffolding
# to microvm-cache.nix; differs only in resources, composed modules, and
# baked secrets.
#
# Phase 1: shared scaffolding only (boot + SSH + networkd + sysctls +
# node_exporter). The docker/nginx-client/mitm/ca-injector modules and the
# MITM-CA / cache-CA activation land in Phase 2/3.
{ pkgs, lib, microvm, nixpkgs, system, nodeName,
  hostKey ? null, sshPubKey ? null, mitm ? null, cacheCa ? null }:
let
  constants    = import ./constants.nix;
  hostname     = constants.getHostname nodeName;
  res          = constants.getVmResources "client";
  consolePorts = constants.getConsolePorts nodeName;
  nodeIp4      = constants.network.ipv4.${nodeName};
  nodeIp6      = constants.network.ipv6.${nodeName};
  mac          = constants.network.macs.${nodeName};
  tap          = constants.network.taps.${nodeName};

  # Per-FQDN leaf certs this client's nginx :443 loads (§14.2/§14.3). One
  # per mitmCertGroups entry, signed by this client's own MITM CA. Empty
  # until cache-gen-ca has run (mitm == null).
  mitmLeaves = if mitm == null then [] else
    map (g: {
      name = g.name;
      crt  = mitm.mitmDir + "/${g.name}.crt";
      key  = mitm.mitmDir + "/${g.name}.key";
    }) constants.mitmCertGroups;

  vmConfig = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      microvm.nixosModules.microvm
      ./modules/sysctls.nix
      ./modules/observability.nix
      ./modules/nginx-client.nix
      ./modules/docker-client.nix
      ./modules/mitm.nix
      ./modules/ca-injector.nix
      ({ config, pkgs, ... }: {
        system.stateVersion  = "26.05";
        nixpkgs.hostPlatform = system;
        networking.hostName  = hostname;

        microvm = {
          hypervisor = "qemu";
          mem  = res.mem;     # 6144
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

        # ── cache CA public cert (Phase 2; no-op while null) ───────────
        system.activationScripts.cache-ca = lib.optionalString (cacheCa != null) ''
          install -d -m 0755 /etc/nginx
          install -m 0644 ${cacheCa} /etc/nginx/cache-ca.crt
        '';

        # ── per-client MITM CA + leaves (Phase 3, §14.2/§14.4) ─────────
        # Trust THIS client's own root CA so the local nginx :443 can
        # impersonate the model-store origins without TLS errors. Distinct
        # from the cache CA above (that one only authenticates the cache).
        security.pki.certificateFiles = lib.optional (mitm != null) mitm.ca;

        # Raw CA PEM at a fixed path + a COMBINED bundle (system public CAs
        # ++ this MITM CA) the ca-injector (§14.4) bind-mounts into containers
        # and points SSL_CERT_FILE/CURL_CA_BUNDLE/… at. deps=["etc"] so the
        # system bundle (/etc/ssl/certs/ca-certificates.crt, from
        # security.pki) already exists when we concatenate.
        system.activationScripts.mitm-ca-file = {
          deps = [ "etc" ];
          text = lib.optionalString (mitm != null) ''
            install -m 0644 ${mitm.ca} /etc/cache-mitm-ca.crt
            cat /etc/ssl/certs/ca-certificates.crt /etc/cache-mitm-ca.crt \
              > /etc/cache-mitm-ca-bundle.crt
            chmod 0644 /etc/cache-mitm-ca-bundle.crt
          '';
        };

        # Install the per-FQDN leaf crt/key nginx loads per SNI server{}.
        # Owned by nginx (the config-test pre-start reads keys as that user),
        # mirroring the cache-tls install on the cache VMs.
        system.activationScripts.mitm-leaves =
          lib.optionalString (mitm != null) (''
            install -d -m 0755 /etc/nginx/mitm
          '' + lib.concatMapStringsSep "\n" (l: ''
            install -o nginx -g nginx -m 0644 ${l.crt} /etc/nginx/mitm/${l.name}.crt
            install -o nginx -g nginx -m 0600 ${l.key} /etc/nginx/mitm/${l.name}.key
          '') mitmLeaves);

        networking.firewall.enable = false;   # trusted lab subnet
      })
    ];
  };
in
vmConfig.config.microvm.declaredRunner
