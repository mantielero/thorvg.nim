## Uniformly scaled image rasterizers (`rasterScaledImage`, `rasterScaledRleImage`).
##
## Ported from the "Image Sampling" and "Scaled Image" sections of
## `src/renderer/cpu_engine/tvgSwRaster.cpp`. The destination pixel is mapped back to the
## source with the inverse transform (only its scale/translate terms are used) and
## sampled by nearest, bilinear (up-scaling) or box filter (down-scaling, scale < 0.5).
## `ImageScaleFilter` function pointers became the `ScaleKind` enum.
## Masked (non matte) compositions and 8-bit matted/blended targets are unsupported
## in the C++ too and return false.
##
## Float math is `float32` like the original; float -> unsigned casts follow gcc/x86
## (`toU32`); `floatChecks` are off because `0.5f / scale` may divide by zero (H2).

import ../../core/[types, geom]
import ../../renderer/render
import ./[hot, common, pixel, blend, rastercore]

{.push floatChecks: off.}

type ScaleKind = enum
  skNearest, skUp, skDown

func toU32(f: float32): uint32 =
  ## C `(uint32_t)f`: truncation; NaN and huge values never trap.
  if f > -9.0e18'f32 and f < 9.0e18'f32: uint32(int64(f) and 0xffffffff'i64) else: 0'u32

func sampleSize(scale: float32): int =
  let s = toU32(0.5'f32 / scale)
  if s == 0: 1 else: int(s)

func scaleKind(image: SwImage): ScaleKind =
  if image.filter == FilterMethod.Bilinear:
    (if image.scale < 0.5'f32: skDown else: skUp)
  else: skNearest

func interpUp(image: SwImage, sx, sy: float32): uint32 =
  let img {.cursor.} = image.surface.data
  let stride = int(image.stride)
  let rx = int(toU32(sx))
  let ry = int(toU32(sy))
  let rx2 = min(rx + 1, int(image.w) - 1)
  let ry2 = min(ry + 1, int(image.h) - 1)
  let dx = if sx > 0.0'f32: uint8((sx - float32(rx)) * 255.0'f32) else: 0'u8
  let dy = if sy > 0.0'f32: uint8((sy - float32(ry)) * 255.0'f32) else: 0'u8
  let c1 = img[rx + ry * stride]
  let c2 = img[rx2 + ry * stride]
  let c3 = img[rx + ry2 * stride]
  let c4 = img[rx2 + ry2 * stride]
  interpolate(interpolate(c4, c3, dx), interpolate(c2, c1, dx), dy)

func sample(kind: ScaleKind, image: SwImage, sx, sy: float32, miny, maxy, n: int): uint32 {.noRaiseHot.} =
  case kind
  of skNearest: image.surface.data[int(toU32(sx)) + int(toU32(sy)) * int(image.stride)]
  of skUp: interpUp(image, sx, sy)
  of skDown: rasterDownScaler(image.surface.data, int(image.stride), int(image.w), sx, miny,
                              maxy, n)

type Rows = object
  ## Source row of a destination row (`SCALED_IMAGE_RANGE_Y`).
  sy: float32
  miny, maxy: int

func rowRange(image: SwImage, kind: ScaleKind, m: Matrix, y, ss: int, r: var Rows): bool =
  r.sy = float32(y) * m.e22 + m.e23 - 0.49'f32
  result = not (r.sy <= -0.5'f32 or toU32(r.sy + 0.5'f32) >= image.h)
  if result and kind == skDown:
    let my = int(int32(nearbyint(r.sy)))
    r.miny = max(my - ss, 0)
    r.maxy = min(my + ss, int(image.h))

func colRange(image: SwImage, m: Matrix, x: int, sx: var float32): bool =
  ## `SCALED_IMAGE_RANGE_X`.
  sx = float32(x) * m.e11 + m.e13 - 0.49'f32
  not (sx <= -0.5'f32 or toU32(sx + 0.5'f32) >= image.w)

func srcOver(dst, src: uint32): uint32 = src + alphaBlend(dst, uint32(ialpha(src)))

# One destination pixel. `a` is the extra opacity applied to the sampled color.
proc plainPixel(dst, src: uint32, a: uint8, ignored: bool): uint32 =
  if ignored: (if a == 255: src else: interpolate(src, dst, a))
  elif a == 255: srcOver(dst, src)
  else: srcOver(dst, alphaBlend(src, uint32(a)))

proc scaledImage(surface: SwSurface, image: SwImage, m: Matrix, bbox: Region,
                 opacity: uint8): bool =
  let kind = scaleKind(image)
  let ss = sampleSize(image.scale)
  let stride = int(surface.stride)
  let cmp = surface.compositor
  let blend = blending(surface)
  let matte = compositing(surface) and matting(surface)
  let cimg = if matte: cmp.image else: nil
  let getAlpha = if matte: surfaceAlpha(surface, cmp.meth) else: nil
  if compositing(surface) and not matte: return false
  if (matte or blend) and surface.channelSize != 4: return false
  var r: Rows
  for y in int(bbox.yMin) ..< int(bbox.yMax):
    if rowRange(image, kind, m, y, ss, r):
      for x in int(bbox.xMin) ..< int(bbox.xMax):
        var sx: float32
        if colRange(image, m, x, sx):
          let src = sample(kind, image, sx, r.sy, r.miny, r.maxy, ss)
          let i = y * stride + x
          if surface.channelSize == 1: surface.buf8[i] = multiply(alpha(src), opacity)
          elif matte:
            let ca = getAlpha(cimg.cmpAt(y * int(cimg.stride) + x))
            let tmp = alphaBlend(src, uint32(if opacity == 255: ca else: multiply(opacity, ca)))
            surface.data[i] = srcOver(surface.data[i], tmp)
          elif blend:
            let d = surface.data[i]
            surface.data[i] = interpolate(surface.blender(surface, unpremultiply(src), d), d,
                                          multiply(opacity, alpha(src)))
          else: surface.data[i] = plainPixel(surface.data[i], src, opacity, image.alphaIgnored)
  true

proc scaledRleImage(surface: SwSurface, image: SwImage, m: Matrix, opacity: uint8): bool =
  let kind = scaleKind(image)
  let ss = sampleSize(image.scale)
  let stride = int(surface.stride)
  let cmp = surface.compositor
  let blend = blending(surface)
  let matte = compositing(surface) and matting(surface)
  let cimg = if matte: cmp.image else: nil
  let getAlpha = if matte: surfaceAlpha(surface, cmp.meth) else: nil
  if compositing(surface) and not matte: return false
  if (matte or blend) and surface.channelSize != 4: return false
  var r: Rows
  if image.rle != nil:
    for span in image.rle.spans:
      if rowRange(image, kind, m, int(span.y), ss, r):
        let a = multiply(span.coverage, opacity)
        for x in int(span.x) ..< int(span.x) + int(span.len):
          var sx: float32
          if colRange(image, m, x, sx):
            let src = sample(kind, image, sx, r.sy, r.miny, r.maxy, ss)
            let i = int(span.y) * stride + x
            if surface.channelSize == 1: surface.buf8[i] = multiply(alpha(src), a)
            elif matte:
              let ca = getAlpha(cimg.cmpAt(int(span.y) * int(cimg.stride) + x))
              let s = alphaBlend(src, uint32(if a == 255: ca else: multiply(ca, a)))
              surface.data[i] = srcOver(surface.data[i], s)
            elif blend:
              let d = surface.data[i]
              let b = surface.blender(surface, unpremultiply(src), d)
              surface.data[i] = interpolate(b, d, if a == 255: alpha(src)
                                                  else: multiply(a, alpha(src)))
            else:
              let s = if a < 255: alphaBlend(src, uint32(a)) else: src
              surface.data[i] = srcOver(surface.data[i], s)
  true

proc rasterScaledImage*(surface: SwSurface, image: SwImage, transform: Matrix, bbox: Region,
                        opacity: uint8): bool =
  ## Draws `image` scaled by `transform` (no rotation) inside `bbox`.
  var m: Matrix
  if not inverse(transform, m): true else: scaledImage(surface, image, m, bbox, opacity)

proc rasterScaledRleImage*(surface: SwSurface, image: SwImage, transform: Matrix, bbox: Region,
                           opacity: uint8): bool =
  ## Like `rasterScaledImage` but limited to the spans of `image.rle` (clipped images).
  var m: Matrix
  if not inverse(transform, m): true else: scaledRleImage(surface, image, m, opacity)

{.pop.}
