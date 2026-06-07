# ─── nix/modules/docker-client.nix ─────────────────────────────────────
# Container runtime on the NixOS client, wired so UNMODIFIED pulls
# (`FROM gcr.io/foo/bar` stays exactly that) transparently route through the
# client nginx OCI frontend (:8088) → shared cache (focus-design §12).
#
# The mechanism is containerd's per-registry `certs.d/<reg>/hosts.toml`:
# containerd encodes the original registry in a `?ns=<reg>` param when it
# pulls through a mirror, which the client nginx routes on (§12.2). This is
# the PRIMARY path — it covers every registry, including non-docker.io.
# `nerdctl` reads /etc/containerd/certs.d by default, so it exercises it
# directly. Docker Engine is enabled too with a docker.io registry-mirror,
# but that only mirrors docker.io (the demoted path) — per-registry mirroring
# of arbitrary registries is a containerd feature, not a dockerd one.
#
# `server = <upstream>` in each hosts.toml is the FINAL fallback: if the
# cache is down containerd silently pulls direct, so a broken cache never
# breaks a pull — it just stops accelerating it (§12.1).
{ config, pkgs, lib, ... }:
let
  c        = import ../constants.nix;
  mirror   = ''http://127.0.0.1:${toString c.ports.clientOci}'';

  # certs.d/<registry>/hosts.toml for every Tier-1 upstream (§12.1) …
  hostsToml = url: ''
    server = "${url}"

    [host."${mirror}"]
      capabilities = ["pull", "resolve"]
  '';
  tierOne = lib.mapAttrs' (ns: u:
    lib.nameValuePair "containerd/certs.d/${ns}/hosts.toml" { text = hostsToml u.url; })
    c.upstreams;
in
{
  # ── containerd (primary; nerdctl uses its certs.d) ────────────────────
  virtualisation.containerd.enable = true;

  # ── Docker Engine (demoted docker.io mirror path, §12) ────────────────
  # containerd image store so unmodified `docker pull` uses the same OCI
  # plumbing; registry-mirrors accelerates docker.io only.
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      features.containerd-snapshotter = true;
      registry-mirrors = [ mirror ];
    };
  };

  environment.systemPackages = with pkgs; [ nerdctl ];

  # ── per-registry hosts.toml + the _default wildcard (§12.3) ───────────
  environment.etc = tierOne // {
    "containerd/certs.d/_default/hosts.toml".text = ''
      server = ""

      [host."${mirror}"]
        capabilities = ["pull", "resolve"]
    '';
  };
}
