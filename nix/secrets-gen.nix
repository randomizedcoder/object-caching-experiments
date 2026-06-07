# ─── nix/secrets-gen.nix ───────────────────────────────────────────────
# Offline secret/CA generators, exposed as `nix run .#cache-*` apps.
# Phase 1: `cache-gen-secrets` (SSH host + user keys + known_hosts).
# Phase 2/3 add `cache-gen-ca` and `cache-distribute-trust`.
# Mirrors ceph-on-k8s/nix/secrets-gen.nix.
{ pkgs, constants }:
let
  # The three NixOS VMs we mint host keys for.
  nodes = constants.clientNames ++ constants.cacheNames;   # [client0 cache0 cache1]

  # node → "hostname ip" pairs the generator iterates over.
  nodeLines = builtins.concatStringsSep "\n" (builtins.map
    (n: "${constants.getHostname n} ${constants.network.ipv4.${n}}")
    nodes);
in
{
  secrets = pkgs.writeShellApplication {
    name = "cache-gen-secrets";
    runtimeInputs = with pkgs; [ coreutils openssh git gnugrep ];
    text = ''
      set -euo pipefail

      DIR="''${PWD}/secrets"
      FORCE=0
      for arg in "$@"; do
        case "$arg" in
          --force) FORCE=1 ;;
          *) echo "unknown arg: $arg" >&2; exit 2 ;;
        esac
      done

      if [ -e "$DIR" ] && [ "$FORCE" -ne 1 ]; then
        echo "ERROR: $DIR already exists. Re-run with --force to overwrite." >&2
        exit 1
      fi
      rm -rf "$DIR"
      install -d -m 0700 "$DIR" "$DIR/host-keys"

      # ── user key authorized on every VM ──────────────────────────────
      ssh-keygen -t ed25519 -f "$DIR/ssh-ed25519" -N "" \
        -C "object-caching-experiments lab" -q
      chmod 600 "$DIR/ssh-ed25519"
      chmod 644 "$DIR/ssh-ed25519.pub"

      # ── per-node host keys + known_hosts ─────────────────────────────
      : > "$DIR/known_hosts"
      while read -r hostname ip; do
        [ -z "$hostname" ] && continue
        keyfile="$DIR/host-keys/$hostname"
        ssh-keygen -t ed25519 -f "$keyfile" -N "" -C "$hostname" -q
        chmod 600 "$keyfile"
        chmod 644 "$keyfile.pub"
        pub="$(cut -d' ' -f1-2 < "$keyfile.pub")"
        # Trust the node by both its IPv4 and short hostname.
        echo "$ip $pub"       >> "$DIR/known_hosts"
        echo "$hostname $pub" >> "$DIR/known_hosts"
      done <<'NODES'
${nodeLines}
NODES

      # Make untracked files visible to the flake (pure-eval sees only
      # tracked/intent-to-add paths).
      git add --intent-to-add "$DIR" 2>/dev/null || true

      echo "Secrets written to $DIR"
      echo "  user key : $DIR/ssh-ed25519(.pub)"
      echo "  host keys: $DIR/host-keys/"
      echo "  known_hosts: $DIR/known_hosts"
    '';
  };
}
