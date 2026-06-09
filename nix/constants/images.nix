# ─── nix/constants/images.nix ──────────────────────────────────────────
# Ubuntu cloud-image pins. Isolated here because these are the only
# time-sensitive values in the constant set — a dated-release bump churns
# this file alone, not the rest of the namespace.
# Merged into the flat `constants` namespace by ../constants.nix.
self: {
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
}
