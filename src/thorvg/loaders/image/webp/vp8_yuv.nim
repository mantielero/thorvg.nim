## YUV 4:2:0 to premultiplied RGBA/BGRA words.
##
## Ported from `src/modules/webp/static/dsp/yuv.h` (non-table version, 14-bit fixed point),
## `dec/io.cpp` (`EmitSampledRGB`, point-sampled chroma) and `dsp/alpha_processing.cpp`
## (`ApplyAlphaMultiply`). The stripped ThorVG decoder has no fancy upsampling, so the
## chroma sample of pixel (x, y) is simply `u[y / 2][x / 2]`.

import ./vp8_types

const
  YScale = 19077
  VToR = 26149
  UToG = 6419
  VToG = 13320
  UToB = 33050
  RCst = -YScale * 16 - VToR * 128 + (1 shl 13)
  GCst = -YScale * 16 + UToG * 128 + VToG * 128 + (1 shl 13)
  BCst = -YScale * 16 - UToB * 128 + (1 shl 13)
  YuvMask2 = (256 shl 14) - 1

func clip8(v: int): uint32 {.inline.} =
  if (v and not YuvMask2) == 0: uint32(v shr 14)
  elif v < 0: 0'u32
  else: 255'u32

func premultiply(c, a: uint32): uint32 {.inline.} =
  ## `PREMULTIPLY(c, MULTIPLIER(a))`: (int)(c * a / 255.)
  (c * (a * 32897'u32)) shr 23

proc toPixels*(dec: Vp8Decoder, width, height: int, alpha: openArray[byte],
               bgra: bool): seq[uint32] =
  ## Converts the decoded planes to `width * height` words. Byte order in memory is
  ## R, G, B, A (`bgra == false`, word = R | G << 8 | B << 16 | A << 24) or B, G, R, A.
  ## `alpha`, when not empty, holds one byte per pixel and the colors get premultiplied.
  result = newSeq[uint32](width * height)
  let hasAlpha = alpha.len > 0
  for y in 0 ..< height:
    let yRow = y * dec.yStride
    let uvRow = (y shr 1) * dec.uvStride
    for x in 0 ..< width:
      let yy = YScale * int(dec.yPlane[yRow + x])
      let u = int(dec.uPlane[uvRow + (x shr 1)])
      let v = int(dec.vPlane[uvRow + (x shr 1)])
      var r = clip8(yy + VToR * v + RCst)
      var g = clip8(yy - UToG * u - VToG * v + GCst)
      var b = clip8(yy + UToB * u + BCst)
      var a = 255'u32
      if hasAlpha:
        a = uint32(alpha[y * width + x])
        if a != 255:
          r = premultiply(r, a)
          g = premultiply(g, a)
          b = premultiply(b, a)
      result[y * width + x] =
        if bgra: b or (g shl 8) or (r shl 16) or (a shl 24)
        else: r or (g shl 8) or (b shl 16) or (a shl 24)
