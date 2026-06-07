# ─── nix/network-setup.nix ─────────────────────────────────────────────
# Host bridge + TAP + NAT setup/teardown for the cache MicroVM lab
# (focus-design §9). Lifted from nix-k8s-examples/nix/network-setup.nix
# MINUS the apiserver-HAProxy section (no HA control plane here).
#
# Creates cachebr0 with the gateway IPs, three cachetap{0..2} with
# multi_queue (+ vhost-net), nftables masquerade for the v4/v6 subnets,
# and enables IP forwarding. Ubuntu VMs attach to cachebr0 directly via
# libvirt (no host TAP) when that path lands.
{ pkgs, constants }:
let
  inherit (constants.network) bridge gateway4 gateway6 subnet4 subnet6;

  # The three NixOS VMs get a host-side TAP.
  tapNodes = constants.clientNames ++ constants.cacheNames;   # [client0 cache0 cache1]
  tapList  = builtins.map (n: constants.network.taps.${n}) tapNodes;
in
{
  check = pkgs.writeShellApplication {
    name = "cache-check-host";
    runtimeInputs = with pkgs; [ kmod coreutils ];
    text = ''
      echo "=== Cache MicroVM Host Environment Check ==="
      errors=0

      if [[ -c /dev/net/tun ]]; then
        echo "OK /dev/net/tun exists"
      else
        echo "FAIL /dev/net/tun not found"
        echo "  Run: sudo modprobe tun"
        errors=$((errors + 1))
      fi

      if lsmod | grep -q vhost_net; then
        echo "OK vhost_net module loaded"
      elif [[ -c /dev/vhost-net ]]; then
        echo "OK /dev/vhost-net exists"
      else
        echo "FAIL vhost_net not available"
        echo "  Run: sudo modprobe vhost_net"
        errors=$((errors + 1))
      fi

      if lsmod | grep -q bridge; then
        echo "OK bridge module loaded"
      else
        echo "INFO bridge module not loaded (will be loaded during setup)"
      fi

      if sudo -n true 2>/dev/null; then
        echo "OK sudo access available"
      else
        echo "FAIL sudo access required for network setup"
        errors=$((errors + 1))
      fi

      if [[ $errors -gt 0 ]]; then
        echo ""
        echo "Host environment check failed with $errors error(s)"
        exit 1
      else
        echo ""
        echo "Host environment ready for cache lab"
      fi
    '';
  };

  setup = pkgs.writeShellApplication {
    name = "cache-network-setup";
    runtimeInputs = with pkgs; [ iproute2 kmod nftables acl procps ];
    text = ''
      echo "=== Cache MicroVM Network Setup ==="

      if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run with sudo: sudo nix run .#cache-network-setup"
        exit 1
      fi

      REAL_USER="''${SUDO_USER:-$USER}"
      if [[ "$REAL_USER" == "root" ]]; then
        echo "ERROR: Run via 'sudo nix run .#cache-network-setup' as a regular user"
        exit 1
      fi
      echo "Setting up network for user: $REAL_USER"

      # Load required kernel modules
      modprobe tun
      modprobe vhost_net
      modprobe bridge

      # Create bridge with dual-stack gateway IPs
      if ! ip link show ${bridge} &>/dev/null; then
        echo "Creating bridge ${bridge}..."
        ip link add ${bridge} type bridge
        ip addr add ${gateway4}/24 dev ${bridge}
        ip -6 addr add ${gateway6}/64 dev ${bridge}
        ip link set ${bridge} up
      else
        echo "Bridge ${bridge} already exists"
      fi

      # Create TAP devices for each node (multi_queue → match vcpu count)
      ${builtins.concatStringsSep "\n" (builtins.map (tap: ''
      if ip link show ${tap} &>/dev/null; then
        echo "Removing existing TAP device ${tap}..."
        ip link del ${tap}
      fi
      echo "Creating TAP device ${tap} for user $REAL_USER..."
      ip tuntap add dev ${tap} mode tap multi_queue user "$REAL_USER"
      ip link set ${tap} master ${bridge}
      ip link set ${tap} up
      '') tapList)}

      # Enable vhost-net access for the unprivileged runner
      if [[ -c /dev/vhost-net ]]; then
        if command -v setfacl &>/dev/null; then
          setfacl -m "u:$REAL_USER:rw" /dev/vhost-net
          echo "vhost-net enabled (ACL for $REAL_USER)"
        elif getent group kvm &>/dev/null; then
          chgrp kvm /dev/vhost-net
          chmod 660 /dev/vhost-net
          echo "vhost-net enabled (kvm group)"
        else
          echo "WARNING: Cannot set vhost-net permissions securely"
        fi
      fi

      # NAT for dual-stack internet access
      echo "Configuring NAT..."
      nft add table inet cache-nat 2>/dev/null || true
      nft flush table inet cache-nat 2>/dev/null || true
      nft -f - <<EOF
table inet cache-nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    # Skip NAT for VM-to-VM traffic (stays on bridge)
    ip saddr ${subnet4} ip daddr ${subnet4} accept
    ip6 saddr ${subnet6} ip6 daddr ${subnet6} accept
    # NAT only outbound traffic to the internet
    ip saddr ${subnet4} masquerade
    ip6 saddr ${subnet6} masquerade
  }
  chain forward {
    type filter hook forward priority 0;
    iifname "${bridge}" accept
    oifname "${bridge}" ct state related,established accept
  }
}
EOF

      # Enable IP forwarding (v4 + v6)
      sysctl -w net.ipv4.ip_forward=1 >/dev/null
      sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

      echo ""
      echo "Network ready. Nodes:"
      ${builtins.concatStringsSep "\n" (builtins.map (n: ''
      echo "  ${n}: ${constants.network.ipv4.${n}} / ${constants.network.ipv6.${n}} (${constants.network.taps.${n}})"
      '') tapNodes)}
    '';
  };

  teardown = pkgs.writeShellApplication {
    name = "cache-network-teardown";
    runtimeInputs = with pkgs; [ iproute2 nftables ];
    text = ''
      echo "=== Cache MicroVM Network Teardown ==="

      if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run with sudo: sudo nix run .#cache-network-teardown"
        exit 1
      fi

      # Remove TAP devices
      ${builtins.concatStringsSep "\n" (builtins.map (tap: ''
      if ip link show ${tap} &>/dev/null; then
        ip link del ${tap}
        echo "Removed TAP device ${tap}"
      fi
      '') tapList)}

      # Remove bridge
      if ip link show ${bridge} &>/dev/null; then
        ip link set ${bridge} down
        ip link del ${bridge}
        echo "Removed bridge ${bridge}"
      fi

      # Remove NAT rules
      nft delete table inet cache-nat 2>/dev/null && \
        echo "Removed NAT rules" || true

      echo "Network teardown complete"
    '';
  };
}
