# Samsung Galaxy Book5 Pro — Local Platform Modifications

Host: `sammypro5` — Samsung Galaxy Book5 Pro (DMI `960XHA`, Intel Core Ultra 7 258V / Lunar Lake)
OS: Bazzite (Fedora Atomic) 44.20260921, kernel `7.2.4-ogc3.1.fc44.x86_64`
Inventoried: 2026-09-26

> **This is the Bazzite-era record (historical).** The machine moved to Omarchy (Arch) on
> 2026-10-15 and now uses upstream's installer — see the
> [Omarchy-era addendum](#addendum-the-omarchy-era-inventoried-2026-10-18) at the bottom
> for the current live state.

This documents every local deviation from the stock Bazzite image: what it is, where it
lives, why it exists, and what state it is actually in.

---

## 1. Summary of all modifications

| # | Area | Artifact | Kind | Active? |
|---|------|----------|------|---------|
| 1 | Layered packages | `akmods`, `alsa-tools`, `dkms` | rpm-ostree layer | Yes |
| 2 | Kernel cmdline | `bluetooth.disable_ertm=1` | kargs | Yes |
| 3 | Kernel module | `max98390-hda` DKMS driver | out-of-tree module | Yes (loaded) |
| 4 | Boot activation | `~/.config/autostart/max98390-hda.desktop` | KDE autostart + sudo | Yes |
| 5 | Audio config | `/etc/modprobe.d/sof.conf` | modprobe | Yes |
| 6 | Audio config | `/etc/modprobe.d/blacklist.conf` | modprobe | Yes |
| 7 | Wi-Fi | `/etc/modprobe.d/default-disable-broadcom-wl.conf` | modprobe | Yes |
| 8 | Secure Boot | MOK key at `/var/lib/dkms/mok.{key,pub}` | UEFI enrollment | Enrolled |
| 9 | Upstream watch | `max98390-hda-check-upstream.service` | systemd oneshot | Yes |
| 10 | Unused artifacts | `*-i2c-setup.service`, `max98390-hda-loader.service` | systemd, disabled | **No** |

---

## 2. rpm-ostree layer

```
LayeredPackages: akmods alsa-tools dkms
```

Applied to both the current deployment and the rollback deployment
(`44.20260713`). Requires a reboot after `rpm-ostree upgrade` to keep the layer.

- `akmods` — kernel module build/sign hooks
- `dkms` — out-of-tree module build framework
- `alsa-tools` — provides `i2cget`, used by the I2C probe script

Per Bazzite convention this layer is required and must not be removed.

---

## 3. Kernel command line

```
rhgb quiet root=UUID=... vconsole.keymap=us rootflags=subvol=root rw bluetooth.disable_ertm=1
```

The only local addition is `bluetooth.disable_ertm=1`. Everything else is Bazzite default.

This is the **only** cmdline change and it is Bluetooth-only, unrelated to audio. Disables
Extended Retransmit Mode, which improves pairing stability on some Intel controllers.
Controller present: `28:95:29:97:FF:17` (firmware 0x0d), `bluetooth.service` enabled.

**No other platform-specific kernel args are set** — notably no `snd_hda_intel` model
override, no `acpi_osi` hack, no `i2c_designware` tweaks.

---

## 4. The audio fix: MAX98390 speaker amplifiers

This is the substantive platform-specific work. The Book5 Pro's four internal speakers are
driven by four Maxim MAX98390 I2C smart amplifiers that the upstream kernel does not support.

### 4.1 Root cause

The stock kernel is missing three things:

1. **`serial-multi-instantiate`** does not know the `MAX98390` ACPI device ID, so it never
   enumerates all four amplifiers.
2. **`snd_hda_codec_alc269`** has no quirk entry for the Samsung MAX98390 subsystem IDs, so
   the HDA side-codec component master is never set up.
3. **`snd-hda-scodec-max98390`** — the actual amp driver — is not in the kernel tree at all.

Result: headphone jack, HDMI, and Bluetooth audio all work; internal speakers are completely
silent. Confirmed hardware:

```
00:1f.3 Audio device [0401]: Intel Core Ultra 200V Series HD Audio [8086:a828]
                Kernel driver in use: sof-audio-pci-intel-lnl
Card: sofhdadsp — SAMSUNGELECTRONICSCO.LTD.-960XHA-P08AMA-NP960XHA_KG3US
```

### 4.2 Speaker layout

| I2C address | Component | Channel | Enumerated by |
|--------------|-----------|---------|---------------|
| `0x38` | 0 | Woofer Left | ACPI automatically |
| `0x39` | 1 | Woofer Right | created by i2c-setup script |
| `0x3c` | 2 | Tweeter Left | created by i2c-setup script |
| `0x3d` | 3 | Tweeter Right | created by i2c-setup script |

### 4.3 DKMS source

- **Canonical source:** `/usr/local/src/max98390-hda-1.0/` (`dkms.conf` + `src/`, 9 C files)
- **Active DKMS tree:** `/var/lib/dkms/max98390-hda/1.0/source/` — a copy; `dkms` uses this
- **`/usr/src/max98390-hda-1.0/` does not exist** (dkms never copies there on this image)

`dkms.conf` defines two modules, both to `/updates/dkms`:

| Module | Role |
|--------|------|
| `snd-hda-scodec-max98390` | Core HDA side-codec driver (init, DSM, component binding) |
| `snd-hda-scodec-max98390-i2c` | I2C transport (probe, regmap, ACPI matching) |

`AUTOINSTALL="yes"` — rebuilds on every kernel update.

### 4.4 The read-only-filesystem workaround (important)

Standard DKMS install copies modules to `/lib/modules/<kver>/extra/`. On an OSTree image
**that path is read-only**, so the install step always fails. Actual boot log:

```
dkms: Signing module .../snd-hda-scodec-max98390.ko
dkms: Installing /lib/modules/7.2.4-.../extra/snd-hda-scodec-max98390.ko.xz
cp: cannot create regular file '/lib/modules/.../extra/snd-hda-scodec-max98390.ko.xz':
    Read-only file system
dkms: Autoinstall on 7.2.4-... failed for module(s) max98390-hda(6).
```

Note that **build and signing succeed**; only the install copy fails. The compiled module
stays in the writable DKMS build cache:

```
/var/lib/dkms/max98390-hda/1.0/<kernel>/x86_64/module/
    snd-hda-scodec-max98390.ko.xz
    snd-hda-scodec-max98390-i2c.ko.xz
```

Consequence: **the module is not in the kernel's depmod database** and `modinfo
snd_hda_scodec_max98390` fails even while the module is loaded and working. Nothing is
broken — it just means the module must be `insmod`-ed by absolute path rather than
`modprobe`-d by name.

`dkms status` also reports `Built modules are missing in the kernel modules folder` for the
five older kernels (6.17.7 ×2, 6.19.14, 7.0.9, 7.1.3). Only the running 7.2.4 shows a
clean `built`. Stale build dirs; harmless, but they are why the old kernels can't be
rolled back into working audio.

### 4.5 Boot activation — KDE autostart, not systemd

The module is loaded by a **KDE autostart entry that shells out to sudo**, not by a
systemd unit:

```
~/.config/autostart/max98390-hda.desktop

[Desktop Entry]
Type=Application
Name=MAX98390 Speaker Fix
Exec=sudo /usr/local/sbin/max98390-hda-boot.sh
Hidden=false
NoDisplay=true
X-KDE-autostart-phase=1
```

Boot journal confirms it:

```
09:59:17 systemd[2158]: Starting app-max98390\x2dhda@autostart.service - MAX98390 Speaker Fix...
09:59:17 sudo[3459]: gdeyoung : PWD=/var/home/gdeyoung ; COMMAND=/usr/local/sbin/max98390-hda-boot.sh
```

Consequences worth knowing:

- **Speakers are silent until the desktop session starts.** No console, no TTY, no
  early-boot audio.
- `sudo` must succeed non-interactively. If it ever prompts for a password, the autostart
  entry hangs and the fix silently does not apply.
- The `check-upstream.service` (`ConditionPathExists=/usr/local/src/max98390-hda-1.0/dkms.conf`)
  auto-removes the whole workaround once native support lands. Its removal path does **not**
  delete `~/.config/autostart/max98390-hda.desktop` or the sudoers rule — that cleanup is
  manual. Verify the autostart entry is gone when the service reports native support.

### 4.6 Boot sequence (`max98390-hda-boot.sh`)

1. `insmod` the two modules by absolute path from the DKMS build cache (base module first,
   order matters).
2. `sleep 2` — let the HDA bus register the new codec drivers.
3. Run `max98390-hda-i2c-setup.sh start` — create the missing I2C devices.
4. `sleep 1`.
5. Write each unbound device name to
   `/sys/bus/i2c/drivers/max98390-hda-i2c/bind` to attach the driver to
   `i2c-MAX98390:*` and `2-003{9,c,d}`.

All failures are `>/dev/null 2>&1 || true` — the script cannot report failure. If speakers
go silent after a kernel update, check the journal for the `sudo` line above rather than
trusting this script's exit status.

### 4.7 I2C enumeration script (`max98390-hda-i2c-setup.sh`)

- Finds the I2C bus by scanning `/sys/bus/i2c/devices/*MAX98390*` and falling back to
  `/sys/bus/acpi/devices/MAX98390:*` — works across Book4/Book5 board layouts.
- **Probes** each candidate address with `i2cget -y <bus> <addr> 0x00 b` and only creates
  devices for chips that ACK. This avoids ghost devices on 2-amp boards.
- Skips `0x38` (ACPI already created it).
- `stop` removes `0x3d`, `0x3c`, `0x39`.
- If no MAX98390 ACPI device is found it exits 0 — "hardware just isn't present" is not
  treated as an error.
- Requires `i2c-tools` (pulled in via the `alsa-tools` layer dependency).

### 4.8 SELinux

The loader unit documents the SELinux requirement — `insmod` under enforcing policy needs
`CapabilityBoundingSet=CAP_SYSMODULE` plus `AmbientCapabilities=CAP_SYSMODULE` and
`SecureBits=keep-caps`. The autostart path gets this via the sudoers rule instead.

### 4.9 Secure Boot

Secure Boot is **enabled**. The akmods MOK is enrolled:

```
mokutil --test-key /var/lib/dkms/mok.pub
  → /var/lib/dkms/mok.pub is already enrolled
```

(`mokutil --test-key` also prints a benign `Failed to access kernel trusted keyring` warning
on this image; the enrollment result is the line that counts.)

Key material: `/var/lib/dkms/mok.key`, `/var/lib/dkms/mok.pub` (mode 0600 / 0644,
created 2026-02-18). Because DKMS signing succeeds, rebuilt modules keep loading across
kernel updates without re-enrollment.

---

## 5. Other `/etc` modifications

### `/etc/modprobe.d/sof.conf`
```
options snd slots=snd_soc_skl_hda_dsp
```
Pins the ALSA `slots=` allocation to the Skylake HDA DSP platform driver. This is what keeps
the SOF/sof-hda-dsp card as the active HDA device on this Intel platform.

### `/etc/modprobe.d/blacklist.conf`
```
blacklist snd-hda-intel
```
Prevents the legacy `snd_hda_intel` driver from claiming the audio controller, so the
firmware-driven SOF stack (`sof-audio-pci-intel-lnl`) is used instead. This is the
`dsp_driver=1`-equivalent approach discussed in the community for Samsung Book hardware.

Note `snd_hda_intel` still appears in `lspci`'s module list as a fallback for the HDA
controller — it is simply not bound first.

### `/etc/modprobe.d/blacklist.conf.bak`
Backup of the above from 2026-02-14. Inert; safe to delete.

### `/etc/modprobe.d/default-disable-broadcom-wl.conf`
```
blacklist wl
```
Stock Bazzite — this machine has no Broadcom wireless. Not a Book5-specific change.

### `/etc/modprobe.d/tuned.conf`
Empty (0 bytes). Harmless.

### `/etc/asound.conf`
Contains only the default commented-out template. Not a real modification.

### `/etc/sysctl.d/`
Only `99-sysctl.conf -> ../sysctl.conf`; `/etc/sysctl.conf` is empty. **No sysctl
tweaks.**

### `/etc/udev/rules.d/`
**Empty.** All customisation is in scripts, not udev rules.

---

## 6. Disabled / vestigial artifacts

`max98390-hda-i2c-setup.service` and `max98390-hda-loader.service` are both **disabled** —
superseded by the autostart entry. The loader unit is the cleaner design: it runs as root
at boot, grants `CAP_SYS_MODULE` for `insmod`, checks for a build for the current kernel
and rebuilds if missing, and reports real failures with a nonzero exit code.

Present but unused:

- `/etc/systemd/system/max98390-hda-i2c-setup.service` — disabled
- `/etc/systemd/system/max98390-hda-loader.service` — disabled
- `/usr/local/sbin/max98390-hda-loader.sh` — never invoked
- `/usr/local/bin/lsfg-vk-ui` (74 MB) — unrelated binary, not part of the audio work
- `default-disable-broadcom-wl.conf`, `tuned.conf`, `blacklist.conf.bak` — inert

The upstream installer's `/etc/modules-load.d/max98390-hda.conf` is **absent** — the
autostart path replaced it.

Recommended cleanup: either enable `max98390-hda-loader.service` and drop the
`sudo`-from-autostart path (better — works headless, real error reporting, no passwordless
sudo), or delete the two disabled units and the unused loader script. Do not leave both
paths half-wired.

---

## 7. Not modified

Confirmed clean — no local changes needed or present:

- **Webcam / camera** — no `intel_cvs` DKMS module, no libcamera overrides. 32 `/dev/video*`
  nodes and `/dev/media0` exist from the in-kernel IPU7 driver. Community reports Book5
  webcam issues, but nothing has been patched here.
- **Microphone** — works on stock SOF firmware; no fix applied (upstream confirms the
  speaker fix does not break the built-in mic on Book5 Pro).
- **Graphics** — `xe` driver, in-kernel, stock.
- **Bluetooth** — kernel + firmware, stock. Only the `disable_ertm` karg.
- **Flatpak overrides** — none.
- **TPM / Secure Boot / fstrim / zram / system76-power** — stock Bazzite.

---

## 8. Upstream status and removal criteria

Upstream fix in development: [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616).
Not merged to mainline. No confirmed timeline.

`max98390-hda-check-upstream.service` (enabled, runs each boot) tests three conditions on the
running kernel:

1. `serial-multi-instantiate` has a `MAX98390` alias
2. `snd_hda_codec_alc269` contains `alc298-samsung-max98390`
3. `snd-hda-scodec-max98390` exists in the kernel tree

Current boot output — all three fail, DKMS still required:

```
max98390-hda-check: serial-multi-instantiate: missing MAX98390 support
max98390-hda-check: snd_hda_codec_alc269: missing MAX98390 quirk entries
max98390-hda-check: snd-hda-scodec-max98390: not in kernel tree
max98390-hda-check: upstream not available yet in 7.2.4-ogc3.1.fc44.x86_64
```

---

## 9. Known gaps and risks

1. **No headless audio.** Speakers depend on a KDE session starting. Console/TTY is silent.
2. **Silent failure mode.** `max98390-hda-boot.sh` swallows all errors; a failed `sudo`
   looks identical to success.
3. **Passwordless sudo dependency.** The autostart entry needs NOPASSWD sudo for
   `/usr/local/sbin/max98390-hda-boot.sh`. Not currently documented anywhere in `/etc`
   (that directory is root-only readable) — record it if this machine is ever rebuilt.
4. **No suspend/resume re-init.** No `system-sleep` hook. The amps are enabled at probe and
   never powered down. Upstream added resume re-initialisation for this in Sept 2026
   (commit `4bae1c2`, issue #98) — **this local copy predates that fix and will likely lose
   audio after resume.** Update the source from upstream when convenient.
5. **DKMS install permanently fails** on the read-only `/lib/modules`. The build cache is
   load-bearing: if `/var/lib/dkms/max98390-hda/1.0/<kernel>/` is ever cleaned (e.g.
   `dkms autoinstall` cleanup, `/var` tmpfs reset, package-manager vacuum), the modules
   vanish and nothing restores them. The disabled loader script had rebuild logic for
   exactly this; the active boot script has none.
6. **Stale build trees** for five retired kernels. Rollback to those will not have working
   audio.
7. **Upstream auto-removal is incomplete** — see 4.5. It will not clear the autostart entry
   or the sudoers rule.

---

## 10. Upstream references

- `samsung-galaxy-book-linux-fixes` (Andycodeman) — the DKMS driver this host runs:
  <https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes>
  - `speaker-fix/README.md` — install, root cause, speaker layout, MOK setup
  - Confirmed working on Galaxy Book5 Pro on Fedora with mic intact
- thesofproject/linux PR #5616 — the upstream driver this package is based on:
  <https://github.com/thesofproject/linux/pull/5616>
- `joshuagrisham/samsung-galaxybook-extras` — the alternative `alc269` quirk-table route
  (`alc298-samsung-amp-v2-*-amps` model string). Not used here; the DKMS driver is the
  right choice for MAX98390 I2C boards such as this one.
- `topzyray/galaxybook-linux-setup` — the `hda-verb` workaround. Not used here; the DKMS
  driver supersedes it.

---

## Addendum: the Omarchy era (inventoried 2026-10-18)

The machine left Bazzite on **2026-10-15** and now runs **Omarchy 4.0.4** (Arch, rolling,
kernel `7.2.8-9-omarchy`, Hyprland/Wayland). Everything above is the Bazzite-era record —
kept because it is the only public walkthrough of the immutable-image failure modes. The
live mechanism is now simpler: **upstream's installer, native Arch path**, replacing the
autostart/sudo loader entirely.

Current audited state, verified 2026-10-18 (commands and real output):

| Item | State |
|------|-------|
| DKMS | `max98390-hda/1.0, 7.2.8-9-omarchy, x86_64: installed` (AUTOINSTALL on kernel bumps) |
| Kernel modules | `snd_hda_scodec_max98390`, `snd_hda_scodec_max98390_i2c` loaded |
| Amp enumeration | `i2c-MAX98390:00` (0x38, ACPI) + `2-0039`, `2-003c`, `2-003d` (setup service) — kernel log shows 4 successful probes |
| Units | `max98390-hda-i2c-setup.service` active/enabled (`WantedBy=sound.target`); `max98390-hda-check-upstream.service` enabled (oneshot, armed for mainline) |
| Packages | `sof-firmware 2026.09.2-1` (mic, stock Omarchy), `swh-plugins 0.4.17-7` (LADSPA limiter — see below), `linux-omarchy-headers` matching the kernel |
| Secure Boot | off — no MOK dance on this install |
| Bazzite artifacts | all gone with the reinstall; nothing carried over |

What changed beyond the driver — **loudness**. With speakers working, 100% volume was
still ~4–5 dB quieter than Windows (documented expected behavior: no Samsung Dolby stack,
Redrix-derived DSM tuning). Measured at the speaker monitor: every plain software gain
mechanism is normalized away by the amps' protection DSP (details in the README's loudness
ceiling section). The working remedy is a system-wide PipeWire stage — 120 Hz high-pass
into a SWH `fastLookaheadLimiter` with 0…+6 dB input gain — shipped as
[`gdeyoung/audiofx-engine`](https://github.com/gdeyoung/audiofx-engine) +
[`gdeyoung/omarchy-audiofx`](https://github.com/gdeyoung/omarchy-audiofx), ear-validated
2026-10-18 at +6 dB. `swh-plugins` is that stage's only extra package.

Watch items on this install (young): first reboot early-load, suspend/resume re-init.
