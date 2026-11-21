## Differential oracle for G2a (`gpu_path`, `gpu_dash`, `gpu_probe`).
##
##   gpucommon_dump gen <cases.txt> [seed]      writes the fixed-seed case file
##   gpucommon_dump run <cases.txt> <out.txt>   runs the Nim port on the cases
##
## `gpucommon_dump.cpp` reads the same case file, runs the ORIGINAL
## `tvgGpuCommon.cpp` and writes the same text format. Floats are exchanged as
## 8-digit hex float32 bit patterns, so the comparison is bit exact.
import std/[strutils, os, options, math, sequtils]
import thorvg/core/[types, geom, path]
import thorvg/renderer/render
import thorvg/engine/gl/[gpu_path, gpu_dash, gpu_probe]

# ------------------------------------------------------------------ text io

func hx(f: float32): string = toHex(cast[uint32](f), 8).toLowerAscii
func unhx(s: string): float32 = cast[float32](uint32(parseHexInt(s)))

func letter(c: PathCommand): char =
  case c
  of PathCommand.MoveTo: 'M'
  of PathCommand.LineTo: 'L'
  of PathCommand.CubicTo: 'C'
  of PathCommand.Close: 'Z'

func command(ch: char): PathCommand =
  case ch
  of 'M': PathCommand.MoveTo
  of 'L': PathCommand.LineTo
  of 'C': PathCommand.CubicTo
  else: PathCommand.Close

func fmtPath(p: RenderPath): string =
  var letters = ""
  for c in p.cmds: letters.add letter(c)
  result = $p.cmds.len & " " & (if letters.len == 0: "-" else: letters) & " " & $p.pts.len
  for pt in p.pts: result.add " " & hx(pt.x) & " " & hx(pt.y)

func fmtPt(p: Point): string = hx(p.x) & " " & hx(p.y)

func fmtMatrix(m: Matrix): string =
  [m.e11, m.e12, m.e13, m.e21, m.e22, m.e23, m.e31, m.e32, m.e33].mapIt(hx(it)).join(" ")

type Reader = object
  tok: seq[string]
  pos: int

proc next(r: var Reader): string =
  result = r.tok[r.pos]
  inc r.pos

proc rInt(r: var Reader): int = parseInt(r.next())
proc rF(r: var Reader): float32 = unhx(r.next())
proc rPt(r: var Reader): Point =
  result.x = r.rF()
  result.y = r.rF()

proc rMatrix(r: var Reader): Matrix =
  result.e11 = r.rF(); result.e12 = r.rF(); result.e13 = r.rF()
  result.e21 = r.rF(); result.e22 = r.rF(); result.e23 = r.rF()
  result.e31 = r.rF(); result.e32 = r.rF(); result.e33 = r.rF()

proc rPath(r: var Reader): RenderPath =
  let nc = r.rInt()
  let letters = r.next()
  if nc > 0:
    for ch in letters: result.cmds.add command(ch)
  let np = r.rInt()
  for i in 0 ..< np: result.pts.add r.rPt()

# ------------------------------------------------------------------ generator

type Rng = object
  s: uint32

proc nextU(r: var Rng): uint32 =
  r.s = r.s xor (r.s shl 13)
  r.s = r.s xor (r.s shr 17)
  r.s = r.s xor (r.s shl 5)
  r.s

proc uni(r: var Rng): float32 = float32(r.nextU() shr 8) / 16777216.0'f32
proc rng(r: var Rng, lo, hi: float32): float32 = lo + (hi - lo) * r.uni()
proc ri(r: var Rng, n: int): int = int(r.nextU() mod uint32(n))

type GenStyle = enum gsGrid, gsFloat, gsThin, gsTiny

proc coord(r: var Rng, st: GenStyle, base: Point): Point =
  case st
  of gsGrid: Point(x: float32(r.ri(21)), y: float32(r.ri(21)))
  of gsFloat: Point(x: r.rng(-50, 150), y: r.rng(-50, 150))
  of gsThin: Point(x: base.x + r.rng(-60, 60), y: base.y + r.rng(-0.12'f32, 0.12'f32))
  of gsTiny: Point(x: base.x + r.rng(-0.4'f32, 0.4'f32), y: base.y + r.rng(-0.4'f32, 0.4'f32))

proc genPath(r: var Rng): RenderPath =
  let st = GenStyle(r.ri(4))
  let base = Point(x: r.rng(0, 100), y: r.rng(0, 100))
  let contours = 1 + r.ri(3)
  var last = Point()
  for c in 0 ..< contours:
    last = r.coord(st, base)
    result.moveTo(last)
    let start = last
    for s in 0 ..< 1 + r.ri(6):
      let k = r.ri(8)
      if k < 4:
        last = if k == 0: last else: r.coord(st, base)   # k == 0: repeated point
        result.lineTo(last)
      else:
        let c1 = r.coord(st, base)
        let c2 = r.coord(st, base)
        last = if k == 7: start else: r.coord(st, base)
        result.cubicTo(c1, c2, last)
    if r.ri(2) == 0: result.cmds.add PathCommand.Close

func rectPath(x, y, w, h: float32, closeIt = true): RenderPath =
  result.moveTo(Point(x: x, y: y))
  result.lineTo(Point(x: x + w, y: y))
  result.lineTo(Point(x: x + w, y: y + h))
  result.lineTo(Point(x: x, y: y + h))
  if closeIt: result.cmds.add PathCommand.Close

proc handPaths(): seq[RenderPath] =
  result.add RenderPath()
  var p = RenderPath()
  p.moveTo(Point(x: 5, y: 5))
  result.add p
  result.add rectPath(10, 10, 100, 0.3'f32)
  result.add rectPath(10, 10, 100, 0.01'f32)
  result.add rectPath(10, 10, 0.2'f32, 80)
  result.add rectPath(10, 10, 60, 40)
  result.add rectPath(10, 10, 60, 40, false)
  p = RenderPath()
  p.moveTo(Point(x: 0, y: 0)); p.lineTo(Point(x: 100, y: 0)); p.lineTo(Point(x: 50, y: 0.2'f32))
  p.cmds.add PathCommand.Close
  result.add p
  p = RenderPath()
  p.moveTo(Point(x: 0, y: 0)); p.cubicTo(Point(x: 30, y: 0.05'f32), Point(x: 60, y: -0.05'f32), Point(x: 90, y: 0))
  result.add p
  p = RenderPath()
  p.moveTo(Point(x: 0, y: 0)); p.cubicTo(Point(x: 100, y: 100), Point(x: -50, y: 100), Point(x: 50, y: 0))
  p.cmds.add PathCommand.Close
  result.add p
  p = RenderPath()
  p.moveTo(Point(x: 1, y: 1)); p.lineTo(Point(x: 1, y: 1)); p.cmds.add PathCommand.Close
  result.add p
  p = RenderPath()
  p.moveTo(Point(x: 1, y: 1)); p.lineTo(Point(x: 9, y: 1)); p.moveTo(Point(x: 1, y: 5)); p.lineTo(Point(x: 9, y: 5))
  result.add p
  p = RenderPath()
  p.moveTo(Point(x: 0, y: 0)); p.cubicTo(Point(x: 0, y: 0), Point(x: 0, y: 0), Point(x: 0, y: 0))
  result.add p
  p = RenderPath()
  p.moveTo(Point(x: 0, y: 0)); p.cubicTo(Point(x: 10, y: 10), Point(x: 20, y: 20), Point(x: 30, y: 30))
  result.add p
  p = RenderPath()
  p.moveTo(Point(x: 0, y: 0)); p.moveTo(Point(x: 4, y: 4)); p.lineTo(Point(x: 8, y: 0))
  result.add p

proc genMatrix(r: var Rng): Matrix =
  case r.ri(6)
  of 0: IdentityMatrix
  of 1:
    let s = r.rng(0.01'f32, 4)
    Matrix(e11: s, e22: s, e33: 1)
  of 2:
    let a = r.rng(0, 6.2831853'f32)
    let c = cos(a)
    let s = sin(a)
    Matrix(e11: c, e12: -s, e13: r.rng(-20, 20), e21: s, e22: c, e23: r.rng(-20, 20), e33: 1)
  of 3:
    Matrix(e11: r.rng(-3, 3), e12: r.rng(-1, 1), e13: r.rng(-30, 30),
           e21: r.rng(-1, 1), e22: r.rng(-3, 3), e23: r.rng(-30, 30), e33: 1)
  of 4:
    Matrix(e11: r.rng(0.001'f32, 0.2'f32), e22: r.rng(0.001'f32, 0.2'f32), e33: 1)  # thin after transform
  else:
    Matrix(e11: 1, e13: r.rng(-5, 5), e22: -1, e23: r.rng(-5, 5), e33: 1)

proc genPattern(r: var Rng): seq[float32] =
  let n = r.ri(5)
  for i in 0 ..< n:
    result.add(case r.ri(4)
      of 0: 0.0'f32
      of 1: float32(1 + r.ri(8))
      else: r.rng(0.5'f32, 12))

proc wPath(o: var string, p: RenderPath) = o.add " " & fmtPath(p)

proc genCases(file: string, seed: uint32) =
  var r = Rng(s: seed)
  var o = ""
  var paths = handPaths()
  for i in 0 ..< 400: paths.add genPath(r)
  # OPT
  for p in paths:
    for k in 0 ..< 5:
      o.add "OPT " & $r.ri(2) & " " & fmtMatrix(r.genMatrix())
      o.wPath(p)
      o.add "\n"
  for i in 0 ..< 1500:
    o.add "OPT " & $r.ri(2) & " " & fmtMatrix(r.genMatrix())
    o.wPath(r.genPath())
    o.add "\n"
  # DASH
  for i in 0 ..< 2500:
    let p = if i < paths.len: paths[i] else: r.genPath()
    var pat = r.genPattern()
    if i mod 97 == 0: pat = @[0.0004'f32]
    if i mod 89 == 0: pat = @[0.0'f32, 0.0'f32]
    let apply = r.ri(2)
    let trimmed = r.ri(3) == 0
    let tb = if trimmed: r.rng(0, 0.6'f32) else: 0.0'f32
    let te = if trimmed: r.rng(0.4'f32, 1) else: 1.0'f32
    o.add "DASH " & fmtMatrix(r.genMatrix()) & " " & $apply & " " & $r.ri(3) & " " & hx(tb) & " " &
          hx(te) & " " & $r.ri(2) & " " & hx(if r.ri(3) == 0: 0.0'f32 else: r.rng(-30, 30)) & " " & $pat.len
    for v in pat: o.add " " & hx(v)
    o.wPath(p)
    o.add "\n"
  # PROBE
  for p in paths:
    o.add "PROBE"
    o.wPath(p)
    o.add "\n"
  for i in 0 ..< 1500:
    o.add "PROBE"
    o.wPath(r.genPath())
    o.add "\n"
  # CROSS
  for i in 0 ..< 1000:
    let st = GenStyle(r.ri(2))
    o.add "CROSS"
    for k in 0 ..< 4: o.add " " & fmtPt(r.coord(st, Point()))
    o.add "\n"
  # ARC / CONIC
  for i in 0 ..< 300:
    o.add "ARC " & hx(r.rng(-7, 7)) & " " & hx(if i mod 20 == 0: r.rng(0, 0.0000001'f32) else: r.rng(0, 500)) & "\n"
    o.add "CONIC " & fmtPt(Point(x: r.rng(-100, 100), y: r.rng(-100, 100))) & " " & hx(r.rng(-720, 720)) & "\n"
  # BOUNDS
  for i in 0 ..< 400:
    let x0 = int32(r.ri(200)) - 100
    let y0 = int32(r.ri(200)) - 100
    let x1 = if i mod 25 == 0: x0 - 3 else: x0 + int32(r.ri(300))
    let y1 = y0 + int32(r.ri(300))
    o.add "BOUNDS " & $x0 & " " & $y0 & " " & $x1 & " " & $y1 & " " & fmtMatrix(r.genMatrix()) & "\n"
  # MESH
  for i in 0 ..< 600:
    let nv = 3 + r.ri(8)
    let nt = 1 + r.ri(6)
    o.add "MESH " & $nv
    for k in 0 ..< nv: o.add " " & fmtPt(Point(x: float32(r.ri(21)), y: float32(r.ri(21))))
    o.add " " & $(nt * 3)
    for k in 0 ..< nt * 3: o.add " " & $r.ri(nv)
    let pt = if r.ri(2) == 0: Point(x: float32(r.ri(21)), y: float32(r.ri(21))) else: Point(x: r.rng(0, 20), y: r.rng(0, 20))
    o.add " " & fmtPt(pt) & "\n"
  for i in 0 ..< 500:
    o.add "TRI"
    for k in 0 ..< 4: o.add " " & fmtPt(Point(x: float32(r.ri(11)), y: float32(r.ri(11))))
    o.add "\n"
    o.add "QUAD"
    for k in 0 ..< 7: o.add " " & fmtPt(Point(x: float32(r.ri(11)), y: float32(r.ri(11))))
    o.add "\n"
  writeFile(file, o)

# ------------------------------------------------------------------ runner

proc probeState(p: GpuConvexProbe): string =
  $int(p.convex) & " " & $p.winding & " " & fmtPt(p.firstEdge) & " " & fmtPt(p.prevEdge) & " " &
    $p.prevXDir & " " & $p.prevYDir & " " & $p.xDirChanges & " " & $p.yDirChanges & " " &
    $p.reversals & " " & $int(p.contourHasEdges)

proc runProbe(path: RenderPath): string =
  var probe = initConvexProbe()
  var pi = 0
  var cur, first: Point
  for cmd in path.cmds:
    case cmd
    of PathCommand.MoveTo:
      probe.nextContour()
      cur = path.pts[pi]
      first = cur
      inc pi
    of PathCommand.LineTo:
      let pt = path.pts[pi]
      probe.addEdge(pt - cur)
      cur = pt
      inc pi
    of PathCommand.CubicTo:
      let c1 = path.pts[pi]
      let c2 = path.pts[pi + 1]
      let e = path.pts[pi + 2]
      let x = gpuEdgesCross(cur, c1, c2, e)
      result.add $int(x) & " "
      if x: probe.convex = false
      probe.addEdge(c1 - cur)
      probe.addEdge(c2 - c1)
      probe.addEdge(e - c2)
      cur = e
      pi += 3
    of PathCommand.Close:
      probe.addContourClose(first - cur)
      cur = first
    result.add probeState(probe) & " | "

proc runCases(inFile, outFile: string) =
  var r = Reader(tok: readFile(inFile).splitWhitespace())
  var o = ""
  while r.pos < r.tok.len:
    let op = r.next()
    o.add op
    case op
    of "OPT":
      let want = r.rInt() != 0
      let m = r.rMatrix()
      let p = r.rPath()
      let res = gpuOptimize(p, m, want)
      o.add " " & $int(res.thin) & " " & $int(res.skipFill) & " T " & fmtPath(res.transformed)
      if want: o.add " L " & fmtPath(res.local)
    of "DASH":
      let m = r.rMatrix()
      let apply = r.rInt() != 0
      let cap = StrokeCap(r.rInt())
      var st = initStroke()
      st.cap = cap
      st.trim.begin = r.rF()
      st.trim.`end` = r.rF()
      st.trim.simultaneous = r.rInt() != 0
      st.dash.offset = r.rF()
      let n = r.rInt()
      for i in 0 ..< n:
        let v = r.rF()
        st.dash.pattern.add v
        st.dash.length += v
      let rs = RenderShape(path: r.rPath(), stroke: some(st))
      var outp = RenderPath()
      let ok = gpuStrokeDash(rs, m, apply, outp)
      o.add " " & $int(ok) & " " & fmtPath(outp)
    of "PROBE": o.add " " & runProbe(r.rPath())
    of "CROSS":
      let a = r.rPt(); let b = r.rPt(); let c = r.rPt(); let d = r.rPt()
      o.add " " & $int(gpuEdgesCross(a, b, c, d))
    of "ARC":
      let a = r.rF()
      let rad = r.rF()
      o.add " " & $gpuArcSegmentsCnt(a, rad)
    of "CONIC":
      let c = r.rPt()
      o.add " " & fmtMatrix(gpuConicTransform(c, r.rF()))
    of "BOUNDS":
      let b = Region(xMin: int32(r.rInt()), yMin: int32(r.rInt()), xMax: int32(r.rInt()), yMax: int32(r.rInt()))
      let res = gpuTransformBounds(b, r.rMatrix())
      o.add " " & $res.xMin & " " & $res.yMin & " " & $res.xMax & " " & $res.yMax
    of "MESH":
      var verts: seq[Point]
      for i in 0 ..< r.rInt(): verts.add r.rPt()
      var idx: seq[uint32]
      for i in 0 ..< r.rInt(): idx.add uint32(r.rInt())
      let p = r.rPt()
      var flat: seq[float32]
      for v in verts:
        flat.add v.x
        flat.add v.y
      let a = gpuPointInAnyMesh(p, verts, idx)
      doAssert a == gpuPointInAnyMesh(p, flat, idx)
      o.add " " & $int(a) & " " & $int(gpuPointInFillMesh(p, verts, idx, FillRule.NonZero)) & " " &
        $int(gpuPointInFillMesh(p, verts, idx, FillRule.EvenOdd))
    of "TRI":
      let p = r.rPt(); let a = r.rPt(); let b = r.rPt(); let c = r.rPt()
      o.add " " & $int(gpuPointInTriangle(p, a, b, c))
    of "QUAD":
      let p = r.rPt()
      var q: array[6, Point]
      for i in 0 ..< 6: q[i] = r.rPt()
      o.add " " & $int(gpuPointInQuad(p, q))
    else: quit("unknown op " & op, 2)
    o.add "\n"
  writeFile(outFile, o)

when isMainModule:
  let a = commandLineParams()
  if a.len >= 2 and a[0] == "gen":
    genCases(a[1], if a.len > 2: uint32(parseInt(a[2])) else: 0x2545F491'u32)
  elif a.len == 3 and a[0] == "run": runCases(a[1], a[2])
  else: quit("usage: gen <cases> | run <cases> <out>", 2)
