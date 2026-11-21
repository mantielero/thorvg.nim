## Scene effects (ported behaviour of tvgSwPostEffect.cpp / Scene::add(SceneEffect)):
## blur, drop shadow, fill, tint, tritone and motion blur through the software canvas.
import std/unittest
import thorvg/core/types
import thorvg/renderer/[render, shape, scene, canvas, effect]
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

proc channel(c: uint32, shift: int): int = int((c shr uint32(shift)) and 0xff'u32)

proc near(a, b: uint32, tol = 4): bool =
  ## Per-channel closeness: a single direct composition interpolates with 255/256 (twice for tint).
  for sh in [0, 8, 16, 24]:
    if abs(channel(a, sh) - channel(b, sh)) > tol: return false
  true

proc sceneWith(c: Canvas, x, y, w, h: float32, r, g, b, a: uint8): Scene =
  result = newScene()
  check result.add(rectShape(x, y, w, h, r, g, b, a)) == Result.Success
  check c.add(result) == Result.Success

proc alphaSum(c: Canvas, w, h: int): int =
  for y in 0 ..< h:
    for x in 0 ..< w: result += channel(px(c, x, y), 24)

suite "effect description":
  test "gen clamps its arguments like upstream":
    let b = genGaussianBlur(-3.0, 9, 5, 500)
    check b.sigma == 0.0'f32 and b.direction == 2 and b.border == 1 and b.quality == 100
    check genTint(0, 0, 0, 255, 255, 255, 100.0).intensity == 255
    check genMotionBlur(-1.0, 270.0, 100).angle == 90.0'f32
    check genMotionBlur(-1.0, 270.0, 100).distance == 0.0'f32
    check genFill(256 + 7, 0, 0, 255).color[0] == 7

  test "duplicate drops the engine data":
    let e = genDropShadow(1, 2, 3, 4, 45.0, 6.0, 2.0, 80)
    e.valid = true
    let d = DropShadowEffect(e.duplicate())
    check d.kind == SceneEffect.DropShadow and d.color == [1'u8, 2, 3, 4]
    check d.rd == nil and not d.valid and d.sigma == 2.0'f32

suite "gaussian blur":
  test "blurs a hard edged rect symmetrically and expands the region":
    let c = newSwCanvas(60, 40)
    let s = sceneWith(c, 20, 10, 20, 20, 255, 0, 0, 255)
    check s.gaussianBlur(2.0, 0, 0, 100) == Result.Success
    frame(c)
    # the original edge pixels are no longer opaque, the outside got some alpha
    check channel(px(c, 20, 20), 24) < 255 and channel(px(c, 20, 20), 24) > 0
    check channel(px(c, 18, 20), 24) > 0
    check px(c, 30, 20) == 0xFFFF0000'u32
    for d in 0 ..< 6:  # symmetric falloff around the left/right and top/bottom edges
      check abs(channel(px(c, 19 - d, 20), 24) - channel(px(c, 40 + d, 20), 24)) <= 1
      check abs(channel(px(c, 30, 9 - d), 24) - channel(px(c, 30, 30 + d), 24)) <= 1
    # the alpha mass is roughly preserved (truncation loses a little)
    let total = alphaSum(c, 60, 40)
    check total <= 400 * 255 and total > 400 * 255 * 95 div 100

  test "horizontal only blur leaves the rows untouched":
    let c = newSwCanvas(60, 40)
    let s = sceneWith(c, 20, 10, 20, 20, 255, 0, 0, 255)
    check s.gaussianBlur(2.0, 1, 0, 100) == Result.Success
    frame(c)
    check channel(px(c, 19, 20), 24) > 0
    check px(c, 30, 9) == 0'u32 and px(c, 30, 30) == 0'u32
    check px(c, 30, 10) == 0xFFFF0000'u32

  test "a zero sigma is not applied":
    let c = newSwCanvas(30, 30)
    let s = sceneWith(c, 5, 5, 10, 10, 0, 255, 0, 255)
    check s.gaussianBlur(0.0, 0, 0, 100) == Result.Success
    frame(c)
    check px(c, 5, 5) == 0xFF00FF00'u32 and px(c, 4, 5) == 0'u32

  test "clearEffects removes the effects":
    let c = newSwCanvas(30, 30)
    let s = sceneWith(c, 5, 5, 10, 10, 0, 255, 0, 255)
    check s.gaussianBlur(3.0, 0, 0, 100) == Result.Success
    check s.clearEffects() == Result.Success
    frame(c)
    check px(c, 5, 5) == 0xFF00FF00'u32 and px(c, 4, 5) == 0'u32

suite "drop shadow":
  test "the shadow is offset and the body stays on top":
    let c = newSwCanvas(60, 60)
    let s = sceneWith(c, 10, 10, 20, 20, 255, 0, 0, 255)
    # angle 90 + distance: the offset direction is (cos(0), -sin(0)) = to the right
    check s.dropShadow(0, 0, 255, 255, 90.0, 10.0, 0.0, 100) == Result.Success
    frame(c)
    check px(c, 15, 15) == 0xFFFF0000'u32               # body on top
    check px(c, 35, 15) == 0xFF0000FF'u32               # shadow shifted by 10 px
    check px(c, 39, 15) == 0xFF0000FF'u32
    check px(c, 41, 15) == 0'u32
    check px(c, 35, 5) == 0'u32

  test "a blurred shadow fades out":
    let c = newSwCanvas(80, 80)
    let s = sceneWith(c, 20, 20, 20, 20, 255, 255, 255, 255)
    check s.dropShadow(0, 0, 0, 255, 180.0, 8.0, 2.0, 100) == Result.Success
    frame(c)
    check px(c, 30, 30) == 0xFFFFFFFF'u32
    let below = [channel(px(c, 30, 41), 24), channel(px(c, 30, 44), 24),
                 channel(px(c, 30, 47), 24), channel(px(c, 30, 52), 24)]
    check below[0] > below[1] and below[1] > below[2] and below[2] > below[3]
    check below[0] > 0

  test "a transparent shadow color is not valid":
    let c = newSwCanvas(30, 30)
    let s = sceneWith(c, 5, 5, 10, 10, 255, 0, 0, 255)
    check s.dropShadow(0, 0, 0, 0, 90.0, 5.0, 1.0, 100) == Result.Success
    frame(c)
    check px(c, 5, 5) == 0xFFFF0000'u32 and px(c, 16, 5) == 0'u32

suite "color effects":
  test "fill recolors keeping the alpha":
    let c = newSwCanvas(20, 20)
    let s = sceneWith(c, 5, 5, 10, 10, 255, 0, 0, 255)
    check s.fill(0, 255, 0, 255) == Result.Success
    frame(c)
    check px(c, 8, 8) == 0xFF00FF00'u32 and px(c, 2, 2) == 0'u32

  test "fill with a translucent color":
    let c = newSwCanvas(20, 20)
    let s = sceneWith(c, 5, 5, 10, 10, 255, 0, 0, 255)
    check s.fill(0, 0, 255, 128) == Result.Success
    frame(c)
    check channel(px(c, 8, 8), 24) == 128 and channel(px(c, 8, 8), 0) == 128

  test "tint maps black and white":
    let c = newSwCanvas(30, 30)
    let sc = newScene()
    check sc.add(rectShape(0, 0, 10, 30, 0, 0, 0, 255)) == Result.Success
    check sc.add(rectShape(10, 0, 10, 30, 255, 255, 255, 255)) == Result.Success
    check c.add(sc) == Result.Success
    check sc.tint(255, 0, 0, 0, 0, 255, 100.0) == Result.Success
    frame(c)
    check near(px(c, 5, 5), 0xFFFF0000'u32)   # black -> red
    check near(px(c, 15, 5), 0xFF0000FF'u32)  # white -> blue
    check px(c, 25, 5) == 0'u32

  test "zero intensity tint is skipped":
    let c = newSwCanvas(20, 20)
    let s = sceneWith(c, 0, 0, 10, 10, 10, 20, 30, 255)
    check s.tint(255, 0, 0, 0, 0, 255, 0.0) == Result.Success
    frame(c)
    check px(c, 5, 5) == 0xFF0A141E'u32

  test "tritone maps shadow, midtone and highlight":
    let c = newSwCanvas(40, 20)
    let sc = newScene()
    check sc.add(rectShape(0, 0, 10, 20, 0, 0, 0, 255)) == Result.Success
    check sc.add(rectShape(10, 0, 10, 20, 255, 255, 255, 255)) == Result.Success
    check c.add(sc) == Result.Success
    check sc.tritone([255, 0, 0], [0, 255, 0], [0, 0, 255], 0) == Result.Success
    frame(c)
    check near(px(c, 5, 5), 0xFFFF0000'u32)
    check near(px(c, 15, 5), 0xFF0000FF'u32)

  test "effects chain in order":
    let c = newSwCanvas(30, 30)
    let s = sceneWith(c, 10, 10, 10, 10, 255, 0, 0, 255)
    check s.fill(0, 255, 0, 255) == Result.Success
    check s.tint(0, 0, 0, 255, 255, 255, 100.0) == Result.Success
    frame(c)
    check px(c, 14, 14) == 0xFFB6B6B6'u32 or channel(px(c, 14, 14), 24) == 255

suite "motion blur":
  test "a horizontal blur spreads along x only":
    let c = newSwCanvas(60, 40)
    let s = sceneWith(c, 20, 10, 20, 20, 255, 255, 255, 255)
    check s.motionBlur(10.0, 0.0, 100) == Result.Success
    frame(c)
    check px(c, 30, 20) == 0xFFFFFFFF'u32
    check channel(px(c, 17, 20), 24) > 0 and channel(px(c, 17, 20), 24) < 255
    check channel(px(c, 42, 20), 24) > 0
    check px(c, 30, 8) == 0'u32 and px(c, 30, 31) == 0'u32
    check abs(channel(px(c, 19, 20), 24) - channel(px(c, 40, 20), 24)) <= 2

  test "a zero distance is not applied":
    let c = newSwCanvas(30, 30)
    let s = sceneWith(c, 5, 5, 10, 10, 0, 255, 0, 255)
    check s.motionBlur(0.0, 45.0, 100) == Result.Success
    frame(c)
    check px(c, 5, 5) == 0xFF00FF00'u32 and px(c, 4, 5) == 0'u32
