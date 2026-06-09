# ─── nix/constants.nix ─────────────────────────────────────────────────
# Single source of truth for the object-caching-experiments lab.
# Every IP, MAC, hostname, port, upstream, model-store FQDN and resource
# size is defined here exactly once. The same data later feeds the
# Ubuntu/Ansible path via `nix eval --json`, so both worlds derive from
# one place. Shape is specified by focus-design §10; this file *is* that
# block, plus a few helper functions the Nix modules read.
#
# Where this file and focus-design disagree, focus-design §8–§10 wins.
#
# ─── Structure ─────────────────────────────────────────────────────────
# The data is split by concern into ./constants/*.nix and merged back into
# ONE flat namespace here. Consumers still `import ./constants.nix` with no
# arguments and read `c.network.*`, `c.ports.*`, `c.modelStores.*`, … exactly
# as before — the split is invisible to them.
#
# Each topic file is a function `self: { … }`. `self` is the *complete*
# merged set (a lazy fixpoint), so a section may reference any sibling's
# values via `self.<key>` — replicating the old single-`rec` cross-references
# (e.g. security's `mitmCertGroups` reads `self.modelStores` from app.nix).
# Because the evaluated result is value-identical to the former flat `rec`,
# every derivation hash is unchanged by the split.
let
  self =
    (import ./constants/network.nix   self) //
    (import ./constants/images.nix    self) //
    (import ./constants/app.nix       self) //
    (import ./constants/security.nix  self) //
    (import ./constants/resources.nix self);
in
self
