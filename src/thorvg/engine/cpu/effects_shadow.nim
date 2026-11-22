## CPU engine scene effects, part 2: drop shadow.
##
## Ported from the drop shadow part of `src/renderer/cpu_engine/tvgSwPostEffect.cpp`.
## The three pixel buffers involved (the composition image and two scratch surfaces) are
## kept in a local pool; `cmpIdx`/`buf0`/`buf1` mirror which buffer each C++ pointer
## would hold, so every `std::swap` of the original is an index swap (D-L1-1).

import ../../core/[types, geom]
import ../../renderer/[effect, render]
import ./[common, pixel, rastercore, effects]

proc dropShadowFilter(dst: var seq[uint32], src: seq[uint32], stride, w, h: int,
    bbox: Region, dimension: int, color: uint32, flipped: bool) =
  let base = if flipped: int(bbox.xMin) * stride + int(bbox.yMin)
             else: int(bbox.yMin) * stride + int(bbox.xMin)
  let iarr = 1.0'f32 / float32(dimension + dimension + 1)
  let last = w - 1
  for y in 0 ..< h:
    let p = base + y * stride
    var l = -(dimension + 1)
    var r = dimension
    var acc = 0
    for x in l ..< r:  # initial accumulation
      acc += int(alpha(src[edgeExtend(last, x) + p]))
    for x in 0 ..< w:  # rounding is ignored for performance, like upstream
      acc += int(alpha(src[edgeExtend(last, r) + p])) - int(alpha(src[edgeExtend(last, l) + p]))
      dst[p + x] = alphaBlend(color, uint32(uint8(int(float32(acc) * iarr) and 0xff)))
      inc r
      inc l

proc shift(dOff, sOff: var int, dstride, sstride: int, bbox: Region, offset: SwPoint,
    w, h: var int) =
  ## Moves the start offsets and shrinks the size by the shadow offset.
  w = int(bbox.sw)
  h = int(bbox.sh)
  if offset.x < 0:
    sOff -= int(offset.x)
    w += int(offset.x)
  else:
    dOff += int(offset.x)
    w -= int(offset.x)
  if offset.y < 0:
    sOff -= int(offset.y) * sstride
    h += int(offset.y)
  else:
    dOff += int(offset.y) * dstride
    h -= int(offset.y)

proc dropShadowNoFilter(dst: var seq[uint32], src: seq[uint32], dstride, sstride: int,
    bbox: Region, offset: SwPoint, color: uint32, opacity: uint8, direct: bool) =
  var sOff = int(bbox.yMin) * sstride + int(bbox.xMin)
  var dOff = int(bbox.yMin) * dstride + int(bbox.xMin)
  var w, h: int
  shift(dOff, sOff, dstride, sstride, bbox, offset, w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let a = multiply(opacity, alpha(src[sOff + x]))
      if not direct or a == 255: dst[dOff + x] = alphaBlend(color, uint32(a))
      else: dst[dOff + x] = interpolate(color, dst[dOff + x], a)
    sOff += sstride
    dOff += dstride

proc dropShadowShift(dst: var seq[uint32], src: seq[uint32], dstride, sstride: int,
    bbox: Region, offset: SwPoint, opacity: uint8, direct: bool) =
  var sOff = int(bbox.yMin) * sstride + int(bbox.xMin)
  var dOff = int(bbox.yMin) * dstride + int(bbox.xMin)
  var w, h: int
  shift(dOff, sOff, dstride, sstride, bbox, offset, w, h)
  for y in 0 ..< h:
    if direct: rasterTranslucentPixels(dst, dOff, src, sOff, w, opacity)
    else: rasterSolidPixels(dst, dOff, src, sOff, w, opacity)
    sOff += sstride
    dOff += dstride

proc dropShadowRegion*(p: DropShadowEffect): bool =
  let d = SwBlurData(p.rd)
  let extra = int32(d.extends)
  p.extend = Region(xMin: -extra, yMin: -extra, xMax: extra, yMax: extra)
  if d.offset.x < 0: p.extend.xMin += d.offset.x else: p.extend.xMax += d.offset.x
  if d.offset.y < 0: p.extend.yMin += d.offset.y else: p.extend.yMax += d.offset.y
  true

proc dropShadowUpdate*(p: DropShadowEffect, tm: Matrix) =
  var offset: Point
  if not p.update(tm, offset): return
  if p.rd == nil: p.rd = SwBlurData()
  let d = SwBlurData(p.rd)
  # the sum of the box radii covers the full blur support
  let scaleSquared = tm.e11 * tm.e11 + tm.e12 * tm.e12
  d.extends = gaussianInit(d, p.sigma * p.sigma * scaleSquared * 0.5'f32, int(p.quality))
  d.offset = SwPoint(x: int32(offset.x), y: int32(offset.y))

proc effectDropShadow*(cmp: SwCompositor, s0, s1: SwSurface, p: DropShadowEffect,
    direct: bool): bool =
  ## `s0` keeps the original image to overlay it, `s1` generates the filtered image.
  let data = SwBlurData(p.rd)
  let bbox = cmp.bbox
  let w = int(bbox.sw)
  let h = int(bbox.sh)
  let off = data.offset
  if abs(int(off.x)) >= w or abs(int(off.y)) >= h: return true  # outside the screen
  let rsfc = cmp.recoverSfc
  let color = rsfc.join(p.color[0], p.color[1], p.color[2], 255)
  let stride = int(cmp.image.stride)
  let opacity = if direct: multiply(p.color[3], cmp.opacity) else: p.color[3]

  var pool = [move(cmp.image.surface.data), move(s0.data), move(s1.data)]
  var cmpIdx = 0  # which buffer each surface (or local pointer) currently holds
  var buf0 = 1
  var buf1 = 2
  var front = 0
  var back = 2
  let base = int(bbox.yMin) * stride + int(bbox.xMin)

  if data.extends == 0:  # no filter required
    if direct:
      dropShadowNoFilter(rsfc.data, pool[cmpIdx], int(rsfc.stride), stride, bbox, off,
                         color, opacity, true)
    else:
      # the shadow image, then the original image over it
      dropShadowNoFilter(pool[buf1], pool[cmpIdx], stride, stride, bbox, off, color, 255, false)
      for y in 0 ..< h:
        rasterTranslucentPixels(pool[buf1], base + y * stride, pool[cmpIdx],
                                base + y * stride, w, 255)
      swap(cmpIdx, buf1)
  else:
    # save the original image to overlay it into the filtered image
    dropShadowFilter(pool[back], pool[front], stride, w, h, bbox, data.kernel[0], color, false)
    swap(front, buf0)
    swap(front, back)
    for i in 1 ..< data.level:  # horizontal
      dropShadowFilter(pool[back], pool[front], stride, w, h, bbox, data.kernel[i], color, false)
      swap(front, back)
    xyFlip(pool[front], pool[back], stride, w, h, bbox, false)  # vertical
    swap(front, back)
    for i in 0 ..< data.level:
      dropShadowFilter(pool[back], pool[front], stride, h, w, bbox, data.kernel[i], color, true)
      swap(front, back)
    xyFlip(pool[front], pool[back], stride, h, w, bbox, true)
    swap(cmpIdx, back)
    if direct:  # draw to the main surface directly
      dropShadowShift(rsfc.data, pool[cmpIdx], int(rsfc.stride), stride, bbox, off, opacity, true)
      swap(cmpIdx, buf0)
    else:  # draw to the intermediate surface
      for y in 0 ..< h: fillPixels32(pool[buf1], 0, base + y * stride, w)
      dropShadowShift(pool[buf1], pool[cmpIdx], stride, stride, bbox, off, opacity, false)
      swap(cmpIdx, buf1)
      for y in 0 ..< h:  # compositing the shadow and the body
        rasterTranslucentPixels(pool[cmpIdx], base + y * stride, pool[buf0],
                                base + y * stride, w, 255)

  cmp.image.surface.data = move(pool[cmpIdx])
  s0.data = move(pool[buf0])
  s1.data = move(pool[buf1])
  true