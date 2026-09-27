#!/bin/bash
KVER=$(uname -r)
BUILD_DIR="/var/lib/dkms/max98390-hda/1.0/${KVER}/x86_64/module"

# Load modules
insmod "${BUILD_DIR}/snd-hda-scodec-max98390.ko.xz" 2>/dev/null || true
insmod "${BUILD_DIR}/snd-hda-scodec-max98390-i2c.ko.xz" 2>/dev/null || true

sleep 2

# Create additional i2c amp devices
/usr/local/sbin/max98390-hda-i2c-setup.sh start

sleep 1

# Bind all devices
BIND="/sys/bus/i2c/drivers/max98390-hda-i2c/bind"
for dev in /sys/bus/i2c/devices/i2c-MAX98390:* /sys/bus/i2c/devices/2-003{9,c,d}; do
    [ -e "$dev" ] || continue
    devname=$(basename "$dev")
    [ -e "${dev}/driver" ] && continue
    echo "$devname" > "$BIND" 2>/dev/null || true
done
