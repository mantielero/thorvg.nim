import std/unittest
import thorvg/core/[types, geom, fill]
import thorvg/renderer/render
import thorvg/engine/cpu/[common, pixel, blend, rle, rle_clip, raster, image]
import thorvg/engine/cpu/fill as swfill

const
  Red = 0xffff0000'u32
  Green = 0xff00ff00'u32
  Blue = 0xff0000ff'u32
  White = 0xffffffff'u32
  Black = 0xff000000'u32

func region(x0, y0, x1, y1: int): Region =
  Region(xMin: int32(x0), yMin: int32(y0), xMax: int32(x1), yMax: int32(y1))

proc newSw(w, h: int, cs = ColorSpace.ARGB8888): SwSurface =
  result = SwSurface(stride: uint32(w), w: uint32(w), h: uint32(h),
                     blendMethod: BlendMethod.Normal)
  result.setup(cs)
  if cs == ColorSpace.Grayscale8: result.buf8 = newSeq[uint8](w * h)
  else:
    result.data = newSeq[uint32](w * h)
    doAssert rasterCompositor(result) == Result.Success

func at(s: RenderSurface, x, y: int): uint32 = s.data[y * int(s.stride) + x]
func nearRed(c: uint32): bool =
  alpha(c) == 255 and ch1(c) > 240 and ch3(c) < 16

func at8(s: RenderSurface, x, y: int): uint8 = s.buf8[y * int(s.stride) + x]

proc fillAll(s: RenderSurface, c: uint32) =
  for i in 0 ..< s.data.len: s.data[i] = c

proc fillAll8(s: RenderSurface, c: uint8) =
  for i in 0 ..< s.buf8.len: s.buf8[i] = c

proc rectShape(): SwShape = SwShape(fastTrack: true)

proc polyShape(x0, y0, x1, y1: float, bbox: Region): SwShape =
  ## RLE shape of an axis-aligned rectangle (fixed point 26.6, anti-aliased).
  func sp(x, y: float): SwPoint = SwPoint(x: int32(x * 64.0), y: int32(y * 64.0))
  let o = SwOutline(fillRule: FillRule.NonZero)
  o.cmds = @[PathCommand.MoveTo, PathCommand.LineTo, PathCommand.LineTo, PathCommand.LineTo,
             PathCommand.Close]
  o.pts = @[sp(x0, y0), sp(x1, y0), sp(x1, y1), sp(x0, y1)]
  SwShape(rle: rleRender(nil, o, bbox, true))

proc rgba(r, g, b, a: uint8): RGBA = RGBA(r: r, g: g, b: b, a: a)

proc maskCompositor(meth: MaskMethod, cmpSfc: RenderSurface, bbox: Region): SwCompositor =
  let img = SwImage(surface: cmpSfc, stride: cmpSfc.stride, w: cmpSfc.w, h: cmpSfc.h,
                    channelSize: cmpSfc.channelSize)
  SwCompositor(meth: meth, image: img, bbox: bbox, valid: true)

proc newImage(w, h: int, pixels: seq[uint32]): SwImage =
  let s = newSurface(uint32(w), uint32(h))
  s.data = pixels
  SwImage(surface: s, w: uint32(w), h: uint32(h), stride: uint32(w), channelSize: 4,
          filter: FilterMethod.Nearest, scale: 1.0'f32)

proc redBlue(a: uint8 = 255): Fill =
  result = linearGradient(0, 0, 20, 0)
  result.stops = @[ColorStop(offset: 0, r: 255, g: 0, b: 0, a: a),
                   ColorStop(offset: 1, r: 0, g: 0, b: 255, a: a)]

proc gradientShape(f: Fill, sfc: SwSurface, fast: bool, bbox: Region): SwShape =
  result = if fast: rectShape() else: polyShape(0, 0, 20, 4, bbox)
  doAssert swfill.fillPrepare(result.fill, f, identity(), sfc, 255, true)

suite "solid rect":
  test "opaque fast-track rect":
    let s = newSw(10, 8)
    var c = rgba(255, 0, 0, 255)
    check rasterShape(s, rectShape(), region(2, 1, 6, 4), c)
    check s.at(2, 1) == Red
    check s.at(5, 3) == Red
    check s.at(6, 3) == 0
    check s.at(1, 1) == 0
    check s.at(3, 4) == 0
  test "translucent rect over background":
    let s = newSw(4, 4)
    var c = rgba(255, 0, 0, 128)
    check rasterShape(s, rectShape(), region(0, 0, 4, 4), c)
    check c.r == 128 and c.a == 128
    check s.at(1, 1) == 0x80800000'u32
    s.fillAll(Black)
    var c2 = rgba(255, 0, 0, 128)
    check rasterShape(s, rectShape(), region(0, 0, 2, 2), c2)
    check s.at(0, 0) == 0x80800000'u32 + alphaBlend(Black, 127)
    check s.at(3, 3) == Black
  test "8-bit grayscale target":
    let s = newSw(4, 4, ColorSpace.Grayscale8)
    var c = rgba(0, 0, 0, 255)
    check rasterShape(s, rectShape(), region(1, 1, 3, 3), c)
    check s.at8(1, 1) == 255 and s.at8(0, 0) == 0
    var c2 = rgba(0, 0, 0, 128)
    check rasterShape(s, rectShape(), region(0, 0, 1, 1), c2)
    check s.at8(0, 0) == 128

suite "rle fill":
  test "full coverage and anti-aliased edge":
    let s = newSw(16, 8)
    let shape = polyShape(2.5, 1, 10, 5, region(0, 0, 16, 8))
    var c = rgba(255, 0, 0, 255)
    check rasterShape(s, shape, region(0, 0, 16, 8), c)
    check s.at(5, 2) == Red
    let edge = s.at(2, 2)
    check alpha(edge) == ch1(edge)
    check int(alpha(edge)) in 120 .. 135
    check s.at(1, 2) == 0 and s.at(10, 2) == 0 and s.at(5, 5) == 0
  test "alpha color over opaque background":
    let s = newSw(16, 8)
    s.fillAll(White)
    let shape = polyShape(0, 0, 16, 8, region(0, 0, 16, 8))
    var c = rgba(0, 0, 255, 128)
    check rasterShape(s, shape, region(0, 0, 16, 8), c)
    let p = s.at(3, 3)
    check alpha(p) == 255
    check int(ch1(p)) in 126 .. 128
    check int(ch3(p)) in 254 .. 255
  test "clipped to bbox":
    let s = newSw(16, 8)
    let shape = polyShape(0, 0, 16, 8, region(0, 0, 16, 8))
    var c = rgba(0, 255, 0, 255)
    check rasterShape(s, shape, region(4, 2, 8, 4), c)
    check s.at(4, 2) == Green and s.at(7, 3) == Green
    check s.at(3, 2) == 0 and s.at(8, 2) == 0 and s.at(4, 4) == 0 and s.at(4, 1) == 0
  test "empty rle is rejected":
    let s = newSw(4, 4)
    var c = rgba(1, 2, 3, 255)
    check not rasterShape(s, SwShape(rle: newRle()), region(0, 0, 4, 4), c)
    check not rasterShape(s, SwShape(), region(0, 0, 4, 4), c)

suite "blending":
  test "multiply on white keeps the color (rect and rle)":
    let s = newSw(8, 4)
    s.fillAll(White)
    s.blender = blenderFor(BlendMethod.Multiply)
    var c = rgba(255, 128, 0, 255)
    check rasterShape(s, rectShape(), region(0, 0, 4, 4), c)
    check s.at(1, 1) == 0xffff8000'u32
    var c2 = rgba(0, 0, 255, 255)
    check rasterShape(s, polyShape(4, 0, 8, 4, region(0, 0, 8, 4)), region(0, 0, 8, 4), c2)
    check s.at(5, 1) == Blue
  test "every blender matches a direct call on a rect":
    let bg = 0xff406080'u32
    for m in [BlendMethod.Multiply, BlendMethod.Screen, BlendMethod.Overlay,
              BlendMethod.Darken, BlendMethod.Lighten, BlendMethod.ColorDodge,
              BlendMethod.ColorBurn, BlendMethod.HardLight, BlendMethod.SoftLight,
              BlendMethod.Difference, BlendMethod.Exclusion, BlendMethod.Hue,
              BlendMethod.Saturation, BlendMethod.Color, BlendMethod.Luminosity,
              BlendMethod.Add]:
      let s = newSw(2, 2)
      s.fillAll(bg)
      s.blender = blenderFor(m)
      var c = rgba(200, 100, 50, 255)
      check rasterShape(s, rectShape(), region(0, 0, 2, 2), c)
      check s.at(1, 1) == s.blender(s, argbJoin(200, 100, 50, 255), bg)
  test "blender with partial coverage interpolates":
    let s = newSw(16, 8)
    s.fillAll(White)
    s.blender = blenderFor(BlendMethod.Difference)
    var c = rgba(255, 255, 255, 255)
    check rasterShape(s, polyShape(2.5, 1, 10, 5, region(0, 0, 16, 8)), region(0, 0, 16, 8), c)
    check s.at(5, 2) == Black
    let edge = s.at(2, 2)
    check ch2(edge) > 100 and ch2(edge) < 160
    check s.at(0, 0) == White

suite "composition masks":
  test "alpha matte on rect":
    let s = newSw(8, 2)
    let mask = newSurface(8, 2, ColorSpace.Grayscale8)
    for x in 0 ..< 4:
      for y in 0 ..< 2: mask.buf8[y * 8 + x] = 255
    s.compositor = maskCompositor(MaskMethod.Alpha, mask, region(0, 0, 8, 2))
    var c = rgba(255, 0, 0, 255)
    check rasterShape(s, rectShape(), region(0, 0, 8, 2), c)
    check s.at(1, 0) == Red
    check s.at(6, 1) == 0
  test "inverse alpha matte on rle":
    let s = newSw(8, 2)
    let mask = newSurface(8, 2, ColorSpace.Grayscale8)
    for x in 0 ..< 4:
      for y in 0 ..< 2: mask.buf8[y * 8 + x] = 255
    s.compositor = maskCompositor(MaskMethod.InvAlpha, mask, region(0, 0, 8, 2))
    var c = rgba(255, 0, 0, 255)
    check rasterShape(s, polyShape(0, 0, 8, 2, region(0, 0, 8, 2)), region(0, 0, 8, 2), c)
    check s.at(1, 0) == 0
    check s.at(6, 1) == Red
  test "luma matte with a 32-bit matte image":
    let s = newSw(4, 1)
    let matte = newSurface(4, 1)
    matte.data = @[White, Black, White, Black]
    s.compositor = maskCompositor(MaskMethod.Luma, matte, region(0, 0, 4, 1))
    var c = rgba(0, 255, 0, 255)
    check rasterShape(s, rectShape(), region(0, 0, 4, 1), c)
    check alpha(s.at(0, 0)) >= 253 and ch2(s.at(0, 0)) >= 253
    check s.at(1, 0) == 0
    check alpha(s.at(2, 0)) >= 253
  test "mask Add (composite) and Intersect (direct) into an 8-bit target":
    let target = newSw(4, 2, ColorSpace.Grayscale8)
    let other = newSw(4, 2, ColorSpace.Grayscale8)
    target.compositor = maskCompositor(MaskMethod.Add, other, region(0, 0, 4, 2))
    var c = rgba(0, 0, 0, 255)
    check rasterShape(target, rectShape(), region(0, 0, 2, 2), c)
    check target.at8(0, 0) == 255 and target.at8(1, 1) == 255
    check target.at8(3, 0) == 0
    check other.at8(0, 0) == 255
    let t2 = newSw(4, 2, ColorSpace.Grayscale8)
    let m2 = newSw(4, 2, ColorSpace.Grayscale8)
    m2.buf8[0] = 255
    t2.compositor = maskCompositor(MaskMethod.Intersect, m2, region(0, 0, 4, 2))
    check rasterShape(t2, polyShape(0, 0, 2, 2, region(0, 0, 4, 2)), region(0, 0, 4, 2), c)
    check t2.at8(0, 0) == 255
    check t2.at8(1, 0) == 0
  test "rect mask uses the color alpha":
    let target = newSw(4, 1, ColorSpace.Grayscale8)
    let other = newSw(4, 1, ColorSpace.Grayscale8)
    target.compositor = maskCompositor(MaskMethod.Add, other, region(0, 0, 4, 1))
    var c = rgba(0, 0, 0, 100)
    check rasterShape(target, rectShape(), region(0, 0, 4, 1), c)
    check target.at8(2, 0) == 100

suite "surface utilities":
  test "clear full and partial":
    let s = newSw(6, 4)
    s.fillAll(White)
    check rasterClear(s, 1, 1, 2, 2)
    check s.at(1, 1) == 0 and s.at(2, 2) == 0
    check s.at(0, 1) == White and s.at(3, 1) == White and s.at(1, 3) == White
    check rasterClear(s, 0, 0, 6, 4)
    for v in s.data: check v == 0
    let g = newSw(4, 4, ColorSpace.Grayscale8)
    g.fillAll8(9)
    check rasterClear(g, 0, 1, 4, 2)
    check g.at8(0, 0) == 9 and g.at8(3, 1) == 0 and g.at8(0, 3) == 9
    check not rasterClear(nil, 0, 0, 1, 1)
  test "premultiply / unpremultiply round trip":
    let s = newSurface(4, 1, ColorSpace.ARGB8888S)
    s.data = @[0x80ff8040'u32, 0xffaabbcc'u32, 0x00ffffff'u32, 0x40c0a080'u32]
    let orig = s.data
    check not s.premultiplied
    rasterPremultiplySurface(s)
    check s.premultiplied
    check s.data[1] == orig[1]
    check alpha(s.data[0]) == 0x80 and ch1(s.data[0]) == 0x7f
    check ch1(s.data[0]) <= alpha(s.data[0])
    rasterPremultiplySurface(s)
    let once = s.data
    rasterUnpremultiplySurface(s)
    check not s.premultiplied
    check s.data[1] == orig[1]
    for i in [0, 3]:
      check alpha(s.data[i]) == alpha(orig[i])
      check abs(int(ch1(s.data[i])) - int(ch1(orig[i]))) <= 4
      check abs(int(ch2(s.data[i])) - int(ch2(orig[i]))) <= 4
      check abs(int(ch3(s.data[i])) - int(ch3(orig[i]))) <= 4
    check once != s.data
  test "convert color space swaps red and blue":
    let s = newSurface(2, 1, ColorSpace.ABGR8888)
    s.data = @[0xff112233'u32, 0x80aabbcc'u32]
    check rasterConvertCS(s, ColorSpace.ARGB8888)
    check s.cs == ColorSpace.ARGB8888
    check s.data == @[0xff332211'u32, 0x80ccbbaa'u32]
    check rasterConvertCS(s, ColorSpace.ARGB8888)
    check not rasterConvertCS(s, ColorSpace.Grayscale8)
    check rasterConvertCS(s, ColorSpace.ABGR8888)
    check s.data == @[0xff112233'u32, 0x80aabbcc'u32]
  test "rasterCompositor installs join and getters":
    let s = newSw(2, 2, ColorSpace.ABGR8888)
    check s.join(1, 2, 3, 4) == 0x04030201'u32
    let a = newSw(2, 2)
    check a.join(1, 2, 3, 4) == 0x04010203'u32
    check a.alphas[0](0x01020304'u32) == 4
    check a.alphas[1](0x01020304'u32) == 251
    let g = SwSurface(cs: ColorSpace.Grayscale8)
    check rasterCompositor(g) == Result.NonSupport

suite "gradient":
  test "linear gradient on a fast-track rect":
    let s = newSw(20, 4)
    let shape = gradientShape(redBlue(), s, true, region(0, 0, 20, 4))
    check rasterGradientShape(s, shape, region(0, 0, 20, 4), redBlue(), 255)
    check nearRed(s.at(0, 0))
    check alpha(s.at(10, 2)) == 255
    check ch1(s.at(19, 3)) < 40 and ch3(s.at(19, 3)) > 215
    for x in 1 ..< 20: check ch1(s.at(x, 0)) <= ch1(s.at(x - 1, 0))
  test "rle gradient equals the rect gradient":
    let a = newSw(20, 4)
    let b = newSw(20, 4)
    let bb = region(0, 0, 20, 4)
    check rasterGradientShape(a, gradientShape(redBlue(), a, true, bb), bb, redBlue(), 255)
    check rasterGradientShape(b, gradientShape(redBlue(), b, false, bb), bb, redBlue(), 255)
    check a.data == b.data
  test "translucent gradient keeps the opaque background alpha":
    let s = newSw(20, 4)
    s.fillAll(White)
    let bb = region(0, 0, 20, 4)
    let f = redBlue(128)
    check rasterGradientShape(s, gradientShape(f, s, true, bb), bb, f, 255)
    check alpha(s.at(0, 0)) == 255
    check s.at(0, 0) != White
    check ch3(s.at(0, 0)) > 100
  test "single stop gradient draws as a solid color with opacity":
    let s = newSw(4, 4)
    var f = linearGradient(0, 0, 4, 0)
    f.stops = @[ColorStop(offset: 0, r: 0, g: 255, b: 0, a: 255)]
    let shape = rectShape()
    check swfill.fillPrepare(shape.fill, f, identity(), s, 255, true)
    check rasterGradientShape(s, shape, region(0, 0, 4, 4), f, 255)
    check s.at(2, 2) == Green
    let s2 = newSw(4, 4)
    check rasterGradientShape(s2, shape, region(0, 0, 4, 4), f, 0)
    check s2.at(2, 2) == 0
  test "gradient without prepared fill is rejected":
    let s = newSw(4, 4)
    check not rasterGradientShape(s, rectShape(), region(0, 0, 4, 4), redBlue(), 255)
    check not rasterGradientStroke(s, SwShape(), region(0, 0, 4, 4), redBlue(), 255)
  test "gradient stroke uses the stroke rle":
    let s = newSw(20, 4)
    let bb = region(0, 0, 20, 4)
    let shape = polyShape(0, 0, 20, 4, bb)
    shape.strokeRle = shape.rle
    shape.rle = nil
    shape.stroke = SwStroke()
    check swfill.fillPrepare(shape.stroke.fill, redBlue(), identity(), s, 255, true)
    check rasterGradientStroke(s, shape, bb, redBlue(), 255)
    check nearRed(s.at(0, 1))
    check ch3(s.at(19, 1)) > 215
  test "gradient with a blender and with a matte":
    let bb = region(0, 0, 20, 4)
    let s = newSw(20, 4)
    s.fillAll(White)
    s.blender = blenderFor(BlendMethod.Multiply)
    check rasterGradientShape(s, gradientShape(redBlue(), s, true, bb), bb, redBlue(), 255)
    check ch2(s.at(5, 1)) == 0 and alpha(s.at(5, 1)) == 255
    let m = newSw(20, 4)
    let mask = newSurface(20, 4, ColorSpace.Grayscale8)
    mask.buf8[0] = 255
    m.compositor = maskCompositor(MaskMethod.Alpha, mask, bb)
    check rasterGradientShape(m, gradientShape(redBlue(), m, false, bb), bb, redBlue(), 255)
    check nearRed(m.at(0, 0))
    check m.at(1, 0) == 0

suite "images":
  test "imagePrepare classifies the transform":
    let img = newImage(4, 4, newSeq[uint32](16))
    var box: Region
    var m = identity()
    m.e13 = 2.0'f32
    m.e23 = 3.0'f32
    check imagePrepare(img, m, region(0, 0, 10, 10), box)
    check img.direct and not img.scaled
    check img.ox == -2 and img.oy == -3
    check box == region(2, 3, 6, 7)
    var big = identity()
    big.e11 = 4.0'f32
    big.e22 = 4.0'f32
    check imagePrepare(img, big, region(0, 0, 10, 10), box)
    check not img.direct and img.scaled and img.scale == 4.0'f32
    check box == region(0, 0, 10, 10)
    var rot = Matrix(e11: 0, e12: -1, e13: 4, e21: 1, e22: 0, e23: 0, e33: 1)
    check imagePrepare(img, rot, region(0, 0, 10, 10), box)
    check not img.direct and not img.scaled
    var far = identity()
    far.e13 = 50.0'f32
    check not imagePrepare(img, far, region(0, 0, 10, 10), box)
  test "direct blit with offset":
    var px = newSeq[uint32](16)
    for i in 0 ..< 16: px[i] = 0xff000000'u32 + uint32(i)
    let img = newImage(4, 4, px)
    img.ox = -2
    img.oy = -3
    let s = newSw(10, 10)
    check rasterDirectImage(s, img, region(2, 3, 6, 7), 255)
    check s.at(2, 3) == px[0]
    check s.at(5, 6) == px[15]
    check s.at(4, 4) == px[6]
    check s.at(1, 3) == 0 and s.at(6, 3) == 0 and s.at(2, 7) == 0
  test "direct blit with opacity and translucent pixels":
    let img = newImage(2, 1, @[0x80800000'u32, Blue])
    let s = newSw(2, 1)
    s.fillAll(Black)
    check rasterDirectImage(s, img, region(0, 0, 2, 1), 255)
    check s.at(0, 0) == 0xff800000'u32
    check s.at(1, 0) == Blue
    s.fillAll(Black)
    check rasterDirectImage(s, img, region(0, 0, 2, 1), 128)
    check alpha(s.at(1, 0)) == 255
    check int(ch3(s.at(1, 0))) in 127 .. 129
  test "alpha ignored image copies the pixels":
    let img = newImage(2, 1, @[0x11223344'u32, 0x55667788'u32])
    img.alphaIgnored = true
    let s = newSw(2, 1)
    check rasterDirectImage(s, img, region(0, 0, 2, 1), 255)
    check s.data == @[0x11223344'u32, 0x55667788'u32]
  test "direct blit to an 8-bit target":
    let img = newImage(2, 1, @[0x80800000'u32, Blue])
    let g = newSw(2, 1, ColorSpace.Grayscale8)
    check rasterDirectImage(g, img, region(0, 0, 2, 1), 255)
    check g.at8(0, 0) == 0x80 and g.at8(1, 0) == 255
  test "direct blit through a matte and a blender":
    let img = newImage(2, 1, @[Red, Red])
    let s = newSw(2, 1)
    let mask = newSurface(2, 1, ColorSpace.Grayscale8)
    mask.buf8[0] = 255
    s.compositor = maskCompositor(MaskMethod.Alpha, mask, region(0, 0, 2, 1))
    check rasterDirectImage(s, img, region(0, 0, 2, 1), 255)
    check s.at(0, 0) == Red and s.at(1, 0) == 0
    let b = newSw(2, 1)
    b.fillAll(White)
    b.blender = blenderFor(BlendMethod.Multiply)
    check rasterDirectImage(b, img, region(0, 0, 2, 1), 255)
    check b.at(0, 0) == Red
    let u = newSw(2, 1)
    u.compositor = maskCompositor(MaskMethod.Add, newSw(2, 1, ColorSpace.Grayscale8),
                                  region(0, 0, 2, 1))
    check not rasterDirectImage(u, img, region(0, 0, 2, 1), 255)
  test "direct rle image honors spans and coverage":
    let img = newImage(8, 4, newSeq[uint32](32))
    for i in 0 ..< 32: img.surface.data[i] = Red
    var box: Region
    var m = identity()
    m.e13 = 1.0'f32
    check imagePrepare(img, m, region(0, 0, 10, 4), box)
    check imageGenRle(img, box, true)
    let s = newSw(10, 4)
    check rasterDirectImage(s, img, box, 255)
    let s2 = newSw(10, 4)
    check rasterDirectRleImage(s2, img, box, 255)
    check s2.at(1, 0) == Red and s2.at(8, 3) == Red and s2.at(0, 0) == 0 and s2.at(9, 0) == 0
    check s2.data == s.data
    imageReset(img)
    check img.rle.spans.len == 0
    check rasterDirectRleImage(s2, img, box, 255)
    let g = newSw(4, 4, ColorSpace.Grayscale8)
    check not rasterDirectRleImage(g, img, box, 255)
  test "scaled nearest and bilinear":
    let img = newImage(2, 2, @[Red, Green, Blue, White])
    var m = identity()
    m.e11 = 4.0'f32
    m.e22 = 4.0'f32
    var box: Region
    check imagePrepare(img, m, region(0, 0, 12, 12), box)
    let s = newSw(12, 12)
    check rasterScaledImage(s, img, m, box, 255)
    check s.at(0, 0) == Red and s.at(7, 0) == Green
    check s.at(0, 7) == Blue and s.at(7, 7) == White
    check s.at(9, 9) == 0
    img.filter = FilterMethod.Bilinear
    let b = newSw(12, 12)
    check rasterScaledImage(b, img, m, box, 255)
    check b.at(0, 0) == Red
    let mid = b.at(5, 0)
    check ch1(mid) > 0 and ch2(mid) > 0
    let h = newSw(12, 12)
    check rasterScaledImage(h, img, m, box, 128)
    check int(alpha(h.at(0, 0))) in 127 .. 129
  test "scaled down box filter":
    var px = newSeq[uint32](64)
    for i in 0 ..< 64: px[i] = Red
    let img = newImage(8, 8, px)
    img.filter = FilterMethod.Bilinear
    var m = identity()
    m.e11 = 0.25'f32
    m.e22 = 0.25'f32
    var box: Region
    check imagePrepare(img, m, region(0, 0, 4, 4), box)
    check img.scale < 0.5'f32
    let s = newSw(4, 4)
    check rasterScaledImage(s, img, m, box, 255)
    check s.at(0, 0) == Red
  test "scaled rle image, matte and blender":
    let img = newImage(2, 2, @[Red, Green, Blue, White])
    var m = identity()
    m.e11 = 4.0'f32
    m.e22 = 4.0'f32
    var box: Region
    check imagePrepare(img, m, region(0, 0, 12, 12), box)
    check imageGenRle(img, box, true)
    let a = newSw(12, 12)
    check rasterScaledRleImage(a, img, m, box, 255)
    check a.at(0, 0) == Red and a.at(7, 7) == White
    let b = newSw(12, 12)
    b.fillAll(White)
    b.blender = blenderFor(BlendMethod.Multiply)
    check rasterScaledRleImage(b, img, m, box, 255)
    check b.at(0, 0) == Red
    let c = newSw(12, 12)
    let mask = newSurface(12, 12, ColorSpace.Grayscale8)
    for i in 0 ..< 12: mask.buf8[i] = 255
    c.compositor = maskCompositor(MaskMethod.Alpha, mask, box)
    check rasterScaledRleImage(c, img, m, box, 255)
    check c.at(0, 0) == Red and c.at(0, 1) == 0
    let d = newSw(12, 12)
    d.compositor = maskCompositor(MaskMethod.Add, newSw(12, 12, ColorSpace.Grayscale8), box)
    check not rasterScaledRleImage(d, img, m, box, 255)
    check not rasterScaledImage(d, img, m, box, 255)
    var singular = Matrix()
    check rasterScaledImage(a, img, singular, box, 255)
  test "rotated image goes through the texture mapper":
    var px = newSeq[uint32](16)
    for i in 0 ..< 16: px[i] = 0xff000000'u32 + uint32(i)
    let img = newImage(4, 4, px)
    let rot = Matrix(e11: 0, e12: -1, e13: 4.5'f32, e21: 1, e22: 0, e23: 0.5'f32, e33: 1)
    let s = newSw(6, 6)
    check rasterTexmapPolygon(s, img, rot, region(0, 0, 6, 6), 255)
    check s.at(3, 0) == px[0]
    check s.at(0, 3) == px[15]
    check s.at(4, 0) == 0 and s.at(0, 4) == 0
