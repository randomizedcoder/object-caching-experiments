# ─── nix/modules/mitm.nix ──────────────────────────────────────────────
# Client-side HTTPS interception plumbing (focus-design §14). This module
# carries only the SECRET-INDEPENDENT half: the /etc/hosts poisoning that
# pins every MITM'd FQDN to 127.0.0.1 (so the local nginx :443 frontend
# terminates them), plus the /etc/nginx/mitm dir the leaf certs land in.
#
# The secret-DEPENDENT half — trusting THIS client's own root CA
# (security.pki.certificateFiles) and installing the per-FQDN leaf
# crt/key into /etc/nginx/mitm — lives in the inline module of
# microvm-client.nix, where the per-client `mitm` secret is in scope
# (same pattern as the cache-ca activation). See §14.2/§14.4.
{ config, pkgs, lib, ... }:
let
  c = import ../constants.nix;
  # "127.0.0.1 fqdn" per MITM'd host (model stores + mitmExtraHosts, §14.3).
  hostsBlock = lib.concatMapStringsSep "\n" (f: "127.0.0.1 ${f}") c.mitmAllFqdns;
in
{
  # DNS redirection (no DNS server in v1 — /etc/hosts poisoning, §14.3).
  networking.extraHosts = hostsBlock;

  # Leaf certs (this client's, signed by its own CA) are installed here by
  # the client generator's `mitm-leaves` activation; nginx loads them per
  # SNI server{}. Created up front so the activation can drop files in.
  systemd.tmpfiles.rules = [
    "d /etc/nginx 0755 root root - -"
    "d /etc/nginx/mitm 0755 nginx nginx - -"
  ];
}
