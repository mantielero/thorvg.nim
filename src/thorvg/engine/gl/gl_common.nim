## Shared GL engine types (port of `tvgGlCommon.h`).
##
## Data only, no GL calls. The geometry procs live in `geometry.nim`, the tessellators in
## `tessellator.nim` / `tess_stroke.nim`.
##
## - `GlGeometryBuffer`: output of a tessellation. `vertex` is packed `float32` (x, y pairs;
##   x, y, u, v for images) and `index` is a `uint32` triangle list. G3a pushes both into the
##   `GlStageBuffer` of `gpu_buffer.nim` (`stage.push(buf.vertex)`, `stage.pushIndex(buf.index)`).
## - `GlGeometry`: per paint geometry (`fill`, `stroke`, bboxes, `convex`, `strokeDirect`,
##   `fillRule`, `matrix`).
## - `GlDrawable` / `GlShape` / `GlImage`: `RenderData` subclasses. `GlShape.rshape` holds a COPY
##   of the `RenderShape` (the C++ keeps a pointer), `valid.fill/stroke` and `multiplier` are the
##   results of `GlGeometry.tesselateShape/tesselateStroke`.
## - `GlCompositor`, the gradient uniform blocks (float32 objects with the std140 layout and the
##   C++ `sizeof`: linear 400, radial 416, conic 384 bytes) and `GlImageOpacityBlock`.
##
## Not here: `GlGeometry::draw` (G3a, it needs the stage buffer and the render task) and
## `GlDrawable::destroy` / `GlImage::destroy` (G4a, they need the renderer).

import ../../core/[types, geom, path]
import ../../renderer/render

{.push floatChecks: false.}

const
  MinGlStrokeWidth* = 1.0'f32
  MinGlStrokeAlpha* = 0.25'f32
  GlMat3Std140Size* = 12'u32
  MaxGradientStops* = 16

type
  GlStencilMode* {.pure.} = enum
    None, FillNonZero, FillEvenOdd, Stroke

  GlGeometryBuffer* = object
    vertex*: seq[float32]
    index*: seq[uint32]

  GlGeometry* = object
    fill*, stroke*: GlGeometryBuffer
    matrix*: Matrix
    viewport*: Region
    fillBBox*, strokeBBox*: Region
    optPath*: RenderPath         ## optimal transformed path
    optStrokePath*: RenderPath   ## matching local path using transformed-space tolerance
    strokeRenderWidth*: float32
    imatrix: Matrix              ## inverse matrix cache (see `itransform`)
    dirty: bool                  ## `imatrix` is stale
    fillRule*: FillRule
    fillWorld*, optPathThin*, optPathSkipFill*, convex*, strokeDirect*: bool

  GlDrawable* = ref object of RenderData
    geometry*: GlGeometry
    clips*: seq[RenderData]
    size*: Point                 ## view size
    opacity*: uint32
    flags*: RenderUpdateFlags    ## a backup flag for deferred update

  GlShape* = ref object of GlDrawable
    rshape*: RenderShape
    multiplier*: float32
    valid*: tuple[fill, stroke: bool]

  GlImage* = ref object of GlDrawable
    surface*: RenderSurface
    texId*: uint32
    stamp*: uint16               ## tracks TextureMgr.stamp ownership of `texId`
    filter*: FilterMethod

  GlCompositor* = ref object of RenderCompositor
    bbox*: Region
    flags*: CompositionFlags
    blendMethod*: BlendMethod

  GlImageOpacityBlock* = array[4, int32]

  GlLinearGradientBlock* = object
    nStops*: array[4, float32]
    startPos*, endPos*: array[2, float32]
    stopPoints*: array[MaxGradientStops, float32]
    stopColors*: array[4 * MaxGradientStops, float32]
    invTransform*: array[12, float32]

  GlRadialGradientBlock* = object
    nStops*: array[4, float32]
    centerPos*: array[4, float32]
    radius*: array[2, float32]
    pad: array[2, float32]       ## `alignas(16)` of `stopPoints`
    stopPoints*: array[MaxGradientStops, float32]
    stopColors*: array[4 * MaxGradientStops, float32]
    invTransform*: array[12, float32]

  GlConicGradientBlock* = object
    nStops*: array[4, float32]
    stopPoints*: array[MaxGradientStops, float32]
    stopColors*: array[4 * MaxGradientStops, float32]
    invTransform*: array[12, float32]

func stdMin*(a, b: float32): float32 {.inline.} =
  ## `std::min`: returns `a` unless `b < a`.
  if b < a: b else: a

func stdMax*(a, b: float32): float32 {.inline.} =
  ## `std::max`: returns `a` unless `a < b`.
  if a < b: b else: a

func toI32*(x: float32): int32 =
  ## C `int32_t(float)` as compiled by gcc on x86-64 (`cvttss2si`).
  if x >= -2147483648.0'f32 and x < 2147483648.0'f32: int32(x) else: low(int32)

func isFinite32*(x: float32): bool {.inline.} = x - x == 0.0'f32

func getMatrix3*(m: Matrix): array[9, float32] =
  ## Column major 3x3 matrix.
  [m.e11, m.e21, m.e31, m.e12, m.e22, m.e32, m.e13, m.e23, m.e33]

func getMatrix3Std140*(m: Matrix): array[12, float32] =
  ## Column major mat3 with each column padded to a vec4 (std140).
  [m.e11, m.e21, m.e31, 0.0'f32, m.e12, m.e22, m.e32, 0.0'f32,
   m.e13, m.e23, m.e33, 0.0'f32]

func initGlGeometry*(): GlGeometry =
  ## `GlGeometry()`: zeroed, matrix dirty.
  GlGeometry(dirty: true)

func newGlShape*(rshape: RenderShape): GlShape =
  GlShape(rshape: rshape, multiplier: 1.0'f32, geometry: initGlGeometry())

func newGlImage*(surface: RenderSurface, filter = FilterMethod.Bilinear): GlImage =
  GlImage(surface: surface, filter: filter, geometry: initGlGeometry())

func newGlCompositor*(box: Region, flags: CompositionFlags): GlCompositor =
  GlCompositor(bbox: box, flags: flags, blendMethod: BlendMethod.Normal)

func clear*(b: var GlGeometryBuffer) =
  b.vertex.setLen(0)
  b.index.setLen(0)

func itransform*(g: var GlGeometry): Matrix =
  ## Inverse of `matrix`, cached until the next `transform`.
  if g.dirty:
    discard inverse(g.matrix, g.imatrix)
    g.dirty = false
  g.imatrix

func transform*(g: var GlGeometry, m: Matrix) =
  g.matrix = m
  g.dirty = true

func drawable*(g: GlGeometry, flags: RenderUpdateFlags): bool =
  ## True if the buffer selected by `flags` (stroke or fill) has indices.
  if flags == {}: return false
  let buffer = if flags * {RenderUpdateFlag.Stroke, RenderUpdateFlag.GradientStroke} != {}:
      g.stroke.index.len else: g.fill.index.len
  buffer != 0

func prepare*(d: GlDrawable, updateFlags: var RenderUpdateFlags, viewSize: Point, opacity: uint8,
              clipper: bool): bool =
  ## `GlDrawable::prepare` (defined in tvgGlRenderer.cpp). True: nothing left to update.
  if opacity == 0 and not clipper:
    d.opacity = 0
    d.flags = d.flags + updateFlags
    return true
  updateFlags = updateFlags + d.flags
  d.flags = {}
  if updateFlags == {}: return true
  d.size = viewSize
  false

{.pop.}
