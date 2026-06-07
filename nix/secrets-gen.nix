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

  # SAN for the shared cache server cert: the stable serverName plus both
  # cache VMs' IPv4+IPv6 (they present the SAME cert, so the consistent-hash
  # upstream verifies one name regardless of which peer ketama picks). §11.5.
  serverName = constants.cacheTls.serverName;
  cacheSan = "DNS:${serverName}" + builtins.concatStringsSep "" (builtins.map
    (n: ",IP:${constants.network.ipv4.${n}},IP:${constants.network.ipv6.${n}}")
    constants.cacheNames);
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

  # ── Phase 2b: the cache CA + one shared cache server cert (§11.5) ──────
  # A dedicated lab-wide CA (separate from the per-client MITM CA) signs ONE
  # server cert deployed to BOTH interchangeable cache VMs; every client
  # trusts the CA and verifies (proxy_ssl_verify on). CA/server keys stay in
  # secrets/ — only the public CA cert is SSH-pushed to clients.
  caGen = pkgs.writeShellApplication {
    name = "cache-gen-ca";
    runtimeInputs = with pkgs; [ coreutils openssl git ];
    text = ''
      set -euo pipefail

      DIR="''${PWD}/secrets/cache"
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
      install -d -m 0700 "$DIR" "$DIR/ca" "$DIR/server"

      # ── self-signed cache CA ──────────────────────────────────────────
      openssl genrsa -out "$DIR/ca/cache-CA.key" 4096
      chmod 600 "$DIR/ca/cache-CA.key"
      openssl req -x509 -new -nodes -key "$DIR/ca/cache-CA.key" \
        -sha256 -days 3650 -out "$DIR/ca/cache-CA.crt" \
        -subj "/O=object-caching-experiments/CN=cache-CA"
      chmod 644 "$DIR/ca/cache-CA.crt"

      # ── shared server cert (SAN = serverName + both cache IPs) ─────────
      openssl genrsa -out "$DIR/server/cache-server.key" 2048
      chmod 600 "$DIR/server/cache-server.key"
      openssl req -new -key "$DIR/server/cache-server.key" \
        -out "$DIR/server/cache-server.csr" \
        -subj "/O=object-caching-experiments/CN=${serverName}"
      cat > "$DIR/server/cache-server.ext" <<'EXT'
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${cacheSan}
EXT
      openssl x509 -req -in "$DIR/server/cache-server.csr" \
        -CA "$DIR/ca/cache-CA.crt" -CAkey "$DIR/ca/cache-CA.key" \
        -CAcreateserial -sha256 -days 825 \
        -extfile "$DIR/server/cache-server.ext" \
        -out "$DIR/server/cache-server.crt"
      chmod 644 "$DIR/server/cache-server.crt"
      rm -f "$DIR/server/cache-server.csr" "$DIR/server/cache-server.ext"

      # Make untracked files visible to the flake (pure-eval sees only
      # tracked/intent-to-add paths).
      git add --intent-to-add "$DIR" 2>/dev/null || true

      echo "Cache CA + shared server cert written to $DIR"
      echo "  CA cert : $DIR/ca/cache-CA.crt (public; SSH-pushed to clients)"
      echo "  server  : $DIR/server/cache-server.{crt,key} (both cache VMs)"
      echo "  SAN     : ${cacheSan}"
    '';
  };
}
