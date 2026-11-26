import std/[strutils, json, math, options]
import ../../src/thorvg/lottie/expr/[val, runtime]
import ../../src/generated/expr_audio_layer

var pass = 0
var fail = 0
var total = 0

proc nearly(a,b: float64): bool =
  if a != a and b != b: return true
  abs(a-b) <= 1e-5 + 1e-5 * abs(b)

# audio_layer: fr=60, ip=0, op=114 -> clamp to [0, 113]
for line in lines("tests/lottie/expr_golden/audio_layer_dense.jsonl"):
  if line.len == 0: continue
  let j = parseJson(line)
  let frame = j["frame"].getFloat()
  let expected = j["value"][0].getFloat()
  let f = clamp(frame, 0.0, 113.0)
  let ctx = ExprCtx(time: f / 60.0, frame: f)
  let r = exprAudioLayerR(ctx)
  inc total
  if r.isNone:
    inc fail
    echo "FAIL frame=", frame, " none"
  elif r.get().kind != vkNum:
    inc fail
    echo "FAIL frame=", frame, " not num"
  elif not nearly(r.get().num, expected):
    inc fail
    echo "FAIL frame=", frame, " got=", r.get().num, " exp=", expected
  else:
    inc pass

echo "pass=", pass, " fail=", fail, " total=", total
if fail > 0: quit(1)
