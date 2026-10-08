#!/usr/bin/env python3
"""Read and modify FLST_SEQ.ZDT, the effect index of ZOOM MultiStomp (ZDL) pedals.

Format: 13-byte records (8.3 name + NUL, zero-padded).
  ">>>\\0" + u32 category  → start of category
  "NAME.ZDL"              → effect
  "<<<\\0" + u32 category  → end of category
The file has a fixed size (4108 bytes on the MS-100BT), with zeros at the end.

Usage:
  python3 -I tools/flst.py list   FLST_SEQ.ZDT
  python3 -I tools/flst.py add    FLST_SEQ.ZDT OUTPUT.ZDT NAME.ZDL CATEGORY_HEX [NAME CAT ...]
  python3 -I tools/flst.py remove FLST_SEQ.ZDT OUTPUT.ZDT NAME.ZDL

The older Spanish command names (listar, agregar, quitar) are still accepted as aliases.
"""
import struct
import sys

REC = 13

ALIASES = {"listar": "list", "agregar": "add", "quitar": "remove"}


def parse(data):
    """Return a list of (category, [effects]) in order, validating the structure."""
    cats, cur, names = [], None, []
    end = len(data.rstrip(b"\0"))
    end += (-end) % REC
    for off in range(0, end, REC):
        r = data[off:off + REC]
        if r[:4] == b">>>\0":
            assert cur is None, f"unclosed category at {off}"
            cur, names = struct.unpack_from("<I", r, 4)[0], []
        elif r[:4] == b"<<<\0":
            cat = struct.unpack_from("<I", r, 4)[0]
            assert cat == cur, f"end of category {cat} does not match {cur} at {off}"
            cats.append((cur, names))
            cur = None
        elif r == b"\0" * REC:
            assert cur is not None, f"empty record outside a category at {off}"
            names.append("")
        else:
            assert cur is not None, f"effect outside a category at {off}"
            names.append(r.split(b"\0")[0].decode("ascii"))
    assert cur is None, "last category not closed"
    return cats


def build(cats, size):
    out = bytearray()
    for cat, names in cats:
        out += b">>>\0" + struct.pack("<I", cat) + b"\0" * 5
        for n in names:
            b = n.encode("ascii")
            assert len(b) <= 12, n
            out += b + b"\0" * (REC - len(b))
        out += b"<<<\0" + struct.pack("<I", cat) + b"\0" * 5
    assert len(out) <= size, f"the index does not fit: {len(out)} > {size}"
    return bytes(out) + b"\0" * (size - len(out))


def main():
    cmd, src = sys.argv[1], sys.argv[2]
    cmd = ALIASES.get(cmd, cmd)
    data = open(src, "rb").read()
    cats = parse(data)
    assert build(cats, len(data)) == data, "the file does not rebuild identically; unexpected format"
    if cmd == "list":
        for cat, names in cats:
            if any(names):
                print(f"{cat:02x}: {' '.join(n for n in names if n)}")
        print(f"(used {len(data.rstrip(bytes(1)))} of {len(data)} bytes)")
        return
    dst, name = sys.argv[3], sys.argv[4]
    all_names = [n for _, ns in cats for n in ns]
    if cmd == "add":
        # accepts several pairs: NAME CAT [NAME CAT ...]
        pairs = sys.argv[4:]
        assert len(pairs) % 2 == 0, "missing categories"
        for name, c in zip(pairs[0::2], pairs[1::2]):
            assert name not in all_names, f"{name} is already in the index"
            idx = [cc for cc, _ in cats].index(int(c, 16))
            cats[idx][1].append(name)
            all_names.append(name)
        name = " ".join(pairs[0::2])
    elif cmd == "remove":
        assert name in all_names, f"{name} is not in the index"
        for _, ns in cats:
            if name in ns:
                ns.remove(name)
    else:
        sys.exit(f"unknown command: {cmd}")
    new = build(cats, len(data))
    assert parse(new) == cats
    open(dst, "wb").write(new)
    print(f"OK: {cmd} {name} → {dst} ({len(new)} bytes)")


if __name__ == "__main__":
    main()
