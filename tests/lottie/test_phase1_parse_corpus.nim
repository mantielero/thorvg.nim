import std/[os, strformat, strutils]
import thorvg/lottie/parser/parser
import thorvg/lottie/model/model

proc countShapes(objs: seq[LottieObject]): int =
  for o in objs:
    if o == nil: continue
    inc result
    if o of LottieGroup: result += countShapes(LottieGroup(o).children)

proc main() =
  let dir = "upstream/test/res"
  var ok = true
  var count = 0
  var totalShapes = 0
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let ext = splitFile(path).ext.toLowerAscii
    if ext != ".lot" and ext != ".json": continue
    # skip non-lottie jsons heuristically? try parse
    let content = readFile(path)
    if content.len == 0: continue
    try:
      let comp = parseLottieFile(content)
      inc count
      var shapes = 0
      for l in comp.layers: shapes += countShapes(l.children)
      totalShapes += shapes
      echo fmt"OK {splitFile(path).name}{ext} layers={comp.layers.len} shapes={shapes} {comp.w}x{comp.h} fr={comp.frameRate}"
    except CatchableError as e:
      let name = splitFile(path).name & ext
      echo fmt"FAIL {name}: {e.msg}"
      ok = false
  echo fmt"parsed={count} shapes={totalShapes}"
  if totalShapes == 0:
    echo "FAIL: no shapes parsed"; ok = false
  if not ok: quit(1)

when isMainModule:
  main()
