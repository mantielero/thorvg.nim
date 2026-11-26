#!/usr/bin/env python3
"""
tests/lottie/harness/gen_compose_cases.py

Genera .lot minimos de capas de texto ty=5 con glyphs embebidos (ruta local de
C++: updateLocalFont) y, si se indica el harness, el volcado JSONL de C++ como
oraculo para cada caso.

Uso:
  gen_compose_cases.py <out_dir> [<dump_layout_bin>]

Con harness:  dump_layout <lot> <w> <h> <out.jsonl> [frames...]
Cada caso se vuelca dos veces y se aborta si el JSONL no es identico.

IMPORTANTE (verificar contra la matriz de docs/lottie-notes.md y tvgLottieParser.cpp):
  - j (justify): 0 izq, 1 der, 2 centro, 3-6 variantes justify segun spec Lottie.
  - m.g (grouping): 1 chars, 2 words, 3 lines, 4 all (spec Lottie).
  - selector s.b (based on): 1 chars, 2 chars sin espacios, 3 words, 4 lines.
  - selector s.sh (shape): 1 square, 2 ramp, 3 triangle, 4 round, 5 smooth.
  - selector s.t (units): 0 percentage, 1 index.
  - salto de linea en el texto: "\r".
Si algun valor difiere en C++ 1.2.0, ajustar aqui y en la matriz. No cambiar a ciegas.
"""
import copy, json, pathlib, subprocess, sys

W, H, FR, OP = 400, 200, 30, 60
FONT = "T-Reg"

# --- Glyphs embebidos: rectangulos de distinta anchura/altura para que el layout sea visible
GLYPHS = {  # ch: (advance w, altura)
    "A": (60, 70), "B": (50, 60), "C": (55, 50), "D": (65, 80),
    "W": (110, 70), " ": (30, 0),
}

def rect_shape(w, h):
    # Glyph shapes: path only. C++ textShape() casts group children to LottiePath;
    # including fl/stroke causes UB/crash. Fill is applied from text doc color.
    x0, x1, y0 = 5, w - 5, -h
    v = [[x0, y0], [x1, y0], [x1, 0], [x0, 0]]
    z = [[0, 0]] * 4
    return [{"ty": "gr", "it": [
        {"ind": 0, "ty": "sh", "ks": {"a": 0, "k": {"i": z, "o": z, "v": v, "c": True}}},
    ]}]

def chars():
    out = []
    for ch, (w, h) in GLYPHS.items():
        out.append({"ch": ch, "size": 100, "style": "Reg", "w": w, "fFamily": "T",
                    "data": {"shapes": rect_shape(w, h) if h else []}})
    return out

def prop(v):  # propiedad estatica
    return {"a": 0, "k": v}

def animated(kfs):  # keyframes lineales [(t, valor)]
    out = []
    for i, (t, v) in enumerate(kfs):
        k = {"t": t, "s": v if isinstance(v, list) else [v]}
        if i < len(kfs) - 1:
            k["i"] = {"x": [1], "y": [1]}; k["o"] = {"x": [0], "y": [0]}
        out.append(k)
    return {"a": 1, "k": out}

def selector(start=0, end=100, offset=0, based=1, shape=1, units=1, amount=100):
    # t = expressible (bool, 0/1), r = rangeUnit (Percent=1, Index=2) per C++ 1.2.0
    return {"t": 0, "xe": prop(0), "ne": prop(0), "a": prop(amount), "b": based,
            "rn": 0, "sh": shape, "r": units, "sm": prop(100),
            "s": start if isinstance(start, dict) else prop(start),
            "e": prop(end), "o": offset if isinstance(offset, dict) else prop(offset)}

def animator(sel, **props):
    base = {}
    for k, v in props.items():
        base[k] = v if isinstance(v, dict) else prop(v)
    return {"nm": "Animator 1", "s": sel, "a": base}

def lot(text, *, size=50, j=0, tr=0, lh=60, group=4, anchor=(0, 0), box=None,
        animators=None, ks=None):
    s = {"s": size, "f": FONT, "t": text, "j": j, "tr": tr, "lh": lh, "ls": 0,
         "fc": [1, 0.2, 0.2]}
    if box:  # (x, y, w, h)
        s["ps"] = [box[0], box[1]]; s["sz"] = [box[2], box[3]]
    return {
        "v": "5.7.0", "fr": FR, "ip": 0, "op": OP, "w": W, "h": H, "ddd": 0, "assets": [],
        "fonts": {"list": [{"fName": FONT, "fFamily": "T", "fStyle": "Reg", "ascent": 75}]},
        "chars": chars(),
        "layers": [{
            "ddd": 0, "ind": 1, "ty": 5, "nm": "t", "sr": 1, "ao": 0, "ip": 0, "op": OP, "st": 0, "bm": 0,
            "ks": ks or {"o": prop(100), "r": prop(0), "p": prop([40, 100, 0]),
                         "a": prop([0, 0, 0]), "s": prop([100, 100, 100])},
            "t": {"d": {"k": [{"s": s, "t": 0}]}, "p": {},
                  "m": {"g": group, "a": prop(list(anchor))},
                  "a": animators or []},
        }],
    }

def one(**kw):  # un solo glifo, grouping All salvo que se indique
    return lot("A", **kw)

CASES = {}   # nombre -> (lot, frames)
F0 = [0]

# Casos base sin animator: referencia de sensibilidad (ver comprobacion en main)
MULTI = "AB CD\rAB CD"
CASES["base_single"] = (one(), F0)
CASES["base_multi"]  = (lot(MULTI, group=4, anchor=(10, 5)), F0)
CASES["base_range"]  = (lot("ABCDA"), F0)

# Propiedades aisladas (el oraculo dice cual es el efecto de cada una)
# Nota: text range animator style en C++ 1.2.0 soporta p,s,r,o,fc,fo,sc,so,sw,t,ls;
# NO soporta anchor (a). No agregar anchor aqui.
def single(**props):
    return one(animators=[animator(selector(), **props)])
CASES["single_position"] = (single(p=[30, 15]), F0)
CASES["single_rotation"] = (single(r=30), F0)
CASES["single_scale"]    = (single(s=[150, 150]), F0)
CASES["single_opacity"]  = (single(o=50), F0)

# Pares y combinacion completa: delatan el orden de composicion
CASES["pair_position_rotation"] = (single(p=[30, 15], r=30), F0)
CASES["pair_position_scale"]    = (single(p=[30, 15], s=[150, 150]), F0)
CASES["pair_rotation_scale"]    = (single(r=30, s=[150, 150]), F0)
CASES["pair_opacity_scale"]     = (single(o=50, s=[150, 150]), F0)
CASES["full_pos_rot_scale"]     = (single(p=[30, 15], r=30, s=[150, 150]), F0)

# Grouping: mismo texto y mismo animator, distinto m.g (texto multi palabra y multilinea)
for g, name in ((1, "chars"), (2, "words"), (3, "lines"), (4, "all")):
    CASES[f"group_{name}"] = (lot(MULTI, group=g, anchor=(10, 5),
        animators=[animator(selector(based=1), r=15, s=[120, 120], p=[0, -10])]), F0)

# Rangos con factor intermedio
CASES["range_factor_half"]   = (lot("ABCDA", animators=[animator(selector(start=0, end=50, shape=2), p=[0, -20])]), F0)
CASES["range_triangle_edge"] = (lot("ABCDA", animators=[animator(selector(start=0, end=100, shape=3), p=[0, -20], s=[130, 130])]), F0)
CASES["range_offset_animated"] = (lot("ABCDA", animators=[animator(
    selector(start=0, end=50, shape=3, offset=animated([(0, 0), (59, 100)])), p=[0, -20])]),
    [0, 15, 30, 45, 59])

# Wrap (caja 300x120): puntos donde es facil divergir de C++
BOX = (0, 0, 300, 120)
CASES["wrap_long_word"]      = (lot("WWWW AB", box=BOX), F0)       # palabra mas larga que la caja
CASES["wrap_multi_space"]    = (lot("AB   CD   AB", box=BOX), F0)
CASES["wrap_leading_space"]  = (lot(" AB CD", box=BOX), F0)
CASES["wrap_trailing_space"] = (lot("AB CD ", box=BOX), F0)
CASES["wrap_newline"]        = (lot("AB\rCD", box=BOX), F0)
CASES["wrap_empty_line"]     = (lot("AB\r\rCD", box=BOX), F0)
CASES["wrap_exact_fit"]      = (lot("ABCD", size=50, box=(0, 0, 120, 120)), F0)
CASES["wrap_neg_tracking"]   = (lot("AB CD AB", tr=-100, box=BOX), F0)
CASES["wrap_pos_tracking"]   = (lot("AB CD AB", tr=200, box=BOX), F0)

# Justify: C++ 1.2.0 parser only handles j==1(right)->1.0, j==2(center)->0.5; 0=left default.
# j>=3 (justify-last-line variants) are not parsed by 1.2.0 - excluded to avoid false insensitivity.
for j in range(0, 3):
    CASES[f"justify_{j}"] = (lot("AB CD AB\rCD AB", j=j, box=BOX), F0)


def run_dump(binpath, lot_path, frames, out):
    cmd = [binpath, str(lot_path), str(W), str(H), str(out)] + [str(f) for f in frames]
    subprocess.run(cmd, check=True, capture_output=True, text=True)

# Casos extra: aislan grouping/selector/tracking. Modulo en el mismo dir.
import compose_extra_cases
compose_extra_cases.add_extra(CASES, lot, animator, selector, animated, MULTI, F0)

BASES = (("groupscale_", "base_multi"), ("group_", "base_multi"), ("range_", "base_range"),
         ("track_", "base_track"),
         ("single_", "base_single"), ("pair_", "base_single"), ("full_", "base_single"))

def rec_sig(path):
    sig = []
    for l in open(path):
        if not l.strip(): continue
        j = json.loads(l)
        wm = tuple(round(x, 5) for x in j["wm"])
        scalars = tuple(round(j.get(k, 0.0), 5) for k in ("opacity","rangeFactor","strokeWidth") if k in j)
        sig.append((wm, scalars))
    return sig

def insensitive(out_dir):
    """Casos cuyo oraculo coincide con el de su base: parametrizacion o flush mal."""
    dead = []
    for name in CASES:
        for prefix, base in BASES:
            if name.startswith(prefix):
                if rec_sig(out_dir / f"{name}.jsonl") == rec_sig(out_dir / f"{base}.jsonl"):
                    dead.append(f"{name} (insensible, igual que {base})")
    return dead

def main():
    out_dir = pathlib.Path(sys.argv[1]); out_dir.mkdir(parents=True, exist_ok=True)
    dump = sys.argv[2] if len(sys.argv) > 2 else None
    bad = []
    for name, (doc, frames) in CASES.items():
        p = out_dir / f"{name}.lot"
        json.dump(doc, open(p, "w"), separators=(",", ":"))
        if not dump:
            continue
        a, b = out_dir / f"{name}.jsonl", out_dir / f"{name}.repeat.jsonl"
        run_dump(dump, p, frames, a)
        run_dump(dump, p, frames, b)
        if a.read_bytes() != b.read_bytes():
            bad.append(name)
        b.unlink()
        if a.stat().st_size == 0:
            bad.append(f"{name} (oraculo vacio)")
    if dump:
        bad += insensitive(out_dir)
    print(f"{len(CASES)} casos generados en {out_dir}")
    if bad:
        sys.exit("ABORTA: no deterministas o vacios: " + ", ".join(bad))

if __name__ == "__main__":
    main()
