## Attribute parsers of the SVG elements: what each `_attrParse<Node>Node` of the original
## does with one `key="value"` pair of the element being parsed (`ctx.parser.node`).
##
## Ported from `modules/svg/tvgSvgLoader.cpp`. The per-type `...Tags[]` offset tables are
## `case` statements on the attribute name. `parseNodeAttr` dispatches on the node kind.
## Attribute callbacks return false for unknown attributes; callers ignore it except for
## the declarations of a `style` attribute.

import std/options
import ../../core/[types, geom, str]
import ./[nodes, util, xml, parser_value, parser_style, parser_clone]

proc parseInlineStyle(ctx: SvgParserContext, value: string): bool =
  ## The `style=""` attribute: a list of CSS declarations.
  xmlParseW3CAttribute(value, proc(k, v: string): bool = parseStyleAttr(ctx, k, v, true))

proc commonAttr(ctx: SvgParserContext, node: SvgNode, key, value: string,
                withFilter = true): bool =
  ## `style`, `id`, `class`, `filter` and the presentation attributes (`_attrParseGNode`).
  case key
  of "style": return parseInlineStyle(ctx, value)
  of "id": node.id = value
  of "class": handleCssClass(ctx, node, value)
  of "filter":
    if withFilter: handleFilterAttr(node, value)
    else: return parseStyleAttr(ctx, key, value, false)
  else: return parseStyleAttr(ctx, key, value, false)
  true

# --- boxes (mask, filter, gaussian blur, pattern) ---

func boxIndex(key: string): int =
  case key
  of "x": 0
  of "y": 1
  of "width": 2
  of "height": 3
  else: -1

func setBoxField(box: var Box, i: int, v: float32) =
  case i
  of 0: box.x = v
  of 1: box.y = v
  of 2: box.w = v
  else: box.h = v

func recalcBox*(ctx: SvgParserContext, box: var Box, isPercentage: array[4, bool]) =
  ## `_recalcBox`: fractional fields become lengths in the viewport.
  let g = ctx.parser.global
  if isPercentage[0]: box.x = box.x * g.w
  if isPercentage[1]: box.y = box.y * g.h
  if isPercentage[2]: box.w = box.w * g.w
  if isPercentage[3]: box.h = box.h * g.h

proc parseBox(key, value: string, box: var Box, isPercentage: var array[4, bool]): bool =
  let i = boxIndex(key)
  if i < 0: return false
  setBoxField(box, i, gradientFloat(nil, value, isPercentage[i]))
  true

# --- <svg> ---

proc parseSvgAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  ## `_attrParseSvgNode`: size, view box and aspect ratio of an `<svg>`.
  template doc: untyped = node.doc
  template global: untyped = ctx.parser.global
  case key
  of "width":
    doc.w = ctxLength(ctx, value, LengthKind.Horizontal)
    if '%' in value and SvgViewFlag.Viewbox notin doc.viewFlag:
      doc.viewFlag.incl SvgViewFlag.WidthInPercent
    else:
      doc.viewFlag.incl SvgViewFlag.Width
  of "height":
    doc.h = ctxLength(ctx, value, LengthKind.Vertical)
    if '%' in value and SvgViewFlag.Viewbox notin doc.viewFlag:
      doc.viewFlag.incl SvgViewFlag.HeightInPercent
    else:
      doc.viewFlag.incl SvgViewFlag.Height
  of "viewBox":
    var pos = 0
    if parseNumberAt(value, pos, doc.vbox.x):
      if parseNumberAt(value, pos, doc.vbox.y):
        if parseNumberAt(value, pos, doc.vbox.w):
          if parseNumberAt(value, pos, doc.vbox.h):
            doc.viewFlag.incl SvgViewFlag.Viewbox
            global.h = doc.vbox.h
          global.w = doc.vbox.w
        global.y = doc.vbox.y
      global.x = doc.vbox.x
    if SvgViewFlag.Viewbox in doc.viewFlag and (doc.vbox.w < 0.0'f32 or doc.vbox.h < 0.0'f32):
      doc.viewFlag.excl SvgViewFlag.Viewbox # negative size: the attribute is invalid
    if SvgViewFlag.Viewbox notin doc.viewFlag:
      global.x = 0.0'f32
      global.y = 0.0'f32
      global.w = 1.0'f32
      global.h = 1.0'f32
  of "preserveAspectRatio": parseAspectRatio(value, doc.align, doc.meetOrSlice)
  of "style": return parseInlineStyle(ctx, value)
  else: return parseStyleAttr(ctx, key, value, false)
  true

# --- containers ---

proc parseClipPathAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  if key == "clipPathUnits":
    if value == "objectBoundingBox": node.clipUserSpace = false
    return true
  commonAttr(ctx, node, key, value, withFilter = false)

proc parseMaskAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  if parseBox(key, value, node.mask.box, node.mask.isPercentage): return true
  case key
  of "maskUnits":
    if value == "userSpaceOnUse": node.mask.userSpace = true
  of "maskContentUnits":
    if value == "objectBoundingBox": node.mask.maskContentUserSpace = false
  of "mask-type": node.mask.kind = toMaskType(value)
  of "style", "id", "class": return commonAttr(ctx, node, key, value, withFilter = false)
  else: return parseStyleAttr(ctx, key, value, false)
  true

proc parseSymbolAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  template symbol: untyped = node.symbol
  case key
  of "viewBox":
    var pos = 0
    if not parseNumberAt(value, pos, symbol.vx) or not parseNumberAt(value, pos, symbol.vy):
      return false
    if not parseNumberAt(value, pos, symbol.vw) or not parseNumberAt(value, pos, symbol.vh):
      return false
    symbol.hasViewBox = true
  of "width":
    symbol.w = ctxLength(ctx, value, LengthKind.Horizontal)
    symbol.hasWidth = true
  of "height":
    symbol.h = ctxLength(ctx, value, LengthKind.Vertical)
    symbol.hasHeight = true
  of "preserveAspectRatio": parseAspectRatio(value, symbol.align, symbol.meetOrSlice)
  of "overflow":
    if value == "visible": symbol.overflowVisible = true
  else: return commonAttr(ctx, node, key, value)
  true

proc parseFilterAttr(node: SvgNode, key, value: string): bool =
  ## `_attrParseFilterNode`: only the region and the units; everything else is ignored.
  discard parseBox(key, value, node.filter.box, node.filter.isPercentage)
  case key
  of "id": node.id = value
  of "primitiveUnits":
    if value == "objectBoundingBox": node.filter.primitiveUserSpace = false
  of "filterUnits":
    if value == "userSpaceOnUse": node.filter.filterUserSpace = true
  else: discard
  true

func parseStdDeviation(value: string, x, y: var float32) =
  ## One or two non-negative numbers.
  var deviation: array[2, float32]
  var n = 0
  var pos = 0
  while pos < value.len and n < 2:
    pos = skipWhiteSpaceAndComma(value, pos)
    var e = 0
    let parsed = toFloat(value, pos, e)
    if parsed < 0.0'f32: break
    deviation[n] = parsed
    inc n
    pos = e
  x = deviation[0]
  y = if n == 1: deviation[0] else: deviation[1]

proc parseGaussianBlurAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  template blur: untyped = node.gaussianBlur
  if parseBox(key, value, blur.box, blur.isPercentage): blur.hasBox = true
  case key
  of "id": node.id = value
  of "stdDeviation": parseStdDeviation(value, blur.stdDevX, blur.stdDevY)
  of "edgeMode":
    if value == "wrap": blur.edgeModeWrap = true
  else: return parseStyleAttr(ctx, key, value, false)
  true

proc parsePatternAttr(node: SvgNode, key, value: string): bool =
  template pattern: untyped = node.pattern
  if parseBox(key, value, pattern.box, pattern.isPercentage): return true
  case key
  of "id": node.id = value
  of "patternUnits":
    if value == "userSpaceOnUse": pattern.patternUserSpace = true
  of "patternContentUnits":
    if value == "objectBoundingBox": pattern.contentUserSpace = false
  of "viewBox":
    var pos = 0
    if not parseNumberAt(value, pos, pattern.vbox.x) or
        not parseNumberAt(value, pos, pattern.vbox.y): return false
    if not parseNumberAt(value, pos, pattern.vbox.w) or
        not parseNumberAt(value, pos, pattern.vbox.h): return false
    if pattern.vbox.w > 0.0'f32 and pattern.vbox.h > 0.0'f32: pattern.hasViewBox = true
  of "patternTransform":
    var m = identity()
    pattern.transform = if parseTransform(value, m): some(m) else: none(Matrix)
  else: discard
  true

# --- shapes ---

proc parseCircleAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  case key
  of "cx": node.circle.cx = ctxLength(ctx, value, LengthKind.Horizontal)
  of "cy": node.circle.cy = ctxLength(ctx, value, LengthKind.Vertical)
  of "r": node.circle.r = ctxLength(ctx, value, LengthKind.Diagonal)
  else: return commonAttr(ctx, node, key, value)
  true

proc parseEllipseAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  case key
  of "cx": node.ellipse.cx = ctxLength(ctx, value, LengthKind.Horizontal)
  of "cy": node.ellipse.cy = ctxLength(ctx, value, LengthKind.Vertical)
  of "rx": node.ellipse.rx = ctxLength(ctx, value, LengthKind.Horizontal)
  of "ry": node.ellipse.ry = ctxLength(ctx, value, LengthKind.Vertical)
  else: return commonAttr(ctx, node, key, value)
  true

proc parsePolygonAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  if key == "points":
    var pos = 0
    var x, y: float32
    while parseNumberAt(value, pos, x) and parseNumberAt(value, pos, y):
      node.polygon.pts.add x
      node.polygon.pts.add y
    return true
  commonAttr(ctx, node, key, value)

proc parseRectAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  template rect: untyped = node.rect
  case key
  of "x": rect.x = ctxLength(ctx, value, LengthKind.Horizontal)
  of "y": rect.y = ctxLength(ctx, value, LengthKind.Vertical)
  of "width": rect.w = ctxLength(ctx, value, LengthKind.Horizontal)
  of "height": rect.h = ctxLength(ctx, value, LengthKind.Vertical)
  of "rx", "ry":
    if key == "rx":
      rect.rx = ctxLength(ctx, value, LengthKind.Horizontal)
      rect.hasRx = true
    else:
      rect.ry = ctxLength(ctx, value, LengthKind.Vertical)
      rect.hasRy = true
  else: return commonAttr(ctx, node, key, value)
  # only rx or only ry declared: the other one follows
  if rect.rx >= FloatEpsilon and rect.ry < FloatEpsilon and rect.hasRx and not rect.hasRy:
    rect.ry = rect.rx
  if rect.ry >= FloatEpsilon and rect.rx < FloatEpsilon and not rect.hasRx and rect.hasRy:
    rect.rx = rect.ry
  true

proc parseLineAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  case key
  of "x1": node.line.x1 = ctxLength(ctx, value, LengthKind.Horizontal)
  of "y1": node.line.y1 = ctxLength(ctx, value, LengthKind.Vertical)
  of "x2": node.line.x2 = ctxLength(ctx, value, LengthKind.Horizontal)
  of "y2": node.line.y2 = ctxLength(ctx, value, LengthKind.Vertical)
  else: return commonAttr(ctx, node, key, value)
  true

proc parsePathAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  if key == "d":
    node.path = value
    return true
  commonAttr(ctx, node, key, value)

proc parseImageAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  case key
  of "x": node.image.x = ctxLength(ctx, value, LengthKind.Horizontal)
  of "y": node.image.y = ctxLength(ctx, value, LengthKind.Vertical)
  of "width": node.image.w = ctxLength(ctx, value, LengthKind.Horizontal)
  of "height": node.image.h = ctxLength(ctx, value, LengthKind.Vertical)
  of "href", "xlink:href": node.image.href = idFromHref(value)
  else: return commonAttr(ctx, node, key, value)
  true

# --- use ---

proc useHref(ctx: SvgParserContext, node: SvgNode, value: string) =
  ## `href` of `<use>`: clones the referenced node now, or postpones it when it depends on a
  ## node that is itself waiting, or when the target is not (yet) defined.
  let id = idFromHref(value)
  let nodeFrom = findNodeById(getDefsNode(node), id)
  if nodeFrom == nil:
    # `<defs>` may come at the end of the file: look again once the whole file is parsed
    ctx.cloneNodes.add SvgNodeIdPair(node: node, id: id)
    return
  if findParentById(node, id, ctx.doc) != nil: return # reference to an ancestor: invalid
  for pair in ctx.cloneNodes:
    if checkPostponed(nodeFrom, pair.node, 1):
      ctx.cloneNodes.add SvgNodeIdPair(node: node, id: id)
      return
  cloneNode(nodeFrom, node, 0)
  if nodeFrom.kind == SvgNodeType.Symbol: node.use.symbol = nodeFrom

proc parseUseAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  template use: untyped = node.use
  case key
  of "x": use.x = ctxLength(ctx, value, LengthKind.Horizontal)
  of "y": use.y = ctxLength(ctx, value, LengthKind.Vertical)
  of "width":
    use.w = ctxLength(ctx, value, LengthKind.Horizontal)
    use.isWidthSet = true
  of "height":
    use.h = ctxLength(ctx, value, LengthKind.Vertical)
    use.isHeightSet = true
  of "href", "xlink:href": useHref(ctx, node, value)
  else: return commonAttr(ctx, node, key, value)
  true

# --- text ---

proc prescanTextFontSize*(ctx: SvgParserContext, key, value: string): bool =
  ## `_attrPrescanTextFontSize`: the font size is needed before the other attributes (`em`).
  if key == "font-size": ctx.parser.node.text.fontSize = ctxFontSize(ctx, value)
  true

proc parseTextAttr(ctx: SvgParserContext, node: SvgNode, key, value: string): bool =
  template text: untyped = node.text
  case key
  of "x": text.x = ctxLength(ctx, value, LengthKind.Horizontal)
  of "y": text.y = ctxLength(ctx, value, LengthKind.Vertical)
  of "dx": text.dx = ctxLength(ctx, value, LengthKind.Horizontal)
  of "dy": text.dy = ctxLength(ctx, value, LengthKind.Vertical)
  of "font-size": text.fontSize = ctxFontSize(ctx, value)
  of "font-family":
    if value.len > 0: text.fontFamily = value
  else: return commonAttr(ctx, node, key, value)
  true

# --- dispatcher and font-face ---

proc parseNodeAttr*(ctx: SvgParserContext, key, value: string): bool =
  ## Applies one attribute to `ctx.parser.node` according to its element type.
  let node = ctx.parser.node
  case node.kind
  of SvgNodeType.Doc: parseSvgAttr(ctx, node, key, value)
  of SvgNodeType.ClipPath: parseClipPathAttr(ctx, node, key, value)
  of SvgNodeType.Mask: parseMaskAttr(ctx, node, key, value)
  of SvgNodeType.CssStyle:
    if key == "id":
      node.id = value
      true
    else: parseStyleAttr(ctx, key, value, true)
  of SvgNodeType.Symbol: parseSymbolAttr(ctx, node, key, value)
  of SvgNodeType.Filter: parseFilterAttr(node, key, value)
  of SvgNodeType.GaussianBlur: parseGaussianBlurAttr(ctx, node, key, value)
  of SvgNodeType.Pattern: parsePatternAttr(node, key, value)
  of SvgNodeType.Path: parsePathAttr(ctx, node, key, value)
  of SvgNodeType.Circle: parseCircleAttr(ctx, node, key, value)
  of SvgNodeType.Ellipse: parseEllipseAttr(ctx, node, key, value)
  of SvgNodeType.Polygon, SvgNodeType.Polyline: parsePolygonAttr(ctx, node, key, value)
  of SvgNodeType.Rect: parseRectAttr(ctx, node, key, value)
  of SvgNodeType.Line: parseLineAttr(ctx, node, key, value)
  of SvgNodeType.Image: parseImageAttr(ctx, node, key, value)
  of SvgNodeType.Use: parseUseAttr(ctx, node, key, value)
  of SvgNodeType.Text, SvgNodeType.Tspan: parseTextAttr(ctx, node, key, value)
  else: commonAttr(ctx, node, key, value)

proc parseFontFaceAttr*(ctx: SvgParserContext, key, value: string): bool =
  ## `_attrParseFontFace`: `font-family` and `src` of the last `@font-face`.
  let key = key[skipWhiteSpace(key, 0) .. ^1]
  let value = value[skipWhiteSpace(value, 0) .. ^1]
  if ctx.fonts.len == 0: return false
  if key == "font-family": ctx.fonts[^1].name = unquote(value)
  elif key == "src": ctx.fonts[^1].src = srcFromUrl(value)
  true
