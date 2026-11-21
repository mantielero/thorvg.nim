## Renderer contract: surfaces, render shapes and the abstract `RenderMethod`.
##
## Ported from `src/renderer/tvgRender.h` / `tvgRender.cpp`.
## `RenderMethod` is a `ref object` with base `method`s; each engine (CPU today,
## GL/WebGPU later) subclasses it. `RenderData` is the engine's opaque per-paint
## cache (the C++ `void*`), subclassed by the engine. Scene effects are described in
## `effect.nim`; the `effect*` methods below are the C++ overloads of
## `prepare/region/render/dispose(RenderEffect*)`. Partial rendering and the thread
## pool are not part of the port (DECISIONS.md D5).

import std/options
import ../core/[types, path, fill]
import ./effect

type
  RenderUpdateFlag* {.pure.} = enum
    Path, Color, Gradient, Stroke, Transform, Image, GradientStroke, Blend, Clip,
    Children

  RenderUpdateFlags* = set[RenderUpdateFlag]

  CompositionFlag* {.pure.} = enum
    Opacity, Blending, Masking, PostProcessing

  CompositionFlags* = set[CompositionFlag]

  RenderData* = ref object of RootObj
    ## Engine-owned cache for one paint. Engines subclass it.

  RenderSurface* = ref object of RootObj
    ## A pixel buffer. 32-bit surfaces use `data`; Grayscale8 uses `buf8`.
    ## `stride` is counted in pixels.
    data*: seq[uint32]
    buf8*: seq[uint8]
    stride*, w*, h*: uint32
    cs*: ColorSpace
    channelSize*: uint8
    premultiplied*: bool   ## alpha-premultiplied colors
    opaque*: bool          ## the alpha channel can be ignored

  RenderCompositor* = ref object of RootObj
    meth*: MaskMethod      ## `method` is a Nim keyword
    opacity*: uint8

  RenderTrimPath* = object
    begin*: float32
    `end`*: float32
    simultaneous*: bool

  RenderDash* = object
    pattern*: seq[float32]
    offset*: float32
    length*: float32       ## sum of the pattern values

  RenderStroke* = object
    width*: float32
    color*: RGBA
    fill*: Option[Fill]
    dash*: RenderDash
    miterlimit*: float32
    trim*: RenderTrimPath
    cap*: StrokeCap
    join*: StrokeJoin
    first*: bool           ## stroke below the fill

  RenderShape* = object
    path*: RenderPath
    fill*: Option[Fill]
    color*: RGBA
    stroke*: Option[RenderStroke]
    rule*: FillRule

  RenderMethod* = ref object of RootObj
    ## Abstract rendering backend. Defaults are "unsupported" no-ops.
    vport*: Region

func channelSize*(cs: ColorSpace): uint8 =
  ## Bytes per pixel of a color space (0 for Unknown).
  case cs
  of ColorSpace.XBGR8888, ColorSpace.XRGB8888, ColorSpace.ABGR8888,
      ColorSpace.ABGR8888S, ColorSpace.ARGB8888, ColorSpace.ARGB8888S: 4
  of ColorSpace.Grayscale8: 1
  of ColorSpace.Unknown: 0

func initTrimPath*(): RenderTrimPath =
  RenderTrimPath(begin: 0.0'f32, `end`: 1.0'f32, simultaneous: true)

func valid*(t: RenderTrimPath): bool = t.begin != 0.0'f32 or t.`end` != 1.0'f32

func initStroke*(): RenderStroke =
  ## Stroke with ThorVG's defaults (miter limit 4, square cap, bevel join).
  RenderStroke(miterlimit: 4.0'f32, trim: initTrimPath(), cap: StrokeCap.Square,
               join: StrokeJoin.Bevel)

func strokeWidth*(s: RenderShape): float32 =
  if s.stroke.isSome: s.stroke.get.width else: 0.0'f32

func trimpath*(s: RenderShape): bool =
  s.stroke.isSome and s.stroke.get.trim.valid

func strokeFirst*(s: RenderShape): bool =
  s.stroke.isSome and s.stroke.get.first

func setup*(s: RenderSurface, cs: ColorSpace) =
  ## Normalizes X* color spaces to opaque A* ones and derives `premultiplied`.
  var cs = cs
  if cs == ColorSpace.XBGR8888:
    cs = ColorSpace.ABGR8888
    s.opaque = true
  elif cs == ColorSpace.XRGB8888:
    cs = ColorSpace.ARGB8888
    s.opaque = true
  s.cs = cs
  s.channelSize = channelSize(cs)
  s.premultiplied = cs == ColorSpace.ABGR8888 or cs == ColorSpace.ARGB8888

func newSurface*(w, h: uint32, cs: ColorSpace = ColorSpace.ARGB8888): RenderSurface =
  ## Allocates a zero-filled surface (32-bit, or 8-bit for Grayscale8).
  result = RenderSurface(stride: w, w: w, h: h, channelSize: channelSize(cs))
  result.setup(cs)
  if cs == ColorSpace.Grayscale8: result.buf8 = newSeq[uint8](int(w) * int(h))
  else: result.data = newSeq[uint32](int(w) * int(h))

# ---- RenderMethod: abstract interface -------------------------------------

method preUpdate*(r: RenderMethod): bool {.base.} = false

method prepareShape*(r: RenderMethod, rshape: RenderShape, data: RenderData,
    transform: Matrix, clips: seq[RenderData], opacity: uint8,
    flags: RenderUpdateFlags, clipper: bool): RenderData {.base.} = nil

method prepareImage*(r: RenderMethod, surface: RenderSurface, data: RenderData,
    transform: Matrix, clips: seq[RenderData], opacity: uint8,
    filter: FilterMethod, flags: RenderUpdateFlags): RenderData {.base.} = nil

method postUpdate*(r: RenderMethod): bool {.base.} = false
method preRender*(r: RenderMethod): bool {.base.} = false
method renderShape*(r: RenderMethod, data: RenderData): bool {.base.} = false
method renderImage*(r: RenderMethod, data: RenderData): bool {.base.} = false
method postRender*(r: RenderMethod): bool {.base.} = false
method dispose*(r: RenderMethod, data: RenderData) {.base.} = discard
method region*(r: RenderMethod, data: RenderData): Region {.base.} = Region()

method bounds*(r: RenderMethod, data: RenderData, pt4: var array[4, Point],
    m: Matrix): bool {.base.} = false

method blend*(r: RenderMethod, m: BlendMethod): bool {.base.} = false
method colorSpace*(r: RenderMethod): ColorSpace {.base.} = ColorSpace.Unknown
method mainSurface*(r: RenderMethod): RenderSurface {.base.} = nil
method clear*(r: RenderMethod): bool {.base.} = false
method sync*(r: RenderMethod): bool {.base.} = false

method intersectsShape*(r: RenderMethod, data: RenderData,
    region: Region): bool {.base.} = false

method intersectsImage*(r: RenderMethod, data: RenderData,
    region: Region): bool {.base.} = false

method target*(r: RenderMethod, region: Region, cs: ColorSpace,
    flags: CompositionFlags): RenderCompositor {.base.} = nil

method beginComposite*(r: RenderMethod, cmp: RenderCompositor, m: MaskMethod,
    opacity: uint8): bool {.base.} = false

method endComposite*(r: RenderMethod, cmp: RenderCompositor): bool {.base.} = false

# scene effects (the C++ overloads taking a `RenderEffect*`)
method effectPrepare*(r: RenderMethod, effect: RenderEffect, tm: Matrix) {.base.} = discard
method effectRegion*(r: RenderMethod, effect: RenderEffect): bool {.base.} = false

method effectRender*(r: RenderMethod, cmp: RenderCompositor, effect: RenderEffect,
    direct: bool): bool {.base.} = false

method effectDispose*(r: RenderMethod, effect: RenderEffect) {.base.} = discard

# ---- helpers shared by paints and engines ---------------------------------

func multiply*(c: uint8, a: uint8): uint8 =
  ## ThorVG `MULTIPLY(c, a)`: scales a channel by an alpha (0..255).
  uint8((uint32(c) * uint32(a) + 0xff'u32) shr 8)

func maskRegionMerging*(m: MaskMethod): bool =
  ## True for mask methods that may expand the rendering region.
  case m
  of MaskMethod.Add, MaskMethod.Difference, MaskMethod.Lighten,
      MaskMethod.Darken: true
  else: false

func maskToColorSpace*(r: RenderMethod, m: MaskMethod): ColorSpace =
  case m
  of MaskMethod.Alpha, MaskMethod.InvAlpha, MaskMethod.Add, MaskMethod.Difference,
      MaskMethod.Subtract, MaskMethod.Intersect, MaskMethod.Lighten,
      MaskMethod.Darken: ColorSpace.Grayscale8
  of MaskMethod.Luma, MaskMethod.InvLuma: colorSpace(r)
  else: ColorSpace.Unknown
