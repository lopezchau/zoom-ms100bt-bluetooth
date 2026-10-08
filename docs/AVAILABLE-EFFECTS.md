# Effects from other pedals that the MS-100BT does not have

Comparison made on 2026-10-08 between the pedal backup (175 files) and two public sources.
The comparison is **by content** (git-blob SHA-1 hash), not just by name:
- MS-50G: [UnnoTed/zoom-ms50g](https://github.com/UnnoTed/zoom-ms50g) (`efx_1_00`, 173 ZDL)
- MS-60B and others: the corpus in [repeat98/ZoomMultistompZDL](https://github.com/repeat98/ZoomMultistompZDL) (`stock_zdls/`, 830 ZDL)

See also [PROTOCOL.md](PROTOCOL.md) for the file system and `FLST_SEQ.ZDT` format.

## MS-50G
- **167 of 173 are byte-for-byte identical** to the MS-100BT's. It is the same platform.
- Same name but different content (another version): CRN_TRI, SHIMMER, SLAPBACK, STDELAY.
- Not on the MS-100BT: **DUAL_REV.ZDL** (DualRev, 42,339 B) and **LOFI_REV.ZDL** (LOFI Rev, 28,471 B).
- On the MS-100BT but not in that MS-50G set: PARA_REV, ROUGHVER.

## MS-60B (143 files in the corpus)
- 61 identical to MS-100BT files.
- 27 with the same name but different content (variants tuned for bass).
- **55 new** (886,247 B in total; the pedal has 752,560 B free, so they do not all fit):

```
  160_COMP.ZDL       14126
  4V_SYN.ZDL         14597
  ACOUSTIC.ZDL       16256
  AC_B_PRE.ZDL       15062
  AG_AMP.ZDL         18214
  A_FILTER.ZDL       14273
  BASSDRV.ZDL        14030
  BASSMUFF.ZDL       12006
  BASS_BB.ZDL        12935
  BASS_PRE.ZDL       13956
  BOTTOM_B.ZDL       11541
  B_ATWAH.ZDL        13949
  B_BOOST.ZDL        12633
  B_CHORUS.ZDL       13763
  B_CRY.ZDL          13819
  B_DETUNE.ZDL       17700
  B_DIST_1.ZDL       11684
  B_ENSMBL.ZDL       14872
  B_FLNGR.ZDL        17489
  B_GEQ.ZDL          12702
  B_MAN.ZDL          18492
  B_METAL.ZDL        11630
  B_OCTAVE.ZDL       10582
  B_OD.ZDL           10992
  B_PEQ.ZDL          13055
  B_PITCH.ZDL        21961
  B_SYNTH.ZDL        17047
  CMN_BASS.ZDL       14571
  DEFRET.ZDL         13986
  DI5.ZDL            15309
  DI_PLUS.ZDL        17141
  DUAL_CMP.ZDL       12144
  D_COMP.ZDL         11376
  HRT3500.ZDL        17071
  LIMITER.ZDL        12364
  LOFI_REV.ZDL       28471
  MARK_B.ZDL         16268
  MODDLY2.ZDL        15574
  SPLITTER.ZDL       13083
  STDSYN.ZDL         16289
  ST_B_GEQ.ZDL       13067
  SVT.ZDL            16081
  SYNTLK.ZDL         15724
  V_SYN.ZDL          14336
  Z_SYN.ZDL          14097
  Z_TRON.ZDL         13204
  _BASS_TS.ZDL       14209
  _B_FZSML.ZDL       14210
  _B_SQUEK.ZDL       14142
  _FlipTop.ZDL       27987
  _GKruegr.ZDL       27728
  _Heaven.ZDL        26886
  _Monoton.ZDL       29614
  _SMR.ZDL           23649
  _SuperB.ZDL        28300
```

Groups of interest:
- Bass amps: SVT, HRT3500, AG_AMP, MARK_B, ACOUSTIC, _FlipTop, _GKruegr, _Heaven, _Monoton, _SMR, _SuperB.
  They probably require **CMN_BASS.ZDL**, just as the guitar amps use CMN_DRV.ZDL. Whole group: 262,625 B.
- Synths: 4V_SYN, STDSYN, SYNTLK, V_SYN, Z_SYN, Z_TRON, B_SYNTH (105,294 B).
- Preamps / DI: BASS_PRE, AC_B_PRE, DI5, DI_PLUS. Bass drives: BASSDRV, BASSMUFF, B_OD, B_DIST_1, B_METAL, _BASS_TS…
- Utilities: SPLITTER, LIMITER, DEFRET, 160_COMP, DUAL_CMP, D_COMP.

## Headers
- On the MS-100BT, 151 effects use the standard header (56 + ELF at 76) and **22 (all the amps) use the extended `CABI` header** (312 + ELF at 332).
  So firmware 1.30 already understands `CABI`.
- The corpus mentions another variant, `BCAB` (176 extra bytes), which the MS-100BT does not have. Effects that use it are **untested**.
- Header byte 60 = category in `FLST_SEQ.ZDT` (LINESEL 02 = filter, HALL 09 = reverb, FDCOMBO 04 = amp, CMN_DRV 0F = common DLL).

## Header and dependency analysis of the full corpus (830 ZDL)

Done with `tools/zdlinfo.py`, which reads the header and the ELF dynamic symbol table.
There are **82 effects** (by name) that the MS-100BT does not have. Classified by risk:

**Group A: standard header, no dependencies, in categories the pedal already shows.** Lowest risk.
- 01 dynamics: 160_COMP, DUAL_CMP, D_COMP, LIMITER
- 02 filter: A_FILTER, BOTTOM_B, B_ATWAH, B_CRY, B_GEQ, B_PEQ, SPLITTER, ST_B_GEQ, Z_TRON
- 06 modulation: B_CHORUS, B_DETUNE, B_ENSMBL, B_FLNGR, B_OCTAVE, B_PITCH
- 07 SFX / synths: 4V_SYN, B_SYNTH, DEFRET, STDSYN, SYNTLK, V_SYN, Z_SYN
- 08 delay: MODDLY2
- 09 reverb: LOFI_REV (DUAL_REV: the MS-70CDR copy is truncated; the unprefixed 42,339 B version looks complete)

**Group B: bass categories (0C bass drive, 0D bass preamp, 14, 16).** The pedal's index has these categories, but they are empty; it is unknown whether the MS-100BT menu shows them.
- The MS-60B versions depend on **CMN_BASS.ZDL** (`Fx_DRV_*_KawaOD_Bass`).
- `_BASS_TS`, `_B_FZSML` and `_B_SQUEK` (0C) have no dependencies.

**Group C: bass amps (category 05, empty on the pedal), with the extended `BCAB` header (232).**
The MS-100BT only has `CABI` headers (312), so it is unknown whether firmware 1.30 understands `BCAB`. Highest risk.
- SVT, HRT3500, AG_AMP, MARK_B, ACOUSTIC and B_MAN depend on CMN_BASS.
- `_FLIPTOP`, `_GKRUEGR`, `_HEAVEN`, `_MONOTON`, `_SMR` and `_SUPERB` have no external dependencies.

**Not recommended: category 0B (expression-pedal effects).** PEDALWAH, PEDALVX, PEDALPIT… The MS-100BT has no expression pedal.

## `FLST_SEQ.ZDT` index (verified with `tools/flst.py`)
- 32 categories (0x00–0x1F). The file is rebuilt **byte-for-byte identical** from the model.
- It uses 3073 of 4108 bytes, so roughly 79 more effects fit in the index.
- It has no CRC or special trailer; just zeros at the end.
