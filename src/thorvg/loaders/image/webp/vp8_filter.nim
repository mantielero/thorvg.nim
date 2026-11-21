## VP8 in-loop filters (Paragraphs 15.2 and 15.3).
##
## Ported from `src/modules/webp/static/dsp/dec.cpp`. The C++ lookup tables
## (`VP8kclip1`, `VP8ksclip1`, `VP8ksclip2`, `VP8kabs0`) are plain clamps and `abs`.
## Pointers become an offset `p` into a plane.

func clip1(v: int): uint8 {.inline.} =
  if v < 0: 0'u8 elif v > 255: 255'u8 else: uint8(v)

func sclip1(v: int): int {.inline.} = clamp(v, -128, 127)
func sclip2(v: int): int {.inline.} = clamp(v, -16, 15)

proc doFilter2(b: var openArray[uint8], p, step: int) =
  ## 4 pixels in, 2 pixels out
  let p1 = int(b[p - 2 * step])
  let p0 = int(b[p - step])
  let q0 = int(b[p])
  let q1 = int(b[p + step])
  let a = 3 * (q0 - p0) + sclip1(p1 - q1)
  let a1 = sclip2((a + 4) shr 3)
  let a2 = sclip2((a + 3) shr 3)
  b[p - step] = clip1(p0 + a2)
  b[p] = clip1(q0 - a1)

proc doFilter4(b: var openArray[uint8], p, step: int) =
  ## 4 pixels in, 4 pixels out
  let p1 = int(b[p - 2 * step])
  let p0 = int(b[p - step])
  let q0 = int(b[p])
  let q1 = int(b[p + step])
  let a = 3 * (q0 - p0)
  let a1 = sclip2((a + 4) shr 3)
  let a2 = sclip2((a + 3) shr 3)
  let a3 = (a1 + 1) shr 1
  b[p - 2 * step] = clip1(p1 + a3)
  b[p - step] = clip1(p0 + a2)
  b[p] = clip1(q0 - a1)
  b[p + step] = clip1(q1 - a3)

proc doFilter6(b: var openArray[uint8], p, step: int) =
  ## 6 pixels in, 6 pixels out
  let p2 = int(b[p - 3 * step])
  let p1 = int(b[p - 2 * step])
  let p0 = int(b[p - step])
  let q0 = int(b[p])
  let q1 = int(b[p + step])
  let q2 = int(b[p + 2 * step])
  let a = sclip1(3 * (q0 - p0) + sclip1(p1 - q1))
  let a1 = (27 * a + 63) shr 7
  let a2 = (18 * a + 63) shr 7
  let a3 = (9 * a + 63) shr 7
  b[p - 3 * step] = clip1(p2 + a3)
  b[p - 2 * step] = clip1(p1 + a2)
  b[p - step] = clip1(p0 + a1)
  b[p] = clip1(q0 - a1)
  b[p + step] = clip1(q1 - a2)
  b[p + 2 * step] = clip1(q2 - a3)

func hev(b: openArray[uint8], p, step, thresh: int): bool =
  let p1 = int(b[p - 2 * step])
  let p0 = int(b[p - step])
  let q0 = int(b[p])
  let q1 = int(b[p + step])
  abs(p1 - p0) > thresh or abs(q1 - q0) > thresh

func needsFilter(b: openArray[uint8], p, step, t: int): bool =
  let p1 = int(b[p - 2 * step])
  let p0 = int(b[p - step])
  let q0 = int(b[p])
  let q1 = int(b[p + step])
  4 * abs(p0 - q0) + abs(p1 - q1) <= t

func needsFilter2(b: openArray[uint8], p, step, t, it: int): bool =
  let p3 = int(b[p - 4 * step])
  let p2 = int(b[p - 3 * step])
  let p1 = int(b[p - 2 * step])
  let p0 = int(b[p - step])
  let q0 = int(b[p])
  let q1 = int(b[p + step])
  let q2 = int(b[p + 2 * step])
  let q3 = int(b[p + 3 * step])
  if 4 * abs(p0 - q0) + abs(p1 - q1) > t: return false
  abs(p3 - p2) <= it and abs(p2 - p1) <= it and abs(p1 - p0) <= it and
    abs(q3 - q2) <= it and abs(q2 - q1) <= it and abs(q1 - q0) <= it

# ---- simple filter ----

proc simpleVFilter16*(b: var openArray[uint8], p, stride, thresh: int) =
  let thresh2 = 2 * thresh + 1
  for i in 0 ..< 16:
    if needsFilter(b, p + i, stride, thresh2): doFilter2(b, p + i, stride)

proc simpleHFilter16*(b: var openArray[uint8], p, stride, thresh: int) =
  let thresh2 = 2 * thresh + 1
  for i in 0 ..< 16:
    if needsFilter(b, p + i * stride, 1, thresh2): doFilter2(b, p + i * stride, 1)

proc simpleVFilter16i*(b: var openArray[uint8], p, stride, thresh: int) =
  for k in 1 .. 3: simpleVFilter16(b, p + 4 * k * stride, stride, thresh)

proc simpleHFilter16i*(b: var openArray[uint8], p, stride, thresh: int) =
  for k in 1 .. 3: simpleHFilter16(b, p + 4 * k, stride, thresh)

# ---- complex filter ----

proc filterLoop26(b: var openArray[uint8], p0, hstride, vstride, size, thresh, ithresh,
                  hevThresh: int) =
  let thresh2 = 2 * thresh + 1
  var p = p0
  for _ in 0 ..< size:
    if needsFilter2(b, p, hstride, thresh2, ithresh):
      if hev(b, p, hstride, hevThresh): doFilter2(b, p, hstride)
      else: doFilter6(b, p, hstride)
    p += vstride

proc filterLoop24(b: var openArray[uint8], p0, hstride, vstride, size, thresh, ithresh,
                  hevThresh: int) =
  let thresh2 = 2 * thresh + 1
  var p = p0
  for _ in 0 ..< size:
    if needsFilter2(b, p, hstride, thresh2, ithresh):
      if hev(b, p, hstride, hevThresh): doFilter2(b, p, hstride)
      else: doFilter4(b, p, hstride)
    p += vstride

proc vFilter16*(b: var openArray[uint8], p, stride, thresh, ithresh, hevThresh: int) =
  filterLoop26(b, p, stride, 1, 16, thresh, ithresh, hevThresh)

proc hFilter16*(b: var openArray[uint8], p, stride, thresh, ithresh, hevThresh: int) =
  filterLoop26(b, p, 1, stride, 16, thresh, ithresh, hevThresh)

proc vFilter16i*(b: var openArray[uint8], p, stride, thresh, ithresh, hevThresh: int) =
  for k in 1 .. 3:
    filterLoop24(b, p + 4 * k * stride, stride, 1, 16, thresh, ithresh, hevThresh)

proc hFilter16i*(b: var openArray[uint8], p, stride, thresh, ithresh, hevThresh: int) =
  for k in 1 .. 3:
    filterLoop24(b, p + 4 * k, 1, stride, 16, thresh, ithresh, hevThresh)

proc vFilter8*(b: var openArray[uint8], p, stride, thresh, ithresh, hevThresh: int) =
  filterLoop26(b, p, stride, 1, 8, thresh, ithresh, hevThresh)

proc hFilter8*(b: var openArray[uint8], p, stride, thresh, ithresh, hevThresh: int) =
  filterLoop26(b, p, 1, stride, 8, thresh, ithresh, hevThresh)

proc vFilter8i*(b: var openArray[uint8], p, stride, thresh, ithresh, hevThresh: int) =
  filterLoop24(b, p + 4 * stride, stride, 1, 8, thresh, ithresh, hevThresh)

proc hFilter8i*(b: var openArray[uint8], p, stride, thresh, ithresh, hevThresh: int) =
  filterLoop24(b, p + 4, 1, stride, 8, thresh, ithresh, hevThresh)
