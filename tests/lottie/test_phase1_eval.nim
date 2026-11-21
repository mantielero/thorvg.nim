import std/[json, os, strformat, math, strutils]
import thorvg/lottie/parser/parser
import thorvg/lottie/model/[model, property, common]

proc near(a, b: float; tol = 0.01): bool = abs(a-b) <= tol

proc hasExpr(j: JsonNode): bool =
  if j.kind != JObject: return false
  if j.hasKey("x"): return true
  # sometimes expression in k frames - rare
  return false

proc findLayerJson(layers: JsonNode; name: string): JsonNode =
  if layers.kind != JArray: return newJNull()
  for l in layers:
    if l.kind == JObject and l.hasKey("nm") and l["nm"].getStr("") == name:
      return l
  newJNull()

proc main() =
  let goldenDir = "tests/lottie/golden"
  let manifestPath = goldenDir / "manifest.json"
  if not fileExists(manifestPath):
    echo "no manifest"; quit(1)
  let manifest = parseFile(manifestPath)
  var ok = true
  var skippedExpr = 0
  for c in manifest["cases"]:
    let name = c["name"].getStr()
    let file = c["file"].getStr()
    echo "== ", name
    let content = readFile(file)
    let raw = parseJson(content)
    let comp = parseLottieFile(content)
    let rawLayers = if raw.kind == JObject and raw.hasKey("layers"): raw["layers"] else: newJArray()
    for fr in c["frames"]:
      let frameNo = float32(fr["frame"].getFloat())
      let propsPath = goldenDir / fr["props"].getStr()
      if not fileExists(propsPath):
        echo "  missing props ", propsPath; ok = false; continue
      let props = parseFile(propsPath)
      var used: seq[int] = @[]
      for lj in props["layers"]:
        let lname = lj["name"].getStr()
        var layer: LottieLayer = nil
        var li = -1
        for idx, l in comp.layers:
          if l.name == lname and idx notin used:
            layer = l; li = idx; break
        if li >= 0: used.add(li)
        if layer == nil:
          echo fmt"  MISS layer {lname} frame {frameNo}"
          ok = false
          continue
        if layer.transform == nil: continue
        let rawLayer = findLayerJson(rawLayers, lname)
        let ks = if rawLayer.kind == JObject and rawLayer.hasKey("ks"): rawLayer["ks"] else: newJNull()
        let p = evalPosition(layer.transform, frameNo)
        let s = evalScale(layer.transform, frameNo)
        let r = evalRotation(layer.transform, frameNo)
        let o = evalOpacity(layer.transform, frameNo)
        let ep = lj["pos"]; let es = lj["scale"]; let er = lj["rotation"].getFloat(); let eo = lj["opacity"].getFloat()
        let epx = ep[0].getFloat(); let epy = ep[1].getFloat()
        let esx = es[0].getFloat(); let esy = es[1].getFloat()
        let posExpr = ks.kind == JObject and ks.hasKey("p") and hasExpr(ks["p"])
        let scaleExpr = ks.kind == JObject and ks.hasKey("s") and hasExpr(ks["s"])
        let rotExpr = ks.kind == JObject and ks.hasKey("r") and hasExpr(ks["r"])
        let opExpr = ks.kind == JObject and ks.hasKey("o") and hasExpr(ks["o"])
        if posExpr: inc skippedExpr else:
          if not near(p.x, epx, 0.5) or not near(p.y, epy, 0.5):
            echo fmt"  DIFF {lname}@{frameNo} pos {p.x},{p.y} != {epx},{epy}"; ok = false
        if scaleExpr: inc skippedExpr else:
          if not near(s.x, esx, 0.5) or not near(s.y, esy, 0.5):
            echo fmt"  DIFF {lname}@{frameNo} scale {s.x},{s.y} != {esx},{esy}"; ok = false
        if rotExpr: inc skippedExpr else:
          if not near(r, er, 0.05):
            echo fmt"  DIFF {lname}@{frameNo} rot {r} != {er}"; ok = false
        if opExpr: inc skippedExpr else:
          if not near(float(o), eo, 1.5):
            echo fmt"  DIFF {lname}@{frameNo} op {o} != {eo}"; ok = false
  echo fmt"skippedExpr={skippedExpr}"
  if ok:
    echo "ALL OK"
  else:
    echo "DIFFERENCES FOUND"; quit(1)

when isMainModule:
  main()
