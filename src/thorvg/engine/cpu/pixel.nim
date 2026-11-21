## 32-bit pixel arithmetic of the CPU engine (premultiplied ARGB/ABGR helpers).
##
## Ported from the inline functions of `tvgSwCommon.h`
## (`ALPHA_BLEND`, `INTERPOLATE`, `PREMULTIPLY`, ...). All math is done on
## `uint32`, which wraps like the C code. Channel layout: A = bits 24..31,
## C1 = 16..23, C2 = 8..15, C3 = 0..7.

import ./hot

# Small pixel helpers are inlined into every caller module: they sit in the per-pixel loops
# and gcc cannot inline across Nim modules (H-perf-4).
{.push inline.}

func join*(c0, c1, c2, c3: uint8): uint32 =
  ## Joins four channels (c0 is the top byte), the C `JOIN` macro.
  (uint32(c0) shl 24) or (uint32(c1) shl 16) or (uint32(c2) shl 8) or uint32(c3)

func alphaBlend*(c: uint32, a: uint32): uint32 =
  ## Scales all channels of `c` by `a` / 256 (after `a + 1`).
  let a = a + 1
  ((((c shr 8) and 0x00ff00ff'u32) * a) and 0xff00ff00'u32) +
    ((((c and 0x00ff00ff'u32) * a) shr 8) and 0x00ff00ff'u32)

func interpolate*(s, d: uint32, a: uint8): uint32 =
  ## Linear blend of `s` over `d`: `d + (s - d) * a / 256` per channel.
  let a = uint32(a)
  (((((s shr 8) and 0xff00ff'u32) - ((d shr 8) and 0xff00ff'u32)) * a +
    (d and 0xff00ff00'u32)) and 0xff00ff00'u32) +
  (((((s and 0xff00ff'u32) - (d and 0xff00ff'u32)) * a) shr 8 +
    (d and 0xff00ff'u32)) and 0xff00ff'u32)

func interpolate8*(s, d, a: uint8): uint8 =
  ## 8-bit variant; `~a` is evaluated on an `int` like in C.
  let t1 = (int(s) * int(a) + 0xff) shr 8
  let t2 = (int(d) * (not int(a)) + 0xff) shr 8
  uint8((t1 + t2) and 0xff)

func alpha*(c: uint32): uint8 = uint8(c shr 24)
func ialpha*(c: uint32): uint8 = uint8((not c) shr 24)
func ch1*(c: uint32): uint8 = uint8(c shr 16)
func ch2*(c: uint32): uint8 = uint8(c shr 8)
func ch3*(c: uint32): uint8 = uint8(c)

func premultiply*(c: uint32, a: uint8): uint32 =
  let a = uint32(a)
  (c and 0xff000000'u32) + ((((c shr 8) and 0xff'u32) * a) and 0xff00'u32) +
    ((((c and 0x00ff00ff'u32) * a) shr 8) and 0x00ff00ff'u32)

{.pop.}

func unpremultiply*(data: uint32): uint32 {.noRaiseHot.} =
  let al = alpha(data)
  if al == 255 or al == 0: return data
  let r = uint8(min(uint32(ch1(data)) * 255'u32 div uint32(al), 255'u32))
  let g = uint8(min(uint32(ch2(data)) * 255'u32 div uint32(al), 255'u32))
  let b = uint8(min(uint32(ch3(data)) * 255'u32 div uint32(al), 255'u32))
  join(al, r, g, b)

func opBlendInterp*(s, d: uint32, a: uint8): uint32 = interpolate(s, d, a)

func opBlendNormal*(s, d: uint32, a: uint8): uint32 =
  let t = alphaBlend(s, uint32(a))
  t + alphaBlend(d, uint32(ialpha(t)))

func opBlendPreNormal*(s, d: uint32, a: uint8): uint32 =
  s + alphaBlend(d, uint32(ialpha(s)))

func opBlendSrcOver*(s, d: uint32, a: uint8): uint32 = s
