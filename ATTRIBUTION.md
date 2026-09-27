# Attribution and provenance

## Kernel driver (`source/max98390-hda-1.0/`)

The `snd-hda-scodec-max98390` driver source in this repository is **not original work**. It
is copied from:

- **Project:** `samsung-galaxy-book-linux-fixes`
- **Author:** Andycodeman
- **Upstream:** <https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes>
- **Path:** `speaker-fix/` in that repository
- **License:** GNU General Public License v2.0 — see [`LICENSE`](LICENSE)

That project in turn derives the driver from
[thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616), which
remains unmerged upstream as of this writing.

**Keeping it current.** The copy here is tracked against upstream `main` and was last synced
**2026-09-27** (upstream commit `4bae1c2`, "Re-initialise MAX98390 amps after resume from
hibernate"). To check for drift:

```bash
for f in source/max98390-hda-1.0/src/*; do
  n=$(basename "$f")
  curl -sS "https://raw.githubusercontent.com/Andycodeman/samsung-galaxy-book-linux-fixes/main/speaker-fix/src/$n" \
    | diff -q - "$f" >/dev/null 2>&1 || echo "DRIFTED: $n"
done
```

`restore.sh` intentionally installs the source **unmodified** — the immutable-image handling
lives in the scripts around it, not in the driver. Keeping the driver byte-identical to
upstream means upstream fixes arrive by re-copying, with no merge.

If you fork or redistribute this, carry the GPL-2.0 license and this attribution forward.
The driver is the copyrighted part; the scripts and documentation in this repository are
the parts specific to running it on Bazzite.

## What is ours

Everything except `source/max98390-hda-1.0/` is original to this repository:

| Path | What it is |
|------|------------|
| `restore.sh` | one-shot installer, written for this repo |
| `scripts/` | adapted from upstream's installer scripts for immutable-image constraints |
| `systemd/` | adapted unit files, plus a systemd boot path upstream does not ship |
| `etc/` | modprobe drop-ins |
| `README.md`, `INVENTORY.md` | documentation |

## Provenance of the live configuration

`INVENTORY.md` records the audited state of a real machine — a Samsung Galaxy Book5 Pro
(DMI `960XHA`) running Bazzite — as of 2026-09-26. It is included because it captures what
the fix actually looks like once installed, including the failure modes you are *expected*
to see on an OSTree image. The odd-looking errors documented there are real and expected,
and seeing them in the wild sends people looking for problems that do not exist.
