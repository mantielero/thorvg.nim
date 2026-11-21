## Nim twin of `cpp_webp_dump_ll.cpp` (same CLI and output format) for lossless files: the
## bare VP8L payload (chunk start up to the end of the file) goes to `decodeVp8l`.
##
##   nim_webp_dump_ll <in.webp> <out.bin> [rgba]

import std/os
import thorvg/loaders/image/webp/vp8l

proc le32(f: string, p: int): int =
  int(f[p]) or (int(f[p + 1]) shl 8) or (int(f[p + 2]) shl 16) or (int(f[p + 3]) shl 24)

proc vp8lPayload(f: string): seq[byte] =
  ## Bytes from the first `VP8L` chunk payload to the end of the file.
  if f.len < 12: return
  var pos = 12
  while pos + 8 <= f.len:
    let sz = le32(f, pos + 4)
    if f[pos .. pos + 3] == "VP8L":
      for i in pos + 8 ..< f.len: result.add byte(f[i])
      return
    let next = pos + 8 + sz + (sz and 1)
    if sz < 0 or next <= pos: return
    pos = next

proc main() =
  if paramCount() < 2: quit(2)
  let data = vp8lPayload(readFile(paramStr(1)))
  let abgr = paramCount() > 2 and paramStr(3) == "rgba"
  var w, h = 0
  var hasAlpha = false
  let px = if data.len > 0: decodeVp8l(data, w, h, hasAlpha, abgr) else: @[]
  let wh = if px.len > 0: [w, h] else: [0, 0]
  var outp = newString(8 + px.len * 4)
  for k in 0 ..< 2:
    for b in 0 ..< 4: outp[k * 4 + b] = char((wh[k] shr (8 * b)) and 0xff)
  for i, v in px:
    for b in 0 ..< 4: outp[8 + i * 4 + b] = char((v shr uint32(8 * b)) and 0xff'u32)
  writeFile(paramStr(2), outp)

main()
