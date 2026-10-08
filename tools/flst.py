#!/usr/bin/env python3
"""Lee y modifica FLST_SEQ.ZDT, el índice de efectos de los pedales ZOOM MultiStomp (ZDL).

Formato: registros de 13 bytes (nombre 8.3 + NUL, relleno con ceros).
  ">>>\\0" + u32 categoría  → inicio de categoría
  "NOMBRE.ZDL"              → efecto
  "<<<\\0" + u32 categoría  → fin de categoría
El archivo tiene un tamaño fijo (4108 bytes en el MS-100BT), con ceros al final.

Uso:
  python3 -I tools/flst.py listar FLST_SEQ.ZDT
  python3 -I tools/flst.py agregar FLST_SEQ.ZDT SALIDA.ZDT NOMBRE.ZDL CATEGORIA_HEX [NOMBRE CAT ...]
  python3 -I tools/flst.py quitar  FLST_SEQ.ZDT SALIDA.ZDT NOMBRE.ZDL
"""
import struct
import sys

REC = 13


def parse(data):
    """Devuelve una lista de (categoría, [efectos]) en orden, validando la estructura."""
    cats, cur, names = [], None, []
    end = len(data.rstrip(b"\0"))
    end += (-end) % REC
    for off in range(0, end, REC):
        r = data[off:off + REC]
        if r[:4] == b">>>\0":
            assert cur is None, f"categoría sin cerrar en {off}"
            cur, names = struct.unpack_from("<I", r, 4)[0], []
        elif r[:4] == b"<<<\0":
            cat = struct.unpack_from("<I", r, 4)[0]
            assert cat == cur, f"fin de categoría {cat} no coincide con {cur} en {off}"
            cats.append((cur, names))
            cur = None
        elif r == b"\0" * REC:
            assert cur is not None, f"registro vacío fuera de categoría en {off}"
            names.append("")
        else:
            assert cur is not None, f"efecto fuera de categoría en {off}"
            names.append(r.split(b"\0")[0].decode("ascii"))
    assert cur is None, "última categoría sin cerrar"
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
    assert len(out) <= size, f"el índice no cabe: {len(out)} > {size}"
    return bytes(out) + b"\0" * (size - len(out))


def main():
    cmd, src = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    cats = parse(data)
    assert build(cats, len(data)) == data, "el archivo no se reconstruye idéntico; formato inesperado"
    if cmd == "listar":
        for cat, names in cats:
            if any(names):
                print(f"{cat:02x}: {' '.join(n for n in names if n)}")
        print(f"(usados {len(data.rstrip(bytes(1)))} de {len(data)} bytes)")
        return
    dst, name = sys.argv[3], sys.argv[4]
    all_names = [n for _, ns in cats for n in ns]
    if cmd == "agregar":
        # admite varios pares: NOMBRE CAT [NOMBRE CAT ...]
        pairs = sys.argv[4:]
        assert len(pairs) % 2 == 0, "faltan categorías"
        for name, c in zip(pairs[0::2], pairs[1::2]):
            assert name not in all_names, f"{name} ya está en el índice"
            idx = [cc for cc, _ in cats].index(int(c, 16))
            cats[idx][1].append(name)
            all_names.append(name)
        name = " ".join(pairs[0::2])
    elif cmd == "quitar":
        assert name in all_names, f"{name} no está en el índice"
        for _, ns in cats:
            if name in ns:
                ns.remove(name)
    else:
        sys.exit(f"comando desconocido: {cmd}")
    new = build(cats, len(data))
    assert parse(new) == cats
    open(dst, "wb").write(new)
    print(f"OK: {cmd} {name} → {dst} ({len(new)} bytes)")


if __name__ == "__main__":
    main()
