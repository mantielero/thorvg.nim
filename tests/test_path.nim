import std/unittest
import thorvg/core/[types, geom, path]

suite "path":
  test "move/line/close":
    var p: RenderPath
    p.moveTo(pt(0, 0))
    p.lineTo(pt(10, 0))
    p.close()
    p.close()
    check p.cmds == @[PathCommand.MoveTo, PathCommand.LineTo, PathCommand.Close]
    check p.pts.len == 2

  test "sharp rect":
    var p: RenderPath
    p.addRect(1, 2, 10, 20, 0, 0, true)
    check p.pts.len == 4
    check p.cmds.len == 5
    var box: BBox
    check p.bounds(box)
    check box.min == pt(1, 2)
    check box.max == pt(11, 22)

  test "round rect has 17 points":
    var p: RenderPath
    p.addRect(0, 0, 100, 50, 10, 10, true)
    check p.pts.len == 17
    check p.cmds.len == 10
    var ccw: RenderPath
    ccw.addRect(0, 0, 100, 50, 10, 10, false)
    check ccw.pts.len == 17
    check ccw.pts[0] == p.pts[0]
    check ccw.pts[16] == p.pts[16]

  test "circle":
    var p: RenderPath
    p.addCircle(50, 50, 10, 10, true)
    check p.pts.len == 13
    var box: BBox
    check p.bounds(box)
    check abs(box.min.x - 40) < 0.01
    check abs(box.max.y - 60) < 0.01

  test "bounds of empty path":
    var p: RenderPath
    var box: BBox
    check not p.bounds(box)

  test "point along a line":
    var p: RenderPath
    p.moveTo(pt(0, 0))
    p.lineTo(pt(10, 0))
    let q = p.point(0.5)
    check abs(q.x - 5) < 0.2
