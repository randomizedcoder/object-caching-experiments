# ─── nix/microvm-client.nix ────────────────────────────────────────────
# Client-VM role descriptor (client0). Shares the boot/SSH/networkd/ZFS/
# observability scaffold via ./lib/mk-microvm-node.nix; this file only
# declares the client deltas: the docker/nginx-client/mitm/ca-injector
# modules and the cache-CA + per-client MITM-CA/leaf activation.
{ pkgs, lib, microvm, nixpkgs, system, nodeName,
  hostKey ? null, sshPubKey ? null, mitm ? null, cacheCa ? null }:
let
  constants = import ./constants.nix;

  # Per-FQDN leaf certs this client's nginx :443 loads (§14.2/§14.3). One
  # per mitmCertGroups entry, signed by this client's own MITM CA. Empty
  # until cache-gen-ca has run (mitm == null).
  mitmLeaves = if mitm == null then [] else
    map (g: {
      name = g.name;
      crt  = mitm.mitmDir + "/${g.name}.crt";
      key  = mitm.mitmDir + "/${g.name}.key";
    }) constants.mitmCertGroups;
in
import ./lib/mk-microvm-node.nix {
  inherit lib microvm nixpkgs system nodeName hostKey sshPubKey;
  role = "client";

  extraModules = [
    ./modules/nginx-client.nix
    ./modules/docker-client.nix
    ./modules/mitm.nix
    ./modules/ca-injector.nix
  ];

  extraConfig = {
    # ── cache CA public cert (no-op while cacheCa == null) ─────────────
    system.activationScripts.cache-ca = lib.optionalString (cacheCa != null) ''
      install -d -m 0755 /etc/nginx
      install -m 0644 ${cacheCa} /etc/nginx/cache-ca.crt
    '';

    # ── per-client MITM CA + leaves (§14.2/§14.4) ──────────────────────
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
  };
}
