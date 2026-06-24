#!/bin/bash -e
set -x

apt-get update

# User-space hailo stack. hailo-all pulls in hailort, hailofw, etc.
# Do NOT install hailo-dkms — it conflicts with how hailort-pcie-driver
# wants to build, and hailort-pcie-driver's own postinst handles the
# kernel module build (DKMS if available, one-shot make otherwise).
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential raspberrypi-kernel-headers hailo-all

# hailort-pcie-driver ships kernel module source + firmware + udev rules,
# and its postinst builds the kernel module itself. On trixie the package
# is in Pi OS apt; on bookworm it's only in the package pool — fall back
# to direct download.
cd /tmp
if ! apt-get download hailort-pcie-driver; then
    echo "hailort-pcie-driver not in apt sources on this release, fetching from pool"
    wget -q "https://archive.raspberrypi.com/debian/pool/main/h/hailort-pcie-driver/hailort-pcie-driver_4.23.0_all.deb"
fi
DEB_FILE=$(ls /tmp/hailort-pcie-driver_*.deb 2>/dev/null | head -1)
if [ -z "$DEB_FILE" ]; then
    echo "ERROR: failed to acquire hailort-pcie-driver .deb"
    exit 1
fi

# Patch postinst to skip modprobe while inside the build chroot. The build
# steps still run (target kernel headers are installed above); only the
# final `modprobe hailo_pci` is skipped because it cannot work in a chroot.
echo "=== Patching $DEB_FILE postinst ==="
mkdir -p /tmp/pcie-pkg
dpkg-deb -x "$DEB_FILE" /tmp/pcie-pkg
dpkg-deb -e "$DEB_FILE" /tmp/pcie-pkg/DEBIAN

if [ -f /tmp/pcie-pkg/DEBIAN/postinst ]; then
    ORIGINAL_CONTENT=$(tail -n +4 /tmp/pcie-pkg/DEBIAN/postinst)
    cat > /tmp/pcie-pkg/DEBIAN/postinst << 'POSTINST_EOF'
#!/bin/bash
set -eEuo pipefail

readonly PKG_NAME="hailort-pcie-driver"
readonly LOG="/var/log/${PKG_NAME}.deb.log"
echo "######### $(date) #########" >> $LOG

# Skip driver load while in the pi-gen build chroot — modprobe cannot work
# here. The kernel module itself still gets built by the steps below.
if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]; then
    echo "In chroot, skipping modprobe" | tee -a $LOG
    sed -i 's/^function reload_pcie_driver.*$/function reload_pcie_driver() { echo "In chroot, reload skipped"; }/' "$0"
fi

# Original postinst logic follows
POSTINST_EOF
    echo "$ORIGINAL_CONTENT" >> /tmp/pcie-pkg/DEBIAN/postinst
    chmod +x /tmp/pcie-pkg/DEBIAN/postinst

    dpkg-deb --root-owner-group -b /tmp/pcie-pkg /tmp/hailort-pcie-driver-patched.deb
    dpkg -i /tmp/hailort-pcie-driver-patched.deb
    echo "=== Patched driver installed ==="
fi

rm -rf /tmp/pcie-pkg "$DEB_FILE" /tmp/hailort-pcie-driver-patched.deb

# Install hailo-rpi5-examples
echo ${FIRST_USER_NAME}
sudo echo ${FIRST_USER_NAME}

cd /home/${FIRST_USER_NAME}
pwd
uname -a
git clone https://github.com/hailo-ai/hailo-rpi5-examples.git --depth 1
cd hailo-rpi5-examples
sed -i 's/device_arch=.*$/device_arch=HAILO8/g' setup_env.sh
sed -i '/sudo apt install python3-gi python3-gi-cairo/ s/$/ -y/' install.sh
./install.sh || true

free -h
swapon --show
df -h

# clean temp files and caches
apt-get -y autoremove --purge
apt-get -y clean
rm -rf /tmp/*
