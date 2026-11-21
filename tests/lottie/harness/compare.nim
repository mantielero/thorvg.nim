import std/[os, strformat, json, strutils, math]

type
  DiffResult* = object
    ok*: bool
    totalPixels*: int
    diffPixels*: int
    maxDiff*: int
    meanAbsDiff*: float

proc readBytes(path: string): seq[byte] =
  if not fileExists(path): return @[]
  let f = open(path, fmRead)
  defer: f.close()
  let n = f.getFileSize().int
  result.setLen(n)
  if n > 0:
    discard f.readBytes(result, 0, n)

proc compareRGBA*(aPath, bPath: string; tolPerChannel = 2): DiffResult =
  let a = readBytes(aPath)
  let b = readBytes(bPath)
  result.ok = true
  if a.len == 0 or b.len == 0:
    result.ok = false
    return
  if a.len != b.len:
    result.ok = false
    result.totalPixels = min(a.len, b.len) div 4
    result.diffPixels = result.totalPixels
    result.maxDiff = 255
    return
  result.totalPixels = a.len div 4
  var sumDiff = 0'i64
  for i in countup(0, a.len - 4, 4):
    var pxDiff = 0
    var over = false
    for c in 0..3:
      let d = abs(int(a[i+c]) - int(b[i+c]))
      pxDiff = max(pxDiff, d)
      sumDiff += d
      if d > tolPerChannel: over = true
    if over:
      inc result.diffPixels
    result.maxDiff = max(result.maxDiff, pxDiff)
  if result.totalPixels > 0:
    result.meanAbsDiff = sumDiff.float / (result.totalPixels * 4).float
  result.ok = result.diffPixels == 0

proc compareJsonNum(a, b: JsonNode; path: string; tol: float; ok: var bool) =
  if a.kind == JObject and b.kind == JObject:
    for k, v in a:
      if b.hasKey(k):
        compareJsonNum(v, b[k], path & "." & k, tol, ok)
      else:
        echo "  DIFF missing key ", path & "." & k
        ok = false
  elif a.kind == JArray and b.kind == JArray:
    if a.len != b.len:
      echo "  DIFF array len ", path, " ", a.len, " != ", b.len
      ok = false
    else:
      for i in 0..<a.len:
        compareJsonNum(a[i], b[i], path & "[" & $i & "]", tol, ok)
  elif a.kind in {JInt, JFloat} and b.kind in {JInt, JFloat}:
    let av = a.getFloat()
    let bv = b.getFloat()
    if abs(av - bv) > tol:
      echo fmt"  DIFF {path} {av} != {bv} (tol={tol})"
      ok = false
  elif a.kind == JString and b.kind == JString:
    if a.getStr() != b.getStr():
      echo "  DIFF ", path, " ", a.getStr(), " != ", b.getStr()
      ok = false
  elif a.kind == JBool and b.kind == JBool:
    if a.getBool() != b.getBool():
      echo "  DIFF ", path
      ok = false
  else:
    discard # ignore type mismatches for now

proc compareProps*(aPath, bPath: string; tol = 0.01): bool =
  if not fileExists(aPath) or not fileExists(bPath):
    return true # optional
  let a = parseFile(aPath)
  let b = parseFile(bPath)
  var ok = true
  compareJsonNum(a, b, "", tol, ok)
  return ok

proc compareManifest*(goldenDir: string; otherDir = ""; tolPerChannel = 2; propTol = 0.01): bool =
  let manifestPath = goldenDir / "manifest.json"
  if not fileExists(manifestPath):
    echo "manifest not found: ", manifestPath
    return false
  let m = parseFile(manifestPath)
  let baseOther = if otherDir.len == 0: goldenDir else: otherDir
  var allOk = true
  for c in m["cases"]:
    let name = c["name"].getStr()
    echo "== case ", name
    for fr in c["frames"]:
      let rel = fr["rgba"].getStr()
      let aPath = goldenDir / rel
      let bPath = baseOther / rel
      let d = compareRGBA(aPath, bPath, tolPerChannel)
      let status = if d.ok: "OK" else: "DIFF"
      echo fmt"  {status} {rel} max={d.maxDiff} diffPx={d.diffPixels}/{d.totalPixels} mean={d.meanAbsDiff:.3f}"
      if not d.ok: allOk = false
      if fr.hasKey("props"):
        let prel = fr["props"].getStr()
        let pok = compareProps(goldenDir / prel, baseOther / prel, propTol)
        if not pok:
          echo "  DIFF props ", prel
          allOk = false
  return allOk

when isMainModule:
  let args = commandLineParams()
  let golden = if args.len >= 1: args[0] else: "tests/lottie/golden"
  let other = if args.len >= 2: args[1] else: ""
  let tol = if args.len >= 3: parseInt(args[2]) else: 2
  let ok = compareManifest(golden, other, tol)
  if ok:
    echo "ALL OK"
    quit(0)
  else:
    echo "DIFFERENCES FOUND"
    quit(1)
