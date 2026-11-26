import std/[os, options, strutils, osproc]
import ../../src/thorvg/lottie/expr/[val, runtime, hash]
import ../../src/generated/expr_audio_layer

var pass = 0
var fail = 0
template check(name: string; cond: bool) =
  if cond: inc pass
  else: inc fail; echo "FAIL ", name

# Hash must match canonical hash of source
const audioSrc = """var $bm_rt;
var $bm_rt;
var veloc, amplitude, decay;
veloc = 15;
amplitude = 65;
decay = 4;
$bm_rt = $bm_rt = div(mul(amplitude, Math.sin(mul(veloc, time))), Math.exp(mul(decay, time)));"""
check("hash matches", exprAudioLayerHash == exprHash(audioSrc))

# Sanity eval
let r0 = exprAudioLayerR(ExprCtx(time: 0.0, frame: 0.0))
check("t0 some", r0.isSome)
if r0.isSome and r0.get().kind == vkNum:
  check("t0 == 0", abs(r0.get().num - 0.0) < 1e-9)

# Regen diff check (CI guard)
let (outp, code) = execCmdEx("/home/jose/.nimble/bin/nim c -r --hints:off --warnings:off --path:src --path:tools tools/exprc/gen_audio_pack.nim --check")
check("regen check exits 0", code == 0)
if code != 0:
  echo outp

echo "pass=", pass, " fail=", fail
if fail > 0: quit(1)
