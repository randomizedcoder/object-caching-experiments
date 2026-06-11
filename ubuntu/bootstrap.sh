#!/usr/bin/env bash
# ─── ubuntu/bootstrap.sh ────────────────────────────────────────────────
# Turn a stock Ubuntu box into a cache client, on the box itself, from a
# copy of this repo (rsync'd here by `nix run .#cache-ubuntu-deploy`, or by
# hand). Idempotent — safe to re-run; a second run converges to a no-op.
#
# What it does, in order:
#   1. ensure Nix is installed with flakes enabled
#   2. ensure Docker is installed (system-manager drops daemon.json/certs.d
#      but never installs the engine itself — no virtualisation.* on non-NixOS)
#   3. assert the PUBLIC cache CA cert is present (deploy copies only this)
#   4. mint THIS box's MITM tree locally (cache-gen-ca --mitm-only --node)
#   5. apply the client config: system-manager switch --flake .#ubuntu-client
#      (the non-NixOS analogue of `nixos-rebuild switch` — NOT `nix build`,
#      which only realizes a store path and writes nothing to /etc)
#   6. restart Docker so it re-reads the freshly written daemon.json
#
# Run from the repo root on the box:  sudo bash ubuntu/bootstrap.sh
set -euo pipefail

# The MITM secrets slot this box reuses. systemConfigs.ubuntu-client reads
# `clientMitm "client0"` (flake.nix), so a fresh client0 MITM tree minted
# here drops straight into the slot the config already consumes.
NODE="client0"

# Resolve the repo root (this script lives in <root>/ubuntu/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Make a Determinate-installed nix visible even in a fresh non-login shell.
if ! command -v nix >/dev/null 2>&1; then
  for p in /nix/var/nix/profiles/default/bin \
           "${HOME}/.nix-profile/bin"; do
    [ -d "$p" ] && PATH="$p:$PATH"
  done
  export PATH
fi

echo "═══ cache client bootstrap (repo: $REPO_ROOT, node: $NODE) ═══"

# ── 1. Nix + flakes ─────────────────────────────────────────────────────
if ! command -v nix >/dev/null 2>&1; then
  echo "→ installing Determinate Nix (flakes enabled)"
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install linux --no-confirm \
        --extra-conf 'experimental-features = nix-command flakes'
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
  export PATH="/nix/var/nix/profiles/default/bin:$PATH"
else
  echo "→ nix present ($(nix --version))"
  # Ensure flakes are on even if Nix predates this script.
  if ! nix --extra-experimental-features 'nix-command flakes' \
        flake metadata --no-write-lock-file . >/dev/null 2>&1; then
    echo "  (note: enabling nix-command + flakes for this run via --extra-experimental-features)"
  fi
fi
# Use this on every nix invocation so we don't depend on system nix.conf.
# An ARRAY, not a string: --extra-experimental-features takes ONE argument
# ("nix-command flakes"), which word-splitting a string would break apart.
NIX=(nix --extra-experimental-features "nix-command flakes")

# ── 2. Docker ───────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  echo "→ installing Docker (get.docker.com)"
  curl -fsSL https://get.docker.com | sh
else
  echo "→ docker present ($(docker --version))"
fi

# ── 3. PUBLIC cache CA cert must already be here ────────────────────────
CACHE_CA="secrets/cache/ca/cache-CA.crt"
if [ ! -f "$CACHE_CA" ]; then
  echo "ERROR: $CACHE_CA missing." >&2
  echo "       Copy the PUBLIC cache CA cert from the lab into place, e.g.:" >&2
  echo "         scp lab:object-caching-experiments/$CACHE_CA $REPO_ROOT/$CACHE_CA" >&2
  echo "       (public cert only — the cache CA private key never leaves the lab)." >&2
  echo "       cache-ubuntu-deploy copies this for you automatically." >&2
  exit 1
fi
echo "→ public cache CA present: $CACHE_CA"

# ── 4. mint this box's MITM tree (no cache CA key created) ───────────────
echo "→ minting MITM secrets for $NODE (--mitm-only)"
"${NIX[@]}" run ".#cache-gen-ca" -- --mitm-only --node="$NODE"

# ── 5. apply the client config ──────────────────────────────────────────
# system-manager switch writes /etc, installs systemd units, trusts the CA.
# Needs root. `.#ubuntu-client` is evaluated from this dir (a non-git copy
# exposes all files; cache-gen-ca's intent-to-add covers the git-repo case).
# Sweep stray sockets/fifos first: a non-git flake dir copies ALL files to the
# store and nix errors on a socket (the lab's cache-*.sock VM control sockets).
find "$REPO_ROOT" -xdev \( -type s -o -type p \) -delete 2>/dev/null || true
echo "→ applying system-manager switch --flake .#ubuntu-client"
if [ "$(id -u)" -eq 0 ]; then
  "${NIX[@]}" run github:numtide/system-manager -- switch --flake .#ubuntu-client
else
  # sudo keeps the cwd ($REPO_ROOT), so .#ubuntu-client still resolves here.
  sudo env "PATH=$PATH" "${NIX[@]}" run github:numtide/system-manager -- \
    switch --flake .#ubuntu-client
fi

# ── 6. restart Docker so it re-reads the new daemon.json ────────────────
echo "→ restarting docker (re-read daemon.json: containerd-snapshotter + mirror)"
if [ "$(id -u)" -eq 0 ]; then
  systemctl restart docker || true
else
  sudo systemctl restart docker || true
fi

echo
echo "═══ done ═══"
echo "verify:"
echo "  cat /etc/cache-ubuntu-client-stub"
echo "  systemctl is-active nginx node-exporter cache-trust"
echo "  cat /etc/docker/daemon.json"
echo "  ls /etc/containerd/certs.d/docker.io/hosts.toml"
echo "  docker pull alpine:latest   # should route through local nginx"
