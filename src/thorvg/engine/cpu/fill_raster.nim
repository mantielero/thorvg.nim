## Gradient span rasterizers of the CPU engine (the five `fillRaster` overloads).
##
## Ported from `fillRaster(...)` of `tvgSwFill.cpp` / `tvgSwCommon.h` lines 515-522.
## Destinations are `openArray` + start index `off` (C++: `dst` pointer). `y`, `x` is the
## device position of the first pixel of the span and `len` its length in pixels.
## Every proc handles linear, radial and conic gradients (by `fill.kind`).
##
## Signatures (C++ overload -> Nim):
##
##   composite masking: `fillRaster(fill, uint8_t* dst, y, x, len, SwMask op, a)`
##     fillRasterMask(fill: SwFill, dst: var openArray[uint8], off, y, x, len: int,
##                    op: SwMask, a: uint8)
##   direct masking:    `fillRaster(fill, uint8_t* dst, y, x, len, uint8_t* cmp, SwMask op, a)`
##     fillRasterMaskDirect(fill: SwFill, dst: var openArray[uint8], off, y, x, len: int,
##                          cmp: openArray[uint8], cmpOff: int, op: SwMask, a: uint8)
##   blending:          `fillRaster(fill, uint32_t* dst, y, x, len, SwBlenderA op, a)`
##     fillRasterBlend(fill: SwFill, dst: var openArray[uint32], off, y, x, len: int,
##                     op: SwBlenderA, a: uint8)
##   blending + method: `fillRaster(surface, fill, uint32_t* dst, y, x, len, op, SwBlender op2, a)`
##     fillRasterBlendEx(surface: SwSurface, fill: SwFill, dst: var openArray[uint32],
##                       off, y, x, len: int, op: SwBlenderA, op2: SwBlender, a: uint8)
##   matting:           `fillRaster(fill, uint32_t* dst, y, x, len, uint8_t* cmp, SwAlpha alpha,
##                                  uint8_t csize, uint8_t opacity)`
##     fillRasterMatte(fill: SwFill, dst: var openArray[uint32], off, y, x, len: int,
##                     cmp: openArray[uint8] | openArray[uint32], cmpOff: int,
##                     getAlpha: SwAlpha, opacity: uint8)
##
## Matte: `csize` is implied by the element type of `cmp` (1 = `uint8` mask, 4 = `uint32`
## ARGB mask); `cmpOff` is an element index and each element is passed to `getAlpha` as a
## `uint32`. `off`/`cmpOff` index the first pixel of the span; the spans must fit.

import ../../renderer/render
import ./[common, pixel, fill_gen]

proc fillRasterMask*(fill: SwFill, dst: var openArray[uint8], off, y, x, len: int,
                     op: SwMask, a: uint8) =
  var g = initGen(fill, y, x, len)
  for i in 0 ..< len:
    let src = multiply(a, alpha(g.next()))
    dst[off + i] = op(src, dst[off + i], not src)

proc fillRasterMaskDirect*(fill: SwFill, dst: var openArray[uint8], off, y, x, len: int,
                           cmp: openArray[uint8], cmpOff: int, op: SwMask, a: uint8) =
  var g = initGen(fill, y, x, len, quirk = true)
  for i in 0 ..< len:
    let src = multiply(alpha(g.next()), a)
    let tmp = op(src, cmp[cmpOff + i], 0)
    dst[off + i] = tmp + multiply(dst[off + i], not tmp)

proc fillRasterBlend*(fill: SwFill, dst: var openArray[uint32], off, y, x, len: int,
                      op: SwBlenderA, a: uint8) =
  var g = initGen(fill, y, x, len)
  # An indirect call makes the loop poll the thread-local error flag per pixel (see
  # `hot.nim`), so the four blenders the callers pass are matched and called directly.
  template run(blend: untyped) =
    for i in 0 ..< len:
      dst[off + i] = blend(g.next(), dst[off + i], a)
  if op == opBlendNormal: run(opBlendNormal)
  elif op == opBlendInterp: run(opBlendInterp)
  elif op == opBlendPreNormal: run(opBlendPreNormal)
  elif op == opBlendSrcOver: run(opBlendSrcOver)
  else: run(op)

proc fillRasterBlendEx*(surface: SwSurface, fill: SwFill, dst: var openArray[uint32],
                        off, y, x, len: int, op: SwBlenderA, op2: SwBlender, a: uint8) =
  var g = initGen(fill, y, x, len)
  for i in 0 ..< len:
    let d = dst[off + i]
    let tmp = op(g.next(), d, 255)
    let tmp2 = op2(surface, tmp, d)
    dst[off + i] = if a == 255: tmp2 else: interpolate(tmp2, d, a)

proc fillRasterMatte*[T: uint8 | uint32](fill: SwFill, dst: var openArray[uint32],
                                         off, y, x, len: int, cmp: openArray[T],
                                         cmpOff: int, getAlpha: SwAlpha, opacity: uint8) =
  var g = initGen(fill, y, x, len)
  for i in 0 ..< len:
    let a = multiply(opacity, getAlpha(uint32(cmp[cmpOff + i])))
    dst[off + i] = opBlendNormal(g.next(), dst[off + i], a)
