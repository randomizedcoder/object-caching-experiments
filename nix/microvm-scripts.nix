# ─── nix/microvm-scripts.nix ───────────────────────────────────────────
# VM lifecycle apps (focus-design §20, nix-design §10). Sister-repo
# pattern: build the package → run microvm-run in the background → pgrep
# to check/stop.
#
# Phase 1: start-all / vm-ssh / vm-stop / vm-wipe. cache-distribute-trust
# (called from start-all) and the diff/render/corpus/obs apps land in
# Phase 2/3.
{ pkgs, constants, secrets }:
let
  # Boot order: caches first, then the client (the client's nginx upstreams
  # point at the caches).
  bootOrder = constants.cacheNames ++ constants.clientNames;   # [cache0 cache1 client0]
  allNodes  = constants.clientNames ++ constants.cacheNames;

  knownHosts = secrets.knownHostsPath;   # path | null

  # bash `case` arm: node) IP ;;
  ipCases = builtins.concatStringsSep "\n        " (builtins.map
    (n: "${n}) echo ${constants.network.ipv4.${n}} ;;") allNodes);

  hostnameCases = builtins.concatStringsSep "\n        " (builtins.map
    (n: "${n}) echo ${constants.getHostname n} ;;") allNodes);

  nodeListMsg = builtins.concatStringsSep " " allNodes;
in
{
  startAll = pkgs.writeShellApplication {
    name = "cache-start-all";
    runtimeInputs = with pkgs; [ nix procps coreutils ];
    text = ''
      set -euo pipefail
      echo "=== Booting cache lab (caches first, then client) ==="
      ${builtins.concatStringsSep "\n" (builtins.map (n: ''
      hostname_${n}="${constants.getHostname n}"
      result_${n}="result-cache-${n}"
      if pgrep -f "process=$hostname_${n}" >/dev/null 2>&1; then
        echo "[${n}] already running (process=$hostname_${n}) — skipping"
      else
        echo "[${n}] building .#cache-microvm-${n} ..."
        rm -f "$result_${n}"
        nix build ".#cache-microvm-${n}" -o "$result_${n}"
        echo "[${n}] starting microvm-run in background ..."
        "$result_${n}/bin/microvm-run" &
        sleep 2
      fi
      '') bootOrder)}
      echo ""
      echo "All VMs launched. Check with: nix run .#cache-vm-ssh -- --node=cache0 -- uptime"
    '';
  };

  ssh = pkgs.writeShellApplication {
    name = "cache-vm-ssh";
    runtimeInputs = with pkgs; [ openssh coreutils ];
    text = ''
      set -euo pipefail
      unset SSH_AUTH_SOCK || true

      NODE=""
      ARGS=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --node=*) NODE="''${1#--node=}"; shift ;;
          --) shift; ARGS=("$@"); break ;;
          *) ARGS+=("$1"); shift ;;
        esac
      done

      if [[ -z "$NODE" ]]; then
        echo "usage: cache-vm-ssh -- --node=<${nodeListMsg}> [-- <command>]" >&2
        exit 2
      fi

      ip="$(case "$NODE" in
        ${ipCases}
        *) echo "" ;;
      esac)"
      if [[ -z "$ip" ]]; then
        echo "ERROR: unknown node '$NODE' (expected one of: ${nodeListMsg})" >&2
        exit 2
      fi

      KEY="''${PWD}/secrets/ssh-ed25519"
      if [[ ! -f "$KEY" ]]; then
        echo "ERROR: $KEY not found. Run 'nix run .#cache-gen-secrets' first." >&2
        exit 1
      fi

      ${if knownHosts == null then ''
      echo "ERROR: no known_hosts baked. Run 'nix run .#cache-gen-secrets' then re-evaluate." >&2
      exit 1
      '' else ''
      exec ssh \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile=${knownHosts} \
        -o IdentitiesOnly=yes \
        -i "$KEY" \
        "root@$ip" "''${ARGS[@]}"
      ''}
    '';
  };

  stop = pkgs.writeShellApplication {
    name = "cache-vm-stop";
    runtimeInputs = with pkgs; [ procps coreutils ];
    text = ''
      set -euo pipefail
      NODE=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --node=*) NODE="''${1#--node=}"; shift ;;
          --) shift ;;
          *) shift ;;
        esac
      done
      if [[ -z "$NODE" ]]; then
        echo "usage: cache-vm-stop -- --node=<${nodeListMsg}>" >&2
        exit 2
      fi
      hostname="$(case "$NODE" in
        ${hostnameCases}
        *) echo "" ;;
      esac)"
      if [[ -z "$hostname" ]]; then
        echo "ERROR: unknown node '$NODE'" >&2
        exit 2
      fi
      if pgrep -f "process=$hostname" >/dev/null 2>&1; then
        pkill -f "process=$hostname" || true
        echo "Stopped $NODE ($hostname)"
      else
        echo "$NODE ($hostname) not running"
      fi
    '';
  };

  # ── Phase 2b: push the cache CA public cert to every client ───────────
  # Build-time activation already bakes the CA into each client image; this
  # runtime push lets you rotate the cache CA (cache-gen-ca --force) and
  # refresh clients WITHOUT a rebuild — scp the public cert into nginx's
  # proxy_ssl_trusted_certificate path and reload. §11.5.
  distributeTrust = pkgs.writeShellApplication {
    name = "cache-distribute-trust";
    runtimeInputs = with pkgs; [ openssh coreutils ];
    text = ''
      set -euo pipefail
      unset SSH_AUTH_SOCK || true

      CA="''${PWD}/secrets/cache/ca/cache-CA.crt"
      KEY="''${PWD}/secrets/ssh-ed25519"
      if [[ ! -f "$CA" ]]; then
        echo "ERROR: $CA not found. Run 'nix run .#cache-gen-ca' first." >&2
        exit 1
      fi
      if [[ ! -f "$KEY" ]]; then
        echo "ERROR: $KEY not found. Run 'nix run .#cache-gen-secrets' first." >&2
        exit 1
      fi
      ${if knownHosts == null then ''
      echo "ERROR: no known_hosts baked. Run 'nix run .#cache-gen-secrets' first." >&2
      exit 1
      '' else ''
      for spec in ${builtins.concatStringsSep " " (builtins.map
        (n: "${n}:${constants.network.ipv4.${n}}") constants.clientNames)}; do
        node="''${spec%%:*}"; ip="''${spec##*:}"
        echo "[$node] pushing cache CA to root@$ip:/etc/nginx/cache-ca.crt"
        scp -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile=${knownHosts} \
            -o IdentitiesOnly=yes -i "$KEY" \
            "$CA" "root@$ip:/etc/nginx/cache-ca.crt"
        ssh -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile=${knownHosts} \
            -o IdentitiesOnly=yes -i "$KEY" \
            "root@$ip" 'systemctl reload nginx 2>/dev/null || true'
      done
      echo "Cache CA distributed to: ${builtins.concatStringsSep " " constants.clientNames}"
      ''}
    '';
  };

  # ── Phase 2e: three-way correctness gate (§7.4, §20.5) ────────────────
  # Pull a fixed corpus three ways and compare the manifest content digest:
  #   • upstream   → the real origin registry  (ground truth for a transparent cache)
  #   • nginx      → cache VM :8085 (TLS, ?ns=<reg>)  — the hand-written rules
  #   • Zot oracle → cache VM :<zotPort>              — spec cross-check
  #
  # GATE: nginx MUST byte-match upstream (same Docker-Content-Digest). That is
  # the transparency property — the cache serves exactly what the origin serves.
  # Zot agreement is reported but NOT a gate: Zot re-serialises docker-media
  # manifests to OCI on ingest, so its digest only matches for OCI-native
  # upstreams. A "zot diverges" line on a docker-media image is EXPECTED, not a
  # bug — nginx (pass-through) is the more faithful cache there.
  diffTest = pkgs.writeShellApplication {
    name = "cache-diff-test";
    runtimeInputs = with pkgs; [ curl coreutils gnugrep gnused gawk jq ];
    text = let
      cacheIp    = constants.network.ipv4.${builtins.head constants.cacheNames};
      serverName = constants.cacheTls.serverName;
      nginxPort  = toString constants.ports.nginxWildcard;
      upstreamCases = builtins.concatStringsSep "\n          " (pkgs.lib.mapAttrsToList
        (ns: u: "${ns}) echo ${u.url} ;;") constants.upstreams);
      accept = builtins.concatStringsSep "," [
        "application/vnd.oci.image.index.v1+json"
        "application/vnd.oci.image.manifest.v1+json"
        "application/vnd.docker.distribution.manifest.list.v2+json"
        "application/vnd.docker.distribution.manifest.v2+json"
      ];
    in ''
      set -uo pipefail

      CA="''${PWD}/secrets/cache/ca/cache-CA.crt"
      if [[ ! -f "$CA" ]]; then
        echo "ERROR: $CA not found. Run 'nix run .#cache-gen-ca' first." >&2
        exit 1
      fi

      # reg|repo|tag|zotPort
      corpus=(
        "registry.k8s.io|pause|3.9|5054"
        "registry.k8s.io|coredns/coredns|v1.11.1|5054"
        "gcr.io|distroless/static|latest|5051"
      )

      # ns → real upstream base URL (from constants.upstreams).
      upstream_url() {
        case "$1" in
          ${upstreamCases}
          *) echo "" ;;
        esac
      }

      # Parse "<status> <digest>" out of an HTTP header dump on stdin.
      parse_hdrs() {
        awk 'BEGIN{IGNORECASE=1; s="000"; d="-"}
             /^HTTP\//{s=$2}
             /^Docker-Content-Digest:/{d=$2; sub(/\r/,"",d)}
             END{print s, d}'
      }

      # Probe a cache backend. $1=url $2..=extra curl args → "<status> <digest>".
      probe() {
        local url="$1"; shift
        curl -sS -o /dev/null -D - -H "Accept: ${accept}" "$@" "$url" 2>/dev/null | parse_hdrs
      }

      # Probe the real origin, following a Bearer-token challenge if issued.
      probe_upstream() {
        local reg="$1" repo="$2" tag="$3" base url hdrs status wa realm svc scope tok
        base="$(upstream_url "$reg")"
        [[ -z "$base" ]] && { echo "000 -"; return; }
        url="$base/v2/$repo/manifests/$tag"
        hdrs="$(curl -sSL -o /dev/null -D - -H "Accept: ${accept}" "$url" 2>/dev/null)"
        status="$(awk 'BEGIN{IGNORECASE=1}/^HTTP\//{s=$2}END{print s}' <<<"$hdrs")"
        if [[ "$status" == "401" ]]; then
          wa="$(grep -i '^Www-Authenticate:' <<<"$hdrs" | head -1)"
          realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p'   <<<"$wa")"
          svc="$(sed -n 's/.*service="\([^"]*\)".*/\1/p'    <<<"$wa")"
          scope="$(sed -n 's/.*scope="\([^"]*\)".*/\1/p'    <<<"$wa")"
          tok="$(curl -sS "$realm?service=$svc&scope=$scope" 2>/dev/null \
                 | jq -r '.token // .access_token // empty')"
          hdrs="$(curl -sSL -o /dev/null -D - -H "Accept: ${accept}" \
                  -H "Authorization: Bearer $tok" "$url" 2>/dev/null)"
        fi
        parse_hdrs <<<"$hdrs"
      }

      pass=0; fail=0
      for entry in "''${corpus[@]}"; do
        IFS='|' read -r reg repo tag zotPort <<<"$entry"
        echo "── ''${reg}/''${repo}:''${tag} ──"

        read -r us ud < <(probe_upstream "''${reg}" "''${repo}" "''${tag}")
        read -r ns nd < <(probe \
          "https://${serverName}:${nginxPort}/v2/''${repo}/manifests/''${tag}?ns=''${reg}" \
          --cacert "$CA" --resolve "${serverName}:${nginxPort}:${cacheIp}")
        read -r zs zd < <(probe \
          "http://${cacheIp}:''${zotPort}/v2/''${repo}/manifests/''${tag}")

        echo "   upstream: status=$us digest=$ud"
        echo "   nginx   : status=$ns digest=$nd"
        echo "   zot     : status=$zs digest=$zd"

        if [[ "$us" == "200" && "$ns" == "200" && "$ud" == "$nd" && "$ud" != "-" ]]; then
          echo "   PASS (nginx matches upstream)"; pass=$((pass+1))
        else
          echo "   FAIL (nginx diverges from upstream)"; fail=$((fail+1))
        fi
        if [[ "$zd" == "$ud" && "$zd" != "-" ]]; then
          echo "   note: zot agrees"
        else
          echo "   note: zot diverges (OCI re-serialisation — expected for docker-media upstreams)"
        fi
      done

      echo ""
      echo "=== diff-test: $pass passed, $fail failed (gate = nginx vs upstream) ==="
      [[ "$fail" -eq 0 ]]
    '';
  };

  wipe = pkgs.writeShellApplication {
    name = "cache-vm-wipe";
    runtimeInputs = with pkgs; [ procps coreutils ];
    text = ''
      set -euo pipefail
      NODE=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --node=*) NODE="''${1#--node=}"; shift ;;
          --) shift ;;
          *) shift ;;
        esac
      done
      if [[ -z "$NODE" ]]; then
        echo "usage: cache-vm-wipe -- --node=<${nodeListMsg}>" >&2
        exit 2
      fi
      hostname="$(case "$NODE" in
        ${hostnameCases}
        *) echo "" ;;
      esac)"
      if [[ -z "$hostname" ]]; then
        echo "ERROR: unknown node '$NODE'" >&2
        exit 2
      fi
      # stop first
      if pgrep -f "process=$hostname" >/dev/null 2>&1; then
        pkill -f "process=$hostname" || true
        sleep 1
      fi
      img="''${PWD}/$hostname-data.img"
      if [[ -f "$img" ]]; then
        rm -f "$img"
        echo "Wiped $img (next boot is cold)"
      else
        echo "No data image for $NODE ($img)"
      fi
    '';
  };
}
