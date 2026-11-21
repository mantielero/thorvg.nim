## GL renderer core, part 3: the `RenderMethod` overrides that build and query the per-paint
## data (port of the `prepare` / lifecycle / query half of tvgGlRenderer.cpp, unit G4a):
## `preUpdate`, `prepareShape`, `prepareImage`, `postUpdate`, `preRender`, `postRender`,
## `dispose`, `region`, `bounds`, `blend`, `colorSpace`, `mainSurface`, `intersectsShape`,
## `intersectsImage`. Drawing is in `renderer_draw.nim`; G4b TODO list: see `renderer.nim`.
##
## Import this module (it re-exports the other two) to get the whole G4a renderer.

import ../../core/[types, geom]
import ../../renderer/render
import ./[geometry, gl_common, render_pass, render_target, renderer, renderer_draw, texture_mgr]

export renderer, renderer_draw

const AllUpdateFlags = {RenderUpdateFlag.low .. RenderUpdateFlag.high}

func viewSize(r: GlRenderer): Point =
  Point(x: float32(r.surface.w), y: float32(r.surface.h))

method preUpdate*(r: GlRenderer): bool =
  if r.rootTarget.invalid: return false
  discard r.currentContext()
  true

method postUpdate*(r: GlRenderer): bool = true

method prepareShape*(r: GlRenderer, rshape: RenderShape, data: RenderData, transform: Matrix,
    clips: seq[RenderData], opacity: uint8, flags: RenderUpdateFlags,
    clipper: bool): RenderData =
  var shape = GlShape(data)
  var flags = flags
  if shape == nil:
    shape = newGlShape(rshape)
    flags = AllUpdateFlags
  # the C++ keeps a pointer to the paint's shape, so it always sees fresh data (D-G2b-2)
  shape.rshape = rshape

  if shape.prepare(flags, r.viewSize(), opacity, clipper): return shape

  updateShape(shape, transform, r.vport, flags)
  shape.opacity = uint32(float32(opacity) * shape.multiplier)
  if RenderUpdateFlag.Clip in flags: shape.clips = clips
  shape

method prepareImage*(r: GlRenderer, surface: RenderSurface, data: RenderData, transform: Matrix,
    clips: seq[RenderData], opacity: uint8, filter: FilterMethod,
    flags: RenderUpdateFlags): RenderData =
  var image = GlImage(data)
  var flags = flags
  if image == nil:
    image = newGlImage(nil)
    flags = AllUpdateFlags

  let cacheStale = image.texId != 0 and image.stamp != r.textures.stamp
  if cacheStale: flags.incl RenderUpdateFlag.Image
  if image.prepare(flags, r.viewSize(), opacity, false): return image

  if cacheStale or image.texId == 0 or image.surface != surface or image.filter != filter:
    image.destroy(r)
    image.texId = r.textures.retain(r.state, surface, filter)
    image.surface = surface
    image.filter = filter
    image.stamp = r.textures.stamp
    image.geometry = initGlGeometry()
  elif RenderUpdateFlag.Image in flags:
    r.textures.upload(r.state, image.texId, surface, filter)

  if flags * {RenderUpdateFlag.Image, RenderUpdateFlag.Transform} != {}:
    image.geometry.transform(transform)
    image.geometry.tesselateImage(surface)

  if RenderUpdateFlag.Clip in flags: image.clips = clips

  image.geometry.viewport = r.vport
  image.opacity = uint32(opacity)
  image

method preRender*(r: GlRenderer): bool =
  if r.rootTarget.invalid: return false

  discard r.currentContext()
  if not r.textures.flushPreprocess(r.state, r.targetFboId): return false
  if r.programs.len == 0: r.initShaders()
  r.passStack.add newGlRenderPass(r.rootTarget)
  true

method postRender*(r: GlRenderer): bool = true

method dispose*(r: GlRenderer, data: RenderData) =
  if data of GlImage: GlImage(data).destroy(r)

method region*(r: GlRenderer, data: RenderData): Region =
  if data == nil: Region() else: GlDrawable(data).geometry.bounds()

method bounds*(r: GlRenderer, data: RenderData, pt4: var array[4, Point], m: Matrix): bool =
  if data == nil: return false

  let shape = GlShape(data)
  if not shape.valid.stroke: return false

  var bbox = initBBox()
  let vertexes = shape.geometry.stroke.vertex
  for i in 0 ..< vertexes.len div 2:
    let vert = Point(x: vertexes[i * 2], y: vertexes[i * 2 + 1]) * m
    bbox = BBox(min: Point(x: stdMin(bbox.min.x, vert.x), y: stdMin(bbox.min.y, vert.y)),
      max: Point(x: stdMax(bbox.max.x, vert.x), y: stdMax(bbox.max.y, vert.y)))

  pt4[0] = bbox.min
  pt4[1] = Point(x: bbox.max.x, y: bbox.min.y)
  pt4[2] = bbox.max
  pt4[3] = Point(x: bbox.min.x, y: bbox.max.y)
  true

method blend*(r: GlRenderer, m: BlendMethod): bool =
  if m == r.mBlendMethod: return true
  r.mBlendMethod = if m == BlendMethod.Composition: BlendMethod.Normal else: m
  true

method colorSpace*(r: GlRenderer): ColorSpace = r.surface.cs

method mainSurface*(r: GlRenderer): RenderSurface = r.surface

method intersectsShape*(r: GlRenderer, data: RenderData, region: Region): bool =
  if data == nil: return false
  let shape = GlShape(data)
  if shape.opacity == 0: return false
  let bbox = shape.geometry.bounds()
  if not region.intersected(bbox): return false
  if region.contained(bbox): return true
  shape.intersect(region.intersect(bbox))

method intersectsImage*(r: GlRenderer, data: RenderData, region: Region): bool =
  if data == nil: return false
  let image = GlImage(data)
  if image.opacity == 0: return false
  let bbox = image.geometry.bounds()
  if not region.intersected(bbox): return false
  if region.contained(bbox): return true
  image.intersect(region.intersect(bbox))
