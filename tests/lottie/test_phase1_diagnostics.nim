import std/[strutils]
import thorvg/lottie/parser/parser
import thorvg/lottie/model/model

proc main() =
  # malformed JSON
  var threw = false
  try:
    discard parseLottieFile("{bad json")
  except CatchableError:
    threw = true
  doAssert threw, "malformed json should raise"

  # unsupported shape type + ctx
  let j = """{"v":"5.5","fr":30,"ip":0,"op":10,"w":10,"h":10,"layers":[
    {"ty":4,"nm":"L","ind":1,"ip":0,"op":10,"shapes":[
      {"ty":"gr","nm":"G","it":[{"ty":"zz","nm":"Zig"},{"ty":"tr"}]}
    ]}
  ]}"""
  let comp = parseLottieFile(j)
  doAssert comp.layers.len == 1
  doAssert comp.layers[0].children.len == 1
  let g = LottieGroup(comp.layers[0].children[0])
  doAssert g.children.len >= 1
  var sawZZ = false
  for w in comp.warnings:
    if w.contains("unsupported shape type 'zz'") and w.contains("layers[0]"): sawZZ = true
  doAssert sawZZ, "expected unsupported shape warning with ctx: " & $comp.warnings

  # audio layer warning
  let j2 = """{"fr":30,"ip":0,"op":10,"w":10,"h":10,"layers":[{"ty":6,"nm":"A","ind":1,"ip":0,"op":10}]}"""
  let c2 = parseLottieFile(j2)
  var sawAudio = false
  for w in c2.warnings:
    if w.contains("audio layer not supported") and w.contains("layers[0]"): sawAudio = true
  doAssert sawAudio, "expected audio warning"

  # expression warning
  let j3 = """{"fr":30,"ip":0,"op":10,"w":10,"h":10,"layers":[{"ty":4,"nm":"E","ind":1,"ip":0,"op":10,"ks":{"o":{"a":0,"k":100,"x":"var $bm_rt = 100;"}}}]}"""
  let c3 = parseLottieFile(j3)
  var sawExpr = false
  for w in c3.warnings:
    if w.contains("opacity has expression"): sawExpr = true
  doAssert sawExpr, "expected expression warning: " & $c3.warnings

  echo "ok"

when isMainModule:
  main()
