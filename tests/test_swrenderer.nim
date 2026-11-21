## End-to-end tests of the software renderer glue (ported behaviour of
## tvgSwRenderer.cpp + SwCanvas): real Canvas -> Paint tree -> SwRenderer -> pixels.
import std/unittest
import thorvg/core/types
from thorvg/core/fill import linearGradient, Fill
import thorvg/renderer/[render, paint, shape, scene, picture, canvas]
import thorvg/engine/cpu/renderer

proc px(c: Canvas, x, y: int): uint32 =
  let s = swSurface(c)
  s.data[y * int(s.stride) + x]

proc frame(c: Canvas) =
  check c.update() == Result.Success
  check c.draw() == Result.Success
  check c.sync() == Result.Success

proc rectShape(x, y, w, h: float32, r, g, b, a: uint8): Shape =
  result = newShape()
  check result.appendRect(x, y, w, h) == Result.Success
  check result.fill(r, g, b, a) == Result.Success

proc red(c: Canvas, x, y: int): uint32 = (px(c, x, y) shr 16) and 0xFF
proc blue(c: Canvas, x, y: int): uint32 = px(c, x, y) and 0xFF

suite "SwCanvas creation":
  test "bad sizes and color spaces raise":
    expect ValueError: discard newSwCanvas(0, 0)
    expect ValueError: discard newSwCanvas(8, 8, ColorSpace.Grayscale8)

  test "an empty canvas is transparent":
    let c = newSwCanvas(8, 8)
    frame(c)
    let s = swSurface(c)
    check s.w == 8 and s.h == 8
    for p in s.data: check p == 0'u32

suite "shapes":
  test "opaque rect covers exactly its pixels":
    let c = newSwCanvas(20, 20)
    let s = rectShape(5, 5, 10, 10, 255, 0, 0, 255)
    check c.add(s) == Result.Success
    frame(c)
    for y in 0 ..< 20:
      for x in 0 ..< 20:
        let inside = x in 5 .. 14 and y in 5 .. 14
        check px(c, x, y) == (if inside: 0xFFFF0000'u32 else: 0'u32)

  test "translucent fill is premultiplied":
    let c = newSwCanvas(10, 10)
    check c.add(rectShape(0, 0, 10, 10, 255, 0, 0, 128)) == Result.Success
    frame(c)
    check px(c, 4, 4) == 0x80800000'u32

  test "shape opacity scales the color":
    let c = newSwCanvas(10, 10)
    let s = rectShape(0, 0, 10, 10, 255, 0, 0, 255)
    check s.opacity(128) == Result.Success
    check c.add(s) == Result.Success
    frame(c)
    check px(c, 4, 4) == 0x80800000'u32

  test "circle with a linear gradient":
    let c = newSwCanvas(40, 40)
    let s = newShape()
    check s.appendCircle(20, 20, 18, 18) == Result.Success
    var g = linearGradient(0, 0, 40, 0)
    g.stops = @[ColorStop(offset: 0, r: 255, g: 0, b: 0, a: 255),
                ColorStop(offset: 1, r: 0, g: 0, b: 255, a: 255)]
    check s.fill(g) == Result.Success
    check c.add(s) == Result.Success
    frame(c)
    check px(c, 0, 0) == 0'u32
    check px(c, 39, 39) == 0'u32
    check px(c, 20, 20) shr 24 == 0xFF'u32
    check red(c, 6, 20) > red(c, 20, 20)
    check red(c, 20, 20) > red(c, 34, 20)
    check blue(c, 6, 20) < blue(c, 20, 20)
    check blue(c, 20, 20) < blue(c, 34, 20)

  test "stroked line":
    let c = newSwCanvas(20, 20)
    let s = newShape()
    check s.moveTo(5, 10) == Result.Success
    check s.lineTo(15, 10) == Result.Success
    check s.strokeWidth(4) == Result.Success
    check s.strokeCap(StrokeCap.Butt) == Result.Success
    check s.strokeFill(0, 255, 0, 255) == Result.Success
    check c.add(s) == Result.Success
    frame(c)
    for y in 0 ..< 20:
      for x in 0 ..< 20:
        let inside = x in 5 .. 14 and y in 8 .. 11
        check px(c, x, y) == (if inside: 0xFF00FF00'u32 else: 0'u32)

  test "fill and stroke with opacity are composited as one":
    let c = newSwCanvas(30, 30)
    let s = newShape()
    check s.appendRect(8, 8, 14, 14) == Result.Success
    check s.fill(255, 0, 0, 255) == Result.Success
    check s.strokeWidth(4) == Result.Success
    check s.strokeFill(255, 0, 0, 255) == Result.Success
    check s.opacity(128) == Result.Success
    check c.add(s) == Result.Success
    frame(c)
    check px(c, 15, 15) == 0x80800000'u32
    check px(c, 6, 15) == 0x80800000'u32
    check px(c, 1, 1) == 0'u32

  test "redraw after a color change":
    let c = newSwCanvas(10, 10)
    let s = rectShape(0, 0, 10, 10, 255, 0, 0, 255)
    check c.add(s) == Result.Success
    frame(c)
    check px(c, 3, 3) == 0xFFFF0000'u32
    check s.fill(0, 0, 255, 255) == Result.Success
    frame(c)
    check px(c, 3, 3) == 0xFF0000FF'u32

  test "blend Add":
    let c = newSwCanvas(10, 10)
    check c.add(rectShape(0, 0, 10, 10, 100, 0, 0, 255)) == Result.Success
    let top = rectShape(0, 0, 10, 10, 50, 50, 0, 255)
    check top.blend(BlendMethod.Add) == Result.Success
    check c.add(top) == Result.Success
    frame(c)
    check px(c, 5, 5) == 0xFF963200'u32

suite "composition":
  test "scene opacity composites its children":
    let c = newSwCanvas(30, 30)
    let sc = newScene()
    check sc.add(rectShape(0, 0, 20, 20, 255, 0, 0, 255)) == Result.Success
    check sc.add(rectShape(10, 10, 20, 20, 0, 0, 255, 255)) == Result.Success
    check sc.opacity(128) == Result.Success
    check c.add(sc) == Result.Success
    frame(c)
    check px(c, 5, 5) == 0x80800000'u32
    check px(c, 15, 15) == 0x80000080'u32
    check px(c, 25, 25) == 0x80000080'u32
    check px(c, 25, 5) == 0'u32

  test "circle clip path":
    let c = newSwCanvas(40, 40)
    let s = rectShape(0, 0, 40, 40, 255, 0, 0, 255)
    let clp = newShape()
    check clp.appendCircle(20, 20, 12, 12) == Result.Success
    check s.clip(clp) == Result.Success
    check c.add(s) == Result.Success
    frame(c)
    check px(c, 1, 1) == 0'u32
    check px(c, 38, 38) == 0'u32
    check px(c, 20, 20) == 0xFFFF0000'u32

  test "rect clip path":
    let c = newSwCanvas(20, 20)
    let s = rectShape(0, 0, 20, 20, 255, 0, 0, 255)
    let clp = newShape()
    check clp.appendRect(5, 5, 8, 8) == Result.Success
    check s.clip(clp) == Result.Success
    check c.add(s) == Result.Success
    frame(c)
    for y in 0 ..< 20:
      for x in 0 ..< 20:
        let inside = x in 5 .. 12 and y in 5 .. 12
        check px(c, x, y) == (if inside: 0xFFFF0000'u32 else: 0'u32)

  test "alpha mask":
    let c = newSwCanvas(40, 40)
    let s = rectShape(0, 0, 40, 40, 255, 0, 0, 255)
    let m = newShape()
    check m.appendCircle(20, 20, 10, 10) == Result.Success
    check m.fill(0, 0, 0, 255) == Result.Success
    check s.mask(m, MaskMethod.Alpha) == Result.Success
    check c.add(s) == Result.Success
    frame(c)
    check px(c, 1, 1) == 0'u32
    check px(c, 38, 2) == 0'u32
    check px(c, 20, 20) == 0xFFFF0000'u32

suite "pictures":
  test "raw picture is blitted":
    let c = newSwCanvas(12, 12)
    let pic = newPicture()
    var pix = newSeq[uint32](16)
    for i in 0 ..< 16: pix[i] = 0xFF112233'u32
    pix[0] = 0xFFAABBCC'u32
    check pic.loadRaw(pix, 4, 4, ColorSpace.ARGB8888) == Result.Success
    check pic.translate(3, 3) == Result.Success
    check c.add(pic) == Result.Success
    frame(c)
    check px(c, 3, 3) == 0xFFAABBCC'u32
    check px(c, 4, 4) == 0xFF112233'u32
    check px(c, 6, 6) == 0xFF112233'u32
    check px(c, 7, 7) == 0'u32
    check px(c, 2, 2) == 0'u32

  test "scaled raw picture":
    let c = newSwCanvas(12, 12)
    let pic = newPicture()
    let pix = @[0xFF336699'u32, 0xFF336699'u32, 0xFF336699'u32, 0xFF336699'u32]
    check pic.loadRaw(pix, 2, 2, ColorSpace.ARGB8888) == Result.Success
    check pic.scale(2) == Result.Success
    check c.add(pic) == Result.Success
    frame(c)
    check px(c, 0, 0) == 0xFF336699'u32
    check px(c, 3, 3) == 0xFF336699'u32
    check px(c, 4, 4) == 0'u32

suite "color spaces":
  test "ABGR8888 swaps red and blue":
    let c = newSwCanvas(6, 6, ColorSpace.ABGR8888)
    check c.add(rectShape(0, 0, 6, 6, 255, 0, 0, 255)) == Result.Success
    frame(c)
    check px(c, 2, 2) == 0xFF0000FF'u32

  test "ARGB8888S is unpremultiplied after the frame":
    let c = newSwCanvas(6, 6, ColorSpace.ARGB8888S)
    check c.add(rectShape(0, 0, 6, 6, 255, 0, 0, 128)) == Result.Success
    frame(c)
    check px(c, 2, 2) == 0x80FF0000'u32
