## SVG document model: the node tree, style properties, gradients and parser state.
##
## Ported from `modules/svg/tvgSvgCommon.h`. Differences with C++:
## * `SvgNode` is a `ref object` whose per-type payload is a case variant (the C++ union);
##   `parent` is a `{.cursor.}` so the tree has no strong cycle through its parents.
## * Bit-flag enums became `set`s of `{.pure.}` enums (`flags == {}` is `Flags::None`).
## * `char*` members are `string`; null and the empty string are the same thing ("").
## * Optional `Matrix*` members are `Option[Matrix]`.
## * Gradients keep their coordinates in arrays indexed by `LinearCoord` / `RadialCoord`,
##   so inheritance and recalculation are loops over the coordinates, as in the original tables.

import std/options
import ../../core/types

type
  Box* = object
    x*, y*, w*, h*: float32

  SvgNodeType* {.pure.} = enum
    Doc, G, Defs, Animation, Arc, Circle, Ellipse, Image, Line, Path, Polygon, Polyline,
    Rect, Text, TextArea, Tspan, Use, Video, ClipPath, Mask, CssStyle, Symbol, Filter,
    GaussianBlur, Pattern, Unknown

  SvgFillFlag* {.pure.} = enum
    Paint, Opacity, Gradient, FillRule

  SvgStrokeFlag* {.pure.} = enum
    Paint, Opacity, Gradient, Scale, Width, Cap, Join, Dash, Miterlimit, DashOffset

  SvgGradientType* {.pure.} = enum
    Linear, Radial

  SvgStyleFlag* {.pure.} = enum
    Color, Fill, FillRule, FillOpacity, Opacity, Stroke, StrokeWidth, StrokeLineJoin,
    StrokeLineCap, StrokeOpacity, StrokeDashArray, Transform, ClipPath, Mask, MaskType,
    Display, PaintOrder, StrokeMiterlimit, StrokeDashOffset, Filter, BlendMode, TextAnchor,
    AlignmentBaseline, DominantBaseline, FontWeight, LetterSpacing, WordSpacing,
    ImageRendering

  SvgStopStyleFlag* {.pure.} = enum
    StopOpacity, StopColor

  SvgGradientFlag* {.pure.} = enum
    GradientUnits, SpreadMethod, X1, X2, Y1, Y2, Cx, Cy, R, Fx, Fy, Fr

  SvgMaskType* {.pure.} = enum
    Luminance, Alpha

  SvgXmlSpace* {.pure.} = enum
    None, Default, Preserve

  SvgViewFlag* {.pure.} = enum
    Width, Height, Viewbox, WidthInPercent, HeightInPercent

  AspectRatioAlign* {.pure.} = enum
    None, XMinYMin, XMidYMin, XMaxYMin, XMinYMid, XMidYMid, XMaxYMid, XMinYMax, XMidYMax,
    XMaxYMax

  AspectRatioMeetOrSlice* {.pure.} = enum
    Meet, Slice

  SvgBaseline* {.pure.} = enum
    Auto, Alphabetic, BeforeEdge, AfterEdge, Central, Middle, Hanging, Mathematical

  SvgFontWeight* {.pure.} = enum
    ## Values as in the original (CSS weights); declared in ascending order.
    Lighter = -3
    Bolder = -2
    Inherit = -1
    Invalid = 0
    Weight100 = 100
    Weight200 = 200
    Weight300 = 300
    Normal = 400
    Weight500 = 500
    Weight600 = 600
    Bold = 700
    Weight800 = 800
    Weight900 = 900

  OpenedTagType* {.pure.} = enum
    Other, Style, Text

  LinearCoord* {.pure.} = enum
    X1, Y1, X2, Y2

  RadialCoord* {.pure.} = enum
    Cx, Cy, Fx, Fy, R, Fr

  SvgStyleFlags* = set[SvgStyleFlag]
  SvgFillFlags* = set[SvgFillFlag]
  SvgStrokeFlags* = set[SvgStrokeFlag]
  SvgGradientFlags* = set[SvgGradientFlag]
  SvgViewFlags* = set[SvgViewFlag]

  SvgNode* = ref SvgNodeObj

  SvgStyleGradient* = ref object
    ## `linear`: coords are x1,y1,x2,y2; `radial`: cx,cy,fx,fy,r,fr (see the coord enums).
    id*, refId*: string
    kind*: SvgGradientType
    coord*: array[6, float32]
    isPercentage*: array[6, bool]
    transform*: Option[Matrix]
    stops*: seq[ColorStop]
    flags*: SvgGradientFlags
    spread*: FillSpread
    userSpace*: bool

  SvgPaint* = object
    gradient*: SvgStyleGradient
    pattern*: SvgNode
    url*: string
    color*: RGBA
    none*, curColor*: bool

  SvgComposite* = object
    ## clip-path / mask reference: `url` is the id; `node` is resolved after parsing.
    url*: string
    node*: SvgNode
    applying*: bool ## circular-dependency guard for the builder

  SvgFilter* = object
    url*: string
    node*: SvgNode

  SvgDash* = object
    array*: seq[float32]
    offset*: float32

  SvgStyleFill* = object
    paint*: SvgPaint
    opacity*: int
    flags*: SvgFillFlags
    fillRule*: FillRule

  SvgStyleStroke* = object
    flags*: SvgStrokeFlags
    paint*: SvgPaint
    opacity*: int
    scale*, width*, centered*, miterlimit*: float32
    dash*: SvgDash
    cap*: StrokeCap
    join*: StrokeJoin

  SvgStyleProperty* = object
    fill*: SvgStyleFill
    stroke*: SvgStyleStroke
    clipPath*, mask*: SvgComposite
    filter*: SvgFilter
    opacity*: int
    color*: RGBA
    cssClass*: string
    textAnchor*: float32 ## 0 = start, 0.5 = middle, 1 = end
    alignmentBaseline*, dominantBaseline*: SvgBaseline
    fontWeight*: SvgFontWeight
    letterSpacing*, wordSpacing*: float32
    flags*: SvgStyleFlags
    flagsImportance*: SvgStyleFlags ## flags set by `!important` declarations
    curColorSet*: bool
    paintOrder*: bool ## true when fill is painted before stroke (the default)
    display*: bool
    letterSpacingRelative*, wordSpacingRelative*: bool
    blendMode*: BlendMethod
    imageRendering*: FilterMethod

  SvgDocNode* = object
    w*, h*: float32 ## unit: px, or a fraction when the matching `...InPercent` flag is set
    vbox*: Box
    defs*, style*: SvgNode
    align*: AspectRatioAlign
    meetOrSlice*: AspectRatioMeetOrSlice
    viewFlag*: SvgViewFlags

  SvgDefsNode* = object
    gradients*: seq[SvgStyleGradient]

  SvgSymbolNode* = object
    w*, h*, vx*, vy*, vw*, vh*: float32
    align*: AspectRatioAlign
    meetOrSlice*: AspectRatioMeetOrSlice
    overflowVisible*, hasViewBox*, hasWidth*, hasHeight*: bool

  SvgUseNode* = object
    x*, y*, w*, h*: float32
    symbol*: SvgNode
    isWidthSet*, isHeightSet*: bool

  SvgEllipseNode* = object
    cx*, cy*, rx*, ry*: float32

  SvgCircleNode* = object
    cx*, cy*, r*: float32

  SvgRectNode* = object
    x*, y*, w*, h*, rx*, ry*: float32
    hasRx*, hasRy*: bool

  SvgLineNode* = object
    x1*, y1*, x2*, y2*: float32

  SvgImageNode* = object
    x*, y*, w*, h*: float32
    href*: string

  SvgPolygonNode* = object
    pts*: seq[float32]

  SvgMaskNode* = object
    box*: Box
    isPercentage*: array[4, bool]
    kind*: SvgMaskType
    userSpace*, maskContentUserSpace*: bool

  SvgTextNode* = object
    text*, fontFamily*: string
    x*, y*, dx*, dy*, fontSize*: float32

  SvgGaussianBlurNode* = object
    stdDevX*, stdDevY*: float32
    box*: Box
    isPercentage*: array[4, bool]
    hasBox*, edgeModeWrap*: bool

  SvgFilterNode* = object
    box*: Box
    isPercentage*: array[4, bool]
    filterUserSpace*, primitiveUserSpace*: bool

  SvgPatternNode* = object
    box*, vbox*: Box
    transform*: Option[Matrix]
    isPercentage*: array[4, bool]
    patternUserSpace*, contentUserSpace*, hasViewBox*, applying*: bool

  SvgNodeObj* = object
    parent* {.cursor.}: SvgNode
    child*: seq[SvgNode]
    id*: string
    style*: SvgStyleProperty
    transform*: Option[Matrix]
    xmlSpace*: SvgXmlSpace
    case kind*: SvgNodeType
    of SvgNodeType.Doc: doc*: SvgDocNode
    of SvgNodeType.Defs: defs*: SvgDefsNode
    of SvgNodeType.Use: use*: SvgUseNode
    of SvgNodeType.Circle: circle*: SvgCircleNode
    of SvgNodeType.Ellipse: ellipse*: SvgEllipseNode
    of SvgNodeType.Polygon, SvgNodeType.Polyline: polygon*: SvgPolygonNode
    of SvgNodeType.Rect: rect*: SvgRectNode
    of SvgNodeType.Path: path*: string
    of SvgNodeType.Line: line*: SvgLineNode
    of SvgNodeType.Image: image*: SvgImageNode
    of SvgNodeType.Mask: mask*: SvgMaskNode
    of SvgNodeType.ClipPath: clipUserSpace*: bool
    of SvgNodeType.Symbol: symbol*: SvgSymbolNode
    of SvgNodeType.Text, SvgNodeType.Tspan: text*: SvgTextNode
    of SvgNodeType.Filter: filter*: SvgFilterNode
    of SvgNodeType.GaussianBlur: gaussianBlur*: SvgGaussianBlurNode
    of SvgNodeType.Pattern: pattern*: SvgPatternNode
    else: discard

  SvgParser* = object
    node*: SvgNode ## the node whose attributes are being parsed (kept after creation)
    styleGrad*: SvgStyleGradient
    global*: Box
    gradStop*: ColorStop
    flags*: set[SvgStopStyleFlag]
    parsedFx*, parsedFy*: bool

  SvgNodeIdPair* = object
    node*: SvgNode
    id*: string

  FontFace* = object
    name*, src*: string

  SvgParserContext* = ref object
    parser*: SvgParser
    doc*, def*, cssStyle*, currentGraphicsNode*: SvgNode
    cloneNodes*: seq[SvgNodeIdPair] ## postponed `use` references (front = index 0)
    stack*: seq[SvgNode]
    gradients*, gradientStack*: seq[SvgStyleGradient] ## nil entry = ignored subtree
    nodesToStyle*: seq[SvgNodeIdPair]
    fonts*: seq[FontFace]
    openedTag*: OpenedTagType

const
  LinearFlags* = [SvgGradientFlag.X1, SvgGradientFlag.Y1, SvgGradientFlag.X2, SvgGradientFlag.Y2]
  RadialFlags* = [SvgGradientFlag.Cx, SvgGradientFlag.Cy, SvgGradientFlag.Fx,
                  SvgGradientFlag.Fy, SvgGradientFlag.R, SvgGradientFlag.Fr]

func intersect*(a: var Box, b: Box) =
  ## Shrinks `a` to the overlap with `b` (empty boxes get zero size).
  let x1 = a.x + a.w
  let y1 = a.y + a.h
  let x2 = b.x + b.w
  let y2 = b.y + b.h
  a.x = if a.x > b.x: a.x else: b.x
  a.y = if a.y > b.y: a.y else: b.y
  a.w = (if x1 < x2: x1 else: x2) - a.x
  a.h = (if y1 < y2: y1 else: y2) - a.y
  if a.w < 0.0'f32: a.w = 0.0'f32
  if a.h < 0.0'f32: a.h = 0.0'f32

func initStyle*(): SvgStyleProperty =
  ## Default style of a new node (https://www.w3.org/TR/SVGTiny12/painting.html).
  result.opacity = 255
  result.color.a = 255
  result.fill.opacity = 255
  result.fill.paint.color.a = 255
  result.fill.fillRule = FillRule.NonZero
  result.stroke.paint.none = true
  result.stroke.paint.color.a = 255
  result.stroke.opacity = 255
  result.stroke.width = 1
  result.stroke.cap = StrokeCap.Butt
  result.stroke.join = StrokeJoin.Miter
  result.stroke.miterlimit = 4.0'f32
  result.stroke.scale = 1.0'f32
  result.paintOrder = true
  result.display = true
  result.fontWeight = SvgFontWeight.Normal

func newNode*(parent: SvgNode, kind: SvgNodeType): SvgNode =
  ## `_createNode`: a node with the default style, appended to `parent`'s children.
  result = SvgNode(kind: kind, parent: parent, style: initStyle())
  if parent != nil: parent.child.add result

func findEmBaseFontSize*(node: SvgNode): float32 =
  ## Font size of the nearest text ancestor (or the default 10px).
  var n = node
  while n != nil:
    if n.kind in {SvgNodeType.Text, SvgNodeType.Tspan} and n.text.fontSize > 0.0'f32:
      return n.text.fontSize
    n = n.parent
  10.0'f32
