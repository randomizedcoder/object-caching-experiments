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

  sh = import ./lib/sh-helpers.nix { inherit lib; };

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
      ${sh.requireKey}
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

  # ── bare-metal deploy (focus-design §16) ────────────────────────────────
  # rsync THIS repo to a real Ubuntu box, copy ONLY the public cache CA cert,
  # then run ubuntu/bootstrap.sh over SSH. Unlike up/ssh/down (libvirt lab
  # guests) this targets an arbitrary --host using the operator's own SSH
  # access. The rsync filter is the security boundary: default-deny secrets/,
  # allow-list the single public cert — no private key ever transits.
  deploy = pkgs.writeShellApplication {
    name = "cache-ubuntu-deploy";
    runtimeInputs = with pkgs; [ rsync openssh coreutils ];
    # $DEST is expanded client-side ON PURPOSE — it is the deploy host's known
    # destination path, identical on the remote, so SC2029 is a false positive.
    excludeShellChecks = [ "SC2029" ];
    text = ''
      set -euo pipefail

      HOST=""; DEST="/opt/cache-lab"; KEY=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --host=*) HOST="''${1#--host=}"; shift ;;
          --dest=*) DEST="''${1#--dest=}"; shift ;;
          --key=*)  KEY="''${1#--key=}";  shift ;;
          --) shift ;;
          *) echo "unknown arg: $1" >&2; exit 2 ;;
        esac
      done
      if [[ -z "$HOST" ]]; then
        echo "usage: cache-ubuntu-deploy -- --host=<user@addr> [--dest=/opt/cache-lab] [--key=<ssh key>]" >&2
        exit 2
      fi

      # The PUBLIC cache CA cert is the one secret artifact the box needs and
      # the only one we copy. Refuse to deploy without it.
      CACHE_CA="''${PWD}/secrets/cache/ca/cache-CA.crt"
      if [[ ! -f "$CACHE_CA" ]]; then
        echo "ERROR: $CACHE_CA not found. Run 'nix run .#cache-gen-ca' in the lab first." >&2
        exit 1
      fi

      # First-contact host keys go into a repo-local known_hosts (matches
      # cache-ubuntu-ssh) so we neither prompt nor touch ~/.ssh. accept-new
      # only ADDS unknown keys — a changed key still hard-fails.
      KH="''${PWD}/ubuntu/deploy-known_hosts"
      mkdir -p "''${PWD}/ubuntu"
      COMMON=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KH")
      if [[ -n "$KEY" ]]; then
        # An explicit key: don't let the operator's agent shadow it.
        unset SSH_AUTH_SOCK 2>/dev/null || true
        COMMON+=(-i "$KEY" -o IdentitiesOnly=yes)
      fi
      SSH_OPTS=("''${COMMON[@]}")
      # rsync -e takes one string; the lab repo path has no spaces.
      RSH="ssh ''${COMMON[*]}"

      # $DEST may live under a root-owned prefix (e.g. /opt); create it with
      # sudo and hand it to the SSH user so rsync can write without root.
      # (id -un/-gn expand on the REMOTE side — that is intentional.)
      echo "→ preparing $DEST on $HOST (sudo mkdir + chown to ssh user)"
      ssh "''${SSH_OPTS[@]}" "$HOST" \
        "sudo mkdir -p '$DEST' && sudo chown \"\$(id -un):\$(id -gn)\" '$DEST'"

      echo "→ rsync repo to $HOST:$DEST (excluding secrets/, .git, build artifacts)"
      # --delete protects excluded paths, so a re-deploy keeps the box's
      # already-minted MITM tree under secrets/<node>/.
      # --no-specials/--no-devices: never transfer sockets/fifos (the lab leaves
      # cache-*.sock VM control sockets in the repo root; nix chokes copying a
      # socket into the store when it evaluates the flake from a non-git dir).
      rsync -az --delete --no-specials --no-devices \
        --exclude='secrets/' \
        --exclude='.git/' \
        --exclude='result*' \
        --exclude='*.qcow2' \
        --exclude='*.img' \
        --exclude='*.sock' \
        -e "$RSH" \
        "''${PWD}/" "$HOST:$DEST/"

      # A prior rsync may have left sockets behind (excludes protect them from
      # --delete); sweep them so the flake evaluates cleanly.
      ssh "''${SSH_OPTS[@]}" "$HOST" "find '$DEST' -xdev -type s -delete 2>/dev/null || true"

      echo "→ copying ONLY the public cache CA cert (no private keys transit)"
      ssh "''${SSH_OPTS[@]}" "$HOST" "mkdir -p '$DEST/secrets/cache/ca'"
      rsync -az -e "$RSH" "$CACHE_CA" "$HOST:$DEST/secrets/cache/ca/cache-CA.crt"

      echo "→ running bootstrap on $HOST"
      ssh "''${SSH_OPTS[@]}" "$HOST" "sudo bash '$DEST/ubuntu/bootstrap.sh'"
    '';
  };
}
