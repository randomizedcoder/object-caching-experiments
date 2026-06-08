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
# Stages: 4b-1 sysctls + node_exporter; 4b-2 (this) the nginx serving path
# (OCI/apt frontends + cache-CA TLS hop + :443 MITM frontends) reusing
# modules/nginx-client.nix verbatim; 4b-3 docker/containerd/ca-injector.
#
# This is ONE config shared by all three Ubuntu nodes, so it must be
# node-agnostic: it reuses client0's per-FQDN MITM leaves + the shared cache
# CA (passed in via specialArgs from flake.nix). Per-node bits (container
# /etc/hosts → that node's LAN IP) are resolved at runtime in 4b-3.
{ pkgs, lib, cacheCa ? null, mitm ? null, ... }:
let
  c = import ./constants.nix;

  # Same tuning the NixOS VMs get via boot.kernel.sysctl (modules/sysctls.nix),
  # rendered to a drop-in since system-manager ignores boot.kernel.sysctl.
  sysctlValues = import ./sysctl-values.nix;
  sysctlConf = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "${k} = ${toString v}") sysctlValues) + "\n";

  # Per-FQDN leaf crt/key this client's nginx :443 loads (§14.2). One per
  # mitmCertGroups entry, from client0's reused MITM tree. Empty until
  # cache-gen-ca has run (mitm == null).
  mitmLeaves = if mitm == null then [] else
    map (g: {
      name = g.name;
      crt  = mitm.mitmDir + "/${g.name}.crt";
      key  = mitm.mitmDir + "/${g.name}.key";
    }) c.mitmCertGroups;

  # nginx runs as the userborn-created static nginx user (uid/gid 980, forced
  # by system-manager's nginx.nix); reference it numerically so the etc-file
  # copy doesn't depend on name resolution ordering during activation.
  nginxUid = 980;

  # /etc/hosts MITM block (host-level): pin every MITM'd FQDN to 127.0.0.1 so
  # host tools hit the local nginx :443. (Containers get the LAN IP instead,
  # via ca-injector in 4b-3.) system-manager has no networking.extraHosts, so
  # the cache-trust oneshot below maintains a marked block in /etc/hosts.
  hostsBlock = lib.concatMapStringsSep "\n" (f: "127.0.0.1 ${f}") c.mitmAllFqdns;

  # Runtime trust + bundle + /etc/hosts. Replaces the NixOS security.pki +
  # mitm-ca-file activation (neither exists under system-manager).
  caTrust = pkgs.writeShellApplication {
    name = "cache-trust";
    runtimeInputs = with pkgs; [ coreutils gnused gnugrep ];
    text = ''
      # Ubuntu's update-ca-certificates is a system script that shells out to
      # openssl/run-parts/etc; writeShellApplication pins PATH to runtimeInputs,
      # so append the distro bin dirs to let it use the guest's own tools.
      export PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"

      # 1) Trust the MITM CA system-wide (Ubuntu's update-ca-certificates).
      if [ -f /etc/cache-mitm-ca.crt ]; then
        install -d -m 0755 /usr/local/share/ca-certificates
        install -m 0644 /etc/cache-mitm-ca.crt \
          /usr/local/share/ca-certificates/cache-mitm-ca.crt
        if command -v update-ca-certificates >/dev/null 2>&1; then
          update-ca-certificates >/dev/null
        else
          /usr/sbin/update-ca-certificates >/dev/null
        fi
        # 2) Combined bundle (system store ++ MITM CA) for the ca-injector.
        cat /etc/ssl/certs/ca-certificates.crt /etc/cache-mitm-ca.crt \
          > /etc/cache-mitm-ca-bundle.crt
        chmod 0644 /etc/cache-mitm-ca-bundle.crt
      fi

      # 3) /etc/hosts marked block (idempotent rewrite).
      sed -i '/# BEGIN cache-lab MITM/,/# END cache-lab MITM/d' /etc/hosts
      {
        echo "# BEGIN cache-lab MITM"
        cat <<'HOSTS'
${hostsBlock}
HOSTS
        echo "# END cache-lab MITM"
      } >> /etc/hosts
    '';
  };
in
{
  # Reuse the NixOS client's serving path verbatim (services.nginx is one of
  # the upstream modules system-manager carries). It loads the runtime cert
  # paths we install below; validateConfigFile=false in the module skips the
  # build-time nginx -t that those paths would break.
  imports = [ ./modules/nginx-client.nix ];

  nixpkgs.hostPlatform = "x86_64-linux";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = with pkgs; [ htop curl jq ];

  # ── sysctl tuning (§18.1) ─────────────────────────────────────────────
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

  # ── node_exporter (:9100) + nginx exporter (:9113), §19 ───────────────
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

  # stub_status served on loopback only; the exporter re-exposes Prometheus
  # metrics on :9113. (The prometheus exporter NixOS module isn't carried by
  # system-manager, so run the binary directly.)
  services.nginx.virtualHosts."nginx-status" = {
    listen    = [{ addr = "127.0.0.1"; port = c.ports.nginxStatus; }];
    locations."/nginx_status".extraConfig = ''
      stub_status;
      access_log off;
    '';
  };
  systemd.services.nginx-exporter = {
    description = "Prometheus nginx exporter";
    wantedBy   = [ "multi-user.target" ];
    after      = [ "nginx.service" ];
    serviceConfig = {
      ExecStart   = "${pkgs.prometheus-nginx-exporter}/bin/nginx-prometheus-exporter "
                  + "--nginx.scrape-uri=http://127.0.0.1:${toString c.ports.nginxStatus}/nginx_status "
                  + "--web.listen-address=:${toString c.ports.nginxExporter}";
      DynamicUser = true;
      Restart     = "on-failure";
      RestartSec  = 2;
    };
  };

  # ── nginx user: static (uid 980), not DynamicUser ─────────────────────
  # system-manager's nginx.nix forces DynamicUser=true; override it so the
  # /var/lib/cache dirs (owned by the static nginx user via tmpfiles) and the
  # 0440-nginx leaf keys are actually owned by the runtime process.
  systemd.services.nginx.serviceConfig.DynamicUser = lib.mkForce false;

  # ── certs nginx loads at runtime ──────────────────────────────────────
  # Public certs as symlinks; the per-FQDN leaf KEYS copied 0440 owned by
  # nginx (uid 980). Source paths come from secrets/ via specialArgs.
  environment.etc = lib.mkMerge [
    {
      # Stub marker (confirms a switch took effect) + sysctl drop-in.
      "cache-ubuntu-client-stub".text =
        "ubuntu-client system-manager stub (Phase 4b-2)\nuserAgent=${c.userAgent}\n";
      "sysctl.d/60-cache-lab.conf".text = sysctlConf;
    }
    (lib.optionalAttrs (cacheCa != null) {
      "nginx/cache-ca.crt".source = cacheCa;
    })
    (lib.optionalAttrs (mitm != null) {
      "cache-mitm-ca.crt".source = mitm.ca;
    })
    (lib.optionalAttrs (mitm != null) (lib.listToAttrs (lib.concatMap (l: [
      (lib.nameValuePair "nginx/mitm/${l.name}.crt" { source = l.crt; })
      (lib.nameValuePair "nginx/mitm/${l.name}.key" {
        source = l.key; mode = "0440"; uid = nginxUid; gid = nginxUid;
      })
    ]) mitmLeaves)))
  ];

  # ── runtime trust (CA store + bundle + /etc/hosts) ────────────────────
  systemd.services.cache-trust = {
    description = "Install MITM CA trust + /etc/hosts poisoning";
    wantedBy   = [ "multi-user.target" ];
    before     = [ "nginx.service" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart       = "${caTrust}/bin/cache-trust";
    };
  };
}
