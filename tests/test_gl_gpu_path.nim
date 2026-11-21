## G2a: GPU path helpers (`gpu_path`, `gpu_dash`, `gpu_probe`), no GL needed.
## The bit-exact comparison with the C++ original lives in
## `tests/gl/gpucommon_compare.ps1`; these are hand-derived expectations.
import std/[unittest, options, math]
import thorvg/core/[types, geom, path]
import thorvg/renderer/render
import thorvg/engine/gl/[gpu_path, gpu_dash, gpu_probe]

func pt(x, y: float32): Point = Point(x: x, y: y)

func rect(x, y, w, h: float32, closeIt = true): RenderPath =
  result.moveTo(pt(x, y))
  result.lineTo(pt(x + w, y))
  result.lineTo(pt(x + w, y + h))
  result.lineTo(pt(x, y + h))
  if closeIt: result.cmds.add PathCommand.Close

func hline(x0, x1: float32): RenderPath =
  result.moveTo(pt(x0, 0))
  result.lineTo(pt(x1, 0))

func scale(s: float32): Matrix = Matrix(e11: s, e22: s, e33: 1)

func dashed(p: RenderPath, pattern: seq[float32], offset = 0.0'f32,
            cap = StrokeCap.Butt): RenderShape =
  var st = initStroke()
  st.cap = cap
  st.dash.pattern = pattern
  st.dash.offset = offset
  for v in pattern: st.dash.length += v
  RenderShape(path: p, stroke: some(st))

proc dash(rs: RenderShape, m = IdentityMatrix, apply = false): tuple[ok: bool, path: RenderPath] =
  gpuStrokeDash(rs, m, apply)

func xs(p: RenderPath): seq[float32] =
  for q in p.pts: result.add q.x

suite "gpuArcSegmentsCnt / gpuConicTransform / gpuTransformBounds":
  test "arc segment count":
    check gpuArcSegmentsCnt(1.0, 0.0) == 2
    check gpuArcSegmentsCnt(0.0, 50.0) == 1
    # segment angle = 2 * sqrt(0.5 / 100) = 0.1414; pi / 0.1414 = 22.2 -> 23 + 1
    check gpuArcSegmentsCnt(PI.float32, 100.0) == 24
    check gpuArcSegmentsCnt(-PI.float32, 100.0) == 24

  test "conic transform maps the center to the origin":
    let center = pt(12, -7)
    let m = gpuConicTransform(center, 33.0)
    let o = center * m
    check abs(o.x) < 1e-4'f32
    check abs(o.y) < 1e-4'f32
    let q = gpuConicTransform(pt(0, 0), 90.0)
    check abs(q.e11) < 1e-6'f32
    check q.e12 > 0.999'f32
    check q.e21 < -0.999'f32
    check q.e33 == 1.0'f32

  test "transform bounds":
    let b = Region(xMin: 0, yMin: 0, xMax: 10, yMax: 10)
    check gpuTransformBounds(b, IdentityMatrix) == b
    let s = gpuTransformBounds(b, scale(2))
    check (s.xMin, s.yMin, s.xMax, s.yMax) == (0'i32, 0'i32, 20'i32, 20'i32)
    # 90 degrees: (x, y) -> (-y, x)
    let r = gpuTransformBounds(b, Matrix(e12: -1, e21: 1, e33: 1))
    check (r.xMin, r.yMin, r.xMax, r.yMax) == (-10'i32, 0'i32, 0'i32, 10'i32)
    # fractional translation widens outwards
    let t = gpuTransformBounds(b, Matrix(e11: 1, e13: 0.5, e22: 1, e23: -0.5, e33: 1))
    check (t.xMin, t.yMin, t.xMax, t.yMax) == (0'i32, -1'i32, 11'i32, 10'i32)
    let bad = Region(xMin: 5, yMin: 0, xMax: 5, yMax: 10)
    check gpuTransformBounds(bad, scale(3)) == bad

suite "gpuOptimize":
  test "plain rect is kept":
    let p = rect(10, 10, 60, 40)
    let r = gpuOptimize(p, IdentityMatrix)
    check not r.thin
    check not r.skipFill
    check r.transformed.cmds == p.cmds
    check r.transformed.pts == p.pts
    check r.local.pts == p.pts

  test "empty input":
    let r = gpuOptimize(RenderPath(), IdentityMatrix)
    check r.transformed.empty and r.local.empty
    check not r.thin and not r.skipFill

  test "transformed vs local coordinates":
    let r = gpuOptimize(rect(1, 1, 4, 4), scale(3))
    check r.transformed.pts[2] == pt(15, 15)
    check r.local.pts[2] == pt(5, 5)
    check not gpuOptimize(rect(1, 1, 4, 4), scale(3), wantLocal = false).transformed.empty
    check gpuOptimize(rect(1, 1, 4, 4), scale(3), wantLocal = false).local.empty

  test "points closer than a quarter pixel are dropped":
    var p = RenderPath()
    p.moveTo(pt(0, 0))
    p.lineTo(pt(0.1, 0.1))
    p.lineTo(pt(10, 0))
    p.lineTo(pt(10, 10))
    p.cmds.add PathCommand.Close
    let r = gpuOptimize(p, IdentityMatrix)
    check r.transformed.pts.len == 3
    check r.local.pts.len == 3
    check r.transformed.pts[1] == pt(10, 0)

  test "thin rect uses the thin fallback, hairline skips the fill":
    let thin = gpuOptimize(rect(10, 10, 100, 0.2), IdentityMatrix)
    check thin.thin
    check not thin.skipFill
    let hair = gpuOptimize(rect(10, 10, 100, 0.001), IdentityMatrix)
    check not hair.thin
    check hair.skipFill
    # 0.3 px of thickness is more than the 0.25 px tolerance: ordinary fill
    check not gpuOptimize(rect(10, 10, 100, 0.3), IdentityMatrix).thin
    check gpuOptimize(rect(10, 10, 100, 0.01), IdentityMatrix).thin
    check not hair.transformed.empty

  test "a thin result depends on the transform":
    let p = rect(0, 0, 100, 40)
    check not gpuOptimize(p, IdentityMatrix).thin
    check gpuOptimize(p, Matrix(e11: 1, e22: 0.00005, e33: 1)).skipFill
    check gpuOptimize(p, Matrix(e11: 1, e22: 0.005, e33: 1)).thin

suite "gpuStrokeDash":
  test "no dash, tiny pattern":
    check not dash(RenderShape(path: hline(0, 10))).ok
    var rs = dashed(hline(0, 10), @[0.0004'f32])
    check not dash(rs).ok
    rs = dashed(hline(0, 10), @[])
    check not dash(rs).ok

  test "even pattern on a line":
    let r = dash(dashed(hline(0, 10), @[2'f32, 2]))
    check r.ok
    check r.path.cmds == @[PathCommand.MoveTo, LineTo, MoveTo, LineTo, MoveTo, LineTo]
    check r.path.xs == @[0'f32, 2, 4, 6, 8, 10]

  test "offset shifts the pattern":
    let r = dash(dashed(hline(0, 10), @[2'f32, 2], offset = 1))
    check r.path.xs == @[0'f32, 1, 3, 5, 7, 9]
    let neg = dash(dashed(hline(0, 10), @[2'f32, 2], offset = -1))
    check neg.path.xs == @[1'f32, 3, 5, 7, 9, 10]
    let wrapped = dash(dashed(hline(0, 10), @[2'f32, 2], offset = 5))
    check wrapped.path.xs == dash(dashed(hline(0, 10), @[2'f32, 2], offset = 1)).path.xs

  test "odd pattern is repeated with swapped phases":
    let r = dash(dashed(hline(0, 12), @[3'f32]))
    check r.path.xs == @[0'f32, 3, 6, 9]

  test "transform is applied on request":
    let rs = dashed(hline(0, 10), @[2'f32, 2])
    check dash(rs, scale(2), true).path.xs == @[0'f32, 4, 8, 12, 16, 20]
    check dash(rs, scale(2), false).path.xs == @[0'f32, 2, 4, 6, 8, 10]

  test "zero-length dashes become dots only with a cap":
    let butt = dash(dashed(hline(0, 9), @[0'f32, 3]))
    let round = dash(dashed(hline(0, 9), @[0'f32, 3], cap = StrokeCap.Round))
    check round.ok
    check round.path.pts.len > butt.path.pts.len
    check round.path.cmds[0] == PathCommand.MoveTo

  test "trim limits the dashed span":
    var rs = dashed(hline(0, 10), @[2'f32, 2])
    rs.stroke.get.trim.`end` = 0.5
    let r = dash(rs)
    check r.ok
    check r.path.xs == @[0'f32, 2, 4, 5]
    rs.stroke.get.trim.begin = 0.5
    rs.stroke.get.trim.`end` = 0.5001
    discard dash(rs)

  test "closed rect: dashes wrapping over the start are joined":
    # perimeter 40, pattern 30 on / 5 off: [0,30] and [35,40] touch at the start point
    let r = dash(dashed(rect(0, 0, 10, 10), @[30'f32, 5]))
    check r.ok
    check r.path.cmds[0] == PathCommand.MoveTo
    var moves = 0
    for c in r.path.cmds:
      if c == PathCommand.MoveTo: inc moves
    check moves == 1
    check r.path.pts[0] == pt(0, 5)

  test "cubic is split by length":
    var p = RenderPath()
    p.moveTo(pt(0, 0))
    p.cubicTo(pt(10, 0), pt(20, 0), pt(30, 0))
    let r = dash(dashed(p, @[10'f32, 10]))
    check r.ok
    check r.path.cmds == @[PathCommand.MoveTo, CubicTo, MoveTo, CubicTo]
    check abs(r.path.pts[3].x - 10) < 0.05'f32
    check abs(r.path.pts[^1].x - 30) < 0.05'f32

suite "GpuConvexProbe / gpuEdgesCross":
  func feed(edges: openArray[Point]): GpuConvexProbe =
    result = initConvexProbe()
    result.nextContour()
    for e in edges: result.addEdge(e)

  test "square stays convex":
    var p = feed([pt(10, 0), pt(0, 10), pt(-10, 0)])
    p.addContourClose(pt(0, -10))
    check p.convex
    check p.winding != 0

  test "triangle and a bow tie":
    var tri = feed([pt(10, 0), pt(-5, 8)])
    tri.addContourClose(pt(-5, -8))
    check tri.convex
    var bow = feed([pt(10, 10), pt(-10, 0), pt(10, -10)])
    bow.addContourClose(pt(-10, 0))
    check not bow.convex

  test "concave arrow":
    var a = feed([pt(10, 0), pt(-5, 5), pt(5, 5), pt(-10, 0)])
    a.addContourClose(pt(0, -10))
    check not a.convex

  test "a second contour disables the fan":
    var p = feed([pt(10, 0), pt(0, 10)])
    p.addContourClose(pt(-10, -10))
    check p.convex
    p.nextContour()
    check not p.convex

  test "an empty contour is harmless":
    var p = initConvexProbe()
    p.nextContour()
    p.nextContour()
    check p.convex

  test "edge crossing":
    check gpuEdgesCross(pt(0, 0), pt(10, 10), pt(10, 0), pt(0, 10))
    check not gpuEdgesCross(pt(0, 0), pt(10, 0), pt(0, 5), pt(10, 5))
    check not gpuEdgesCross(pt(0, 0), pt(10, 0), pt(5, 0), pt(15, 0))   # collinear
    check not gpuEdgesCross(pt(0, 0), pt(4, 4), pt(6, 0), pt(10, 4))    # lines cross, segments don't

suite "mesh intersectors":
  test "triangle / quad":
    check gpuPointInTriangle(pt(2, 2), pt(0, 0), pt(10, 0), pt(0, 10))
    check not gpuPointInTriangle(pt(8, 8), pt(0, 0), pt(10, 0), pt(0, 10))
    check gpuPointInTriangle(pt(2, 2), pt(0, 10), pt(0, 0), pt(10, 0))      # winding independent
    check gpuPointInTriangle(pt(5, 0), pt(0, 0), pt(10, 0), pt(0, 10))      # on an edge
    let q = [pt(0, 0), pt(10, 0), pt(10, 10), pt(0, 0), pt(10, 10), pt(0, 10)]
    check gpuPointInQuad(pt(8, 2), q)
    check gpuPointInQuad(pt(2, 8), q)
    check not gpuPointInQuad(pt(12, 5), q)

  test "any mesh, Point and packed float layouts":
    let v = [pt(0, 0), pt(10, 0), pt(0, 10), pt(20, 20), pt(30, 20), pt(20, 30)]
    let flat = [0'f32, 0, 10, 0, 0, 10, 20, 20, 30, 20, 20, 30]
    let idx = [0'u32, 1, 2, 3, 4, 5]
    check gpuPointInAnyMesh(pt(2, 2), v, idx)
    check gpuPointInAnyMesh(pt(22, 22), v, idx)
    check gpuPointInAnyMesh(pt(22, 22), flat, idx)
    check not gpuPointInAnyMesh(pt(15, 15), v, idx)
    check not gpuPointInAnyMesh(pt(22, 22), v, idx, count = 3)   # second triangle ignored

  test "fill mesh: nonzero vs even-odd":
    # two concentric squares as triangle fans with the same orientation
    let v = [pt(0, 0), pt(10, 0), pt(10, 10), pt(0, 10), pt(3, 3), pt(7, 3), pt(7, 7), pt(3, 7)]
    let idx = [0'u32, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
    check gpuPointInFillMesh(pt(1, 5), v, idx, FillRule.NonZero)
    check gpuPointInFillMesh(pt(1, 5), v, idx, FillRule.EvenOdd)
    check gpuPointInFillMesh(pt(5, 5), v, idx, FillRule.NonZero)
    check not gpuPointInFillMesh(pt(5, 5), v, idx, FillRule.EvenOdd)
    check not gpuPointInFillMesh(pt(20, 5), v, idx, FillRule.NonZero)
    check not gpuPointInFillMesh(pt(20, 5), v, idx, FillRule.EvenOdd)
