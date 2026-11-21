## VP8 inverse transforms and intra predictors.
##
## Ported from `src/modules/webp/static/dsp/dec.cpp` (plain C versions). All buffers are
## `var openArray[uint8]` plus an offset `d` (the C++ `dst` pointer) and the stride `Bps`.

import ./vp8_types

func clip8(v: int): uint8 {.inline.} =
  if v < 0: 0'u8 elif v > 255: 255'u8 else: uint8(v)

# ---- transforms (Paragraph 14.4) ----

const
  C1 = 20091 + (1 shl 16)
  C2 = 35468

func mul(a, b: int): int {.inline.} =
  ## `MUL(a, b)`: the C product is a 32-bit `int` that wraps.
  var p = (a * b) and 0xffffffff
  if p >= 0x80000000: p -= 0x100000000
  p shr 16

template store(x, y, v: untyped) =
  dst[d + (x) + (y) * Bps] = clip8(int(dst[d + (x) + (y) * Bps]) + ((v) shr 3))

proc transformOne(inp: openArray[int16], i0: int, dst: var openArray[uint8], d: int) =
  var tmp: array[16, int]
  for i in 0 ..< 4:                     # vertical pass
    let k = i0 + i
    let a = int(inp[k]) + int(inp[k + 8])
    let b = int(inp[k]) - int(inp[k + 8])
    let c = mul(int(inp[k + 4]), C2) - mul(int(inp[k + 12]), C1)
    let d4 = mul(int(inp[k + 4]), C1) + mul(int(inp[k + 12]), C2)
    tmp[i * 4] = a + d4
    tmp[i * 4 + 1] = b + c
    tmp[i * 4 + 2] = b - c
    tmp[i * 4 + 3] = a - d4
  for i in 0 ..< 4:                     # horizontal pass
    let dc = tmp[i] + 4
    let a = dc + tmp[i + 8]
    let b = dc - tmp[i + 8]
    let c = mul(tmp[i + 4], C2) - mul(tmp[i + 12], C1)
    let dd = mul(tmp[i + 4], C1) + mul(tmp[i + 12], C2)
    store(0, i, a + dd)
    store(1, i, b + c)
    store(2, i, b - c)
    store(3, i, a - dd)

proc transformTwo*(inp: openArray[int16], i0: int, dst: var openArray[uint8], d: int,
                   doTwo: bool) =
  ## `VP8Transform`
  transformOne(inp, i0, dst, d)
  if doTwo: transformOne(inp, i0 + 16, dst, d + 4)

proc transformAC3*(inp: openArray[int16], i0: int, dst: var openArray[uint8], d: int) =
  ## Simplified transform when only in[0], in[1] and in[4] are non-zero.
  let a = int(inp[i0]) + 4
  let c4 = mul(int(inp[i0 + 4]), C2)
  let d4 = mul(int(inp[i0 + 4]), C1)
  let c1 = mul(int(inp[i0 + 1]), C2)
  let d1 = mul(int(inp[i0 + 1]), C1)
  template store2(y, dc, dd, c: untyped) =
    let base = dc
    store(0, y, base + (dd))
    store(1, y, base + (c))
    store(2, y, base - (c))
    store(3, y, base - (dd))
  store2(0, a + d4, d1, c1)
  store2(1, a + c4, d1, c1)
  store2(2, a - c4, d1, c1)
  store2(3, a - d4, d1, c1)

proc transformUV*(inp: openArray[int16], i0: int, dst: var openArray[uint8], d: int) =
  transformTwo(inp, i0, dst, d, true)
  transformTwo(inp, i0 + 32, dst, d + 4 * Bps, true)

proc transformDC*(inp: openArray[int16], i0: int, dst: var openArray[uint8], d: int) =
  let dc = int(inp[i0]) + 4
  for j in 0 ..< 4:
    for i in 0 ..< 4: store(i, j, dc)

proc transformDCUV*(inp: openArray[int16], i0: int, dst: var openArray[uint8], d: int) =
  if inp[i0] != 0: transformDC(inp, i0, dst, d)
  if inp[i0 + 16] != 0: transformDC(inp, i0 + 16, dst, d + 4)
  if inp[i0 + 32] != 0: transformDC(inp, i0 + 32, dst, d + 4 * Bps)
  if inp[i0 + 48] != 0: transformDC(inp, i0 + 48, dst, d + 4 * Bps + 4)

# ---- intra predictions: 16x16 and chroma ----

proc trueMotion(dst: var openArray[uint8], d, size: int) =
  let tl = int(dst[d - Bps - 1])
  for y in 0 ..< size:
    let left = int(dst[d + y * Bps - 1])
    for x in 0 ..< size:
      dst[d + y * Bps + x] = clip8(left + int(dst[d - Bps + x]) - tl)

proc putBlock(dst: var openArray[uint8], d, size: int, v: int) =
  for j in 0 ..< size:
    for i in 0 ..< size: dst[d + j * Bps + i] = uint8(v)

proc sumTop(dst: openArray[uint8], d, size: int): int =
  for i in 0 ..< size: result += int(dst[d - Bps + i])

proc sumLeft(dst: openArray[uint8], d, size: int): int =
  for j in 0 ..< size: result += int(dst[d - 1 + j * Bps])

proc predLuma16*(mode: int, dst: var openArray[uint8], d: int) =
  ## `VP8PredLuma16`: DC, TM, VE, HE, DCNoTop, DCNoLeft, DCNoTopLeft.
  case mode
  of 0: putBlock(dst, d, 16, (16 + sumTop(dst, d, 16) + sumLeft(dst, d, 16)) shr 5)
  of 1: trueMotion(dst, d, 16)
  of 2:
    for j in 0 ..< 16:
      for i in 0 ..< 16: dst[d + j * Bps + i] = dst[d - Bps + i]
  of 3:
    for j in 0 ..< 16:
      for i in 0 ..< 16: dst[d + j * Bps + i] = dst[d + j * Bps - 1]
  of 4: putBlock(dst, d, 16, (8 + sumLeft(dst, d, 16)) shr 4)
  of 5: putBlock(dst, d, 16, (8 + sumTop(dst, d, 16)) shr 4)
  else: putBlock(dst, d, 16, 0x80)

proc predChroma8*(mode: int, dst: var openArray[uint8], d: int) =
  ## `VP8PredChroma8`: DC, TM, VE, HE, DCNoTop, DCNoLeft, DCNoTopLeft.
  case mode
  of 0: putBlock(dst, d, 8, (8 + sumTop(dst, d, 8) + sumLeft(dst, d, 8)) shr 4)
  of 1: trueMotion(dst, d, 8)
  of 2:
    for j in 0 ..< 8:
      for i in 0 ..< 8: dst[d + j * Bps + i] = dst[d - Bps + i]
  of 3:
    for j in 0 ..< 8:
      for i in 0 ..< 8: dst[d + j * Bps + i] = dst[d + j * Bps - 1]
  of 4: putBlock(dst, d, 8, (4 + sumLeft(dst, d, 8)) shr 3)
  of 5: putBlock(dst, d, 8, (4 + sumTop(dst, d, 8)) shr 3)
  else: putBlock(dst, d, 8, 0x80)

# ---- 4x4 predictions ----

func avg3(a, b, c: int): uint8 {.inline.} = uint8((a + 2 * b + c + 2) shr 2)
func avg2(a, b: int): uint8 {.inline.} = uint8((a + b + 1) shr 1)

proc predLuma4*(mode: int, dst: var openArray[uint8], d: int) =
  ## `VP8PredLuma4`: DC, TM, VE, HE, RD, VR, LD, VL, HD, HU.
  template px(i: int): int = int(dst[d + (i)])        # i = x - Bps (top row, x in -1..7)
  template top(x: int): int = px((x) - Bps)
  template left(y: int): int = px(-1 + (y) * Bps)      # y in -1..3 (-1 is the corner)
  template put(x, y: int, v: uint8) = dst[d + (x) + (y) * Bps] = v
  case mode
  of 0:
    var dc = 4
    for i in 0 ..< 4: dc += top(i) + left(i)
    for j in 0 ..< 4:
      for i in 0 ..< 4: put(i, j, uint8(dc shr 3))
  of 1: trueMotion(dst, d, 4)
  of 2:
    let vals = [avg3(top(-1), top(0), top(1)), avg3(top(0), top(1), top(2)),
                avg3(top(1), top(2), top(3)), avg3(top(2), top(3), top(4))]
    for j in 0 ..< 4:
      for i in 0 ..< 4: put(i, j, vals[i])
  of 3:
    let vals = [avg3(left(-1), left(0), left(1)), avg3(left(0), left(1), left(2)),
                avg3(left(1), left(2), left(3)), avg3(left(2), left(3), left(3))]
    for j in 0 ..< 4:
      for i in 0 ..< 4: put(i, j, vals[j])
  of 4:   # down-right
    let (i0, j, k, l, x) = (left(0), left(1), left(2), left(3), left(-1))
    let (a, b, c, e) = (top(0), top(1), top(2), top(3))
    put(0, 3, avg3(j, k, l))
    let v1 = avg3(i0, j, k)
    put(1, 3, v1); put(0, 2, v1)
    let v2 = avg3(x, i0, j)
    put(2, 3, v2); put(1, 2, v2); put(0, 1, v2)
    let v3 = avg3(a, x, i0)
    put(3, 3, v3); put(2, 2, v3); put(1, 1, v3); put(0, 0, v3)
    let v4 = avg3(b, a, x)
    put(3, 2, v4); put(2, 1, v4); put(1, 0, v4)
    let v5 = avg3(c, b, a)
    put(3, 1, v5); put(2, 0, v5)
    put(3, 0, avg3(e, c, b))
  of 5:   # vertical-right
    let (i0, j, k, x) = (left(0), left(1), left(2), left(-1))
    let (a, b, c, e) = (top(0), top(1), top(2), top(3))
    let v0 = avg2(x, a)
    put(0, 0, v0); put(1, 2, v0)
    let v1 = avg2(a, b)
    put(1, 0, v1); put(2, 2, v1)
    let v2 = avg2(b, c)
    put(2, 0, v2); put(3, 2, v2)
    put(3, 0, avg2(c, e))
    put(0, 3, avg3(k, j, i0))
    put(0, 2, avg3(j, i0, x))
    let v3 = avg3(i0, x, a)
    put(0, 1, v3); put(1, 3, v3)
    let v4 = avg3(x, a, b)
    put(1, 1, v4); put(2, 3, v4)
    let v5 = avg3(a, b, c)
    put(2, 1, v5); put(3, 3, v5)
    put(3, 1, avg3(b, c, e))
  of 6:   # down-left
    let (a, b, c, e) = (top(0), top(1), top(2), top(3))
    let (f, g, h, i) = (top(4), top(5), top(6), top(7))
    put(0, 0, avg3(a, b, c))
    let v1 = avg3(b, c, e)
    put(1, 0, v1); put(0, 1, v1)
    let v2 = avg3(c, e, f)
    put(2, 0, v2); put(1, 1, v2); put(0, 2, v2)
    let v3 = avg3(e, f, g)
    put(3, 0, v3); put(2, 1, v3); put(1, 2, v3); put(0, 3, v3)
    let v4 = avg3(f, g, h)
    put(3, 1, v4); put(2, 2, v4); put(1, 3, v4)
    let v5 = avg3(g, h, i)
    put(3, 2, v5); put(2, 3, v5)
    put(3, 3, avg3(h, i, i))
  of 7:   # vertical-left
    let (a, b, c, e) = (top(0), top(1), top(2), top(3))
    let (f, g, h) = (top(4), top(5), top(6))
    put(0, 0, avg2(a, b))
    let v1 = avg2(b, c)
    put(1, 0, v1); put(0, 2, v1)
    let v2 = avg2(c, e)
    put(2, 0, v2); put(1, 2, v2)
    let v3 = avg2(e, f)
    put(3, 0, v3); put(2, 2, v3)
    put(0, 1, avg3(a, b, c))
    let v4 = avg3(b, c, e)
    put(1, 1, v4); put(0, 3, v4)
    let v5 = avg3(c, e, f)
    put(2, 1, v5); put(1, 3, v5)
    let v6 = avg3(e, f, g)
    put(3, 1, v6); put(2, 3, v6)
    put(3, 2, avg3(f, g, h))
    put(3, 3, avg3(g, h, top(7)))
  of 8:   # horizontal-down
    let (i0, j, k, l, x) = (left(0), left(1), left(2), left(3), left(-1))
    let (a, b, c) = (top(0), top(1), top(2))
    let v0 = avg2(i0, x)
    put(0, 0, v0); put(2, 1, v0)
    let v1 = avg2(j, i0)
    put(0, 1, v1); put(2, 2, v1)
    let v2 = avg2(k, j)
    put(0, 2, v2); put(2, 3, v2)
    put(0, 3, avg2(l, k))
    put(3, 0, avg3(a, b, c))
    put(2, 0, avg3(x, a, b))
    let v3 = avg3(i0, x, a)
    put(1, 0, v3); put(3, 1, v3)
    let v4 = avg3(j, i0, x)
    put(1, 1, v4); put(3, 2, v4)
    let v5 = avg3(k, j, i0)
    put(1, 2, v5); put(3, 3, v5)
    put(1, 3, avg3(l, k, j))
  else:   # horizontal-up
    let (i0, j, k, l) = (left(0), left(1), left(2), left(3))
    put(0, 0, avg2(i0, j))
    let v1 = avg2(j, k)
    put(2, 0, v1); put(0, 1, v1)
    let v2 = avg2(k, l)
    put(2, 1, v2); put(0, 2, v2)
    put(1, 0, avg3(i0, j, k))
    let v3 = avg3(j, k, l)
    put(3, 0, v3); put(1, 1, v3)
    let v4 = avg3(k, l, l)
    put(3, 1, v4); put(1, 2, v4)
    let vl = uint8(l)
    put(3, 2, vl); put(2, 2, vl); put(0, 3, vl); put(1, 3, vl); put(2, 3, vl)
    put(3, 3, vl)
