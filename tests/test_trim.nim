import std/unittest
import thorvg/core/[types, geom, path]
import thorvg/renderer/[render, trim]

proc near(a, b: Point, tol = 0.01'f32): bool =
  abs(a.x - b.x) <= tol and abs(a.y - b.y) <= tol

proc polyline(): RenderPath =
  result.moveTo(pt(0, 0))
  result.lineTo(pt(100, 0))
  result.lineTo(pt(100, 100))

proc trimmed(begin, en: float32, input: RenderPath, simultaneous = true): RenderPath =
  let t = RenderTrimPath(begin: begin, `end`: en, simultaneous: simultaneous)
  discard t.trim(input, result)

const
  M = PathCommand.MoveTo
  L = PathCommand.LineTo
  C = PathCommand.CubicTo
  Z = PathCommand.Close

suite "trim path":
  test "rejects degenerate input":
    var output: RenderPath
    var single: RenderPath
    single.moveTo(pt(1, 1))
    check not RenderTrimPath(begin: 0.0, `end`: 1.0, simultaneous: true).trim(single, output)
    check not RenderTrimPath(begin: 0.5, `end`: 0.5, simultaneous: true).trim(polyline(), output)
    check output.empty

  test "single line middle":
    var input: RenderPath
    input.moveTo(pt(0, 0))
    input.lineTo(pt(100, 0))
    var output: RenderPath
    check RenderTrimPath(begin: 0.25, `end`: 0.75, simultaneous: true).trim(input, output)
    check output.cmds == @[M, L]
    check near(output.pts[0], pt(25, 0))
    check near(output.pts[1], pt(75, 0))

  test "polyline crossing a corner":
    let o = trimmed(0.25, 0.75, polyline())
    check o.cmds == @[M, L, L]
    check near(o.pts[0], pt(50, 0))
    check near(o.pts[1], pt(100, 0))
    check near(o.pts[2], pt(100, 50))

  test "full range keeps the path":
    let o = trimmed(0.0, 1.0, polyline())
    check o.cmds == @[M, L, L]
    check near(o.pts[0], pt(0, 0))
    check near(o.pts[2], pt(100, 100))

  test "inverted range inside 0..1 is swapped":
    let o = trimmed(0.75, 0.25, polyline())
    check o.cmds == @[M, L, L]
    check near(o.pts[0], pt(50, 0))
    check near(o.pts[2], pt(100, 50))

  test "negative begin loops over the end":
    let o = trimmed(-0.25, 0.25, polyline())
    check o.cmds == @[M, L, M, L]
    check near(o.pts[0], pt(100, 50))
    check near(o.pts[1], pt(100, 100))
    check near(o.pts[2], pt(0, 0))
    check near(o.pts[3], pt(50, 0))

  test "closed rectangle tail uses the closing edge":
    var input: RenderPath
    input.addRect(0, 0, 100, 100, 0, 0, true)
    let o = trimmed(0.9, 1.0, input)
    check o.cmds == @[M, L]
    check near(o.pts[0], pt(60, 0))
    check near(o.pts[1], pt(100, 0))

  test "closed rectangle head drops the close":
    var input: RenderPath
    input.addRect(0, 0, 100, 100, 0, 0, true)
    let o = trimmed(0.0, 0.5, input)
    check o.cmds == @[M, L, L]
    check near(o.pts[0], pt(100, 0))
    check near(o.pts[2], pt(0, 100))

  test "simultaneous trims every sub-path, sequential trims the whole":
    var input: RenderPath
    input.moveTo(pt(0, 0))
    input.lineTo(pt(100, 0))
    input.moveTo(pt(0, 10))
    input.lineTo(pt(100, 10))
    let sim = trimmed(0.0, 0.5, input, true)
    check sim.cmds == @[M, L, M, L]
    check near(sim.pts[1], pt(50, 0))
    check near(sim.pts[3], pt(50, 10))
    let seqd = trimmed(0.0, 0.5, input, false)
    check seqd.cmds == @[M, L]
    check near(seqd.pts[1], pt(100, 0))

  test "cubic is split by arc length":
    var input: RenderPath
    input.moveTo(pt(0, 0))
    input.cubicTo(pt(100.0 / 3.0, 0), pt(200.0 / 3.0, 0), pt(100, 0))
    let o = trimmed(0.0, 0.5, input)
    check o.cmds == @[M, C]
    check near(o.pts[0], pt(0, 0))
    check near(o.pts[3], pt(50, 0), 0.5)

  test "appends to existing output":
    var output: RenderPath
    output.moveTo(pt(-5, -5))
    output.lineTo(pt(-6, -6))
    check RenderTrimPath(begin: 0.0, `end`: 0.5, simultaneous: true).trim(polyline(), output)
    check output.cmds == @[M, L, M, L]
    check output.pts[0] == pt(-5, -5)

  test "lone close after the last point does not crash":
    var input: RenderPath
    input.moveTo(pt(0, 0))
    input.lineTo(pt(10, 0))
    input.close()
    input.cmds.add Z
    let o = trimmed(0.0, 0.5, input)
    check o.pts.len >= 2
