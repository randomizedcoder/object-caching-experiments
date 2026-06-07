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
