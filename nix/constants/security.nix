# ─── nix/constants/security.nix ────────────────────────────────────────
# The two trust systems: the cache CA (client→cache hop TLS) and the
# per-client MITM CA cert groups. `mitmCertGroups`/`mitmAllFqdns` are
# derived from `self.modelStores` (../constants/app.nix), so this file
# takes the whole fixpoint as `self`.
# Merged into the flat `constants` namespace by ../constants.nix.
self: {
  # ─── TLS on the client→cache hop (focus-design §11.5) ──────────────
  # A dedicated *cache CA* signs ONE shared cache server cert deployed to
  # BOTH (interchangeable) cache VMs; every client trusts the cache CA and
  # verifies (proxy_ssl_verify on). This is a SEPARATE trust system from
  # the per-client MITM CA (§14.2) — the cache CA only authenticates the
  # cache layer, it never forges origins.
  cacheTls = {
    enable     = true;
    serverName = "caches.cache.lab";                       # shared SAN; proxy_ssl_name
    caCert     = "secrets/cache/ca/cache-CA.crt";          # public; SSH-copied to every client
    serverCert = "secrets/cache/server/cache-server.crt";  # same cert on both cache VMs
    serverKey  = "secrets/cache/server/cache-server.key";  # cache VMs only; never leaves them
    # SAN also covers both cache IPs (network.ipv4.cache0/cache1).
  };

  # Everything we MITM = model-store fqdns + HTTPS third-party repos.
  mitmExtraHosts = [ "download.docker.com" ];

  # ─── MITM cert groups (focus-design §14.2/§14.3) ───────────────────
  # Single source of truth for the per-client MITM leaf certs: one cert
  # per SNI server{} unit. Each model store groups ALL its fqdns under
  # one cert (server_name lists them together, §14.3); each mitmExtraHost
  # is its own one-fqdn cert. Read by:
  #   - secrets-gen.nix  (mints secrets/<client>/mitm/<name>.{crt,key})
  #   - modules/mitm.nix (installs leaves to /etc/nginx/mitm + /etc/hosts)
  #   - modules/nginx-client.nix (one :443 server{} per group)
  mitmCertGroups =
    (map (name: { inherit name; fqdns = self.modelStores.${name}.fqdns; })
         (builtins.attrNames self.modelStores))
    ++ (map (h: { name = h; fqdns = [ h ]; }) self.mitmExtraHosts);

  # Flat list of every MITM'd FQDN → 127.0.0.1 /etc/hosts redirect.
  mitmAllFqdns = builtins.concatLists (map (g: g.fqdns) self.mitmCertGroups);

  # ─── Runtime SNI cert minter (focus-design §14.6) ──────────────────
  # Tunables for the on-the-fly leaf minter (modules/mitm-minter.lua, wired
  # in modules/nginx-client.nix). Replaces the pre-minted per-group leaves:
  # nginx mints+signs a leaf per SNI under this client's MITM CA, caches it
  # two-tier (per-worker lrucache of parsed cdata + a shared_dict of PEM), and
  # guards the cold-host stampede with a per-host lock. See §14.6 for the
  # mitmproxy-derived correctness rules baked into the Lua.
  mitmMinter = {
    # Fixed on-box paths the activation installs the signing material to
    # (nginx-owned; CA key + reused leaf key, §14.2). The minter reads these
    # once at init_by_lua and reuses them for every signature.
    caCert  = "/etc/nginx/mitm/ca.crt";
    caKey   = "/etc/nginx/mitm/ca.key";
    leafKey = "/etc/nginx/mitm/leaf.key";

    # Shared dicts. certCacheSize is the leaf-PEM cache cap (LRU-evicts under
    # an SNI flood → set staleness degrades hit-rate, never correctness);
    # lruSize is the per-worker parsed-cdata cap (what the handshake consumes,
    # no re-parse); locks/stats are small bookkeeping dicts.
    certCacheSize = "16m";    # lua_shared_dict mitm_certs  (PEM bytes by host)
    lockSize      = "1m";     # lua_shared_dict mitm_locks  (lua-resty-lock)
    statsSize     = "64k";    # lua_shared_dict mitm_stats  (mint/error counters)
    lruSize       = 512;      # per-worker parsed-cdata entries

    # Leaf shape. Short TTL (we re-mint freely); notBefore back-dated to
    # tolerate client clock skew (mitmproxy CERT_VALIDITY_OFFSET).
    leafTtlSeconds  = 7 * 24 * 3600;   # 7d
    backdateSeconds = 2 * 24 * 3600;   # 2d

    # Collapse a sub-domain SNI onto a single-level wildcard leaf
    # (cdn-lfs.huggingface.co → *.huggingface.co) so an SNI flood across
    # sibling sub-domains still mints once. Apex names and IP literals are
    # never collapsed.
    wildcardCollapse = true;
  };
}
