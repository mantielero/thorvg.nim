import std/[json, os]
import thorvg/renderer/canvas
import thorvg/engine/cpu/renderer as swr
import thorvg/display/imageio
import thorvg/lottie/parser/parser
import thorvg/lottie/builder/builder

proc countNonZero(path: string; frame: float32; w,h: int): int =
  let comp = parseLottieFile(readFile(path))
  let b = newLottieBuilder(comp)
  discard b.update(frame, float32(w), float32(h))
  let cvs = newSwCanvas(w, h)
  discard cvs.add(b.rootScene())
  discard cvs.draw(true)
  discard cvs.sync()
  let surf = swSurface(cvs)
  for y in 0 ..< int(surf.h):
    for x in 0 ..< int(surf.w):
      if rgbaAt(surf, x, y).a > 0: inc result

proc main() =
  # Minimal embedded local-font text case derived from test3 (no followPath/ranges).
  let src = parseJson(readFile("upstream/test/res/test3.lot"))
  var d = src
  # keep one font, one char 'T', one text layer
  d["fonts"]["list"] = %*[d["fonts"]["list"][0]]
  var chars = %*[]
  for c in d["chars"]:
    if c["ch"].getStr("") == "T":
      chars.add(c)
      break
  d["chars"] = chars
  var layers = %*[]
  for l in d["layers"]:
    if l.getOrDefault("ty").getInt() == 5:
      var l2 = l
      l2["t"]["p"] = %*{}
      l2["t"]["a"] = %*[]
      l2["t"]["m"] = %*{"g": 1, "a": {"a": 0, "k": [0, 0]}}
      l2["t"]["d"]["k"][0]["s"]["t"] = %"T"
      l2["ks"]["p"]["k"] = %*[20, 180, 0]
      layers.add(l2)
      break
  d["layers"] = layers
  d["assets"] = %*[]
  d["w"] = %200
  d["h"] = %200
  let tmp = "/tmp/opencode/phase2_text_min.json"
  createDir("/tmp/opencode")
  writeFile(tmp, $d)
  let nz = countNonZero(tmp, 0.0'f32, 200, 200)
  echo "nonZero=", nz
  if nz <= 0:
    quit("FAIL: expected rendered text pixels")

when isMainModule:
  main()
