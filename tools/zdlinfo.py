#!/usr/bin/env python3
"""Lee la cabecera de archivos .ZDL de ZOOM (sin ejecutar nada) y la imprime como tabla o CSV.

Uso: python3 -I tools/zdlinfo.py [--csv] ARCHIVO.ZDL...
"""
import struct
import sys

CATS = {0x01: "dinámica", 0x02: "filtro", 0x03: "drive", 0x04: "ampli", 0x05: "ampli bajo?",
        0x06: "modulación", 0x07: "SFX", 0x08: "delay", 0x09: "reverb", 0x0F: "DLL común"}


def elf_dyn_symbols(elf):
    """Devuelve (definidos, indefinidos) de la tabla .dynsym del ELF (32 bits LE)."""
    try:
        shoff, = struct.unpack_from("<I", elf, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", elf, 0x2E)
        secs = [struct.unpack_from("<IIIIIIIIII", elf, shoff + i * shentsize) for i in range(shnum)]
    except struct.error:
        return set(), set()
    defined, undefined = set(), set()
    for s in secs:
        if s[1] != 11:  # SHT_DYNSYM
            continue
        strtab = secs[s[6]]
        for off in range(s[4], s[4] + s[5], 16):
            name_off, value, size, info, other, shndx = struct.unpack_from("<IIIBBH", elf, off)
            if not name_off:
                continue
            p = strtab[4] + name_off
            name = elf[p:elf.index(b"\0", p)].decode("latin-1")
            (undefined if shndx == 0 else defined).add(name)
    return defined, undefined


def parse(path):
    d = open(path, "rb").read()
    r = {"archivo": path.rsplit("/", 1)[-1], "bytes": len(d)}
    if d[4:8] != b"SIZE" or d[20:24] != b"INFO":
        r["error"] = "no es ZDL"
        return r
    hsize, esize = struct.unpack_from("<II", d, 12)
    elf_off = 4 + 8 + 8 + hsize
    r.update(cabecera=hsize, elf_off=elf_off, elf_decl=esize,
             truncado=len(d) < elf_off + esize,
             ext=d[0x4C:0x50].decode("latin-1") if hsize > 56 else "",
             categoria=d[60], tipo=d[61], cat_txt=CATS.get(d[60], "?"),
             version=d[68:72].split(b"\0")[0].decode("latin-1", "replace"),
             es_elf=d[elf_off:elf_off + 4] == b"\x7fELF")
    defined, undefined = elf_dyn_symbols(d[elf_off:elf_off + esize]) if r["es_elf"] else (set(), set())
    r["exporta"] = len(defined)
    r["importa"] = sorted(undefined)
    return r


if __name__ == "__main__":
    csv = "--csv" in sys.argv
    files = [a for a in sys.argv[1:] if not a.startswith("--")]
    rows = [parse(f) for f in files]
    if csv:
        print("archivo,bytes,cabecera,ext,categoria,tipo,version,truncado,importa")
        for r in rows:
            print(",".join(str(r.get(k, "")) for k in ("archivo", "bytes", "cabecera", "ext", "categoria", "tipo", "version", "truncado"))
                  + "," + " ".join(r.get("importa", [])))
    else:
        for r in rows:
            print(f"{r['archivo']:22s} {r['bytes']:7d}  cab={r.get('cabecera','?'):>3} {r.get('ext',''):4s} "
                  f"cat={r.get('categoria',0):02x}({r.get('cat_txt','?')}) tipo={r.get('tipo',0):02x} v{r.get('version','')} "
                  f"{'TRUNCADO ' if r.get('truncado') else ''}importa={len(r.get('importa', []))}")
