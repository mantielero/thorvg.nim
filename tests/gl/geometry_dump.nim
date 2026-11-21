## Differential oracle for G2b (`gl_common`, `geometry`, `tessellator`, `tess_stroke`).
##
##   geometry_dump gen <cases.txt> [seed]      writes the fixed-seed case file
##   geometry_dump run <cases.txt> <out.txt>   runs the Nim port on the cases
##
## `geometry_dump.cpp` reads the same case file, runs the ORIGINAL `tvgGlGeometry.cpp` +
## `tvgGlTessellator.cpp` and writes the same text format (floats and indices as hex / decimal,
## one line per case): vertex + index buffers, bboxes, convex / direct flags, hit tests.
import std/[strutils, os, options, sequtils, math]
import thorvg/core/[types, geom, path]
import thorvg/renderer/render
import thorvg/engine/gl/[gl_common, geometry]

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

func fmtMatrix(m: Matrix): string =
  [m.e11, m.e12, m.e13, m.e21, m.e22, m.e23, m.e31, m.e32, m.e33].mapIt(hx(it)).join(" ")

func fmtRegion(r: Region): string = $r.xMin & " " & $r.yMin & " " & $r.xMax & " " & $r.yMax

func fmtFloats(v: seq[float32]): string =
  result = $v.len
  for f in v: result.add " " & hx(f)

func fmtUints(v: seq[uint32]): string =
  result = $v.len
  for u in v: result.add " " & $u

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

proc rRegion(r: var Reader): Region =
  result.xMin = int32(r.rInt())
  result.yMin = int32(r.rInt())
  result.xMax = result.xMin + int32(r.rInt())
  result.yMax = result.yMin + int32(r.rInt())

# ------------------------------------------------------------------ shape spec

type ShapeSpec = object
  matrix: Matrix
  rshape: RenderShape

proc fmtSpec(s: ShapeSpec): string =
  let rs = s.rshape
  result = fmtMatrix(s.matrix) & " " & $int(rs.rule) & " " & $int(rs.color.a) & " " &
    $int(rs.stroke.isSome)
  if rs.stroke.isSome:
    let st = rs.stroke.get
    result.add " " & hx(st.width) & " " & $int(st.cap) & " " & $int(st.join) & " " &
      hx(st.miterlimit) & " " & hx(st.trim.begin) & " " & hx(st.trim.`end`) & " " &
      $int(st.trim.simultaneous) & " " & hx(st.dash.offset) & " " & $st.dash.pattern.len
    for v in st.dash.pattern: result.add " " & hx(v)
  result.add " " & fmtPath(rs.path)

proc rSpec(r: var Reader): ShapeSpec =
  result.matrix = r.rMatrix()
  result.rshape.rule = FillRule(r.rInt())
  result.rshape.color.a = uint8(r.rInt())
  if r.rInt() != 0:
    var st = initStroke()
    st.width = r.rF()
    st.cap = StrokeCap(r.rInt())
    st.join = StrokeJoin(r.rInt())
    st.miterlimit = r.rF()
    st.trim.begin = r.rF()
    st.trim.`end` = r.rF()
    st.trim.simultaneous = r.rInt() != 0
    st.dash.offset = r.rF()
    for i in 0 ..< r.rInt():
      let v = r.rF()
      st.dash.pattern.add v
      st.dash.length += v
    result.rshape.stroke = some(st)
  result.rshape.path = r.rPath()

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

func poly(pts: openArray[(float32, float32)], closeIt = true): RenderPath =
  for i, p in pts:
    if i == 0: result.moveTo(Point(x: p[0], y: p[1]))
    else: result.lineTo(Point(x: p[0], y: p[1]))
  if closeIt: result.cmds.add PathCommand.Close

proc handPaths(): seq[RenderPath] =
  result.add RenderPath()
  var p = RenderPath()
  p.moveTo(Point(x: 5, y: 5))
  result.add p
  result.add poly([(10'f32, 10'f32), (110, 10), (110, 10.3'f32), (10, 10.3'f32)])
  result.add poly([(10'f32, 10'f32), (110, 10), (110, 10.01'f32), (10, 10.01'f32)])
  result.add poly([(10'f32, 10'f32), (10.2'f32, 10), (10.2'f32, 90), (10, 90)])
  result.add poly([(10'f32, 10'f32), (70, 10), (70, 50), (10, 50)])
  result.add poly([(10'f32, 10'f32), (70, 10), (70, 50), (10, 50)], false)
  result.add poly([(0'f32, 0'f32), (100, 0), (50, 0.2'f32)])
  result.add poly([(0'f32, 0'f32), (50, 50), (100, 0), (0, 40), (100, 40)])   # self intersecting
  result.add poly([(0'f32, 0'f32), (10, 0), (20, 0)], false)                  # collinear
  result.add poly([(0'f32, 0'f32), (10, 0), (0, 0)], false)                   # reversal
  result.add poly([(5'f32, 5'f32), (5, 5), (5, 5)])
  p = RenderPath()                                                            # holes
  for (x0, y0, x1, y1, cw) in [(0'f32, 0'f32, 40'f32, 40'f32, true), (10, 10, 30, 30, false),
                               (12, 12, 20, 20, true)]:
    p.moveTo(Point(x: x0, y: y0))
    if cw:
      p.lineTo(Point(x: x1, y: y0)); p.lineTo(Point(x: x1, y: y1)); p.lineTo(Point(x: x0, y: y1))
    else:
      p.lineTo(Point(x: x0, y: y1)); p.lineTo(Point(x: x1, y: y1)); p.lineTo(Point(x: x1, y: y0))
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
  p = RenderPath()
  p.moveTo(Point(x: 3, y: 3)); p.lineTo(Point(x: 3, y: 3)); p.cmds.add PathCommand.Close
  result.add p
  p = RenderPath()
  p.moveTo(Point(x: 3, y: 3)); p.cmds.add PathCommand.Close
  result.add p
  p = RenderPath()
  p.moveTo(Point(x: 0, y: 0)); p.lineTo(Point(x: 30, y: 0)); p.lineTo(Point(x: 30, y: 30))
  p.lineTo(Point(x: 0, y: 30)); p.lineTo(Point(x: 0, y: 0)); p.lineTo(Point(x: 30, y: 0.5'f32))
  result.add p

proc shapePath(r: var Rng, hand: seq[RenderPath]): RenderPath =
  case r.ri(12)
  of 0:
    result.addRect(r.rng(0, 50), r.rng(0, 50), r.rng(0.1'f32, 80), r.rng(0.1'f32, 80), 0, 0, r.ri(2) == 0)
  of 1:
    result.addRect(r.rng(0, 50), r.rng(0, 50), r.rng(5, 80), r.rng(5, 80), r.rng(0, 20), r.rng(0, 20),
                   r.ri(2) == 0)
  of 2:
    result.addCircle(r.rng(10, 80), r.rng(10, 80), r.rng(0.2'f32, 40), r.rng(0.2'f32, 40), r.ri(2) == 0)
  of 3, 4: result = hand[r.ri(hand.len)]
  else: result = r.genPath()

proc genMatrix(r: var Rng): Matrix =
  case r.ri(10)
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
    Matrix(e11: r.rng(0.001'f32, 0.2'f32), e22: r.rng(0.001'f32, 0.2'f32), e33: 1)
  of 5:
    Matrix(e11: 1, e13: r.rng(-5, 5), e22: -1, e23: r.rng(-5, 5), e33: 1)
  of 6:
    Matrix(e33: 1)                                                  # singular
  of 7:
    Matrix(e11: r.rng(10, 40), e22: r.rng(10, 40), e33: 1)          # big scale
  else:
    Matrix(e11: 1, e12: r.rng(-2, 2), e22: 1, e23: r.rng(-5, 5), e33: 1)  # skew

proc genStroke(r: var Rng): Option[RenderStroke] =
  if r.ri(100) >= 70: return none(RenderStroke)
  var st = initStroke()
  st.width = case r.ri(9)
    of 0: 0.0'f32
    of 1: 0.3'f32
    of 2: 1.0'f32
    of 3: 2.5'f32
    of 4: 8.0'f32
    of 5: 30.0'f32
    of 6: r.rng(0.01'f32, 20)
    of 7: (if r.ri(4) == 0: [NaN, Inf, -3.0'f32, 1e4'f32][r.ri(4)] else: 5.0'f32)
    else: r.rng(1, 12)
  st.cap = StrokeCap(r.ri(3))
  st.join = StrokeJoin(r.ri(3))
  st.miterlimit = [1.0'f32, 2.0, 4.0, 10.0, r.rng(1, 8)][r.ri(5)]
  if r.ri(8) == 0:
    st.trim.begin = r.rng(0, 0.6'f32)
    st.trim.`end` = r.rng(0.4'f32, 1)
    st.trim.simultaneous = r.ri(2) == 0
  if r.ri(4) == 0:
    st.dash.offset = if r.ri(3) == 0: 0.0'f32 else: r.rng(-10, 10)
    for i in 0 ..< 1 + r.ri(3):
      let v = if r.ri(4) == 0: 0.0'f32 else: r.rng(0.5'f32, 12)
      st.dash.pattern.add v
      st.dash.length += v
  some(st)

proc genSpec(r: var Rng, hand: seq[RenderPath]): ShapeSpec =
  result.matrix = r.genMatrix()
  result.rshape.rule = FillRule(r.ri(2))
  result.rshape.color.a = if r.ri(5) == 0: 0'u8 else: 255'u8
  result.rshape.stroke = r.genStroke()
  result.rshape.path = r.shapePath(hand)

proc genRegion(r: var Rng): string =
  $(r.ri(130) - 10) & " " & $(r.ri(130) - 10) & " " & $(1 + r.ri(14)) & " " & $(1 + r.ri(14))

proc genCases(file: string, seed: uint32) =
  var r = Rng(s: seed)
  var o = "SIZES\n"
  let hand = handPaths()
  # every hand path with a set of strokes, so all caps / joins meet each path
  for i, p in hand:
    for cap in 0 ..< 3:
      for join in 0 ..< 3:
        var st = initStroke()
        st.width = [4.0'f32, 12.0, 2.0][(cap + join + i) mod 3]
        st.cap = StrokeCap(cap)
        st.join = StrokeJoin(join)
        st.miterlimit = [4.0'f32, 1.5, 10.0][(cap + i) mod 3]
        let m = [IdentityMatrix, Matrix(e11: 2, e22: 2, e33: 1), Matrix(e11: 0.05'f32, e22: 0.05'f32, e33: 1)][join]
        let spec = ShapeSpec(matrix: m, rshape: RenderShape(path: p, stroke: some(st),
                             color: RGBA(a: 255), rule: FillRule(i mod 2)))
        o.add "SHAPE " & fmtSpec(spec) & " " & r.genRegion() & "\n"
  for i in 0 ..< 3500:
    o.add "SHAPE " & fmtSpec(r.genSpec(hand)) & " " & r.genRegion() & "\n"
  for i in 0 ..< 250:
    let shapeSpec = r.genSpec(hand)
    var clipSpec = r.genSpec(hand)
    if i mod 2 == 1:
      # a covering clip rectangle (sometimes shifted), so the clipped hit path is reached
      clipSpec.matrix = Matrix(e11: 1, e13: float32(r.ri(3) * 20 - 20), e22: 1, e23: float32(r.ri(3) * 20 - 20), e33: 1)
      clipSpec.rshape.path = RenderPath()
      clipSpec.rshape.path.addRect(0, 0, float32(60 + r.ri(80)), float32(60 + r.ri(80)), 0, 0, true)
      clipSpec.rshape.stroke = none(RenderStroke)
      clipSpec.rshape.color.a = 255
    let region = if i mod 2 == 1: $(r.ri(60)) & " " & $(r.ri(60)) & " " & $(10 + r.ri(70)) & " " & $(10 + r.ri(70))
                 else: r.genRegion()
    o.add "CLIP " & fmtSpec(shapeSpec) & " " & fmtSpec(clipSpec) & " " & region & "\n"
  for i in 0 ..< 300:
    o.add "IMAGE " & fmtMatrix(r.genMatrix()) & " " & $(r.ri(40)) & " " & $(r.ri(40)) & " " &
      r.genRegion() & "\n"
  writeFile(file, o)

# ------------------------------------------------------------------ runner

proc fmtShape(shape: GlShape, hit: bool): string =
  var g = shape.geometry
  let flags = [{RenderUpdateFlag.Path}, {RenderUpdateFlag.Stroke}, {RenderUpdateFlag.Image}]
  result = [$int(g.optPathThin), $int(g.optPathSkipFill), $int(shape.valid.fill), hx(shape.multiplier),
            $int(g.fillRule), $int(g.convex), $int(g.fillWorld), fmtRegion(g.fillBBox),
            $int(g.strokeDirect), $int(shape.valid.stroke), hx(g.strokeRenderWidth),
            fmtRegion(g.strokeBBox), fmtRegion(g.bounds())].join(" ")
  for f in flags: result.add " " & $int(g.stencilMode(f))
  result.add " " & $int(g.drawable({RenderUpdateFlag.Stroke})) & " " & $int(g.drawable({RenderUpdateFlag.Path}))
  result.add " | " & fmtPath(g.optPath) & " | " & fmtPath(g.optStrokePath)
  result.add " | " & fmtFloats(g.fill.vertex) & " | " & fmtUints(g.fill.index)
  result.add " | " & fmtFloats(g.stroke.vertex) & " | " & fmtUints(g.stroke.index)
  result.add " | " & $int(hit)

proc buildShape(spec: ShapeSpec): GlShape =
  result = newGlShape(spec.rshape)
  result.updateShape(spec.matrix, Region(), {RenderUpdateFlag.Path, RenderUpdateFlag.Stroke})

proc runCases(inFile, outFile: string) =
  var r = Reader(tok: readFile(inFile).splitWhitespace())
  var o = ""
  while r.pos < r.tok.len:
    let op = r.next()
    o.add op
    case op
    of "SIZES":
      o.add " " & $sizeof(GlLinearGradientBlock) & " " & $sizeof(GlRadialGradientBlock) & " " &
        $sizeof(GlConicGradientBlock) & " " & $sizeof(GlImageOpacityBlock)
    of "SHAPE":
      let shape = buildShape(r.rSpec())
      let region = r.rRegion()
      o.add " " & fmtShape(shape, intersect(shape, region))
    of "CLIP":
      let shape = buildShape(r.rSpec())
      let clip = buildShape(r.rSpec())
      shape.clips = @[RenderData(clip)]
      let region = r.rRegion()
      o.add " " & fmtShape(shape, intersect(shape, region))
    of "IMAGE":
      let m = r.rMatrix()
      let surface = RenderSurface(w: uint32(r.rInt()), h: uint32(r.rInt()))
      let image = newGlImage(surface)
      image.geometry.transform(m)
      image.geometry.tesselateImage(surface)
      let region = r.rRegion()
      o.add " " & fmtFloats(image.geometry.fill.vertex) & " | " & fmtUints(image.geometry.fill.index) &
        " | " & fmtRegion(image.geometry.fillBBox) & " | " & fmtRegion(image.geometry.bounds()) &
        " | " & $int(intersect(image, region))
    else: quit("unknown op " & op, 2)
    o.add "\n"
  writeFile(outFile, o)

when isMainModule:
  let a = commandLineParams()
  if a.len >= 2 and a[0] == "gen":
    genCases(a[1], if a.len > 2: uint32(parseInt(a[2])) else: 0x2545F491'u32)
  elif a.len == 3 and a[0] == "run": runCases(a[1], a[2])
  else: quit("usage: gen <cases> | run <cases> <out>", 2)
