# ─── nix/modules/nginx-cache.nix ───────────────────────────────────────
# The shared cache VMs' serving path: OpenResty acting as the primary
# pull-through cache for OCI registries (wildcard :8085) and apt repos
# (:8086). focus-design §13.2 / §13.3.
#
# Phase 2b: TLS listeners — both vhosts are `ssl`, presenting the shared
# cache server cert (cache CA, §11.5) installed by the cache-tls activation
# at /etc/nginx/cache/cache-server.{crt,key}. Clients verify against the
# cache CA (proxy_ssl_verify on, §11.5). Pull-through + digest-keyed dedup +
# MISS→HIT were validated on plain HTTP in Phase 2a (git history).
#
# Cache storage lives on /var/lib (the per-VM data disk), NOT /var/cache
# (which is on the small writable root) — model/blob caches need the space.
{ config, pkgs, lib, ... }:
let
  c = import ../constants.nix;

  # ns= (containerd's original-registry hint) → real upstream host. Most
  # registries are identity (gcr.io→gcr.io) but docker.io→registry-1.docker.io,
  # so we drive this from constants.upstreams instead of `proxy_pass $ns`.
  upstreamHostMap = lib.concatStringsSep "\n      " (lib.mapAttrsToList
    (ns: u: let host = lib.removePrefix "https://" u.url; in ''"${ns}" "${host}";'')
    c.upstreams);
in
{
  services.nginx = {
    enable  = true;
    package = pkgs.openresty;

    # This cache is a deliberate forward/pull-through proxy: it proxy_pass'es
    # to a registry host derived at request time from the ns= param. gixy
    # (run by writeNginxConfig) flags every dynamic proxy_pass as SSRF, which
    # is exactly the behaviour we want on this trusted lab subnet. Disabling
    # the build-time validator turns off both gixy AND `nginx -t`; we validate
    # instead by booting and curling the serving path.
    validateConfigFile = false;

    # Cross-cutting proxy/cache state shared by both vhosts.
    appendHttpConfig = ''
      proxy_cache_path /var/lib/cache/nginx/default levels=1:2
        keys_zone=cache_default:100m max_size=40g inactive=30d use_temp_path=off;
      proxy_cache_path /var/lib/cache/nginx/apt levels=1:2
        keys_zone=cache_apt:50m max_size=10g inactive=30d use_temp_path=off;

      # Origins/CDNs send Set-Cookie (Cloudflare __cf_bm) and Cache-Control
      # that would otherwise stop nginx caching; we deliberately override
      # those with our own proxy_cache_valid TTLs. Hide the upstream cookie
      # so it never reaches clients.
      proxy_ignore_headers Cache-Control Set-Cookie Expires X-Accel-Expires Vary;
      proxy_hide_header Set-Cookie;

      # Pull the digest out of /blobs/sha256:<hex> so identical blobs dedup
      # to a single entry across every repo and namespace (§7.2).
      map $uri $blob_digest { ~/blobs/(?<d>sha256:[0-9a-f]+)$ $d; default ""; }

      # ns= → real registry host (Host + SNI for the upstream proxy_pass).
      map $arg_ns $upstream_host {
        default $arg_ns;
        ${upstreamHostMap}
      }
    '';

    virtualHosts = {
      # ── Wildcard OCI catch-all (:8085) ────────────────────────────────
      "oci-cache" = {
        default = true;
        listen  = [{ addr = "0.0.0.0"; port = c.ports.nginxWildcard; ssl = true; }];
        extraConfig = ''
          resolver 1.1.1.1 ipv6=off valid=300s;
          ssl_certificate     /etc/nginx/cache/cache-server.crt;
          ssl_certificate_key /etc/nginx/cache/cache-server.key;
        '';
        locations = {
          "= /health" = { return = ''200 "ok\n"''; };

          # Blobs: immutable, content-addressed → key ONLY on the digest.
          # NB: nginx cannot store a response with proxy_buffering off, so —
          # unlike the design snippet — we keep buffering ON here (and in
          # @follow_cdn); caching the blob bytes is the whole point.
          "~ ^/v2/.+/blobs/sha256:" = {
            extraConfig = ''
              set $ckey "blob:$blob_digest";
              proxy_pass https://$upstream_host;
              proxy_ssl_server_name on;
              proxy_ssl_name $upstream_host;
              proxy_set_header Host $upstream_host;
              proxy_set_header User-Agent "${c.userAgent}";
              proxy_cache cache_default;
              proxy_cache_key $ckey;
              proxy_cache_valid 200 206 30d;
              proxy_cache_lock on;
              proxy_intercept_errors on;
              recursive_error_pages on;
              error_page 301 302 303 307 308 = @follow_cdn;
              add_header X-Cache-Status $upstream_cache_status;
              add_header X-Cache-Upstream-Time $upstream_response_time;
            '';
          };

          # Manifests + everything else: per-name, key on ns:method:uri.
          "/" = {
            extraConfig = ''
              if ($arg_ns = "") { return 404; }   # no ns= → let containerd fall through
              set $ckey "$arg_ns:$request_method:$uri";
              proxy_pass https://$upstream_host;
              proxy_ssl_server_name on;
              proxy_ssl_name $upstream_host;
              proxy_set_header Host $upstream_host;
              proxy_set_header User-Agent "${c.userAgent}";
              proxy_cache cache_default;
              proxy_cache_key $ckey;
              proxy_cache_valid 200 30d;
              proxy_cache_lock on;
              proxy_intercept_errors on;
              recursive_error_pages on;
              error_page 301 302 303 307 308 = @follow_cdn;
              add_header X-Cache-Status $upstream_cache_status;
              add_header X-Cache-Upstream-Time $upstream_response_time;
            '';
          };

          # Follow CDN 30x ourselves and cache the body under the SAME key the
          # entry location set ($ckey: digest for blobs, ns:uri for manifests),
          # dropping the signed (per-pull) query string.
          "@follow_cdn" = {
            extraConfig = ''
              set $cdn_url $upstream_http_location;
              proxy_pass $cdn_url;
              proxy_ssl_server_name on;
              proxy_set_header User-Agent "${c.userAgent}";
              proxy_cache cache_default;
              proxy_cache_key $ckey;
              proxy_cache_valid 200 206 30d;
              proxy_cache_lock on;
              add_header X-Cache-Status $upstream_cache_status;
            '';
          };
        };
      };

      # ── apt cache (:8086) ─────────────────────────────────────────────
      # apt packages are individually GPG-signed, so plain HTTP proxy
      # caching is safe. apt sends absolute-form requests to a proxy
      # (GET http://archive.ubuntu.com/...); we forward by Host header.
      "apt-cache" = {
        listen = [{ addr = "0.0.0.0"; port = c.ports.nginxApt; ssl = true; }];
        extraConfig = ''
          resolver 1.1.1.1 ipv6=off valid=300s;
          ssl_certificate     /etc/nginx/cache/cache-server.crt;
          ssl_certificate_key /etc/nginx/cache/cache-server.key;
        '';
        locations = {
          "= /health" = { return = ''200 "ok\n"''; };

          # Indices change → short TTL (checked before the .deb catch-all).
          "~ (InRelease|Release|Packages|Sources)(\\.(gz|xz|bz2))?$" = {
            extraConfig = ''
              proxy_pass http://$http_host;
              proxy_set_header User-Agent "${c.userAgent}";
              proxy_cache cache_apt;
              proxy_cache_key "$http_host$request_uri";
              proxy_cache_valid 200 5m;
              add_header X-Cache-Status $upstream_cache_status;
              add_header X-Cache-Upstream-Time $upstream_response_time;
            '';
          };

          # .deb are content-addressed by version → immutable, long TTL.
          "/" = {
            extraConfig = ''
              proxy_pass http://$http_host;
              proxy_set_header User-Agent "${c.userAgent}";
              proxy_cache cache_apt;
              proxy_cache_key "$http_host$request_uri";
              proxy_cache_valid 200 206 30d;
              add_header X-Cache-Status $upstream_cache_status;
              add_header X-Cache-Upstream-Time $upstream_response_time;
            '';
          };
        };
      };
    };
  };

  # Cache dirs on the data disk, owned by the nginx service user.
  systemd.tmpfiles.rules = [
    "d /var/lib/cache 0755 nginx nginx - -"
    "d /var/lib/cache/nginx 0750 nginx nginx - -"
    "d /var/lib/cache/nginx/default 0750 nginx nginx - -"
    "d /var/lib/cache/nginx/apt 0750 nginx nginx - -"
  ];

  # The NixOS nginx unit runs under ProtectSystem=strict, which makes the
  # whole FS read-only except /var/cache/nginx, /var/log/nginx, /run/nginx.
  # Our cache lives on the /var/lib data disk (40g+10g), so whitelist it —
  # otherwise nginx can't create its level dirs and silently serves every
  # request as a MISS.
  systemd.services.nginx.serviceConfig.ReadWritePaths = [ "/var/lib/cache" ];
}
