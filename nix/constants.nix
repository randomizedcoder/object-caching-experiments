# ─── nix/constants.nix ─────────────────────────────────────────────────
# Single source of truth for the object-caching-experiments lab.
# Every IP, MAC, hostname, port, upstream, model-store FQDN and resource
# size is defined here exactly once. The same data later feeds the
# Ubuntu/Ansible path via `nix eval --json`, so both worlds derive from
# one place. Shape is specified by focus-design §10; this file *is* that
# block, plus a few helper functions the Nix modules read.
#
# Where this file and focus-design disagree, focus-design §8–§10 wins.
rec {
  # ─── Node sets ─────────────────────────────────────────────────────
  clientNames = [ "client0" ];                 # only one NixOS client for now
  cacheNames  = [ "cache0" "cache1" ];
  ubuntuNames = [ "ubuntu2204" "ubuntu2404" "ubuntu2604" ];  # deferred (Ansible)

  getHostname = node: "cache-${node}";

  # Stable per-node index → drives unique QEMU console port blocks.
  nodeIndex = {
    client0 = 0;
    cache0  = 1;
    cache1  = 2;
  };

  # ─── Network topology (focus-design §9) ────────────────────────────
  # Dedicated bridge isolates this lab from nix-k8s-examples / ceph-on-k8s
  # (both on 10.33.33.0/24).
  network = {
    bridge   = "cachebr0";
    gateway4 = "10.44.44.1";
    gateway6 = "fd44:44:44::1";
    subnet4  = "10.44.44.0/24";
    subnet6  = "fd44:44:44::/64";

    taps = {
      client0 = "cachetap0";
      cache0  = "cachetap1";
      cache1  = "cachetap2";
    };

    ipv4 = {
      client0    = "10.44.44.10";
      cache0     = "10.44.44.20";
      cache1     = "10.44.44.21";
      ubuntu2204 = "10.44.44.30";
      ubuntu2404 = "10.44.44.31";
      ubuntu2604 = "10.44.44.32";
    };

    ipv6 = {
      client0    = "fd44:44:44::10";
      cache0     = "fd44:44:44::20";
      cache1     = "fd44:44:44::21";
      ubuntu2204 = "fd44:44:44::30";
      ubuntu2404 = "fd44:44:44::31";
      ubuntu2604 = "fd44:44:44::32";
    };

    macs = {
      client0    = "02:00:0a:2c:2c:10";
      cache0     = "02:00:0a:2c:2c:20";
      cache1     = "02:00:0a:2c:2c:21";
      ubuntu2204 = "02:00:0a:2c:2c:30";
      ubuntu2404 = "02:00:0a:2c:2c:31";
      ubuntu2604 = "02:00:0a:2c:2c:32";
    };
  };

  # ─── Ubuntu cloud images (Phase 4) ─────────────────────────────────
  # Pinned dated releases from cloud-images.ubuntu.com (NOT the moving
  # "release" symlink). Each Ubuntu client boots from one of these via
  # cloud-init + virt-install, bridged onto cachebr0. sha256 is the raw
  # hex from the release's SHA256SUMS.
  ubuntuImages = {
    ubuntu2204 = {
      release = "jammy/release-20260515";
      file    = "ubuntu-22.04-server-cloudimg-amd64.img";
      sha256  = "f6729b53d930d7f0c6691eb553cfa6be7109de9412125bf1bf2dc6747de8a44d";
    };
    ubuntu2404 = {
      release = "noble/release-20260518";
      file    = "ubuntu-24.04-server-cloudimg-amd64.img";
      sha256  = "53fdde898feed8b027d94baa9cfe8229867f330a1d9c49dc7d84465ee7f229f7";
    };
    ubuntu2604 = {
      release = "26.04/release-20260520";
      file    = "ubuntu-26.04-server-cloudimg-amd64.img";
      sha256  = "dced94c031cc1f23dee14419a3723a5b110df9938de0ac31913a2bfd07c755b4";
    };
  };
  ubuntuImageUrl = img:
    "https://cloud-images.ubuntu.com/releases/${img.release}/${img.file}";

  # ─── Serial console ports ──────────────────────────────────────────
  # Each node gets a block of 10 ports starting at base. Base differs
  # from the k8s lab (25500) so both labs can run simultaneously.
  console = {
    portBase     = 25600;
    serialOffset = 0;
    virtioOffset = 1;
  };

  # ─── Upstream OCI registries (Tier-1) ──────────────────────────────
  # Each gets one Zot oracle on its zotPort (focus-design §13.1).
  upstreams = {
    "docker.io"       = { url = "https://registry-1.docker.io"; zotPort = 5050; };
    "gcr.io"          = { url = "https://gcr.io";               zotPort = 5051; };
    "ghcr.io"         = { url = "https://ghcr.io";              zotPort = 5052; };
    "quay.io"         = { url = "https://quay.io";              zotPort = 5053; };
    "registry.k8s.io" = { url = "https://registry.k8s.io";      zotPort = 5054; };
  };

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

  # User-Agent the client nginx sends on every upstream request (§11.1).
  # Single point of change; cache VMs pass it through so origins see it too.
  userAgent = "Custom Nginx Proxy/caching";

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
    (map (name: { inherit name; fqdns = modelStores.${name}.fqdns; })
         (builtins.attrNames modelStores))
    ++ (map (h: { name = h; fqdns = [ h ]; }) mitmExtraHosts);

  # Flat list of every MITM'd FQDN → 127.0.0.1 /etc/hosts redirect.
  mitmAllFqdns = builtins.concatLists (map (g: g.fqdns) mitmCertGroups);

  # ─── VM resources ──────────────────────────────────────────────────
  # NB: cache.mem = 8192 is an exact power of two. The sister repos avoid
  # powers of two (used 8191/10239) because QEMU hangs on some hosts; if
  # you hit a boot hang, drop cache.mem to 8191. vcpu must equal the
  # multi_queue TAP queue count set in network-setup.nix.
  vmResources = {
    client = { vcpu = 4; mem = 6144; dataGiB = 50; };   # docker + openresty hot cache
    cache  = { vcpu = 4; mem = 8192; dataGiB = 50; };   # nginx cache + zot oracle (proving functionality, not bulk model storage)
  };

  # ─── Helper functions ──────────────────────────────────────────────

  # Per-node QEMU console ports (serial + virtio), unique blocks so two
  # VMs never collide on 127.0.0.1.
  getConsolePorts = node:
    let base = console.portBase + 10 * nodeIndex.${node}; in
    {
      serial = base + console.serialOffset;
      virtio = base + console.virtioOffset;
    };

  getVmResources = role: vmResources.${role};
}
