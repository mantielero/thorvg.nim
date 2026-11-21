## Blend functions, mask operators and channel getters of the CPU engine.
##
## Ported from `src/renderer/cpu_engine/tvgSwBlendOp.cpp` (the 16 `blend*` functions)
## plus the small helpers of `tvgSwRaster.cpp` that belong to blending: `_opMask*`,
## `_getMaskOp`, `_direct`, the alpha/luma getters and the `_abgrJoin`/`_argbJoin`
## color joins that `rasterInit` (T12b) stores in `SwSurface`.
##
## Differences from C++:
## - `SwAlpha` takes the pixel as a `uint32` (the C code reads it through a `uint8_t*`):
##   `maskAlpha` is the low byte, exactly what the C pointer read gives on little endian.
## - `SwSurface::alpha(method)` and `SwSurface::luma(c)` are `surfaceAlpha`/`luma` below.
## - `blenderFor(method)` is the `switch` of `SwRenderer::blend` (nil = Normal/Composition).
##
## All blend functions have the `SwBlender` signature `(surface, s, d) -> uint32` where
## `s` is the (non premultiplied) source and `d` the premultiplied destination.

import ../../core/types
import ../../renderer/render
import ./[common, pixel]

const SqrtLut = [
  0'u8, 15, 22, 27, 31, 35, 39, 42, 45, 47, 50, 52, 55, 57, 59, 61,
  63, 65, 67, 69, 71, 73, 74, 76, 78, 79, 81, 82, 84, 85, 87, 88,
  90, 91, 93, 94, 95, 97, 98, 99, 100, 102, 103, 104, 105, 107, 108, 109,
  110, 111, 112, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126,
  127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 141,
  142, 143, 144, 145, 146, 147, 148, 148, 149, 150, 151, 152, 153, 153, 154, 155,
  156, 157, 158, 158, 159, 160, 161, 162, 162, 163, 164, 165, 165, 166, 167, 168,
  168, 169, 170, 171, 171, 172, 173, 174, 174, 175, 176, 177, 177, 178, 179, 179,
  180, 181, 182, 182, 183, 184, 184, 185, 186, 186, 187, 188, 188, 189, 190, 190,
  191, 192, 192, 193, 194, 194, 195, 196, 196, 197, 198, 198, 199, 200, 200, 201,
  201, 202, 203, 203, 204, 205, 205, 206, 206, 207, 208, 208, 209, 210, 210, 211,
  211, 212, 213, 213, 214, 214, 215, 216, 216, 217, 217, 218, 218, 219, 220, 220,
  221, 221, 222, 222, 223, 224, 224, 225, 225, 226, 226, 227, 228, 228, 229, 229,
  230, 230, 231, 231, 232, 233, 233, 234, 234, 235, 235, 236, 236, 237, 237, 238,
  238, 239, 240, 240, 241, 241, 242, 242, 243, 243, 244, 244, 245, 245, 246, 246,
  247, 247, 248, 248, 249, 249, 250, 250, 251, 251, 252, 252, 253, 253, 254, 255]

# ---- channel getters and joins (tvgSwRaster.cpp helpers) ----

func maskAlpha*(c: uint32): uint8 = uint8(c and 0xff'u32)
func maskInvAlpha*(c: uint32): uint8 = not uint8(c and 0xff'u32)

func abgrLuma*(c: uint32): uint8 =
  ## 0.2126*R + 0.7152*G + 0.0722*B for ABGR pixels.
  uint8((((c and 0xff'u32) * 54) + (((c shr 8) and 0xff'u32) * 182) +
    (((c shr 16) and 0xff'u32) * 19)) shr 8)

func argbLuma*(c: uint32): uint8 =
  ## 0.2126*R + 0.7152*G + 0.0722*B for ARGB pixels.
  uint8((((c and 0xff'u32) * 19) + (((c shr 8) and 0xff'u32) * 182) +
    (((c shr 16) and 0xff'u32) * 54)) shr 8)

func abgrInvLuma*(c: uint32): uint8 = not abgrLuma(c)
func argbInvLuma*(c: uint32): uint8 = not argbLuma(c)

func abgrJoin*(r, g, b, a: uint8): uint32 = join(a, b, g, r)
func argbJoin*(r, g, b, a: uint8): uint32 = join(a, r, g, b)

proc surfaceAlpha*(s: SwSurface, m: MaskMethod): SwAlpha =
  ## `SwSurface::alpha`: the four matting methods map to alphas[0..3].
  let idx = int(m) - 1
  s.alphas[if idx > 3 or idx < 0: 0 else: idx]

proc luma*(s: SwSurface, c: uint32): uint8 = s.alphas[2](c)

# ---- mask operators ----

func opMaskAdd*(s, d, a: uint8): uint8 = s + multiply(d, a)
func opMaskSubtract*(s, d, a: uint8): uint8 = multiply(s, 255'u8 - d)
func opMaskIntersect*(s, d, a: uint8): uint8 = multiply(s, d)
func opMaskDifference*(s, d, a: uint8): uint8 = multiply(s, 255'u8 - d) + multiply(d, a)
func opMaskLighten*(s, d, a: uint8): uint8 = (if s > d: s else: d)
func opMaskDarken*(s, d, a: uint8): uint8 = (if s < d: s else: d)

func maskDirect*(m: MaskMethod): bool =
  m in {MaskMethod.Subtract, MaskMethod.Intersect, MaskMethod.Darken}

func getMaskOp*(m: MaskMethod): SwMask =
  ## nil for methods without a mask operator (None, Alpha, ...).
  case m
  of MaskMethod.Add: opMaskAdd
  of MaskMethod.Subtract: opMaskSubtract
  of MaskMethod.Difference: opMaskDifference
  of MaskMethod.Intersect: opMaskIntersect
  of MaskMethod.Lighten: opMaskLighten
  of MaskMethod.Darken: opMaskDarken
  else: nil

# ---- helpers of tvgSwBlendOp.cpp ----

func u8(x: int): uint8 = uint8(x and 0xff)

func premultiplyBlend(c1, c2: uint32, a: uint8): uint32 =
  if a == 255: c1
  elif a == 0: c2
  else: alphaBlend(c1, uint32(a)) + alphaBlend(c2, uint32(255 - int(a)))

func unpremul(c: uint32): RGBA =
  result = RGBA(r: ch1(c), g: ch2(c), b: ch3(c), a: alpha(c))
  if result.a > 0 and result.a < 255:
    let a = uint32(result.a)
    result.r = uint8(min(uint32(result.r) * 255'u32 div a, 255'u32))
    result.g = uint8(min(uint32(result.g) * 255'u32 div a, 255'u32))
    result.b = uint8(min(uint32(result.b) * 255'u32 div a, 255'u32))

func saturate(c1, c2, c3: var uint8, s1, s2, s3: uint8) =
  let s = max(int(s1), max(int(s2), int(s3))) - min(int(s1), min(int(s2), int(s3)))
  var v = [c1, c2, c3]
  var lo = 0
  var mid = 1
  var hi = 2
  if v[lo] > v[mid]: swap(lo, mid)
  if v[mid] > v[hi]: swap(mid, hi)
  if v[lo] > v[mid]: swap(lo, mid)
  let minv = int(v[lo])
  let maxv = int(v[hi])
  if maxv > minv:
    v[mid] = u8(((int(v[mid]) - minv) * s) div (maxv - minv))
    v[hi] = u8(s)
  else:
    v[mid] = 0
    v[hi] = 0
  v[lo] = 0
  c1 = v[0]
  c2 = v[1]
  c3 = v[2]

func luminance(c1, c2, c3: var uint8, cl, l: int) =
  let d = l - cl
  var r = int(c1) + d
  var g = int(c2) + d
  var b = int(c3) + d
  let minv = min(r, min(g, b))
  var maxv = max(r, max(g, b))
  if minv < 0:
    r = l + ((r - l) * l) div (l - minv)
    g = l + ((g - l) * l) div (l - minv)
    b = l + ((b - l) * l) div (l - minv)
    maxv = max(r, max(g, b))
  if maxv > 255:
    r = l + ((r - l) * (255 - l)) div (maxv - l)
    g = l + ((g - l) * (255 - l)) div (maxv - l)
    b = l + ((b - l) * (255 - l)) div (maxv - l)
  c1 = u8(r)
  c2 = u8(g)
  c3 = u8(b)

func rgb24(c1, c2, c3: uint8): uint32 =
  (uint32(c1) shl 16) or (uint32(c2) shl 8) or uint32(c3)

template opaqueBlend(f: untyped, s, d: uint32): uint32 =
  join(255, f(ch1(s), ch1(d)), f(ch2(s), ch2(d)), f(ch3(s), ch3(d)))

template unpremBlend(f: untyped, s, d: uint32): uint32 =
  let o = unpremul(d)
  premultiplyBlend(join(255, f(ch1(s), o.r), f(ch2(s), o.g), f(ch3(s), o.b)), s, o.a)

# ---- per-channel functions ----

func chDifference(s, d: uint8): uint8 = (if s > d: s - d else: d - s)
func chExclusion(s, d: uint8): uint8 =
  u8(clamp(int(s) + int(d) - 2 * int(multiply(s, d)), 0, 255))
func chAdd(s, d: uint8): uint8 = u8(min(int(s) + int(d), 255))
func chScreen(s, d: uint8): uint8 = u8(int(s) + int(d) - int(multiply(s, d)))
func chMultiply(s, d: uint8): uint8 = multiply(s, d)
func chOverlay(s, d: uint8): uint8 =
  if d < 128: u8(min(255, 2 * int(multiply(s, d))))
  else: u8(255 - min(255, 2 * int(multiply(255'u8 - s, 255'u8 - d))))
func chDarken(s, d: uint8): uint8 = min(s, d)
func chLighten(s, d: uint8): uint8 = max(s, d)
func chColorDodge(s, d: uint8): uint8 =
  if d == 0: 0
  elif s == 255: 255
  else: u8(min(int(d) * 255 div (255 - int(s)), 255))
func chColorBurn(s, d: uint8): uint8 =
  if d == 255: 255
  elif s == 0: 0
  else: u8(255 - min((255 - int(d)) * 255 div int(s), 255))
func chHardLight(s, d: uint8): uint8 =
  if s < 128: u8(min(255, 2 * int(multiply(s, d))))
  else: u8(255 - min(255, 2 * int(multiply(255'u8 - s, 255'u8 - d))))
func chSoftLight(s, d: uint8): uint8 =
  let si = int(s)
  let di = int(d)
  if si <= 127: return u8(di - ((255 - 2 * si) * di * (255 - di)) div 65025)
  let dd = if di <= 64: 4 * di - (12 * di * di) div 255 + (16 * di * di * di) div 65025
    else: int(SqrtLut[di])
  u8(di + ((2 * si - 255) * (dd - di)) div 255)

# ---- the 16 blenders (SwBlender) ----

proc blendDifference*(surface: SwSurface, s, d: uint32): uint32 = opaqueBlend(chDifference, s, d)
proc blendExclusion*(surface: SwSurface, s, d: uint32): uint32 = opaqueBlend(chExclusion, s, d)
proc blendAdd*(surface: SwSurface, s, d: uint32): uint32 = opaqueBlend(chAdd, s, d)
proc blendScreen*(surface: SwSurface, s, d: uint32): uint32 = opaqueBlend(chScreen, s, d)
proc blendLighten*(surface: SwSurface, s, d: uint32): uint32 = opaqueBlend(chLighten, s, d)
proc blendMultiply*(surface: SwSurface, s, d: uint32): uint32 = unpremBlend(chMultiply, s, d)
proc blendOverlay*(surface: SwSurface, s, d: uint32): uint32 = unpremBlend(chOverlay, s, d)
proc blendDarken*(surface: SwSurface, s, d: uint32): uint32 = unpremBlend(chDarken, s, d)
proc blendColorDodge*(surface: SwSurface, s, d: uint32): uint32 =
  unpremBlend(chColorDodge, s, d)
proc blendColorBurn*(surface: SwSurface, s, d: uint32): uint32 = unpremBlend(chColorBurn, s, d)
proc blendHardLight*(surface: SwSurface, s, d: uint32): uint32 = unpremBlend(chHardLight, s, d)
proc blendSoftLight*(surface: SwSurface, s, d: uint32): uint32 = unpremBlend(chSoftLight, s, d)

proc blendHue*(surface: SwSurface, s, d: uint32): uint32 =
  let o = unpremul(d)
  var c1 = ch1(s)
  var c2 = ch2(s)
  var c3 = ch3(s)
  saturate(c1, c2, c3, o.r, o.g, o.b)
  luminance(c1, c2, c3, int(surface.luma(rgb24(c1, c2, c3))),
            int(surface.luma(rgb24(o.r, o.g, o.b))))
  premultiplyBlend(join(255, c1, c2, c3), s, o.a)

proc blendSaturation*(surface: SwSurface, s, d: uint32): uint32 =
  let o = unpremul(d)
  var c1 = o.r
  var c2 = o.g
  var c3 = o.b
  saturate(c1, c2, c3, ch1(s), ch2(s), ch3(s))
  luminance(c1, c2, c3, int(surface.luma(rgb24(c1, c2, c3))),
            int(surface.luma(rgb24(o.r, o.g, o.b))))
  premultiplyBlend(join(255, c1, c2, c3), s, o.a)

proc blendColor*(surface: SwSurface, s, d: uint32): uint32 =
  let o = unpremul(d)
  var c1 = ch1(s)
  var c2 = ch2(s)
  var c3 = ch3(s)
  luminance(c1, c2, c3, int(surface.luma(s)), int(surface.luma(rgb24(o.r, o.g, o.b))))
  premultiplyBlend(join(255, c1, c2, c3), s, o.a)

proc blendLuminosity*(surface: SwSurface, s, d: uint32): uint32 =
  var o = unpremul(d)
  let lo = int(surface.luma(rgb24(o.r, o.g, o.b)))
  luminance(o.r, o.g, o.b, lo, int(surface.luma(s)))
  premultiplyBlend(join(255, o.r, o.g, o.b), s, o.a)

proc blenderFor*(m: BlendMethod): SwBlender =
  ## Blender of a blend method (`SwRenderer::blend`); nil for Normal/Composition.
  case m
  of BlendMethod.Multiply: blendMultiply
  of BlendMethod.Screen: blendScreen
  of BlendMethod.Overlay: blendOverlay
  of BlendMethod.Darken: blendDarken
  of BlendMethod.Lighten: blendLighten
  of BlendMethod.ColorDodge: blendColorDodge
  of BlendMethod.ColorBurn: blendColorBurn
  of BlendMethod.HardLight: blendHardLight
  of BlendMethod.SoftLight: blendSoftLight
  of BlendMethod.Difference: blendDifference
  of BlendMethod.Exclusion: blendExclusion
  of BlendMethod.Hue: blendHue
  of BlendMethod.Saturation: blendSaturation
  of BlendMethod.Color: blendColor
  of BlendMethod.Luminosity: blendLuminosity
  of BlendMethod.Add: blendAdd
  else: nil
