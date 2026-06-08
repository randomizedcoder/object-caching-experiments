# ─── nix/ubuntu-vm.nix ─────────────────────────────────────────────────
# Phase 4 Ubuntu-client lifecycle apps (focus-design §16). No Vagrant: we
# boot the official pinned Ubuntu CLOUD IMAGE directly under libvirt
# (qemu:///system — this host already runs VMs there, user is in the
# libvirtd group, so no per-VM sudo), bridged onto cachebr0 with the
# static MAC/IP from constants. cloud-init does the in-guest bring-up:
# static network, the lab SSH key on the `ubuntu` user, a 9p mount of THIS
# repo at /mnt/repo, and a Nix install. The actual config is then applied
# with `system-manager switch --flake /mnt/repo#ubuntu-client` (Phase 4b),
# which reuses constants.nix → one source of truth across NixOS + Ubuntu.
#
# Per-node mutable state (overlay disk + cloud-init seed) lives in
# $PWD/ubuntu/<node>/, alongside the microvm *-data.img files.
{ pkgs, lib, constants, secrets }:
let
  c      = constants;
  pubKey = secrets.sshPubKey;   # string | null (needs cache-gen-secrets)

  ubuntuNodes = builtins.attrNames c.ubuntuImages;
  nodeListMsg = builtins.concatStringsSep " " ubuntuNodes;

  # One fetchurl per pinned image; emitted into the script as case arms so
  # --node picks the right store path (and IP/MAC/etc).
  imageDrv = node: pkgs.fetchurl {
    url    = c.ubuntuImageUrl c.ubuntuImages.${node};
    sha256 = c.ubuntuImages.${node}.sha256;
  };

  nodeCase = f: builtins.concatStringsSep "\n        "
    (map (n: "${n}) ${f n} ;;") ubuntuNodes);

  # Per-node shell var assignments selected by `case "$NODE"`.
  nodeVars = nodeCase (n:
    "IMG='${imageDrv n}'; "
  + "IP4='${c.network.ipv4.${n}}'; "
  + "IP6='${c.network.ipv6.${n}}'; "
  + "MAC='${c.network.macs.${n}}'; "
  + "HOSTN='${n}'");

  ipCase = nodeCase (n: "echo ${c.network.ipv4.${n}}");

  gw4 = c.network.gateway4;
  gw6 = c.network.gateway6;

  # SSH options shared by ssh/up-wait. Ubuntu host keys are generated fresh
  # at first boot (not baked like the microvms), so we accept-new into a
  # per-node known_hosts under the state dir rather than ~/.ssh.
  sshCommon = node:
    "-o IdentitiesOnly=yes -i \"$KEY\" "
  + "-o StrictHostKeyChecking=accept-new "
  + "-o UserKnownHostsFile=\"$PWD/ubuntu/${node}/known_hosts\"";

  # pubKey is known at eval time, so gate here (a runtime [[ -z ]] on a
  # constant trips shellcheck SC2157).
  needPubKey =
    if pubKey == null then ''
      echo "ERROR: no SSH public key. Run 'nix run .#cache-gen-secrets' first." >&2
      exit 1
    '' else "";
in
{
  up = pkgs.writeShellApplication {
    name = "cache-ubuntu-up";
    runtimeInputs = with pkgs; [
      qemu cloud-utils cdrkit virt-manager libvirt coreutils netcat-gnu
    ];
    text = ''
      set -euo pipefail
      ${needPubKey}

      NODE=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --node=*) NODE="''${1#--node=}"; shift ;;
          --) shift ;;
          *) shift ;;
        esac
      done
      if [[ -z "$NODE" ]]; then
        echo "usage: cache-ubuntu-up -- --node=<${nodeListMsg}>" >&2
        exit 2
      fi

      IMG=""; IP4=""; IP6=""; MAC=""; HOSTN=""
      case "$NODE" in
        ${nodeVars}
        *) echo "ERROR: unknown node '$NODE' (expected: ${nodeListMsg})" >&2; exit 2 ;;
      esac

      REPO="$PWD"
      STATE="$PWD/ubuntu/$NODE"
      mkdir -p "$STATE"
      DISK="$STATE/$NODE.qcow2"
      SEED="$STATE/seed.iso"

      if virsh -c qemu:///system dominfo "cache-$NODE" >/dev/null 2>&1; then
        echo "[$NODE] domain cache-$NODE already defined — 'cache-ubuntu-down --node=$NODE' first" >&2
        exit 1
      fi

      # Standalone overlay (copy, not backing-file, to dodge libvirt chowning
      # the read-only /nix/store base). Grow it so cloud-init can expand root.
      if [[ ! -f "$DISK" ]]; then
        echo "[$NODE] creating disk from $IMG"
        cp --reflink=auto "$IMG" "$DISK"
        chmod u+w "$DISK"
        qemu-img resize "$DISK" 20G
      fi

      # ── cloud-init: NoCloud seed (user-data + network-config) ──────────
      cat > "$STATE/network-config" <<EOF
      version: 2
      ethernets:
        primary:
          match:
            macaddress: "$MAC"
          set-name: eth0
          addresses:
            - "$IP4/24"
            - "$IP6/64"
          routes:
            - to: default
              via: ${gw4}
            - to: "::/0"
              via: ${gw6}
          nameservers:
            addresses: [ 1.1.1.1, 1.0.0.1 ]
      EOF

      cat > "$STATE/user-data" <<EOF
      #cloud-config
      hostname: $HOSTN
      fqdn: $HOSTN
      preserve_hostname: false
      ssh_pwauth: false
      users:
        - name: ubuntu
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          shell: /bin/bash
          groups: [ sudo ]
          ssh_authorized_keys:
            - "${if pubKey == null then "" else pubKey}"
      write_files:
        - path: /etc/cache-lab-node
          content: "$NODE\n"
      runcmd:
        - [ sh, -c, "mkdir -p /mnt/repo && (grep -q ' /mnt/repo ' /etc/fstab || echo 'repo /mnt/repo 9p trans=virtio,version=9p2000.L,ro,_netdev 0 0' >> /etc/fstab) && mount /mnt/repo || true" ]
        - [ sh, -c, "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux --no-confirm --extra-conf 'experimental-features = nix-command flakes'" ]
        - [ sh, -c, "curl -fsSL https://get.docker.com | sh && usermod -aG docker ubuntu" ]
        - [ sh, -c, "touch /etc/cache-lab-cloudinit-done" ]
      EOF

      echo "[$NODE] building cloud-init seed"
      cloud-localds --network-config="$STATE/network-config" "$SEED" "$STATE/user-data"

      echo "[$NODE] virt-install (bridge cachebr0, mac $MAC, ip $IP4)"
      virt-install --connect qemu:///system \
        --name "cache-$NODE" \
        --memory 4096 --vcpus 2 \
        --cpu host-passthrough \
        --osinfo detect=on,require=off \
        --import \
        --disk path="$DISK",format=qcow2,bus=virtio \
        --disk path="$SEED",device=cdrom \
        --network bridge=cachebr0,model=virtio,mac="$MAC" \
        --filesystem source="$REPO",target=repo,driver.type=path,accessmode=passthrough \
        --graphics none --noautoconsole \
        --console pty,target_type=serial

      echo "[$NODE] launched. Waiting for SSH on $IP4 ..."
      for _ in $(seq 1 60); do
        if nc -z -w1 "$IP4" 22 2>/dev/null; then echo "[$NODE] SSH up"; break; fi
        sleep 2
      done
      echo "[$NODE] cloud-init installs Nix in the background; check:"
      echo "  nix run .#cache-ubuntu-ssh -- --node=$NODE -- 'ls /etc/cache-lab-cloudinit-done; nix --version'"
      echo "Then apply config (Phase 4b):"
      echo "  nix run .#cache-ubuntu-ssh -- --node=$NODE -- 'sudo /nix/var/nix/profiles/default/bin/nix run github:numtide/system-manager -- switch --flake /mnt/repo#ubuntu-client'"
    '';
  };

  ssh = pkgs.writeShellApplication {
    name = "cache-ubuntu-ssh";
    runtimeInputs = with pkgs; [ openssh coreutils ];
    text = ''
      set -euo pipefail
      unset SSH_AUTH_SOCK || true

      NODE=""; ARGS=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --node=*) NODE="''${1#--node=}"; shift ;;
          --) shift; ARGS=("$@"); break ;;
          *) ARGS+=("$1"); shift ;;
        esac
      done
      if [[ -z "$NODE" ]]; then
        echo "usage: cache-ubuntu-ssh -- --node=<${nodeListMsg}> [-- <command>]" >&2
        exit 2
      fi
      ip="$(case "$NODE" in
        ${ipCase}
        *) echo "" ;;
      esac)"
      if [[ -z "$ip" ]]; then
        echo "ERROR: unknown node '$NODE' (expected: ${nodeListMsg})" >&2
        exit 2
      fi
      KEY="''${PWD}/secrets/ssh-ed25519"
      if [[ ! -f "$KEY" ]]; then
        echo "ERROR: $KEY not found. Run 'nix run .#cache-gen-secrets' first." >&2
        exit 1
      fi
      mkdir -p "$PWD/ubuntu/$NODE"
      # shellcheck disable=SC2086
      exec ssh ${sshCommon "$NODE"} "ubuntu@$ip" "''${ARGS[@]}"
    '';
  };

  down = pkgs.writeShellApplication {
    name = "cache-ubuntu-down";
    runtimeInputs = with pkgs; [ libvirt coreutils ];
    text = ''
      set -euo pipefail
      NODE=""; PURGE=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --node=*) NODE="''${1#--node=}"; shift ;;
          --purge) PURGE=1; shift ;;
          --) shift ;;
          *) shift ;;
        esac
      done
      if [[ -z "$NODE" ]]; then
        echo "usage: cache-ubuntu-down -- --node=<${nodeListMsg}> [--purge]" >&2
        exit 2
      fi
      if virsh -c qemu:///system dominfo "cache-$NODE" >/dev/null 2>&1; then
        virsh -c qemu:///system destroy "cache-$NODE" 2>/dev/null || true
        virsh -c qemu:///system undefine "cache-$NODE" --nvram 2>/dev/null || true
        echo "[$NODE] domain removed"
      else
        echo "[$NODE] no domain cache-$NODE"
      fi
      if [[ "$PURGE" -eq 1 ]]; then
        rm -rf "''${PWD:?}/ubuntu/$NODE"
        echo "[$NODE] purged state dir"
      fi
    '';
  };
}
