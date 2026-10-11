# MS-100BT firmware 1.30: effect menu and categories

Static analysis of `MAIN.bin` (from ZOOM's 1.30 updater), disassembled with TI's own `dis6x` (C6000 CGT 8.3.15):
the load image's code section at `0xC00E1640` (427,104 bytes) decodes to 142,740 lines, with only 11 undecoded words.
Each section is wrapped as an ELF whose `.c6xabi.attributes` / `.TI.section.flags` come from an object built with `cl6x`,
so `dis6x` decodes the 16-bit compact instructions. Nothing was sent to the pedal.

## Why bass effects never appear in the menu

1. **The category picker is a fixed 2×3 grid.** The function at `0xC00F1E94` draws `SELECT CATEGORY` / `ADD EFFECT UNIT`.
   It then draws exactly five labels at hard-coded screen positions:

   | Label | Position | Address |
   |---|---|---|
   | `DYN/FLTR` | (3, 12) | `0xC014F59D` |
   | `OD/ DIST` | (45, 12) | `0xC014F5A6` |
   | `AMP` | (87, 12) | `0xC014F5AF` |
   | `MOD/SFX` | (3, 38) | `0xC014F5B3` |
   | `DLY/REV` | (45, 38) | `0xC014F5BC` |

   There is no bass group to pick.
2. **The firmware knows every category of the family anyway.** The table at `0xC0151B10` holds 32 words: a permutation of the
   index categories 0x00–0x1F. It is aligned with the category-name table at `0xC0150C38`: Bypass, Reserve0, Dynamics, Reserve1,
   Filter/EQ, Reserve2, Drive, BassDrive, Reserve3, Reserve4, BassPreAmp, …, AmpModeling, BassAmpModeling, …, Modulation, SFX,
   Delay, Reverb, …, TwinFx, PedalFx, …, Mic.

   | Firmware name | `FLST_SEQ.ZDT` / ZDL byte 60 |
   |---|---|
   | Dynamics | 01 |
   | Filter/EQ | 02 |
   | Drive | 03 |
   | AmpModeling | 04 |
   | **BassAmpModeling** | **05** |
   | Modulation | 06 |
   | SFX | 07 |
   | Delay | 08 |
   | Reverb | 09 |
   | TwinFx | 0A |
   | PedalFx | 0B |
   | **BassDrive** | **0C** |
   | **BassPreAmp** | **0D** |
   | AgModeling | 0E |
   | Mic | 10 |
   | Reserve0…13 | 11–1E |

   The function at `0xC0130C04` looks up a category in this table and returns the one `n` steps away. This is how the
   browser walks from one category to the next.
3. **Conclusion.** This is the same code base as the MS-60B / B1on. The MS-100BT build simply offers no menu group that
   contains the bass categories. Installing a bass effect stores it but leaves it unreachable. Listing it under a guitar
   category makes it reachable, but the pedal **froze** when it tried to load it (see PROTOCOL.md). Making bass effects usable
   would need a firmware patch, which this project does not attempt.

## Memory per effect instance

The ctx[3] arena size is not hard-coded in a way that is easy to read statically, so it is measured on the hardware instead.
`effects/memprobe` is a tiny effect that beeps its own arena size: long beeps = hundreds of KB, short beeps = tens.
**Result (2026-10-11, firmware 1.30): 6 long + 8 short beeps = 680–689 KB per effect instance**, close to the
~705 KB reported for the MS-70CDR. At 44.1 kHz that is about:

| Format | Seconds of audio |
|---|---|
| mono 32-bit float | ≈ 3.9 s |
| mono 16-bit | ≈ 7.8 s |
| stereo 16-bit | ≈ 3.9 s |

(One MemProbe per patch was measured; whether two instances each get their own arena is still open.)

## Where the 200-file limit comes from

The function at `0xC0136A50` (its callers report errors under the name `ffs_format`, string at `0xC01511C8`) checks whether
the file-system area of the flash (around `0x400000`) is blank. If it is, it writes a header at `0xC00BC128`:

| Half-word | Value | Likely meaning |
|---|---|---|
| 0 | `0xAA55` | signature |
| 1 | `0x0100` | version / format |
| 2 | `4` | ? |
| 3 | **`200`** | **maximum number of directory entries** |
| 4 | `0x0400` | 1024 (sector / cluster size?) |

So the limit is a **format-time parameter of the pedal's flash file system**, written into its header when the area is
formatted (at the factory, or when the FS region is blank). It is not a menu limit, and it cannot be changed through the
file commands the app uses.

Raising it would mean reformatting the 4 MB file-system region with a larger value and re-uploading every file. That goes
through the ROM erase/write path of firmware-update mode, which this project deliberately does not implement.
It is also unknown whether the directory area has room for more entries, and whether the firmware's in-RAM effect tables
accept more than ~200 effects. The effect index (`FLST_SEQ.ZDT`, 4108 bytes) would hold about 250. Not attempted: the
risk of leaving the pedal without a usable file system is high.
