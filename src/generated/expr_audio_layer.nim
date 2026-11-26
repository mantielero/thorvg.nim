## Generated AOT expression pack for audio_layer. Do not edit by hand.
## Regenerate with: nim c -r --path:src --path:tools tools/exprc/gen_audio_pack.nim
import std/options
import thorvg/lottie/expr/[val, runtime]

const exprAudioLayerHash* = "7ef68f4253eeaf2b"
proc exprAudioLayerR*(ctx: ExprCtx): Option[Val] =
  var bmRt: Val = evUndef()
  var bmAssigned = false
  bmRt = evUndef()
  bmRt = evUndef()
  var veloc = evUndef()
  var amplitude = evUndef()
  var decay = evUndef()
  discard (block: veloc = evNum(15.0); veloc)
  discard (block: amplitude = evNum(65.0); amplitude)
  discard (block: decay = evNum(4.0); decay)
  discard (block: bmAssigned = true; bmRt = (block: bmAssigned = true; bmRt = bmDiv(bmMul(amplitude, evMathSin(bmMul(veloc, evNum(ctx.time)))), evMathExp(bmMul(decay, evNum(ctx.time)))); bmRt); bmRt)
  if bmAssigned: some(bmRt) else: none(Val)
