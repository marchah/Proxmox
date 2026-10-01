#!/usr/bin/env bash
# Inside the test VM (Ubuntu 24.04 cloud image), root. Base stack for both VM setups:
#
# - amdgpu-dkms from AMD GPU driver 31.50 — the kernel driver ROCm 10.0 requires for
#   discrete Radeon cards. The Vulkan setup runs on the SAME driver, so B vs C is the
#   backend alone.
# - Ubuntu's Mesa RADV, the same noble-updates build CT 120 and CT 123 run.
# - qemu-guest-agent, which gpu-blower-control reads the card's temps through.
# - OverDrive (ppfeaturemask) so the test card's offset can be applied as on the host.
set -Eeuo pipefail

DRIVER=31.50
DEB=amdgpu-install_31.50.315000-1_all.deb
MESA="${MESA:-25.2.8-0ubuntu0.24.04.2}"
export DEBIAN_FRONTEND=noninteractive

# No background apt (CPU noise, or a new kernel the dkms module was not built for).
systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

apt-get update -q
# The cloud image ships without the DRM helper modules amdgpu-dkms links against
# (drm_display_helper); they are in linux-modules-extra.
apt-get install -y -q --no-install-recommends qemu-guest-agent \
  "linux-modules-extra-$(uname -r)" "linux-headers-$(uname -r)" \
  libvulkan1 vulkan-tools libgomp1 pciutils python3 curl ca-certificates
# Exactly the Mesa build CT 120 and CT 123 run, held so nothing moves it mid-test.
apt-get install -y -q --no-install-recommends --allow-downgrades \
  "mesa-vulkan-drivers=${MESA}" "mesa-libgallium=${MESA}"
apt-mark hold mesa-vulkan-drivers mesa-libgallium >/dev/null
systemctl start qemu-guest-agent

if ! grep -q installed <<<"$(dkms status -m amdgpu 2>/dev/null)"; then
  curl -fsSLo "/tmp/${DEB}" "https://repo.radeon.com/amdgpu-install/${DRIVER}/ubuntu/noble/${DEB}"
  apt-get install -y -q "/tmp/${DEB}"
  apt-get update -q
  amdgpu-install -y --usecase=dkms --no-32
fi
for k in /lib/modules/*/; do
  k=$(basename "$k")
  grep -q "${k}.*installed" <<<"$(dkms status -m amdgpu)" || { echo "FATAL: amdgpu-dkms not built for ${k}" >&2; exit 1; }
  dpkg -s "linux-modules-extra-${k}" >/dev/null 2>&1 || apt-get install -y -q "linux-modules-extra-${k}"
done

echo 'options amdgpu ppfeaturemask=0xfff7ffff' > /etc/modprobe.d/amdgpu-overdrive.conf
# -k all: the driver install can pull in a newer kernel, which is the one the next boot uses.
update-initramfs -u -k all

echo "kernel:  $(uname -r)"
echo "dkms:    $(dkms status -m amdgpu)"
echo "mesa:    $(dpkg-query -W -f='${Version}' mesa-vulkan-drivers)"
