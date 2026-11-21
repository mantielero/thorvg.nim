## SVG value-parsing primitives: whitespace scanning, URL decoding, HSL, numbers lists,
## `transform` attributes, lengths with units, offsets, opacities, dash arrays, `url(#id)`.
##
## Ported from `modules/svg/tvgSvgUtil.cpp` plus the pure helpers of `tvgSvgLoader.cpp`
## (`_toFloat`, `_unitScale`, `_toOffset`, `_toOpacity`, `_parseDashArray`, `_idFromUrl`,
## `_parseNumbersArray`, `parseTransform`). The original reads `SvgParser` state (viewport,
## font size); here those values are explicit parameters. Strings are scanned by index and
## `charAt` gives the C `'\0'` terminator beyond the end.

import std/[math, strutils]
import ../../core/[types, geom, str]

# SVG numbers can be `nan` / `inf` / huge (`stroke-width:nan`, `fill-opacity:1e40`); C++
# propagates them silently, so float checks stay off in this module (see D-T17b-6).
{.push floatChecks: off.}

const
  PxPerIn* = 96.0'f32 ## 1 in = 96 px
  PxPerPc* = 16.0'f32 ## 1 pc = 1/6 in
  PxPerPt* = 1.333333'f32 ## 1 pt = 1/72 in
  PxPerMm* = 3.779528'f32 ## 1 in = 25.4 mm
  PxPerCm* = 37.79528'f32 ## 1 in = 2.54 cm
  DefaultFontSize* = 10.0'f32

type LengthKind* {.pure.} = enum
  ## Which viewport dimension a percentage length refers to.
  Vertical
  Horizontal
  Diagonal
  Other

func skipWhiteSpace*(s: string, i: int, iEnd = -1): int =
  ## First index >= `i` that is not a space; stops at `iEnd` (or the end of `s` when -1).
  result = i
  while (iEnd >= 0 and result < iEnd) or (iEnd < 0 and s.charAt(result) != '\0'):
    if not isCSpace(s.charAt(result)): break
    inc result

func unskipWhiteSpace*(s: string, i, iStart: int): int =
  ## Index just after the last non-space before `i` (never below `iStart + 1`, as the original).
  if i == iStart: return i
  var k = i - 1
  while k > iStart:
    if not isCSpace(s.charAt(k)): break
    dec k
  k + 1

func skipWhiteSpaceAndComma*(s: string, i: int): int =
  result = skipWhiteSpace(s, i)
  if s.charAt(result) == ',': inc result

func hexValue(c: char): int =
  if c >= 'a': ord(c) - ord('a') + 10
  elif c >= 'A': ord(c) - ord('A') + 10
  else: ord(c) - ord('0')

func urlDecode*(src: string): string =
  ## Decodes `%XX` and `+` (as space).
  var i = 0
  while i < src.len:
    if src[i] == '%' and src.charAt(i + 1) in HexDigits and src.charAt(i + 2) in HexDigits:
      result.add char((hexValue(src[i + 1]) shl 4) + hexValue(src[i + 2]))
      i += 3
    elif src[i] == '+':
      result.add ' '
      inc i
    else:
      result.add src[i]
      inc i

func hslToRgb*(h, s, l: float32, r, g, b: var uint8) =
  ## `h` in degrees, `s` and `l` in 0..1.
  if zero(s):
    let v = uint8(nearbyint(l * 255.0'f32))
    r = v
    g = v
    b = v
    return
  var hue = h
  if equal(hue, 360.0'f32):
    hue = 0.0'f32
  else:
    hue = hue mod 360.0'f32
    if hue < 0.0'f32: hue += 360.0'f32
    hue /= 60.0'f32
  let v = if l <= 0.5'f32: l * (1.0'f32 + s) else: l + s - (l * s)
  let p = l + l - v
  let sv = if zero(v): 0.0'f32 else: (v - p) / v
  let i = uint8(hue)
  let f = hue - float32(i)
  let vsf = v * sv * f
  let t = p + vsf
  let q = v - vsf
  var tr, tg, tb: float32
  case i
  of 0: (tr, tg, tb) = (v, t, p)
  of 1: (tr, tg, tb) = (q, v, p)
  of 2: (tr, tg, tb) = (p, v, t)
  of 3: (tr, tg, tb) = (p, q, v)
  of 4: (tr, tg, tb) = (t, p, v)
  of 5: (tr, tg, tb) = (v, p, q)
  else: (tr, tg, tb) = (0.0'f32, 0.0'f32, 0.0'f32)
  r = uint8(nearbyint(tr * 255.0'f32))
  g = uint8(nearbyint(tg * 255.0'f32))
  b = uint8(nearbyint(tb * 255.0'f32))

proc parseNumber*(s: string, pos: var int, endPos: var int, number: var float32): bool =
  ## Reads a number at `pos`. On success `pos` moves past it and a following comma, and
  ## `endPos` is the end of the number itself; on failure `endPos` is the unchanged `pos`.
  var e = 0
  number = toFloat(s, pos, e)
  endPos = e
  if pos == e: return false
  pos = skipWhiteSpaceAndComma(s, e)
  true

func parseNumbersArray*(s: string, pos: var int, points: var openArray[float32]): int =
  ## Reads up to `points.len` numbers separated by spaces/commas; returns how many.
  pos = skipWhiteSpace(s, pos)
  while result < points.len and
      (isCDigit(s.charAt(pos)) or s.charAt(pos) in {'-', '+', '.'}):
    var e = 0
    points[result] = toFloat(s, pos, e)
    inc result
    pos = skipWhiteSpace(s, skipWhiteSpaceAndComma(s, e))

func mat(a, b, c, d, e, f: float32): Matrix =
  Matrix(e11: a, e12: b, e13: c, e21: d, e22: e, e23: f, e31: 0, e32: 0, e33: 1)

func parseTransform*(value: string, m: var Matrix): bool =
  ## Parses an SVG `transform` list into `m` (identity first, then each item multiplied on
  ## the right). Returns false on any syntax error (`m` is then undefined).
  const tags = ["matrix", "translate", "rotate", "scale", "skewX", "skewY"]
  m = identity()
  var points: array[8, float32]
  var pos = 0
  while pos < value.len:
    if isCSpace(value[pos]) or value[pos] == ',':
      inc pos
    else:
      var tag = -1
      for i, t in tags:
        if value.continuesWith(t, pos):
          tag = i
          pos += t.len
          break
      if tag < 0: return false
      pos = skipWhiteSpace(value, pos, value.len)
      if value.charAt(pos) != '(': return false
      inc pos
      let n = parseNumbersArray(value, pos, points)
      if value.charAt(pos) != ')': return false
      inc pos
      case tag
      of 0:
        if n != 6: return false
        m = m * mat(points[0], points[2], points[4], points[1], points[3], points[5])
      of 1:
        if n == 1: m = m * mat(1, 0, points[0], 0, 1, 0)
        elif n == 2: m = m * mat(1, 0, points[0], 0, 1, points[1])
        else: return false
      of 2:
        var deg = points[0] mod 360.0'f32
        if deg < 0: deg += 360.0'f32
        let c = cos(deg2rad(deg))
        let s = sin(deg2rad(deg))
        if n == 1:
          m = m * mat(c, -s, 0, s, c, 0)
        elif n == 3:
          m = m * mat(1, 0, points[1], 0, 1, points[2])
          m = m * mat(c, -s, 0, s, c, 0)
          m = m * mat(1, 0, -points[1], 0, 1, -points[2])
        else: return false
      of 3:
        if n < 1 or n > 2: return false
        let sy = if n == 2: points[1] else: points[0]
        m = m * mat(points[0], 0, 0, 0, sy, 0)
      of 4:
        if n != 1: return false
        m = m * mat(1, tan(deg2rad(points[0])), 0, 0, 1, 0)
      else:
        if n != 1: return false
        m = m * mat(1, 0, 0, tan(deg2rad(points[0])), 1, 0)
  true

func unitScale*(str: string, emBase: float32): float32 =
  ## Pixels per unit named in `str` (`em`, `ex`, `cm`, `mm`, `pt`, `pc`, `in`; else 1).
  if "em" in str: emBase
  elif "ex" in str: emBase * 0.5'f32
  elif "cm" in str: PxPerCm
  elif "mm" in str: PxPerMm
  elif "pt" in str: PxPerPt
  elif "pc" in str: PxPerPc
  elif "in" in str: PxPerIn
  else: 1.0'f32

func isPercentage(s: string, e: int): bool = s.charAt(skipWhiteSpace(s, e)) == '%'

func toLength*(str: string, kind: LengthKind, viewW, viewH, emBase: float32): float32 =
  ## A length (https://www.w3.org/TR/SVG/coords.html#Units); percentages use the viewport
  ## `viewW` x `viewH`, `em`/`ex` use `emBase` (font size in px).
  var e = 0
  let v = toFloat(str, 0, e)
  if isPercentage(str, e):
    case kind
    of LengthKind.Vertical: return (v / 100.0'f32) * viewH
    of LengthKind.Horizontal: return (v / 100.0'f32) * viewW
    of LengthKind.Diagonal:
      return (sqrt(viewW * viewW + viewH * viewH) / sqrt(2.0'f32)) * (v / 100.0'f32)
    of LengthKind.Other: return (v / 100.0'f32) * max(viewW, viewH)
  v * unitScale(str, emBase)

func toFontSize*(str: string, emBase: float32): float32 =
  ## `font-size`: never negative; `emBase` is the parent font size in px.
  var e = 0
  let v = max(toFloat(str, 0, e), 0.0'f32)
  if isPercentage(str, e): (v / 100.0'f32) * emBase else: v * unitScale(str, emBase)

func gradientToFloat*(str: string, emBase: float32, isPercent: var bool): float32 =
  ## Gradient coordinate: a fraction when written with `%` (then `isPercent`), else a length.
  var e = 0
  let v = toFloat(str, 0, e)
  isPercent = isPercentage(str, e)
  if isPercent: v / 100.0'f32 else: v * unitScale(str, emBase)

func toOffset*(str: string): float32 =
  ## Stop offset: a number or a percentage; 0 when there is trailing garbage.
  var e = 0
  var v = toFloat(str, 0, e)
  e = skipWhiteSpace(str, e)
  let pct = str.find('%')
  if pct >= 0:
    v = v / 100.0'f32
    if e != pct or e + 1 != str.len: return 0
  elif e != str.len: return 0
  v

func lrint32(x: float32, k: float32): int =
  ## C `lrint(x * k)` with the 32-bit `long` of the Windows ABI: out of range, infinite and
  ## NaN values give INT_MIN (so odd opacities such as `1e12` or `inf` behave like the
  ## original). Huge `x` is cut off before the product so float checks never trigger.
  if x != x or abs(x) > 1.0e36'f32: return -2147483648
  let r = nearbyint(x * k)
  if r >= -2147483648.0'f32 and r < 2147483648.0'f32: int(r) else: -2147483648

func toOpacity*(str: string): int =
  ## Opacity as 0..255 (any int for odd values); 255 when `str` is not a plain number
  ## or percentage.
  var e = 0
  let o = toFloat(str, 0, e)
  if str.charAt(e) == '%' and e + 1 == str.len: lrint32(o, 2.55'f32)
  elif e >= str.len: lrint32(o, 255.0'f32)
  else: 255

proc parseDashArray*(str: string, viewW, viewH: float32, dash: var seq[float32]): bool =
  ## `stroke-dasharray`: `none` or a list of non-negative numbers (`%` of the viewport
  ## diagonal). Returns true when `dash` ends up non-empty (or the value is `none`).
  if str == "none":
    dash.setLen(0)
    return true
  var pos = 0
  var replaced = false
  while str.charAt(pos) != '\0':
    pos = skipWhiteSpaceAndComma(str, pos)
    var e = 0
    var v = toFloat(str, pos, e)
    if pos == e: break
    if not replaced:
      dash.setLen(0)
      replaced = true
    if v < 0.0'f32:
      dash.setLen(0)
      return false
    if str.charAt(e) == '%':
      inc e
      v = (sqrt(viewW * viewW + viewH * viewH) / sqrt(2.0'f32)) * (v / 100.0'f32)
    dash.add v
    pos = e
  dash.len > 0

func idFromUrl*(url: string): string =
  ## Extracts `id` from `(#id)` / `( '#id' )`; "" when malformed. Pass the text after `url`.
  let open0 = url.find('(')
  var close = url.find(')')
  if open0 < 0 or close < 0 or open0 >= close: return ""
  var open = url.find('#')
  if open < 0 or open >= close: return ""
  inc open
  dec close
  while open < close and url[close] in {' ', '\'', '"'}: dec close
  for i in open ..< close:
    if url[i] in {' ', '\''}: return ""
  url[open .. close]
