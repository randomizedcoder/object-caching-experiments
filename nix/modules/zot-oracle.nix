# ─── nix/modules/zot-oracle.nix ────────────────────────────────────────
# The Zot verification oracle (focus-design §13.1). ONE Zot per Tier-1
# upstream (constants.upstreams), each an onDemand pull-through mirror with
# Prometheus metrics. Zot is the spec-correct ground truth we diff the
# hand-written nginx rules against (§7.4) — it is NEVER in the client→cache
# serving path; only `cache-diff-test` (§20) pulls against it out of band.
#
# nixpkgs has no `zot` package, so we vendor the official static release
# binary (the full build ships the sync + metrics extensions; the -minimal
# asset does NOT). Pinned by URL + sha256 → reproducible.
#
# Storage lives under /var/lib/cache/zot/<ns> on the data disk, owned by a
# dedicated `zot` user. Generated with mapAttrs' over upstreams so adding a
# registry to constants adds an oracle automatically (§7.2).
{ config, pkgs, lib, ... }:
let
  c = import ../constants.nix;

  zot = pkgs.stdenv.mkDerivation {
    pname   = "zot";
    version = "2.1.17";
    src = pkgs.fetchurl {
      url    = "https://github.com/project-zot/zot/releases/download/v2.1.17/zot-linux-amd64";
      sha256 = "0bb2dmqnvjibs7p3sm522myq4kvllq2nyq8rs1ilx9mshxmxvqpw";
    };
    dontUnpack        = true;
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs       = [ pkgs.stdenv.cc.cc.lib ];
    installPhase      = "install -Dm755 $src $out/bin/zot";
  };

  rootDir   = ns: "/var/lib/cache/zot/${ns}";
  zotConfig = ns: u: pkgs.writeText "zot-${ns}.json" (builtins.toJSON {
    storage = { rootDirectory = rootDir ns; gc = true; };
    http    = { address = "0.0.0.0"; port = toString u.zotPort; };
    log     = { level = "info"; };
    extensions = {
      sync = {
        enable = true;
        registries = [{
          urls      = [ u.url ];
          onDemand  = true;
          tlsVerify = true;
          content   = [{ prefix = "**"; }];
        }];
      };
      metrics = { enable = true; prometheus = { path = "/metrics"; }; };
    };
  });

  mkService = ns: u: lib.nameValuePair "zot-${ns}" {
    description = "Zot verification oracle for ${ns} (§13.1)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network.target" ];
    serviceConfig = {
      ExecStart      = "${zot}/bin/zot serve ${zotConfig ns u}";
      User           = "zot";
      Group          = "zot";
      Restart        = "on-failure";
      RestartSec     = 5;
      ReadWritePaths = [ "/var/lib/cache" ];
    };
  };
in
{
  users.users.zot = { isSystemUser = true; group = "zot"; };
  users.groups.zot = { };

  systemd.services = lib.mapAttrs' mkService c.upstreams;

  # One storage dir per oracle on the data disk, owned by the zot user.
  systemd.tmpfiles.rules =
    [ "d /var/lib/cache/zot 0750 zot zot - -" ]
    ++ lib.mapAttrsToList (ns: _: "d ${rootDir ns} 0750 zot zot - -") c.upstreams;
}
