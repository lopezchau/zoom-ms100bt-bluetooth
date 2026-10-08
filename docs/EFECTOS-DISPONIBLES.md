# Efectos de otros pedales que el MS-100BT no tiene

Comparación hecha el 2026-10-08 entre el respaldo del pedal (175 archivos) y dos fuentes públicas.
La comparación es **por contenido** (hash git-blob SHA-1), no solo por nombre:
- MS-50G: [UnnoTed/zoom-ms50g](https://github.com/UnnoTed/zoom-ms50g) (`efx_1_00`, 173 ZDL)
- MS-60B y otros: corpus de [repeat98/ZoomMultistompZDL](https://github.com/repeat98/ZoomMultistompZDL) (`stock_zdls/`, 830 ZDL)

## MS-50G
- **167 de 173 son idénticos byte a byte** a los del MS-100BT. Es la misma plataforma.
- Con el mismo nombre pero distinto contenido (otra versión): CRN_TRI, SHIMMER, SLAPBACK, STDELAY.
- No están en el MS-100BT: **DUAL_REV.ZDL** (DualRev, 42 339 B) y **LOFI_REV.ZDL** (LOFI Rev, 28 471 B).
- Están en el MS-100BT pero no en ese MS-50G: PARA_REV, ROUGHVER.

## MS-60B (143 archivos en el corpus)
- 61 idénticos a archivos del MS-100BT.
- 27 con el mismo nombre pero contenido distinto (variantes ajustadas para bajo).
- **55 nuevos** (886 247 B en total; el pedal tiene 752 560 B libres, así que no caben todos):

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

Grupos de interés:
- Amplificadores de bajo: SVT, HRT3500, AG_AMP, MARK_B, ACOUSTIC, _FlipTop, _GKruegr, _Heaven, _Monoton, _SMR, _SuperB.
  Probablemente requieren **CMN_BASS.ZDL**, igual que los amplificadores de guitarra usan CMN_DRV.ZDL. Grupo completo: 262 625 B.
- Sintetizadores: 4V_SYN, STDSYN, SYNTLK, V_SYN, Z_SYN, Z_TRON, B_SYNTH (105 294 B).
- Preamps / DI: BASS_PRE, AC_B_PRE, DI5, DI_PLUS. Drives de bajo: BASSDRV, BASSMUFF, B_OD, B_DIST_1, B_METAL, _BASS_TS…
- Utilidades: SPLITTER, LIMITER, DEFRET, 160_COMP, DUAL_CMP, D_COMP.

## Cabeceras
- En el MS-100BT, 151 efectos usan la cabecera estándar (56 + ELF en 76) y **22 (todos los amplificadores) usan la cabecera extendida `CABI`** (312 + ELF en 332).
  Por lo tanto, el firmware 1.30 ya entiende `CABI`.
- El corpus menciona otra variante, `BCAB` (176 bytes extra), que el MS-100BT no tiene. Los efectos que la usen quedan **por probar**.
- Byte 60 de la cabecera = categoría en `FLST_SEQ.ZDT` (LINESEL 02 = filtro, HALL 09 = reverb, FDCOMBO 04 = amplificador, CMN_DRV 0F = DLL común).

## Análisis de cabeceras y dependencias del corpus completo (830 ZDL)

Hecho con `tools/zdlinfo.py`, que lee la cabecera y la tabla de símbolos dinámicos del ELF.
Hay **82 efectos** (por nombre) que el MS-100BT no tiene. Clasificados por riesgo:

**Grupo A: cabecera estándar, sin dependencias, en categorías que el pedal ya muestra.** Es el riesgo más bajo.
- 01 dinámica: 160_COMP, DUAL_CMP, D_COMP, LIMITER
- 02 filtro: A_FILTER, BOTTOM_B, B_ATWAH, B_CRY, B_GEQ, B_PEQ, SPLITTER, ST_B_GEQ, Z_TRON
- 06 modulación: B_CHORUS, B_DETUNE, B_ENSMBL, B_FLNGR, B_OCTAVE, B_PITCH
- 07 SFX / sintes: 4V_SYN, B_SYNTH, DEFRET, STDSYN, SYNTLK, V_SYN, Z_SYN
- 08 delay: MODDLY2
- 09 reverb: LOFI_REV (DUAL_REV: la copia del MS-70CDR está truncada; la versión sin prefijo, de 42 339 B, parece completa)

**Grupo B: categorías de bajo (0C drive de bajo, 0D preamp de bajo, 14, 16).** El índice del pedal tiene esas categorías, pero vacías; no se sabe si el menú del MS-100BT las muestra.
- Las versiones del MS-60B dependen de **CMN_BASS.ZDL** (`Fx_DRV_*_KawaOD_Bass`).
- `_BASS_TS`, `_B_FZSML` y `_B_SQUEK` (0C) no dependen de nada.

**Grupo C: amplificadores de bajo (categoría 05, vacía en el pedal), con cabecera extendida `BCAB` (232).**
El MS-100BT solo tiene cabeceras `CABI` (312), así que no se sabe si el firmware 1.30 entiende `BCAB`. Es el mayor riesgo.
- SVT, HRT3500, AG_AMP, MARK_B, ACOUSTIC y B_MAN dependen de CMN_BASS.
- Los `_FLIPTOP`, `_GKRUEGR`, `_HEAVEN`, `_MONOTON`, `_SMR` y `_SUPERB` no tienen dependencias externas.

**No recomendados: categoría 0B (efectos de pedal de expresión).** PEDALWAH, PEDALVX, PEDALPIT… El MS-100BT no tiene pedal de expresión.

## Índice `FLST_SEQ.ZDT` (verificado con `tools/flst.py`)
- 32 categorías (0x00–0x1F). El archivo se reconstruye **idéntico byte a byte** a partir del modelo.
- Ocupa 3073 de 4108 bytes, así que caben unos 79 efectos más en el índice.
- No tiene CRC ni cola especial; solo ceros al final.
