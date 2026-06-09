# ─── nix/lib/mitm-hosts.nix ────────────────────────────────────────────
# The one builder for the MITM /etc/hosts poisoning block: one
# "127.0.0.1 <fqdn>" line per MITM'd FQDN (focus-design §14.3). Both the
# NixOS path (../modules/mitm.nix → networking.extraHosts) and the Ubuntu
# path (../ubuntu-client.nix → the cache-trust marked block) call this so
# the emitted text is identical by construction, not by coincidence.
{ lib, fqdns }:
lib.concatMapStringsSep "\n" (f: "127.0.0.1 ${f}") fqdns
