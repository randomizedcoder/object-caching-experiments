# ─── nix/constants/resources.nix ───────────────────────────────────────
# Per-VM physical resources: serial console port blocks, vcpu/mem, and the
# whole ZFS cache-pool layout + tuning. `mkZfsDatasets` fans out over
# `self.modelStores` (../constants/app.nix) and `getConsolePorts` reads
# `self.nodeIndex` (../constants/network.nix), so this takes the fixpoint.
# Merged into the flat `constants` namespace by ../constants.nix.
self: {
  # ─── Serial console ports ──────────────────────────────────────────
  # Each node gets a block of 10 ports starting at base. Base differs
  # from the k8s lab (25500) so both labs can run simultaneously.
  console = {
    portBase     = 25600;
    serialOffset = 0;
    virtioOffset = 1;
  };

  # Per-node QEMU console ports (serial + virtio), unique blocks so two
  # VMs never collide on 127.0.0.1.
  getConsolePorts = node:
    let base = self.console.portBase + 10 * self.nodeIndex.${node}; in
    {
      serial = base + self.console.serialOffset;
      virtio = base + self.console.virtioOffset;
    };

  # ─── VM resources ──────────────────────────────────────────────────
  # NB: cache.mem = 8192 is an exact power of two. The sister repos avoid
  # powers of two (used 8191/10239) because QEMU hangs on some hosts; if
  # you hit a boot hang, drop cache.mem to 8191. vcpu must equal the
  # multi_queue TAP queue count set in network-setup.nix.
  vmResources = {
    client = { vcpu = 4; mem = 6144; dataGiB = 50; };   # docker + openresty hot cache
    cache  = { vcpu = 4; mem = 8192; dataGiB = 50; };   # nginx cache + zot oracle (proving functionality, not bulk model storage)
  };

  getVmResources = role: self.vmResources.${role};

  # ─── ZFS cache pools (focus-design §18.6) ──────────────────────────
  # nginx's filesystem cache is split across THREE per-workload ZFS pools
  # so each can be tuned and grown/shrunk independently:
  #   cache-manifests → tiny, latency-critical, all-RAM (ARC), no dedup.
  #   cache-blobs     → large OCI layers; metadata-only ARC, fast async
  #                     writes (sync=disabled); dedup ON purely to MEASURE
  #                     (nginx already digest-dedups blobs, so we expect
  #                     ~1.0x — confirmed by the experiment, not relied on).
  #   cache-http      → apt + model stores + extra; dedup ON (these are
  #                     NOT digest-addressed, so block dedup can genuinely
  #                     help).
  # Pools are created at runtime by modules/zfs-cache-pools.nix on extra
  # raw microvm volumes (one per pool), identified by a stable virtio
  # serial. Sizes here are starting points — the whole point is they can
  # diverge per workload later.

  # Per-VM unique 8-hex hostId (ZFS refuses to import pools without one).
  hostIds = {
    client0 = "ca0c0000";
    cache0  = "ca0c0a00";
    cache1  = "ca0c0a01";
  };

  # Stable virtio serials → /dev/disk/by-id/virtio-<serial> in the guest.
  zfsSerials = { manifests = "zmanifests"; blobs = "zblobs"; http = "zhttp"; };

  # Per-pool raw volume sizes (GiB). Cache VMs hold the fleet corpus;
  # the client only keeps a small hot tier.
  zfsSizesGiB = {
    cache  = { manifests = 4; blobs = 40; http = 20; };
    client = { manifests = 2; blobs = 8;  http = 6;  };
  };

  # Per-pool dataset tuning (focus-design §18.6 table).
  zfsProps = {
    manifests = { dedup = "off"; primarycache = "all";      recordsize = "16K";  atime = "off"; compression = "lz4"; sync = "disabled"; };
    blobs     = { dedup = "on";  primarycache = "metadata"; recordsize = "1M";   atime = "off"; compression = "off"; sync = "disabled"; };
    http      = { dedup = "on";  primarycache = "all";      recordsize = "128K"; atime = "off"; compression = "lz4"; sync = "disabled"; };
  };

  # The three pools, with the data needed to (a) declare microvm volumes
  # and (b) create the pools at runtime.
  mkZfsPools = role: [
    { name = "cache-manifests"; shortName = "manifests"; serial = self.zfsSerials.manifests; sizeGiB = self.zfsSizesGiB.${role}.manifests; }
    { name = "cache-blobs";     shortName = "blobs";     serial = self.zfsSerials.blobs;     sizeGiB = self.zfsSizesGiB.${role}.blobs;     }
    { name = "cache-http";      shortName = "http";      serial = self.zfsSerials.http;      sizeGiB = self.zfsSizesGiB.${role}.http;      }
  ];

  # datasets: pool/name → nginx cache dir (the ZFS mountpoint). The http
  # pool fans out one dataset per http-workload so each is independently
  # observable; cache VMs serve all model stores, the client only apt +
  # the MITM model hot tier.
  mkZfsDatasets = role:
    let
      httpSubs =
        if role == "cache"
        then [ "apt" ] ++ builtins.attrNames self.modelStores ++ [ "extra" ]
        else [ "apt" "model" ];
    in
    [
      { dataset = "cache-manifests/manifests"; mountpoint = "/var/lib/cache/nginx/manifests"; props = self.zfsProps.manifests; }
      { dataset = "cache-blobs/blobs";         mountpoint = "/var/lib/cache/nginx/blobs";     props = self.zfsProps.blobs;     }
    ]
    ++ map (sub: {
      dataset    = "cache-http/${sub}";
      mountpoint = "/var/lib/cache/nginx/${sub}";
      props      = self.zfsProps.http;
    }) httpSubs;

  mkZfsLayout = role: { pools = self.mkZfsPools role; datasets = self.mkZfsDatasets role; };

  # ─── ZFS ARC / L2ARC / ZIL tuning (focus-design §18.7) ─────────────
  # ARC is the in-RAM read cache. Cap it below ZFS's ~50%-RAM default
  # because the dedup DDT (the blobs + http pools) competes with the
  # manifest working set on these small-RAM VMs (cache 8 GiB, client
  # 6 GiB — see vmResources). L2ARC and SLOG/ZIL are deliberately OFF:
  # every virtio disk shares one host backing store (an L2ARC vdev can't
  # be faster, and its headers steal ARC RAM), and every dataset is
  # sync=disabled so the ZIL is bypassed (a SLOG would sit idle). Enable
  # either one only with a real dedicated fast device — see §18.7.
  zfsTuning = {
    arcMaxGiB = { cache = 4; client = 2; };
    l2arc     = { enable = false; };
    slog      = { enable = false; };
  };

  # zfs_arc_max wants bytes for the zfs.zfs_arc_max kernel param.
  getZfsArcMaxBytes = role: self.zfsTuning.arcMaxGiB.${role} * 1024 * 1024 * 1024;
}
