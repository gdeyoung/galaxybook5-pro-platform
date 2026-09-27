#!/bin/bash
# restore.sh — reapply the Galaxy Book5 Pro platform mods to a fresh Bazzite install.
#
# Assumes: Bazzite / Fedora Atomic, dnf-free environment, root. Run after a rebuild.
#   sudo ./restore.sh
#
# Idempotent: safe to re-run. Does NOT remove existing working config.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
SUDO_USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || echo gdeyoung)}"
HOME_DIR="$(getent passwd "$SUDO_USER_NAME" | cut -d: -f6)"

log()  { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "FATAL: $*" >&2; exit 1; }

# ── Guard: don't run on the wrong hardware ───────────────────────────────────
DMI="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown)"
if [ "$DMI" != "960XHA" ]; then
    warn "DMI product_name is '$DMI', expected '960XHA' (Galaxy Book5 Pro)."
    warn "This fix is specific to MAX98390 I2C amps. Wrong board = silent speakers still."
    read -r -p "Continue anyway? [y/N] " a; [ "$a" = "y" ] || exit 1
fi

# ── 1. Layered packages ──────────────────────────────────────────────────────
# akmods/dkms/alsa-tools are required and must be layered, not installed.
# i2c-tools comes from the alsa-tools dependency chain; verify.
log "Checking layered packages"
if ! rpm -q dkms akmods alsa-tools >/dev/null 2>&1; then
    log "Layering akmods, alsa-tools, dkms  (reboot required)"
    rpm-ostree install --allow-inactive akmods alsa-tools dkms
    NEEDS_REBOOT=true
else
    log "  akmods, alsa-tools, dkms already present"
fi

if ! command -v i2cget >/dev/null 2>&1; then
    warn "i2cget not found. The I2C probe needs it — install i2c-tools if amps go missing."
fi

# ── 2. DKMS source ──────────────────────────────────────────────────────────
# NOTE: do NOT use /usr/src — dkms never populates it on OSTree. The upstream
# installer puts it there, but the real tree must live at /usr/local/src.
log "Installing DKMS source to /usr/local/src/max98390-hda-1.0"
mkdir -p /usr/local/src
rm -rf /usr/local/src/max98390-hda-1.0
cp -r "${REPO_DIR}/source/max98390-hda-1.0" /usr/local/src/
chown -R root:root /usr/local/src/max98390-hda-1.0

log "Registering with DKMS"
if dkms status -m max98390-hda -v 1.0 2>/dev/null | grep -q "max98390-hda/1.0"; then
    dkms remove max98390-hda/1.0 --all 2>/dev/null || true
fi
dkms add max98390-hda/1.0 || warn "dkms add failed (may already be registered)"
dkms build  -m max98390-hda -v 1.0 -k "$KVER" || die "dkms build FAILED — no module"
dkms install -m max98390-hda -v 1.0 -k "$KVER" \
    || warn "dkms install to /lib/modules expected to FAIL (read-only OSTree). Modules are in the build cache."

BUILD_DIR="/var/lib/dkms/max98390-hda/1.0/${KVER}/x86_64/module"
if [ ! -f "${BUILD_DIR}/snd-hda-scodec-max98390-i2c.ko.xz" ]; then
    die "Module missing from ${BUILD_DIR} — insmod path will fail."
fi
log "Module present: ${BUILD_DIR}"

# ── 3. Secure Boot / MOK ────────────────────────────────────────────────────
if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    if [ ! -f /var/lib/dkms/mok.key ]; then
        log "Secure Boot enabled and no MOK key — generating (needs reboot + enrollment)"
        # akmods generates the key on first build; if absent, prompt user
        warn "No /var/lib/dkms/mok.key. Run: sudo dkms install max98390-hda/1.0"
        warn "then enroll with: sudo mokutil --import /var/lib/dkms/mok.pub"
        warn "and reboot into the MOK Manager blue screen."
        NEEDS_REBOOT=true
    elif ! mokutil --test-key /var/lib/dkms/mok.pub 2>&1 | grep -q "already enrolled"; then
        warn "MOK key exists but NOT enrolled. Run: sudo mokutil --import /var/lib/dkms/mok.pub"
        NEEDS_REBOOT=true
    else
        log "MOK key enrolled"
    fi
fi

# ── 4. Scripts ──────────────────────────────────────────────────────────────
log "Installing scripts to /usr/local/sbin"
install -m 0755 "${REPO_DIR}"/scripts/*.sh /usr/local/sbin/

# ── 5. systemd units ────────────────────────────────────────────────────────
log "Installing systemd units"
install -m 0644 "${REPO_DIR}"/systemd/*.service /etc/systemd/system/
systemctl daemon-reload

# The loader unit is the good path: root at boot, CAP_SYS_MODULE, rebuilds if the
# build cache is missing, and reports real failures. Enable it.
log "Enabling max98390-hda-loader.service (preferred boot path)"
systemctl enable max98390-hda-loader.service
systemctl enable max98390-hda-check-upstream.service

# The i2c-setup unit is redundant when the loader is enabled — loader's script
# calls i2c-setup directly. Leave it disabled.
systemctl disable max98390-hda-i2c-setup.service 2>/dev/null || true

# ── 6. modprobe config ──────────────────────────────────────────────────────
log "Installing /etc/modprobe.d config"
install -m 0644 "${REPO_DIR}/etc/modprobe.d-sof.conf"    /etc/modprobe.d/sof.conf
install -m 0644 "${REPO_DIR}/etc/modprobe.d-blacklist.conf" /etc/modprobe.d/blacklist.conf

# ── 7. Autostart fallback (only if NOT using systemd loader) ────────────────
# Installed but disabled: the desktop entry uses `sudo`, which we would rather
# avoid. If the loader service fails on this host, enable the fallback:
#   sudo cp systemd/max98390-hda.desktop /var/home/$USER/.config/autostart/
log "Autostart fallback available at systemd/max98390-hda.desktop (not installed)"

# ── 8. sudoers (only needed for the autostart fallback) ─────────────────────
warn "If you enable the autostart fallback, add a NOPASSWD rule:"
warn "  echo 'gdeyoung ALL=(root) NOPASSWD: /usr/local/sbin/max98390-hda-boot.sh' \\"
warn "    | sudo tee /etc/sudoers.d/max98390-hda"
warn "  sudo chmod 0440 /etc/sudoers.d/max98390-hda"
warn "Not created automatically — passwordless sudo is a deliberate choice."

# ── 9. Kernel args (Bluetooth only, not audio) ──────────────────────────────
if ! grep -q bluetooth.disable_ertm /proc/cmdline 2>/dev/null; then
    log "Adding karg bluetooth.disable_ertm=1"
    rpm-ostree kargs --append=bluetooth.disable_ertm=1
    NEEDS_REBOOT=true
else
    log "  karg already present"
fi

# ── 10. Verify ──────────────────────────────────────────────────────────────
log "Rebuilding initramfs (best effort)"
dracut --regenerate-all --force >/dev/null 2>&1 || warn "dracut returned nonzero (expected on OSTree)"

echo
log "Done. Current state:"
dkms status -m max98390-hda 2>/dev/null | grep "max98390-hda" | tail -2 || true
systemctl is-enabled max98390-hda-loader.service max98390-hda-check-upstream.service 2>&1 || true

cat <<EOF

NEXT STEPS
  1. Reboot:            sudo systemctl reboot
  2. Verify modules:    lsmod | grep max98390
  3. Verify I2C devs:   ls /sys/bus/i2c/devices/2-003{9,c,d}
  4. Verify card:       cat /proc/asound/cards
  5. Verify boot log:   journalctl -b | grep max98390
  6. Play something.    No sound? Check step 5 for the sudo/loader line.

EXPECTED NON-ERRORS after boot
  - dkms install EROFS error (read-only /lib/modules)  <- normal
  - "Built modules are missing in the kernel modules folder" for old kernels <- normal
  - modinfo snd_hda_scodec_max98390 says not found    <- normal, not in depmod db
EOF

[ "${NEEDS_REBOOT:-false}" = "true" ] && echo && echo ">>> REBOOT REQUIRED <<<"
exit 0
