#!/bin/bash -e
set -x

apt-get update

# Install only target kernel headers (Pi 5 + Pi 4 v8), NOT raspberrypi-kernel-headers
# which pulls in all flavors including 6.1.21-v8+ where hailo-dkms 4.20.0 fails to build.
#
# Behavior differs by Debian version:
# - bookworm: hailo-all 4.x → hailo-dkms (DKMS auto-build), straightforward
# - trixie:   hailo-all 5.x → hailort-pcie-driver, whose postinst runs modprobe
#   and fails in chroot. Patch postinst to skip modprobe but keep module build.
DEBIAN_VER=$(cat /etc/debian_version 2>/dev/null | awk -F'.' '{print $1}')

if [ "${DEBIAN_VER:-0}" -ge 13 ]; then
    # === Trixie (Debian 13) ===
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential linux-headers-rpi-2712 linux-headers-rpi-v8 hailo-all; then
        echo "=== trixie: patching hailort-pcie-driver postinst to skip modprobe ==="
        POSTINST=/var/lib/dpkg/info/hailort-pcie-driver.postinst
        if [ -f "$POSTINST" ]; then
            # In chroot: skip apt-list check (pipefail), skip make clean
            # (uname -r leaks host azure kernel, build dir missing), skip
            # modprobe. DKMS build (make install_dkms) still runs for rpi kernels.
            sed -i '1a if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]; then check_build_essential() { return 0; }; reload_pcie_driver() { echo "chroot: skip modprobe"; }; make() { [ "$1" = "clean" ] && { echo "chroot: skip make clean"; return 0; }; command make "$@"; }; fi' "$POSTINST"
            dpkg --configure hailort-pcie-driver || {
                echo "=== dpkg --configure failed, postinst log: ==="
                cat /var/log/hailort-pcie-driver.deb.log 2>&1 || true
                exit 1
            }
        fi
        # Retry now that postinst is patched
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            build-essential linux-headers-rpi-2712 linux-headers-rpi-v8 hailo-all
    fi
else
    # === Bookworm (Debian 12) ===
    # hailo-all 4.x uses hailo-dkms, no postinst issue expected.
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential linux-headers-rpi-2712 linux-headers-rpi-v8 hailo-all; then
        echo "=== bookworm: apt-get install failed, diagnosing ==="
        dpkg --audit 2>&1 || true
        dpkg -l | grep -vE '^(ii|rc)' || true
        tail -50 /var/log/dpkg.log 2>&1 || true
        exit 1
    fi
fi

# Install hailo-rpi5-examples
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
