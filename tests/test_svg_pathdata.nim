import std/unittest
import thorvg/core/[types, geom, path]
import thorvg/loaders/svg/pathdata

const M = PathCommand.MoveTo
const L = PathCommand.LineTo
const C = PathCommand.CubicTo
const Z = PathCommand.Close

proc parse(d: string): RenderPath =
  discard parsePath(d, result)

proc near(a, b: Point, eps = 0.05'f32): bool = abs(a.x - b.x) <= eps and abs(a.y - b.y) <= eps

suite "pathdata lines":
  test "absolute commands and close":
    let p = parse("M10 20 L30 40 Z")
    check p.cmds == @[M, L, Z]
    check p.pts == @[pt(10, 20), pt(30, 40)]

  test "relative commands and implicit repeats":
    let p = parse("m10 20 l5 5")
    check p.pts == @[pt(10, 20), pt(15, 25)]
    let q = parse("m 1 2 3 4 5 6")
    check q.cmds == @[M, L, L]
    check q.pts == @[pt(1, 2), pt(4, 6), pt(9, 12)]
    let r = parse("M1 2 3 4")
    check r.cmds == @[M, L]
    check r.pts == @[pt(1, 2), pt(3, 4)]

  test "H V h v":
    let p = parse("M0 0 H10 V5 h-2 v1")
    check p.cmds == @[M, L, L, L, L]
    check p.pts == @[pt(0, 0), pt(10, 0), pt(10, 5), pt(8, 5), pt(8, 6)]
    check parse("M0 0 H1 2 3").pts == @[pt(0, 0), pt(1, 0), pt(2, 0), pt(3, 0)]

  test "close returns to the sub-path start, then relative moves start from there":
    let p = parse("M0 0 L10 0 L10 10 z m 5 5 l 1 1")
    check p.cmds == @[M, L, L, Z, M, L]
    check p.pts == @[pt(0, 0), pt(10, 0), pt(10, 10), pt(5, 5), pt(6, 6)]

suite "pathdata numbers":
  test "exponents and signs":
    let p = parse("M1e1 2E0 L-1.5e+1 5e-2")
    check p.pts[0] == pt(10, 2)
    check p.pts[1] == pt(-15, 0.05)

  test "compact forms":
    let p = parse("M10-5.5.5 1")
    check p.cmds == @[M, L]
    check p.pts == @[pt(10, -5.5), pt(0.5, 1)]
    check parse("M1,2,3,4").pts == @[pt(1, 2), pt(3, 4)]
    check parse("M 1 , 2 L 3 , 4").pts == @[pt(1, 2), pt(3, 4)]
    check parse("M0 0l1.5.5").pts == @[pt(0, 0), pt(1.5, 0.5)]

suite "pathdata curves":
  test "cubic and smooth cubic":
    let p = parse("M0 0 C0 10 10 10 10 0 S20 -10 20 0")
    check p.cmds == @[M, C, C]
    check p.pts[3] == pt(10, 0)
    check p.pts[4] == pt(10, -10) # reflected control point
    check p.pts[^1] == pt(20, 0)

  test "smooth cubic without a previous cubic uses the current point":
    let p = parse("M5 5 S10 10 20 5")
    check p.pts[1] == pt(5, 5)

  test "quadratics become cubics":
    let p = parse("M0 0 Q3 6 6 0")
    check p.cmds == @[M, C]
    check near(p.pts[1], pt(2, 4), 1e-5)
    check near(p.pts[2], pt(4, 4), 1e-5)
    check p.pts[3] == pt(6, 0)

  test "smooth quadratic reflects the last quadratic control":
    let p = parse("M0 0 Q3 6 6 0 T12 0")
    check p.cmds == @[M, C, C]
    check near(p.pts[4], pt(8, -4), 1e-4)
    check near(p.pts[5], pt(10, -4), 1e-4)
    check p.pts[6] == pt(12, 0)

  test "relative curves":
    let p = parse("M10 10 c1 2 3 4 5 6")
    check p.pts == @[pt(10, 10), pt(11, 12), pt(13, 14), pt(15, 16)]

suite "pathdata arcs":
  test "semicircle with sweep becomes three cubics through the upper half":
    let p = parse("M0 0 A10 10 0 0 1 20 0")
    check p.cmds == @[M, C, C, C]
    check near(p.pts[3], pt(5, -8.66))
    check near(p.pts[6], pt(15, -8.66))
    check near(p.pts[^1], pt(20, 0), 1e-3)

  test "sweep flag mirrors the arc":
    let p = parse("M0 0 A10 10 0 0 0 20 0")
    check near(p.pts[3], pt(5, 8.66))

  test "large arc flag chooses the other center":
    let small = parse("M0 0 A10 10 0 0 1 10 10")
    let large = parse("M0 0 A10 10 0 1 1 10 10")
    check small.cmds.len < large.cmds.len
    check near(small.pts[^1], pt(10, 10), 1e-3)
    check near(large.pts[^1], pt(10, 10), 1e-3)

  test "flags may be written without separators":
    check parse("M0 0a10 10 0 1120 0").pts == parse("M0 0a10 10 0 1 1 20 0").pts
    check parse("M0 0a10 10 0 1,1,20,0").pts == parse("M0 0a10 10 0 1 1 20 0").pts

  test "radii too small are scaled up":
    let p = parse("M0 0 A1 1 0 0 1 20 0")
    check near(p.pts[^1], pt(20, 0), 1e-3)
    check p.cmds.len >= 3

  test "relative arc":
    let p = parse("M5 5 a10 10 0 0 1 20 0")
    check near(p.pts[^1], pt(25, 5), 1e-3)

  test "zero radius is a line, same endpoint is skipped":
    check parse("M0 0 A0 5 0 0 0 10 10").cmds == @[M, L]
    check parse("M0 0 A5 5 0 0 0 0 0").cmds == @[M]

suite "pathdata errors":
  test "must start with a move":
    var p: RenderPath
    check not parsePath("L10 10", p)
    var q: RenderPath
    check parsePath("", q)
    check q.empty

  test "stops at the first error but keeps the valid prefix":
    var p: RenderPath
    check parsePath("M0 0 L1 1 L2", p)
    check p.cmds == @[M, L]
    check parse("M0 0 X 1 2").cmds == @[M]
    check parse("M0 0 E 1 2 3 4 5 6").cmds == @[M]
    check parse("M10").cmds.len == 0
    check parse("M0 0 Z 5 5").cmds == @[M, Z]
    check parse("M0 0 A1 1 0 2 0 5 5").cmds == @[M]

  test "appends to an existing path":
    var p: RenderPath
    p.moveTo(pt(1, 1))
    p.lineTo(pt(2, 2))
    check parsePath("M5 5 L6 6", p)
    check p.cmds == @[M, L, M, L]
    var q: RenderPath
    q.moveTo(pt(1, 1))
    check not parsePath("L6 6", q)
