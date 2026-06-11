# ─── nix/microvm-client.nix ────────────────────────────────────────────
# Client-VM role descriptor (client0). Shares the boot/SSH/networkd/ZFS/
# observability scaffold via ./lib/mk-microvm-node.nix; this file only
# declares the client deltas: the docker/nginx-client/mitm/ca-injector
# modules and the cache-CA + per-client MITM-CA/leaf activation.
{ pkgs, lib, microvm, nixpkgs, system, nodeName,
  hostKey ? null, sshPubKey ? null, mitm ? null, cacheCa ? null }:
let
  constants = import ./constants.nix;

  # Patched containerd: adds the `dial_addr` hosts.toml field so the OCI pull
  # hop reaches the client nginx over a Unix domain socket instead of loopback
  # TCP (fork randomizedcoder/containerd#1). Pinned by commit rev; vendorHash
  # stays null (the fork's committed vendor/ is unchanged). The REVISION/VERSION
  # swap makes `containerd --version` report the fork — positive deploy proof.
  containerdOverlay = final: prev: {
    containerd = prev.containerd.overrideAttrs (old: {
      version = "2.2.1-uds";
      src = prev.fetchFromGitHub {
        owner = "randomizedcoder";
        repo  = "containerd";
        rev   = "8123c921742aceca6749392d048bf13e0a936d55";
        hash  = "sha256-AQW1KIFLc2TB2vEkHKHkHuCZNsGmY1SZSPI049Kmyds=";
      };
      makeFlags =
        (builtins.filter
          (f: !(lib.hasPrefix "REVISION=" f || lib.hasPrefix "VERSION=" f))
          old.makeFlags)
        ++ [ "REVISION=8123c921742aceca6749392d048bf13e0a936d55" "VERSION=v2.2.1-uds" ];
    });
  };

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
    # ── patched containerd (UDS dial_addr, §12) ───────────────────────
    nixpkgs.overlays = [ containerdOverlay ];

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

    # Install the runtime SNI minter's signing material (§14.6): the per-client
    # MITM CA cert+key (issuer) and the single reused EC leaf key, all read
    # once at init_by_lua. Owned by nginx (the config-test pre-start and the
    # workers read them as that user); private keys 0600. The CA private key
    # now lives on the box so the minter can sign a leaf per SNI online — it is
    # per-client and never leaves this node (same isolation as the offline
    # signer it replaces). Paths match constants.mitmMinter (ca.crt/ca.key/
    # leaf.key under /etc/nginx/mitm).
    system.activationScripts.mitm-leaves =
      lib.optionalString (mitm != null) ''
        install -d -m 0755 /etc/nginx/mitm
        install -o nginx -g nginx -m 0644 ${mitm.ca}      /etc/nginx/mitm/ca.crt
        install -o nginx -g nginx -m 0600 ${mitm.caKey}   /etc/nginx/mitm/ca.key
        install -o nginx -g nginx -m 0600 ${mitm.leafKey} /etc/nginx/mitm/leaf.key
      '';
  };
}
