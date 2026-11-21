import std/[unittest, options, math]
import thorvg/core/[types, geom, path]
import thorvg/renderer/render
import thorvg/engine/cpu/[common, shape, util, dash]

let clip = Region(xMin: 0, yMin: 0, xMax: 100, yMax: 100)

func region(x0, y0, x1, y1: int): Region =
  Region(xMin: int32(x0), yMin: int32(y0), xMax: int32(x1), yMax: int32(y1))

func sameRegion(a, b: Region): bool =
  a.xMin == b.xMin and a.yMin == b.yMin and a.xMax == b.xMax and a.yMax == b.yMax

proc fillShape(p: RenderPath, rule = FillRule.NonZero): RenderShape =
  RenderShape(path: p, rule: rule)

proc strokeShape(p: RenderPath, width: float32, cap = StrokeCap.Butt,
                 join = StrokeJoin.Miter): RenderShape =
  var st = initStroke()
  st.width = width
  st.cap = cap
  st.join = join
  RenderShape(path: p, stroke: some(st))

proc rectPath(x, y, w, h: float32): RenderPath =
  result.addRect(x, y, w, h, 0, 0, true)

proc linePath(x1, y1, x2, y2: float32): RenderPath =
  result.moveTo(pt(x1, y1))
  result.lineTo(pt(x2, y2))

func area(r: SwRle): float =
  for s in r.spans: result += float(s.len) * float(s.coverage) / 255.0

func moveCount(o: SwOutline): int =
  for c in o.cmds:
    if c == PathCommand.MoveTo: inc result

func rowSpans(r: SwRle, y: int): int =
  for s in r.spans:
    if int(s.y) == y: inc result

func xRange(r: SwRle): (int, int) =
  result = (int.high, int.low)
  for s in r.spans:
    result[0] = min(result[0], int(s.x))
    result[1] = max(result[1], int(s.x + s.len))

suite "util":
  test "utilExport converts to 26.6 fixed point":
    var o = SwOutline(fpts: @[pt(1.5, 2.25), pt(-3.0, 10.0)])
    var bb: BBox
    utilExport(o, IdentityMatrix, bb)
    check o.pts.len == 2
    check o.pts[0].x == 96 and o.pts[0].y == 144
    check o.pts[1].x == -192 and o.pts[1].y == 640
    check bb.min.x == -3.0'f32 and bb.max.y == 10.0'f32
    var m = IdentityMatrix
    m.e11 = 2.0'f32
    m.e22 = 2.0'f32
    utilExport(o, m, bb)
    check o.pts.len == 2 and o.pts[0].x == 192 and o.pts[0].y == 288

  test "utilBBox rounds fast track, encloses otherwise, clips":
    let bb = BBox(min: pt(10.4, 10.6), max: pt(50.5, 40.2))
    var box: Region
    check utilBBox(bb, clip, box, true)
    check sameRegion(box, region(10, 11, 51, 40))
    check utilBBox(bb, clip, box, false)
    check sameRegion(box, region(10, 10, 51, 41))
    let big = BBox(min: pt(-20, -20), max: pt(200, 200))
    check utilBBox(big, clip, box, false)
    check sameRegion(box, clip)
    let outside = BBox(min: pt(150, 10), max: pt(160, 20))
    check not utilBBox(outside, clip, box, false)

suite "fill":
  test "aligned rect takes the fast track":
    let s = SwShape()
    var box: Region
    check shapeGenRle(s, fillShape(rectPath(10, 10, 40, 30)), IdentityMatrix, clip, box,
                      false, true)
    check s.fastTrack
    check s.rle == nil
    check sameRegion(box, region(10, 10, 50, 40))
    check sameRegion(s.bbox, box)
    check s.outline != nil and s.outline.pts.len == 4

  test "composited rect builds an rle":
    let s = SwShape()
    var box: Region
    check shapeGenRle(s, fillShape(rectPath(10, 10, 40, 30)), IdentityMatrix, clip, box,
                      true, true)
    check not s.fastTrack
    check s.rle.spans.len == 30
    check area(s.rle) == 1200.0
    check xRange(s.rle) == (10, 50)

  test "rotated rect is not fast track":
    var m = IdentityMatrix
    m.rotate(30.0'f32)
    m.translate(pt(50, 10))
    let s = SwShape()
    var box: Region
    check shapeGenRle(s, fillShape(rectPath(0, 0, 20, 20)), m, clip, box, false, true)
    check not s.fastTrack
    check abs(area(s.rle) - 400.0) < 4.0

  test "circle area and bounds":
    var p: RenderPath
    p.addCircle(50, 50, 20, 20, true)
    let s = SwShape()
    var box: Region
    check shapeGenRle(s, fillShape(p), IdentityMatrix, clip, box, false, true)
    check not s.fastTrack
    check box.xMin in 29'i32 .. 30'i32 and box.yMin in 29'i32 .. 30'i32
    check box.xMax in 70'i32 .. 71'i32 and box.yMax in 70'i32 .. 71'i32
    check abs(area(s.rle) - PI * 400.0) < 0.02 * PI * 400.0
    # the center is fully covered
    var full = false
    for sp in s.rle.spans:
      if sp.y == 50 and sp.x <= 50 and sp.x + sp.len > 50 and sp.coverage == 255: full = true
    check full

  test "even-odd ring":
    var p = rectPath(10, 10, 60, 60)
    p.addRect(30, 30, 20, 20, 0, 0, true)
    let s = SwShape()
    var box: Region
    check shapeGenRle(s, fillShape(p, FillRule.EvenOdd), IdentityMatrix, clip, box, false,
                      true)
    check abs(area(s.rle) - (3600.0 - 400.0)) < 1.0

  test "clip box limits the render box and the rle":
    let s = SwShape()
    var box: Region
    let cb = region(20, 20, 60, 60)
    check shapeGenRle(s, fillShape(rectPath(10, 10, 100, 100)), IdentityMatrix, cb, box,
                      true, true)
    check sameRegion(box, cb)
    check area(s.rle) == 1600.0
    check xRange(s.rle) == (20, 60)

  test "outside the clip box fails":
    let s = SwShape()
    var box: Region
    check not shapeGenRle(s, fillShape(rectPath(200, 200, 10, 10)), IdentityMatrix, clip,
                          box, false, true)

  test "empty path and path starting with a cubic fail and reset the box":
    let s = SwShape()
    var box = region(1, 2, 3, 4)
    check not shapeGenRle(s, fillShape(RenderPath()), IdentityMatrix, clip, box, false, true)
    check sameRegion(box, Region())
    var p: RenderPath
    p.cubicTo(pt(1, 1), pt(2, 2), pt(3, 3))
    box = region(1, 2, 3, 4)
    check not shapeGenRle(s, fillShape(p), IdentityMatrix, clip, box, false, true)
    check sameRegion(box, Region())

  test "trimmed fill":
    var rs = fillShape(rectPath(10, 10, 40, 30))
    var st = initStroke()
    st.trim = RenderTrimPath(begin: 0.0'f32, `end`: 0.5'f32, simultaneous: true)
    rs.stroke = some(st)
    let s = SwShape()
    var box: Region
    check shapeGenRle(s, rs, IdentityMatrix, clip, box, false, true)
    check not s.fastTrack
    check s.outline.cmds.len > 0 and s.outline.cmds[0] == PathCommand.MoveTo

  test "reset and free":
    let s = SwShape()
    var box: Region
    check shapeGenRle(s, fillShape(rectPath(10, 10, 40, 30)), IdentityMatrix, clip, box,
                      true, true)
    shapeReset(s)
    check s.outline == nil and s.rle.spans.len == 0 and not s.fastTrack
    check sameRegion(s.bbox, Region())
    shapeFree(s)
    check s.rle == nil and s.fill == nil and s.stroke == nil

suite "stroke":
  test "butt line":
    let s = SwShape()
    var box: Region
    let rs = strokeShape(linePath(10, 20, 60, 20), 4)
    check shapeGenStrokeRle(s, rs, IdentityMatrix, clip, box, true)
    check sameRegion(box, region(10, 18, 60, 22))
    check abs(area(s.strokeRle) - 200.0) < 1.0
    check s.stroke != nil
    shapeDelStroke(s)
    check s.stroke == nil and s.strokeRle == nil

  test "square cap extends the line":
    let s = SwShape()
    var box: Region
    let rs = strokeShape(linePath(10, 20, 60, 20), 4, StrokeCap.Square)
    check shapeGenStrokeRle(s, rs, IdentityMatrix, clip, box, true)
    check sameRegion(box, region(8, 18, 62, 22))
    check abs(area(s.strokeRle) - 216.0) < 1.0

  test "closed rect with miter joins":
    let s = SwShape()
    var box: Region
    let rs = strokeShape(rectPath(20, 20, 40, 30), 4)
    check shapeGenStrokeRle(s, rs, IdentityMatrix, clip, box, true)
    check sameRegion(box, region(18, 18, 62, 52))
    check abs(area(s.strokeRle) - 560.0) < 1.0

  test "fill outline is reused by the stroke":
    let s = SwShape()
    var box: Region
    var rs = strokeShape(rectPath(20, 20, 40, 30), 4)
    check shapeGenRle(s, rs, IdentityMatrix, clip, box, true, true)
    let outline = s.outline
    check shapeGenStrokeRle(s, rs, IdentityMatrix, clip, box, true)
    check s.outline == outline
    check abs(area(s.strokeRle) - 560.0) < 1.0

  test "stroke clipped to the clip box":
    let s = SwShape()
    var box: Region
    let rs = strokeShape(linePath(10, 20, 160, 20), 4)
    check shapeGenStrokeRle(s, rs, IdentityMatrix, clip, box, true)
    check xRange(s.strokeRle) == (10, 100)

  test "no stroke":
    let s = SwShape()
    var box: Region
    check not shapeGenStrokeRle(s, fillShape(rectPath(1, 1, 5, 5)), IdentityMatrix, clip,
                                box, true)

  test "trimmed stroke":
    var rs = strokeShape(linePath(0, 10, 100, 10), 2)
    rs.stroke.get.trim = RenderTrimPath(begin: 0.0'f32, `end`: 0.5'f32, simultaneous: true)
    let s = SwShape()
    var box: Region
    check shapeGenStrokeRle(s, rs, IdentityMatrix, clip, box, true)
    let (x0, x1) = xRange(s.strokeRle)
    check x0 == 0 and abs(x1 - 50) <= 1

  test "stroke bounds":
    let s = SwShape()
    var pt4: array[4, Point]
    let rs = strokeShape(linePath(10, 20, 60, 20), 4)
    check shapeStrokeBBox(s, rs, pt4, IdentityMatrix)
    check abs(pt4[0].x - 10) < 0.01 and abs(pt4[0].y - 18) < 0.01
    check abs(pt4[2].x - 60) < 0.01 and abs(pt4[2].y - 22) < 0.01
    check abs(pt4[1].x - 60) < 0.01 and abs(pt4[3].y - 22) < 0.01
    check not shapeStrokeBBox(s, fillShape(linePath(0, 0, 5, 5)), pt4, IdentityMatrix)

suite "dash":
  proc dashed(p: RenderPath, pattern: seq[float32], offset = 0.0'f32,
              cap = StrokeCap.Butt): RenderShape =
    result = strokeShape(p, 2, cap)
    var len = 0.0'f32
    for v in pattern: len += v
    result.stroke.get.dash = RenderDash(pattern: pattern, offset: offset, length: len)

  test "line dashes":
    let s = SwShape()
    var box: Region
    let rs = dashed(linePath(0, 10, 100, 10), @[10.0'f32, 10.0'f32])
    check shapeGenStrokeRle(s, rs, IdentityMatrix, clip, box, true)
    check rowSpans(s.strokeRle, 9) == 5 and rowSpans(s.strokeRle, 10) == 5
    check s.strokeRle.spans.len == 10
    check abs(area(s.strokeRle) - 100.0 * 2.0 / 2.0) < 1.0
    let o = genDashOutline(rs, false)
    check o.moveCount == 5
    check o.fpts.len == 10

  test "dash offset":
    let rs = dashed(linePath(0, 10, 100, 10), @[10.0'f32, 10.0'f32], 5.0'f32)
    let o = genDashOutline(rs, false)
    check o.moveCount == 6
    check abs(o.fpts[1].x - 5.0'f32) < 0.01
    # negative offset wraps around the pattern
    let rn = dashed(linePath(0, 10, 100, 10), @[10.0'f32, 10.0'f32], -15.0'f32)
    check genDashOutline(rn, false).moveCount == 6

  test "odd pattern repeats mirrored":
    let rs = dashed(linePath(0, 10, 60, 10), @[10.0'f32])
    let o = genDashOutline(rs, false)
    check o.moveCount == 3
    check abs(o.fpts[0].x) < 0.01 and abs(o.fpts[1].x - 10.0'f32) < 0.01
    check abs(o.fpts[2].x - 20.0'f32) < 0.01 and abs(o.fpts[3].x - 30.0'f32) < 0.01

  test "closed rect joins the dashes across the seam":
    let rs = dashed(rectPath(0, 0, 40, 30), @[10.0'f32, 5.0'f32])
    let o = genDashOutline(rs, false)
    check o.moveCount == 9
    check o.cmds[0] == PathCommand.MoveTo
    # the last dash continues into the first one through the start point
    check o.cmds[^1] == PathCommand.LineTo

  test "curve dashes":
    var p: RenderPath
    p.moveTo(pt(0, 50))
    p.cubicTo(pt(0, 0), pt(100, 0), pt(100, 50))
    let rs = dashed(p, @[10.0'f32, 10.0'f32])
    let o = genDashOutline(rs, false)
    check o.moveCount >= 5
    var cubics = 0
    for c in o.cmds:
      if c == PathCommand.CubicTo: inc cubics
    check cubics == o.moveCount
    let s = SwShape()
    var box: Region
    check shapeGenStrokeRle(s, rs, IdentityMatrix, clip, box, true)
    check s.strokeRle.spans.len > 10

  test "zero length dash with round cap draws points":
    let rs = dashed(linePath(0, 10, 50, 10), @[0.0'f32, 10.0'f32], 0.0'f32, StrokeCap.Round)
    let o = genDashOutline(rs, false)
    check o.moveCount >= 4

  test "dashes of a trimmed path":
    var rs = dashed(linePath(0, 10, 100, 10), @[10.0'f32, 10.0'f32])
    rs.stroke.get.trim = RenderTrimPath(begin: 0.0'f32, `end`: 0.5'f32, simultaneous: true)
    let o = genDashOutline(rs, true)
    check o.moveCount == 3
    check abs(o.fpts[^1].x - 50.0'f32) < 0.05

  test "nothing to dash":
    check genDashOutline(fillShape(rectPath(0, 0, 5, 5)), false) == nil
    var rs = dashed(RenderPath(), @[1.0'f32, 1.0'f32])
    check genDashOutline(rs, false) == nil
