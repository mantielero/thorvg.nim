## Tests of the texture-mapped (rotated / sheared / scaled) image rasterizer
## (tvgSwRasterTexmap.h): pixel permutations, coverage, opacity, clipping, composition
## variants and the renderer wiring. Bit-exactness against the C++ original is checked by
## the `pngrot_*` parity cases (tests\parity).
import std/[unittest, math, sequtils]
import thorvg/core/[types, geom]
import thorvg/renderer/[render, paint, picture, canvas]
import thorvg/engine/cpu/[common, pixel, blend, raster, renderer]

const
  Red = 0xffff0000'u32
  White = 0xffffffff'u32

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

proc newImage(w, h: int, pixels: seq[uint32],
              filter = FilterMethod.Nearest): SwImage =
  let s = newSurface(uint32(w), uint32(h))
  s.data = pixels
  SwImage(surface: s, w: uint32(w), h: uint32(h), stride: uint32(w), channelSize: 4,
          filter: filter, scale: 1.0'f32)

func solid(w, h: int, c: uint32): seq[uint32] = newSeqWith(w * h, c)

func at(s: RenderSurface, x, y: int): uint32 = s.data[y * int(s.stride) + x]

func rotation(deg, scale, cx, cy, w, h: float32): Matrix =
  ## Rotation and scale of a w x h image about the point (cx, cy) of the target.
  let a = deg * MathPi / 180.0'f32
  let c = cos(a) * scale
  let s = sin(a) * scale
  Matrix(e11: c, e12: -s, e13: cx - (c * w * 0.5'f32 - s * h * 0.5'f32),
         e21: s, e22: c, e23: cy - (s * w * 0.5'f32 + c * h * 0.5'f32), e33: 1.0'f32)

func nonzero(s: RenderSurface): int =
  for p in s.data:
    if p != 0: inc result

func alphaSum(s: RenderSurface): float =
  for p in s.data: result += float(alpha(p)) / 255.0

func bounds(s: RenderSurface): Region =
  ## Pixel box of everything that was drawn (xMax/yMax exclusive).
  result = region(int(s.w), int(s.h), 0, 0)
  for y in 0 ..< int(s.h):
    for x in 0 ..< int(s.w):
      if s.at(x, y) != 0:
        result.xMin = min(result.xMin, int32(x))
        result.yMin = min(result.yMin, int32(y))
        result.xMax = max(result.xMax, int32(x + 1))
        result.yMax = max(result.yMax, int32(y + 1))

suite "texmap geometry":
  test "90 degree rotation is a pixel permutation":
    # x' = -y + h + 0.5, y' = x + 0.5: the half pixel shift keeps every texel on its own pixel
    for (w, h) in [(4, 4), (7, 5), (3, 8)]:
      var px = newSeq[uint32](w * h)
      for i in 0 ..< px.len: px[i] = 0xff000000'u32 + uint32(i + 1)
      let img = newImage(w, h, px)
      let m = Matrix(e11: 0, e12: -1, e13: float32(h) + 0.5'f32, e21: 1, e22: 0, e23: 0.5'f32, e33: 1)
      let s = newSw(h + 2, w + 2)
      check rasterTexmapPolygon(s, img, m, region(0, 0, h + 2, w + 2), 255)
      for sy in 0 ..< h:
        for sx in 0 ..< w:
          check s.at(h - 1 - sy, sx) == px[sy * w + sx]
      check nonzero(s) == w * h

  test "integer aligned vertices start one row late (upstream pre-stepping)":
    var px = newSeq[uint32](16)
    for i in 0 ..< 16: px[i] = 0xff000000'u32 + uint32(i + 1)
    let m = Matrix(e11: 0, e12: -1, e13: 4, e21: 1, e22: 0, e23: 0, e33: 1)
    let s = newSw(6, 6)
    check rasterTexmapPolygon(s, newImage(4, 4, px), m, region(0, 0, 6, 6), 255)
    check s.at(3, 0) == px[1] and s.at(0, 0) == px[13]
    check s.at(3, 2) == px[3] and s.at(0, 3) == 0

  test "45 degree rotation: bounds and coverage":
    let s = newSw(32, 32)
    let m = rotation(45, 1, 16, 16, 8, 8)
    check rasterTexmapPolygon(s, newImage(8, 8, solid(8, 8, White)), m, region(0, 0, 32, 32), 255)
    let b = bounds(s)
    check b.xMin >= 10 and b.xMax <= 23 and b.yMin >= 10 and b.yMax <= 23
    check b.xMax - b.xMin >= 11 and b.yMax - b.yMin >= 11
    check nonzero(s) in 55 .. 75
    check alphaSum(s) in 45.0 .. 70.0   # edge texels are feathered, not area weighted
    for (x, y) in [(15, 15), (16, 15), (15, 16), (16, 16), (16, 13), (13, 16)]:
      check s.at(x, y) == White
    check s.at(10, 10) == 0 and s.at(21, 21) == 0

  test "scale and rotate":
    let s = newSw(64, 64)
    let m = rotation(30, 2, 32, 32, 8, 6)
    check rasterTexmapPolygon(s, newImage(8, 6, solid(8, 6, Red)), m, region(0, 0, 64, 64), 255)
    check nonzero(s) in 170 .. 215
    check alphaSum(s) in 120.0 .. 200.0
    var cx, cy, tot = 0.0
    for y in 0 ..< 64:
      for x in 0 ..< 64:
        let a = float(alpha(s.at(x, y)))
        cx += a * (float(x) + 0.5)
        cy += a * (float(y) + 0.5)
        tot += a
    check abs(cx / tot - 32.0) < 1.0 and abs(cy / tot - 32.0) < 1.0

  test "shear keeps the parallelogram area":
    let s = newSw(40, 24)
    let m = Matrix(e11: 1, e12: 0.5'f32, e13: 4, e21: 0, e22: 1, e23: 4, e33: 1)
    check rasterTexmapPolygon(s, newImage(10, 8, solid(10, 8, White)), m, region(0, 0, 40, 24), 255)
    check alphaSum(s) in 60.0 .. 90.0
    check s.at(10, 8) == White and s.at(4, 6) == 0

  test "degenerate transforms draw nothing":
    let s = newSw(8, 8)
    let img = newImage(4, 4, solid(4, 4, White))
    check rasterTexmapPolygon(s, img, Matrix(e11: 0, e22: 0, e33: 1), region(0, 0, 8, 8), 255)
    check rasterTexmapPolygon(s, img, Matrix(e11: 1, e12: 1, e13: 2, e21: 1, e22: 1, e23: 2,
                                             e33: 1), region(0, 0, 8, 8), 255)
    check nonzero(s) == 0

suite "texmap pixels":
  test "bilinear filter blends neighbours, nearest does not":
    var px = newSeq[uint32](64)  # vertical black / white stripes
    for i in 0 ..< 64: px[i] = if i mod 2 == 0: 0xff000000'u32 else: White
    let m = rotation(10, 3, 16, 16, 8, 8)
    let a = newSw(32, 32)
    let b = newSw(32, 32)
    check rasterTexmapPolygon(a, newImage(8, 8, px, FilterMethod.Nearest), m,
                              region(0, 0, 32, 32), 255)
    check rasterTexmapPolygon(b, newImage(8, 8, px, FilterMethod.Bilinear), m,
                              region(0, 0, 32, 32), 255)
    func greys(s: RenderSurface): int =
      for p in s.data:  # opaque (non feathered) pixels that are neither black nor white
        if alpha(p) == 255 and p != White and p != 0xff000000'u32: inc result
    check greys(a) == 0
    check greys(b) > 0

  test "opacity scales the image":
    let s = newSw(32, 32)
    s.data[16 * 32 + 16] = 0xff0000ff'u32
    let m = rotation(30, 2, 16, 16, 8, 8)
    check rasterTexmapPolygon(s, newImage(8, 8, solid(8, 8, White)), m, region(0, 0, 32, 32), 128)
    let c = s.at(16, 16)
    check alpha(c) == 255  # over an opaque pixel
    check ch3(c) == 255 and ch1(c) == 128
    let d = newSw(32, 32)
    check rasterTexmapPolygon(d, newImage(8, 8, solid(8, 8, White)), m, region(0, 0, 32, 32), 128)
    check alpha(d.at(14, 16)) == 128

  test "clipping at the surface edges and at the bbox":
    let img = newImage(20, 20, solid(20, 20, White))
    let m = rotation(30, 1, 5, 5, 20, 20)  # hangs over the top left corner
    let s = newSw(12, 12)
    check rasterTexmapPolygon(s, img, m, region(0, 0, 12, 12), 255)
    check nonzero(s) == 144
    check s.at(0, 0) == White and s.at(5, 5) == White
    let t = newSw(12, 12)
    check rasterTexmapPolygon(t, img, m, region(3, 2, 9, 8), 255)
    for y in 0 ..< 12:
      for x in 0 ..< 12:
        if x in 4 .. 7 and y in 3 .. 6: check t.at(x, y) == White
        elif x notin 3 .. 8 or y notin 2 .. 7: check t.at(x, y) == 0
    check nonzero(t) == 36

  test "image fully outside draws nothing and does not raise":
    let s = newSw(8, 8)
    let m = rotation(30, 1, 100, 100, 4, 4)
    check rasterTexmapPolygon(s, newImage(4, 4, solid(4, 4, White)), m, region(0, 0, 8, 8), 255)
    check nonzero(s) == 0

  test "grayscale target receives alpha * opacity":
    let s = newSw(16, 16, ColorSpace.Grayscale8)
    let m = rotation(30, 2, 8, 8, 4, 4)
    check rasterTexmapPolygon(s, newImage(4, 4, solid(4, 4, White)), m, region(0, 0, 16, 16), 128)
    check s.buf8[8 * 16 + 8] == 128

  test "blender is used when set":
    let s = newSw(16, 16)
    for i in 0 ..< s.data.len: s.data[i] = White
    s.blender = blenderFor(BlendMethod.Multiply)
    let m = rotation(30, 2, 8, 8, 4, 4)
    check rasterTexmapPolygon(s, newImage(4, 4, solid(4, 4, Red)), m, region(0, 0, 16, 16), 255)
    check s.at(8, 8) == Red   # multiply(red, white)
    check s.at(0, 0) == White

  test "alpha matte limits the drawing":
    let s = newSw(16, 16)
    let mask = newSurface(16, 16, ColorSpace.Grayscale8)
    for y in 0 ..< 16:
      for x in 0 ..< 8: mask.buf8[y * 16 + x] = 255
    let img = SwImage(surface: mask, stride: 16, w: 16, h: 16, channelSize: 1)
    s.compositor = SwCompositor(meth: MaskMethod.Alpha, image: img, valid: true,
                                bbox: region(0, 0, 16, 16))
    let m = rotation(30, 3, 8, 8, 4, 4)
    check rasterTexmapPolygon(s, newImage(4, 4, solid(4, 4, Red)), m, region(0, 0, 16, 16), 255)
    check s.at(6, 8) == Red and s.at(10, 8) == 0
    # composition without a matte (mask operators) is not implemented upstream either
    let u = newSw(16, 16)
    u.compositor = SwCompositor(meth: MaskMethod.Add, image: img, valid: true)
    check rasterTexmapPolygon(u, newImage(4, 4, solid(4, 4, Red)), m, region(0, 0, 16, 16), 255)
    check nonzero(u) == 0

suite "texmap through the renderer":
  proc raw(w, h: int, c: uint32): Picture =
    result = newPicture()
    check result.loadRaw(solid(w, h, c), uint32(w), uint32(h), ColorSpace.ARGB8888) ==
      Result.Success

  test "rotated picture":
    let c = newSwCanvas(40, 40)
    let pic = raw(10, 10, 0xff336699'u32)
    check pic.translate(20, 20) == Result.Success
    check pic.rotate(45) == Result.Success
    check c.add(pic) == Result.Success
    check c.update() == Result.Success and c.draw() == Result.Success and c.sync() == Result.Success
    let s = swSurface(c)
    check s.at(20, 24) == 0xff336699'u32
    check alphaSum(s) in 75.0 .. 105.0
    let b = bounds(s)
    check b.xMin >= 12 and b.xMax <= 28 and b.yMin >= 19 and b.yMax <= 36

  test "rotated picture with opacity":
    let c = newSwCanvas(40, 40)
    let pic = raw(10, 10, White)
    check pic.translate(20, 5) == Result.Success
    check pic.rotate(90) == Result.Success
    check pic.opacity(128) == Result.Success
    check c.add(pic) == Result.Success
    check c.update() == Result.Success and c.draw() == Result.Success and c.sync() == Result.Success
    let s = swSurface(c)
    check s.at(15, 7) == 0x80808080'u32
    check s.at(25, 7) == 0
