#!/usr/bin/env python3
import json, os
BASE = os.path.join(os.path.dirname(__file__), '..')
CASES_JSON = os.path.join(BASE, 'expr_boundary_cases.json')
OUT = os.path.join(BASE, 'expr_boundary_cases')
GOLDEN = os.path.join(BASE, 'expr_boundary_golden')
os.makedirs(OUT, exist_ok=True)
os.makedirs(GOLDEN, exist_ok=True)

def base_lot(name, layers, fr=30, ip=0, op=60, w=100, h=100):
    return {"v":"5.5.2","fr":fr,"ip":ip,"op":op,"w":w,"h":h,"nm":name,"ddd":0,"assets":[],"layers":layers}

def ks(r=33.3, p=(7,9,0), o=77, a=(0,0,0), s=(100,100,100)):
    # o is percent 0-100 in Lottie, static 77%
    return {"o":{"a":0,"k":o,"ix":11},"r":{"a":0,"k":r,"ix":10},
            "p":{"a":0,"k":list(p),"ix":2},"a":{"a":0,"k":list(a),"ix":1},
            "s":{"a":0,"k":list(s),"ix":6}}

def layer(nm, idx, ksd, ip=0, op=60):
    return {"ddd":0,"ind":idx,"ty":3,"nm":nm,"sr":1,"ks":ksd,"ao":0,"ip":ip,"op":op,"st":0,"bm":0}

def set_expr(ksd, prop, src):
    p = dict(ksd[prop]); p["x"] = src; ksd[prop] = p

data = json.load(open(CASES_JSON))
manifest = []
for section in ['scalar','vec2','opacity','program']:
    for c in data.get(section, []):
        if c.get('status') != 'pending-oracle': continue
        if c.get('kind') == 'sweep': continue
        name = c['id']
        prop = c.get('prop','r')
        static = c.get('static')
        if prop == 'p':
            st = static if isinstance(static, list) else [7,9]
            ksd = ks(r=33.3, p=(st[0], st[1], 0), o=77)
        elif prop == 'o':
            st = static if isinstance(static, (int,float)) else 77
            ksd = ks(r=33.3, p=(7,9,0), o=st)
        else:
            st = static if isinstance(static, (int,float)) else 33.3
            ksd = ks(r=st, p=(7,9,0), o=77)
        set_expr(ksd, prop, c['jsExpr'])
        fr = 10 if 'time' in c['jsExpr'] else 30
        opf = 60
        frames = [0.0]
        # time-dependent cases
        if c['id'] in ('pg_ternary_definite','pg_if_no_else'):
            fr = 10; opf = 60
            frames = [5.0, 20.0]  # time 0.5, 2.0
        elif 'time' in c['jsExpr']:
            frames = [0.0, 10.0, 20.0]
        lot = base_lot(name, [layer('L',1,ksd,op=opf)], fr=fr, ip=0, op=opf)
        with open(os.path.join(OUT, name+'.lot'), 'w') as f:
            json.dump(lot, f, separators=(',',':'))
        manifest.append({"name":name, "frames":frames, "prop":"ks."+prop, "section":section})

with open(os.path.join(OUT,'manifest.json'),'w') as f:
    json.dump({"cases":manifest}, f, indent=2)
print(len(manifest))
