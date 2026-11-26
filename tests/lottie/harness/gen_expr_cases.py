#!/usr/bin/env python3
"""Generate minimal .lot expression cases for Phase 1 oracle."""
import json, os, math

OUT = os.path.join(os.path.dirname(__file__), '..', 'expr_cases')
os.makedirs(OUT, exist_ok=True)

def base_lot(name, layers):
    return {"v":"5.5.2","fr":30,"ip":0,"op":90,"w":100,"h":100,"nm":name,"ddd":0,"assets":[],"layers":layers}

def null_layer(nm, idx, ks_extra=None, expr_prop=None, expr_src=None):
    ks = {
        "o":{"a":0,"k":100,"ix":11},
        "r":{"a":0,"k":0,"ix":10},
        "p":{"a":0,"k":[50,50,0],"ix":2},
        "a":{"a":0,"k":[0,0,0],"ix":1},
        "s":{"a":0,"k":[100,100,100],"ix":6}
    }
    if ks_extra:
        ks.update(ks_extra)
    if expr_prop and expr_src is not None:
        ks[expr_prop] = dict(ks[expr_prop])
        if expr_src == "":
            ks[expr_prop].pop("x", None)
        else:
            ks[expr_prop]["x"] = expr_src
    return {"ddd":0,"ind":idx,"ty":3,"nm":nm,"sr":1,"ks":ks,"ao":0,"ip":0,"op":90,"st":0,"bm":0}

CASES = []

def add(name, prop, expr, base_expr=None):
    CASES.append((name, prop, expr, base_expr))

# Core characteristics from corpus (ThorVG 1.2.0 evaluate() reads $bm_rt from global)
add("expr_time_rot", "r", "var $bm_rt = time * 10;", "")
add("expr_var_rot", "r", "var a = 5; var b = 3; var $bm_rt = a * b + time;", "")
add("expr_math_sin_rot", "r", "var $bm_rt = Math.sin(time * 2) * 45;", "")
add("expr_math_cos_rot", "r", "var $bm_rt = Math.cos(time * 2) * 45;", "")
add("expr_math_exp_rot", "r", "var $bm_rt = 10 / Math.exp(time);", "")
add("expr_bm_rt_div_mul", "r", "var $bm_rt; var $bm_rt; $bm_rt = $bm_rt = div(mul(10, Math.sin(mul(2, time))), Math.exp(mul(0.5, time)));", "")
add("expr_array_pos", "p", "var t = time; var $bm_rt = [50 + Math.sin(t * 2) * 20, 50 + Math.cos(t * 2) * 20];", "")
add("expr_array_scale", "s", "var s = 100 + Math.sin(time * 3) * 20; var $bm_rt = [s, s];", "")
add("expr_opacity", "o", "var minO = 30; var maxO = 100; var c = Math.sin(time * 2); var $bm_rt = minO + (maxO - minO) * (c + 1) / 2;", "")

for name, prop, expr, base_expr in CASES:
    lot = base_lot(name, [null_layer(name, 1, expr_prop=prop, expr_src=expr)])
    with open(os.path.join(OUT, name + '.lot'), 'w') as f:
        json.dump(lot, f, separators=(',',':'))
    base_name = name + '_base'
    lot_b = base_lot(base_name, [null_layer(base_name, 1, expr_prop=prop, expr_src=base_expr)])
    with open(os.path.join(OUT, base_name + '.lot'), 'w') as f:
        json.dump(lot_b, f, separators=(',',':'))

# Write manifest
manifest = []
for name, prop, expr, _ in CASES:
    manifest.append({"name": name, "base": name + "_base", "prop": "ks."+prop, "expr": expr})
with open(os.path.join(OUT, 'manifest.json'), 'w') as f:
    json.dump({"cases": manifest, "frames": [0, 7.5, 15, 22.5, 30, 45, 60, 89]}, f, indent=2)
print(f"wrote {len(CASES)} cases + bases to {OUT}")
