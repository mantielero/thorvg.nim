## Node factories of the SVG loader: tag name tables and the `_create<Node>Node` functions.
##
## Ported from `modules/svg/tvgSvgLoader.cpp`. The `FactoryMethod` of the original is
## `createNodeOf(ctx, kind, ...)`: one entry per element kind with its default values. The
## `groupTags` / `graphicsTags` tables keep their order, which the close-tag matching of
## the loader depends on.

import ./[nodes, parser_value, parser_attr]

const
  GroupTags* = [("defs", SvgNodeType.Defs), ("g", SvgNodeType.G), ("svg", SvgNodeType.Doc),
                ("mask", SvgNodeType.Mask), ("clipPath", SvgNodeType.ClipPath),
                ("style", SvgNodeType.CssStyle), ("symbol", SvgNodeType.Symbol),
                ("filter", SvgNodeType.Filter), ("pattern", SvgNodeType.Pattern)]
  GraphicsTags* = [("use", SvgNodeType.Use), ("circle", SvgNodeType.Circle),
                   ("ellipse", SvgNodeType.Ellipse), ("path", SvgNodeType.Path),
                   ("polygon", SvgNodeType.Polygon), ("rect", SvgNodeType.Rect),
                   ("polyline", SvgNodeType.Polyline), ("line", SvgNodeType.Line),
                   ("image", SvgNodeType.Image), ("text", SvgNodeType.Text),
                   ("feGaussianBlur", SvgNodeType.GaussianBlur)]
  GradientTags* = [("linearGradient", SvgGradientType.Linear),
                   ("radialGradient", SvgGradientType.Radial)]

func findGroupKind*(name: string, kind: var SvgNodeType): bool =
  ## `_findGroupFactory`: exact tag name.
  for (tag, k) in GroupTags:
    if tag == name:
      kind = k
      return true
  false

func findGraphicsKind*(name: string, kind: var SvgNodeType): bool =
  for (tag, k) in GraphicsTags:
    if tag == name:
      kind = k
      return true
  false

func findGradientKind*(name: string, kind: var SvgGradientType): bool =
  for (tag, k) in GradientTags:
    if tag == name:
      kind = k
      return true
  false

proc runAttrs(ctx: SvgParserContext, attrs: string, parse: AttrParser) =
  discard parse(attrs, proc(key, value: string): bool = parseNodeAttr(ctx, key, value))

proc createDefsNode*(ctx: SvgParserContext): SvgNode =
  ## The single `<defs>` of the document (later `<defs>` elements share it).
  if ctx.def != nil and ctx.doc.doc.defs != nil: return ctx.def
  ctx.def = newNode(nil, SvgNodeType.Defs)
  ctx.doc.doc.defs = ctx.def
  ctx.def

proc createTextNode(ctx: SvgParserContext, parent: SvgNode, kind: SvgNodeType,
                    attrs: string, parse: AttrParser): SvgNode =
  ## `_createTextNode` / `_createTspanNode`.
  let node = newNode(parent, kind)
  ctx.parser.node = node
  if kind == SvgNodeType.Text:
    node.text.fontSize = 10.0'f32
  else:
    node.text.x = high(float32)
    node.text.y = high(float32)
  discard parse(attrs, proc(key, value: string): bool = prescanTextFontSize(ctx, key, value))
  runAttrs(ctx, attrs, parse)
  node

proc createNodeOf*(ctx: SvgParserContext, kind: SvgNodeType, parent: SvgNode,
                   attrs: string, parse: AttrParser): SvgNode =
  ## Creates a node of `kind` below `parent`, with its defaults, and parses `attrs` into it.
  if kind == SvgNodeType.Defs: return createDefsNode(ctx)
  if kind in {SvgNodeType.Text, SvgNodeType.Tspan}:
    return createTextNode(ctx, parent, kind, attrs, parse)
  let node = newNode(parent, kind)
  ctx.parser.node = node
  case kind
  of SvgNodeType.Doc:
    ctx.parser.global.w = 1.0'f32
    ctx.parser.global.h = 1.0'f32
    node.doc.align = AspectRatioAlign.XMidYMid
    node.doc.meetOrSlice = AspectRatioMeetOrSlice.Meet
  of SvgNodeType.Mask:
    # default region: x/y = -10%, width/height = 120% (SVG 1.1 masking)
    node.mask.maskContentUserSpace = true
    node.mask.kind = SvgMaskType.Luminance
    node.mask.box = Box(x: -0.1'f32, y: -0.1'f32, w: 1.2'f32, h: 1.2'f32)
    node.mask.isPercentage = [true, true, true, true]
  of SvgNodeType.ClipPath:
    node.style.display = false
    node.clipUserSpace = true
  of SvgNodeType.Symbol:
    node.symbol.align = AspectRatioAlign.XMidYMid
    node.symbol.meetOrSlice = AspectRatioMeetOrSlice.Meet
  of SvgNodeType.GaussianBlur:
    node.style.display = false
    node.gaussianBlur.box = Box(x: 0.0'f32, y: 0.0'f32, w: 1.0'f32, h: 1.0'f32)
  of SvgNodeType.Filter:
    node.style.display = false
    node.filter.box = Box(x: -0.1'f32, y: -0.1'f32, w: 1.2'f32, h: 1.2'f32)
    node.filter.primitiveUserSpace = true
  of SvgNodeType.Pattern:
    node.style.display = false
    node.pattern.patternUserSpace = false
    node.pattern.contentUserSpace = true
  of SvgNodeType.Ellipse:
    # unspecified radii are 'auto' (-1), resolved when the shape is built
    node.ellipse.rx = -1.0'f32
    node.ellipse.ry = -1.0'f32
  else: discard
  runAttrs(ctx, attrs, parse)
  case kind
  of SvgNodeType.Doc:
    let doc = node.doc
    if SvgViewFlag.Viewbox notin doc.viewFlag:
      if SvgViewFlag.Width in doc.viewFlag: ctx.parser.global.w = doc.w
      if SvgViewFlag.Height in doc.viewFlag: ctx.parser.global.h = doc.h
  of SvgNodeType.Mask:
    if node.mask.userSpace: recalcBox(ctx, node.mask.box, node.mask.isPercentage)
  of SvgNodeType.Filter:
    if node.filter.filterUserSpace: recalcBox(ctx, node.filter.box, node.filter.isPercentage)
  of SvgNodeType.Pattern:
    if node.pattern.patternUserSpace: recalcBox(ctx, node.pattern.box, node.pattern.isPercentage)
  else: discard
  node
