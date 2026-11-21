import std/unittest
import thorvg/core/[types, geom, bezier]

suite "geom":
  test "identity and multiply":
    let m = identity()
    check m * m == m
    check isIdentity(m)

  test "point transform":
    var m = identity()
    translate(m, pt(10, 20))
    scale(m, pt(2, 3))
    check pt(1, 1) * m == pt(12, 23)

  test "inverse":
    var m = identity()
    translate(m, pt(5, 7))
    scale(m, pt(2, 2))
    var inv: Matrix
    check inverse(m, inv)
    check (pt(3, 4) * m) * inv == pt(3, 4)

  test "singular matrix has no inverse":
    var m = identity()
    m.e11 = 0
    m.e22 = 0
    var inv: Matrix
    check not inverse(m, inv)

  test "nearbyint ties to even":
    check nearbyint(0.5'f32) == 0.0'f32
    check nearbyint(1.5'f32) == 2.0'f32
    check nearbyint(2.5'f32) == 2.0'f32
    check nearbyint(-1.5'f32) == -2.0'f32

  test "fastAtan2 close to atan2":
    check abs(fastAtan2(1, 1) - 0.7853982'f32) < 1e-3'f32
    check fastAtan2(0, 0) == 0.0'f32

  test "region intersect collapses":
    let a = initRegion(0, 0, 10, 10)
    let b = initRegion(20, 20, 30, 30)
    check invalid(intersect(a, b))
    check intersect(a, initRegion(5, 5, 15, 15)) == initRegion(5, 5, 10, 10)

suite "bezier":
  test "straight cubic length":
    let b = initBezier(pt(0, 0), pt(10, 0), pt(20, 0), pt(30, 0))
    check abs(length(b) - 30.0'f32) < 0.05'f32

  test "at midpoint":
    let b = initBezier(pt(0, 0), pt(10, 0), pt(20, 0), pt(30, 0))
    check b.at(0.5'f32) == pt(15, 0)

  test "bounds with extrema":
    var box = initBBox()
    bounds(box, pt(0, 0), pt(0, 10), pt(10, 10), pt(10, 0))
    check box.max.y > 7.0'f32
    check box.min.x == 0.0'f32

  test "path length":
    let cmds = [PathCommand.MoveTo, PathCommand.LineTo, PathCommand.Close]
    let pts = [pt(0, 0), pt(10, 0)]
    check abs(pathLength(cmds, pts) - 20.0'f32) < 0.01'f32
