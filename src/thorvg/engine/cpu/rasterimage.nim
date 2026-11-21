## Image rasterizers: direct (shifted only) blits.
##
## Ported from the "RLE Direct Image" and "Direct Image" sections of
## `src/renderer/cpu_engine/tvgSwRaster.cpp`. The scaled variants live in
## `rasterscale.nim` and are re-exported here.
##
## `rasterTexmapPolygon` (rotated and sheared images, tvgSwRasterTexmap.h) lives in
## `texmap.nim` / `texmappoly.nim` (PLAN L3) and is re-exported from here.
##
## Differences from C++: `image.buf32` is `image.surface.data`; the compositor image is
## read through `cmpAt`; the unsupported masked-image paths return false like the original.

import ../../core/types
import ../../renderer/render
import ./[common, pixel, blend, rastercore, rasterscale, texmappoly]

export rasterscale, texmappoly

proc srcAt(image: SwImage, x, y: int): int =
  ## Index in the image buffer of the source pixel under destination pixel (x, y).
  (y + int(image.oy)) * int(image.stride) + x + int(image.ox)

# ---- rle ----

proc directMattedRleImage(surface: SwSurface, image: SwImage, bbox: Region,
                          opacity: uint8): bool =
  let cimg = surface.compositor.image
  let getAlpha = surfaceAlpha(surface, surface.compositor.meth)
  let stride = int(surface.stride)
  forSpans(image.rle, bbox, span, x, n):
    let a = multiply(span.coverage, opacity)
    let img = srcAt(image, x, int(span.y))
    for i in 0 ..< n:
      let ca = getAlpha(cimg.cmpAt(int(span.y) * int(cimg.stride) + x + i))
      let tmp = alphaBlend(image.surface.data[img + i],
                           uint32(if a == 255: ca else: multiply(a, ca)))
      let d = int(span.y) * stride + x + i
      surface.data[d] = tmp + alphaBlend(surface.data[d], uint32(ialpha(tmp)))
  true

proc directBlendingRleImage(surface: SwSurface, image: SwImage, bbox: Region,
                            opacity: uint8): bool =
  let stride = int(surface.stride)
  forSpans(image.rle, bbox, span, x, n):
    let a = multiply(span.coverage, opacity)
    let img = srcAt(image, x, int(span.y))
    for i in 0 ..< n:
      let src = image.surface.data[img + i]
      let d = int(span.y) * stride + x + i
      let dst = surface.data[d]
      let b = surface.blender(surface, unpremultiply(src), dst)
      surface.data[d] = if a == 255: b else: interpolate(b, dst, multiply(a, alpha(src)))
  true

proc rasterDirectRleImage*(surface: SwSurface, image: SwImage, bbox: Region,
                           opacity: uint8): bool =
  ## Blits the spans of `image.rle` (clipped image) shifted by `image.ox/oy`.
  if surface.channelSize == 1: return false
  if compositing(surface):
    if matting(surface): directMattedRleImage(surface, image, bbox, opacity) else: false
  elif blending(surface): directBlendingRleImage(surface, image, bbox, opacity)
  else:
    let stride = int(surface.stride)
    forSpans(image.rle, bbox, span, x, n):
      rasterTranslucentPixels(surface.data, int(span.y) * stride + x, image.surface.data,
                              srcAt(image, x, int(span.y)), n,
                              multiply(span.coverage, opacity))
    true

# ---- direct image ----

proc directMattedImage(surface: SwSurface, image: SwImage, cmp: SwCompositor, bbox: Region,
                       w, h: int, opacity: uint8): bool =
  ## Matte composition (`blend`: also run the blender, used by the injecting fast track).
  let cimg = cmp.image
  let getAlpha = surfaceAlpha(surface, cmp.meth)
  let stride = int(surface.stride)
  for y in 0 ..< h:
    let py = int(bbox.yMin) + y
    let s0 = srcAt(image, int(bbox.xMin), py)
    let crow = py * int(cimg.stride) + int(bbox.xMin)
    let drow = py * stride + int(bbox.xMin)
    for x in 0 ..< w:
      let src = image.surface.data[s0 + x]
      let ca = getAlpha(cimg.cmpAt(crow + x))
      let ma = if opacity == 255: ca else: multiply(opacity, ca)
      if surface.channelSize == 1:
        let tmp = multiply(alpha(src), ma)
        surface.buf8[drow + x] = tmp + multiply(surface.buf8[drow + x], 255'u8 - tmp)
      else:
        let tmp = alphaBlend(src, uint32(ma))
        surface.data[drow + x] = tmp + alphaBlend(surface.data[drow + x], uint32(ialpha(tmp)))
  true

proc directMattedBlendingImage(surface: SwSurface, image: SwImage, cmp: SwCompositor,
                               bbox: Region, w, h: int, opacity: uint8): bool =
  if surface.channelSize == 1: return directMattedImage(surface, image, cmp, bbox, w, h, opacity)
  let cimg = cmp.image
  let getAlpha = surfaceAlpha(surface, cmp.meth)
  for y in 0 ..< h:
    let py = int(bbox.yMin) + y
    let s0 = srcAt(image, int(bbox.xMin), py)
    let crow = py * int(cimg.stride) + int(bbox.xMin)
    let drow = py * int(surface.stride) + int(bbox.xMin)
    for x in 0 ..< w:
      let src = image.surface.data[s0 + x]
      let ma = multiply(alpha(src), getAlpha(cimg.cmpAt(crow + x)))
      let d = surface.data[drow + x]
      surface.data[drow + x] = interpolate(surface.blender(surface, src, d), d,
                                           if opacity == 255: ma else: multiply(ma, opacity))
  true

proc directImage(surface: SwSurface, image: SwImage, bbox: Region, w, h: int,
                 opacity: uint8): bool =
  let stride = int(surface.stride)
  for y in 0 ..< h:
    let py = int(bbox.yMin) + y
    let s0 = srcAt(image, int(bbox.xMin), py)
    let drow = py * stride + int(bbox.xMin)
    if surface.channelSize == 4:
      if image.alphaIgnored:
        rasterSolidPixels(surface.data, drow, image.surface.data, s0, w, opacity)
      else: rasterTranslucentPixels(surface.data, drow, image.surface.data, s0, w, opacity)
    elif surface.channelSize == 1:
      for x in 0 ..< w:
        let src = image.surface.data[s0 + x]
        surface.buf8[drow + x] =
          if opacity == 255: alpha(src) + multiply(surface.buf8[drow + x], ialpha(src))
          else: interpolate8(alpha(src), surface.buf8[drow + x], opacity)
  true

proc injecting(cmp: SwCompositor): bool =
  ## Blending drawn into a matte compositor: mix both in one pass (fast track).
  if cmp == nil or cmp.recoverCmp == nil or cmp.recoverCmp.meth == MaskMethod.None: return false
  let sfc = cmp.recoverSfc
  sfc != nil and sfc.compositor != nil and matting(sfc) and not blending(sfc)

proc directBlendingImage(surface: SwSurface, image: SwImage, bbox: Region, w, h: int,
                         opacity: uint8): bool =
  if surface.channelSize == 1: return directImage(surface, image, bbox, w, h, opacity)
  if injecting(surface.compositor):
    return directMattedBlendingImage(surface, image, surface.compositor.recoverCmp, bbox, w, h,
                                     opacity)
  for y in 0 ..< h:
    let py = int(bbox.yMin) + y
    let s0 = srcAt(image, int(bbox.xMin), py)
    let drow = py * int(surface.stride) + int(bbox.xMin)
    for x in 0 ..< w:
      let src = image.surface.data[s0 + x]
      let d = surface.data[drow + x]
      surface.data[drow + x] = interpolate(surface.blender(surface, unpremultiply(src), d), d,
                                           if opacity == 255: alpha(src)
                                           else: multiply(opacity, alpha(src)))
  true

proc rasterDirectImage*(surface: SwSurface, image: SwImage, bbox: Region,
                        opacity: uint8): bool =
  ## Blits `image` shifted by `image.ox/oy` (no scaling) inside `bbox`.
  let w = int(min(bbox.xMax - bbox.xMin, int32(image.w) - (bbox.xMin + image.ox)))
  let h = int(min(bbox.yMax - bbox.yMin, int32(image.h) - (bbox.yMin + image.oy)))
  if w <= 0 or h <= 0: return true
  if compositing(surface):
    if matting(surface):
      if blending(surface):
        directMattedBlendingImage(surface, image, surface.compositor, bbox, w, h, opacity)
      else: directMattedImage(surface, image, surface.compositor, bbox, w, h, opacity)
    else: false
  elif blending(surface): directBlendingImage(surface, image, bbox, w, h, opacity)
  else: directImage(surface, image, bbox, w, h, opacity)
