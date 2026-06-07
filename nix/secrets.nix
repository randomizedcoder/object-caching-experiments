# ─── nix/secrets.nix ───────────────────────────────────────────────────
# Null-able reads of ./secrets/. The flake still evaluates when ./secrets/
# is absent (every field returns null); the build-time activation scripts
# fail loudly at boot instead ("run nix run .#cache-gen-secrets first").
# Mirrors ceph-on-k8s/nix/secrets.nix.
#
# Phase 1 implements the SSH fields (hostKeyPath / sshPubKey / knownHostsPath).
# cacheServer / cacheCaCert / clientMitm are null stubs filled by Phase 2/3.
{ pkgs, lib }:
let
  constants  = import ./constants.nix;
  secretsDir = ../secrets;
  hasSecrets = builtins.pathExists secretsDir;

  readTrimmed = path:
    if builtins.pathExists path then lib.trim (builtins.readFile path) else null;
in
if !hasSecrets then {
  # Graceful all-null shape so `nix flake check` works on a fresh checkout.
  hostKeyPath    = _nodeName: null;
  sshPubKey      = null;
  knownHostsPath = null;
  cacheServer    = null;
  cacheCaCert    = null;
  clientMitm     = _nodeName: null;
} else {
  # SSH host private key for a node, or null if not generated yet. A
  # FUNCTION (the flake calls `secrets.hostKeyPath nodeName`).
  hostKeyPath = nodeName:
    let f = secretsDir + "/host-keys/${constants.getHostname nodeName}";
    in if builtins.pathExists f then f else null;

  # User public key authorized on every VM.
  sshPubKey =
    let f = secretsDir + "/ssh-ed25519.pub";
    in readTrimmed f;

  # Baked known_hosts so the lifecycle scripts can use StrictHostKeyChecking=yes.
  knownHostsPath =
    let f = secretsDir + "/known_hosts";
    in if builtins.pathExists f then f else null;

  # ── Phase 2b: cache CA + shared server cert (§11.5) ─────────────────
  # Shared server cert (same on both cache VMs); null until cache-gen-ca runs.
  cacheServer =
    let
      crt = secretsDir + "/cache/server/cache-server.crt";
      key = secretsDir + "/cache/server/cache-server.key";
    in if builtins.pathExists crt && builtins.pathExists key
       then { inherit crt key; } else null;

  # Cache CA public cert — baked into every client's proxy_ssl_trusted_certificate.
  cacheCaCert =
    let f = secretsDir + "/cache/ca/cache-CA.crt";
    in if builtins.pathExists f then f else null;

  # ── Phase 3 stub (null until that phase mints the per-client MITM CA) ─
  clientMitm  = _nodeName: null;   # { ca; leaves; } per-client MITM (§14)
}
