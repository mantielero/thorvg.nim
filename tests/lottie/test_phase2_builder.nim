import std/[json, os, strformat, strutils, math]
import thorvg/core/types
import thorvg/renderer/[canvas, scene, paint, render]
import thorvg/engine/cpu/renderer as swr
import thorvg/display/imageio
import thorvg/lottie/parser/parser
import thorvg/lottie/builder/builder

proc readBytes(path: string): seq[byte] =
  if not fileExists(path): return @[]
  let f = open(path, fmRead)
  defer: f.close()
  let n = f.getFileSize().int
  result.setLen(n)
  if n > 0: discard f.readBytes(result, 0, n)

proc compareSurfaceToRgba(s: RenderSurface; rgbaPath: string; tolPerChannel = 2): tuple[ok: bool, diffPixels, maxDiff: int, total: int] =
  let b = readBytes(rgbaPath)
  result.total = int(s.w * s.h)
  if b.len != result.total * 4:
    result.ok = false; result.diffPixels = result.total; result.maxDiff = 255; return
  result.ok = true
  for y in 0 ..< int(s.h):
    for x in 0 ..< int(s.w):
      let p = rgbaAt(s, x, y)
      let i = (y * int(s.w) + x) * 4
      # golden .rgba is raw ARGB8888 memory dump (little-endian bytes: B,G,R,A), premultiplied
      let ga = int(b[i+3])
      var gr = int(b[i+2]); var gg = int(b[i+1]); var gb = int(b[i+0])
      if ga > 0 and ga < 255:
        gr = min(255, (gr * 255 + ga div 2) div ga)
        gg = min(255, (gg * 255 + ga div 2) div ga)
        gb = min(255, (gb * 255 + ga div 2) div ga)
      elif ga == 0:
        gr = 0; gg = 0; gb = 0
      var over = false
      for (v, gv) in [(p.r.int, gr), (p.g.int, gg), (p.b.int, gb), (p.a.int, ga)]:
        let d = abs(v - gv)
        result.maxDiff = max(result.maxDiff, d)
        if d > tolPerChannel: over = true
      if over: inc result.diffPixels
  result.ok = result.diffPixels == 0

proc main() =
  let goldenDir = "tests/lottie/golden"
  let manifest = parseFile(goldenDir / "manifest.json")
  var pass = 0; var fail = 0; var skip = 0
  for c in manifest["cases"]:
    let name = c["name"].getStr()
    let file = c["file"].getStr()
    let w = c["w"].getInt()
    let h = c["h"].getInt()
    if not fileExists(file):
      echo "SKIP ", name, " missing file"; inc skip; continue
    let comp = parseLottieFile(readFile(file))
    comp.resourceDir = parentDir(file)
    let builder = newLottieBuilder(comp)
    var caseOk = true
    for fr in c["frames"]:
      let frameNo = float32(fr["frame"].getFloat())
      let rgbaPath = goldenDir / fr["rgba"].getStr()
      if not fileExists(rgbaPath):
        echo "  MISS ", rgbaPath; caseOk = false; continue
      discard builder.update(frameNo, float32(w), float32(h))
      let canvas = newSwCanvas(w, h)
      discard canvas.add(builder.rootScene())
      discard canvas.draw(true)
      discard canvas.sync()
      let surf = swSurface(canvas)
      let cmp = compareSurfaceToRgba(surf, rgbaPath, 2)
      if not cmp.ok:
        echo fmt"  DIFF {name}@{frameNo} diffPx={cmp.diffPixels}/{cmp.total} maxDiff={cmp.maxDiff}"
        caseOk = false
    if caseOk:
      echo "OK ", name; inc pass
    else:
      echo "FAIL ", name; inc fail
  echo fmt"pass={pass} fail={fail} skip={skip}"
  if fail > 0: quit(1)

when isMainModule:
  main()
