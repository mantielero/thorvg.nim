## GL geometry: path optimization, fill / stroke / image tessellation, bounds, stencil mode and
## the CPU hit tests (`GlGeometry` + `GlIntersector` of `tvgGlGeometry.cpp`). No GL calls.
##
## API (same names as the C++ methods, `g: var GlGeometry`):
##   `g.transform(m)`                          set the local -> world matrix (in `gl_common`)
##   `g.prepare(rshape)`                       trim + `gpuOptimize` into `optPath` / `optStrokePath`
##   `g.tesselateShape(rshape, multiplier)`    fills `g.fill`, `fillBBox`, `convex`, `fillRule`;
##                                             false if nothing to draw (`multiplier` = 0.25 for
##                                             thin fills, else 1)
##   `g.tesselateStroke(rshape)`               fills `g.stroke`, `strokeBBox`, `strokeDirect`,
##                                             `strokeRenderWidth`
##   `g.tesselateImage(surface)`               4 vertices (x, y, u, v) + 6 indices
##   `g.stencilMode(flags)`, `g.bounds()`, `g.drawable(flags)`
##   `updateShape(shape, m, viewport, flags)`  the geometry part of `GlRenderer::prepare(shape)`
##   `intersect(clips, pt)`, `intersect(shape, region)`, `intersect(image, region)`
##
## Buffers: `g.fill` / `g.stroke` hold `seq[float32]` vertices and `seq[uint32]` indices ready for
## `GlStageBuffer.push` / `pushIndex` (`GlGeometry::draw` itself belongs to G3a).
## Deviation: a malformed path (`CubicTo` without a start point) raises `IndexDefect` instead of
## reading out of bounds. Bit-exact oracle: `tests/gl/geometry_compare.ps1`.

import std/options
import ../../core/[types, geom, path]
import ../../renderer/[render, trim]
import ./[gl_common, gpu_path, gpu_dash, gpu_probe, tessellator]
export gl_common

{.push floatChecks: false.}

func strokeCap(rs: RenderShape): StrokeCap =
  if rs.stroke.isSome: rs.stroke.get.cap else: StrokeCap.Square

func strokeJoin(rs: RenderShape): StrokeJoin =
  if rs.stroke.isSome: rs.stroke.get.join else: StrokeJoin.Bevel

func strokeMiterlimit(rs: RenderShape): float32 =
  if rs.stroke.isSome: rs.stroke.get.miterlimit else: 4.0'f32

# ---------------------------------------------------------------- GlIntersector

proc intersect*(clips: seq[RenderData], pt: Point): bool =
  ## True if `pt` is inside every clip shape.
  for c in clips:
    let clip = GlShape(c)
    if clip.valid.fill:
      let p = if clip.geometry.fillWorld: pt else: pt * clip.geometry.itransform()
      if not clip.geometry.fillBBox.inside(p) or
          not gpuPointInFillMesh(p, clip.geometry.fill.vertex, clip.geometry.fill.index,
                                 clip.geometry.fillRule):
        return false
    elif clip.valid.stroke:
      let p = pt * clip.geometry.itransform()
      if not clip.geometry.strokeBBox.inside(p) or
          not gpuPointInAnyMesh(p, clip.geometry.stroke.vertex, clip.geometry.stroke.index):
        return false
  true

proc intersect*(shape: GlShape, region: Region): bool =
  ## True if any pixel of `region` hits the fill or the stroke (and the clips).
  # the fill is tessellated regardless of its paint (clippers need it), skip it if unpainted
  let validFill = shape.valid.fill and shape.geometry.fill.index.len != 0 and
    (shape.rshape.fill.isSome or shape.rshape.color.a > 0)
  let validStroke = shape.valid.stroke and shape.geometry.stroke.index.len != 0
  if not validFill and not validStroke: return false

  let itransform = shape.geometry.itransform()
  let sizeX = region.sw
  let sizeY = region.sh
  for y in 0'i32 ..< sizeY:
    let py = if y mod 2 == 0: y else: sizeY - y - sizeY mod 2
    for x in 0'i32 ..< sizeX:
      let pt = Point(x: float32(x) + float32(region.xMin), y: float32(py) + float32(region.yMin))
      var hit = false
      if validFill:
        let p = if shape.geometry.fillWorld: pt else: pt * itransform
        hit = shape.geometry.fillBBox.inside(p) and
          gpuPointInFillMesh(p, shape.geometry.fill.vertex, shape.geometry.fill.index,
                             shape.geometry.fillRule)
      if not hit and validStroke:
        let p = pt * itransform
        hit = shape.geometry.strokeBBox.inside(p) and
          gpuPointInAnyMesh(p, shape.geometry.stroke.vertex, shape.geometry.stroke.index)
      if hit and intersect(shape.clips, pt): return true
  false

proc intersect*(image: GlImage, region: Region): bool =
  ## True if any pixel of `region` is inside the image quad (and the clips).
  let mesh = image.geometry.fill
  if mesh.index.len < 6: return false

  var triangle: array[6, Point]
  for i in 0 ..< 6:
    let idx = int(mesh.index[i]) * 4
    triangle[i] = Point(x: mesh.vertex[idx], y: mesh.vertex[idx + 1])

  let sizeX = region.sw
  let sizeY = region.sh
  for y in 0'i32 ..< sizeY:
    let py = if y mod 2 == 0: y else: sizeY - y - sizeY mod 2
    for x in 0'i32 ..< sizeX:
      let pt = Point(x: float32(x) + float32(region.xMin), y: float32(py) + float32(region.yMin))
      if gpuPointInQuad(pt, triangle) and intersect(image.clips, pt): return true
  false

# ---------------------------------------------------------------- GlGeometry

proc prepare*(g: var GlGeometry, rshape: RenderShape) =
  ## Trims and optimizes the path in transformed space; `optStrokePath` gets the matching local
  ## path when the shape has a visible stroke.
  g.optPathThin = false
  g.optPathSkipFill = false
  g.optStrokePath.clear()

  let strokeWidth = rshape.strokeWidth
  let wantLocal = isFinite32(strokeWidth) and not zero(strokeWidth)
  var res: GpuOptimizeResult
  if rshape.trimpath:
    var trimmed = RenderPath()
    if rshape.stroke.get.trim.trim(rshape.path, trimmed):
      res = gpuOptimize(trimmed, g.matrix, wantLocal)
    else:
      g.optPath.clear()
      return
  else:
    res = gpuOptimize(rshape.path, g.matrix, wantLocal)
  g.optPath = move res.transformed
  if wantLocal: g.optStrokePath = move res.local
  g.optPathThin = res.thin
  g.optPathSkipFill = res.skipFill

proc tesselateThinFill*(g: var GlGeometry, path: RenderPath): bool =
  ## Thin fills borrow the stroke tessellation (1px butt/bevel stroke, winding preserved).
  g.stroke.clear()
  g.strokeBBox = Region()
  if path.pts.len < 2: return false
  var stroker = initStroker(MinGlStrokeWidth, StrokeCap.Butt, StrokeJoin.Bevel)
  stroker.run(path, true)
  g.fill = move stroker.buffer
  g.fillBBox = stroker.bounds()
  g.strokeRenderWidth = 0.0'f32
  true

proc tesselateShape*(g: var GlGeometry, rshape: RenderShape, multiplier: var float32): bool =
  g.fill.clear()
  g.fillBBox = Region()
  g.fillWorld = true
  g.convex = false
  multiplier = 1.0'f32

  # `skipFill`: the path stayed thin enough that even the thin fallback should not draw a fill
  if g.optPathSkipFill: return false

  # a filled path scaled thinner than 1px in device space is drawn by the stroker, with alpha
  if g.optPathThin and zero(rshape.strokeWidth):
    if g.tesselateThinFill(g.optPath):
      multiplier = MinGlStrokeAlpha
      g.fillRule = rshape.rule
      return true
    return false

  var bw = initBWTessellator()
  bw.tessellate(g.optPath)
  g.fill = move bw.buffer
  g.fillRule = rshape.rule
  g.fillBBox = bw.bounds()
  g.convex = bw.convex
  true

proc tesselateStroke*(g: var GlGeometry, rshape: RenderShape): bool =
  g.stroke.clear()
  g.strokeBBox = Region()
  g.strokeRenderWidth = 0.0'f32

  let strokeWidth = rshape.strokeWidth
  if not isFinite32(strokeWidth) or zero(strokeWidth): return false

  let qualityScale = scaling(g.matrix)
  if not isFinite32(qualityScale) or zero(qualityScale): return false
  g.strokeRenderWidth = strokeWidth * qualityScale
  if not isFinite32(g.strokeRenderWidth): return false

  # stroke vertices stay local; GL applies the model matrix later
  var stroker = initStroker(strokeWidth, rshape.strokeCap, rshape.strokeJoin,
                            rshape.strokeMiterlimit, qualityScale)
  var dashed = RenderPath()
  if gpuStrokeDash(rshape, g.matrix, false, dashed): stroker.run(dashed)
  else: stroker.run(g.optStrokePath)
  g.strokeBBox = stroker.bounds()
  g.strokeDirect = stroker.overlapFree
  g.stroke = move stroker.buffer
  true

proc tesselateImage*(g: var GlGeometry, image: RenderSurface) =
  g.fill.clear()
  g.fillWorld = true
  g.strokeRenderWidth = 0.0'f32
  let w = float32(image.w)
  let h = float32(image.h)
  let leftTop = Point(x: 0.0'f32, y: 0.0'f32) * g.matrix
  let leftBottom = Point(x: 0.0'f32, y: h) * g.matrix
  let rightTop = Point(x: w, y: 0.0'f32) * g.matrix
  let rightBottom = Point(x: w, y: h) * g.matrix

  for (pt, u, v) in [(leftTop, 0.0'f32, 0.0'f32), (leftBottom, 0.0'f32, 1.0'f32),
                     (rightTop, 1.0'f32, 0.0'f32), (rightBottom, 1.0'f32, 1.0'f32)]:
    g.fill.vertex.add [pt.x, pt.y, u, v]
  g.fill.index.add [0'u32, 1, 2, 2, 1, 3]
  g.fillBBox = gpuTransformBounds(
    Region(xMin: 0, yMin: 0, xMax: int32(image.w), yMax: int32(image.h)), g.matrix)

func stencilMode*(g: GlGeometry, flags: RenderUpdateFlags): GlStencilMode =
  if flags * {RenderUpdateFlag.Stroke, RenderUpdateFlag.GradientStroke} != {}:
    return if g.strokeDirect: GlStencilMode.None else: GlStencilMode.Stroke
  if RenderUpdateFlag.Image in flags: return GlStencilMode.None
  if g.convex: return GlStencilMode.None
  if g.fillRule == FillRule.NonZero: return GlStencilMode.FillNonZero
  if g.fillRule == FillRule.EvenOdd: return GlStencilMode.FillEvenOdd
  GlStencilMode.None

func bounds*(g: GlGeometry): Region =
  ## World space bounds of the fill and the stroke.
  var valid = false
  if g.fill.index.len != 0:
    let fill = if g.fillWorld: g.fillBBox else: gpuTransformBounds(g.fillBBox, g.matrix)
    if fill.valid:
      result = fill
      valid = true
  if g.stroke.index.len != 0:
    let stroke = gpuTransformBounds(g.strokeBBox, g.matrix)
    if stroke.valid:
      result = if valid: result.add(stroke) else: stroke

proc updateShape*(shape: GlShape, transform: Matrix, viewport: Region, flags: RenderUpdateFlags) =
  ## Geometry part of `GlRenderer::prepare(RenderShape)`, after `GlDrawable::prepare` said that
  ## an update is needed. `flags` are the (merged) update flags.
  if RenderUpdateFlag.Path in flags: shape.geometry = initGlGeometry()
  shape.geometry.transform(transform)
  shape.geometry.viewport = viewport

  let sw = shape.rshape.strokeWidth
  let update = flags * {RenderUpdateFlag.Path, RenderUpdateFlag.Transform} != {} or
    (RenderUpdateFlag.Stroke in flags and shape.rshape.stroke.isSome and isFinite32(sw) and
     not zero(sw) and shape.geometry.optStrokePath.empty)
  if update:
    shape.geometry.prepare(shape.rshape)
    shape.valid.fill = shape.geometry.tesselateShape(shape.rshape, shape.multiplier)
  if update or RenderUpdateFlag.Stroke in flags:
    shape.valid.stroke = shape.geometry.tesselateStroke(shape.rshape)

{.pop.}
