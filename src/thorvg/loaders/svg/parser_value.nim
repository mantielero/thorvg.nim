## Value parsers of the SVG loader that map attribute text to node-model values.
##
## Ported from the `_to...` helpers of `modules/svg/tvgSvgLoader.cpp`: aspect ratio, font
## weight, baseline, paint order, line cap/join, fill rule, blend mode, xml:space, href/url
## helpers. Tag lookups (`_PARSE_TAG`) are `case` statements over the exact tag text.
## `ctxLength` & co. read the viewport and font size from the parser state, as `_toFloat`.

import std/strutils
import ../../core/[types, str]
import ./[nodes, util, xml]

type AttrParser* = proc(buf: string, cb: XmlAttributeCb): bool
  ## The `parseAttributes` of the original: `xmlParseAttributes` or `xmlParseW3CAttribute`.

func isFontRelativeUnit*(value: string): bool =
  ## True for a trailing `em`/`ex` unit (`rem` is not one).
  var p = value.len
  while p > 0 and isCSpace(value[p - 1]): dec p
  let e = p
  while p > 0 and value[p - 1] in Letters: dec p
  e - p == 2 and (value.continuesWith("em", p) or value.continuesWith("ex", p))

func ctxLength*(ctx: SvgParserContext, value: string, kind: LengthKind): float32 =
  ## `_toFloat`: a length in the current viewport and font context.
  toLength(value, kind, ctx.parser.global.w, ctx.parser.global.h,
           findEmBaseFontSize(ctx.parser.node))

func ctxFontSize*(ctx: SvgParserContext, value: string): float32 =
  ## `_toFontSize`: relative to the font size of the parent of the current node.
  let n = ctx.parser.node
  toFontSize(value, findEmBaseFontSize(if n != nil: n.parent else: nil))

func gradientFloat*(ctx: SvgParserContext, value: string, isPercent: var bool): float32 =
  ## `_gradientToFloat` with the current font context (`ctx` may be nil: default font size).
  let n = if ctx != nil: ctx.parser.node else: nil
  gradientToFloat(value, findEmBaseFontSize(n), isPercent)

func idFromHref*(href: string): string =
  ## `_idFromHref`: the id of `#id` (leading blanks and the `#` are dropped).
  var p = skipWhiteSpace(href, 0)
  if href.charAt(p) == '#': inc p
  href[p .. ^1]

func unquote*(s: string): string =
  if s.len >= 2 and s[0] == '\'' and s[^1] == '\'': s[1 ..< s.len - 1] else: s

func srcFromUrl*(url: string): string =
  ## `_srcFromUrl`: the quoted source inside `url('...')`, trimmed; "" when malformed.
  let open = url.find('(')
  let close = url.find(')')
  if open < 0 or close < 0 or open >= close: return ""
  var src = url.find('\'', open)
  if src < 0 or src >= close: return ""
  inc src
  var last = url.find('\'', src)
  if last < 0 or last == src: return ""
  dec last
  while src < last and url[src] == ' ': inc src
  while src < last and url[last] == ' ': dec last
  url[src .. last]

func parseAspectRatio*(value: string, align: var AspectRatioAlign,
                       meetOrSlice: var AspectRatioMeetOrSlice) =
  const tags = ["xMinYMin", "xMidYMin", "xMaxYMin", "xMinYMid", "xMidYMid", "xMaxYMid",
                "xMinYMax", "xMidYMax", "xMaxYMax"]
  if value == "none":
    align = AspectRatioAlign.None
    return
  var pos = 0
  for i, t in tags:
    if value.continuesWith(t, 0):
      align = AspectRatioAlign(i + 1)
      pos = skipWhiteSpace(value, 8)
      break
  let rest = value[pos .. ^1]
  if rest == "meet": meetOrSlice = AspectRatioMeetOrSlice.Meet
  elif rest == "slice": meetOrSlice = AspectRatioMeetOrSlice.Slice

func toFontWeight*(str: string): SvgFontWeight =
  case str
  of "normal": return SvgFontWeight.Normal
  of "bold": return SvgFontWeight.Bold
  of "inherit": return SvgFontWeight.Inherit
  of "bolder": return SvgFontWeight.Bolder
  of "lighter": return SvgFontWeight.Lighter
  else: discard
  var p = skipWhiteSpace(str, 0)
  var neg = false
  if str.charAt(p) in {'+', '-'}:
    neg = str[p] == '-'
    inc p
  var weight = 0
  while isCDigit(str.charAt(p)):
    weight = min(weight * 10 + (ord(str[p]) - ord('0')), 100000)
    inc p
  if skipWhiteSpace(str, p) < str.len: return SvgFontWeight.Invalid
  if neg: weight = -weight
  case weight
  of 100: SvgFontWeight.Weight100
  of 200: SvgFontWeight.Weight200
  of 300: SvgFontWeight.Weight300
  of 400: SvgFontWeight.Normal
  of 500: SvgFontWeight.Weight500
  of 600: SvgFontWeight.Weight600
  of 700: SvgFontWeight.Bold
  of 800: SvgFontWeight.Weight800
  of 900: SvgFontWeight.Weight900
  else: SvgFontWeight.Invalid

func toBaseline*(str: string): SvgBaseline =
  case str
  of "alphabetic": SvgBaseline.Alphabetic
  of "before-edge", "text-before-edge", "text-top": SvgBaseline.BeforeEdge
  of "after-edge", "text-after-edge", "ideographic", "text-bottom": SvgBaseline.AfterEdge
  of "central": SvgBaseline.Central
  of "middle": SvgBaseline.Middle
  of "hanging": SvgBaseline.Hanging
  of "mathematical": SvgBaseline.Mathematical
  else: SvgBaseline.Auto

func toMaskType*(str: string): SvgMaskType =
  if str == "alpha": SvgMaskType.Alpha else: SvgMaskType.Luminance

func toPaintOrder*(str: string): bool =
  ## True when fill is painted before stroke (the default order).
  var position = 1
  var strokePosition = 0
  var fillPosition = 0
  var p = 0
  while str.charAt(p) != '\0':
    p = skipWhiteSpace(str, p)
    if str.continuesWith("fill", p):
      fillPosition = position
      inc position
      p += 4
    elif str.continuesWith("stroke", p):
      strokePosition = position
      inc position
      p += 6
    elif str.continuesWith("markers", p):
      p += 7
    else:
      return true # invalid: the default order "fill stroke"
  if fillPosition == 0:
    fillPosition = position
    inc position
  if strokePosition == 0: strokePosition = position
  fillPosition < strokePosition

func toLineCap*(str: string): StrokeCap =
  case str
  of "round": StrokeCap.Round
  of "square": StrokeCap.Square
  else: StrokeCap.Butt

func toLineJoin*(str: string): StrokeJoin =
  case str
  of "round": StrokeJoin.Round
  of "bevel": StrokeJoin.Bevel
  else: StrokeJoin.Miter

func toFillRule*(str: string): FillRule =
  if str == "evenodd": FillRule.EvenOdd else: FillRule.NonZero

func toBlendMode*(str: string): BlendMethod =
  case str
  of "multiply": BlendMethod.Multiply
  of "screen": BlendMethod.Screen
  of "overlay": BlendMethod.Overlay
  of "darken": BlendMethod.Darken
  of "lighten": BlendMethod.Lighten
  of "color-dodge": BlendMethod.ColorDodge
  of "color-burn": BlendMethod.ColorBurn
  of "hard-light": BlendMethod.HardLight
  of "soft-light": BlendMethod.SoftLight
  of "difference": BlendMethod.Difference
  of "exclusion": BlendMethod.Exclusion
  of "hue": BlendMethod.Hue
  of "saturation": BlendMethod.Saturation
  of "color": BlendMethod.Color
  of "luminosity": BlendMethod.Luminosity
  else: BlendMethod.Normal

func toXmlSpace*(str: string): SvgXmlSpace =
  case str
  of "default": SvgXmlSpace.Default
  of "preserve": SvgXmlSpace.Preserve
  else: SvgXmlSpace.None

func toSpreadValue*(str: string): FillSpread =
  case str
  of "reflect": FillSpread.Reflect
  of "repeat": FillSpread.Repeat
  else: FillSpread.Pad

func parseNumberAt*(s: string, pos: var int, number: var float32): bool =
  ## `_parseNumber` without the end pointer.
  var e = 0
  parseNumber(s, pos, e, number)
