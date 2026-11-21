import std/[unittest, options, math, sequtils]
import thorvg/core/[types, geom, path]
import thorvg/renderer/render
import thorvg/engine/cpu/[common, stroke, strokeborder]

proc makeShape(width: float32, cap: StrokeCap, join: StrokeJoin,
               miter: float32 = 4.0'f32): RenderShape =
  var st = initStroke()
  st.width = width
  st.cap = cap
  st.join = join
  st.miterlimit = miter
  RenderShape(stroke: some(st))

proc run(p: RenderPath, width: float32, cap: StrokeCap, join: StrokeJoin,
         miter: float32 = 4.0'f32): SwOutline =
  ## Strokes `p`; returns nil if the parser rejects the path.
  let s = SwStroke()
  s.strokeReset(makeShape(width, cap, join, miter), IdentityMatrix)
  let src = SwOutline(cmds: p.cmds, fpts: p.pts, fillRule: FillRule.NonZero)
  if not s.strokeParseOutline(src): return nil
  s.strokeExportOutline()

proc contours(o: SwOutline): int =
  for c in o.cmds:
    if c == PathCommand.MoveTo: inc result

proc bounds(o: SwOutline): BBox =
  result = initBBox()
  for p in o.fpts:
    result.min = min(result.min, p)
    result.max = max(result.max, p)

proc near(a, b: float32, tol: float32 = 0.3'f32): bool = abs(a - b) <= tol

proc hasPoint(o: SwOutline, x, y: float32): bool =
  for p in o.fpts:
    if near(p.x, x, 0.05'f32) and near(p.y, y, 0.05'f32): return true

proc linePath(x1, y1, x2, y2: float32): RenderPath =
  result.moveTo(pt(x1, y1))
  result.lineTo(pt(x2, y2))

proc rectPath(): RenderPath =
  result.addRect(10, 10, 100, 50, 0, 0, true)

proc circlePath(): RenderPath =
  result.addCircle(50, 50, 30, 30, true)

suite "stroke line caps":
  test "butt cap":
    let o = run(linePath(0, 0, 100, 0), 10, StrokeCap.Butt, StrokeJoin.Miter)
    check o != nil
    check o.fpts.len > 0
    check o.contours == 1
    check o.fillRule == FillRule.NonZero
    let b = o.bounds
    check near(b.min.x, 0) and near(b.max.x, 100)
    check near(b.min.y, -5) and near(b.max.y, 5)

  test "square cap extends by half width":
    let o = run(linePath(0, 0, 100, 0), 10, StrokeCap.Square, StrokeJoin.Miter)
    let b = o.bounds
    check near(b.min.x, -5) and near(b.max.x, 105)
    check near(b.min.y, -5) and near(b.max.y, 5)
    check o.contours == 1

  test "round cap extends by half width":
    let o = run(linePath(0, 0, 100, 0), 10, StrokeCap.Round, StrokeJoin.Miter)
    let b = o.bounds
    check near(b.min.x, -5) and near(b.max.x, 105)
    check near(b.min.y, -5) and near(b.max.y, 5)
    check PathCommand.CubicTo in o.cmds

  test "diagonal line":
    let o = run(linePath(0, 0, 30, 40), 10, StrokeCap.Butt, StrokeJoin.Bevel)
    let b = o.bounds
    # normal of (3,4)/5 times 5 = (-4, 3)
    check near(b.min.x, -4) and near(b.max.x, 34)
    check near(b.min.y, -3) and near(b.max.y, 43)

suite "stroke closed paths":
  test "rect yields two contours for every join":
    for join in [StrokeJoin.Miter, StrokeJoin.Round, StrokeJoin.Bevel]:
      let o = run(rectPath(), 8, StrokeCap.Butt, join)
      check o != nil
      check o.contours == 2
      let b = o.bounds
      check near(b.min.x, 6) and near(b.max.x, 114)
      check near(b.min.y, 6) and near(b.max.y, 64)
      check o.cmds.count(PathCommand.Close) == 2

  test "miter corner is pointed, bevel is cut":
    var p: RenderPath
    p.moveTo(pt(0, 0))
    p.lineTo(pt(100, 0))
    p.lineTo(pt(100, 100))
    let m = run(p, 10, StrokeCap.Butt, StrokeJoin.Miter)
    check m.hasPoint(105, -5)
    let bv = run(p, 10, StrokeCap.Butt, StrokeJoin.Bevel)
    check not bv.hasPoint(105, -5)
    check bv.hasPoint(100, -5) and bv.hasPoint(105, 0)
    let r = run(p, 10, StrokeCap.Butt, StrokeJoin.Round)
    check PathCommand.CubicTo in r.cmds
    check not r.hasPoint(105, -5)

  test "miter limit falls back to bevel":
    var p: RenderPath
    p.moveTo(pt(0, 0))
    p.lineTo(pt(100, 0))
    p.lineTo(pt(0, 10))
    let o = run(p, 10, StrokeCap.Butt, StrokeJoin.Miter, 1.0'f32)
    let b = o.bounds
    check b.max.x < 110  # a real miter would shoot far beyond 100

  test "circle yields two contours (cubic path)":
    for join in [StrokeJoin.Miter, StrokeJoin.Round, StrokeJoin.Bevel]:
      let o = run(circlePath(), 10, StrokeCap.Butt, join)
      check o != nil
      check o.contours == 2
      let b = o.bounds
      check near(b.min.x, 15, 1.0'f32) and near(b.max.x, 85, 1.0'f32)
      check near(b.min.y, 15, 1.0'f32) and near(b.max.y, 85, 1.0'f32)

  test "open cubic with round cap":
    var p: RenderPath
    p.moveTo(pt(0, 0))
    p.cubicTo(pt(30, 60), pt(70, -60), pt(100, 0))
    let o = run(p, 6, StrokeCap.Round, StrokeJoin.Round)
    check o.contours == 1
    let b = o.bounds
    check b.min.x < 0 and b.max.x > 100

suite "stroke edge cases":
  test "path starting with cubic is rejected":
    var p: RenderPath
    p.cubicTo(pt(1, 1), pt(2, 2), pt(3, 3))
    check run(p, 4, StrokeCap.Butt, StrokeJoin.Miter) == nil

  test "zero length line: dot for round cap, nothing for butt":
    var p: RenderPath
    p.moveTo(pt(10, 10))
    p.lineTo(pt(10, 10))
    let r = run(p, 10, StrokeCap.Round, StrokeJoin.Round)
    check r.fpts.len > 0
    let b = r.bounds
    check near(b.min.x, 5) and near(b.max.x, 15)
    let bt = run(p, 10, StrokeCap.Butt, StrokeJoin.Round)
    check bt.fpts.len == 0

  test "initial LineTo is treated as MoveTo":
    var p: RenderPath
    p.lineTo(pt(0, 0))
    p.lineTo(pt(100, 0))
    let o = run(p, 10, StrokeCap.Butt, StrokeJoin.Miter)
    check o.contours == 1
    check near(o.bounds.max.x, 100)

  test "two subpaths give two contours; reset clears old borders":
    var p: RenderPath
    p.moveTo(pt(0, 0))
    p.lineTo(pt(50, 0))
    p.moveTo(pt(0, 20))
    p.lineTo(pt(50, 20))
    let s = SwStroke()
    let rs = makeShape(4, StrokeCap.Butt, StrokeJoin.Miter)
    s.strokeReset(rs, IdentityMatrix)
    let src = SwOutline(cmds: p.cmds, fpts: p.pts)
    check s.strokeParseOutline(src)
    check s.strokeExportOutline().contours == 2
    s.strokeReset(rs, IdentityMatrix)
    check s.strokeExportOutline().fpts.len == 0

  test "empty outline":
    let s = SwStroke()
    s.strokeReset(makeShape(4, StrokeCap.Butt, StrokeJoin.Miter), IdentityMatrix)
    check s.strokeParseOutline(SwOutline())
    check s.strokeExportOutline().cmds.len == 0

  test "remainderf is IEEE":
    check near(remainderf(7.0'f32, 2.0'f32), -1.0'f32, 1e-6'f32)
    check near(remainderf(3.5'f32, 2.0'f32), -0.5'f32, 1e-6'f32)
    check near(remainderf(-3.0'f32, 2.0'f32), 1.0'f32, 1e-6'f32)
    check classify(remainderf(Inf.float32, 1.0'f32)) == fcNan
