## VP8L inverse transforms and color conversion (dsp/lossless.cpp/.h, scalar C paths).
##
## Upstream applies the inverse transforms in 16-row blocks; here each transform runs once on
## the whole image (same result: every transform is a deterministic function of the already
## reconstructed pixels). Pixels are ARGB words (`a shl 24 or r shl 16 or g shl 8 or b`).
## `convertFromBgra` is `VP8LConvertFromBGRA` for the premultiplied modes ThorVG requests
## (`MODE_bgrA` = ARGB word, `MODE_rgbA` = ABGR word) including `WebPApplyAlphaMultiply`.

type
  TransformKind* = enum
    tkPredictor, tkCrossColor, tkSubtractGreen, tkColorIndexing

  Vp8lTransform* = object
    kind*: TransformKind
    bits*: int            ## subsampling bits of the transform window
    xsize*, ysize*: int   ## image size the transform was read for
    data*: seq[uint32]    ## predictor modes / color multipliers / palette

const ArgbBlack = 0xff000000'u32

func subSampleSize*(size, bits: int): int {.inline.} =
  (size + (1 shl bits) - 1) shr bits

func addPixels*(a, b: uint32): uint32 {.inline.} =
  let ag = (a and 0xff00ff00'u32) + (b and 0xff00ff00'u32)
  let rb = (a and 0x00ff00ff'u32) + (b and 0x00ff00ff'u32)
  (ag and 0xff00ff00'u32) or (rb and 0x00ff00ff'u32)

func average2(a0, a1: uint32): uint32 {.inline.} =
  (((a0 xor a1) and 0xfefefefe'u32) shr 1) + (a0 and a1)

func clip255(a: int): int {.inline.} = clamp(a, 0, 255)

func comp(c: uint32, shift: int): int {.inline.} = int((c shr uint32(shift)) and 0xff)

func clampedAddSubtractFull(c0, c1, c2: uint32): uint32 =
  var r = 0'u32
  for shift in [24, 16, 8, 0]:
    r = (r shl 8) or uint32(clip255(comp(c0, shift) + comp(c1, shift) - comp(c2, shift)))
  r

func clampedAddSubtractHalf(c0, c1, c2: uint32): uint32 =
  let ave = average2(c0, c1)
  var r = 0'u32
  for shift in [24, 16, 8, 0]:
    let a = comp(ave, shift)
    r = (r shl 8) or uint32(clip255(a + (a - comp(c2, shift)) div 2))
  r

func select(a, b, c: uint32): uint32 =
  var paMinusPb = 0
  for shift in [24, 16, 8, 0]:
    let pb = comp(b, shift) - comp(c, shift)
    let pa = comp(a, shift) - comp(c, shift)
    paMinusPb += abs(pb) - abs(pa)
  if paMinusPb <= 0: a else: b

func predict(mode: int, left: uint32, d: openArray[uint32], top: int): uint32 {.inline.} =
  ## Predictors 0-13 (14 and 15 are padding aliases of predictor 0). `top` indexes the pixel
  ## above the current one (`top[0]`); `top[-1]` / `top[1]` are its neighbours.
  case mode
  of 1: left
  of 2: d[top]
  of 3: d[top + 1]
  of 4: d[top - 1]
  of 5: average2(average2(left, d[top + 1]), d[top])
  of 6: average2(left, d[top - 1])
  of 7: average2(left, d[top])
  of 8: average2(d[top - 1], d[top])
  of 9: average2(d[top], d[top + 1])
  of 10: average2(average2(left, d[top - 1]), average2(d[top], d[top + 1]))
  of 11: select(d[top], left, d[top - 1])
  of 12: clampedAddSubtractFull(left, d[top], d[top - 1])
  of 13: clampedAddSubtractHalf(left, d[top], d[top - 1])
  else: ArgbBlack

func predictorInverse(t: Vp8lTransform, data: var seq[uint32], height: int) =
  let w = t.xsize
  data[0] = addPixels(data[0], ArgbBlack)     # first row follows mode 1 (L), first pixel black
  for x in 1 ..< w: data[x] = addPixels(data[x], data[x - 1])
  let tilesPerRow = subSampleSize(w, t.bits)
  for y in 1 ..< height:
    let base = y * w
    let modes = (y shr t.bits) * tilesPerRow
    data[base] = addPixels(data[base], data[base - w])     # first column follows T
    for x in 1 ..< w:
      let mode = int((t.data[modes + (x shr t.bits)] shr 8) and 0xf)
      data[base + x] = addPixels(data[base + x],
                                 predict(mode, data[base + x - 1], data, base + x - w))

func addGreenToBlueAndRed(data: var seq[uint32], numPixels: int) =
  for i in 0 ..< numPixels:
    let argb = data[i]
    let green = (argb shr 8) and 0xff
    let rb = ((argb and 0x00ff00ff'u32) + ((green shl 16) or green)) and 0x00ff00ff'u32
    data[i] = (argb and 0xff00ff00'u32) or rb

func s8(x: uint32): int {.inline.} =
  ## C `int8_t` conversion of the low byte.
  let b = int(x and 0xff)
  if b >= 128: b - 256 else: b

func colorDelta(pred, color: int): uint32 {.inline.} =
  uint32((pred * color) and 0xFFFFFFFF) shr 5

func crossColorInverse(t: Vp8lTransform, data: var seq[uint32], height: int) =
  let w = t.xsize
  let tilesPerRow = subSampleSize(w, t.bits)
  for y in 0 ..< height:
    for x in 0 ..< w:
      let code = t.data[(y shr t.bits) * tilesPerRow + (x shr t.bits)]
      let greenToRed = s8(code)
      let greenToBlue = s8(code shr 8)
      let redToBlue = s8(code shr 16)
      let argb = data[y * w + x]
      let green = s8(argb shr 8)
      let newRed = ((argb shr 16) + colorDelta(greenToRed, green)) and 0xff
      let newBlue = (argb + colorDelta(greenToBlue, green) +
                     colorDelta(redToBlue, s8(newRed))) and 0xff
      data[y * w + x] = (argb and 0xff00ff00'u32) or (newRed shl 16) or newBlue

func colorIndexInverse*(t: Vp8lTransform, src: seq[uint32], height: int): seq[uint32] =
  ## Unpacks pixel bundles and maps indices (green channel) through the palette; the source
  ## has `subSampleSize(xsize, bits)` words per row.
  let w = t.xsize
  result = newSeq[uint32](w * height)
  let bpp = 8 shr t.bits
  let mask = (1'u32 shl uint32(bpp)) - 1
  let ppbMask = (1 shl t.bits) - 1
  var si = 0
  var di = 0
  for y in 0 ..< height:
    var packed = 0'u32
    for x in 0 ..< w:
      if bpp < 8:
        if (x and ppbMask) == 0:
          packed = (src[si] shr 8) and 0xff
          inc si
        result[di] = t.data[int(packed and mask)]
        packed = packed shr uint32(bpp)
      else:
        result[di] = t.data[int((src[si] shr 8) and 0xff)]
        inc si
      inc di

func colorIndexInverseAlpha*(t: Vp8lTransform, src: seq[byte], height: int): seq[byte] =
  ## `VP8LColorIndexInverseTransformAlpha`: same on byte indices, keeps the green channel.
  let w = t.xsize
  result = newSeq[byte](w * height)
  let bpp = 8 shr t.bits
  let mask = (1'u32 shl uint32(bpp)) - 1
  let ppbMask = (1 shl t.bits) - 1
  var si = 0
  var di = 0
  for y in 0 ..< height:
    var packed = 0'u32
    for x in 0 ..< w:
      if bpp < 8:
        if (x and ppbMask) == 0:
          packed = uint32(src[si])
          inc si
        result[di] = byte((t.data[int(packed and mask)] shr 8) and 0xff)
        packed = packed shr uint32(bpp)
      else:
        result[di] = byte((t.data[int(src[si])] shr 8) and 0xff)
        inc si
      inc di

func inverseTransform*(t: Vp8lTransform, data: var seq[uint32], height: int) =
  ## In-place inverse for predictor / cross-color / subtract-green. The color indexing
  ## transform changes the row width: use `colorIndexInverse`.
  case t.kind
  of tkSubtractGreen: addGreenToBlueAndRed(data, t.xsize * height)
  of tkPredictor: predictorInverse(t, data, height)
  of tkCrossColor: crossColorInverse(t, data, height)
  of tkColorIndexing: discard

func convertFromBgra*(data: var seq[uint32], abgr: bool) =
  ## Premultiplies like `WebPApplyAlphaMultiply` (alpha 0xff untouched, otherwise
  ## `(x * a * 32897) shr 23`); `abgr` swaps red and blue (bytes R,G,B,A in memory).
  for i in 0 ..< data.len:
    var argb = data[i]
    let a = argb shr 24
    if a != 0xff:
      let m = a * 32897'u32
      let r = (((argb shr 16) and 0xff) * m) shr 23
      let g = (((argb shr 8) and 0xff) * m) shr 23
      let b = ((argb and 0xff) * m) shr 23
      argb = (a shl 24) or (r shl 16) or (g shl 8) or b
    if abgr:
      argb = (argb and 0xff00ff00'u32) or ((argb shr 16) and 0xff) or ((argb and 0xff) shl 16)
    data[i] = argb
