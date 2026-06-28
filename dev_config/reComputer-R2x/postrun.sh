#!/bin/bash -e
set -x

apt-get update

# Install only target kernel headers (Pi 5 + Pi 4 v8), NOT raspberrypi-kernel-headers
# which pulls in all flavors including 6.1.21-v8+ where hailo-dkms 4.20.0 fails to build.
# hailo-all pulls in hailort, hailofw, hailo-dkms.
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential linux-headers-rpi-2712 linux-headers-rpi-v8 hailo-all; then
    echo "=== apt-get install failed, diagnosing ==="
    dpkg --audit 2>&1 || true
    echo "=== non-installed/broken packages ==="
    dpkg -l | grep -vE '^(ii|rc)' || true
    echo "=== last 50 lines of dpkg log ==="
    tail -50 /var/log/dpkg.log 2>&1 || true
    exit 1
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
