# ─── nix/constants/network.nix ─────────────────────────────────────────
# Node sets, network topology, and upstream OCI registries.
# Merged into the flat `constants` namespace by ../constants.nix; takes the
# whole fixpoint as `self` so sibling sections can be referenced uniformly.
self: {
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

  # ─── Upstream OCI registries (Tier-1) ──────────────────────────────
  # Each gets one Zot oracle on its zotPort (focus-design §13.1).
  upstreams = {
    "docker.io"       = { url = "https://registry-1.docker.io"; zotPort = 5050; };
    "gcr.io"          = { url = "https://gcr.io";               zotPort = 5051; };
    "ghcr.io"         = { url = "https://ghcr.io";              zotPort = 5052; };
    "quay.io"         = { url = "https://quay.io";              zotPort = 5053; };
    "registry.k8s.io" = { url = "https://registry.k8s.io";      zotPort = 5054; };
  };
}
