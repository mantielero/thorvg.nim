## Scalar pixel loops and surface helpers of the CPU rasterizer.
##
## Ported from `src/renderer/cpu_engine/tvgSwRasterCore.cpp` (the `c*` scalar
## functions only; AVX/NEON dispatch is not ported, DECISIONS D3) and from the small
## predicates at the top of `tvgSwRaster.cpp` (`_compositing`, `_matting`, ...).
##
## Differences from C++: buffers are `seq`s with an element offset instead of
## pointers; the compositor image is a `SwImage` whose `surface` holds the pixels
## (`data` for 32-bit, `buf8` for 8-bit); `cmpAt` reads one of its elements.

import ../../core/[types, geom]
import ../../renderer/render
import ./[common, pixel, rle_clip]

func compositing*(s: SwSurface): bool =
  ## A compositor is attached and does something (C++ `_compositing`).
  s.compositor != nil and s.compositor.meth != MaskMethod.None

func matting*(s: SwSurface): bool =
  ## The compositor uses a matte (alpha/luma), not a mask operator. Needs a compositor.
  int(s.compositor.meth) < int(MaskMethod.Add)

func blending*(s: SwSurface): bool = s.blender != nil

func cmpAt*(img: SwImage, i: int): uint32 =
  ## Element `i` (in pixels) of a compositor image: 8-bit mask or 32-bit color.
  if img.channelSize == 1: uint32(img.surface.buf8[i]) else: img.surface.data[i]

func spanSlice*(rle: SwRle, bbox: Region): Slice[int] =
  ## Indices of the spans whose row lies inside `bbox` (empty slice if none).
  if rle == nil or rle.spans.len == 0: 1 .. 0
  else: spanRange(rle, bbox.yMin, bbox.yMax - 1)

template forSpans*(rle: SwRle, bbox: Region, span, x, n, body: untyped) =
  ## Runs `body` for every span clipped to `bbox`; `x`/`n` are the clipped start and
  ## length (C++ `for (span = rle->fetch(bbox, &end); ...) if (!span->fetch(...))`).
  for si in spanSlice(rle, bbox):
    let span = rle.spans[si]
    var fx, fl: int32
    if span.fetch(bbox, fx, fl):
      let x {.inject.} = int(fx)
      let n {.inject.} = int(fl)
      body

func fillPixels32*(dst: var seq[uint32], val: uint32, offset, len: int) =
  for i in offset ..< offset + len: dst[i] = val

func fillPixels8*(dst: var seq[uint8], val: uint8, offset, len: int) =
  for i in offset ..< offset + len: dst[i] = val

proc rasterTranslucentPixels*(dst: var seq[uint32], dOff: int, src: seq[uint32], sOff, len: int,
                              opacity: uint8) =
  if opacity == 255:
    for i in 0 ..< len:
      let s = src[sOff + i]
      dst[dOff + i] = s + alphaBlend(dst[dOff + i], uint32(ialpha(s)))
  else:
    for i in 0 ..< len:
      let tmp = alphaBlend(src[sOff + i], uint32(opacity))
      dst[dOff + i] = tmp + alphaBlend(dst[dOff + i], uint32(ialpha(tmp)))

proc rasterSolidPixels*(dst: var seq[uint32], dOff: int, src: seq[uint32], sOff, len: int,
                        opacity: uint8) =
  if opacity == 255:
    for i in 0 ..< len: dst[dOff + i] = src[sOff + i]
  else: rasterTranslucentPixels(dst, dOff, src, sOff, len, opacity)

proc rasterDownScaler*(img: seq[uint32], stride, w: int, sx: float32, miny, maxy, n: int): uint32 =
  ## Box filter over `n` pixels around `sx` (C++ `cRasterDownScaler`).
  var c: array[4, uint64]
  var count = 0'u64
  let minx = max(int(int32(sx)) - n, 0)
  let maxx = min(int(int32(sx)) + n, w)
  let inc = n div 2 + 1
  var y = miny
  while y < maxy:
    var x = minx
    while x < maxx:
      let p = img[x + y * stride]
      c[0] += uint64(alpha(p))
      c[1] += uint64(ch1(p))
      c[2] += uint64(ch2(p))
      c[3] += uint64(ch3(p))
      inc count
      x += inc
    y += inc
  if count == 0: 0'u32
  else:
    uint32(((c[0] div count) shl 24) or ((c[1] div count) shl 16) or
           ((c[2] div count) shl 8) or (c[3] div count))

proc rasterTranslucentRect*(surface: SwSurface, bbox: Region, c: RGBA): bool =
  let stride = int(surface.stride)
  let w = max(int(bbox.sw), 0)
  let h = max(int(bbox.sh), 0)
  if surface.channelSize == 4:
    let color = surface.join(c.r, c.g, c.b, c.a)
    let ia = 255'u32 - uint32(c.a)
    for y in 0 ..< h:
      let row = (int(bbox.yMin) + y) * stride + int(bbox.xMin)
      for x in 0 ..< w:
        surface.data[row + x] = color + alphaBlend(surface.data[row + x], ia)
  elif surface.channelSize == 1:
    let ia = not c.a
    for y in 0 ..< h:
      let row = (int(bbox.yMin) + y) * stride + int(bbox.xMin)
      for x in 0 ..< w:
        surface.buf8[row + x] = c.a + multiply(surface.buf8[row + x], ia)
  true

proc rasterTranslucentRle*(surface: SwSurface, rle: SwRle, bbox: Region, c: RGBA): bool =
  let stride = int(surface.stride)
  if surface.channelSize == 4:
    let color = surface.join(c.r, c.g, c.b, c.a)
    forSpans(rle, bbox, span, x, n):
      let base = int(span.y) * stride + x
      let src = if span.coverage < 255: alphaBlend(color, uint32(span.coverage)) else: color
      let ia = uint32(ialpha(src))
      for i in 0 ..< n:
        surface.data[base + i] = src + alphaBlend(surface.data[base + i], ia)
  elif surface.channelSize == 1:
    forSpans(rle, bbox, span, x, n):
      let base = int(span.y) * stride + x
      let src = if span.coverage < 255: multiply(span.coverage, c.a) else: c.a
      let ia = not c.a
      for i in 0 ..< n:
        surface.buf8[base + i] = src + multiply(surface.buf8[base + i], ia)
  true

proc rasterABGRtoARGB*(surface: RenderSurface): bool =
  ## Swaps the red and blue channels of every pixel.
  let stride = int(surface.stride)
  for y in 0 ..< int(surface.h):
    for x in 0 ..< int(surface.w):
      let c = surface.data[y * stride + x]
      surface.data[y * stride + x] = (c and 0xff000000'u32) + ((c and 0x00ff0000'u32) shr 16) +
        (c and 0x0000ff00'u32) + ((c and 0x000000ff'u32) shl 16)
  true

proc rasterClear*(surface: SwSurface, x, y, w, h: int): bool =
  ## Zeroes the rectangle (the whole rows when `w` equals the stride).
  if surface == nil or surface.stride == 0 or surface.w == 0 or surface.h == 0: return false
  if surface.data.len == 0 and surface.buf8.len == 0: return false
  let stride = int(surface.stride)
  if surface.channelSize == 4:
    if w == stride: fillPixels32(surface.data, 0, stride * y, w * h)
    else:
      for i in 0 ..< h: fillPixels32(surface.data, 0, stride * y + x + stride * i, w)
  elif surface.channelSize == 1:
    if w == stride: fillPixels8(surface.buf8, 0, stride * y, w * h)
    else:
      for i in 0 ..< h: fillPixels8(surface.buf8, 0, stride * y + x + stride * i, w)
  true
