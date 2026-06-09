# ─── nix/modules/zfs-cache-pools.nix ───────────────────────────────────
# Runtime creation/import of the per-workload ZFS cache pools that back
# nginx (focus-design §18.6). NixOS can *import* existing pools but cannot
# declaratively *create* them, and these lab VMs are ephemeral (the data
# disks are wiped/recreated by `cache-vm-wipe`). So a single oneshot,
# ordered BEFORE nginx, imports-or-creates each pool on its dedicated raw
# virtio volume and lays down the datasets with their per-workload tuning.
#
# The pool/dataset spec is data: it comes from constants.nix via
# `mkZfsLayout`, set by the microvm generators. This module is just the
# generic machinery.
{ config, pkgs, lib, ... }:
let
  cfg = config.cacheZfs;
in
{
  options.cacheZfs = {
    enable = lib.mkEnableOption "ZFS-backed per-workload nginx cache pools";

    hostId = lib.mkOption {
      type = lib.types.str;
      description = "Unique 8-hex networking.hostId (ZFS won't import without it).";
    };

    pools = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      default = [ ];
      description = "Pools to create/import: { name; serial; ... } (from constants.mkZfsPools).";
    };

    datasets = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      default = [ ];
      description = "Datasets to create: { dataset; mountpoint; props } (from constants.mkZfsDatasets).";
    };

    # ─── ARC / L2ARC / ZIL tuning (focus-design §18.7) ───────────────
    arcMaxBytes = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "zfs_arc_max in bytes (zfs.zfs_arc_max kernel param); 0 = ZFS default (~50% RAM).";
    };

    l2arc.enable = lib.mkEnableOption "an L2ARC cache vdev (not used in the lab — focus-design §18.7)";
    slog.enable = lib.mkEnableOption "a SLOG/ZIL log vdev (not used in the lab — focus-design §18.7)";
  };

  config = lib.mkIf cfg.enable {
    boot.supportedFilesystems = [ "zfs" ];
    # No ZFS root pool here (root is tmpfs, /var/lib is ext4); the cache
    # pools are non-root data pools, so force-import-root is irrelevant.
    boot.zfs.forceImportRoot = false;
    networking.hostId = cfg.hostId;
    environment.systemPackages = [ config.boot.zfs.package ];

    # Cap the ARC via the zfs.zfs_arc_max kernel cmdline param. boot.kernelParams
    # is list-merged across modules, so this concatenates with the console
    # params the microvm generator sets — no conflict.
    boot.kernelParams = lib.mkIf (cfg.arcMaxBytes > 0)
      [ "zfs.zfs_arc_max=${toString cfg.arcMaxBytes}" ];

    # L2ARC/SLOG are deliberately unimplemented for the lab: the levers exist
    # and are documented in constants.zfsTuning, but flipping one on is a
    # guarded build-time error rather than a silent no-op (each needs a real
    # dedicated fast vdev — focus-design §18.7).
    assertions = [
      { assertion = !cfg.l2arc.enable;
        message = "cacheZfs.l2arc.enable: L2ARC is not implemented for the lab — every disk shares one host backing store, so an L2ARC vdev can't be faster. See focus-design §18.7."; }
      { assertion = !cfg.slog.enable;
        message = "cacheZfs.slog.enable: SLOG/ZIL is not implemented for the lab — all datasets are sync=disabled so the ZIL is bypassed. See focus-design §18.7."; }
    ];

    systemd.services.zfs-cache-pools = {
      description = "Import/create per-workload ZFS cache pools for nginx";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      # /var/lib is the ext4 data disk that holds the dataset mountpoints'
      # parent dirs; ZFS userland modules must be loaded first.
      after = [ "zfs.target" ];
      requires = [ "zfs.target" ];
      unitConfig.RequiresMountsFor = [ "/var/lib" ];
      path = [ config.boot.zfs.package pkgs.coreutils pkgs.util-linux ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        # ── 1. import-or-create each pool on its dedicated raw volume ──────
        ${lib.concatMapStringsSep "\n" (p: ''
          dev=/dev/disk/by-id/virtio-${p.serial}
          # The virtio-by-id symlink can lag device probe; wait briefly.
          for _ in $(seq 1 50); do [ -e "$dev" ] && break; sleep 0.1; done
          if [ ! -e "$dev" ]; then
            echo "zfs-cache-pools: device $dev for pool ${p.name} never appeared" >&2
            exit 1
          fi
          if ! zpool list -H -o name ${p.name} >/dev/null 2>&1; then
            # Existing pool on the disk? import it. Otherwise the disk is a
            # fresh (throwaway ext4) volume — create, -f to clobber the label.
            zpool import -d /dev/disk/by-id -N ${p.name} 2>/dev/null \
              || zpool create -f -o ashift=12 -o autotrim=on \
                   -O mountpoint=none -O canmount=off ${p.name} "$dev"
          fi
        '') cfg.pools}

        # ── 2. create/refresh datasets with their per-workload tuning ─────
        ${lib.concatMapStringsSep "\n" (d:
          let
            allProps = d.props // { mountpoint = d.mountpoint; };
            createArgs = lib.concatStringsSep " "
              (lib.mapAttrsToList (k: v: "-o ${k}=${v}") allProps);
            setLines = lib.concatStringsSep "\n          "
              (lib.mapAttrsToList (k: v: "zfs set ${k}=${v} ${d.dataset}") allProps);
          in ''
            mkdir -p "$(dirname ${d.mountpoint})"
            if ! zfs list -H -o name ${d.dataset} >/dev/null 2>&1; then
              zfs create ${createArgs} ${d.dataset}
            else
              # Idempotent re-apply (tuning may have changed across rebuilds).
              ${setLines}
            fi
            # nginx must own its cache dir; the mount masks any prior chown.
            chown nginx:nginx ${d.mountpoint}
            chmod 0750 ${d.mountpoint}
          '') cfg.datasets}
      '';
    };

    # nginx's mount namespace is snapshotted at unit start, so the ZFS
    # datasets must be mounted before nginx starts or it won't see them.
    systemd.services.nginx = {
      after = [ "zfs-cache-pools.service" ];
      requires = [ "zfs-cache-pools.service" ];
    };
  };
}
