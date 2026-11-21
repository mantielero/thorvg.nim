## Nim twin of `cpp_webp_dump_lossy.cpp` (same CLI and output format).
##
##   nim_webp_dump_lossy <in.webp> <out.bin> [rgba]

import std/os
import thorvg/loaders/image/webp/vp8
import ./webp_lossy_util

proc main() =
  if paramCount() < 2: quit(2)
  let data = payloadOf(readBytes(paramStr(1)))
  let bgra = not (paramCount() > 2 and paramStr(3) == "rgba")
  var w, h: int
  let px = if data.len > 0: decodeVp8(data, w, h, bgra = bgra) else: @[]
  var hdr = newString(8)
  var outp = newString(8 + px.len * 4)
  let wh = if px.len > 0: [w, h] else: [0, 0]
  for k in 0 ..< 2:
    for b in 0 ..< 4: outp[k * 4 + b] = char((wh[k] shr (8 * b)) and 0xff)
  for i, v in px:
    for b in 0 ..< 4: outp[8 + i * 4 + b] = char((v shr uint32(8 * b)) and 0xff'u32)
  hdr = outp
  writeFile(paramStr(2), hdr)

main()
