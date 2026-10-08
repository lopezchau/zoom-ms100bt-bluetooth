# ZOOM MS-100BT Bluetooth protocol

This document describes how the ZOOM MS-100BT MultiStomp talks over Bluetooth and how its
internal file system (effects, effect index) can be read and written with SysEx messages.

The protocol was first reconstructed by disassembling the i386 slice of
`ZOOM MS-100BT System v1.30 Updater.app` (a 2013 binary), then checked step by step against a
real pedal. Everything under [Findings confirmed on hardware](#findings-confirmed-on-hardware)
was tested on an actual MS-100BT; the earlier sections describe what the official updater does.

Related files: [README.md](../README.md), [AVAILABLE-EFFECTS.md](AVAILABLE-EFFECTS.md),
[PEDAL-EFFECTS.md](PEDAL-EFFECTS.md), [`tools/zdlinfo.py`](../tools/zdlinfo.py),
[`tools/flst.py`](../tools/flst.py).

## Transport

- Classic Bluetooth, **Serial Port** profile (SDP UUID `0x1101`) → RFCOMM channel.
- The pedal must be in **MENU → Bluetooth → PAIRING** (as in the official update guide).
- **Raw MIDI SysEx bytes** are sent, with no extra framing. Outgoing data is split according to the channel MTU.
- Receiving: bytes are accumulated until the last one is `F7`. Messages are then dispatched by header:
  - `F0 52 xx 5D|5E …` → ZOOM message (other model IDs are ignored)
  - `F0 7E xx 06 …` → universal reply (identity)
- 5 s timeout per message, with up to 5 retries.

## Messages sent by the updater (`dev` = model ID, 0x5D or 0x5E)

| State | Message | Bytes |
|---|---|---|
| 1 | Identity request | `F0 7E 00 06 01 F7` |
| 2 | FS function 6 | `F0 52 00 dev 60 06 F7` |
| 3 | Bluetooth op 5 | `F0 52 00 dev 61 05 F7` |
| 4 | Flash op 1 | `F0 52 00 dev 01 F7` |
| 5–8 | ROM erase | `makeRomEraseMessage` (regions 0x0/0xA0000, 0x1FD000, 0x400000, 0xA0000/0x100000) |
| 9–12 | ROM write | `makeRomWritePacket` |
| 13 | Flash op 4 | `F0 52 00 dev 04 F7` |
| 14 | FS ACK (result 0) | `F0 52 00 dev 60 05 00 F7` |
| 15 | FS delete file | `F0 52 00 dev 60 24 <name, 12 bytes, zero-padded> 00 F7` |
| 16 | FS write block | see below |
| 17 | FS function 2 | `F0 52 00 dev 60 02 F7` |
| 18 | FS open file | `F0 52 00 dev 60 20 <flag 32→7 bits, 5 bytes> 00×5 <name, 12 bytes> 00 F7` (flag = 1) |
| 19 | FS close file | `F0 52 00 dev 60 21 <handle> F7` |

**WARNING:** states 5–13 rewrite the firmware. Our tool must **never** use them.

### FS write block (function 0x23)
```
F0 52 00 dev 60 23
<handle>                      (exactly as returned by "open")
<size: 32 bits in 5 7-bit bytes, LSB first>
<8→7 encoded data>            (every 7 bytes → 1 byte holding the high bits + 7 7-bit bytes)
<CRC32 of the original data: 5 7-bit bytes, LSB first>
F7
```

### 8→7 encoding (`convert8to7`)
For each group of up to 7 bytes: first an "MSB" byte whose bit 6 belongs to the 1st byte,
bit 5 to the 2nd, and so on. Then the 7 bytes with their high bit stripped.

### 32-bit integer → 7-bit (`convert32to7`)
5 bytes: `v & 7F, (v>>7) & 7F, (v>>14) & 7F, (v>>21) & 7F, v>>28`.

## Responses

- **Identity:** `F0 7E ch 06 02 52 <ID> 00 <mode> … F7`. ID 0x5D/0x5E is accepted; any other ID →
  "Illegal device connected". Byte 8 is the mode (0, 1 or other).
- **ZOOM** `F0 52 00 dev <func> <sub> …`:
  - func `00` → response code in byte 5 (0 = OK; advances the ROM write)
  - func `60` (FS):
    - sub `03` → reply to open; bytes 6–10 are a 32-bit value in 7-bit form (handle, or an error if 0 or 0xFA)
    - sub `04` → "data send code" (flow control during writes)
    - sub `05` → ACK; byte 6 is the result (0 = OK)
  - func `61` (Bluetooth): sub `08` → 7 bytes in 8→7 format

### FS "data send" responses (sub 04): `F0 52 00 dev 60 04 <func> …`

Indices count from the `F0`.
- func `02` (reply to "FS info") → bytes 20–24: `maxFFSWriteSize` (32 bits in 7-bit form). This is the write block size.
- func `20` (reply to "open") → bytes 11–15: 5-byte **handle**, copied verbatim into write and close.
- func `23` (reply to "write") → advances progress by one block.

## Communication engine (`executeCommunication`)

Each step works like this:
- The state's message is sent and the reply is awaited for up to 5 s. If none arrives, it is retried up to 5 times.
- If the reply is "busy", the message is resent up to `txErrCount` times, waiting `txErrWaitTime` between attempts.
- Errors: FS ACK 3/0xFF and response 0x0C/0xFF show the "low battery" warning. FS ACK 1 with retries exhausted gives "transfer error".

An **FS handshake** (`executeFsHandShake`) is the operation's message followed by `F0 52 00 dev 60 05 00 F7` (state 14). Both expect a reply. zoom-zt2 does exactly the same: it sends `60 05 00` after every operation.

## CRC32
Initial value 0xFFFFFFFF, standard table and **no final XOR**, i.e. `zlib.crc32(data) ^ 0xFFFFFFFF`.
Identical to zoom-zt2.

## Full updater flow in normal mode (mode byte = 1)

1. State 1: identity.
2. State 2: `60 06`, resent up to 100 times every 50 ms until the pedal accepts it. Probably "prepare file system".
3. State 3: `61 05` (Bluetooth function 5, meaning unknown).
4. State 4: `F0 52 00 dev 01 F7` (meaning unknown; might prepare update mode). **Do not use without investigating it.**
5. Loads MAIN.bin and waits 0.5 s.
6. Handshake 0x11: `60 02` + `60 05 00` → obtains `maxFFSWriteSize`.
7. **For each ZDL** (`executeZdlUpdate`):
   1. State 15: delete → `60 24 <name>`
   2. Handshake 0x12: open → `60 20 01 …<name>` + `60 05 00` → handle
   3. Repeated handshake 0x10: write blocks of `maxFFSWriteSize` → `60 23 <handle> <size> <8→7 data> <crc>` + `60 05 00`
   4. State 19: close → `60 21 <handle>`
8. States 5–12: ROM erase and write (firmware). **This is where we stop.**

ZDL installation happens in **normal mode**, before the firmware is touched, and uses only file operations.
It was unclear whether steps 2–4 are needed for the file system to respond; this was checked with read-only operations (see below: they are not needed).

## Additional FS commands known from zoom-zt2 (G1 Four / MS Plus)

These are read-only and not used by the updater. They were later tested on the MS-100BT (see below).

| Bytes | Use |
|---|---|
| `60 25 00 00 <pattern> 00` | find first file (`*` = all); sub 04 reply with the name in bytes 15–27 |
| `60 26 00 00 <pattern> 00` | find next |
| `60 27` | end the search |
| `60 29 00 00 00 00 00` | disk space: bytes 11–15 total, 16–20 free (7-bit, LSB first) |
| `60 20 02 …<name> 00` | open for **reading** |
| `60 22 …` | read block |
| `60 09` | sent after closing |

In zoom-zt2, "open for writing" is `60 20 01 00×9 <name> 00` (same format as the updater: 5-byte flag + 5 bytes of padding) and the write handle is `40 00 00 00 00`.

## .ZDL file format

A `SIZE` / `INFO` header with `"ZOOM EFFECT DLL SYSTEM VER 1.00"`, followed by an ELF
(DSP code). It is the same format as the MS-50G / MS-60B / MS-70CDR family.

Analysis of `LINESEL.ZDL` (9217 bytes):
- `00000000`, then `SIZE`(8): `38 00 00 00` `b5 23 00 00`. 0x38 = 56 is the size of the INFO+header block; 0x23B5 = 9141 is the ELF size.
- `INFO`(48): system version text, then `02 01 02 00 08 00 00 02` (probably effect type/category/ID) and the version `"1.01"`.
- 32-bit little-endian ELF at offset 76, with `e_machine = 140` (**TI TMS320C6000**).
  Built with TI C6x Compiler v7.3.7 (2012). Visible parameters: `OnOff`, `LineSel`.
- Conclusion: the DSP is a TI C6000, the same one used across the MultiStomp family. Custom
  effects can be built with the TI C6000 toolchain, as the ZoomMultistompZDL project does for the MS-70CDR.

`tools/zdlinfo.py` prints the header fields and ELF dynamic-symbol dependencies of any .ZDL file
(also available as `ms100bt zdl FILE.ZDL…`).

## Findings confirmed on hardware

Test of 2026-10-08: M1 MacBook running macOS 26.6.2, pedal on SYSTEM 1.30 in MENU → Bluetooth → PAIRING.

### Connection and identity

- Bluetooth name `ZOOM MS-100BT`, device class `0x240408`. The pedal does **not** need to be paired in System Settings.
- SDP advertises two RFCOMM services:
  - channel 1 "Serial Port": opens, but **does not respond** to SysEx
  - channel 2 (unnamed, with UUID 0x1101): **this is the MIDI channel**
- Opening the channel right after the SDP query fails with `kIOReturnError` (0xE00002BC). It works when opened directly.
- Channel MTU: 503.
- Identity: TX `F0 7E 00 06 01 F7` → RX `F0 7E 00 06 02 52 5E 00 01 00 31 2E 33 30 F7`
  - model ID **0x5E**
  - mode byte **0x01** in normal operation (so 0x00 would be boot/update mode)
  - firmware version in ASCII: `"1.30"`
- Reply in under 1 s.

### File system (2026-10-08, normal mode, WITHOUT sending `60 06` / `61 05` / `01`)

The file system responds directly after the identity request. The updater's three preliminary messages **are not needed for reading**.

- `60 02` → `60 04 02 …`: `maxFFSWriteSize` in bytes 20–24 = **4096**.
- `60 05 00` → `F0 52 00 5E 60 03 00 00 00 00 00 F7`, i.e. sub 03 with value 0 = OK.
- `60 29 00×5` → total **4,143,170 bytes**, free **752,560 bytes**.
- `60 25 00 00 '*' 00` / `60 26 …` → sub 04, with the name in bytes 15–27 and the **file size in bytes 30–34** (7-bit).
  When the listing ends, sub 03 arrives with value `7A 7F 7F 7F 0F` = 0xFFFFFFFA. That is the "0xFA" the updater treats as end / "not found".
- `60 27` → sub 03 with value 0.
- **175 files** (listed in `pedal-files.txt`):
  - 101 factory files (alphabetical order), including `CMN_DRV.ZDL` (common amp driver) and `LINESEL.ZDL`.
  - `FLST_SEQ.ZDT` (4108 bytes): probably the effect list order (confirmed below).
  - `PAIR.DAT` (1024 bytes): Bluetooth pairing data. **Do not touch it.**
  - 72 effects added later (the StompShare guitar library): CLONECHO, SHIMMER, PARTICLE, HolyFLRB…
- `LINESEL.ZDL` on the pedal is **9217 bytes**, identical to the one in the updater.

### Reading files (confirmed 2026-10-08)

```
TX 60 20 02 00×9 <name> 00                    open for READING
RX 60 04 20 00 00 04 00 <handle: 00 00 00 00 00> …   (handle in bytes 11–15; on the MS-100BT it is 00×5)
TX 60 05 00            → RX 60 03 00…          ACK
repeat:
  TX 60 22 <handle 5> <requested size 5 (7-bit)>
  RX 60 04 22 00 …                             short acknowledgement (byte 7 = 00)
  TX 60 05 00
  RX 60 04 22 01 00 <lenLo> <lenHi> <8→7 data from byte 11> <CRC 5> F7   (byte 7 = 01 means data)
  TX 60 05 00            → RX 60 03 00…
  (ends when len < requested size)
TX 60 21 <handle>      → RX 60 03 00…          close
TX 60 09               → RX 60 05 00            end of file session
```
- The data block CRC is `zlib.crc32(block) ^ 0xFFFFFFFF`.
- Works with 512-byte and **4096-byte** blocks (the latter is about 2× faster: 9 KB in 1.8 s).
- Verification: `LINESEL.ZDL` read from the pedal is **byte-for-byte identical** to the updater's file (CRC32 0x80b78c37).
- The first read attempt automatically paired the pedal with macOS (it shows up in the paired-devices list).
- **Full backup** (2026-10-08): all 175 files in `backup/2026-10-08-completo/` (3.2 MB, 398 s), with
  `MANIFEST.txt` (name, size and CRC32). All sizes match the listing and every .ZDL has a valid header.
  (Made with the older prototype's `--backup` flag; today: `ms100bt backup DIR`.)

### Writing files (confirmed 2026-10-08)

`LINESEL.ZDL` (9217 bytes) was rewritten with its own content, in normal mode and without `60 06` / `61 05` / `01`:
```
TX 60 24 "LINESEL.ZDL" 00                        → RX 60 03 00×5         delete (OK)
TX 60 20 01 00×9 "LINESEL.ZDL" 00                → RX 60 04 20 … handle 00×5
TX 60 05 00                                      → RX 60 03 00×5
per block (4096, 4096, 1025):
  TX 60 23 <handle 00×5> <size 5> <8→7 data> <CRC 5>   → RX 60 04 23 00 00 04 00 <size 5> …  (size echoed)
  TX 60 05 00                                    → RX 60 03 00×5
TX 60 21 <handle>                                → RX 60 03 00×5         close
TX 60 09                                         → RX 60 05 00
```
- Block CRC = `zlib.crc32(block) ^ 0xFFFFFFFF`, same as for reading.
- 4096-byte blocks (`maxFFSWriteSize`), i.e. 4704 bytes of SysEx sent in MTU-sized (503) chunks.
- Reading it back gave an **identical** file (CRC32 0x80b78c37). The full write plus verification took about 5 s.

### `FLST_SEQ.ZDT`: effect list order and categories

A 4108-byte file made of **13-byte records** (8.3 name of up to 12 characters + NUL, zero-padded):
- `>>>\0` + `u32 category` + zeros → start of category
- `NAME.ZDL\0…` → one effect, in the order it appears on the pedal
- `<<<\0` + `u32 category` + zeros → end of category

There are categories from 0x00 to 0x1A or beyond; many are empty. Useful data up to byte 3072, zeros after that.

| Cat. | Contents (examples) |
|---|---|
| 01 | dynamics: COMP, RACKCOMP, ZNR, NOISEGTE… |
| 02 | filter: LINESEL, GEQ, AUTOWAH, SLOWFLTR… |
| 03 | drive: BOOSTER, T_SCREAM, Z_* … |
| 04 | amp: FDCOMBO, MS_1959, HW_STACK… |
| 05 | empty (bass amps on other models?) |
| 06 | modulation: TREMOLO, CHORUS, PHASER… |
| 07 | SFX: BITCRUSH, BOMBER, Z_ORGAN… |
| 08 | delay: DELAY, TAPEECHO, ICEDLY… |
| 09 | reverb: HALL, SHIMMER, PARTICLE, PLATE… |

StompShare effects appear at the end of their category. This suggests that, for a new effect to
show up in the menu, **the .ZDL must be uploaded and its name must also be inserted into `FLST_SEQ.ZDT`** under the right category.
At this point it was a reasonable hypothesis, still to be confirmed (the Z_SYN install below confirmed it).

`tools/flst.py` parses and edits this file (`ms100bt index FLST_SEQ.ZDT` prints it); see also [AVAILABLE-EFFECTS.md](AVAILABLE-EFFECTS.md).

### Installing a new effect (2026-10-08): Z_SYN from the MS-60B

1. `Z_SYN.ZDL` (14,097 B, 4 blocks) was written and verified with CRC32 5f19a8d2.
   The preliminary delete replied `60 03 7A 7F 7F 7F 0F` (0xFFFFFFFA = does not exist), which is harmless.
2. `FLST_SEQ.ZDT` was written with `Z_SYN.ZDL` appended to the end of category 07 and verified with CRC32 b832cbf8.
   - **The handle is not always 00×5:** when opening FLST_SEQ.ZDT the pedal returned `54 26 46 28 0E`. Always use the handle returned by "open".
3. **Result: confirmed by the user.** After a restart, Z_SYN appears in the SFX category and works.
   This is the first effect from another pedal (MS-60B) installed on an MS-100BT from a Mac, without StompShare.

### Firmware 1.30 (`MAIN.bin`, 496,212 B), analysed without sending it to the pedal

- **Not compressed:** it is a TI boot image with a `TIPA` header and records `<type> "YSX" <addr u32> <len u32> <data>`.
  Type 01 is a section and type 06 is the entry point (`0xC0145400`). The high entropy (~6.8) comes from dense C674x code.
- Sections: internal L2 (`0x11817000`…), code in DDR (`0xC00E1640`, 427 KB) and data (`0xC0149AA0`, 40 KB).
  It contains TI SYS/BIOS, a Bluetooth stack with SPP and iAP profiles (`/dev/spp/`, `siAP`, `cSerial`) and the display fonts.
- The 1.30 updater flashes **only the main program** (region 0xA0000). It does not include the bootloader, presets or file system.
- **It contains no patch names.** Patches live in another memory area, outside the file system and outside this update.
- **Category name table** (offset 474,765):
  `Bypass, Dynamics, Filter/EQ, Drive, BassDrive, BassPreAmp, AgModeling, AmpModeling, BassAmpModeling,
  Modulation, SFX, Delay, Reverb, TwinFx, PedalFx, Mic` (plus several `ReserveN`).
  **The MS-100BT firmware already knows the bass categories** (BassDrive, BassPreAmp, BassAmpModeling). This is a good sign for groups B and C (see [AVAILABLE-EFFECTS.md](AVAILABLE-EFFECTS.md)).

### All Initialize and Bluetooth (2026-10-08)

- The pedal's **All Initialize** (hold knob 1 while powering on, then press the footswitch) restored the factory patches.
  **It did not remove the added effects or modify `FLST_SEQ.ZDT`**: Z_SYN remained installed.
- After the All Initialize, the RFCOMM channel returned `kIOReturnError` / `kIOReturnTimeout`: **the pedal had forgotten the pairing**.
  The fix was "Forget This Device" in macOS, then reconnecting with the pedal in PAIRING (today: `ms100bt pair`). The MIDI channel was still channel 2.
  (SDP may list the two services in a different order; the record with UUID 0x1101 still points to channel 2.)

### Batch installation (group A, batch 1)

The older prototype's `--write-many LIST` flag (now superseded by `ms100bt apply PLAN.json`) writes and verifies (full read-back) each file and stops at the first error.
Batch 1: 14 effects from the MS-60B (232 KB), all verified, plus the index (CRC32 17652ffb).

### File system limit: 200 files (2026-10-08)

Batch 2: 10 effects were written. The 11th (SPLITTER.ZDL) was **opened** (handle 00×5), but the **first write block** was rejected with
`60 03 7F 7F 7F 7F 0F` (= -1). A subsequent listing showed **exactly 200 files** with **327,200 B free**, and SPLITTER.ZDL did not exist.
→ **The file system holds at most 200 entries**, regardless of free space. No partial file was left behind.

- Those 200 include `FLST_SEQ.ZDT`, `PAIR.DAT`, `CMN_DRV.ZDL` and `LINESEL.ZDL`.
- To install more effects, others must be **deleted** (`60 24 <name>`) and removed from the index.
- Rewriting an existing file (delete and create) works even with 200 files present: the index was rewritten and verified (CRC32 3d739c0f).
- Open item at the time (older prototype): check the file count before writing a new file.

State after batch 2: 24 group A effects installed and in the index. Not installed for lack of free entries: SPLITTER, ST_B_GEQ, Z_TRON, DUAL_REV.
