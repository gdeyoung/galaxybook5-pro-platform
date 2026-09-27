#!/bin/bash
# Load MAX98390 HDA modules and bind all amplifiers.
# On Bazzite: /lib/modules is read-only (OSTree), so we use insmod from
# the DKMS build cache in /var/lib/dkms/ (writable).
# SELinux note: service unit must grant CAP_SYS_MODULE for insmod to work.

DKMS_NAME="max98390-hda"
DKMS_VER="1.0"
KVER=$(uname -r)
BUILD_DIR="/var/lib/dkms/${DKMS_NAME}/${DKMS_VER}/${KVER}/x86_64/module"
DRIVER_NAME="max98390-hda-i2c"

log() { echo "max98390-hda: $*"; logger -t max98390-hda "$*"; }

# ── Rebuild for new kernel if needed ────────────────────────────────────────
if [ ! -d "${BUILD_DIR}" ]; then
    log "No build for kernel ${KVER} — rebuilding..."
    /usr/sbin/dkms build "${DKMS_NAME}/${DKMS_VER}" -k "${KVER}" || {
        log "ERROR: dkms build failed"
        exit 1
    }
fi

# ── Load modules via insmod ──────────────────────────────────────────────────
# Load base module first, then i2c variant (order matters)
for mod in snd-hda-scodec-max98390 snd-hda-scodec-max98390-i2c; do
    KO="${BUILD_DIR}/${mod}.ko.xz"
    [ -f "$KO" ] || { log "ERROR: ${KO} not found"; exit 1; }

    MODNAME="${mod//-/_}"
    if lsmod | grep -q "^${MODNAME} "; then
        log "${mod} already loaded"
        continue
    fi

    if insmod "$KO"; then
        log "loaded ${mod}"
    else
        log "ERROR: insmod failed for ${mod} (exit $?)"
        log "  Check: is CAP_SYS_MODULE set in the service unit?"
        log "  Check: is the MOK key enrolled? (sudo mokutil --test-key /var/lib/dkms/mok.pub)"
        exit 1
    fi
done

# Give the HDA bus a moment to register the newly loaded codec drivers
sleep 2

# ── Bind all MAX98390 i2c devices to the driver ──────────────────────────────
# Devices exist in sysfs but have no driver because the driver module wasn't
# loaded when they were created. We must trigger binding manually.
BOUND=0
FAILED=0

bind_device() {
    local devpath="$1"
    local devname
    devname=$(basename "$devpath")

    # Already bound?
    if [ -e "${devpath}/driver" ]; then
        log "${devname}: already bound to $(basename $(readlink ${devpath}/driver))"
        BOUND=$((BOUND + 1))
        return 0
    fi

    # Try binding via the driver's bind sysfs interface
    local BIND_PATH="/sys/bus/i2c/drivers/${DRIVER_NAME}/bind"
    if [ ! -w "$BIND_PATH" ]; then
        log "WARNING: ${BIND_PATH} not writable — driver module may not be loaded yet"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if echo "$devname" > "$BIND_PATH" 2>/dev/null; then
        log "${devname}: bound to ${DRIVER_NAME}"
        BOUND=$((BOUND + 1))
    else
        # Try with driver_override (more explicit)
        echo "${DRIVER_NAME}" > "${devpath}/driver_override" 2>/dev/null || true
        if echo "$devname" > "$BIND_PATH" 2>/dev/null; then
            log "${devname}: bound via driver_override"
            BOUND=$((BOUND + 1))
            echo "" > "${devpath}/driver_override" 2>/dev/null || true
        else
            log "WARNING: could not bind ${devname}"
            FAILED=$((FAILED + 1))
        fi
    fi
}

# Bind ACPI device (0x38 — always present)
for dev in /sys/bus/i2c/devices/i2c-MAX98390:*; do
    [ -e "$dev" ] && bind_device "$dev"
done

# Bind additional i2c devices created by i2c-setup (0x39, 0x3c, 0x3d)
for dev in /sys/bus/i2c/devices/2-003{9,c,d}; do
    [ -e "$dev" ] && bind_device "$dev"
done

log "Done: ${BOUND} amplifier(s) bound, ${FAILED} failed"
[ "$FAILED" -eq 0 ] || exit 1
