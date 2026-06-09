# ─── nix/nodes.nix ─────────────────────────────────────────────────────
# Node registry. Split so flake.nix can pick the right generator per role
# (mirrors ceph-on-k8s/nix/nodes.nix's definitions / clientDefinitions).
# Adding cache2 or client1 is a one-line edit here — the flake's mapAttrs'
# picks it up automatically.
{ constants }:
{
  cacheDefinitions = {
    cache0 = { role = "cache"; };
    cache1 = { role = "cache"; };
  };

  clientDefinitions = {
    client0 = { role = "client"; };
  };
}
