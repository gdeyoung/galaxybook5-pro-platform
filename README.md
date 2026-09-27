# Samsung Galaxy Book5 Pro — Linux support

Make the internal speakers work on a **Samsung Galaxy Book5 Pro** running Linux.

The Galaxy Book5 Pro (DMI `960XHA`, Intel Core Ultra 200V / Lunar Lake) has no sound from
its built-in speakers on a stock Linux kernel. Headphone jack, HDMI, and Bluetooth all work
fine — only the four internal speakers are silent. This repository fixes that, and packages
the fix so it survives a reinstall.

**Contents:** a one-shot installer, the out-of-tree kernel driver, systemd units, an
upstream-support watcher, and a full inventory of what a configured machine looks like.

---

## Table of contents

- [Quick start](#quick-start)
- [The problem, explained](#the-problem-explained)
- [How the fix works](#how-the-fix-works)
- [Requirements](#requirements)
- [What the installer does](#what-the-installer-does)
- [Verifying it worked](#verifying-it-worked)
- [Troubleshooting](#troubleshooting)
- [Errors that are NOT problems](#errors-that-are-not-problems)
  - [The read-only `/lib/modules` problem](#the-read-only-libmodules-problem)
  - [`/usr/src` is empty](#usrsrc-is-empty)
  - [`modinfo` says module not found](#modinfo-says-module-not-found)
- [Uninstalling](#uninstalling)
- [Secure Boot](#secure-boot)
- [Which boot path should I use?](#which-boot-path-should-i-use)
- [Upstream support status](#upstream-support-status)
- [Hardware reference](#hardware-reference)
- [Repository layout](#repository-layout)
- [Credits and license](#credits-and-license)

---

## Quick start

```bash
git clone https://github.com/gdeyoung/galaxybook5-pro-platform.git
cd galaxybook5-pro-platform
sudo ./restore.sh
```

The script checks your hardware before touching anything, is safe to re-run, and tells you
at the end whether a reboot is required. It also explains any manual step it could not
perform for you (Secure Boot enrollment, mainly).

Then reboot and verify:

```bash
lsmod | grep max98390                  # two modules loaded
ls /sys/bus/i2c/devices/2-003{9,c,d}    # three I2C amplifier devices exist
cat /proc/asound/cards                  # sofhdadsp, your board name
```

---

## The problem, explained

Your Book5 Pro has four internal speakers. They are not driven directly by the Intel HD
Audio controller — the controller is a digital audio interface, and the analog signal has to
be amplified before it reaches a speaker. On this machine that amplification is done by four
**Maxim MAX98390** smart amplifiers, each sitting on the **I²C** bus at addresses `0x38`,
`0x39`, `0x3c`, and `0x3d`.

The upstream Linux kernel cannot drive these chips. Not a configuration issue, not a
distro bug — three separate pieces are missing:

| # | Missing piece | Consequence |
|---|---------------|-------------|
| 1 | `serial-multi-instantiate` doesn't know the `MAX98390` ACPI device ID | Only **1 of 4** amplifiers is ever enumerated. The other three are invisible to the kernel. |
| 2 | `snd_hda_codec_alc269` has no quirk entry for the Samsung MAX98390 subsystem IDs | The HDA side-codec component master is never set up, so even the enumerated amp is never driven. |
| 3 | `snd-hda-scodec-max98390` — the actual driver — | Does not exist in the kernel tree at all. |

The result is a failure that *looks* like a software problem, because the audio subsystem
starts cleanly and every other output path works. `aplay -l` lists a card, PipeWire starts,
`alsamixer` renders — you just get nothing from the built-in speakers.

Worth knowing: this is why you will find well-intentioned but wrong advice online. A lot of
"how do I fix audio on a Samsung Galaxy Book" threads recommend the ALC298 quirk-table
route or an `hda-verb` init script. Those target *different hardware* — boards where the
amplifier hangs off the audio codec rather than sitting on I²C. On a Book5 Pro with I²C
amps, they do nothing. See [Credits](#credits-and-license) for what to use instead.

---

## How the fix works

The driver is built out-of-tree with [DKMS](https://github.com/dell/dkms), so it rebuilds
automatically when your kernel updates.

**1. Provide the missing driver.** `source/max98390-hda-1.0/` is a DKMS package that builds
two modules:

| Module | Role |
|--------|------|
| `snd-hda-scodec-max98390` | Core HDA side-codec driver — init, DSM (dynamic speaker management), component binding |
| `snd-hda-scodec-max98390-i2c` | I²C transport — probe, regmap, ACPI matching |

**2. Create the amplifier devices the kernel didn't.** ACPI only enumerates the amplifier
at `0x38`. `scripts/max98390-hda-i2c-setup.sh` finds the right I²C bus, then **probes** each
remaining address with `i2cget` and creates a device only for chips that actually ACK. This
matters: it means the same script works on 2-amp boards without creating phantom devices
that would confuse the driver.

**3. Bind the driver to each device.** Because the I²C devices are created *after* udev has
already run, nothing binds them automatically. `scripts/max98390-hda-loader.sh` writes each
unbound device name to the driver's `bind` interface in sysfs.

**4. Watch for upstream support.** `max98390-hda-check-upstream.service` runs at every boot
and checks whether the kernel has gained native support. If it ever does, it removes this
workaround automatically. See [Upstream support status](#upstream-support-status).

---

## Requirements

- **Hardware:** Galaxy Book5 Pro (DMI product name `960XHA`). Other Galaxy Book models use
  different amplifiers and need different fixes — see [Hardware reference](#hardware-reference).
- **OS:** Bazzite / Fedora Atomic (or any OSTree-based immutable Fedora). Also works on
  regular Fedora.
- **Secure Boot:** if enabled, needs one-time MOK enrollment — see [Secure Boot](#secure-boot).

---

## What the installer does

`restore.sh` is idempotent; run it as many times as you like. In order:

1. **Verifies hardware** — warns and prompts if the DMI product name isn't `960XHA`.
2. **Layers packages** — `akmods`, `alsa-tools`, `dkms` via `rpm-ostree install`. These must
   be *layered* on an immutable image, not installed normally.
3. **Installs the DKMS source to `/usr/local/src`** and registers it. (Not `/usr/src` — see
   [that section](#usrsrc-is-empty).)
4. **Builds the module** for the running kernel, and hard-fails if the build didn't produce
   a `.ko`. Warns (expected) if the install-to-`/lib/modules` step fails.
5. **Checks Secure Boot / MOK** and tells you how to enroll if needed.
6. **Installs the scripts** to `/usr/local/sbin`, mode 0755.
7. **Installs and enables the systemd units.**
8. **Installs the modprobe drop-ins** — `sof.conf` and `blacklist.conf`.
9. **Adds the kernel argument** `bluetooth.disable_ertm=1` if absent.
10. **Regenerates initramfs** (best effort) and prints a verification checklist.

### What it deliberately does *not* do

- **It does not create a passwordless sudo rule.** Only the deprecated desktop-autostart
  path needs one. The script takes the systemd path instead, where root access comes from
  the unit's `CAP_SYS_MODULE` capability. If you enable the autostart fallback, the script
  prints the exact command to add one — your call, not a default.
- **It does not enroll your MOK.** That requires a reboot into a blue setup screen and a
  typed password. It cannot be automated, and pretending otherwise would strand you.

---

## Verifying it worked

```bash
# 1. Both modules loaded
$ lsmod | grep max98390
snd_hda_scodec_max98390_i2c    12288  0
snd_hda_scodec_max98390        20480  1 snd_hda_scodec_max98390_i2c

# 2. Three extra I²C amplifier devices created by the setup script
$ ls /sys/bus/i2c/devices/ | grep 2-003
2-0039   2-003c   2-003d

# 3. The SOF card is present and named after your board
$ cat /proc/asound/cards
0 [sofhdadsp]: sof-hda-dsp - sof-hda-dsp
       SAMSUNGELECTRONICSCO.LTD.-960XHA-P08AMA-NP960XHA_KG3US

# 4. The loader ran without error
$ systemctl status max98390-hda-loader.service
```

If `lsmod` shows both modules and `/dev/snd` has a working playback device, you're done.
The real test is playing something.

---

## Troubleshooting

### No sound, but everything looks configured

Check the boot log for the loader service first:

```bash
journalctl -b | grep -i max98390
```

What you're looking for:

| Message | Meaning |
|---------|---------|
| `N amplifier(s) bound, 0 failed` | Working as intended |
| `could not bind 2-0039` | Driver didn't load, or the I²C device was never created |
| `No MAX98390 ACPI device found on I2C bus` | The script found no ACPI node — likely wrong hardware, or the ACPI tables aren't exposing the amp |
| `No additional amplifiers found` | Only one amp detected; the other three didn't ACK the probe. Possible hardware fault, or a board with fewer amps |
| `dkms build failed` | The driver didn't compile. Almost always a kernel too new for the driver source — see below |

### The module didn't build

The driver is maintained against mainline. On a very new or very old kernel, the build can
fail. Check the log:

```bash
sudo dkms build max98390-hda/1.0 -k $(uname -r)
```

A common cause is a kernel API change in the HDA side-codec subsystem. If you're on a very
recent kernel and it fails, pin to a known-good kernel for now, or check whether upstream
support has landed (below) and drop the workaround.

### Sound works, then dies after suspend/resume

Known limitation of the driver version bundled here. Upstream added re-initialisation of
the amplifiers after resume in September 2026 (commit `4bae1c2`, issue #98); the copy in this
repository predates that commit. Update the driver source from upstream:

```bash
# replace source/max98390-hda-1.0/src/ with the newer upstream sources, then:
sudo dkms remove max98390-hda/1.0 --all
sudo dkms add max98390-hda/1.0
sudo dkms build max98390-hda/1.0 -k $(uname -r)
sudo reboot
```

Until then, a reboot restores audio.

### Audio works, but not on the console / TTY

You're using the desktop autostart path, which only runs at graphical login. Switch to the
systemd loader:

```bash
sudo systemctl enable --now max98390-hda-loader.service
```

---

## Errors that are NOT problems

This is the section that will save you the most time. **All of the following are expected on
an immutable image and do not indicate a broken install.**

### The read-only `/lib/modules` problem

DKMS normally installs a built module by copying it to `/lib/modules/<kernel>/extra/`. On
an OSTree image that path is **read-only**, so this always fails:

```
dkms: Signing module /var/lib/dkms/max98390-hda/1.0/build/src/snd-hda-scodec-max98390.ko
dkms: Installing /lib/modules/7.2.4-ogc3.1.fc44.x86_64/extra/snd-hda-scodec-max98390.ko.xz
cp: cannot create regular file '/lib/modules/.../snd-hda-scodec-max98390.ko.xz':
    Read-only file system
dkms: Autoinstall on 7.2.4-ogc3.1.fc44.x86_64 failed for module(s) max98390-hda(6).
```

Note that **building and signing both succeeded.** Only the copy failed. The usable module
stays in the writable build cache:

```
/var/lib/dkms/max98390-hda/1.0/<kernel>/x86_64/module/
    snd-hda-scodec-max98390.ko.xz
    snd-hda-scodec-max98390-i2c.ko.xz
```

This is why `scripts/max98390-hda-loader.sh` uses `insmod` with an **absolute path** rather
than `modprobe` by name. Don't try to "fix" the DKMS install — there is nothing to fix.

The one real consequence: if `/var/lib/dkms/max98390-hda/1.0/<kernel>/` is ever cleaned out
(a `/var` tmpfs reset, aggressive package vacuuming), the modules vanish and nothing will
rebuild them automatically. The loader service does rebuild on demand; the autostart path
does not. One more reason to use the systemd path.

### `/usr/src` is empty

The upstream installer places the DKMS source in `/usr/src/max98390-hda-1.0/`. On this
image that directory does not exist — DKMS never populates `/usr/src` here.

Real locations:

| Path | Role |
|------|------|
| `/usr/local/src/max98390-hda-1.0/` | Canonical source, what `restore.sh` installs |
| `/var/lib/dkms/max98390-hda/1.0/source/` | Working copy DKMS builds from |

If you go looking for `/usr/src/max98390-hda-1.0` and don't find it, that's correct.

### `modinfo` says module not found

```
$ modinfo snd_hda_scodec_max98390
modinfo: ERROR: Module snd_hda_scodec_max98390 not found.
```

This is the downstream consequence of the read-only `/lib/modules` issue above: because the
module never got installed into the kernel's module tree, it was never added to the depmod
database, so `modinfo` can't find it. `lsmod` will still show it loaded, and the speakers
will still work. `modinfo` is simply looking in the wrong place.

Use this instead to get module info:

```bash
modinfo /var/lib/dkms/max98390-hda/1.0/$(uname -r)/x86_64/module/snd-hda-scodec-max98390.ko.xz
```

### Stale build trees

```
$ dkms status
max98390-hda/1.0, 6.17.7-ba25.fc43.x86_64, x86_64: built (Built modules are missing in the kernel modules folder)
max98390-hda/1.0, 7.2.4-ogc3.1.fc44.x86_64, x86_64: built
```

Entries for kernels you're no longer running are left over from previous boots. Harmless.
Clean them with:

```bash
sudo dkms remove max98390-hda/1.0 -k <old-kernel-version>
```

One genuine consequence: **rolling back to one of those older kernels will not have working
audio**, because the install step never completed for them.

---

## Uninstalling

```bash
sudo systemctl disable --now max98390-hda-loader.service
sudo systemctl disable --now max98390-hda-check-upstream.service
sudo systemctl disable --now max98390-hda-i2c-setup.service 2>/dev/null || true

sudo rm -f /etc/systemd/system/max98390-hda-*.service
sudo rm -f /usr/local/sbin/max98390-hda-*.sh
sudo systemctl daemon-reload

# if you used the autostart fallback
rm -f ~/.config/autostart/max98390-hda.desktop
sudo rm -f /etc/sudoers.d/max98390-hda   # if you created one

sudo dkms remove max98390-hda/1.0 --all
sudo rm -rf /usr/local/src/max98390-hda-1.0

# restore the modprobe defaults
sudo rm -f /etc/modprobe.d/sof.conf
echo "blacklist wl" | sudo tee /etc/modprobe.d/default-disable-broadcom-wl.conf

# drop the karg if you added it
rpm-ostree kargs --delete-if-present=bluetooth.disable_ertm=1

sudo reboot
```

The MOK key can stay enrolled; an unused key is harmless.

---

## Secure Boot

If Secure Boot is enabled, the kernel will refuse to load unsigned modules. DKMS handles
this by signing with a **Machine Owner Key (MOK)**, but the key must be enrolled in your
firmware before it counts.

Check whether you need this:

```bash
mokutil --sb-state
# "SecureBoot enabled" = you need an enrolled MOK
```

`restore.sh` checks for you. If enrollment is required, it will tell you. The manual steps:

```bash
# generate a key (akmods does this on first DKMS build)
sudo dkms install max98390-hda/1.0

# import it — you'll be prompted for a one-time password
sudo mokutil --import /var/lib/dkms/mok.pub

# reboot, then in the BLUE MOK Manager screen:
#   Enroll MOK  ->  Continue  ->  Yes  ->  type your password  ->  Reboot
```

Verify:

```bash
mokutil --test-key /var/lib/dkms/mok.pub
# "/var/lib/dkms/mok.pub is already enrolled" = good
```

This is a **one-time** procedure. Once enrolled, every future kernel rebuild is signed
automatically and keeps loading across kernel updates.

---

## Which boot path should I use?

Two boot paths exist. The systemd loader is recommended; the desktop autostart is a
fallback.

| | systemd loader (recommended) | KDE autostart (fallback) |
|---|---|---|
| Runs as | root, at boot | user session, **needs a graphical login** |
| Console / TTY audio | **works** | **silent until you log in graphically** |
| SELinux | `CAP_SYS_MODULE` granted in the unit | needs passwordless sudo |
| Error reporting | real exit codes, visible in `systemctl status` | swallows every error |
| Rebuilds if the build cache is wiped | **yes, automatically** | no |
| Passwordless sudo | not needed | **required** |

To switch from autostart to the systemd loader:

```bash
sudo systemctl enable --now max98390-hda-loader.service
rm ~/.config/autostart/max98390-hda.desktop
```

The autostart path has a real failure mode worth knowing: `max98390-hda-boot.sh` sends all
output to `/dev/null` and uses `|| true` throughout, so a failed `sudo` password prompt and
a successful run look *identical*. If you must use it, check `journalctl -b | grep max98390`
rather than trusting the exit code.

---

## Upstream support status

The proper fix is upstream at
[thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616) —
**not merged, no confirmed timeline.** Until it lands, this workaround is necessary.

`max98390-hda-check-upstream.service` runs on every boot and tests three conditions against
the running kernel:

1. Does `serial-multi-instantiate` have a `MAX98390` alias?
2. Does `snd_hda_codec_alc269` contain `alc298-samsung-max98390`?
3. Does `snd-hda-scodec-max98390` exist in the kernel tree?

If all three pass, the service removes the DKMS package, the scripts, and the systemd units.
Your speakers keep working that session (modules are already loaded); the next boot uses the
native driver instead.

Check the current status any time:

```bash
journalctl -b -u max98390-hda-check-upstream.service
```

Typical output when upstream support is *still* missing:

```
max98390-hda-check: serial-multi-instantiate: missing MAX98390 support
max98390-hda-check: snd_hda_codec_alc269: missing MAX98390 quirk entries
max98390-hda-check: snd-hda-scodec-max98390: not in kernel tree
max98390-hda-check: upstream not available yet in 7.2.4-ogc3.1.fc44.x86_64
```

⚠️ **The auto-removal is incomplete.** When it fires, it does not remove a desktop autostart
entry or a sudoers rule you may have created. Clean those up by hand.

---

## Hardware reference

Recorded from a working Galaxy Book5 Pro.

**Board**

| Property | Value |
|----------|-------|
| DMI product name | `960XHA` |
| DMI sys_vendor | `SAMSUNG ELECTRONICS CO., LTD.` |
| Audio subsystem ID | `144d:c1dd` (Samsung) |
| Audio controller | `00:1f.3` Intel HD Audio `[8086:a828]` |
| Audio driver in use | `sof-audio-pci-intel-lnl` (SOF firmware) |
| ALSA card | `sofhdadsp` |

**Amplifier layout**

| I²C address | Component | Channel | Enumerated by |
|-------------|-----------|---------|---------------|
| `0x38` | 0 | Woofer Left | ACPI (automatic) |
| `0x39` | 1 | Woofer Right | `max98390-hda-i2c-setup.sh` |
| `0x3c` | 2 | Tweeter Left | `max98390-hda-i2c-setup.sh` |
| `0x3d` | 3 | Tweeter Right | `max98390-hda-i2c-setup.sh` |

**Other platform changes**

| Change | Value | Purpose |
|--------|-------|---------|
| Layered packages | `akmods alsa-tools dkms` | module build/sign tooling |
| Kernel arg | `bluetooth.disable_ertm=1` | Bluetooth pairing stability — **unrelated to audio** |
| `/etc/modprobe.d/sof.conf` | `options snd slots=snd_soc_skl_hda_dsp` | pin ALSA slot allocation to the SOF platform driver |
| `/etc/modprobe.d/blacklist.conf` | `blacklist snd_hda_intel` | keep the legacy driver from claiming the controller, so SOF is used |

There are **no** `snd_hda_intel model=` overrides, no `acpi_osi` hacks, and no
`i2c_designware` tweaks on a correctly configured machine. If you're looking for audio
kernel arguments, there aren't any.

**Not needed on this model:** the built-in microphone works with stock SOF firmware, and
the webcam works with the in-kernel IPU7 driver. No camera or microphone patches are
included here because none were required.

### Other Galaxy Book models — don't use this

The MAX98390 DKMS driver is specific to boards with I²C smart amps. It **will not work** on
every Galaxy Book:

| Model | Hardware | What it needs |
|-------|----------|---------------|
| Book5 Pro / Ultra, Book4 Pro | MAX98390 I²C amps | **this repo** |
| Book2 Pro SE | 2× MAX98390 I²C amps | this repo (auto-detects amp count) |
| Book3 Pro 14" (`NP940XFG`) | ALC298 codec-internal amps, **no I²C amp chip** | userspace fix — [upstream `speaker-fix-940xfg/`](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/tree/main/speaker-fix-940xfg) |

The DKMS installer's hardware check should refuse to install on the wrong board, but verify
your DMI name before running anything.

---

## Repository layout

```
restore.sh                  one-shot installer — start here
INVENTORY.md                audit of a real configured machine, as of 2026-09-26
ATTRIBUTION.md              provenance and licensing of the driver source
LICENSE                     GPL-2.0 (covers the kernel driver)
source/max98390-hda-1.0/    DKMS driver source (from upstream, unmodified)
  dkms.conf
  src/                      9 C/H files, the driver itself
scripts/
  max98390-hda-i2c-setup.sh      finds the I²C bus, probes, creates amp devices
  max98390-hda-loader.sh         insmods the modules, binds devices to the driver
  max98390-hda-boot.sh           legacy all-in-one script (autostart path)
  max98390-hda-check-upstream.sh detects native kernel support, self-removes
systemd/
  max98390-hda-loader.service          recommended boot path
  max98390-hda-i2c-setup.service       legacy, superseded by the loader
  max98390-hda-check-upstream.service  upstream support watcher
  max98390-hda.desktop                 legacy KDE autostart fallback
etc/
  modprobe.d-sof.conf                  -> /etc/modprobe.d/sof.conf
  modprobe.d-blacklist.conf            -> /etc/modprobe.d/blacklist.conf
```

`INVENTORY.md` is a record of an actual audited machine. It's included because it captures
the real-world failure modes described above — the ones that otherwise send people hunting
for problems that don't exist.

---

## Credits and license

This repository exists because a community maintainer solved a real hardware problem.

- **Kernel driver:** [`Andycodeman/samsung-galaxy-book-linux-fixes`](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes)
  — the `speaker-fix/` package. The driver source here is copied from it, **unmodified**,
  under **GPL-2.0**. All the credit for the actual driver belongs there.
- **Upstream driver work:** [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616) —
  the in-flight effort to get native support into mainline.
- **Install script and immutable-image adaptations:** original to this repository.

See [`ATTRIBUTION.md`](ATTRIBUTION.md) for the full provenance breakdown.

### Approaches you may find online that do *not* apply here

Both of these are for **different hardware** and will not fix a Book5 Pro:

- [`joshuagrisham/samsung-galaxybook-extras`](https://github.com/joshugrisham/samsung-galaxybook-extras) —
  adds ALC269 quirk-table entries forcing a `model=` string. For boards whose amps hang off
  the codec, not I²C.
- [`topzyray/galaxybook-linux-setup`](https://github.com/topzyray/galaxybook-linux-setup) —
  initializes the amp with `hda-verb` verbs at boot. Same mismatch: codec-attached amps.

The DKMS driver is the right approach for MAX98390 I²C amplifiers, which is what the Book5
Pro has.

### License

GPL-2.0. See [`LICENSE`](LICENSE).

## A note on battery

The amplifiers are enabled when the driver probes them and stay powered — they are not shut
down when audio is idle. This is a consequence of the missing kernel quirk: the driver
implements an HDA playback hook for on-demand power management, but it never fires, because
the in-kernel ALC269 quirk that would create the component master doesn't exist for these
boards. Enabling at probe is what makes the speakers work at all.

If you care about idle battery drain, unload the modules when you're not using audio:
`sudo rmmod snd_hda_scodec_max98390_i2c snd_hda_scodec_max98390`.
