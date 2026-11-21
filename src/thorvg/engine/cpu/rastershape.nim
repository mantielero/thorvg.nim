## Solid-color rasterizers (rectangles and RLE spans) of the CPU engine.
##
## Ported from the "Rect" and "Rle" sections of `src/renderer/cpu_engine/tvgSwRaster.cpp`
## plus `rasterShape` / `rasterStroke`. Every path of the C++ dispatch is kept:
## masking (8-bit compositor, `maskOp`), matting (alpha/luma compositor), custom
## blending (`surface.blender`), opaque fast path and translucent path.
## The compositor pixels are read through `compositor.image.surface` (see `cmpAt`).

import ../../core/[types, geom]
import ../../renderer/render
import ./[common, pixel, blend, rastercore]

proc compositeMaskImage*(surface: SwSurface, image: SwImage, bbox: Region): bool =
  ## Merges the compositor mask `image` into the 8-bit target (C++ `_compositeMaskImage`).
  let dstride = int(surface.stride)
  let sstride = int(image.stride)
  for y in int(bbox.yMin) ..< int(bbox.yMax):
    let drow = y * dstride
    let srow = (y + int(image.oy)) * sstride + int(image.ox)
    for x in int(bbox.xMin) ..< int(bbox.xMax):
      let s = image.surface.buf8[srow + x]
      surface.buf8[drow + x] = s + multiply(surface.buf8[drow + x], not s)
  true

# ---- rect ----

proc maskedRect(surface: SwSurface, bbox: Region, c: RGBA): bool =
  if surface.channelSize != 1: return false
  let cmp = surface.compositor
  let maskOp = getMaskOp(cmp.meth)
  let cimg = cmp.image
  let w = max(int(bbox.sw), 0)
  let h = max(int(bbox.sh), 0)
  if maskDirect(cmp.meth):
    for y in 0 ..< h:
      let crow = (int(bbox.yMin) + y) * int(cimg.stride) + int(bbox.xMin)
      let drow = (int(bbox.yMin) + y) * int(surface.stride) + int(bbox.xMin)
      for x in 0 ..< w:
        let tmp = maskOp(c.a, cimg.surface.buf8[crow + x], 0)
        surface.buf8[drow + x] = tmp + multiply(surface.buf8[drow + x], not tmp)
    true
  else:
    for y in 0 ..< h:
      let crow = (int(bbox.yMin) + y) * int(cimg.stride) + int(bbox.xMin)
      for x in 0 ..< w:
        cimg.surface.buf8[crow + x] = maskOp(c.a, cimg.surface.buf8[crow + x], 255'u8 - c.a)
    compositeMaskImage(surface, cimg, cmp.bbox)

proc mattedRect(surface: SwSurface, bbox: Region, c: RGBA): bool =
  let cimg = surface.compositor.image
  let getAlpha = surfaceAlpha(surface, surface.compositor.meth)
  let w = max(int(bbox.sw), 0)
  let h = max(int(bbox.sh), 0)
  if surface.channelSize == 4:
    let color = surface.join(c.r, c.g, c.b, c.a)
    for y in 0 ..< h:
      let drow = (int(bbox.yMin) + y) * int(surface.stride) + int(bbox.xMin)
      let crow = (int(bbox.yMin) + y) * int(cimg.stride) + int(bbox.xMin)
      for x in 0 ..< w:
        let tmp = alphaBlend(color, uint32(getAlpha(cimg.cmpAt(crow + x))))
        surface.data[drow + x] = tmp + alphaBlend(surface.data[drow + x], uint32(ialpha(tmp)))
  elif surface.channelSize == 1:
    for y in 0 ..< h:
      let drow = (int(bbox.yMin) + y) * int(surface.stride) + int(bbox.xMin)
      let crow = (int(bbox.yMin) + y) * int(cimg.stride) + int(bbox.xMin)
      for x in 0 ..< w:
        surface.buf8[drow + x] =
          interpolate8(c.a, surface.buf8[drow + x], getAlpha(cimg.cmpAt(crow + x)))
  true

proc blendingRect(surface: SwSurface, bbox: Region, c: RGBA): bool =
  if surface.channelSize != 4: return false
  let color = surface.join(c.r, c.g, c.b, c.a)
  for y in 0 ..< max(int(bbox.sh), 0):
    let row = (int(bbox.yMin) + y) * int(surface.stride) + int(bbox.xMin)
    for x in 0 ..< max(int(bbox.sw), 0):
      surface.data[row + x] = surface.blender(surface, color, surface.data[row + x])
  true

proc solidRect(surface: SwSurface, bbox: Region, c: RGBA): bool =
  let w = max(int(bbox.sw), 0)
  if surface.channelSize == 4:
    let color = surface.join(c.r, c.g, c.b, 255)
    for y in 0 ..< max(int(bbox.sh), 0):
      fillPixels32(surface.data, color, (int(bbox.yMin) + y) * int(surface.stride) +
                   int(bbox.xMin), w)
    true
  elif surface.channelSize == 1:
    for y in 0 ..< max(int(bbox.sh), 0):
      fillPixels8(surface.buf8, 255, (int(bbox.yMin) + y) * int(surface.stride) +
                  int(bbox.xMin), w)
    true
  else: false

proc rasterRect(surface: SwSurface, bbox: Region, c: RGBA): bool =
  if compositing(surface):
    if matting(surface): mattedRect(surface, bbox, c) else: maskedRect(surface, bbox, c)
  elif blending(surface): blendingRect(surface, bbox, c)
  elif c.a == 255: solidRect(surface, bbox, c)
  else: rasterTranslucentRect(surface, bbox, c)

# ---- rle ----

proc maskedRle(surface: SwSurface, rle: SwRle, bbox: Region, c: RGBA): bool =
  if surface.channelSize != 1: return false
  let cmp = surface.compositor
  let maskOp = getMaskOp(cmp.meth)
  let cimg = cmp.image
  let direct = maskDirect(cmp.meth)
  forSpans(rle, bbox, span, x, n):
    let src = if span.coverage == 255: c.a else: multiply(c.a, span.coverage)
    let crow = int(span.y) * int(cimg.stride) + x
    if direct:
      let drow = int(span.y) * int(surface.stride) + x
      for i in 0 ..< n:
        let tmp = maskOp(src, cimg.surface.buf8[crow + i], 0)
        surface.buf8[drow + i] = tmp + multiply(surface.buf8[drow + i], not tmp)
    else:
      for i in 0 ..< n:
        cimg.surface.buf8[crow + i] = maskOp(src, cimg.surface.buf8[crow + i], 255'u8 - src)
  if direct: true else: compositeMaskImage(surface, cimg, cmp.bbox)

proc mattedRle(surface: SwSurface, rle: SwRle, bbox: Region, c: RGBA): bool =
  let cimg = surface.compositor.image
  let getAlpha = surfaceAlpha(surface, surface.compositor.meth)
  if surface.channelSize == 4:
    let color = surface.join(c.r, c.g, c.b, c.a)
    forSpans(rle, bbox, span, x, n):
      let drow = int(span.y) * int(surface.stride) + x
      let crow = int(span.y) * int(cimg.stride) + x
      let src = if span.coverage == 255: color else: alphaBlend(color, uint32(span.coverage))
      for i in 0 ..< n:
        let tmp = alphaBlend(src, uint32(getAlpha(cimg.cmpAt(crow + i))))
        surface.data[drow + i] = tmp + alphaBlend(surface.data[drow + i], uint32(ialpha(tmp)))
  elif surface.channelSize == 1:
    forSpans(rle, bbox, span, x, n):
      let drow = int(span.y) * int(surface.stride) + x
      let crow = int(span.y) * int(cimg.stride) + x
      let src = if span.coverage == 255: c.a else: multiply(c.a, span.coverage)
      for i in 0 ..< n:
        surface.buf8[drow + i] =
          interpolate8(src, surface.buf8[drow + i], getAlpha(cimg.cmpAt(crow + i)))
  true

proc blendingRle(surface: SwSurface, rle: SwRle, bbox: Region, c: RGBA): bool =
  if surface.channelSize != 4: return false
  let color = surface.join(c.r, c.g, c.b, c.a)
  forSpans(rle, bbox, span, x, n):
    let row = int(span.y) * int(surface.stride) + x
    for i in 0 ..< n:
      let d = surface.data[row + i]
      let b = surface.blender(surface, color, d)
      surface.data[row + i] = if span.coverage == 255: b else: interpolate(b, d, span.coverage)
  true

proc solidRle(surface: SwSurface, rle: SwRle, bbox: Region, c: RGBA): bool =
  if surface.channelSize == 4:
    let color = surface.join(c.r, c.g, c.b, 255)
    forSpans(rle, bbox, span, x, n):
      let row = int(span.y) * int(surface.stride) + x
      if span.coverage == 255: fillPixels32(surface.data, color, row, n)
      else:
        let src = alphaBlend(color, uint32(span.coverage))
        let ia = 255'u32 - uint32(span.coverage)
        for i in 0 ..< n: surface.data[row + i] = src + alphaBlend(surface.data[row + i], ia)
  elif surface.channelSize == 1:
    forSpans(rle, bbox, span, x, n):
      let row = int(span.y) * int(surface.stride) + x
      if span.coverage == 255: fillPixels8(surface.buf8, span.coverage, row, n)
      else:
        let ia = 255'u8 - span.coverage
        for i in 0 ..< n:
          surface.buf8[row + i] = span.coverage + multiply(surface.buf8[row + i], ia)
  true

proc rasterRle(surface: SwSurface, rle: SwRle, bbox: Region, c: RGBA): bool =
  if rle.invalid: false
  elif compositing(surface):
    if matting(surface): mattedRle(surface, rle, bbox, c) else: maskedRle(surface, rle, bbox, c)
  elif blending(surface): blendingRle(surface, rle, bbox, c)
  elif c.a == 255: solidRle(surface, rle, bbox, c)
  else: rasterTranslucentRle(surface, rle, bbox, c)

# ---- external interface ----

proc premultiplyColor(c: var RGBA) =
  if c.a < 255:
    c.r = multiply(c.r, c.a)
    c.g = multiply(c.g, c.a)
    c.b = multiply(c.b, c.a)

proc rasterShape*(surface: SwSurface, shape: SwShape, bbox: Region, c: var RGBA): bool =
  ## Fills the shape with a straight-alpha color `c` (premultiplied in place).
  premultiplyColor(c)
  if shape.fastTrack: rasterRect(surface, bbox, c) else: rasterRle(surface, shape.rle, bbox, c)

proc rasterStroke*(surface: SwSurface, shape: SwShape, bbox: Region, c: var RGBA): bool =
  premultiplyColor(c)
  rasterRle(surface, shape.strokeRle, bbox, c)
