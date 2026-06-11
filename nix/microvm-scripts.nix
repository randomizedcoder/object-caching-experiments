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

  sh = import ./lib/sh-helpers.nix { inherit (pkgs) lib; };

  # bash `case` arm: node) IP ;;
  ipCases = builtins.concatStringsSep "\n        " (builtins.map
    (n: "${n}) echo ${constants.network.ipv4.${n}} ;;") allNodes);

  hostnameCases = builtins.concatStringsSep "\n        " (builtins.map
    (n: "${n}) echo ${constants.getHostname n} ;;") allNodes);

  nodeListMsg = builtins.concatStringsSep " " allNodes;

  # ── Phase 2b: push the cache CA public cert to every client ───────────
  # Build-time activation already bakes the CA into each client image; this
  # runtime push lets you rotate the cache CA (cache-gen-ca --force) and
  # refresh clients WITHOUT a rebuild — scp the public cert into nginx's
  # proxy_ssl_trusted_certificate path and reload. §11.5. Defined in `let`
  # (not the attrset) so cache-start-all can call it after boot.
  distributeTrust = pkgs.writeShellApplication {
    name = "cache-distribute-trust";
    runtimeInputs = with pkgs; [ openssh coreutils ];
    text = ''
      set -euo pipefail
      unset SSH_AUTH_SOCK || true

      CA="''${PWD}/secrets/cache/ca/cache-CA.crt"
      if [[ ! -f "$CA" ]]; then
        echo "ERROR: $CA not found. Run 'nix run .#cache-gen-ca' first." >&2
        exit 1
      fi
      ${sh.requireKey}
      ${if knownHosts == null then sh.noKnownHosts else ''
      # shellcheck disable=SC2043  # list is Nix-generated; may be a single client
      for spec in ${builtins.concatStringsSep " " (builtins.map
        (n: "${n}:${constants.network.ipv4.${n}}") constants.clientNames)}; do
        node="''${spec%%:*}"; ip="''${spec##*:}"
        echo "[$node] pushing cache CA to root@$ip:/etc/nginx/cache-ca.crt"
        scp ${sh.sshOpts knownHosts} "$CA" "root@$ip:/etc/nginx/cache-ca.crt"
        ssh ${sh.sshOpts knownHosts} "root@$ip" 'systemctl reload nginx 2>/dev/null || true'
      done
      echo "Cache CA distributed to: ${builtins.concatStringsSep " " constants.clientNames}"
      ''}
    '';
  };
in
{
  inherit distributeTrust;

  startAll = pkgs.writeShellApplication {
    name = "cache-start-all";
    runtimeInputs = with pkgs; [ nix procps coreutils netcat-gnu ];
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
      echo "All VMs launched."

      # Best-effort: once the clients answer SSH, push the current cache CA
      # (idempotent; the image already bakes it, this refreshes after a
      # cache-gen-ca rotation). Never fails the boot.
      if [[ -f "''${PWD}/secrets/cache/ca/cache-CA.crt" ]]; then
        # shellcheck disable=SC2043  # list is Nix-generated; may be a single client
        for ip in ${builtins.concatStringsSep " " (builtins.map
          (n: constants.network.ipv4.${n}) constants.clientNames)}; do
          for _ in $(seq 1 30); do
            if nc -z -w1 "$ip" 22 2>/dev/null; then break; fi
            sleep 2
          done
        done
        echo "=== distributing cache CA to clients ==="
        ${distributeTrust}/bin/cache-distribute-trust || \
          echo "WARN: trust distribution failed (clients may still be booting)"
      fi
      echo "Check with: nix run .#cache-vm-ssh -- --node=cache0 -- uptime"
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

      ${sh.requireKey}

      ${if knownHosts == null then ''
      echo "ERROR: no known_hosts baked. Run 'nix run .#cache-gen-secrets' then re-evaluate." >&2
      exit 1
      '' else ''
      exec ssh ${sh.sshOpts knownHosts} "root@$ip" "''${ARGS[@]}"
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
        "docker.io|runpod/flash|latest|5050"
        "docker.io|runpod/flash|py3.12-latest|5050"
        "docker.io|runpod/pytorch|2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04|5050"
        "docker.io|runpod/pytorch|2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04|5050"
        "docker.io|runpod/pytorch|2.1.0-py3.10-cuda11.8.0-devel-ubuntu22.04|5050"
        "docker.io|runpod/comfyui|latest|5050"
        "docker.io|runpod/pytorch|1.0.2-cu1281-torch280-ubuntu2404|5050"
        "docker.io|vllm/vllm-openai|latest|5050"
        "docker.io|ollama/ollama|latest|5050"
      )

      # FUTURE — compiled-kernel GPU accelerators. NOT added to the corpus above
      # because they are not OCI images and the cache does not intercept their
      # origins today; they arrive over PyPI / GitHub-release / git, which is the
      # arbitrary-origin MITM design (NOT built) in
      # docs/container-mitm-arbitrary-origins.md ("Worked example: accelerator
      # fetch surfaces"). Anchored here so the test corpus to add lands beside the
      # OCI one once interception (or a PyPI/git mirror) exists:
      #   pypi.org    triton, accelerate           wheels  (files.pythonhosted.org)
      #   github.com  dao-ailab/flash-attention     release .whl (objects.githubusercontent.com)
      #   github.com  thu-ml/sageattention          git clone (smart-HTTP)

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

  # ── Phase 3: runtime SNI cert-minter correctness gate (§14.6) ─────────
  # Drives the client's :443 MITM frontend directly from the host (the
  # listener binds 0.0.0.0, so we connect to the client IP with an SNI and
  # the ssl_certificate_by_lua minter forges a leaf for that name). For each
  # probe we pull the served leaf with `openssl s_client -servername` and
  # assert the mitmproxy-derived correctness rules baked into the minter:
  #   1. chain validates leaf→client-MITM-CA under `openssl verify -x509_strict`
  #   2. Go crypto/x509 (strict: SAN-only, EKU serverAuth) accepts it
  #   3. distinct SNIs get distinct serials but SHARE the one reused leaf key
  #   4. a repeat SNI returns the SAME serial (two-tier cache HIT, not a re-mint)
  #   5. sibling sub-domains collapse onto ONE *.parent wildcard leaf (same serial)
  # Covers all three :443 server{} shapes: a model-store router (huggingface),
  # a mitmExtraHost (download.docker.com), and the minting catch-all (an
  # arbitrary origin the fleet never pre-declared).
  mitmTest = pkgs.writeShellApplication {
    name = "cache-mitm-test";
    runtimeInputs = with pkgs; [ openssl go coreutils gnugrep gnused gawk ];
    text = let
      clientName = builtins.head constants.clientNames;
      clientIp   = constants.network.ipv4.${clientName};
      port       = toString constants.ports.clientMitm;
      caRel      = "secrets/${clientName}/ca/${clientName}-CA.crt";
      # Strict acceptance check beyond `openssl verify`: Go's crypto/x509
      # enforces SAN-only identity (no CN fallback since 1.15) and the EKU,
      # which is exactly the strict-client class the minter targets. Stdlib
      # only → `go run` works offline with a scratch GOCACHE.
      goVerifier = pkgs.writeText "mitm-verify.go" ''
        package main

        import (
        	"crypto/x509"
        	"encoding/pem"
        	"fmt"
        	"os"
        )

        func fail(err error) {
        	fmt.Fprintln(os.Stderr, "go-verify:", err)
        	os.Exit(1)
        }

        func main() {
        	// args: caPath leafPath dnsName
        	caPEM, err := os.ReadFile(os.Args[1])
        	if err != nil {
        		fail(err)
        	}
        	leafPEM, err := os.ReadFile(os.Args[2])
        	if err != nil {
        		fail(err)
        	}
        	roots := x509.NewCertPool()
        	if !roots.AppendCertsFromPEM(caPEM) {
        		fail(fmt.Errorf("no CA in %s", os.Args[1]))
        	}
        	block, _ := pem.Decode(leafPEM)
        	if block == nil {
        		fail(fmt.Errorf("no PEM cert in %s", os.Args[2]))
        	}
        	leaf, err := x509.ParseCertificate(block.Bytes)
        	if err != nil {
        		fail(err)
        	}
        	if _, err := leaf.Verify(x509.VerifyOptions{
        		Roots:     roots,
        		DNSName:   os.Args[3],
        		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
        	}); err != nil {
        		fail(err)
        	}
        	fmt.Println("OK")
        }
      '';
    in ''
      set -uo pipefail

      IP="${clientIp}"
      PORT="${port}"
      CA="''${PWD}/${caRel}"
      if [[ ! -f "$CA" ]]; then
        echo "ERROR: $CA not found. Run 'nix run .#cache-gen-ca' (EC scheme) first." >&2
        exit 1
      fi

      WORK="$(mktemp -d)"
      trap 'rm -rf "$WORK"' EXIT
      # go run needs a writable cache + HOME; keep it fully offline/local.
      export HOME="$WORK" GOCACHE="$WORK/gocache" GO111MODULE=off GOTOOLCHAIN=local GOFLAGS=

      pass=0; fail=0
      note_pass() { echo "   PASS: $1"; pass=$((pass+1)); }
      note_fail() { echo "   FAIL: $1"; fail=$((fail+1)); }

      # Pull the served leaf for one SNI into $2 (PEM). The minter forges it in
      # the handshake; `openssl x509` reads the first (leaf) cert of the chain.
      fetch_leaf() {
        local sni="$1" out="$2"
        openssl s_client -connect "$IP:$PORT" -servername "$sni" -showcerts \
          </dev/null 2>/dev/null | openssl x509 -outform PEM >"$out" 2>/dev/null
        [[ -s "$out" ]]
      }

      x509_field() { openssl x509 -in "$1" -noout "$2" 2>/dev/null; }

      # Liveness: the frontend must answer a TLS handshake at all.
      if ! fetch_leaf "huggingface.co" "$WORK/probe.pem"; then
        echo "ERROR: no leaf served by $IP:$PORT — is ${clientName} booted and provisioned?" >&2
        echo "       (nix run .#cache-start-all, and regenerate EC secrets if needed)" >&2
        exit 1
      fi

      # Each SNI exercises a different :443 server{} shape.
      #   huggingface.co       → model-store router  (apex, never collapsed)
      #   download.docker.com  → mitmExtraHost block
      #   registry.example.org → minting catch-all   (arbitrary origin)
      for sni in huggingface.co download.docker.com registry.example.org; do
        echo "── $sni ──"
        leaf="$WORK/$sni.pem"
        if ! fetch_leaf "$sni" "$leaf"; then
          note_fail "$sni: no leaf served"; continue
        fi
        if openssl verify -x509_strict -CAfile "$CA" "$leaf" >/dev/null 2>&1; then
          note_pass "$sni: openssl -x509_strict chain OK"
        else
          note_fail "$sni: openssl -x509_strict rejected"
          openssl verify -x509_strict -CAfile "$CA" "$leaf" 2>&1 | sed 's/^/        /'
        fi
        if [[ "$(go run ${goVerifier} "$CA" "$leaf" "$sni" 2>"$WORK/go.err")" == "OK" ]]; then
          note_pass "$sni: Go crypto/x509 strict accepts"
        else
          note_fail "$sni: Go crypto/x509 strict rejected"
          sed 's/^/        /' "$WORK/go.err"
        fi
        san="$(x509_field "$leaf" -ext subjectAltName | grep -o 'DNS:[^,]*' | head -1)"
        echo "   SAN=''${san:-<none>} serial=$(x509_field "$leaf" -serial)"
      done

      echo "── shared leaf key + distinct serials ──"
      # The single reused EC leaf key means every forged leaf carries the SAME
      # public key; only the serial (random per mint) distinguishes them.
      hf_serial="$(x509_field "$WORK/huggingface.co.pem" -serial)"
      dk_serial="$(x509_field "$WORK/download.docker.com.pem" -serial)"
      hf_pub="$(x509_field "$WORK/huggingface.co.pem" -pubkey)"
      dk_pub="$(x509_field "$WORK/download.docker.com.pem" -pubkey)"
      if [[ "$hf_serial" != "$dk_serial" ]]; then
        note_pass "distinct SNIs → distinct serials ($hf_serial vs $dk_serial)"
      else
        note_fail "distinct SNIs collided on serial $hf_serial"
      fi
      if [[ -n "$hf_pub" && "$hf_pub" == "$dk_pub" ]]; then
        note_pass "leaves share the one reused leaf key"
      else
        note_fail "leaves do NOT share a public key"
      fi

      echo "── repeat SNI is a cache HIT (no re-mint) ──"
      # A second handshake for the same name must return the byte-identical
      # leaf (same serial) — proof the two-tier cache served it, not a re-sign.
      fetch_leaf "huggingface.co" "$WORK/hf2.pem" || true
      hf2_serial="$(x509_field "$WORK/hf2.pem" -serial)"
      if [[ -n "$hf_serial" && "$hf_serial" == "$hf2_serial" ]]; then
        note_pass "repeat huggingface.co reused cached leaf ($hf_serial)"
      else
        note_fail "repeat huggingface.co re-minted ($hf_serial → $hf2_serial)"
      fi

      echo "── sibling sub-domains collapse to one *.parent leaf ──"
      # cdn-lfs.* and cdn-lfs-us-1.* both fold onto *.huggingface.co, so they
      # share a cache key → one mint, one serial, a wildcard SAN.
      fetch_leaf "cdn-lfs.huggingface.co"      "$WORK/wc1.pem" || true
      fetch_leaf "cdn-lfs-us-1.huggingface.co" "$WORK/wc2.pem" || true
      wc1_serial="$(x509_field "$WORK/wc1.pem" -serial)"
      wc2_serial="$(x509_field "$WORK/wc2.pem" -serial)"
      wc_san="$(x509_field "$WORK/wc1.pem" -ext subjectAltName | grep -o 'DNS:[^,]*' | head -1)"
      if [[ "$wc_san" == "DNS:*.huggingface.co" ]]; then
        note_pass "sub-domain leaf SAN collapsed to $wc_san"
      else
        note_fail "sub-domain leaf SAN was ''${wc_san:-<none>}, expected DNS:*.huggingface.co"
      fi
      if [[ -n "$wc1_serial" && "$wc1_serial" == "$wc2_serial" ]]; then
        note_pass "siblings shared one wildcard leaf ($wc1_serial)"
      else
        note_fail "siblings minted separately ($wc1_serial vs $wc2_serial)"
      fi

      echo ""
      echo "=== mitm-test: $pass passed, $fail failed ==="
      [[ "$fail" -eq 0 ]]
    '';
  };

  # ── cache load-loop: soak driver to watch per-store cache hits (§21) ──
  # Drives a client over SSH on a cadence — pull → run → dwell → teardown
  # (rmi, which FORCES the next cycle's re-pull) → pause → repeat — so the
  # §19 per-store access logs (manifests.log / blobs.log / apt.log / …) show
  # MISS on cycle 1 and HIT on cycles 2+. Docker keeps image layers locally,
  # so the rmi each cycle is what sends the next pull back through nginx.
  # Reported counts are CUMULATIVE per store, so the HIT column climbing
  # cycle-over-cycle is the thing to watch. NB: this exercises the driving
  # client's LOCAL hot tier; to see SHARED-cache (cache-VM) hits, drive a
  # second client so its first pull misses locally but hits the shared tier.
  loadLoop = pkgs.writeShellApplication {
    name = "cache-load-loop";
    runtimeInputs = with pkgs; [ openssh coreutils ];
    # SC2016: the single-quoted blocks are remote commands run over SSH — their
    # $vars must expand on the target node, not locally. The expansion is intended.
    excludeShellChecks = [ "SC2016" ];
    text = ''
      set -euo pipefail
      unset SSH_AUTH_SOCK || true

      NODE="client0"
      RUN_SECS=300
      PAUSE_SECS=30
      CYCLES=0
      REPORT_NODES="client0,${builtins.concatStringsSep "," constants.cacheNames}"
      IMAGES="registry.k8s.io/pause:3.9 registry.k8s.io/coredns/coredns:v1.11.1 gcr.io/distroless/static:latest alpine:latest ghcr.io/astral-sh/uv:latest runpod/flash:latest runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04 runpod/comfyui:latest runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404 vllm/vllm-openai:latest ollama/ollama:latest"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --node=*)         NODE="''${1#*=}" ;;
          --run-secs=*)     RUN_SECS="''${1#*=}" ;;
          --pause-secs=*)   PAUSE_SECS="''${1#*=}" ;;
          --cycles=*)       CYCLES="''${1#*=}" ;;
          --report-nodes=*) REPORT_NODES="''${1#*=}" ;;
          --images=*)       IMAGES="''${1#*=}" ;;
          --) ;;
          *) echo "usage: cache-load-loop -- [--node=N] [--run-secs=S] [--pause-secs=S] [--cycles=N] [--images=\"a b c\"] [--report-nodes=a,b]" >&2; exit 2 ;;
        esac
        shift
      done

      ${sh.requireKey}
      ${if knownHosts == null then ''
      echo "ERROR: no known_hosts baked. Run 'nix run .#cache-gen-secrets' then re-evaluate." >&2
      exit 1
      '' else ""}
      node_ip() {
        case "$1" in
          ${ipCases}
          *) echo "" ;;
        esac
      }

      # Run a command on a node over SSH (same wiring as cache-vm-ssh).
      cssh() {
        local node="$1"; shift
        local ip; ip="$(node_ip "$node")"
        if [[ -z "$ip" ]]; then echo "ERROR: unknown node '$node'" >&2; return 2; fi
        ssh ${sh.sshOpts (if knownHosts == null then "/dev/null" else knownHosts)} "root@$ip" "$@"
      }

      # Per-store cumulative HIT/MISS tally over the §19 split access logs.
      # cs=[A-Z_]+ requires ≥1 uppercase letter, so the lua active-HC HEAD /v2/
      # 404s (logged as cs=-) are skipped — only HIT/MISS/EXPIRED/STALE/etc count.
      report_node() {
        local node="$1"
        echo "  [$node]"
        cssh "$node" '
          shopt -s nullglob
          for f in /var/log/nginx/*.log; do
            store="$(basename "$f" .log)"
            line="$(grep -hoE "cs=[A-Z_]+" "$f" 2>/dev/null | sort | uniq -c | tr "\n" " ")"
            [[ -n "$line" ]] && printf "    %-14s %s\n" "$store" "$line" || true
          done
        ' || true
      }

      read -r -a IMG_ARR <<< "$IMAGES"
      echo "cache-load-loop: node=$NODE run=''${RUN_SECS}s pause=''${PAUSE_SECS}s cycles=$CYCLES report=$REPORT_NODES"
      echo "images: ''${IMG_ARR[*]}"

      teardown() {
        echo "→ teardown (rm containers + rmi images)"
        cssh "$NODE" 'docker ps -aq --filter "name=cacheload_" | xargs -r docker rm -f >/dev/null 2>&1 || true' || true
        for img in "''${IMG_ARR[@]}"; do
          cssh "$NODE" "docker rmi -f '$img' >/dev/null 2>&1 || true" || true
        done
      }
      trap 'echo; echo "interrupted — cleaning up"; teardown; exit 0' INT TERM

      cycle=0
      while :; do
        cycle=$((cycle+1))
        echo ""
        echo "═══ cycle $cycle ═══"
        i=0
        for img in "''${IMG_ARR[@]}"; do
          i=$((i+1))
          echo "→ pull $img"
          cssh "$NODE" "docker pull '$img'" || echo "  (pull failed: $img)"
          cssh "$NODE" "docker run -d --rm --name cacheload_$i '$img' sleep $RUN_SECS >/dev/null 2>&1 || docker run -d --rm --name cacheload_$i '$img' >/dev/null 2>&1 || true" || true
        done

        echo "→ dwell ''${RUN_SECS}s"
        sleep "$RUN_SECS"
        teardown

        echo "→ cumulative cache status after cycle $cycle:"
        IFS=',' read -r -a RNODES <<< "$REPORT_NODES"
        for rn in "''${RNODES[@]}"; do report_node "$rn"; done

        if [[ "$CYCLES" -ne 0 && "$cycle" -ge "$CYCLES" ]]; then
          echo ""; echo "done ($cycle cycles)"; break
        fi
        echo "→ pause ''${PAUSE_SECS}s"
        sleep "$PAUSE_SECS"
      done
    '';
  };

  # ── Phase 2f: toggle the client's in-process active health-check (§11.3) ──
  # Writes/removes /run/nginx-hc-disabled on each client and reloads nginx;
  # the init_worker_by_lua_block kill-switch (nginx-client.nix) skips spawning
  # the active probers when the flag is present. The PASSIVE backstop (upstream
  # max_fails/fail_timeout) stays in force regardless — this only turns the
  # active lua probing on/off, e.g. to A/B its effect or quiesce probe noise.
  setHc = pkgs.writeShellApplication {
    name = "cache-set-hc";
    runtimeInputs = with pkgs; [ openssh coreutils ];
    text = ''
      set -euo pipefail
      unset SSH_AUTH_SOCK || true

      STATE=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --state=*) STATE="''${1#--state=}"; shift ;;
          --) shift ;;
          *) shift ;;
        esac
      done
      if [[ "$STATE" != "on" && "$STATE" != "off" ]]; then
        echo "usage: cache-set-hc -- --state=<on|off>" >&2
        exit 2
      fi

      ${sh.requireKey}
      ${if knownHosts == null then sh.noKnownHosts else ''
      if [[ "$STATE" == "off" ]]; then
        cmd='touch /run/nginx-hc-disabled && systemctl reload nginx'
      else
        cmd='rm -f /run/nginx-hc-disabled && systemctl reload nginx'
      fi
      # shellcheck disable=SC2043  # list is Nix-generated; may be a single client
      for ip in ${builtins.concatStringsSep " " (builtins.map
        (n: constants.network.ipv4.${n}) constants.clientNames)}; do
        echo "[$ip] active health-check → $STATE"
        ssh ${sh.sshOpts knownHosts} "root@$ip" "$cmd"
      done
      echo "Active health-check set $STATE on: ${builtins.concatStringsSep " " constants.clientNames}"
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
      # Data disk plus the per-workload ZFS pool volumes (§18.6). Deleting
      # the pool images forces zfs-cache-pools.nix to recreate empty pools
      # on next boot (the only way to truly reset dedup/usage state).
      wiped=0
      for img in \
        "''${PWD}/$hostname-data.img" \
        "''${PWD}/$hostname-manifests.img" \
        "''${PWD}/$hostname-blobs.img" \
        "''${PWD}/$hostname-http.img"; do
        if [[ -f "$img" ]]; then
          rm -f "$img"
          echo "Wiped $img"
          wiped=1
        fi
      done
      if [[ "$wiped" -eq 1 ]]; then
        echo "Next boot for $NODE is cold (data + ZFS pools recreated)"
      else
        echo "No images for $NODE (nothing to wipe)"
      fi
    '';
  };
}
