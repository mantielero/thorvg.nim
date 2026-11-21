## Style attribute parsing of the SVG loader (presentation attributes and `style=""` /
## CSS declarations) and the application of CSS classes to nodes.
##
## Ported from `_handle...Attr`, `_parseStyleAttr` and `_cssApplyClass` of
## `modules/svg/tvgSvgLoader.cpp`. The `styleTags` table is `styleFlagOf` + the `case` of
## `runStyleHandler`. Null urls are "".

import std/[options, strutils]
import ../../core/[types, geom, str]
import ./[nodes, util, color, css, css_style, parser_value]

func styleFlagOf(key: string, flag: var SvgStyleFlag): bool =
  ## The `styleTags` lookup: the exact property name.
  result = true
  case key
  of "color": flag = SvgStyleFlag.Color
  of "fill": flag = SvgStyleFlag.Fill
  of "fill-rule": flag = SvgStyleFlag.FillRule
  of "fill-opacity": flag = SvgStyleFlag.FillOpacity
  of "opacity": flag = SvgStyleFlag.Opacity
  of "stroke": flag = SvgStyleFlag.Stroke
  of "stroke-width": flag = SvgStyleFlag.StrokeWidth
  of "stroke-linejoin": flag = SvgStyleFlag.StrokeLineJoin
  of "stroke-miterlimit": flag = SvgStyleFlag.StrokeMiterlimit
  of "stroke-linecap": flag = SvgStyleFlag.StrokeLineCap
  of "stroke-opacity": flag = SvgStyleFlag.StrokeOpacity
  of "stroke-dasharray": flag = SvgStyleFlag.StrokeDashArray
  of "stroke-dashoffset": flag = SvgStyleFlag.StrokeDashOffset
  of "transform": flag = SvgStyleFlag.Transform
  of "clip-path": flag = SvgStyleFlag.ClipPath
  of "mask": flag = SvgStyleFlag.Mask
  of "mask-type": flag = SvgStyleFlag.MaskType
  of "display": flag = SvgStyleFlag.Display
  of "paint-order": flag = SvgStyleFlag.PaintOrder
  of "filter": flag = SvgStyleFlag.Filter
  of "mix-blend-mode": flag = SvgStyleFlag.BlendMode
  of "image-rendering": flag = SvgStyleFlag.ImageRendering
  of "text-anchor": flag = SvgStyleFlag.TextAnchor
  of "alignment-baseline": flag = SvgStyleFlag.AlignmentBaseline
  of "dominant-baseline": flag = SvgStyleFlag.DominantBaseline
  of "font-weight": flag = SvgStyleFlag.FontWeight
  of "letter-spacing": flag = SvgStyleFlag.LetterSpacing
  of "word-spacing": flag = SvgStyleFlag.WordSpacing
  else: result = false

func handlePaint(paint: var SvgPaint, value: string) =
  if value == "none":
    paint.none = true
    return
  if value == "currentColor":
    paint.curColor = true
    paint.none = false
    paint.url = ""
    return
  paint.color.a = 255
  if toColor(value, paint.color, paint.url):
    paint.none = false
    paint.curColor = false
    if not value.startsWith("url"): paint.url = ""

func urlOf(value: string): string = idFromUrl(value[3 .. ^1])

func handleFilterAttr*(node: SvgNode, value: string) =
  ## `_handleFilterAttr`: only `url(#id)` references are understood.
  if value.startsWith("url"): node.style.filter.url = urlOf(value)

func handleSpacing(value: string, spacing: var float32, relative: var bool) =
  ## letter-spacing / word-spacing: `normal`, a number, `%` or a font-relative unit.
  relative = false
  if value == "normal":
    spacing = 0.0'f32
    return
  var e = 0
  let parsed = toFloat(value, 0, e)
  let percentage = value.charAt(skipWhiteSpace(value, e)) == '%'
  relative = percentage or isFontRelativeUnit(value)
  spacing = parsed * (if percentage: 0.01'f32 else: unitScale(value, 1.0'f32))

proc runStyleHandler(ctx: SvgParserContext, node: SvgNode, flag: SvgStyleFlag, value: string) =
  ## The `_handle<Name>Attr` of `flag`.
  template style: untyped = node.style
  case flag
  of SvgStyleFlag.Color:
    style.color.a = 255
    if toColor(value, style.color): style.curColorSet = true
  of SvgStyleFlag.Fill:
    style.fill.flags.incl SvgFillFlag.Paint
    handlePaint(style.fill.paint, value)
  of SvgStyleFlag.Stroke:
    style.stroke.flags.incl SvgStrokeFlag.Paint
    handlePaint(style.stroke.paint, value)
  of SvgStyleFlag.StrokeOpacity:
    style.stroke.flags.incl SvgStrokeFlag.Opacity
    style.stroke.opacity = toOpacity(value)
  of SvgStyleFlag.StrokeDashArray:
    if parseDashArray(value, ctx.parser.global.w, ctx.parser.global.h, style.stroke.dash.array):
      style.stroke.flags.incl SvgStrokeFlag.Dash
  of SvgStyleFlag.StrokeDashOffset:
    style.stroke.flags.incl SvgStrokeFlag.DashOffset
    style.stroke.dash.offset = ctxLength(ctx, value, LengthKind.Horizontal)
  of SvgStyleFlag.StrokeWidth:
    style.stroke.flags.incl SvgStrokeFlag.Width
    style.stroke.width = ctxLength(ctx, value, LengthKind.Diagonal)
  of SvgStyleFlag.StrokeLineCap:
    style.stroke.flags.incl SvgStrokeFlag.Cap
    style.stroke.cap = toLineCap(value)
  of SvgStyleFlag.StrokeLineJoin:
    style.stroke.flags.incl SvgStrokeFlag.Join
    style.stroke.join = toLineJoin(value)
  of SvgStyleFlag.StrokeMiterlimit:
    let miterlimit = toFloat(value)
    if miterlimit < 0.0'f32: return # illegal value (SVG2 painting): omitted
    style.stroke.flags.incl SvgStrokeFlag.Miterlimit
    style.stroke.miterlimit = miterlimit
  of SvgStyleFlag.FillRule:
    style.fill.flags.incl SvgFillFlag.FillRule
    style.fill.fillRule = toFillRule(value)
  of SvgStyleFlag.Opacity:
    style.flags.incl SvgStyleFlag.Opacity
    style.opacity = toOpacity(value)
  of SvgStyleFlag.FillOpacity:
    style.fill.flags.incl SvgFillFlag.Opacity
    style.fill.opacity = toOpacity(value)
  of SvgStyleFlag.Transform:
    var m = identity()
    node.transform = if parseTransform(value, m): some(m) else: none(Matrix)
  of SvgStyleFlag.ClipPath:
    if value.startsWith("url"): style.clipPath.url = urlOf(value)
    elif value == "none": style.clipPath.url = ""
  of SvgStyleFlag.Mask:
    if value.startsWith("url"): style.mask.url = urlOf(value)
    elif value == "none": style.mask.url = ""
  of SvgStyleFlag.Filter: handleFilterAttr(node, value)
  of SvgStyleFlag.MaskType:
    if node.kind == SvgNodeType.Mask: node.mask.kind = toMaskType(value)
  of SvgStyleFlag.Display:
    style.flags.incl SvgStyleFlag.Display
    style.display = value != "none"
  of SvgStyleFlag.PaintOrder:
    style.flags.incl SvgStyleFlag.PaintOrder
    style.paintOrder = toPaintOrder(value)
  of SvgStyleFlag.BlendMode:
    style.blendMode = toBlendMode(value)
    style.flags.incl SvgStyleFlag.BlendMode
  of SvgStyleFlag.ImageRendering:
    let nearest = value == "pixelated" or value == "crisp-edges"
    style.imageRendering = if nearest: FilterMethod.Nearest else: FilterMethod.Bilinear
    style.flags.incl SvgStyleFlag.ImageRendering
  of SvgStyleFlag.TextAnchor:
    style.flags.incl SvgStyleFlag.TextAnchor
    style.textAnchor = (if value == "middle": 0.5'f32 elif value == "end": 1.0'f32 else: 0.0'f32)
  of SvgStyleFlag.AlignmentBaseline:
    style.flags.incl SvgStyleFlag.AlignmentBaseline
    style.alignmentBaseline = toBaseline(value)
  of SvgStyleFlag.DominantBaseline:
    style.flags.incl SvgStyleFlag.DominantBaseline
    style.dominantBaseline = toBaseline(value)
  of SvgStyleFlag.FontWeight:
    style.fontWeight = toFontWeight(value)
    style.flags.incl SvgStyleFlag.FontWeight
  of SvgStyleFlag.LetterSpacing:
    style.flags.incl SvgStyleFlag.LetterSpacing
    handleSpacing(value, style.letterSpacing, style.letterSpacingRelative)
  of SvgStyleFlag.WordSpacing:
    style.flags.incl SvgStyleFlag.WordSpacing
    handleSpacing(value, style.wordSpacing, style.wordSpacingRelative)

func isValidValue(flag: SvgStyleFlag, value: string): bool =
  case flag
  of SvgStyleFlag.FontWeight: toFontWeight(value) != SvgFontWeight.Invalid
  of SvgStyleFlag.DominantBaseline:
    # the svg 1.1 keyword set only: browsers drop the css-level text-top/text-bottom
    if value == "text-top" or value == "text-bottom": false
    else: toBaseline(value) != SvgBaseline.Auto or value == "auto"
  of SvgStyleFlag.ImageRendering: value != "inherit" # keep the inherited value
  of SvgStyleFlag.LetterSpacing, SvgStyleFlag.WordSpacing:
    var e = 0
    discard toFloat(value, 0, e)
    e != 0 or value == "normal"
  else: true

proc parseStyleAttr*(ctx: SvgParserContext, key, value: string, style: bool): bool =
  ## `_parseStyleAttr`: applies one declaration to `ctx.parser.node`. `style` is true for
  ## `style=""` / CSS declarations (which can override earlier ones) and false for plain
  ## attributes. Returns false when `key` is not a style property.
  let key = key[skipWhiteSpace(key, 0) .. ^1]
  var value = value[skipWhiteSpace(value, 0) .. ^1]
  let node = ctx.parser.node
  if not style and key == "xml:space":
    node.xmlSpace = toXmlSpace(value)
    return true
  var flag: SvgStyleFlag
  if not styleFlagOf(key, flag): return false

  var importance = false
  var ptr0 = value.find("!important")
  if ptr0 < 0 and style:
    let upper = value.find("!IMPORTANT")
    if upper >= 0 and skipWhiteSpace(value, upper + 10) >= value.len: ptr0 = upper
  if ptr0 >= 0:
    var size = ptr0
    while size > 0 and isCSpace(value[size - 1]): dec size
    value = value[0 ..< size]
    importance = true
  if not isValidValue(flag, value): return true
  if style:
    if importance or flag notin node.style.flagsImportance:
      runStyleHandler(ctx, node, flag, value)
      node.style.flags.incl flag
  elif flag notin node.style.flags:
    runStyleHandler(ctx, node, flag, value)
  if importance: node.style.flagsImportance.incl flag
  true

proc cssApplyClass*(node: SvgNode, classString: string, styleRoot: SvgNode): bool =
  ## `_cssApplyClass`: merges the rules of every class in `classString` (`.name` and
  ## `tag.name`) and applies them to `node` without overwriting its own values. Returns
  ## false when a class has no rule (yet).
  if classString.len == 0 or styleRoot == nil: return false
  var allFound = true
  let temp = SvgNode(kind: node.kind)
  temp.style.opacity = 255
  temp.style.color.a = 255
  temp.style.fill.opacity = 255
  temp.style.stroke.opacity = 255
  for name in classNames(classString):
    var found = false
    var cssNode = cssFindStyleNode(styleRoot, name)
    if cssNode != nil:
      cssCopyStyleAttr(temp, cssNode, true)
      found = true
    cssNode = cssFindStyleNode(styleRoot, name, node.kind)
    if cssNode != nil:
      cssCopyStyleAttr(temp, cssNode, true)
      found = true
    if not found: allFound = false
  cssCopyStyleAttr(node, temp)
  allFound

proc handleCssClass*(ctx: SvgParserContext, node: SvgNode, value: string) =
  ## `_handleCssClassAttr`: styles `node` now, or postpones it until the rules are known.
  node.style.cssClass = value
  if not cssApplyClass(node, value, ctx.cssStyle):
    ctx.nodesToStyle.add SvgNodeIdPair(node: node, id: value)

proc cssApplyStyleToPostponeds*(postponeds: seq[SvgNodeIdPair], style: SvgNode) =
  for p in postponeds:
    discard cssApplyClass(p.node, p.node.style.cssClass, style)
