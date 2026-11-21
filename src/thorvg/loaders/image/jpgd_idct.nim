## Inverse DCT and YCbCr -> RGB conversion of jpgd (integer arithmetic of `tvgJpgd.cpp`).
##
## Upstream picks specialised row/column passes depending on how many coefficients are
## non-zero. Those are algebraically identical to the full pass (the missing inputs are
## exact zeros), so a single full implementation is used here: same bytes out.
## Chroma upsampling is a plain replication of each chroma sample (no filtering).

import ./jpgd_bits

const
  ConstBits = 13
  Pass1Bits = 2
  Fix0298631336 = 2446
  Fix0390180644 = 3196
  Fix0541196100 = 4433
  Fix0765366865 = 6270
  Fix0899976223 = 7373
  Fix1175875602 = 9633
  Fix1501321110 = 12299
  Fix1847759065 = 15137
  Fix1961570560 = 16069
  Fix2053119869 = 16819
  Fix2562915447 = 20995
  Fix3072711026 = 25172

const Zag* = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
  41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30,
  37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]

func clamp*(i: int): uint8 =
  ## 0..255 saturation (jpgd `clamp`).
  if i < 0: 0'u8 elif i > 255: 255'u8 else: uint8(i)

func descale(x, n: int): int = (x + (1 shl (n - 1))) shr n

func descaleZeroShift(x, n: int): int = (x + (128 shl n) + (1 shl (n - 1))) shr n

func idct1d(v: array[8, int]): array[8, int] =
  ## The shared 1-D butterfly; results are not yet descaled.
  let z2 = v[2]
  let z3 = v[6]
  let z1 = (z2 + z3) * Fix0541196100
  let tmp2 = z1 + z3 * -Fix1847759065
  let tmp3 = z1 + z2 * Fix0765366865
  let tmp0 = (v[0] + v[4]) * (1 shl ConstBits)
  let tmp1 = (v[0] - v[4]) * (1 shl ConstBits)
  let tmp10 = tmp0 + tmp3
  let tmp13 = tmp0 - tmp3
  let tmp11 = tmp1 + tmp2
  let tmp12 = tmp1 - tmp2
  let atmp0 = v[7]
  let atmp1 = v[5]
  let atmp2 = v[3]
  let atmp3 = v[1]
  let bz1 = atmp0 + atmp3
  let bz2 = atmp1 + atmp2
  let bz3 = atmp0 + atmp2
  let bz4 = atmp1 + atmp3
  let bz5 = (bz3 + bz4) * Fix1175875602
  let az1 = bz1 * -Fix0899976223
  let az2 = bz2 * -Fix2562915447
  let az3 = bz3 * -Fix1961570560 + bz5
  let az4 = bz4 * -Fix0390180644 + bz5
  let btmp0 = atmp0 * Fix0298631336 + az1 + az3
  let btmp1 = atmp1 * Fix2053119869 + az2 + az4
  let btmp2 = atmp2 * Fix3072711026 + az2 + az3
  let btmp3 = atmp3 * Fix1501321110 + az1 + az4
  [tmp10 + btmp3, tmp11 + btmp2, tmp12 + btmp1, tmp13 + btmp0,
   tmp13 - btmp0, tmp12 - btmp1, tmp11 - btmp2, tmp10 - btmp3]

proc idct*(src: seq[int16], srcOfs: int, dst: var seq[uint8], dstOfs: int) =
  ## Dequantised 8x8 block -> 64 samples (row-major) at `dst[dstOfs ..]`.
  var temp: array[64, int]
  for row in 0 ..< 8:
    var v: array[8, int]
    for x in 0 ..< 8: v[x] = int(src[srcOfs + row * 8 + x])
    let r = idct1d(v)
    for x in 0 ..< 8: temp[row * 8 + x] = descale(r[x], ConstBits - Pass1Bits)
  for col in 0 ..< 8:
    var v: array[8, int]
    for y in 0 ..< 8: v[y] = temp[y * 8 + col]
    let r = idct1d(v)
    for y in 0 ..< 8:
      dst[dstOfs + y * 8 + col] = clamp(descaleZeroShift(r[y], ConstBits + Pass1Bits + 3))

proc createLookUps*(d: JpegDecoder) =
  ## YCbCr -> RGB tables (FIX() is evaluated in float32 like the C++ macro).
  const
    ScaleBits = 16
    OneHalf = 1 shl (ScaleBits - 1)
  func fix(x: float32): int = int(x * float32(1 shl ScaleBits) + 0.5'f32)
  for i in 0 .. 255:
    let k = i - 128
    d.crr[i] = (fix(1.40200'f32) * k + OneHalf) shr ScaleBits
    d.cbb[i] = (fix(1.77200'f32) * k + OneHalf) shr ScaleBits
    d.crg[i] = (-fix(0.71414'f32)) * k
    d.cbg[i] = (-fix(0.34414'f32)) * k + OneHalf

proc putPixel(d: JpegDecoder, line: var seq[uint8], o, y, cb, cr: int) =
  line[o] = clamp(y + d.crr[cr])
  line[o + 1] = clamp(y + ((d.crg[cr] + d.cbg[cb]) shr 16))
  line[o + 2] = clamp(y + d.cbb[cb])
  line[o + 3] = 255'u8

proc convertRow*(d: JpegDecoder) =
  ## Converts one pixel row of the current MCU row into `scanLine0` (and `scanLine1`
  ## for the vertically subsampled layouts, which fill two rows at once).
  let row = d.maxMcuY - d.mcuLinesLeft
  template s: untyped = d.sampleBuf
  var o = 0
  case d.scanType
  of Yh1v1:
    var base = row * 8
    for _ in 0 ..< d.maxMcusPerRow:
      for j in 0 ..< 8:
        d.putPixel(d.scanLine0, o, int(s[base + j]), int(s[base + 64 + j]),
                   int(s[base + 128 + j]))
        o += 4
      base += 64 * 3
  of Yh2v1:
    var y = row * 8
    var c = 2 * 64 + row * 8
    for _ in 0 ..< d.maxMcusPerRow:
      for _ in 0 ..< 2:
        for j in 0 ..< 4:
          let cb = int(s[c])
          let cr = int(s[c + 64])
          d.putPixel(d.scanLine0, o, int(s[y + (j shl 1)]), cb, cr)
          d.putPixel(d.scanLine0, o + 4, int(s[y + (j shl 1) + 1]), cb, cr)
          o += 8
          inc c
        y += 64
      y += 64 * 4 - 64 * 2
      c += 64 * 4 - 8
  of Yh1v2:
    var y = if row < 8: row * 8 else: 64 + (row and 7) * 8
    var c = 64 * 2 + (row shr 1) * 8
    for _ in 0 ..< d.maxMcusPerRow:
      for j in 0 ..< 8:
        let cb = int(s[c + j])
        let cr = int(s[c + 64 + j])
        d.putPixel(d.scanLine0, o, int(s[y + j]), cb, cr)
        d.putPixel(d.scanLine1, o, int(s[y + 8 + j]), cb, cr)
        o += 4
      y += 64 * 4
      c += 64 * 4
  of Yh2v2:
    var y = if row < 8: row * 8 else: 64 * 2 + (row and 7) * 8
    var c = 64 * 4 + (row shr 1) * 8
    for _ in 0 ..< d.maxMcusPerRow:
      for _ in 0 ..< 2:
        for j in countup(0, 6, 2):
          let cb = int(s[c])
          let cr = int(s[c + 64])
          d.putPixel(d.scanLine0, o, int(s[y + j]), cb, cr)
          d.putPixel(d.scanLine0, o + 4, int(s[y + j + 1]), cb, cr)
          d.putPixel(d.scanLine1, o, int(s[y + j + 8]), cb, cr)
          d.putPixel(d.scanLine1, o + 4, int(s[y + j + 8 + 1]), cb, cr)
          o += 8
          inc c
        y += 64
      y += 64 * 6 - 64 * 2
      c += 64 * 6 - 8
  of Grayscale: discard
