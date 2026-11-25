#!/usr/bin/env bash
set -euo pipefail

# Reproducible Phase 0 ty5 layout dump.
# Requires: /tmp/opencode/thorvg-lottie-build (meson build of upstream 1.2.0-dev, lottie+extra=lottie_exp)
# Outputs: tests/lottie/layout_golden/<case>.jsonl

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="/tmp/opencode/thorvg-lottie-build"
WORK="/tmp/opencode/thorvg-layout-upstream"
HARNESS_SRC="$ROOT/tests/lottie/harness/dump_layout.cpp"
OUTDIR="$ROOT/tests/lottie/layout_golden"

if [ ! -d "$BUILD" ]; then
  echo "missing build dir: $BUILD" >&2
  exit 1
fi

# 1) Fresh copy of upstream (never modify upstream/)
rm -rf "$WORK"
cp -a "$ROOT/upstream" "$WORK"

# 2) Apply LAYOUT_DUMP patch to copied builder
python3 - "$WORK/src/modules/lottie/tvgLottieBuilder.h" "$WORK/src/modules/lottie/tvgLottieBuilder.cpp" <<'PY'
import sys
hpath, cpath = sys.argv[1], sys.argv[2]
h=open(hpath).read()
old_h='''    float capScale, firstMargin;\n    LottieTextFollowPath* follow;\n    bool perpendicular = false;\n\n    RenderText(LottieText* text, const TextDocument& doc) : p(doc.text), nChars(strlen(p)), scale(doc.size), textScene(Scene::gen()), lineScene(Scene::gen())\n    {\n    }'''
new_h='''    float capScale, firstMargin;\n    LottieTextFollowPath* follow;\n    bool perpendicular = false;\n#ifdef LAYOUT_DUMP\n    float dumpRangeFactor = 0.0f;\n#endif\n\n    RenderText(LottieText* text, const TextDocument& doc) : p(doc.text), nChars(strlen(p)), scale(doc.size), textScene(Scene::gen()), lineScene(Scene::gen())\n    {\n    }'''
assert old_h in h
open(hpath,'w').write(h.replace(old_h,new_h))

c=open(cpath).read()
old_inc='''#include "tvgLottieTween.h"\n\n/************************************************************************/\n/* Internal Class Implementation                                        */\n/************************************************************************/'''
new_inc='''#include "tvgLottieTween.h"\n\n#ifdef LAYOUT_DUMP\n#include <cstdio>\n#include <cstring>\nstatic FILE* _layoutDumpFp = nullptr;\nstatic const char* _layoutDumpLayer = "";\nstatic float _layoutDumpFrame = 0.0f;\nextern "C" void tvg_layout_dump_set(FILE* fp) { _layoutDumpFp = fp; }\nstatic void _layoutDumpGlyph(int line, int idx, const char* ch, int chLen, float x, float y, float scale, float opacity,\n                             uint8_t fr, uint8_t fg, uint8_t fb, uint8_t sr, uint8_t sg, uint8_t sb, float strokeWidth, float rangeFactor) {\n    if (!_layoutDumpFp) return;\n    char buf[32]; int bi = 0;\n    for (int i = 0; i < chLen && bi < 28; ++i) {\n        unsigned char c = (unsigned char)ch[i];\n        if (c == '"' || c == '\\\\') { buf[bi++]='\\\\'; buf[bi++]= (char)c; }\n        else if (c == '\\n') { buf[bi++]='\\\\'; buf[bi++]='n'; }\n        else if (c == '\\r') { buf[bi++]='\\\\'; buf[bi++]='r'; }\n        else if (c >= 32 && c < 127) { buf[bi++]= (char)c; }\n        else { bi += snprintf(buf+bi, sizeof(buf)-bi, "\\\\u%04x", c); }\n    }\n    buf[bi] = 0;\n    fprintf(_layoutDumpFp, "{\\"layer\\":\\"%s\\",\\"frame\\":%.6g,\\"line\\":%d,\\"idx\\":%d,\\"char\\":\\"%s\\",\\"x\\":%.6f,\\"y\\":%.6f,\\"scale\\":%.6f,\\"opacity\\":%.6f,\\"fill\\":[%u,%u,%u],\\"stroke\\":[%u,%u,%u],\\"strokeWidth\\":%.6f,\\"rangeFactor\\":%.6f}\\n",\n        _layoutDumpLayer, _layoutDumpFrame, line, idx, buf, x, y, scale, opacity, fr,fg,fb, sr,sg,sb, strokeWidth, rangeFactor);\n}\n#endif\n\n/************************************************************************/\n/* Internal Class Implementation                                        */\n/************************************************************************/'''
assert old_inc in c
c=c.replace(old_inc,new_inc)

old_rf='''    if (text->ranges.empty()) return false;\n\n    auto& transform = ctx.lineScene->transform();\n    Point scaling = {1.0f, 1.0f};\n    Point translation = {};\n    auto rotation = 0.0f;\n    auto color = doc.color;\n    auto strokeColor = doc.stroke.color;\n    uint8_t opacity = 255, fillOpacity = 255, strokeOpacity = 255;\n    auto needGroup = false;'''
new_rf='''#ifdef LAYOUT_DUMP\n    ctx.dumpRangeFactor = 0.0f;\n#endif\n    if (text->ranges.empty()) return false;\n\n    auto& transform = ctx.lineScene->transform();\n    Point scaling = {1.0f, 1.0f};\n    Point translation = {};\n    auto rotation = 0.0f;\n    auto color = doc.color;\n    auto strokeColor = doc.stroke.color;\n    uint8_t opacity = 255, fillOpacity = 255, strokeOpacity = 255;\n    auto needGroup = false;'''
assert old_rf in c
c=c.replace(old_rf,new_rf)

old_f='''        auto f = range->factor(frameNo, float(ctx.nChars), (float)basedIdx);\n        if (tvg::zero(f)) continue;\n\n        needGroup = true;'''
new_f='''        auto f = range->factor(frameNo, float(ctx.nChars), (float)basedIdx);\n        if (tvg::zero(f)) continue;\n#ifdef LAYOUT_DUMP\n        ctx.dumpRangeFactor = f;\n#endif\n\n        needGroup = true;'''
assert old_f in c
c=c.replace(old_f,new_f)

old_lf='''void LottieBuilder::updateLocalFont(LottieLayer* layer, float frameNo, LottieText* text, const TextDocument& doc)\n{\n    RenderText ctx(text, doc);'''
new_lf='''void LottieBuilder::updateLocalFont(LottieLayer* layer, float frameNo, LottieText* text, const TextDocument& doc)\n{\n#ifdef LAYOUT_DUMP\n    _layoutDumpLayer = layer->name ? layer->name : "";\n    _layoutDumpFrame = frameNo;\n#endif\n    RenderText ctx(text, doc);'''
assert old_lf in c
c=c.replace(old_lf,new_lf)

old_dump='''            auto shape = textShape(text, frameNo, doc, glyph, ctx);\n            if (!updateTextRange(text, frameNo, shape, doc, ctx)) _commit(glyph, shape, ctx);\n            ctx.cursor.x += advance;\n            ctx.p += glyph->len;\n            ctx.idx += glyph->len;'''
new_dump='''            auto shape = textShape(text, frameNo, doc, glyph, ctx);\n            if (!updateTextRange(text, frameNo, shape, doc, ctx)) _commit(glyph, shape, ctx);\n#ifdef LAYOUT_DUMP\n            {\n                auto& m = shape->transform();\n                uint8_t fr=0,fg=0,fb=0,fa=255; shape->fill(&fr,&fg,&fb,&fa);\n                uint8_t sr=0,sg=0,sb=0,sa=255; float sw = 0.0f;\n                auto sf = shape->strokeFill();\n                if (sf) { /* gradient stroke - dump 0,0,0 */ } else { shape->strokeFill(&sr,&sg,&sb,&sa); }\n                sw = shape->strokeWidth();\n                uint8_t op = PAINT(shape)->opacity;\n                _layoutDumpGlyph(ctx.line, ctx.idx, glyph->code, glyph->len, m.e13, m.e23, m.e11, (float)op,\n                                 fr,fg,fb, sr,sg,sb, sw, ctx.dumpRangeFactor);\n            }\n#endif\n            ctx.cursor.x += advance;\n            ctx.p += glyph->len;\n            ctx.idx += glyph->len;'''
assert old_dump in c
c=c.replace(old_dump,new_dump)
open(cpath,'w').write(c)
print('patched')
PY

# 3) Compile patched builder .o using build flags
python3 - "$BUILD" "$WORK" <<'PY'
import json, re, sys, subprocess, os
build, work = sys.argv[1], sys.argv[2]
cmds=json.load(open(os.path.join(build,'compile_commands.json')))
for c in cmds:
    if c['file'].endswith('tvgLottieBuilder.cpp'):
        command=c['command']
        break
old_up='/home/jose/Documentos/src/nimlang/migration/thorvg/upstream'
command=command.replace(old_up, work)
command=command.replace('../../../home/jose/Documentos/src/nimlang/migration/thorvg/upstream', work)
command = command.replace('c++ ', 'c++ -DLAYOUT_DUMP ', 1)
command=re.sub(r'-o\s+\S+tvgLottieBuilder\.cpp\.o', '-o /tmp/opencode/tvgLottieBuilder_layout.o', command)
command=re.sub(r'-c\s+\S+tvgLottieBuilder\.cpp', '-c '+work+'/src/modules/lottie/tvgLottieBuilder.cpp', command)
subprocess.check_call(command, shell=True, cwd=build)
print('built .o')
PY

# 4) Compile harness and link
g++ -std=c++17 -O2 -I"$WORK/inc" -I"$BUILD/src" -c "$HARNESS_SRC" -o /tmp/opencode/dump_layout.o
python3 - "$BUILD" <<'PY'
import glob, os, sys, subprocess
build=sys.argv[1]
objs = sorted(glob.glob(os.path.join(build,'src/libthorvg-1.so.1.2.0.p/**/*.o'), recursive=True))
objs2=[]
for o in objs:
    if o.endswith('modules_lottie_tvgLottieBuilder.cpp.o'):
        objs2.append('/tmp/opencode/tvgLottieBuilder_layout.o')
    else:
        objs2.append(o)
objs2.append('/tmp/opencode/dump_layout.o')
with open('/tmp/opencode/link_objs.rsp','w') as f:
    for o in objs2: f.write(o+'\n')
subprocess.check_call(['g++','-O2','-o','/tmp/opencode/dump_layout','@/tmp/opencode/link_objs.rsp',
    '-Wl,--whole-archive', os.path.join(build,'src/renderer/cpu_engine/libthorvg-sw-simd.a'),
    '-Wl,--no-whole-archive','-lpthread','-ldl','-lm'], cwd=build)
print('linked')
PY

# 5) Dump selected frames (first, last, 3 intermediate, keyframes of t.d.k and t.p)
mkdir -p "$OUTDIR"
/tmp/opencode/dump_layout "$ROOT/upstream/test/res/test3.lot" 500 500 "$OUTDIR/test3.jsonl" \
  0 89.75000916443776 179.5000183288755 201 269.25002749331327 359.000036657751
/tmp/opencode/dump_layout "$ROOT/upstream/test/res/test8.lot" 500 500 "$OUTDIR/test8.jsonl" \
  0 44.75 89.5 134.25 179

echo "ok"
