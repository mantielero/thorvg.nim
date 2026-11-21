## Shared data types of the CPU (software) engine.
##
## Ported from the structs of `src/renderer/cpu_engine/tvgSwCommon.h`.
## Differences from C++: pointers became `ref`/`seq` (nil = absent), the `union`s of
## SwFill/SwImage became plain fields, the per-thread memory pool (`SwMpool`) is gone
## (each renderer owns scratch buffers), and `SwOutline` stores its own copy of the
## path commands instead of pointing to the `RenderPath`.
## Pixel math lives in `pixel.nim`.

import ../../core/[types, fill]
import ../../renderer/render

const SwColorTable* = 1024

type
  SwPoint* = object
    ## 26.6 fixed-point coordinate (1 pixel = 64 units).
    x*, y*: int32

  SwSize* = object
    w*, h*: int32

  SwOutline* = ref object
    cmds*: seq[PathCommand]   ## same commands as the source path
    pts*: seq[SwPoint]        ## the path points in fixed point (C++: `out`)
    fpts*: seq[Point]         ## float path points (C++: `path->pts`); `utilExport` fills `pts` from it
    fillRule*: FillRule

  SwSpan* = object
    x*, y*, len*: int32
    coverage*: uint8

  SwRle* = ref object
    spans*: seq[SwSpan]       ## sorted by y, then x

  SwFill* = ref object
    kind*: FillKind
    # linear
    dx*, dy*, offset*: float32
    # radial and conic share the affine inverse a11..a23
    a11*, a12*, a13*, a21*, a22*, a23*: float32
    # radial
    fx*, fy*, fr*, rdx*, rdy*, rdr*, invA*, aa*: float32
    # conic
    cx*, cy*: float32
    normal*: Point
    invFwidth*, distanceDx*, seamProjectionDx*: float32
    ctable*: array[SwColorTable, uint32]
    extent*: float32
    spread*: FillSpread
    solid*: bool              ## solid color: the last color stop
    translucent*: bool

  SwStrokeBorder* = ref object
    pts*: seq[Point]
    tags*: seq[uint8]
    start*: int32             ## index of the current sub-path start point
    movable*: bool            ## true for the ends of lineto borders

  SwStroke* = ref object
    angleIn*, angleOut*: float32
    center*: Point
    length*: float32
    subPathAngle*: float32
    subPathStart*: Point
    subPathLength*: float32
    width*: float32
    miterlimit*: float32
    fill*: SwFill
    borders*: array[2, SwStrokeBorder]
    cap*: StrokeCap
    join*: StrokeJoin
    firstPt*: bool
    closedSubPath*: bool
    handleWideStrokes*: bool

  SwShape* = ref object
    outline*: SwOutline
    stroke*: SwStroke
    fill*: SwFill
    rle*: SwRle
    strokeRle*: SwRle
    bbox*: Region             ## shape bounds without the stroke
    fastTrack*: bool          ## axis-aligned rectangle without clips

  SwImage* = ref object
    outline*: SwOutline
    rle*: SwRle
    surface*: RenderSurface   ## source pixels (shared with the loader)
    w*, h*, stride*: uint32
    ox*, oy*: int32           ## offset
    scale*: float32
    channelSize*: uint8
    filter*: FilterMethod
    direct*: bool             ## draw directly (with offset)
    scaled*: bool             ## draw uniformly scaled
    alphaIgnored*: bool

  SwMask* = proc (s, d, a: uint8): uint8 {.nimcall.}
  SwBlender* = proc (surface: SwSurface, s, d: uint32): uint32 {.nimcall.}
  SwBlenderA* = proc (s, d: uint32, a: uint8): uint32 {.nimcall.}
  SwJoin* = proc (r, g, b, a: uint8): uint32 {.nimcall.}
  SwAlpha* = proc (c: uint32): uint8 {.nimcall.}
    ## Alpha of a pixel (Alpha, InvAlpha, Luma, InvLuma).

  SwSurface* = ref object of RenderSurface
    join*: SwJoin
    alphas*: array[4, SwAlpha]  ## Alpha:0, InvAlpha:1, Luma:2, InvLuma:3
    blender*: SwBlender         ## optional
    compositor*: SwCompositor   ## optional
    blendMethod*: BlendMethod

  SwCompositor* = ref object of RenderCompositor
    recoverSfc*: SwSurface      ## surface to restore when composition ends
    recoverCmp*: SwCompositor   ## compositor to restore when composition ends
    image*: SwImage
    bbox*: Region
    valid*: bool

  SwRenderData* = ref object of RenderData
    ## Per-paint cache of the CPU engine (C++ `SwTask`): either a shape or an image.
    shape*: SwShape
    image*: SwImage
    rshape*: RenderShape        ## last prepared vector data
    transform*: Matrix
    bbox*: Region               ## render region incl. stroke
    clips*: seq[SwRle]
    opacity*: uint8
    color*: RGBA
    flags*: RenderUpdateFlags
    isImage*: bool

func zero*(p: SwPoint): bool = p.x == 0 and p.y == 0
func tiny*(p: SwPoint): bool = abs(p.x) < 2 and abs(p.y) < 2
func `+`*(a, b: SwPoint): SwPoint = SwPoint(x: a.x + b.x, y: a.y + b.y)
func `-`*(a, b: SwPoint): SwPoint = SwPoint(x: a.x - b.x, y: a.y - b.y)
func `+=`*(a: var SwPoint, b: SwPoint) =
  a.x += b.x
  a.y += b.y
func `-=`*(a: var SwPoint, b: SwPoint) =
  a.x -= b.x
  a.y -= b.y
func toPoint*(p: SwPoint): Point = Point(x: float32(p.x) / 64.0'f32, y: float32(p.y) / 64.0'f32)

func valid*(r: SwRle): bool = r != nil and r.spans.len > 0
func invalid*(r: SwRle): bool = not valid(r)

func fetch*(s: SwSpan, bbox: Region, x, len: var int32): bool =
  ## Clips the span to `bbox`; true if something is left.
  x = max(s.x, bbox.xMin)
  len = min(s.x + s.len, bbox.xMax) - x
  len > 0
