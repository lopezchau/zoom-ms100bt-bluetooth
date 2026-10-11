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
Result: *pending a test on the pedal*.
