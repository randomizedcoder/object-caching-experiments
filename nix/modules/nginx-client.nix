# ─── nix/modules/nginx-client.nix ──────────────────────────────────────
# The NixOS client's two-tier serving path (focus-design §11). OpenResty
# fronts containerd (OCI :8088) and apt (:8090): it tries a small LOCAL hot
# cache first, and on a miss consistent-hashes onto the shared cache VMs
# over a TLS hop verified against the cache CA (§11.5).
#
# Two tiers, two upstreams:
#   - oci  → shared_caches      (cache VMs' :8085, wildcard OCI)
#   - apt  → shared_caches_apt  (cache VMs' :8086)
# Both verify the cache server cert against /etc/nginx/cache-ca.crt (baked by
# the client generator's cache-ca activation) with proxy_ssl_verify on.
#
# Active HA is in-process: lua-resty-upstream-healthcheck (bundled with
# OpenResty) probes each peer over TLS and marks dead peers down so ketama
# skips them BEFORE a pull selects one — no daemon, no reload (§11.3).
#
# Hot-cache storage lives on /var/lib (the data disk), like the cache VMs,
# so the small writable root isn't filled by cached blobs.
{ config, pkgs, lib, ... }:
let
  c  = import ../constants.nix;
  hc = c.healthcheck;

  # Cache VM peers for each upstream, driven from constants (no hardcoding).
  ociServers = lib.concatStringsSep "\n      " (map (n:
    "server ${c.network.ipv4.${n}}:${toString c.ports.nginxWildcard} max_fails=1 fail_timeout=10s;")
    c.cacheNames);
  aptServers = lib.concatStringsSep "\n      " (map (n:
    "server ${c.network.ipv4.${n}}:${toString c.ports.nginxApt} max_fails=1 fail_timeout=10s;")
    c.cacheNames);

  validStatuses = lib.concatStringsSep ", " (map toString hc.validStatuses);
in
{
  services.nginx = {
    enable  = true;
    package = pkgs.openresty;

    # proxy_ssl_trusted_certificate points at a RUNTIME path (/etc/nginx/
    # cache-ca.crt, installed at VM activation), which doesn't exist in the
    # Nix build sandbox — so `nginx -t` would fail at build time. Disable the
    # build-time validator (same rationale as nginx-cache.nix) and validate
    # by booting + curling instead.
    validateConfigFile = false;

    appendHttpConfig = ''
      # One dedicated User-Agent on every upstream request (§11.1).
      proxy_set_header User-Agent "${c.userAgent}";

      # ── local hot tiers (small on purpose, §5 Req#3) ──────────────────
      proxy_cache_path /var/lib/cache/nginx/oci levels=1:2 keys_zone=oci_hot:64m
                       max_size=8g inactive=24h use_temp_path=off;
      proxy_cache_path /var/lib/cache/nginx/apt levels=1:2 keys_zone=apt_hot:16m
                       max_size=2g inactive=24h use_temp_path=off;

      # digest (cross-repo blob dedup) + ns= extraction.
      map $uri    $oci_digest { ~/blobs/(?<d>sha256:[0-9a-f]+)$ $d; default ""; }
      map $arg_ns $oci_ns     { "" "_default"; default $arg_ns; }

      # ── TLS to the cache layer, verified against the cache CA (§11.5) ──
      # Set once at http{} scope; inherited by every proxy_pass below.
      proxy_ssl_trusted_certificate /etc/nginx/cache-ca.crt;
      proxy_ssl_verify        on;
      proxy_ssl_verify_depth  2;
      proxy_ssl_name          ${c.cacheTls.serverName};
      proxy_ssl_server_name   on;
      proxy_ssl_session_reuse on;

      # ── consistent-hash upstreams (ketama; key set per-location) ──────
      upstream shared_caches {
        hash $cache_key consistent;
        ${ociServers}
        keepalive 32;
      }
      upstream shared_caches_apt {
        hash $cache_key consistent;
        ${aptServers}
        keepalive 16;
      }

      # ── in-process active health-check (§11.3) ────────────────────────
      lua_package_path ";;";
      lua_shared_dict healthcheck 1m;
      init_worker_by_lua_block {
        -- Runtime kill-switch (§11.3): `cache-set-hc --state=off` touches this
        -- flag and reloads; init_worker re-runs in the new workers and skips
        -- spawning the active probers. The PASSIVE backstop (upstream
        -- max_fails/fail_timeout) stays in force either way.
        local off = io.open("/run/nginx-hc-disabled", "r")
        if off then off:close() return end
        local hc = require "resty.upstream.healthcheck"
        -- ssl_verify=false: the probe only checks LIVENESS (§11.3); serving
        -- traffic is authenticated against the cache CA via proxy_ssl_verify.
        -- host sets the SNI so the cache presents its server cert.
        hc.spawn_checker {
          shm = "healthcheck", upstream = "shared_caches", type = "https",
          ssl_verify = false, host = "${c.cacheTls.serverName}",
          http_req = "HEAD /v2/ HTTP/1.0\r\nHost: cache\r\n\r\n",
          interval = ${toString hc.interval}, timeout = ${toString hc.timeout},
          fall = ${toString hc.fall}, rise = ${toString hc.rise},
          valid_statuses = { ${validStatuses} },
        }
        hc.spawn_checker {
          shm = "healthcheck", upstream = "shared_caches_apt", type = "https",
          ssl_verify = false, host = "${c.cacheTls.serverName}",
          http_req = "GET /health HTTP/1.0\r\nHost: cache\r\n\r\n",
          interval = ${toString hc.interval}, timeout = ${toString hc.timeout},
          fall = ${toString hc.fall}, rise = ${toString hc.rise},
          valid_statuses = { 200 },
        }
      }
    '';

    virtualHosts = {
      # ── OCI frontend (:8088) — containerd hosts.toml target ───────────
      "client-oci" = {
        default = true;
        listen  = [{ addr = "0.0.0.0"; port = c.ports.clientOci; }];
        extraConfig = ''
          # Per-tier cache + latency headers, inherited by both locations.
          add_header X-Cache-Hot  $upstream_cache_status;   # local hot-tier HIT/MISS
          add_header X-Cache-Time $request_time;            # total time at this nginx
        '';
        locations = {
          "= /health" = { return = ''200 "ok\n"''; };

          # Blobs: immutable → key purely on the digest (dedup across repos).
          # Buffering kept ON (unlike the §11.1 snippet) — nginx can't STORE a
          # response with buffering off, and proxy_cache_min_uses 2 is meant to
          # cache hot blobs on 2nd use; streaming-off would defeat that.
          "~ ^/v2/.+/blobs/sha256:" = {
            extraConfig = ''
              set $cache_key "blob:$oci_digest";
              proxy_cache oci_hot;
              proxy_cache_valid 200 206 30d;
              proxy_cache_min_uses 2;
              proxy_cache_lock on;
              proxy_next_upstream error timeout http_502 http_503 http_504 non_idempotent;
              proxy_pass https://shared_caches;
            '';
          };

          # Manifests: per-name → key on ns:uri (by-tag short TTL).
          "~ ^/v2/.+/manifests/" = {
            extraConfig = ''
              set $cache_key "$oci_ns:$uri";
              proxy_cache oci_hot;
              proxy_cache_valid 200 5m;
              proxy_cache_lock on;
              proxy_next_upstream error timeout http_502 http_503 http_504;
              proxy_pass https://shared_caches;
            '';
          };
        };
      };

      # ── apt frontend (:8090) — Acquire::http::Proxy target ────────────
      # apt sends absolute-form requests; preserve the origin Host so the
      # shared apt vhost keys/forwards by it. Short local TTL; the shared
      # layer holds the long-lived copy.
      "client-apt" = {
        listen = [{ addr = "0.0.0.0"; port = c.ports.clientApt; }];
        extraConfig = ''
          add_header X-Cache-Hot  $upstream_cache_status;
          add_header X-Cache-Time $request_time;
        '';
        locations = {
          "= /health" = { return = ''200 "ok\n"''; };
          "/" = {
            extraConfig = ''
              set $cache_key "$http_host$request_uri";
              proxy_cache apt_hot;
              proxy_cache_valid 200 206 5m;
              proxy_cache_lock on;
              proxy_set_header Host $http_host;
              proxy_next_upstream error timeout http_502 http_503 http_504;
              proxy_pass https://shared_caches_apt;
            '';
          };
        };
      };
    };
  };

  # Hot-cache dirs on the data disk, owned by the nginx service user.
  systemd.tmpfiles.rules = [
    "d /var/lib/cache 0755 nginx nginx - -"
    "d /var/lib/cache/nginx 0750 nginx nginx - -"
    "d /var/lib/cache/nginx/oci 0750 nginx nginx - -"
    "d /var/lib/cache/nginx/apt 0750 nginx nginx - -"
  ];

  # ProtectSystem=strict makes /var/lib read-only to the nginx unit by
  # default; whitelist the cache tree (same as the cache VMs).
  systemd.services.nginx.serviceConfig.ReadWritePaths = [ "/var/lib/cache" ];
}
