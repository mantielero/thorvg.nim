## Regenerate audio_layer AOT pack. Exits 1 if output differs from committed file when --check.
import std/[os, strutils]
import exprc/[ast, lexer, parser, analysis, emitter]
import thorvg/lottie/expr/hash

const audio = """var $bm_rt;
var $bm_rt;
var veloc, amplitude, decay;
veloc = 15;
amplitude = 65;
decay = 4;
$bm_rt = $bm_rt = div(mul(amplitude, Math.sin(mul(veloc, time))), Math.exp(mul(decay, time)));"""

proc genPack(): string =
  let r = parseProgram(audio)
  if not r.ok:
    stderr.writeLine("PARSE FAIL")
    for d in r.diags: stderr.writeLine(d.msg)
    quit(1)
  if not definitiveBmRt(r.expr):
    stderr.writeLine("FAIL: audio_layer expression not definitive $bm_rt")
    quit(1)
  let h = exprHash(audio)
  let em = emitProgram(r.expr, "exprAudioLayerR")
  if not em.ok:
    stderr.writeLine("EMIT FAIL " & em.err)
    quit(1)
  result = """## Generated AOT expression pack for audio_layer. Do not edit by hand.
## Regenerate with: nim c -r --path:src --path:tools tools/exprc/gen_audio_pack.nim
import std/options
import thorvg/lottie/expr/[val, runtime]

const exprAudioLayerHash* = """ & "\"" & h & "\"" & """

""" & em.code

when isMainModule:
  let outPath = "src/generated/expr_audio_layer.nim"
  let code = genPack()
  let check = commandLineParams().contains("--check")
  if check:
    if not fileExists(outPath) or readFile(outPath) != code:
      stderr.writeLine("FAIL: " & outPath & " is stale; regenerate with tools/exprc/gen_audio_pack.nim")
      quit(1)
    echo "OK pack up to date"
  else:
    createDir(parentDir(outPath))
    writeFile(outPath, code)
    echo "wrote ", outPath
