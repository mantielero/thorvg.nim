## SVG color parsing: `#rgb`, `#rrggbb`, `rgb()`, `rgba()`, `hsl()`, named colors, `url(#id)`.
##
## Ported from `_toColor`/`_parseColor`/`_parseHexColor` and the `colors[]` table of
## `modules/svg/tvgSvgLoader.cpp`. Pure functions: callers own the node state.

import std/[strutils, algorithm]
import ../../core/[types, geom, str]
import ./util

const NamedColors: array[147, (string, uint32)] = [
    ("aliceblue", 0xf0f8ff),
    ("antiquewhite", 0xfaebd7),
    ("aqua", 0x00ffff),
    ("aquamarine", 0x7fffd4),
    ("azure", 0xf0ffff),
    ("beige", 0xf5f5dc),
    ("bisque", 0xffe4c4),
    ("black", 0x000000),
    ("blanchedalmond", 0xffebcd),
    ("blue", 0x0000ff),
    ("blueviolet", 0x8a2be2),
    ("brown", 0xa52a2a),
    ("burlywood", 0xdeb887),
    ("cadetblue", 0x5f9ea0),
    ("chartreuse", 0x7fff00),
    ("chocolate", 0xd2691e),
    ("coral", 0xff7f50),
    ("cornflowerblue", 0x6495ed),
    ("cornsilk", 0xfff8dc),
    ("crimson", 0xdc143c),
    ("cyan", 0x00ffff),
    ("darkblue", 0x00008b),
    ("darkcyan", 0x008b8b),
    ("darkgoldenrod", 0xb8860b),
    ("darkgray", 0xa9a9a9),
    ("darkgreen", 0x006400),
    ("darkgrey", 0xa9a9a9),
    ("darkkhaki", 0xbdb76b),
    ("darkmagenta", 0x8b008b),
    ("darkolivegreen", 0x556b2f),
    ("darkorange", 0xff8c00),
    ("darkorchid", 0x9932cc),
    ("darkred", 0x8b0000),
    ("darksalmon", 0xe9967a),
    ("darkseagreen", 0x8fbc8f),
    ("darkslateblue", 0x483d8b),
    ("darkslategray", 0x2f4f4f),
    ("darkslategrey", 0x2f4f4f),
    ("darkturquoise", 0x00ced1),
    ("darkviolet", 0x9400d3),
    ("deeppink", 0xff1493),
    ("deepskyblue", 0x00bfff),
    ("dimgray", 0x696969),
    ("dimgrey", 0x696969),
    ("dodgerblue", 0x1e90ff),
    ("firebrick", 0xb22222),
    ("floralwhite", 0xfffaf0),
    ("forestgreen", 0x228b22),
    ("fuchsia", 0xff00ff),
    ("gainsboro", 0xdcdcdc),
    ("ghostwhite", 0xf8f8ff),
    ("gold", 0xffd700),
    ("goldenrod", 0xdaa520),
    ("gray", 0x808080),
    ("green", 0x008000),
    ("greenyellow", 0xadff2f),
    ("grey", 0x808080),
    ("honeydew", 0xf0fff0),
    ("hotpink", 0xff69b4),
    ("indianred", 0xcd5c5c),
    ("indigo", 0x4b0082),
    ("ivory", 0xfffff0),
    ("khaki", 0xf0e68c),
    ("lavender", 0xe6e6fa),
    ("lavenderblush", 0xfff0f5),
    ("lawngreen", 0x7cfc00),
    ("lemonchiffon", 0xfffacd),
    ("lightblue", 0xadd8e6),
    ("lightcoral", 0xf08080),
    ("lightcyan", 0xe0ffff),
    ("lightgoldenrodyellow", 0xfafad2),
    ("lightgray", 0xd3d3d3),
    ("lightgreen", 0x90ee90),
    ("lightgrey", 0xd3d3d3),
    ("lightpink", 0xffb6c1),
    ("lightsalmon", 0xffa07a),
    ("lightseagreen", 0x20b2aa),
    ("lightskyblue", 0x87cefa),
    ("lightslategray", 0x778899),
    ("lightslategrey", 0x778899),
    ("lightsteelblue", 0xb0c4de),
    ("lightyellow", 0xffffe0),
    ("lime", 0x00ff00),
    ("limegreen", 0x32cd32),
    ("linen", 0xfaf0e6),
    ("magenta", 0xff00ff),
    ("maroon", 0x800000),
    ("mediumaquamarine", 0x66cdaa),
    ("mediumblue", 0x0000cd),
    ("mediumorchid", 0xba55d3),
    ("mediumpurple", 0x9370db),
    ("mediumseagreen", 0x3cb371),
    ("mediumslateblue", 0x7b68ee),
    ("mediumspringgreen", 0x00fa9a),
    ("mediumturquoise", 0x48d1cc),
    ("mediumvioletred", 0xc71585),
    ("midnightblue", 0x191970),
    ("mintcream", 0xf5fffa),
    ("mistyrose", 0xffe4e1),
    ("moccasin", 0xffe4b5),
    ("navajowhite", 0xffdead),
    ("navy", 0x000080),
    ("oldlace", 0xfdf5e6),
    ("olive", 0x808000),
    ("olivedrab", 0x6b8e23),
    ("orange", 0xffa500),
    ("orangered", 0xff4500),
    ("orchid", 0xda70d6),
    ("palegoldenrod", 0xeee8aa),
    ("palegreen", 0x98fb98),
    ("paleturquoise", 0xafeeee),
    ("palevioletred", 0xdb7093),
    ("papayawhip", 0xffefd5),
    ("peachpuff", 0xffdab9),
    ("peru", 0xcd853f),
    ("pink", 0xffc0cb),
    ("plum", 0xdda0dd),
    ("powderblue", 0xb0e0e6),
    ("purple", 0x800080),
    ("red", 0xff0000),
    ("rosybrown", 0xbc8f8f),
    ("royalblue", 0x4169e1),
    ("saddlebrown", 0x8b4513),
    ("salmon", 0xfa8072),
    ("sandybrown", 0xf4a460),
    ("seagreen", 0x2e8b57),
    ("seashell", 0xfff5ee),
    ("sienna", 0xa0522d),
    ("silver", 0xc0c0c0),
    ("skyblue", 0x87ceeb),
    ("slateblue", 0x6a5acd),
    ("slategray", 0x708090),
    ("slategrey", 0x708090),
    ("snow", 0xfffafa),
    ("springgreen", 0x00ff7f),
    ("steelblue", 0x4682b4),
    ("tan", 0xd2b48c),
    ("teal", 0x008080),
    ("thistle", 0xd8bfd8),
    ("tomato", 0xff6347),
    ("turquoise", 0x40e0d0),
    ("violet", 0xee82ee),
    ("wheat", 0xf5deb3),
    ("white", 0xffffff),
    ("whitesmoke", 0xf5f5f5),
    ("yellow", 0xffff00),
    ("yellowgreen", 0x9acd32),
]

func parseHexColor(s: string, c: var RGBA): bool =
  if s.len != 4 and s.len != 7: return false
  var hex: array[6, int]
  for i in 0 ..< s.len - 1:
    let ch = s[i + 1]
    hex[i] =
      if ch in {'0'..'9'}: ord(ch) - ord('0')
      elif ch in {'a'..'f'}: ord(ch) - ord('a') + 10
      elif ch in {'A'..'F'}: ord(ch) - ord('A') + 10
      else: -1
    if hex[i] < 0: return false
  if s.len == 4:
    c.r = uint8(hex[0] * 17)
    c.g = uint8(hex[1] * 17)
    c.b = uint8(hex[2] * 17)
  else:
    c.r = uint8((hex[0] shl 4) or hex[1])
    c.g = uint8((hex[2] shl 4) or hex[3])
    c.b = uint8((hex[4] shl 4) or hex[5])
  true

func parseChannel(s: string, pos: int, endPos: var int): uint8 =
  ## One `rgb()` channel (0..255 or a percentage); `endPos` = -1 when out of range.
  var e = 0
  var r = toFloat(s, pos, e)
  e = skipWhiteSpace(s, e)
  if s.charAt(e) == '%':
    r = 255.0'f32 * r / 100.0'f32
    inc e
  endPos = skipWhiteSpace(s, e)
  if r < 0.0'f32 or r > 255.0'f32:
    endPos = -1
    return 0
  uint8(nearbyint(r))

func parseRgb(s: string, alpha: bool, c: var RGBA): bool =
  var e = 0
  let tr = parseChannel(s, if alpha: 5 else: 4, e)
  if e < 0 or s.charAt(e) != ',': return false
  let tg = parseChannel(s, e + 1, e)
  if e < 0 or s.charAt(e) != ',': return false
  let tb = parseChannel(s, e + 1, e)
  var ta = c.a
  if alpha:
    if e < 0 or s.charAt(e) != ',': return false
    var e2 = 0
    let value = toFloat(s, e + 1, e2)
    e2 = skipWhiteSpace(s, e2)
    if s.charAt(e2) != ')' or e2 + 1 != s.len or value < 0.0'f32 or value > 1.0'f32:
      return false
    ta = uint8(nearbyint(value * 255.0'f32))
  elif e < 0 or s.charAt(e) != ')' or e + 1 != s.len:
    return false
  c = RGBA(r: tr, g: tg, b: tb, a: ta)
  true

func parseHsl(s: string, c: var RGBA): bool =
  var h, sat, light: float32
  var content = skipWhiteSpace(s, 4)
  var hueEnd = 0
  if not parseNumber(s, content, hueEnd, h): return false
  var pos = skipWhiteSpace(s, skipWhiteSpaceAndComma(s, skipWhiteSpace(s, hueEnd)))
  var satEnd = 0
  if not parseNumber(s, pos, satEnd, sat) or s.charAt(satEnd) != '%': return false
  sat /= 100.0'f32
  pos = skipWhiteSpace(s, skipWhiteSpaceAndComma(s, skipWhiteSpace(s, satEnd + 1)))
  var lightEnd = 0
  if not parseNumber(s, pos, lightEnd, light) or s.charAt(lightEnd) != '%': return false
  light /= 100.0'f32
  let last = skipWhiteSpace(s, lightEnd + 1)
  if s.charAt(last) != ')' or last + 1 != s.len: return false
  hslToRgb(h, clamp(sat, 0.0'f32, 1.0'f32), clamp(light, 0.0'f32, 1.0'f32), c.r, c.g, c.b)
  true

func namedColor(s: string, c: var RGBA): bool =
  let key = s.toLowerAscii
  let idx = NamedColors.binarySearch(key, proc(e: (string, uint32), k: string): int = cmp(e[0], k))
  if idx < 0: return false
  let v = NamedColors[idx][1]
  c.r = uint8(v shr 16)
  c.g = uint8((v shr 8) and 0xff)
  c.b = uint8(v and 0xff)
  true

func parseColorText(s: string, c: var RGBA, url: var string, wantUrl: bool): bool =
  if s.len == 0: return namedColor(s, c)
  if s[0] == '#': return parseHexColor(s, c)
  if s.len >= 10 and s.toLowerAscii.startsWith("rgb(") and s[^1] == ')': return parseRgb(s, false, c)
  if s.len >= 12 and s.toLowerAscii.startsWith("rgba(") and s[^1] == ')':
    return parseRgb(s, true, c)
  if wantUrl and s.len >= 3 and s.startsWith("url"):
    url = idFromUrl(s[3 .. ^1])
    return true
  if s.len >= 10 and s.toLowerAscii.startsWith("hsl(") and s[^1] == ')':
    return parseHsl(s, c)
  namedColor(s, c)

func toColor*(str: string, c: var RGBA): bool =
  ## Parses a color; only `rgba()` writes `c.a` (callers pre-set it to 255).
  var url = ""
  parseColorText(str, c, url, false)

func toColor*(str: string, c: var RGBA, url: var string): bool =
  ## Like `toColor`, also accepting `url(#id)`, in which case `url` receives the id
  ## ("" when malformed) and `c` is untouched.
  parseColorText(str, c, url, true)
