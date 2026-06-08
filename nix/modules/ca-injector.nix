# ─── nix/modules/ca-injector.nix ───────────────────────────────────────
# Transparent MITM-trust injection for UNMODIFIED container pulls/builds
# (design §13.5). The hard constraint: a user's `FROM huggingface.co/...`
# or an in-container `curl https://huggingface.co/...` must Just Work — no
# edits to their Dockerfile, no `-k`, no baked-in CA. We slip two things
# into every container:
#   1. a CA bundle that trusts this client's MITM CA (so the forged origin
#      certs validate), and
#   2. /etc/hosts lines pinning each MITM'd FQDN to the client's LAN IP
#      (so the container reaches the client nginx :443 frontend — NOT
#      127.0.0.1, which inside a container is its OWN loopback, §14.4).
#
# Mechanism: a custom OCI runtime shim. dockerd's default-runtime is set to
# `runc-with-ca`, whose binary is `runc-with-ca-wrapper`. On the `create`
# call it jq-injects read-only BIND MOUNTS into the bundle's config.json,
# then exec's the real runc.
#
# Why bind mounts and not an nsenter prestart hook (the original §13.5
# sketch): with docker's containerd-snapshotter image store, at create-hook
# time the container rootfs is NOT yet visible — `nsenter -m` into the init
# pid shows the HOST fs and `$bundle/rootfs` is empty (the snapshot is
# mounted into the container mount-ns only later, before pivot_root). So a
# create-time hook physically cannot touch the container's files. config.json
# `.mounts`, by contrast, ARE honoured by runc regardless of snapshotter —
# runc creates the mountpoint if absent, so over-mounting a path the image
# lacks is harmless. This also keeps us strictly FAIL-OPEN: the wrapper only
# edits config.json (best-effort, falls back to the untouched file) and never
# runs a hook that could exit non-zero and abort the user's container.
#
# CA trust is delivered two ways at once, because container images put their
# trust store in wildly different places (curlimages/curl uses /cacert.pem;
# alpine /etc/ssl/cert.pem; debian /etc/ssl/certs/ca-certificates.crt; rhel
# /etc/pki/...). Guessing paths is unreliable, so the PRIMARY mechanism is
# environment variables that every common TLS library honours
# (SSL_CERT_FILE/CURL_CA_BUNDLE/REQUESTS_CA_BUNDLE/GIT_SSL_CAINFO for
# openssl/curl/python/git; NODE_EXTRA_CA_CERTS for node), all pointed at one
# fixed in-container path. A belt-and-suspenders set of bind mounts over the
# well-known distro paths covers tools that ignore the env vars.
#
# The bundle source is /etc/cache-mitm-ca-bundle.crt — system public CAs ++
# this client's MITM CA, assembled by the mitm-ca-file activation in
# microvm-client.nix. Using the COMBINED bundle (not just the MITM CA) means
# SSL_CERT_FILE can fully replace the default store without losing normal
# public-CA trust.
{ config, pkgs, lib, ... }:
let
  c = import ../constants.nix;

  # This client's own LAN IP — the address containers must resolve the
  # MITM'd FQDNs to (reaches our nginx :443 over the bridge, §14.4). NOT
  # 127.0.0.1: inside a container that's the container's own loopback.
  nodeName = lib.removePrefix "cache-" config.networking.hostName;
  nodeIp   = c.network.ipv4.${nodeName};

  # Full /etc/hosts bind-mounted into every container. We replace the file
  # wholesale (docker's per-container hostname entry is irrelevant to model
  # fetches in this lab), so it must carry the localhost basics too.
  containerHosts = ''
    127.0.0.1 localhost
    ::1 localhost
  '' + lib.concatMapStringsSep "\n" (f: "${nodeIp} ${f}") c.mitmAllFqdns + "\n";

  # The runtime shim docker calls instead of runc (shared with the Ubuntu
  # clients). Node-agnostic: references only fixed /etc paths.
  wrapper = import ../ca-injector-wrapper.nix { inherit pkgs lib; };
in
{
  # The hosts file bind-mounted into every container (FQDN → client LAN IP).
  environment.etc."cache-mitm-hosts".text = containerHosts;

  # Register the shim as docker's default runtime. Merges with the docker
  # settings in docker-client.nix (NixOS deep-merges attrsets).
  virtualisation.docker.daemon.settings = {
    default-runtime = "runc-with-ca";
    runtimes."runc-with-ca".path = "${wrapper}/bin/runc-with-ca-wrapper";
  };

  environment.systemPackages = [ wrapper ];
}
