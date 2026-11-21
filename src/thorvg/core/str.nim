## C-locale string helpers of ThorVG: float parsing and path name utilities.
##
## Ported from `src/common/tvgStr.cpp`. Strings are Nim `string`s addressed by index;
## reading past the end yields `'\0'` (see `charAt`) like a C string terminator.
## `toFloat` keeps the exact (non strtod) algorithm of ThorVG, including its float32
## accumulation and its quirks (SVG `em` unit, `inf`/`nan`, trailing `e`).

import std/[strutils, math]

const NotSpaces = {'\0'..'\255'} - {' ', '\t', '\n', '\v', '\f', '\r'}

func charAt*(s: string, i: int): char {.inline.} =
  ## `s[i]`, or `'\0'` when `i` is outside the string (C terminator semantic).
  if i >= 0 and i < s.len: s[i] else: '\0'

func isCSpace*(c: char): bool {.inline.} =
  ## C-locale `isspace`.
  c notin NotSpaces

func isCDigit*(c: char): bool {.inline.} = c in {'0'..'9'}

func lower(c: char): char {.inline.} =
  if c in {'A'..'Z'}: char(ord(c) + 32) else: c

{.push floatChecks: off.}

func toFloat*(s: string, start: int, endPos: var int): float32 =
  ## Parses a number at `s[start..]`; `endPos` receives the index after the consumed text
  ## (`start` when nothing was parsed). Non-finite results become 0.
  ## Accepted: `[ws][sign]{digits[.digits]|.digits}[{e|E}[sign]digits]`, `inf`, `nan`.
  endPos = start
  var a = start
  var it = start
  var val = 0.0'f32
  var integerPart = 0'u64
  var minus = 1'i32
  while isCSpace(s.charAt(it)): inc it
  if s.charAt(it) == '-':
    minus = -1
    inc it
  elif s.charAt(it) == '+':
    inc it

  template finish() =
    endPos = a
    return (if val.classify in {fcNan, fcInf, fcNegInf}: 0.0'f32 else: float32(minus) * val)

  if lower(s.charAt(it)) == 'i':
    if lower(s.charAt(it + 1)) == 'n' and lower(s.charAt(it + 2)) == 'f': it += 3
    else: return 0.0'f32
    if lower(s.charAt(it)) == 'i':
      if lower(s.charAt(it + 1)) == 'n' and lower(s.charAt(it + 2)) == 'i' and
          lower(s.charAt(it + 3)) == 't' and lower(s.charAt(it + 4)) == 'y': it += 5
      else: return 0.0'f32
    endPos = it
    return float32(if minus == -1: -Inf else: Inf)
  if lower(s.charAt(it)) == 'n':
    if lower(s.charAt(it + 1)) == 'a' and lower(s.charAt(it + 2)) == 'n': it += 3
    else: return 0.0'f32
    endPos = it
    return (if minus == -1: float32(-NaN) else: float32(NaN))

  if isCDigit(s.charAt(it)):
    while isCDigit(s.charAt(it)):
      integerPart = integerPart * 10'u64 + uint64(ord(s[it]) - ord('0'))
      inc it
    a = it
  elif s.charAt(it) != '.':
    finish()

  val = float32(integerPart)

  if s.charAt(it) == '.':
    var decimalPart = 0'u64
    var pow10 = 1'u64
    var count = 0
    inc it
    if isCDigit(s.charAt(it)):
      while isCDigit(s.charAt(it)):
        if count < 19:
          decimalPart = decimalPart * 10'u64 + uint64(ord(s[it]) - ord('0'))
          pow10 *= 10'u64
        inc it
        inc count
    elif isCSpace(s.charAt(it)): # a space after the dot ends the number
      a = it
      finish()
    val += float32(decimalPart) / float32(pow10)
    a = it

  if s.charAt(it) in {'e', 'E'}:
    inc it
    if s.charAt(it) in {'m', 'M'}: # SVG `em` unit: the caller resolves the multiplier
      a = it + 1
      finish()
    var minusE = 1'i64
    if s.charAt(it) == '-':
      minusE = -1
      inc it
    elif s.charAt(it) == '+':
      inc it
    var exponentPart = 0'u32
    if isCDigit(s.charAt(it)):
      while s.charAt(it) == '0': inc it
      while isCDigit(s.charAt(it)):
        exponentPart = exponentPart * 10'u32 + uint32(ord(s[it]) - ord('0'))
        inc it
    elif not isCDigit(s.charAt(a - 1)):
      a = start
      finish()
    elif s.charAt(it) == '\0':
      finish()
    # `static_cast<int>(exponentPart)` wraps on 32 bits in the original.
    let signedExp =
      if exponentPart > 0x7fffffff'u32: int64(exponentPart) - 4294967296'i64
      else: int64(exponentPart)
    if val == 1.175494351'f32 and minusE * signedExp <= -38:
      val = val * 1.0e-38'f32
      a = it
      finish()
    a = it
    var scale = 1.0'f32
    while exponentPart >= 8'u32:
      scale = scale * 1.0e8'f32
      exponentPart -= 8'u32
    while exponentPart > 0'u32:
      scale = scale * 10.0'f32
      dec exponentPart
    val = if minusE == -1: val / scale else: val * scale
  elif it > start and not isCDigit(s.charAt(it - 1)):
    a = start
  finish()

{.pop.}

proc toFloat*(s: string): float32 =
  ## Parses a number at the start of `s` (see `toFloat(s, start, endPos)`).
  var e = 0
  toFloat(s, 0, e)

func strDuplicate*(s: string, max = high(int)): string =
  ## Copy of at most `max` characters of `s`.
  s[0 ..< min(max, s.len)]

func strAppend*(lhs, rhs: string, n: int): string =
  ## `lhs` followed by at most `n` characters of `rhs`.
  lhs & strDuplicate(rhs, n)

func strConcat*(a, b: string): string = a & b

func lastSeparator(path: string): int =
  ## Index of the last `/` or `\` (Windows build of the original), or -1.
  for i in countdown(path.high, 0):
    if path[i] in {'/', '\\'}: return i
  -1

func strDirname*(path: string): string =
  ## Directory part of `path`, including the trailing separator.
  let p = lastSeparator(path)
  if p < 0: path else: path[0 .. p]

func strFileExt*(path: string): string =
  ## Text after the last `.`; the whole `path` when it has no dot (as the original).
  let p = path.rfind('.')
  if p < 0: path else: path[p + 1 .. ^1]

func strFilename*(path: string): string =
  ## File name of `path` without its (last) extension.
  let base = path[lastSeparator(path) + 1 .. ^1]
  let dot = base.rfind('.')
  if dot >= 0: base[0 ..< dot] else: base
