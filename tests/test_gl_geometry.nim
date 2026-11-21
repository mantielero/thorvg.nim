## G2b: GL geometry (`gl_common`, `geometry`, `tessellator`, `tess_stroke`), no GL needed.
## The bit-exact comparison with the C++ original lives in `tests/gl/geometry_compare.ps1`;
## these are hand-derived expectations.
import std/[unittest, options]
import thorvg/core/[types, geom, path]
import thorvg/renderer/render
import thorvg/engine/gl/[geometry, gl_common, tessellator]

func pt(x, y: float32): Point = Point(x: x, y: y)

func rect(x, y, w, h: float32): RenderPath =
  result.moveTo(pt(x, y))
  result.lineTo(pt(x + w, y))
  result.lineTo(pt(x + w, y + h))
  result.lineTo(pt(x, y + h))
  result.close()

func scale(s: float32): Matrix = Matrix(e11: s, e22: s, e33: 1)

func region(x0, y0, x1, y1: int32): Region = Region(xMin: x0, yMin: y0, xMax: x1, yMax: y1)

func stroked(p: RenderPath, width: float32, cap = StrokeCap.Butt, join = StrokeJoin.Bevel,
             alpha = 255'u8): RenderShape =
  var st = initStroke()
  st.width = width
  st.cap = cap
  st.join = join
  RenderShape(path: p, color: RGBA(a: alpha), stroke: some(st))

func filled(p: RenderPath): RenderShape = RenderShape(path: p, color: RGBA(a: 255))

proc strokeOf(p: RenderPath, width: float32, cap = StrokeCap.Butt, join = StrokeJoin.Bevel): Stroker =
  result = initStroker(width, cap, join)
  result.run(p)

proc build(rs: RenderShape, m = IdentityMatrix, flags = {RenderUpdateFlag.Path, RenderUpdateFlag.Stroke}): GlShape =
  result = newGlShape(rs)
  result.updateShape(m, Region(), flags)

suite "sizes and matrices":
  test "uniform block sizes match the C++ sizeof":
    check sizeof(GlLinearGradientBlock) == 400
    check sizeof(GlRadialGradientBlock) == 416
    check sizeof(GlConicGradientBlock) == 384
    check sizeof(GlImageOpacityBlock) == 16

  test "getMatrix3 is column major":
    let m = Matrix(e11: 1, e12: 2, e13: 3, e21: 4, e22: 5, e23: 6, e31: 7, e32: 8, e33: 9)
    check getMatrix3(m) == [1'f32, 4, 7, 2, 5, 8, 3, 6, 9]
    check getMatrix3Std140(m) == [1'f32, 4, 7, 0, 2, 5, 8, 0, 3, 6, 9, 0]

  test "itransform is the cached inverse and follows transform":
    var g = initGlGeometry()
    g.transform(scale(2))
    check g.itransform().e11 == 0.5'f32
    g.transform(Matrix(e11: 1, e13: 4, e22: 1, e23: 6, e33: 1))
    let inv = g.itransform()
    check inv.e13 == -4'f32
    check inv.e23 == -6'f32

suite "BWTessellator":
  test "a rectangle is two triangles and convex":
    var bw = initBWTessellator()
    bw.tessellate(rect(0, 0, 10, 10))
    check bw.convex
    check bw.bounds == region(0, 0, 10, 10)
    check bw.buffer.vertex == @[0'f32, 0, 10, 0, 10, 10, 0, 10]
    check bw.buffer.index == @[0'u32, 1, 2, 0, 2, 3]

  test "a path with a hole is not convex":
    var p = rect(0, 0, 30, 30)
    p.moveTo(pt(10, 10)); p.lineTo(pt(10, 20)); p.lineTo(pt(20, 20)); p.lineTo(pt(20, 10)); p.close()
    var bw = initBWTessellator()
    bw.tessellate(p)
    check not bw.convex
    check bw.bounds == region(0, 0, 30, 30)
    check bw.buffer.index.len mod 3 == 0
    check bw.buffer.index.len > 6

  test "a single point makes nothing":
    var p: RenderPath
    p.moveTo(pt(3, 3))
    var bw = initBWTessellator()
    bw.tessellate(p)
    check bw.buffer.index.len == 0

suite "Stroker":
  test "butt line: one quad around the segment":
    var s = strokeOf((var p: RenderPath; p.moveTo(pt(0, 0)); p.lineTo(pt(10, 0)); p), 2)
    check s.buffer.vertex == @[0'f32, 1, 0, -1, 10, 1, 10, -1]
    check s.buffer.index == @[0'u32, 1, 2, 1, 3, 2]
    check s.bounds == region(0, -1, 10, 1)
    check s.overlapFree

  test "square cap extends both ends by half the width":
    var p: RenderPath
    p.moveTo(pt(0, 0)); p.lineTo(pt(10, 0))
    let s = strokeOf(p, 2, StrokeCap.Square)
    check s.bounds == region(-1, -1, 11, 1)
    check s.buffer.index.len == 18
    check s.buffer.vertex.len == 24

  test "round cap is a fan of triangles inside the cap box":
    var p: RenderPath
    p.moveTo(pt(0, 0)); p.lineTo(pt(10, 0))
    let s = strokeOf(p, 2, StrokeCap.Round)
    check s.bounds == region(-1, -1, 11, 1)
    check s.buffer.index.len == 30
    check s.buffer.vertex[^2 .. ^1] == @[10'f32, -1]

  test "elbow joins: bevel / miter / round":
    var p: RenderPath
    p.moveTo(pt(0, 0)); p.lineTo(pt(10, 0)); p.lineTo(pt(10, 10))
    let bevel = strokeOf(p, 2, join = StrokeJoin.Bevel)
    let miter = strokeOf(p, 2, join = StrokeJoin.Miter)
    let round = strokeOf(p, 2, join = StrokeJoin.Round)
    check bevel.buffer.index.len == 15       # two quads + one bevel triangle
    check miter.buffer.index.len == 18       # the miter adds one triangle
    check round.buffer.index.len == 18
    for s in [bevel, miter, round]:
      check s.bounds == region(0, -1, 11, 10)
      check s.overlapFree
    check miter.buffer.vertex[^2 .. ^1] == @[11'f32, -1]   # the miter tip

  test "every index points to an existing vertex":
    var p: RenderPath
    p.moveTo(pt(0, 0)); p.lineTo(pt(20, 0)); p.cubicTo(pt(30, 10), pt(30, 20), pt(20, 30)); p.close()
    for cap in [StrokeCap.Butt, StrokeCap.Round, StrokeCap.Square]:
      for join in [StrokeJoin.Miter, StrokeJoin.Round, StrokeJoin.Bevel]:
        let s = strokeOf(p, 3, cap, join)
        check s.buffer.index.len > 0
        check s.buffer.index.len mod 3 == 0
        for i in s.buffer.index: check int(i) * 2 < s.buffer.vertex.len

  test "BWTessellator: a cubic without a start point raises, no out of bounds read (D-G2b)":
    var p: RenderPath
    p.cmds.add PathCommand.CubicTo
    p.pts.add [pt(1, 1), pt(2, 2), pt(3, 3)]
    var bw = initBWTessellator()
    expect IndexDefect:
      bw.tessellate(p)

suite "GlGeometry":
  test "image quad: vertices (x y u v), indices, bounds":
    var g = initGlGeometry()
    g.transform(scale(2))
    g.tesselateImage(RenderSurface(w: 4, h: 3))
    check g.fill.vertex == @[0'f32, 0, 0, 0, 0, 6, 0, 1, 8, 0, 1, 0, 8, 6, 1, 1]
    check g.fill.index == @[0'u32, 1, 2, 2, 1, 3]
    check g.fillBBox == region(0, 0, 8, 6)
    check g.bounds() == region(0, 0, 8, 6)
    check g.drawable({RenderUpdateFlag.Image})
    check g.stencilMode({RenderUpdateFlag.Image}) == GlStencilMode.None

  test "image hit test follows the quad":
    let image = newGlImage(RenderSurface(w: 10, h: 10))
    image.geometry.transform(IdentityMatrix)
    image.geometry.tesselateImage(RenderSurface(w: 10, h: 10))
    check intersect(image, region(5, 5, 8, 8))
    check intersect(image, region(-3, -3, 1, 1))
    check not intersect(image, region(20, 20, 24, 24))
    check not intersect(image, region(-9, -9, 0, 0))

  test "filled rectangle: convex, no stencil, world-space fill":
    let shape = build(filled(rect(0, 0, 10, 10)))
    check shape.valid == (fill: true, stroke: false)
    check shape.multiplier == 1'f32
    check shape.geometry.convex
    check shape.geometry.fillWorld
    check shape.geometry.fillBBox == region(0, 0, 10, 10)
    check shape.geometry.stencilMode({RenderUpdateFlag.Path}) == GlStencilMode.None
    check shape.geometry.drawable({RenderUpdateFlag.Path})
    check not shape.geometry.drawable({RenderUpdateFlag.Stroke})
    check not shape.geometry.drawable({})

  test "stencil mode follows the fill rule of a non convex path":
    var p = rect(0, 0, 30, 30)
    p.moveTo(pt(10, 10)); p.lineTo(pt(10, 20)); p.lineTo(pt(20, 20)); p.lineTo(pt(20, 10)); p.close()
    var rs = filled(p)
    check build(rs).geometry.stencilMode({RenderUpdateFlag.Path}) == GlStencilMode.FillNonZero
    rs.rule = FillRule.EvenOdd
    let shape = build(rs)
    check shape.geometry.stencilMode({RenderUpdateFlag.Path}) == GlStencilMode.FillEvenOdd
    check shape.geometry.stencilMode({RenderUpdateFlag.Image}) == GlStencilMode.None

  test "stroked rectangle: render width, bounds and direct (overlap free) stroke":
    let shape = build(stroked(rect(0, 0, 10, 10), 2), scale(1))
    check shape.valid == (fill: true, stroke: true)
    check shape.geometry.strokeRenderWidth == 2'f32
    check shape.geometry.strokeBBox == region(-1, -1, 11, 11)
    check shape.geometry.bounds() == region(-1, -1, 11, 11)
    check shape.geometry.strokeDirect
    check shape.geometry.stencilMode({RenderUpdateFlag.Stroke}) == GlStencilMode.None

  test "stroke render width follows the matrix scale":
    let shape = build(stroked(rect(0, 0, 10, 10), 2), scale(3))
    check shape.geometry.strokeRenderWidth == 6'f32
    check shape.geometry.fillBBox == region(0, 0, 30, 30)
    check shape.geometry.strokeBBox == region(-1, -1, 11, 11)   # stroke stays in local space
    check shape.geometry.bounds() == region(-3, -3, 33, 33)

  test "zero or non finite stroke width gives no stroke":
    check not build(stroked(rect(0, 0, 10, 10), 0)).valid.stroke
    check not build(stroked(rect(0, 0, 10, 10), -0.0'f32)).valid.stroke
    check not build(stroked(rect(0, 0, 10, 10), Inf)).valid.stroke

  test "a singular matrix draws nothing":
    let shape = build(stroked(rect(0, 0, 10, 10), 2), Matrix(e33: 1))
    check not shape.valid.stroke
    check shape.geometry.bounds() == Region()

  test "a very thin filled path uses the stroker with a quarter alpha":
    let shape = build(filled(rect(0, 0, 100, 0.2'f32)))
    check shape.valid.fill
    check shape.geometry.optPathThin
    check shape.multiplier == 0.25'f32
    check not shape.geometry.convex
    check shape.geometry.fill.index.len > 0
    check shape.geometry.stroke.index.len == 0

  test "an empty path is not drawable":
    var p: RenderPath
    p.moveTo(pt(3, 3))
    let shape = build(filled(p))
    check shape.geometry.fill.index.len == 0     # like the C++, `valid.fill` only says "not thin/skipped"
    check not shape.geometry.drawable({RenderUpdateFlag.Path})
    check not intersect(shape, region(0, 0, 10, 10))

  test "a dashed stroke uses the dash path":
    var rs = stroked((var p: RenderPath; p.moveTo(pt(0, 0)); p.lineTo(pt(20, 0)); p), 2)
    rs.stroke.get.dash.pattern = @[5'f32, 5]
    rs.stroke.get.dash.length = 10
    let shape = build(rs)
    check shape.valid.stroke
    check shape.geometry.strokeBBox == region(0, -1, 15, 1)
    check shape.geometry.stroke.index.len == 12     # two dashes, two quads

suite "intersect":
  test "fill hit test in world space":
    let shape = build(filled(rect(10, 10, 10, 10)), scale(2))
    check intersect(shape, region(30, 30, 32, 32))
    check intersect(shape, region(39, 39, 44, 44))
    check not intersect(shape, region(0, 0, 10, 10))
    check not intersect(shape, region(40, 40, 44, 44))
    check not intersect(shape, region(60, 60, 70, 70))

  test "stroke only shape: hit on the line, miss in the middle":
    var rs = stroked(rect(0, 0, 40, 40), 4)
    rs.color.a = 0
    let shape = build(rs)
    check shape.valid.stroke
    check intersect(shape, region(-1, 10, 0, 11))
    check not intersect(shape, region(10, 10, 15, 15))

  test "an unpainted fill does not hit":
    var rs = filled(rect(0, 0, 10, 10))
    rs.color.a = 0
    check not intersect(build(rs), region(2, 2, 5, 5))

  test "clips restrict the hit":
    let shape = build(filled(rect(0, 0, 100, 100)))
    shape.clips = @[RenderData(build(filled(rect(0, 0, 10, 10))))]
    check intersect(shape, region(2, 2, 5, 5))
    check not intersect(shape, region(50, 50, 53, 53))
    check intersect(shape.clips, pt(5, 5))
    check not intersect(shape.clips, pt(15, 5))

suite "GlDrawable.prepare":
  test "opacity 0 postpones the update, later flags are merged back":
    let d = GlDrawable()
    var flags = {RenderUpdateFlag.Path}
    check d.prepare(flags, pt(100, 50), 0, false)
    check d.opacity == 0
    check d.flags == {RenderUpdateFlag.Path}
    flags = {RenderUpdateFlag.Transform}
    check not d.prepare(flags, pt(100, 50), 255, false)
    check flags == {RenderUpdateFlag.Path, RenderUpdateFlag.Transform}
    check d.flags == {}
    check d.size == pt(100, 50)

  test "a clipper is prepared even when invisible":
    let d = GlDrawable()
    var flags = {RenderUpdateFlag.Path}
    check not d.prepare(flags, pt(1, 2), 0, true)

  test "nothing to update":
    let d = GlDrawable()
    var flags: RenderUpdateFlags
    check d.prepare(flags, pt(1, 2), 255, false)


