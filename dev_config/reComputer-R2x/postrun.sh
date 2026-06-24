#!/bin/bash -e
set -x

apt-get update

# Detect Debian release once (bookworm=12, trixie=13)
DEBIAN_NUM=$(cat /etc/debian_version | awk -F'.' '{print $1}')

if [ "$DEBIAN_NUM" -lt 13 ]; then
    ##################################################################
    # Bookworm (Debian 12)
    # Kernel module comes from hailo-dkms in the Pi OS apt repo; DKMS
    # auto-builds it against the running kernel, so no manual compile.
    ##################################################################
    echo "=== Installing hailo via apt (bookworm) ==="
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        raspberrypi-kernel-headers hailo-all hailo-dkms
else
    ##################################################################
    # Trixie (Debian 13+)
    # Patch hailort-pcie-driver postinst to skip modprobe while in the
    # build chroot, then build hailo_pci.ko from source against the
    # kernel that will actually boot on the target board.
    ##################################################################
    echo "=== Installing hailo via apt + source compile (trixie) ==="

    # Download hailort-pcie-driver and rewrite its postinst to no-op inside a chroot
    cd /tmp && apt-get download hailort-pcie-driver
    DEB_FILE=$(ls hailort-pcie-driver_*.deb 2>/dev/null | head -1)

    if [ -n "$DEB_FILE" ]; then
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

# Skip modprobe if in chroot
if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]; then
    echo "In chroot, skipping driver loading" | tee -a $LOG
    exit 0
fi

# Original postinst logic
POSTINST_EOF
            echo "$ORIGINAL_CONTENT" >> /tmp/pcie-pkg/DEBIAN/postinst
            chmod +x /tmp/pcie-pkg/DEBIAN/postinst

            dpkg-deb --root-owner-group -b /tmp/pcie-pkg /tmp/hailort-pcie-driver-patched.deb
            dpkg -i /tmp/hailort-pcie-driver-patched.deb
            echo "=== Patched driver installed ==="
        fi
        rm -rf /tmp/pcie-pkg "$DEB_FILE" /tmp/hailort-pcie-driver-patched.deb
    fi

    # User-space stack
    DEBIAN_FRONTEND=noninteractive apt-get install -y hailo-all

    # Resolve the kernel version baked into the boot image (not uname -r,
    # which is the builder kernel, not the target kernel)
    uname_r=$(uname -r)
    arch_r=$(dpkg --print-architecture)
    _VER_RUN=""
    function get_kernel_version() {
      local ZIMAGE IMG_OFFSET
      if [ -z "$_VER_RUN" ]; then
        ZIMAGE=/boot/firmware/kernel8.img
        if [[ $uname_r != *rpi-v8* ]]; then
          ZIMAGE=/boot/firmware/kernel_2712.img
        fi
      fi
      [ -f /boot/firmware/vmlinuz ] && ZIMAGE=/boot/firmware/vmlinuz
      IMG_OFFSET=$(LC_ALL=C grep -abo $'\x1f\x8b\x08\x00' $ZIMAGE | head -n 1 | cut -d ':' -f 1)
      _VER_RUN=$(dd if=$ZIMAGE obs=64K ibs=4 skip=$(( IMG_OFFSET / 4)) 2>/dev/null | zcat | grep -a -m1 "Linux version" | strings | awk '{ print $3; }' | grep "[0-9]")
      echo "$_VER_RUN"
      return 0
    }
    kernelver=$(get_kernel_version)

    # Strip Pi OS package suffix so we hit an upstream tag that actually exists
    VERSION=$(apt list hailo-all | grep hailo-all | awk '{print $2}' | cut -d'+' -f1)
    git clone https://github.com/hailo-ai/hailort-drivers.git -b v$VERSION hailort-drivers
    cd hailort-drivers/linux/pcie

    make clean >/dev/null 2>&1 || true
    make all KERNEL_DIR=/lib/modules/$kernelver/build

    # v4 driver produces ./hailo_pci.ko, v5 produces build/release/<arch>/hailo1x_pci.ko
    BUILT_KO=$(find . -type f \( -name 'hailo_pci.ko' -o -name 'hailo1x_pci.ko' \) | head -1)
    if [ -z "$BUILT_KO" ]; then
        echo "ERROR: hailo pci module not found after make. Files in $(pwd):"
        find . -maxdepth 4 -type f \( -name '*.ko' -o -name '*.o' \) || true
        exit 1
    fi
    echo "Found hailo module: $BUILT_KO"

    mkdir -p /lib/modules/$kernelver/kernel/drivers/misc
    cp "$BUILT_KO" /lib/modules/$kernelver/kernel/drivers/misc/

    # Remove kernel built-in hailo driver so the freshly built one wins
    if [ -d "/lib/modules/$kernelver/kernel/drivers/media/pci/hailo" ]; then
        find /lib/modules/$kernelver/kernel/drivers/media/pci/hailo -name "hailo*pci.ko*" -delete 2>/dev/null || true
    fi
    depmod -a $kernelver 2>/dev/null || true

    cd ../..
    if [ -f "./download_firmware.sh" ]; then
        chmod +x ./download_firmware.sh
        ./download_firmware.sh
        mkdir -p /lib/firmware/hailo
        mv hailo8_fw.4.*.bin /lib/firmware/hailo/hailo8_fw.bin
    else
        echo "Warning: download_firmware.sh not found, skipping firmware installation"
    fi

    mkdir -p /etc/udev/rules.d
    cp ./linux/pcie/51-hailo-udev.rules /etc/udev/rules.d/
    rm -rf hailort-drivers
fi

# Install hailo-rpi5-examples (common to both releases)
echo ${FIRST_USER_NAME}

cd /mnt
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
