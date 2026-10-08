# Writing your own effects

`effects/` holds original effects for the MS-100BT (and the other ZDL MultiStomps), written so that the
**same C file** builds for the pedal's TI C674x DSP and for a Mac, where it processes WAV files.

```
effects/
├── common/zdl_fx.h        portable entry macros, arena access, safe math helpers
├── tools/fx.py            preview (Mac, WAV) and build (pedal, .ZDL)
├── tools/host.c           WAV harness: runs the effect in 8-sample blocks like the DSP
└── revecho/               RevEcho — reverse echo (Time, Feedback, Tone, Mix)
```

## Requirements

- **Preview:** only the Xcode Command Line Tools (`cc`).
- **Build:**
  - TI **C6000 Code Generation Tools** 8.3.15 for macOS. Download it from ti.com/tool/C6000-CGT; it runs on Apple Silicon under Rosetta 2.
  - A clone of [themanro/ZoomMultistompZDL](https://github.com/themanro/ZoomMultistompZDL). Its Python linker turns the compiled
    object into a `.ZDL`. Its `previews/audio/dry_*.wav` files are the default test inputs.

## Workflow

```bash
python3 effects/tools/fx.py preview effects/revecho Time=80 Feedback=60 --tag long
```

```bash
python3 effects/tools/fx.py build effects/revecho
```

Then drag `effects/revecho/build/RevEcho.ZDL` onto the pedal in MS-100BT Manager. Test it on a patch you don't care about.

`build` refuses code that calls runtime helpers the pedal lacks (division, float→unsigned casts, modulo) and
files over 32 KB. For effects with more than 2 knobs it uses handlers cloned from a stock one, as the community does.

## Rules (from the community's SAFE-DSP-RULES, all enforced or documented in `zdl_fx.h`)

- No division or modulo. Use `zdl_recip()` and power-of-two masks.
- No libm, no `double`, no `switch`, no static/const arrays used by the audio code.
- No malloc; big state lives in the per-instance arena (`ZDL_ARENA`). Check its size and clear it lazily.
- Cast floats to unsigned through `int32_t`.
- Every helper must be inlined (`ZDL_ALWAYS_INLINE`).
- At most 9 knobs, labels of 8 characters at most, a file name of 8 characters at most.

## Licensing

The effect sources here are MIT, like the rest of this repository. Built `.ZDL` files are **not** committed: the community linker
embeds small pieces of ZOOM runtime code in every effect it produces.
