## Forward VP8L transforms for the test encoder (`mkwebp_ll.nim`). Written from the WebP
## lossless bitstream specification, independently of the decoder in `src`.
## Pixels are ARGB words (`a shl 24 or r shl 16 or g shl 8 or b`).
import std/random

type
  Tf* = object        ## result of a forward transform
    pix*: seq[uint32]       ## transformed image
    width*: int             ## width of `pix`
    side*: seq[uint32]      ## predictor modes / multipliers / delta-coded palette
    bits*: int              ## tile bits (predictor, cross color) or pixel packing bits
    numColors*: int

proc rnd*(r: var Rand, n: int): int = r.rand(n - 1)

func subSample*(size, bits: int): int = (size + (1 shl bits) - 1) shr bits

func ch(p: uint32, shift: int): int = int((p shr uint32(shift)) and 0xff)

func mk(a, r, g, b: int): uint32 =
  (uint32(a and 0xff) shl 24) or (uint32(r and 0xff) shl 16) or
    (uint32(g and 0xff) shl 8) or uint32(b and 0xff)

func addPix(a, b: uint32): uint32 =
  mk(ch(a, 24) + ch(b, 24), ch(a, 16) + ch(b, 16), ch(a, 8) + ch(b, 8), ch(a, 0) + ch(b, 0))

func subPix(a, b: uint32): uint32 =
  mk(ch(a, 24) - ch(b, 24), ch(a, 16) - ch(b, 16), ch(a, 8) - ch(b, 8), ch(a, 0) - ch(b, 0))

func avg2(a, b: uint32): uint32 =
  mk((ch(a, 24) + ch(b, 24)) div 2, (ch(a, 16) + ch(b, 16)) div 2,
     (ch(a, 8) + ch(b, 8)) div 2, (ch(a, 0) + ch(b, 0)) div 2)

func sel(l, t, tl: uint32): uint32 =
  var pl, pt = 0
  for s in [24, 16, 8, 0]:
    let p = ch(l, s) + ch(t, s) - ch(tl, s)
    pl += abs(p - ch(l, s))
    pt += abs(p - ch(t, s))
  if pl < pt: l else: t

func clamp255(v: int): int = max(0, min(255, v))

func addSubFull(a, b, c: uint32): uint32 =
  mk(clamp255(ch(a, 24) + ch(b, 24) - ch(c, 24)), clamp255(ch(a, 16) + ch(b, 16) - ch(c, 16)),
     clamp255(ch(a, 8) + ch(b, 8) - ch(c, 8)), clamp255(ch(a, 0) + ch(b, 0) - ch(c, 0)))

func addSubHalf3(a, b, c: uint32): uint32 =
  let av = avg2(a, b)
  mk(clamp255(ch(av, 24) + (ch(av, 24) - ch(c, 24)) div 2),
     clamp255(ch(av, 16) + (ch(av, 16) - ch(c, 16)) div 2),
     clamp255(ch(av, 8) + (ch(av, 8) - ch(c, 8)) div 2),
     clamp255(ch(av, 0) + (ch(av, 0) - ch(c, 0)) div 2))

func predictPixel(mode: int, l, t, tr, tl: uint32): uint32 =
  case mode
  of 1: l
  of 2: t
  of 3: tr
  of 4: tl
  of 5: avg2(avg2(l, tr), t)
  of 6: avg2(l, tl)
  of 7: avg2(l, t)
  of 8: avg2(tl, t)
  of 9: avg2(t, tr)
  of 10: avg2(avg2(l, tl), avg2(t, tr))
  of 11: sel(l, t, tl)
  of 12: addSubFull(l, t, tl)
  of 13: addSubHalf3(l, t, tl)
  else: 0xff000000'u32

func subtractGreen*(pix: seq[uint32], w: int): Tf =
  result = Tf(width: w, pix: newSeq[uint32](pix.len))
  for i, p in pix:
    let g = ch(p, 8)
    result.pix[i] = mk(ch(p, 24), ch(p, 16) - g, g, ch(p, 0) - g)

proc predictor*(pix: seq[uint32], w, h, bits: int, r: var Rand): Tf =
  ## Random mode per tile; junk in the unused bits of the mode pixels.
  result = Tf(width: w, bits: bits, pix: newSeq[uint32](pix.len))
  let tw = subSample(w, bits)
  for ty in 0 ..< subSample(h, bits):
    for tx in 0 ..< tw:
      result.side.add mk(255, r.rnd(256), r.rnd(16) + 16 * r.rnd(16), r.rnd(256))
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      var pred = 0xff000000'u32
      if y == 0:
        if x > 0: pred = pix[i - 1]
      elif x == 0:
        pred = pix[i - w]
      else:
        let mode = int((result.side[(y shr bits) * tw + (x shr bits)] shr 8) and 0xf)
        pred = predictPixel(mode, pix[i - 1], pix[i - w], pix[i - w + 1], pix[i - w - 1])
      result.pix[i] = subPix(pix[i], pred)

func delta(t, c: int): int =
  let tt = if t >= 128: t - 256 else: t
  let cc = if c >= 128: c - 256 else: c
  (tt * cc) shr 5

proc crossColor*(pix: seq[uint32], w, h, bits: int, r: var Rand): Tf =
  result = Tf(width: w, bits: bits, pix: newSeq[uint32](pix.len))
  let tw = subSample(w, bits)
  for ty in 0 ..< subSample(h, bits):
    for tx in 0 ..< tw:
      result.side.add mk(255, r.rnd(256), r.rnd(256), r.rnd(256))   # r2b, g2b, g2r
  for y in 0 ..< h:
    for x in 0 ..< w:
      let m = result.side[(y shr bits) * tw + (x shr bits)]
      let p = pix[y * w + x]
      let g = ch(p, 8)
      result.pix[y * w + x] = mk(ch(p, 24), ch(p, 16) - delta(ch(m, 0), g), g,
        ch(p, 0) - delta(ch(m, 8), g) - delta(ch(m, 16), ch(p, 16)))

func palette*(pix: seq[uint32], w, h: int): Tf =
  ## Index the colors in order of first appearance; `side` is the delta-coded palette.
  var colors: seq[uint32]
  var index = newSeq[int](pix.len)
  for i, p in pix:
    var k = colors.find(p)
    if k < 0:
      k = colors.len
      colors.add p
    index[i] = k
  doAssert colors.len <= 256, "too many colors for a palette"
  result.numColors = colors.len
  result.bits = if colors.len > 16: 0 elif colors.len > 4: 1 elif colors.len > 2: 2 else: 3
  for i, c in colors:
    result.side.add(if i == 0: c else: subPix(c, colors[i - 1]))
  result.width = subSample(w, result.bits)
  result.pix = newSeq[uint32](result.width * h)
  let bpp = 8 shr result.bits
  for y in 0 ..< h:
    for x in 0 ..< w:
      let o = y * result.width + (x shr result.bits)
      let shift = (x and ((1 shl result.bits) - 1)) * bpp
      result.pix[o] = result.pix[o] or (uint32(index[y * w + x]) shl uint32(8 + shift))
  for o in 0 ..< result.pix.len: result.pix[o] = result.pix[o] or 0xff000000'u32
