#!/usr/bin/env python3
"""FollowPath sensitivity check for C++ 1.2.0 layout dump.

Usage:
  followpath_sensitivity.py <test.lot> <dump_layout_bin> <out_dir> [w h]

Compares base layout JSONL against variants where t.p.r / t.p.a are forced to 0/1.
Uses dump_layout interface: <file.lot> <w> <h> <out.jsonl> [frames...]
"""
import json, subprocess, sys, copy, pathlib

lot_path = sys.argv[1]
dump_bin = sys.argv[2]
out_dir = pathlib.Path(sys.argv[3])
w = int(sys.argv[4]) if len(sys.argv) > 4 else 500
h = int(sys.argv[5]) if len(sys.argv) > 5 else 500
out_dir.mkdir(parents=True, exist_ok=True)

doc = json.load(open(lot_path))

def frames_of(d):
    ip, op = float(d.get('ip', 0)), float(d.get('op', 0))
    fs = {ip, max(ip, op - 1), ip + (op-ip)*0.25, ip + (op-ip)*0.5, ip + (op-ip)*0.75}
    for l in d.get('layers', []):
        if l.get('ty') != 5: continue
        def walk(o):
            if isinstance(o, dict):
                if 't' in o and isinstance(o['t'], (int,float)) and 's' in o:
                    fs.add(float(o['t']))
                for v in o.values(): walk(v)
            elif isinstance(o, list):
                for v in o: walk(v)
        walk(l.get('t', {}).get('p', {}))
    # clamp to [ip, op-1]
    return sorted(max(ip, min(op-1, f)) for f in fs)

def run(d, tag, frames):
    p = out_dir / f"{tag}.lot"
    out = out_dir / f"{tag}.jsonl"
    json.dump(d, open(p, 'w'))
    cmd = [dump_bin, str(p), str(w), str(h), str(out)] + [str(f) for f in frames]
    subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return out.read_bytes()

frames = frames_of(doc)
base = run(doc, 'base', frames)
base2 = run(doc, 'base_repeat', frames)
if base != base2:
    print('ABORT: non-deterministic base')
    sys.exit(2)

report = {'frames': frames, 'variants': {}, 'deterministic': True}
for field, tag in [('r', 'reversePath'), ('a', 'forceAlignment')]:
    changed_any = False
    for v in [0, 1]:
        dd = copy.deepcopy(doc)
        for l in dd.get('layers', []):
            if l.get('ty') == 5 and 'p' in l.get('t', {}):
                l['t']['p'][field] = {'a': 0, 'k': v}
        out = run(dd, f'{tag}_{v}', frames)
        changed = out != base
        changed_any = changed_any or changed
        report['variants'][f'{tag}={v}'] = {'changed': changed}
    report[tag] = 'IMPLEMENTAR' if changed_any else 'WARNING_CONTADO'

report['pathLength'] = 'REVISAR_A_MANO: no es campo de entrada; revisar uso en updateLocalFont/updateTextRange'
(out_dir / 'report.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
