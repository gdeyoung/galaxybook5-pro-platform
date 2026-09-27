# galaxybook5-pro-platform

Platform-specific modifications for the **Samsung Galaxy Book5 Pro** (DMI `960XHA`,
Intel Core Ultra 7 258V / Lunar Lake) running **Bazzite** (Fedora Atomic).

Everything needed to rebuild the Samsung hardware workarounds from scratch, plus a full
inventory of what this host has modified.

## Quick start

```bash
sudo ./restore.sh
```

Reads a confirmation prompt if the hardware doesn't match. Idempotent — safe to re-run.

Then **reboot** and verify:

```bash
lsmod | grep max98390                  # both modules loaded
ls /sys/bus/i2c/devices/2-003{9,c,d}    # 3 I2C amp devices created
cat /proc/asound/cards                  # sofhdadsp / 960XHA
journalctl -b | grep max98390           # look for the loader line
```

## What this actually fixes

One real problem: **the internal speakers are silent on stock Linux.**

The Book5 Pro drives its four internal speakers with four Maxim **MAX98390** I2C smart
amplifiers. The upstream kernel is missing three separate things needed to drive them:

1. `serial-multi-instantiate` doesn't know the `MAX98390` ACPI device ID → only 1 of 4 amps enumerated
2. `snd_hda_codec_alc269` has no quirk entry for the Samsung subsystem IDs → HDA side-codec master never set up
3. `snd-hda-scodec-max98390` — the actual driver — isn't in the kernel tree at all

Headphone jack, HDMI, and Bluetooth audio all work fine. Only the internal speakers are
dead, which is why the failure looks like an audio-config problem rather than a hardware one.

This package provides the missing driver out-of-tree via DKMS and works around the other
two gaps by creating the I2C devices by hand and binding them.

### Amp layout

| I2C address | Component | Channel | Enumerated by |
|-------------|-----------|---------|---------------|
| `0x38` | 0 | Woofer Left | ACPI automatically |
| `0x39` | 1 | Woofer Right | `i2c-setup.sh` |
| `0x3c` | 2 | Tweeter Left | `i2c-setup.sh` |
| `0x3d` | 3 | Tweeter Right | `i2c-setup.sh` |

The setup script **probes** each address with `i2cget` and only creates devices that ACK, so
it degrades correctly on 2-amp boards instead of creating ghost devices.

## Repo layout

```
restore.sh              reapply everything to a fresh install  <- start here
INVENTORY.md            full audit of the live host, as inventoried 2026-09-26
source/max98390-hda-1.0/   DKMS driver source (9 files, from upstream)
scripts/                the 4 deployed shell scripts
systemd/                3 systemd units + the desktop autostart entry
etc/                    modprobe.d drop-in config
```

`INVENTORY.md` is the record of what was actually on the machine. It contains the known
gaps and risks — read the **Known gaps** section before assuming a rebuild is clean.

## The OSTree read-only problem

This is the thing that will confuse you on a fresh install.

`/lib/modules` is **read-only** on an immutable Bazzite image, so DKMS's normal install step
(`cp` the built module to `/lib/modules/<kver>/extra/`) **always fails**:

```
cp: cannot create regular file '/lib/modules/7.2.4-.../extra/snd-hda-scodec-max98390.ko.xz':
    Read-only file system
```

**This is expected and is not a problem.** Build and signing both succeed. The usable module
stays in the writable DKMS build cache:

```
/var/lib/dkms/max98390-hda/1.0/<kernel>/x86_64/module/
    snd-hda-scodec-max98390.ko.xz
    snd-hda-scodec-max98390-i2c.ko.xz
```

Consequence: the module is **not** in the kernel depmod database, so:

```
modinfo snd_hda_scodec_max98390   #  ERROR: Module not found
```

…even while the module is loaded and the speakers are working. Load it by **absolute path**
with `insmod`, never `modprobe` by name. Don't waste time trying to fix the dkms install.

### Second gotcha: `/usr/src` is not where the source lives

Upstream's installer puts the DKMS source in `/usr/src/max98390-hda-1.0/`. On this image
that directory **does not exist** — dkms never populates it. The real tree is:

- canonical: `/usr/local/src/max98390-hda-1.0/`
- dkms working copy: `/var/lib/dkms/max98390-hda/1.0/source/`

`restore.sh` installs to `/usr/local/src` for exactly this reason.

## Secure Boot

Secure Boot is **enabled** on this machine. The akmods Machine Owner Key must be enrolled
in firmware or the unsigned module won't load. `restore.sh` checks and tells you if it
needs enrolling, but the enrollment itself requires a reboot into the blue MOK Manager
screen and a typed password — it can't be automated.

Check with:

```bash
mokutil --test-key /var/lib/dkms/mok.pub
# → "already enrolled"  = good
```

Because DKMS signing succeeds, every future kernel rebuild is signed automatically and keeps
loading without re-enrollment.

## Boot path

Two options exist in `systemd/`. The repo's `restore.sh` enables the **systemd loader**,
which is the better design:

| | systemd loader (recommended) | KDE autostart (fallback) |
|---|---|---|
| Runs as | root, at boot | user session, **needs a desktop login** |
| Console/TTY audio | works | **silent** |
| SELinux | `CAP_SYS_MODULE` in the unit | needs passwordless sudo |
| Error reporting | real exit codes | swallows everything |
| Rebuilds if build cache gone | **yes** | no |

The autostart entry (`systemd/max98390-hda.desktop`) is kept for reference and as a
fallback, but it calls `sudo` from a desktop autostart, which means:

- **No audio until the desktop session starts.**
- `max98390-hda-boot.sh` swallows every error (`2>/dev/null || true`), so a failed password
  prompt looks exactly like success.

If you enable the fallback, you need a NOPASSWD sudoers rule. `restore.sh` prints the exact
command but deliberately does **not** create it — passwordless sudo is a choice you should
make explicitly, and it should be documented wherever you keep your host notes.

## Kernel args

The only kernel command-line change is:

```
bluetooth.disable_ertm=1
```

Bluetooth pairing stability. **Unrelated to audio** — there are no `snd_hda_intel` model
overrides, no `acpi_osi` hacks, no `i2c_designware` tweaks. Anyone auditing this host
looking for audio kargs will not find them.

## `etc/` drop-ins

`etc/modprobe.d-sof.conf` → `/etc/modprobe.d/sof.conf`

```
options snd slots=snd_soc_skl_hda_dsp
```

Pins ALSA slot allocation to the Skylake HDA DSP platform driver, keeping the SOF card
active for this Intel platform.

`etc/modprobe.d-blacklist.conf` → `/etc/modprobe.d/blacklist.conf`

```
blacklist snd-hda-intel
```

Stops the legacy `snd_hda_intel` driver from claiming the controller, so the firmware-driven
SOF stack (`sof-audio-pci-intel-lnl`) is used instead.

## Upstream status

The upstream driver is in development at
[thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616) —
**not merged, no confirmed timeline.**

`max98390-hda-check-upstream.service` runs at every boot and tests three conditions on the
running kernel. When all pass, it removes the DKMS workaround automatically:

1. `serial-multi-instantiate` has a `MAX98390` alias
2. `snd_hda_codec_alc269` contains `alc298-samsung-max98390`
3. `snd-hda-scodec-max98390` exists in the kernel tree

Current status on this host — all three fail:

```
max98390-hda-check: serial-multi-instantiate: missing MAX98390 support
max98390-hda-check: snd_hda_codec_alc269: missing MAX98390 quirk entries
max98390-hda-check: snd-hda-scodec-max98390: not in kernel tree
max98390-hda-check: upstream not available yet in 7.2.4-ogc3.1.fc44.x86_64
```

⚠️ **The auto-removal is incomplete.** When it fires it removes DKMS and the systemd units
but does **not** remove the KDE autostart entry or the sudoers rule. If you ever see it
report native support, clean those up by hand.

⚠️ **Resume is not handled here.** Upstream added resume re-initialisation for these amps in
commit `4bae1c2` (2026-09-24, issue #98). The copy in this repo **predates that fix** and has
no `system-sleep` hook, so audio likely dies after suspend/resume. Refresh from upstream when
convenient.

## Sources

- [Andycodeman/samsung-galaxy-book-linux-fixes](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes)
  — the driver this host runs. `speaker-fix/` is the relevant directory.
  Confirmed working on Galaxy Book5 Pro on Fedora with the built-in mic intact.
- [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616) — upstream

Two other community approaches exist and are **not** used here, because they target different
hardware: [`joshuagrisham/samsung-galaxybook-extras`](https://github.com/joshuagrisham/samsung-galaxybook-extras)
(ALC269 quirk-table model string) and
[`topzyray/galaxybook-linux-setup`](https://github.com/topzyray/galaxybook-linux-setup)
(`hda-verb` init). Both are for boards where the amps hang off the codec rather than sitting
on I2C. The DKMS driver is the right choice for MAX98390 I2C amps like this one.
