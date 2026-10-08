#!/usr/bin/env python3
"""Build and preview custom ZDL effects.

  python3 effects/tools/fx.py preview effects/revecho [--input guitar] [Time=70 Mix=60 …] [--arena 262144] [--tail 4] [--tag name]
  python3 effects/tools/fx.py build   effects/revecho

preview  compiles the effect for this Mac (cc -DZDL_HOST) and processes WAV files exactly the way
         the DSP calls it (8-sample blocks). Output: <effect>/previews/<input>.wav
build    compiles for the pedal with TI C6000 CGT (cl6x) and links with the community linker
         (github.com/themanro/ZoomMultistompZDL, build/linker.py). Output: <effect>/build/<Name>.ZDL

Environment:
  TI_CGT_ROOT     TI C6000 compiler (default ~/ti/ti-cgt-c6000_8.3.15)
  ZDL_TOOLCHAIN   clone of themanro/ZoomMultistompZDL (default ../zdl-dev/ZoomMultistompZDL next to this repo)
  DRY_WAVS        folder with dry test WAVs (default <ZDL_TOOLCHAIN>/previews/audio, files dry_<name>.wav)
"""
import json
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
TI = Path(os.environ.get("TI_CGT_ROOT", Path.home() / "ti" / "ti-cgt-c6000_8.3.15"))
TOOLCHAIN = Path(os.environ.get("ZDL_TOOLCHAIN", REPO.parent / "zdl-dev" / "ZoomMultistompZDL"))
DRY = Path(os.environ.get("DRY_WAVS", TOOLCHAIN / "previews" / "audio"))
SIZE_LIMIT = 32_126


def load(effect_dir: Path) -> dict:
    m = json.loads((effect_dir / "manifest.json").read_text())
    name = m["effect_name"]
    assert len(name) <= 8 and name.isascii(), "effect_name must be ≤ 8 ASCII characters (8.3 file name)"
    assert len(m["params"]) <= 9, "at most 9 knobs"
    for p in m["params"]:
        assert len(p["name"]) <= 8, f"knob label too long: {p['name']}"
    return m


def knob_values(m: dict, overrides: list[str]) -> list[float]:
    vals = {p["name"].lower(): float(p["default"]) * 100.0 / p["max"] for p in m["params"]}
    for o in overrides:
        k, v = o.split("=", 1)
        assert k.lower() in vals, f"unknown knob {k}; knobs: {', '.join(p['name'] for p in m['params'])}"
        vals[k.lower()] = float(v)
    return [vals[p["name"].lower()] for p in m["params"]]


def preview(effect_dir: Path, args: list[str]) -> None:
    m = load(effect_dir)
    inputs, arena, tail, knobs, tag = [], 262144, 4.0, [], ""
    it = iter(args)
    for a in it:
        if a == "--input": inputs.append(next(it))
        elif a == "--arena": arena = int(next(it))
        elif a == "--tail": tail = float(next(it))
        elif a == "--tag": tag = "-" + next(it)
        else: knobs.append(a)
    inputs = inputs or ["guitar", "chord", "riff", "drums"]
    values = knob_values(m, knobs)
    out_dir = effect_dir / "previews"
    out_dir.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        exe = Path(tmp) / "host"
        subprocess.run(["cc", "-O2", "-std=c99", "-Wall", "-Wno-unknown-pragmas", "-DZDL_HOST",
                        f"-DEFFECT_ENTRY={m['audio_func_name']}",
                        str(effect_dir / m["source"]), str(HERE / "host.c"), "-lm", "-o", str(exe)], check=True)
        label = " ".join(f"{p['name']}={v:g}" for p, v in zip(m["params"], values))
        print(f"{m['effect_name']}: {label} · arena {arena // 1024} KB")
        for name in inputs:
            src = Path(name) if name.endswith(".wav") else DRY / f"dry_{name}.wav"
            dst = out_dir / (src.stem.replace("dry_", "") + tag + ".wav")
            r = subprocess.run([str(exe), str(src), str(dst), str(arena), str(tail), *map(str, values)],
                               capture_output=True, text=True)
            print(f"  {src.name:16s} → {dst.relative_to(REPO)}  {r.stdout.strip()}{r.stderr.strip()}")
            if r.returncode:
                sys.exit(f"preview failed for {src.name}")


def build(effect_dir: Path) -> Path:
    m = load(effect_dir)
    cl6x = TI / "bin" / "cl6x"
    assert cl6x.exists(), f"TI compiler not found at {cl6x} (set TI_CGT_ROOT)"
    assert (TOOLCHAIN / "build" / "linker.py").exists(), f"community toolchain not found at {TOOLCHAIN} (set ZDL_TOOLCHAIN)"
    out = effect_dir / "build"
    out.mkdir(exist_ok=True)
    obj = out / f"{m['effect_name'].lower()}.obj"
    flags = ["--c99", "--opt_level=2", "-mv6740", "--abi=eabi", "--mem_model:data=far",
             f"--include_path={TI / 'include'}", f"--include_path={REPO / 'effects' / 'common'}"]
    print(f"[{m['effect_name']}] cl6x {m['source']}")
    subprocess.run([str(cl6x), *flags, "-c", str(effect_dir / m["source"]), f"--output_file={obj}"], check=True, cwd=out)
    for junk in ("compiler.opt", "linker.cmd"):
        (out / junk).unlink(missing_ok=True)

    # Runtime-library helpers (division, float→unsigned casts, …) do not exist on the pedal.
    undefined = [l.split()[-1] for l in subprocess.run([str(TI / "bin" / "nm6x"), str(obj)], capture_output=True,
                 text=True).stdout.splitlines() if " U " in l and l.split()[-1] != "U"]
    if undefined:
        hints = {"__c6xabi_fixfu": "float→unsigned cast: cast through int32_t first",
                 "__c6xabi_divf": "float division: multiply by zdl_recip(x)",
                 "__c6xabi_divu": "integer division: use shifts / power-of-two masks",
                 "__c6xabi_remu": "modulo: use power-of-two masks or compare-and-wrap"}
        sys.exit("unsupported runtime calls: " + "; ".join(f"{u} ({hints.get(u, 'remove it')})" for u in undefined))

    # Every function the audio path uses must have been inlined into .audio; anything left in
    # .text would be reached by a CALL and freezes the DSP (community finding).
    sections = subprocess.run([str(TI / "bin" / "ofd6x"), "--obj_display=none,sections", str(obj)],
                              capture_output=True, text=True).stdout
    text_sizes = [l for l in sections.splitlines() if ".text" in l and "Size" not in l]
    for l in text_sizes:
        if any(tok.startswith("0x") and int(tok, 16) > 0 for tok in l.split()[1:3]):
            print("  warning: code outside .audio:", l.strip())

    sys.path.insert(0, str(TOOLCHAIN / "build"))
    sys.path.insert(0, str(TOOLCHAIN / "src" / "airwindows" / "common"))
    from linker import LinkerConfig, link, params_from_manifest  # noqa: E402
    from custom_covers import make_cover  # noqa: E402
    zdl = out / f"{m['effect_name']}.ZDL"
    kwargs = dict(materialize_init=True, effect_name=m["effect_name"], audio_func_name=m["audio_func_name"],
                  screen_image=make_cover(m["effect_name"], [p["name"] for p in m["params"]]),
                  gid=m["gid"], fxid=m["fxid"], params=params_from_manifest(m["params"]),
                  obj_path=obj, output_path=zdl, fxid_version=m.get("fxid_version", "1.00").encode("ascii"),
                  flags_byte=1, audio_nop=m.get("audio_nop", False))
    if len(m["params"]) > 2:
        # Knobs 3+ get handlers cloned from the stock LineSel handler (hardware-proven by the
        # community with 6-knob effects such as Stasis); otherwise they would be dead NOPs.
        kwargs.update(use_object_edit_handlers=False, synthesize_linesel_edit_handlers=True,
                      synth_edit_start_index=2, knob3_blob_path="/nonexistent")
    if "dsp_cost" in m and "dsp_cost" in LinkerConfig.__dataclass_fields__:
        kwargs["dsp_cost"] = float(m["dsp_cost"])
    link(LinkerConfig(**kwargs))
    size = zdl.stat().st_size
    d = zdl.read_bytes()
    assert d[60] == m["gid"] and struct.unpack_from("<H", d, 64)[0] == m["fxid"], "header does not match the manifest"
    print(f"[{m['effect_name']}] {zdl.relative_to(REPO)} · {size} bytes" + ("  ⚠ over the 32 KB limit" if size > SIZE_LIMIT else ""))
    if size > SIZE_LIMIT:
        sys.exit("too big for the pedal")
    return zdl


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("preview", "build"):
        print(__doc__); sys.exit(2)
    target = Path(sys.argv[2]).resolve()
    (preview if sys.argv[1] == "preview" else build)(target, *([sys.argv[3:]] if sys.argv[1] == "preview" else []))
