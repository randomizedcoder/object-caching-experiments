# ─── nix/lib/sh-helpers.nix ────────────────────────────────────────────
# Eval-time shell snippet builders shared by the lifecycle apps
# (../microvm-scripts.nix, ../ubuntu-vm.nix). These are plain strings the
# apps interpolate into their `writeShellApplication` text — NOT runtime
# functions — so the dedup happens in Nix and every app emits the same
# guard/option text by construction. The generated scripts differ from the
# old copy-pasted ones only in whitespace; behavior (flags, exit codes) is
# unchanged.
{ lib }:
rec {
  # Guard: the lab SSH private key must exist before any ssh/scp. Identical
  # across every app that talks to a node, so it lives here once.
  requireKey = ''
    KEY="''${PWD}/secrets/ssh-ed25519"
    if [[ ! -f "$KEY" ]]; then
      echo "ERROR: $KEY not found. Run 'nix run .#cache-gen-secrets' first." >&2
      exit 1
    fi'';

  # Error block for when secrets haven't been generated (no baked
  # known_hosts) — the eval-time `knownHosts == null` branch in each app.
  noKnownHosts = ''
    echo "ERROR: no known_hosts baked. Run 'nix run .#cache-gen-secrets' first." >&2
    exit 1'';

  # Non-interactive SSH/scp options for root@<microvm>: strict host-key
  # checking against the baked known_hosts, lab key only (no agent). Emits a
  # space-separated option string consumed by `ssh`/`scp` word-splitting.
  # `knownHosts` is the store path of the baked known_hosts file.
  sshOpts = knownHosts:
    "-o StrictHostKeyChecking=yes "
  + "-o UserKnownHostsFile=${knownHosts} "
  + "-o IdentitiesOnly=yes -i \"$KEY\"";
}
