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

  # ── per-client MITM CA inputs (§14.2) ────────────────────────────────
  # Clients that get their own MITM CA + leaves (NixOS client0 for now;
  # the Ubuntu boxes reuse the same secrets/<client> tree via Ansible).
  clientLines = builtins.concatStringsSep "\n" constants.clientNames;
  # "groupname fqdn1,fqdn2,..." — one leaf cert per group (§14.3 SNI unit).
  mitmGroupLines = builtins.concatStringsSep "\n" (builtins.map
    (g: "${g.name} " + builtins.concatStringsSep "," g.fqdns)
    constants.mitmCertGroups);
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

      ROOT="''${PWD}/secrets"
      DIR="$ROOT/cache"
      FORCE=0
      MITM_ONLY=0   # --mitm-only: skip cache-CA minting; reuse a copied-in
                    # PUBLIC cache-CA.crt (bare-metal box, §16 bootstrap).
      NODE=""       # --node=NAME: mint MITM only for NAME (default: all
                    # constants.clientNames). Bare-metal boxes pass client0.
      LEGACY_LEAVES=0 # --legacy-leaves: also mint the OLD pre-minted per-group
                      # leaves (secrets/<client>/mitm/<group>.{crt,key}). The
                      # runtime SNI minter (§14.6) supersedes them — it signs a
                      # leaf per SNI on the box from the CA key + reused leaf
                      # key below — so they are off by default. Kept for the
                      # pre-minter fallback path only.
      for arg in "$@"; do
        case "$arg" in
          --force) FORCE=1 ;;
          --mitm-only) MITM_ONLY=1 ;;
          --node=*) NODE="''${arg#--node=}" ;;
          --legacy-leaves) LEGACY_LEAVES=1 ;;
          *) echo "unknown arg: $arg" >&2; exit 2 ;;
        esac
      done

      # ── cache CA + shared server cert (§11.5) ─────────────────────────
      # Idempotent + additive: skip if already minted (so re-running to add
      # a client's MITM CA doesn't rotate the working cache CA). --force
      # rotates it (rebuild + redistribute trust afterwards).
      if [ "$MITM_ONLY" -eq 1 ]; then
        # Bare-metal box: the canonical cache CA (with key) is minted only in
        # the lab; the box just needs the PUBLIC cert for proxy_ssl_verify.
        # Require it pre-copied (cache-ubuntu-deploy drops only this one file).
        if [ ! -f "$DIR/ca/cache-CA.crt" ]; then
          echo "ERROR: --mitm-only requires $DIR/ca/cache-CA.crt." >&2
          echo "       Copy the PUBLIC cache CA cert from the lab first" >&2
          echo "       (secrets/cache/ca/cache-CA.crt — public, no key)." >&2
          exit 1
        fi
        echo "--mitm-only: reusing public cache CA at $DIR/ca/cache-CA.crt (cache CA not minted)."
      elif [ -e "$DIR" ] && [ "$FORCE" -ne 1 ]; then
        echo "cache CA exists at $DIR — skipping (use --force to rotate)."
      else
        rm -rf "$DIR"
        install -d -m 0700 "$DIR" "$DIR/ca" "$DIR/server"

        # self-signed cache CA
        openssl genrsa -out "$DIR/ca/cache-CA.key" 4096
        chmod 600 "$DIR/ca/cache-CA.key"
        openssl req -x509 -new -nodes -key "$DIR/ca/cache-CA.key" \
          -sha256 -days 3650 -out "$DIR/ca/cache-CA.crt" \
          -subj "/O=object-caching-experiments/CN=cache-CA"
        chmod 644 "$DIR/ca/cache-CA.crt"

        # shared server cert (SAN = serverName + both cache IPs)
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
        echo "Cache CA + shared server cert written to $DIR (SAN ${cacheSan})"
      fi

      # ── per-client MITM CA + runtime SNI minter material (§14.2/§14.6) ─
      # Each client mints+trusts its OWN root CA (full isolation). The CA is
      # ECDSA P-256 (EC signing is the per-handshake cost of the runtime
      # minter — RSA is the wrong default here) and carries a
      # subjectKeyIdentifier, which the minter copies BYTE-FOR-BYTE into each
      # leaf's authorityKeyIdentifier (the AKI footgun strict clients reject).
      # Alongside the CA we mint ONE reused EC leaf key per client: the minter
      # signs every per-SNI leaf with this single key (mitmproxy lesson — one
      # signature per host, never a keygen). Both the CA KEY and the leaf key
      # now live on the client box for runtime signing (per-client, never
      # leaves it — same isolation as before, online signer instead of
      # offline). Legacy pre-minted per-group leaves are off unless
      # --legacy-leaves (the minter replaces them).
      # --node=NAME narrows the loop to a single client (bare-metal box);
      # default is every constants.clientNames entry.
      if [ -n "$NODE" ]; then
        CLIENTS_LIST="$NODE"
      else
        CLIENTS_LIST="${clientLines}"
      fi
      while read -r client; do
        [ -z "$client" ] && continue
        CLDIR="$ROOT/$client"
        if [ -e "$CLDIR" ] && [ "$FORCE" -ne 1 ]; then
          echo "MITM CA for $client exists at $CLDIR — skipping (use --force)."
          continue
        fi
        rm -rf "$CLDIR"
        install -d -m 0700 "$CLDIR" "$CLDIR/ca" "$CLDIR/mitm"

        CA_KEY="$CLDIR/ca/$client-CA.key"
        CA_CRT="$CLDIR/ca/$client-CA.crt"
        # EC P-256 CA. subjectKeyIdentifier=hash is load-bearing: the runtime
        # minter reads this SKI and copies it verbatim into every leaf's AKI.
        openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY"
        chmod 600 "$CA_KEY"
        openssl req -x509 -new -nodes -key "$CA_KEY" \
          -sha256 -days 3650 -out "$CA_CRT" \
          -subj "/O=object-caching-experiments/CN=$client-MITM-CA" \
          -addext "basicConstraints=critical,CA:TRUE" \
          -addext "keyUsage=critical,keyCertSign,cRLSign" \
          -addext "subjectKeyIdentifier=hash"
        chmod 644 "$CA_CRT"

        # One reused EC leaf key per client — every per-SNI leaf the minter
        # forges is signed under this single key (loaded once at init_by_lua).
        LEAF_KEY="$CLDIR/mitm/leaf.key"
        openssl ecparam -name prime256v1 -genkey -noout -out "$LEAF_KEY"
        chmod 600 "$LEAF_KEY"

        if [ "$LEGACY_LEAVES" -ne 1 ]; then
          echo "  MITM CA + reused leaf key for $client (runtime SNI minter; pre-minted leaves skipped)"
        fi

        while [ "$LEGACY_LEAVES" -eq 1 ]; do read -r group fqdns || break
          [ -z "$group" ] && continue
          # a,b,c → DNS:a,DNS:b,DNS:c
          san="$(printf '%s' "$fqdns" | sed 's/[^,][^,]*/DNS:&/g')"
          LKEY="$CLDIR/mitm/$group.key"
          LCRT="$CLDIR/mitm/$group.crt"
          openssl genrsa -out "$LKEY" 2048
          chmod 600 "$LKEY"
          openssl req -new -key "$LKEY" -out "$CLDIR/mitm/$group.csr" \
            -subj "/O=object-caching-experiments/CN=$group"
          cat > "$CLDIR/mitm/$group.ext" <<EXT
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $san
EXT
          openssl x509 -req -in "$CLDIR/mitm/$group.csr" \
            -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
            -sha256 -days 825 -extfile "$CLDIR/mitm/$group.ext" \
            -out "$LCRT"
          chmod 644 "$LCRT"
          rm -f "$CLDIR/mitm/$group.csr" "$CLDIR/mitm/$group.ext"
        done <<'GROUPS'
${mitmGroupLines}
GROUPS
        echo "MITM CA + leaves for $client written to $CLDIR"
      done <<CLIENTS
$CLIENTS_LIST
CLIENTS

      # Make untracked files visible to the flake (pure-eval sees only
      # tracked/intent-to-add paths).
      git add --intent-to-add "$ROOT" 2>/dev/null || true

      echo "Done. Cache CA: $DIR ; per-client MITM CAs under $ROOT/<client>/"
    '';
  };
}
