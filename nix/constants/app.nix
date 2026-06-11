# ─── nix/constants/app.nix ─────────────────────────────────────────────
# Application-layer constants: the port map, the upstream User-Agent, the
# active health-check tunables, apt mirrors, and the LLM model stores.
# Merged into the flat `constants` namespace by ../constants.nix.
self: {
  # ─── Port map (focus-design §9.1) ──────────────────────────────────
  ports = {
    clientOci     = 8088;   # client nginx OCI frontend (containerd hosts.toml target)
    clientApt     = 8090;   # client nginx apt frontend (Acquire::http::Proxy target)
    clientMitm    = 443;    # §14 HTTPS termination (H3+H2)
    nginxWildcard = 8085;   # shared cache OCI catch-all (TLS, §11.5)
    nginxApt      = 8086;   # shared cache apt (TLS)
    nginxExtra    = 8104;   # shared cache generic MITM-extra vhost (download.docker.com etc., §17)
    nodeExporter  = 9100;
    nginxExporter = 9113;
    nginxStatus   = 8099;   # localhost-only stub_status, scraped by nginxExporter (§19)
  };

  # ─── Unix domain sockets ───────────────────────────────────────────
  # containerd→client-nginx OCI hop. The patched containerd (dial_addr in
  # certs.d/*/hosts.toml) dials this socket instead of clientOci TCP; nginx
  # listens on both (TCP retained for the not-built arbitrary-origin redirect).
  # Lives under nginx's RuntimeDirectory (/run/nginx, owned nginx:nginx 0750)
  # because the nginx master runs as the unprivileged `nginx` user and cannot
  # bind a socket directly in root-owned /run; containerd (root) still connects.
  socks = {
    clientOci = "/run/nginx/cache-oci.sock";
  };

  # User-Agent the client nginx sends on every upstream request (§11.1).
  # Single point of change; cache VMs pass it through so origins see it too.
  userAgent = "Custom Nginx Proxy/caching";

  # ─── In-process active health-check (lua-resty-upstream-healthcheck, §11.3) ──
  healthcheck = {
    interval      = 2000;                  # ms between probes
    timeout       = 1000;                  # ms per probe
    fall          = 3;                     # consecutive failures → down (hysteresis)
    rise          = 2;                     # consecutive successes → up
    probePath     = "/v2/";                # OCI liveness; "/health" for apt/wildcard vhosts
    validStatuses = [ 200 401 404 ];       # registry liveness answers
  };

  # apt mirrors to cache (HTTP only — see §17)
  aptUpstreams = [ "archive.ubuntu.com" "security.ubuntu.com" "ports.ubuntu.com" ];

  # ─── LLM model stores (focus-design §15) ───────────────────────────
  # kind=http → MITM + nginx HTTP cache; kind=oci → MITM + nginx
  # OCI/digest-keyed cache. `fqdns` are the hosts we /etc/hosts-redirect
  # and mint MITM certs for. `nginxPort` is the cache-VM vhost serving it.
  modelStores = {
    huggingface = { kind = "http"; nginxPort = 8100;
      fqdns = [ "huggingface.co" "cdn-lfs.huggingface.co" "cdn-lfs-us-1.huggingface.co" ]; };
    modelscope  = { kind = "http"; nginxPort = 8101;
      fqdns = [ "modelscope.cn" "www.modelscope.cn" "modelscope.oss-cn-beijing.aliyuncs.com" ]; };
    pytorch     = { kind = "http"; nginxPort = 8102;
      fqdns = [ "download.pytorch.org" "github.com" "objects.githubusercontent.com" ]; };
    ollama      = { kind = "oci";  nginxPort = 8103;
      fqdns = [ "registry.ollama.ai" ]; };
  };
}
