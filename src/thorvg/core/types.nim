## Shared basic types of the ThorVG port (enums, Point, Matrix, colors).
##
## Ported from `inc/thorvg.h` (public enums/structs) and `src/common/tvgColor.h`.
## Enums are `{.pure.}`, so they are always written qualified, as in C++
## (`BlendMethod.Add`, `MaskMethod.Add`, ...). Floats are `float32` like the original.

type
  Result* {.pure.} = enum
    ## Outcome of an operation, same values as `tvg::Result`.
    Success
    InvalidArguments
    InsufficientCondition
    FailedAllocation
    MemoryCorruption
    NonSupport
    SystemError
    Unknown = 255

  ColorSpace* {.pure.} = enum
    ## How the 8-bit channels are joined into a 32-bit pixel (see `thorvg.h`).
    ABGR8888
    ARGB8888
    ABGR8888S
    ARGB8888S
    Grayscale8
    XBGR8888
    XRGB8888
    Unknown = 255

  EngineOption* {.pure.} = enum
    None = 0
    Default = 1
    SmartRender = 2
    Aliased = 4

  PathCommand* {.pure.} = enum
    Close
    MoveTo
    LineTo
    CubicTo

  StrokeCap* {.pure.} = enum
    Butt
    Round
    Square

  StrokeJoin* {.pure.} = enum
    Miter
    Round
    Bevel

  FillSpread* {.pure.} = enum
    Pad
    Reflect
    Repeat

  FillRule* {.pure.} = enum
    NonZero
    EvenOdd

  FilterMethod* {.pure.} = enum
    Bilinear
    Nearest

  MaskMethod* {.pure.} = enum
    None
    Alpha
    InvAlpha
    Luma
    InvLuma
    Add
    Subtract
    Intersect
    Difference
    Lighten
    Darken

  BlendMethod* {.pure.} = enum
    Normal
    Multiply
    Screen
    Overlay
    Darken
    Lighten
    ColorDodge
    ColorBurn
    HardLight
    SoftLight
    Difference
    Exclusion
    Hue
    Saturation
    Color
    Luminosity
    Add
    Composition = 255

  TextWrap* {.pure.} = enum
    None
    Character
    Word
    Smart
    Ellipsis

  PaintKind* {.pure.} = enum
    ## Replacement of `tvg::Type` for paints (gradients have their own type).
    Shape
    Scene
    Picture
    Text

  Point* = object
    x*, y*: float32

  Matrix* = object
    ## 3x3 affine matrix; e31 = e32 = 0 and e33 = 1 for 2D transforms.
    e11*, e12*, e13*: float32
    e21*, e22*, e23*: float32
    e31*, e32*, e33*: float32

  BBox* = object
    ## Float bounding box.
    min*, max*: Point

  Region* = object
    ## Integer, half-open pixel region [xMin, xMax) x [yMin, yMax).
    xMin*, yMin*, xMax*, yMax*: int32

  RGBA* = object
    r*, g*, b*, a*: uint8

  RGB* = object
    r*, g*, b*: uint8

  HSL* = object
    h*, s*, l*: float32

  ColorStop* = object
    ## One stop of a gradient; `offset` is in 0..1.
    offset*: float32
    r*, g*, b*, a*: uint8

  TextMetrics* = object
    ascent*, descent*, linegap*, advance*: float32

  GlyphMetrics* = object
    advance*, bearing*: float32
    min*, max*: Point

const
  PixelAlphaShift* = 24
