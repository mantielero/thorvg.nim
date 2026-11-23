## CPU engine scene effects, part 1: Gaussian blur and motion blur.
##
## Ported from `src/renderer/cpu_engine/tvgSwPostEffect.cpp` (and the scalar
## `cRasterGaussianFilterRow` of `tvgSwRasterCore.cpp`); scalar only, no SIMD, no OpenMP.
## C++ juggles raw pixel pointers with `std::swap`; here the pixel buffers (`seq[uint32]`)
## are moved out of their surfaces, swapped locally and moved back at the end, which
## leaves the same data in the composition surface (DECISIONS.md D-L1-1).
## Shared helpers (`SwBlurData`, `gaussianInit`, `xyFlip`, `edgeExtend`) are exported
## for `effects_shadow.nim`.

import std/[algorithm, math]
import ../../core/[types, geom]
import ../../renderer/effect
import ./common

type
  SwBlurData* = ref object of EffectData
    ## Box kernels of the almost-gaussian filter (also used by the drop shadow).
    level*: int
    kernel*: array[3, int]
    extends*: int
    offset*: SwPoint            ## drop shadow offset

  Tap = object
    x, y: int32
    weight: uint32              ## bilinear weight scaled by 65536

  SwMotionBlurData* = ref object of EffectData
    count: int                  ## sample count, before merging bilinear taps
    taps: seq[Tap]
    extent: SwPoint

const MaxLevel = 3

func edgeExtend*(last, idx: int): int =
  if idx < 0: 0 elif idx > last: last else: idx

# ---- Gaussian blur ----------------------------------------------------------------

proc gaussianInit*(data: SwBlurData, sigma: float32, quality: int): int =
  ## Fast almost-gaussian filtering by Peter Kovesi; returns the region extension.
  if zero(sigma): return 0
  data.level = int(float32(MaxLevel) * (float32(quality - 1) * 0.01'f32)) + 1
  # compute box kernel sizes
  var wl = int(sqrt(float64(12.0'f32 * sigma / float32(MaxLevel) + 1.0'f32)))
  if wl mod 2 == 0: dec wl
  let wu = wl + 2
  let mi = (12.0'f32 * sigma - float32(MaxLevel * wl * wl) - float32(4 * MaxLevel * wl) -
            float32(3 * MaxLevel)) / float32(-4 * wl - 4)
  let m = int(mi + 0.5'f32)
  for i in 0 ..< min(data.level, MaxLevel):
    data.kernel[i] = ((if i < m: wl else: wu) - 1) div 2
    result += data.kernel[i]

proc filterRow(dst: var seq[uint32], src: seq[uint32], off, w, dimension: int, iarr: float32) =
  let last = w - 1
  var l = -(dimension + 1)
  var r = dimension
  var acc: array[4, int]
  for x in l ..< r:  # initial accumulation
    let px = src[off + edgeExtend(last, x)]
    for c in 0 ..< 4: acc[c] += int((px shr uint32(8 * c)) and 0xff'u32)
  for x in 0 ..< w:  # rounding is ignored for performance, like upstream
    let rp = src[off + edgeExtend(last, r)]
    let lp = src[off + edgeExtend(last, l)]
    var o = 0'u32
    for c in 0 ..< 4:
      let sh = uint32(8 * c)
      acc[c] += int((rp shr sh) and 0xff'u32) - int((lp shr sh) and 0xff'u32)
      o = o or (uint32(uint8(int(float32(acc[c]) * iarr) and 0xff)) shl sh)
    dst[off + x] = o
    inc r
    inc l

proc gaussianFilter(dst: var seq[uint32], src: seq[uint32], stride, w, h: int,
    bbox: Region, dimension: int, flipped: bool) =
  let base = if flipped: int(bbox.xMin) * stride + int(bbox.yMin)
             else: int(bbox.yMin) * stride + int(bbox.xMin)
  let iarr = 1.0'f32 / float32(dimension + dimension + 1)
  for y in 0 ..< h: filterRow(dst, src, base + y * stride, w, dimension, iarr)

proc xyFlip*(src: seq[uint32], dst: var seq[uint32], stride, w, h: int, bbox: Region,
    flipped: bool) =
  ## Transposes a `w` x `h` block (`flipped`: the block is stored transposed).
  let (sb, db) =
    if flipped: (int(bbox.xMin) * stride + int(bbox.yMin),
                 int(bbox.yMin) * stride + int(bbox.xMin))
    else: (int(bbox.yMin) * stride + int(bbox.xMin),
           int(bbox.xMin) * stride + int(bbox.yMin))
  for y in 0 ..< h:
    for x in 0 ..< w: dst[db + x * stride + y] = src[sb + y * stride + x]

proc gaussianBlurUpdate*(p: GaussianBlurEffect, tm: Matrix) =
  if p.rd == nil: p.rd = SwBlurData()
  let d = SwBlurData(p.rd)
  let scaleSquared = tm.e11 * tm.e11 + tm.e12 * tm.e12
  d.extends = gaussianInit(d, p.sigma * p.sigma * scaleSquared, int(p.quality))
  p.valid = d.extends > 0

proc gaussianBlurRegion*(p: GaussianBlurEffect): bool =
  ## Region expansion for feathering.
  let extra = int32(SwBlurData(p.rd).extends)
  if p.direction != 2:
    p.extend.xMin = -extra
    p.extend.xMax = extra
  if p.direction != 1:
    p.extend.yMin = -extra
    p.extend.yMax = extra
  true

proc effectGaussianBlur*(cmp: SwCompositor, buffer: SwSurface, p: GaussianBlurEffect): bool =
  ## Blurs the composition image; `buffer` is a scratch surface of the same size.
  let data = SwBlurData(p.rd)
  let bbox = cmp.bbox
  let w = int(bbox.sw)
  let h = int(bbox.sh)
  let stride = int(cmp.image.stride)
  if w <= 0 or h <= 0: return true
  var front = move(cmp.image.surface.data)
  var back = move(buffer.data)
  # the Gaussian blur is separable: a horizontal and a vertical pass
  if p.direction != 2:
    for i in 0 ..< data.level:
      gaussianFilter(back, front, stride, w, h, bbox, data.kernel[i], false)
      swap(front, back)
  if p.direction != 1:
    xyFlip(front, back, stride, w, h, bbox, false)
    swap(front, back)
    for i in 0 ..< data.level:
      gaussianFilter(back, front, stride, h, w, bbox, data.kernel[i], true)
      swap(front, back)
    xyFlip(front, back, stride, h, w, bbox, true)
    swap(front, back)
  cmp.image.surface.data = move(front)
  buffer.data = move(back)
  true

# ---- Motion blur ------------------------------------------------------------------

proc cmpTap(a, b: Tap): int =
  if a.y != b.y: return if a.y > b.y: 1 else: -1
  int(a.x > b.x) - int(a.x < b.x)

proc motionBlurUpdate*(p: MotionBlurEffect, tm: Matrix) =
  var offset: Point
  var samples: int
  if not p.update(tm, offset, samples): return
  if p.rd == nil: p.rd = SwMotionBlurData()
  let data = SwMotionBlurData(p.rd)
  data.extent = SwPoint(x: int32(ceil(abs(offset.x) * 0.5'f32)),
                        y: int32(ceil(abs(offset.y) * 0.5'f32)))
  data.count = samples
  # flatten the bilinear samples into nonzero integer taps
  data.taps.setLen(0)
  for i in 0 ..< samples:
    let t = (float32(i) + 0.5'f32) / float32(samples) - 0.5'f32
    let px = offset.x * t
    let py = offset.y * t
    let x = int32(floor(px))
    let y = int32(floor(py))
    let fx = uint32((px - float32(x)) * 256.0'f32 + 0.5'f32)
    let fy = uint32((py - float32(y)) * 256.0'f32 + 0.5'f32)
    let weights = [(256 - fx) * (256 - fy), fx * (256 - fy), (256 - fx) * fy, fx * fy]
    for k in 0 ..< 4:
      if weights[k] != 0:
        data.taps.add Tap(x: x + int32(k and 1), y: y + int32(k shr 1), weight: weights[k])
  # merge repeated coordinates without changing the total integer weight
  data.taps.sort(cmpTap)
  var merged: seq[Tap]
  for t in data.taps:
    if merged.len > 0 and merged[^1].x == t.x and merged[^1].y == t.y:
      merged[^1].weight += t.weight
    else: merged.add t
  data.taps = merged
  p.valid = true

proc motionBlurRegion*(p: MotionBlurEffect): bool =
  let d = SwMotionBlurData(p.rd)
  p.extend = Region(xMin: -d.extent.x, yMin: -d.extent.y, xMax: d.extent.x, yMax: d.extent.y)
  true

proc effectMotionBlur*(cmp: SwCompositor, buffer: SwSurface, p: MotionBlurEffect): bool =
  let data = SwMotionBlurData(p.rd)
  let bbox = cmp.bbox
  let stride = int(cmp.image.stride)
  let w = int(bbox.sw)
  let h = int(bbox.sh)
  let divisor = uint64(data.count) * 65536'u64
  let base = int(bbox.yMin) * stride + int(bbox.xMin)
  var rows = newSeq[int](data.taps.len)
  var src = move(cmp.image.surface.data)
  for y in 0 ..< h:
    # Y clamping and row addressing are shared by all pixels of the row
    for i, t in data.taps: rows[i] = base + edgeExtend(h - 1, y + int(t.y)) * stride
    for x in 0 ..< w:
      var acc: array[4, uint64]
      for i, t in data.taps:
        let px = src[rows[i] + edgeExtend(w - 1, x + int(t.x))]
        for c in 0 ..< 4: acc[c] += uint64((px shr uint32(8 * c)) and 0xff'u32) * uint64(t.weight)
      var o = 0'u32
      for c in 0 ..< 4:
        o = o or (uint32(uint8((acc[c] + divisor div 2) div divisor)) shl uint32(8 * c))
      buffer.data[base + y * stride + x] = o
  cmp.image.surface.data = move(buffer.data)
  buffer.data = move(src)
  true
