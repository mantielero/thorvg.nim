## Helpers shared by the lossy WebP tests and the parity dump program: a minimal RIFF
## walker (the real container parser is the loader's job) and raw dump I/O.

import std/os

proc readBytes*(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

proc le32(f: openArray[byte], p: int): int =
  int(f[p]) or (int(f[p + 1]) shl 8) or (int(f[p + 2]) shl 16) or (int(f[p + 3]) shl 24)

proc vp8Payload*(f: openArray[byte]): int =
  ## Offset of the payload of the first 'VP8 ' chunk of a RIFF/WEBP file, or -1.
  if f.len < 12 or f[0] != byte('R') or f[8] != byte('W'): return -1
  var pos = 12
  while pos + 8 <= f.len:
    let sz = le32(f, pos + 4)
    if f[pos] == byte('V') and f[pos + 1] == byte('P') and f[pos + 2] == byte('8') and
        f[pos + 3] == byte(' '):
      return pos + 8
    let next = pos + 8 + sz + (sz and 1)
    if sz < 0 or next <= pos: return -1
    pos = next
  -1

proc payloadOf*(f: seq[byte]): seq[byte] =
  ## The bare VP8 bitstream handed to the decoder: payload start up to the end of `f`.
  let off = vp8Payload(f)
  if off < 0 or off > f.len: return @[]
  f[off .. ^1]

proc dirOf*(path: string): string = parentDir(path)
