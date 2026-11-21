## Base64 decoding and the DJB2 string hash.
##
## Ported from `src/common/tvgCompressor.cpp`. The decoder is the lenient one of ThorVG:
## it accepts the URL-safe alphabet (`-` `_`), `,` as `/`, skips leading control/space bytes
## of each quad and stops at `=`, `.` or the end of the text.

func b64Value(c: char): int =
  ## Value of a Base64 digit; every unknown byte maps to 0 like the original table.
  case c
  of 'A'..'Z': ord(c) - ord('A')
  of 'a'..'z': ord(c) - ord('a') + 26
  of '0'..'9': ord(c) - ord('0') + 52
  of '+', '-', '.': 62
  of '/', ',', '_': 63
  else: 0

func at(s: string, i: int): char {.inline.} =
  if i < s.len: s[i] else: '\0'

func b64Decode*(encoded: string): string =
  ## Decodes `encoded`; returns "" for an empty input.
  var i = 0
  while encoded.at(i) != '\0' and encoded.at(i + 1) != '\0':
    if encoded[i] <= ' ' or encoded[i] >= '\x80': # `char` is signed in the original
      inc i
    else:
      let v1 = b64Value(encoded[i])
      let v2 = b64Value(encoded[i + 1])
      result.add char(((v1 shl 2) + ((v2 and 0x30) shr 4)) and 0xff)
      let c2 = encoded.at(i + 2)
      let c3 = encoded.at(i + 3)
      if c2 == '\0' or c3 >= '\x80' or c2 == '=' or c2 == '.': break
      let v3 = b64Value(c2)
      result.add char((((v2 and 0x0f) shl 4) + ((v3 and 0x3c) shr 2)) and 0xff)
      if c3 == '\0' or c3 == '=' or c3 == '.': break
      result.add char((((v3 and 0x03) shl 6) + b64Value(c3)) and 0xff)
      i += 4

func djb2Encode*(s: string): uint32 =
  ## DJB2 hash (`hash * 33 + c`) with 32-bit wrap-around (`unsigned long` on Windows).
  ## Bytes are signed like `char` in the original.
  result = 5381'u32
  for ch in s:
    if ch == '\0': break
    let c = ord(ch)
    let sc = if c >= 128: c - 256 else: c
    result = (result shl 5) + result + uint32(sc and 0xffffffff)
