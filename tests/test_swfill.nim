import std/[unittest, math]
import thorvg/core/[types, geom, fill]
import thorvg/renderer/render
import thorvg/engine/cpu/[common, pixel, blend]
import thorvg/engine/cpu/fill_gen
import thorvg/engine/cpu/fill as swfill

const
  Red = 0xffff0000'u32
  Blue = 0xff0000ff'u32

proc newSurface(): SwSurface =
  result = SwSurface(join: argbJoin, blendMethod: BlendMethod.Normal)
  result.alphas = [maskAlpha, maskInvAlpha, argbLuma, argbInvLuma]

func stop(offset: float32, r, g, b, a: uint8): ColorStop =
  ColorStop(offset: offset, r: r, g: g, b: b, a: a)

proc redBlue(f: Fill, a: uint8 = 255): Fill =
  result = f
  result.stops = @[stop(0, 255, 0, 0, a), stop(1, 0, 0, 255, a)]

proc prepared(f: Fill, opacity: uint8 = 255, m = identity()): SwFill =
  var sf: SwFill
  doAssert fillPrepare(sf, f, m, newSurface(), opacity, true)
  sf

proc span(sf: SwFill, y, x, n: int): seq[uint32] =
  result = newSeq[uint32](n)
  fillRasterBlend(sf, result, 0, y, x, n, opBlendSrcOver, 255)

func tableIndex(sf: SwFill, c: uint32): int =
  for i in 0 ..< SwColorTable:
    if sf.ctable[i] == c: return i
  -1

suite "color table":
  test "linear pad table ends and middle":
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0)))
    check sf.ctable[0] == Red
    check sf.ctable[1023] == Blue
    check not sf.translucent and not sf.solid
    let mid = sf.ctable[511]
    check alpha(mid) == 255
    check ch2(mid) == 0
    check abs(int(ch1(mid)) - 127) <= 2
    check abs(int(ch3(mid)) - 127) <= 2
    check int(ch1(mid)) + int(ch3(mid)) in 253 .. 257
    for i in 1 .. 1023:
      check ch1(sf.ctable[i]) <= ch1(sf.ctable[i - 1])

  test "translucent stops are premultiplied":
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0), 128))
    check sf.translucent
    check sf.ctable[0] == 0x80800000'u32
    check alpha(sf.ctable[1023]) == 128
    let half = prepared(redBlue(linearGradient(0, 0, 100, 0)), 128)
    check half.translucent
    check half.ctable[0] == 0x80800000'u32

  test "three stops with a plateau":
    var f = linearGradient(0, 0, 100, 0)
    f.stops = @[stop(0, 255, 0, 0, 255), stop(0.5, 0, 255, 0, 255),
                stop(0.5, 0, 255, 0, 255), stop(1, 0, 0, 255, 255)]
    let sf = prepared(f)
    check sf.ctable[0] == Red
    check sf.ctable[1023] == Blue
    check abs(int(ch2(sf.ctable[512])) - 255) <= 3
    check abs(int(ch2(sf.ctable[300]))) in 100 .. 160

  test "colorAt clamps by spread":
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0)))
    check colorAt(sf, 0.0) == sf.ctable[0]
    check colorAt(sf, -3.0) == sf.ctable[0]
    check colorAt(sf, 5.0) == sf.ctable[1023]
    check colorAt(sf, 1.0) == sf.ctable[1023]
    check colorAt(sf, 0.5) == sf.ctable[int(0.5 * 1023.0 + 0.5)]

  test "spread index pad reflect repeat":
    var sf = SwFill(spread: FillSpread.Pad)
    check spreadIndex(sf, -5) == 0
    check spreadIndex(sf, 1030) == 1023
    check spreadIndex(sf, 600) == 600
    sf.spread = FillSpread.Repeat
    check spreadIndex(sf, 1030) == 6
    check spreadIndex(sf, -1) == 1023
    check spreadIndex(sf, 2048) == 0
    sf.spread = FillSpread.Reflect
    check spreadIndex(sf, 1023) == 1023
    check spreadIndex(sf, 1024) == 1023
    check spreadIndex(sf, 1025) == 1022
    check spreadIndex(sf, 2047) == 0
    check spreadIndex(sf, 2048) == 0
    check spreadIndex(sf, -1) == 0
    check spreadIndex(sf, -1024) == 1023

  test "repeat anti-aliases the table seam":
    var f = redBlue(linearGradient(0, 0, 10, 0))
    f.spread = FillSpread.Repeat
    let sf = prepared(f)
    check sf.extent > 9.9 and sf.extent < 10.1
    check sf.ctable[1023] != Blue
    check sf.ctable[0] != Red
    check int(ch1(sf.ctable[1023])) in 100 .. 160
    check sf.ctable[40] == prepared(redBlue(linearGradient(0, 0, 10, 0))).ctable[40]

suite "solid fill":
  test "single stop is solid":
    var f = linearGradient(0, 0, 100, 0)
    f.stops = @[stop(0, 10, 20, 30, 255)]
    let sf = prepared(f)
    var st: ColorStop
    check sf.solid
    check fillFetchSolid(sf, f, st)
    check st.r == 10 and st.g == 20 and st.b == 30

  test "degenerate linear gradient is solid, last stop wins":
    let f = redBlue(linearGradient(5, 5, 5, 5))
    let sf = prepared(f)
    var st: ColorStop
    check sf.solid
    check fillFetchSolid(sf, f, st)
    check st.b == 255 and st.r == 0

  test "radial with a tiny radius is solid":
    let sf = prepared(redBlue(radialGradient(10, 10, 0.001)))
    check sf.solid

  test "normal gradient is not solid":
    let f = redBlue(linearGradient(0, 0, 100, 0))
    let sf = prepared(f)
    var st: ColorStop
    check not fillFetchSolid(sf, f, st)

  test "empty stops fail, singular transform fails":
    var sf: SwFill
    check not fillPrepare(sf, linearGradient(0, 0, 100, 0), identity(), newSurface(), 255, true)
    var m = identity()
    m.e11 = 0
    var sf2: SwFill
    check not fillPrepare(sf2, redBlue(linearGradient(0, 0, 100, 0)), m, newSurface(), 255, true)

  test "reset clears flags and prepare without ctable keeps the table":
    var sf = prepared(redBlue(linearGradient(0, 0, 100, 0)), 100)
    check sf.translucent
    let c = sf.ctable[300]
    fillReset(sf)
    check not sf.translucent
    check fillPrepare(sf, redBlue(linearGradient(0, 0, 100, 0)), identity(), newSurface(), 255,
                      false)
    check sf.ctable[300] == c

suite "linear raster":
  test "horizontal gradient samples the table":
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0)))
    let px = span(sf, 3, 0, 100)
    check px[0] == sf.ctable[5]
    for i in 0 ..< 100:
      let k = int(round(0.01 * (float(i) + 0.5) * 1023.0))
      check px[i] in [sf.ctable[k - 1], sf.ctable[k], sf.ctable[k + 1]]
    check px[99] in [sf.ctable[1017], sf.ctable[1018], sf.ctable[1019]]
    for i in 1 ..< 100:
      check ch1(px[i]) <= ch1(px[i - 1])

  test "span offset (x start) matches the same pixels of a full row":
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0)))
    let full = span(sf, 0, 0, 100)
    let part = span(sf, 0, 40, 10)
    for i in 0 ..< 10:
      check part[i] in [full[40 + i], sf.ctable[spreadIndex(sf, 410 + i * 10)]]

  test "vertical gradient is a constant color per row":
    let sf = prepared(redBlue(linearGradient(0, 0, 0, 100)))
    let px = span(sf, 50, 7, 16)
    for i in 1 ..< 16:
      check px[i] == px[0]
    check px[0] in [sf.ctable[516], sf.ctable[517], sf.ctable[518]]

  test "translation moves the gradient":
    var m = identity()
    translate(m, pt(10, 0))
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0)), 255, m)
    let px = span(sf, 0, 10, 4)
    check px[0] == sf.ctable[5]

  test "spread modes beyond the gradient":
    var f = redBlue(linearGradient(0, 0, 10, 0))
    f.spread = FillSpread.Pad
    let pad = prepared(f)
    check span(pad, 0, 15, 1)[0] == pad.ctable[1023]
    check span(pad, 0, 0, 1)[0] == pad.ctable[51]
    f.spread = FillSpread.Reflect
    let refl = prepared(f)
    check span(refl, 0, 15, 1)[0] in [refl.ctable[460], refl.ctable[461], refl.ctable[462]]
    f.spread = FillSpread.Repeat
    let rep = prepared(f)
    check span(rep, 0, 15, 1)[0] in [rep.ctable[561], rep.ctable[562], rep.ctable[563]]

  test "float fallback for a steep gradient does not fail":
    var f = redBlue(linearGradient(0, 0, 1, 0))
    var m = identity()
    scale(m, pt(0.0001, 1))
    let sf = prepared(f, 255, m)
    let px = span(sf, 0, 0, 8)
    for p in px:
      check p == sf.ctable[1023]

  test "toI32 mimics cvttss2si":
    check toI32(2.9) == 2
    check toI32(-2.9) == -2
    check toI32(NaN) == int(low(int32))
    check toI32(1e20'f32) == int(low(int32))

suite "radial and conic raster":
  test "radial gradient":
    let sf = prepared(redBlue(radialGradient(50, 50, 50)))
    let px = span(sf, 50, 0, 100)
    check px[0] in [sf.ctable[1013], sf.ctable[1014], sf.ctable[1012]]
    check px[50] in [sf.ctable[13], sf.ctable[14], sf.ctable[15]]
    check px[49] in [sf.ctable[13], sf.ctable[14], sf.ctable[15]]
    check span(sf, 50, 99, 1)[0] in [sf.ctable[1013], sf.ctable[1014], sf.ctable[1012]]
    check span(sf, 0, 0, 1)[0] == sf.ctable[1023]

  test "radial gradient with a focal point":
    let f = redBlue(radialGradient(50, 50, 50, 70, 50, 0))
    let sf = prepared(f)
    check not sf.solid
    let px = span(sf, 50, 0, 100)
    check tableIndex(sf, px[70]) in 15 .. 25     # next to the focal point
    check tableIndex(sf, px[0]) in 1013 .. 1019  # focal ray hits the circle at x = 0
    check tableIndex(sf, px[99]) in 1000 .. 1010

  test "conic gradient":
    let f = redBlue(conicGradient(50, 50, 0))
    let sf = prepared(f)
    check sf.kind == FillKind.Conic
    # pixel (90, 50): just below the 3 o'clock seam; pixel (50, 90): a quarter turn
    check span(sf, 50, 90, 1)[0] in [sf.ctable[2], sf.ctable[3], sf.ctable[1]]
    let q = span(sf, 90, 50, 1)[0]
    check q in [sf.ctable[253], sf.ctable[254], sf.ctable[255], sf.ctable[256]]

  test "conic seam is anti-aliased for rotated transforms":
    var m = identity()
    rotate(m, 30)
    let sf = prepared(redBlue(conicGradient(0, 0, 0)), 255, m)
    check sf.invFwidth > 0
    let px = span(sf, 10, 0, 40)
    var mixed = 0
    for p in px:
      if p != sf.ctable[0] and p != sf.ctable[1023] and ch1(p) > 0 and ch3(p) > 0: inc mixed
    check mixed >= 1

suite "raster flavours":
  test "mask add":
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0)))
    var dst = newSeq[uint8](10)
    fillRasterMask(sf, dst, 2, 0, 0, 5, opMaskAdd, 255)
    check dst[0] == 0 and dst[1] == 0 and dst[7] == 0
    for i in 2 ..< 7:
      check dst[i] == 255
    let tr = prepared(redBlue(linearGradient(0, 0, 100, 0), 128))
    fillRasterMask(tr, dst, 0, 0, 0, 2, opMaskAdd, 255)
    check dst[0] == 128 and dst[1] == 128

  test "mask direct intersect":
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0)))
    var dst = @[10'u8, 20, 30, 40]
    let cmp = @[255'u8, 0, 255, 0]
    fillRasterMaskDirect(sf, dst, 0, 0, 0, 4, cmp, 0, opMaskIntersect, 255)
    check dst == @[255'u8, 20, 255, 40]
    var dst2 = @[1'u8, 2]
    fillRasterMaskDirect(sf, dst2, 0, 0, 0, 2, @[0'u8, 9, 255], 1, opMaskIntersect, 255)
    check dst2[1] == 255

  test "blend normal over an opaque destination":
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0), 128))
    var dst = newSeq[uint32](4)
    for i in 0 ..< 4: dst[i] = 0xff000000'u32
    fillRasterBlend(sf, dst, 0, 0, 0, 4, opBlendNormal, 255)
    for i in 0 ..< 4:
      check alpha(dst[i]) == 255
      check ch1(dst[i]) > 120
    var half = @[0xff000000'u32]
    fillRasterBlend(sf, half, 0, 0, 0, 1, opBlendInterp, 0)
    check half[0] == 0xff000000'u32

  test "blend with a blend method":
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0)))
    let surf = newSurface()
    var dst = @[0xff3264c8'u32, 0xff3264c8'u32]
    fillRasterBlendEx(surf, sf, dst, 0, 0, 0, 2, opBlendPreNormal, blendDifference, 255)
    # source is ~red (255,0,0) at the left: |s - d| = (205, 100, 200)
    check alpha(dst[0]) == 255
    check abs(int(ch1(dst[0])) - 205) <= 4
    var dst2 = @[0xff3264c8'u32]
    fillRasterBlendEx(surf, sf, dst2, 0, 0, 0, 1, opBlendPreNormal, blendDifference, 0)
    check dst2[0] == 0xff3264c8'u32

  test "matte with 8 and 32 bit masks":
    let sf = prepared(redBlue(linearGradient(0, 0, 100, 0)))
    var dst = newSeq[uint32](4)
    for i in 0 ..< 4: dst[i] = 0xff000000'u32
    let cmp8 = @[0'u8, 255, 0, 255]
    fillRasterMatte(sf, dst, 0, 0, 0, 4, cmp8, 0, maskAlpha, 255)
    check dst[0] == 0xff000000'u32 and dst[2] == 0xff000000'u32
    check ch1(dst[1]) > 200 and ch1(dst[3]) > 200
    var d2 = @[0xff000000'u32, 0xff000000'u32]
    let cmp32 = @[0x000000ff'u32, 0x00000000'u32]
    fillRasterMatte(sf, d2, 0, 0, 0, 2, cmp32, 0, maskAlpha, 255)
    check ch1(d2[0]) > 200 and d2[1] == 0xff000000'u32
    var d3 = @[0xff000000'u32]
    fillRasterMatte(sf, d3, 0, 0, 0, 1, @[255'u8], 0, maskInvAlpha, 255)
    check d3[0] == 0xff000000'u32
    var d4 = @[0xff000000'u32]
    fillRasterMatte(sf, d4, 0, 0, 0, 1, @[255'u8], 0, maskAlpha, 128)
    check int(ch1(d4[0])) in 120 .. 135

suite "blend functions":
  let surf = newSurface()
  # s = (R100, G200, B50), d = (R50, G100, B200), both opaque ARGB
  const
    S = 0xff64c832'u32
    D = 0xff3264c8'u32

  test "separable blends on opaque pixels":
    check blendDifference(surf, S, D) == 0xff326496'u32
    check blendAdd(surf, S, D) == 0xff96fffa'u32
    check blendLighten(surf, S, D) == 0xff64c8c8'u32
    check blendDarken(surf, S, D) == 0xff326432'u32
    check blendScreen(surf, S, D) == 0xff82ddd2'u32
    check blendMultiply(surf, S, D) == 0xff144f28'u32
    check blendExclusion(surf, S, D) == 0xff6e8eaa'u32
    check blendOverlay(surf, S, D) == 0xff289ea5'u32
    check blendHardLight(surf, S, D) == 0xff28bb50'u32
    check blendColorDodge(surf, S, D) == 0xff52fff8'u32
    check blendColorBurn(surf, S, D) == 0xff003a00'u32
    check blendSoftLight(surf, S, D) == 0xff2a85ae'u32

  test "dodge/burn edge cases":
    check blendColorDodge(surf, 0xffffffff'u32, D) == 0xffffffff'u32
    check blendColorDodge(surf, S, 0xff000000'u32) == 0xff000000'u32
    check blendColorBurn(surf, 0xff000000'u32, D) == 0xff000000'u32
    check blendColorBurn(surf, S, 0xffffffff'u32) == 0xffffffff'u32

  test "unpremultiplied destination":
    check blendMultiply(surf, S, 0x00000000'u32) == S
    check blendMultiply(surf, S, 0x80404040'u32) == 0xff4b9625'u32

  test "non separable blends":
    check blendLuminosity(surf, 0xff0ac832'u32, 0xff808080'u32) == 0xff959595'u32
    check blendColor(surf, 0xff646464'u32, 0xffc86400'u32) == 0xff727272'u32
    check blendSaturation(surf, 0xff646464'u32, 0xffc86400'u32) == 0xff717171'u32
    check blendHue(surf, 0xff646464'u32, 0xff808080'u32) == 0xff7f7f7f'u32
    # hue keeps the destination luminance for saturated pixels
    let h = blendHue(surf, 0xffff0000'u32, 0xff204060'u32)
    check alpha(h) == 255

  test "luma getters and joins":
    check abgrLuma(0x00ffffff'u32) == 254
    check argbLuma(0x000000ff'u32) == 18
    check argbInvLuma(0'u32) == 255
    check maskAlpha(0x12345678'u32) == 0x78
    check maskInvAlpha(0x12345678'u32) == 0x87
    check argbJoin(1, 2, 3, 4) == 0x04010203'u32
    check abgrJoin(1, 2, 3, 4) == 0x04030201'u32
    check luma(surf, 0x00ffffff'u32) == 254
    check surfaceAlpha(surf, MaskMethod.Alpha) == maskAlpha
    check surfaceAlpha(surf, MaskMethod.InvLuma) == argbInvLuma
    check surfaceAlpha(surf, MaskMethod.Add) == maskAlpha

  test "mask operators":
    check opMaskAdd(100, 100, 255) == 200
    check opMaskSubtract(255, 0, 0) == 255
    check opMaskSubtract(255, 255, 0) == 0
    check opMaskIntersect(255, 128, 0) == 128
    check opMaskDifference(255, 0, 255) == 255
    check opMaskLighten(3, 9, 0) == 9
    check opMaskDarken(3, 9, 0) == 3
    check maskDirect(MaskMethod.Intersect) and not maskDirect(MaskMethod.Add)
    check getMaskOp(MaskMethod.Add) == opMaskAdd
    check getMaskOp(MaskMethod.Alpha) == nil

  test "blenderFor maps every blend method":
    check blenderFor(BlendMethod.Normal) == nil
    check blenderFor(BlendMethod.Composition) == nil
    for m in [BlendMethod.Multiply, BlendMethod.Screen, BlendMethod.Overlay, BlendMethod.Darken,
              BlendMethod.Lighten, BlendMethod.ColorDodge, BlendMethod.ColorBurn,
              BlendMethod.HardLight, BlendMethod.SoftLight, BlendMethod.Difference,
              BlendMethod.Exclusion, BlendMethod.Hue, BlendMethod.Saturation, BlendMethod.Color,
              BlendMethod.Luminosity, BlendMethod.Add]:
      check blenderFor(m) != nil
    check blenderFor(BlendMethod.Hue) == blendHue