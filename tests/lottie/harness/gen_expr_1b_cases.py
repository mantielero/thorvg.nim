#!/usr/bin/env python3
"""Phase 1b: semantic oracle cases for ThorVG 1.2.0 expression behavior."""
import json, os
OUT = os.path.join(os.path.dirname(__file__), '..', 'expr_1b_cases')
GOLDEN = os.path.join(os.path.dirname(__file__), '..', 'expr_1b_golden')
os.makedirs(OUT, exist_ok=True)
os.makedirs(GOLDEN, exist_ok=True)

def base_lot(name, layers, fr=30, ip=0, op=30, w=100, h=100):
    return {"v":"5.5.2","fr":fr,"ip":ip,"op":op,"w":w,"h":h,"nm":name,"ddd":0,"assets":[],"layers":layers}

def ks(o=100,r=0,p=(50,50,0),a=(0,0,0),s=(100,100,100)):
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

# 1) Global state leak between properties: r assigns $bm_rt=50, o has expr with no $bm_rt
k = ks()
set_expr(k,'r','var $bm_rt = 50;')
set_expr(k,'o','var x = 1;') # no $bm_rt assignment
add('leak_r_to_o', base_lot('leak_r_to_o',[null_layer('L',1,k)]), [0,1,2], 'r sets $bm_rt=50, o has expr without $bm_rt - does o leak?')

# 1b) Same property across frames: assigns only at frame 0 condition? use time
k = ks()
set_expr(k,'r','if (time < 0.01) { $bm_rt = 99; }') # no assignment after frame 0
add('leak_frame_to_frame', base_lot('leak_frame',[null_layer('L',1,k)]), [0,0.5,1,2], 'r assigns $bm_rt only near t=0; later frames no assignment')

# 1c) $bm_rt set in one layer, next layer prop has no $bm_rt
k1=ks(); set_expr(k1,'r','var $bm_rt = 77;')
k2=ks(); set_expr(k2,'r','var y = 2;')
add('leak_layer_to_layer', base_lot('leak_ll',[null_layer('L1',1,k1),null_layer('L2',2,k2)]), [0,1], 'L1.r sets $bm_rt=77, L2.r expr no $bm_rt')

# 2) Conditional assignment
k=ks(); set_expr(k,'r','if (time > 0.5) { $bm_rt = 45; } else { $bm_rt = 10; }')
add('cond_both', base_lot('cond_both',[null_layer('L',1,k)]), [0,0.5,1,2], 'both branches assign')
k=ks(); set_expr(k,'r','if (time > 0.5) { $bm_rt = 45; }')
add('cond_missing_else', base_lot('cond_missing',[null_layer('L',1,k)]), [0,0.5,1,2], 'only if branch assigns; else no $bm_rt')

# 3) Output types
k=ks(); set_expr(k,'r','var $bm_rt = NaN;')
add('type_nan', base_lot('type_nan',[null_layer('L',1,k)]), [0], 'NaN')
k=ks(); set_expr(k,'r','var $bm_rt = Infinity;')
add('type_inf', base_lot('type_inf',[null_layer('L',1,k)]), [0], 'Infinity')
k=ks(); set_expr(k,'r','var $bm_rt = -Infinity;')
add('type_ninf', base_lot('type_ninf',[null_layer('L',1,k)]), [0], '-Infinity')
k=ks(); set_expr(k,'r','var $bm_rt = undefined;')
add('type_undef', base_lot('type_undef',[null_layer('L',1,k)]), [0], 'undefined')
k=ks(); set_expr(k,'r','var $bm_rt = true;')
add('type_bool_true', base_lot('type_bool_t',[null_layer('L',1,k)]), [0], 'bool true')
k=ks(); set_expr(k,'r','var $bm_rt = false;')
add('type_bool_false', base_lot('type_bool_f',[null_layer('L',1,k)]), [0], 'bool false')
k=ks(); set_expr(k,'r','var $bm_rt = "hello";')
add('type_string', base_lot('type_string',[null_layer('L',1,k)]), [0], 'string')
# scalar $bm_rt on vector prop (position)
k=ks(); set_expr(k,'p','var $bm_rt = 42;')
add('type_scalar_on_vec', base_lot('type_s2v',[null_layer('L',1,k)]), [0], 'scalar on position')
# array on scalar prop (rotation)
k=ks(); set_expr(k,'r','var $bm_rt = [1,2];')
add('type_array_on_scalar', base_lot('type_a2s',[null_layer('L',1,k)]), [0], 'array on rotation')

# 4) Execution errors
k=ks(); set_expr(k,'r','var $bm_rt = undefined_var + 1;')
add('err_undef_ident', base_lot('err_undef',[null_layer('L',1,k)]), [0], 'undefined identifier')
k=ks(); set_expr(k,'r','throw "boom";')
add('err_throw', base_lot('err_throw',[null_layer('L',1,k)]), [0], 'throw')

# 5) Opacity rounding borders (expr returns 0-100, ThorVG converts *2.55 -> uint8)
for val,label in [(0,'0'),(0.4,'0p4'),(49.99,'49p99'),(50,'50'),(99.9,'99p9'),(100,'100')]:
    k=ks(); set_expr(k,'o',f'var $bm_rt = {val};')
    add(f'opacity_{label}', base_lot(f'op_{label}',[null_layer('L',1,k)]), [0], f'opacity expr {val}')

with open(os.path.join(OUT,'manifest.json'),'w') as f:
    json.dump({"cases":CASES}, f, indent=2)
print(f'wrote {len(CASES)} cases to {OUT}')
