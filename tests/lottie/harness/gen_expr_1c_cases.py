#!/usr/bin/env python3
"""Phase 1 prep: distinctive-statics type/error cases + array scalar rule + opacity sweep."""
import json, os
OUT = os.path.join(os.path.dirname(__file__), '..', 'expr_1c_cases')
GOLDEN = os.path.join(os.path.dirname(__file__), '..', 'expr_1c_golden')
os.makedirs(OUT, exist_ok=True)
os.makedirs(GOLDEN, exist_ok=True)

def base_lot(name, layers, fr=30, ip=0, op=30, w=100, h=100):
    return {"v":"5.5.2","fr":fr,"ip":ip,"op":op,"w":w,"h":h,"nm":name,"ddd":0,"assets":[],"layers":layers}

def ks(o=100,r=33.3,p=(7,9,0),a=(0,0,0),s=(100,100,100)):
    # distinctive statics: r=33.3, p=[7,9,0]
    return {"o":{"a":0,"k":o,"ix":11},"r":{"a":0,"k":r,"ix":10},
            "p":{"a":0,"k":list(p),"ix":2},"a":{"a":0,"k":list(a),"ix":1},
            "s":{"a":0,"k":list(s),"ix":6}}

def null_layer(nm, idx, ksd, ip=0, op=30):
    return {"ddd":0,"ind":idx,"ty":3,"nm":nm,"sr":1,"ks":ksd,"ao":0,"ip":ip,"op":op,"st":0,"bm":0}

def set_expr(ksd, prop, src):
    p=dict(ksd[prop]); p["x"]=src; ksd[prop]=p

CASES = []
def add(name, lot, frames, desc):
    path=os.path.join(OUT,name+'.lot')
    with open(path,'w') as f: json.dump(lot,f,separators=(',',':'))
    CASES.append({"name":name,"frames":frames,"desc":desc})

# Distinctive-statics type/error cases
for name, prop, expr, desc in [
    ('type_bool_true_sd','r','var $bm_rt = true;','bool true on scalar, static 33.3'),
    ('type_bool_false_sd','r','var $bm_rt = false;','bool false on scalar, static 33.3'),
    ('type_undef_sd','r','var $bm_rt = undefined;','undefined on scalar, static 33.3'),
    ('type_string_sd','r','var $bm_rt = "hello";','string on scalar, static 33.3'),
    ('type_nan_sd','r','var $bm_rt = NaN;','NaN on scalar, static 33.3'),
    ('err_undef_ident_sd','r','var $bm_rt = undef_var + 1;','undef ident, static 33.3'),
    ('err_throw_sd','r','throw "boom";','throw, static 33.3'),
    ('type_scalar_on_vec_sd','p','var $bm_rt = 42;','scalar on vector pos, static [7,9]'),
]:
    k=ks(); set_expr(k,prop,expr)
    add(name, base_lot(name,[null_layer('L',1,k)]), [0], desc)

# Array-on-scalar rule cases
for name, arr, desc in [
    ('type_arr_1_sd','[3]','single element array'),
    ('type_arr_2_sd','[1,2]','two elements'),
    ('type_arr_3_sd','[1,2,3]','three elements'),
    ('type_arr_empty_sd','[]','empty array'),
]:
    k=ks(); set_expr(k,'r',f'var $bm_rt = {arr};')
    add(name, base_lot(name,[null_layer('L',1,k)]), [0], desc)

# Opacity sweep: 0..100 step 0.1 as frame-driven expression
# Use 1001 frames? Easier: one frame per value via expression on time-mapped value.
# We'll generate a lot with op=1001 (or enough) and expression $bm_rt = frameValue mapping.
# Simpler: use time*1 with fr=1, ip=0, op=101, frames 0..100 step 0.1 -> 1001 frames.
# But dump_expr takes frame numbers; we can pass many frames.
# Alternatively make expression: $bm_rt = Math.min(100, time * 10) - not exact sweep.
# Best: generate 1001 cases? No, too many. Better: single lot, 1001 frames, expression returns frame/10? fr=10, op=1001, time=frame/fr.
# $bm_rt = time * 10 gives 0..100.1? frame 0..1000, fr=10 => time 0..100, value 0..1000. No.
# Easier: fr=10, frames 0..1000 step 1 => time 0..100, expr $bm_rt = time; gives 0..100 step 0.1. Yes.
sweep_frames = [i/10.0 for i in range(0,1001)]  # 0.0,0.1,...,100.0
k=ks(o=77); set_expr(k,'o','var $bm_rt = time * 10;') # time in seconds; fr=10 => frame 1 = 0.1s => 1.0
add('opacity_sweep', base_lot('opacity_sweep',[null_layer('L',1,k)], fr=10, ip=0, op=101), sweep_frames, 'opacity 0..100 step 0.1 via time*10, fr=10, static 77')

with open(os.path.join(OUT,'manifest.json'),'w') as f:
    json.dump({"cases":CASES}, f, indent=2)
print(f'wrote {len(CASES)} cases')
