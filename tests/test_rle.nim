import std/[unittest, math]
import thorvg/core/types
import thorvg/engine/cpu/[common, rle]

const Scale = 64.0

func sp(x, y: float): SwPoint = SwPoint(x: int32(x * Scale), y: int32(y * Scale))

proc polygon(pts: openArray[(float, float)], rule = FillRule.NonZero): SwOutline =
  result = SwOutline(fillRule: rule)
  for i, p in pts:
    result.cmds.add (if i == 0: PathCommand.MoveTo else: PathCommand.LineTo)
    result.pts.add sp(p[0], p[1])
  result.cmds.add PathCommand.Close

proc rectPath(o: SwOutline, x0, y0, x1, y1: float, reverse = false) =
  ## Appends a closed rectangle sub-path.
  let corners = if reverse: @[(x0, y0), (x0, y1), (x1, y1), (x1, y0)]
                else: @[(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
  for i, p in corners:
    o.cmds.add (if i == 0: PathCommand.MoveTo else: PathCommand.LineTo)
    o.pts.add sp(p[0], p[1])
  o.cmds.add PathCommand.Close

func region(x0, y0, x1, y1: int): Region =
  Region(xMin: int32(x0), yMin: int32(y0), xMax: int32(x1), yMax: int32(y1))

func coverageAt(r: SwRle, x, y: int): int =
  for s in r.spans:
    if int(s.y) == y and x >= int(s.x) and x < int(s.x + s.len): return int(s.coverage)
  0

func totalCoverage(r: SwRle): int =
  for s in r.spans: result += int(s.len) * int(s.coverage)

func sortedAndDisjoint(r: SwRle): bool =
  result = true
  for i in 1 ..< r.spans.len:
    let a = r.spans[i - 1]
    let b = r.spans[i]
    if b.y < a.y or (b.y == a.y and b.x < a.x + a.len): result = false

func circle(cx, cy, r: float): SwOutline =
  const K = 0.5522847498
  result = SwOutline()
  result.cmds = @[PathCommand.MoveTo, PathCommand.CubicTo, PathCommand.CubicTo,
                  PathCommand.CubicTo, PathCommand.CubicTo, PathCommand.Close]
  result.pts = @[sp(cx + r, cy),
    sp(cx + r, cy + K * r), sp(cx + K * r, cy + r), sp(cx, cy + r),
    sp(cx - K * r, cy + r), sp(cx - r, cy + K * r), sp(cx - r, cy),
    sp(cx - r, cy - K * r), sp(cx - K * r, cy - r), sp(cx, cy - r),
    sp(cx + K * r, cy - r), sp(cx + r, cy - K * r), sp(cx + r, cy)]

suite "rle render":
  test "pixel aligned rectangle":
    let o = polygon([(2.0, 3.0), (10.0, 3.0), (10.0, 8.0), (2.0, 8.0)])
    let r = rleRender(nil, o, region(0, 0, 20, 20), true)
    check r != nil
    check r.spans.len == 5
    for i, s in r.spans:
      check s == SwSpan(x: 2, y: int32(3 + i), len: 8, coverage: 255)

  test "reverse winding gives the same spans":
    let a = polygon([(2.0, 3.0), (10.0, 3.0), (10.0, 8.0), (2.0, 8.0)])
    let b = polygon([(2.0, 3.0), (2.0, 8.0), (10.0, 8.0), (10.0, 3.0)])
    check rleRender(nil, a, region(0, 0, 20, 20), true).spans ==
      rleRender(nil, b, region(0, 0, 20, 20), true).spans

  test "fractional edges give partial coverage":
    let o = polygon([(2.5, 1.0), (6.0, 1.0), (6.0, 2.0), (2.5, 2.0)])
    let r = rleRender(nil, o, region(0, 0, 10, 10), true)
    check r.spans.len == 2
    check r.spans[0] == SwSpan(x: 2, y: 1, len: 1, coverage: 128)
    check r.spans[1] == SwSpan(x: 3, y: 1, len: 3, coverage: 255)

  test "vertical half pixel":
    let o = polygon([(1.0, 1.0), (4.0, 1.0), (4.0, 1.5), (1.0, 1.5)])
    let r = rleRender(nil, o, region(0, 0, 10, 10), true)
    check r.spans == @[SwSpan(x: 1, y: 1, len: 3, coverage: 128)]

  test "triangle coverage":
    let o = polygon([(0.0, 0.0), (8.0, 0.0), (0.0, 8.0)])
    let r = rleRender(nil, o, region(0, 0, 16, 16), true)
    check sortedAndDisjoint(r)
    check coverageAt(r, 0, 0) == 255
    check coverageAt(r, 6, 0) == 255
    check abs(coverageAt(r, 7, 0) - 128) <= 2    # the diagonal cuts the pixel in half
    check coverageAt(r, 8, 0) == 0
    check coverageAt(r, 0, 7) in 120 .. 136
    check coverageAt(r, 1, 7) == 0
    check abs(totalCoverage(r) - 32 * 255) <= 40

  test "circle area":
    let r = rleRender(nil, circle(16, 16, 10), region(0, 0, 32, 32), true)
    check sortedAndDisjoint(r)
    let area = totalCoverage(r).float / 255.0
    check abs(area - PI * 100.0) < 3.5
    check coverageAt(r, 16, 16) == 255
    check coverageAt(r, 0, 0) == 0
    check coverageAt(r, 16, 6) > 200

  test "anti-alias off forces full coverage":
    let r = rleRender(nil, circle(16, 16, 10), region(0, 0, 32, 32), false)
    check r.spans.len > 0
    for s in r.spans: check s.coverage == 255

  test "even-odd versus non-zero":
    let nz = SwOutline(fillRule: FillRule.NonZero)
    nz.rectPath(0, 0, 12, 12)
    nz.rectPath(4, 4, 8, 8)
    let eo = SwOutline(fillRule: FillRule.EvenOdd, cmds: nz.cmds, pts: nz.pts)
    let a = rleRender(nil, nz, region(0, 0, 16, 16), true)
    let b = rleRender(nil, eo, region(0, 0, 16, 16), true)
    check coverageAt(a, 6, 6) == 255
    check coverageAt(b, 6, 6) == 0
    check coverageAt(b, 2, 6) == 255
    check totalCoverage(b) == (144 - 16) * 255
    # opposite winding of the inner square also makes a hole for non-zero
    let hole = SwOutline(fillRule: FillRule.NonZero)
    hole.rectPath(0, 0, 12, 12)
    hole.rectPath(4, 4, 8, 8, reverse = true)
    check coverageAt(rleRender(nil, hole, region(0, 0, 16, 16), true), 6, 6) == 0

  test "bbox clips the result":
    let o = polygon([(-5.0, -5.0), (30.0, -5.0), (30.0, 30.0), (-5.0, 30.0)])
    let bb = region(2, 3, 12, 9)
    let r = rleRender(nil, o, bb, true)
    check r.spans.len == 6
    for s in r.spans:
      check s.x == 2 and s.len == 10 and s.coverage == 255
      check s.y >= 3 and s.y < 9

  test "shape entirely outside the bbox gives no spans":
    let o = polygon([(50.0, 50.0), (60.0, 50.0), (60.0, 60.0), (50.0, 60.0)])
    check rleRender(nil, o, region(0, 0, 20, 20), true).spans.len == 0

  test "partially clipped on the left keeps the inside":
    let o = polygon([(-4.0, 2.0), (6.5, 2.0), (6.5, 3.0), (-4.0, 3.0)])
    let r = rleRender(nil, o, region(0, 0, 20, 20), true)
    check r.spans.len == 2
    check r.spans[0] == SwSpan(x: 0, y: 2, len: 6, coverage: 255)
    check r.spans[1].x == 6 and int(r.spans[1].coverage) in 126 .. 128

  test "nil outline and appending to an existing rle":
    check rleRender(nil, nil, region(0, 0, 4, 4), true) == nil
    let o = polygon([(1.0, 1.0), (3.0, 1.0), (3.0, 2.0), (1.0, 2.0)])
    let r = rleRender(nil, o, region(0, 0, 8, 8), true)
    let same = rleRender(r, o, region(0, 0, 8, 8), true)
    check same == r
    check r.spans.len == 2

  test "rectangle rle from region":
    let r = rleRender(region(3, 4, 8, 7))
    check r.spans == @[SwSpan(x: 3, y: 4, len: 5, coverage: 255),
                       SwSpan(x: 3, y: 5, len: 5, coverage: 255),
                       SwSpan(x: 3, y: 6, len: 5, coverage: 255)]
    check rleRender(region(3, 4, 8, 4)).spans.len == 0

suite "rle clip":
  proc square(x0, y0, x1, y1: float): SwRle =
    rleRender(nil, polygon([(x0, y0), (x1, y0), (x1, y1), (x0, y1)]),
              region(0, 0, 64, 64), true)

  test "clip by region":
    let r = square(2, 2, 12, 12)
    check rleClip(r, region(5, 4, 9, 8))
    check r.spans.len == 4
    for s in r.spans:
      check s.x == 5 and s.len == 4 and s.y >= 4 and s.y < 8

  test "clip by region with nothing left":
    let r = square(2, 2, 12, 12)
    check not rleClip(r, region(20, 20, 30, 30))
    check r.spans.len == 0
    let e = newRle()
    check not rleClip(e, region(0, 0, 4, 4))
    check not rleClip(square(2, 2, 4, 4), region(3, 3, 3, 9))

  test "clip by rle intersects spans":
    let r = square(2, 2, 12, 12)
    let c = square(6, 5, 20, 8)
    check rleClip(r, c)
    check r.spans.len == 3
    for s in r.spans:
      check s.x == 6 and s.len == 6 and s.coverage == 255
    check r.spans[0].y == 5 and r.spans[2].y == 7

  test "clip multiplies partial coverage":
    let r = square(0, 0, 8, 1.5)         # row 1 has 128 coverage
    let c = square(0, 0, 8, 1.5)
    check coverageAt(r, 3, 1) == 128
    check rleClip(r, c)
    check coverageAt(r, 0, 0) == 255
    check coverageAt(r, 3, 1) == (128 * 128 + 255) shr 8

  test "clip by disjoint rle":
    let r = square(0, 0, 4, 4)
    check not rleClip(r, square(10, 10, 20, 20))
    check r.spans.len == 0
    let r2 = square(0, 0, 4, 4)
    check not rleClip(r2, square(4, 0, 8, 4))
    check not rleClip(r2, newRle())

  test "intersect":
    let r = square(2, 2, 12, 12)
    check rleIntersect(r, region(0, 0, 3, 3))
    check rleIntersect(r, region(11, 11, 40, 40))
    check not rleIntersect(r, region(12, 0, 20, 20))
    check not rleIntersect(r, region(0, 12, 20, 20))
    check not rleIntersect(r, region(0, 0, 2, 20))
    check not rleIntersect(nil, region(0, 0, 20, 20))
    check not rleIntersect(newRle(), region(0, 0, 20, 20))

  test "merge keeps rows ordered":
    let a = square(0, 0, 2, 2)
    let b = square(5, 1, 7, 4)
    let m = newRle()
    rleMerge(m, a, b)
    check m.spans.len == 5
    check sortedAndDisjoint(m)
    check totalCoverage(m) == (4 + 6) * 255
    let only = newRle()
    rleMerge(only, a, newRle())
    check only.spans == a.spans
    rleMerge(only, newRle(), b)
    check only.spans == b.spans

  test "reset":
    let r = square(0, 0, 4, 4)
    rleReset(r)
    check r.spans.len == 0
    rleReset(nil)
