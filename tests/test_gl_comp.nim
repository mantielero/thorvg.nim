## G4b: GL renderer target / sync / composition / effect hooks (renderer_comp.nim and
## renderer_sync.nim). Needs a GL 3.3 context from wgl_ffi; exits 0 with a message when none
## can be created.
## The real `sync` replaces the test-only `present` of test_gl_renderer: frames go through
## `RenderMethod` calls (low level tests) or through a real `Canvas` (scene tests: opacity, masks,
## clips, blend, effects), and the user framebuffer is read back.
import std/unittest
import thorvg/core/[types, geom, path]
import thorvg/renderer/[render, effect, canvas, shape, scene, paint]
import thorvg/engine/gl/[renderer_sync, gl_ffi, wgl_ffi, render_target]

const
  W = 32'i32
  H = 32'i32
  Abgr = ColorSpace.ABGR8888S

let (created, ctxInit) = wglCreateOffscreen(int(W), int(H))
if not created:
  echo "SKIP: no GL 3.3 context could be created"
  quit(0)

var ctx = ctxInit
let baseline = glLiveObjects()

func pt(x, y: float32): Point = Point(x: x, y: y)

func chan(px: uint32, shift: int): int = int((px shr shift) and 0xff'u32)
func rr(px: uint32): int = chan(px, 0)
func gg(px: uint32): int = chan(px, 8)
func bb(px: uint32): int = chan(px, 16)
func aa(px: uint32): int = chan(px, 24)

type Frame = object
  px: seq[uint32]
  w, h: int

func at(f: Frame, x, y: int): uint32 =
  ## Pixel (x, y) with y counted from the top.
  f.px[(f.h - 1 - y) * f.w + x]

proc readFbo(fbo: GlId, w, h: int): Frame =
  bindFramebuffer(GlReadFramebuffer, fbo)
  result = Frame(w: w, h: h)
  readPixels(0, 0, int32(w), int32(h), result.px)

proc rectShape(x, y, w, h: float32, r, g, b, a: uint8): Shape =
  result = newShape()
  discard result.appendRect(x, y, w, h)
  discard result.fill(r, g, b, a)

type Env = object
  r: GlRenderer
  c: Canvas

proc newEnv(): Env =
  let r = newGlTargetRenderer(ctx.dc, ctx.rc, ctx.fbo, int(W), int(H))
  doAssert r != nil
  let c = newCanvas(r)
  doAssert c.retarget(uint32(W), uint32(H), Abgr) == Result.Success
  Env(r: r, c: c)

proc frame(e: Env, clear = true): Frame =
  check e.c.update() == Result.Success
  check e.c.draw(clear) == Result.Success
  check e.c.sync() == Result.Success
  check getError() == GlNoError
  readFbo(ctx.fbo, int(W), int(H))

proc finish(e: Env) =
  discard e.c.remove(nil)
  e.r.destroy()

suite "RenderMethod contract":
  test "every GL method is overridden (dynamic dispatch reaches the GL implementation)":
    let r = newGlTargetRenderer(ctx.dc, ctx.rc, ctx.fbo, int(W), int(H))
    check r != nil
    let m: RenderMethod = r
    check m.colorSpace() == Abgr
    check m.mainSurface() != nil and m.mainSurface().w == uint32(W)
    check m.blend(BlendMethod.Multiply) and m.blend(BlendMethod.Normal)
    check m.clear() and r.mClearBuffer
    check m.sync()  # empty pass stack: nothing to do
    check m.target(initRegion(0, 0, 8, 8), Abgr, {CompositionFlag.Opacity}) == nil
    check not m.beginComposite(nil, MaskMethod.None, 255) and not m.endComposite(nil)
    check m.preUpdate() and m.postUpdate() and m.preRender() and m.postRender()
    let cmp = m.target(initRegion(0, 0, 40, 40), Abgr, {CompositionFlag.Opacity})
    check cmp != nil and GlCompositor(cmp).bbox == initRegion(0, 0, W, H)
    check m.beginComposite(cmp, MaskMethod.None, 200)
    check r.passStack.len == 2 and GlCompositor(cmp).opacity == 200
    check not m.endComposite(RenderCompositor())  # not the last compositor
    check m.endComposite(cmp) and r.passStack.len == 1 and r.composeStack.len == 0
    check m.sync() and r.passStack.len == 0 and not r.mClearBuffer
    r.destroy()

  test "effect hooks: prepare, region, dispose":
    let r = newGlTargetRenderer(ctx.dc, ctx.rc, ctx.fbo, int(W), int(H))
    let m: RenderMethod = r
    let e = genGaussianBlur(2.0, 0, 0, 100)
    check not m.effectRegion(e)  # never prepared
    m.effectPrepare(e, IdentityMatrix)
    check e.valid and e.rd != nil and r.blendPool.len == 2
    check m.effectRegion(e) and e.extend.xMax == 4 and e.extend.yMin == -4
    check not m.effectRender(nil, e, true)  # no pass yet
    m.effectDispose(e)
    check e.rd == nil
    check not m.effectRegion(e)
    r.destroy()

suite "target":
  test "argument checks and results":
    let r = newGlTargetRenderer(ctx.dc, ctx.rc, ctx.fbo, int(W), int(H))
    check r.target(0, ctx.dc, ctx.rc, ctx.fbo, uint32(W), uint32(H),
      ColorSpace.ARGB8888) == Result.NonSupport
    check r.target(0, ctx.dc, 0, ctx.fbo, uint32(W), uint32(H), Abgr) == Result.InvalidArguments
    check r.target(0, ctx.dc, ctx.rc, ctx.fbo, 0, uint32(H), Abgr) == Result.InvalidArguments
    check r.target(0, ctx.dc, ctx.rc, ctx.fbo, uint32(W), 0, Abgr) == Result.InvalidArguments
    check r.target(0, ctx.dc, ctx.rc, ctx.fbo, uint32(W), uint32(H), Abgr) == Result.Success
    check r.surface.w == uint32(W) and r.surface.cs == Abgr and r.vport == initRegion(0, 0, W, H)
    check r.rootTarget.width == uint32(W) and not r.rootTarget.invalid
    check newGlTargetRenderer(ctx.dc, ctx.rc, ctx.fbo, 0, 8) == nil
    r.destroy()
    check getError() == GlNoError

  test "a renderer without target refuses to render":
    let r = newGlRenderer()
    check not r.preUpdate() and not r.preRender() and not r.clear()
    r.destroy()

suite "sync":
  test "a rectangle through prepare / preRender / renderShape / postRender / sync":
    let r = newGlTargetRenderer(ctx.dc, ctx.rc, ctx.fbo, int(W), int(H))
    var rect = RenderShape(color: RGBA(r: 255, a: 255))
    rect.path.moveTo(pt(4, 6))
    rect.path.lineTo(pt(20, 6))
    rect.path.lineTo(pt(20, 16))
    rect.path.lineTo(pt(4, 16))
    rect.path.close()
    let all = {RenderUpdateFlag.low .. RenderUpdateFlag.high}
    let m: RenderMethod = r
    check m.preUpdate()
    let d = m.prepareShape(rect, nil, IdentityMatrix, @[], 255'u8, all, false)
    check m.postUpdate() and m.clear() and m.preRender()
    check m.renderShape(d) and m.postRender() and m.sync()
    let f = readFbo(ctx.fbo, int(W), int(H))
    check getError() == GlNoError
    check f.at(8, 10) == 0xFF0000FF'u32 and f.at(4, 6) == 0xFF0000FF'u32
    check f.at(2, 10) == 0'u32 and f.at(8, 18) == 0'u32 and f.at(25, 25) == 0'u32
    m.dispose(d)
    r.destroy()

  test "without clear the previous frame stays; with clear it is wiped":
    let e = newEnv()
    let a = rectShape(2, 2, 8, 8, 255, 0, 0, 255)
    check e.c.add(a) == Result.Success
    check e.frame().at(5, 5) == 0xFF0000FF'u32
    discard e.c.remove(nil)
    let b = rectShape(20, 20, 8, 8, 0, 255, 0, 255)
    check e.c.add(b) == Result.Success
    let kept = e.frame(clear = false)
    check kept.at(5, 5) == 0xFF0000FF'u32 and kept.at(24, 24) == 0xFF00FF00'u32
    discard e.c.remove(nil)
    check e.c.add(rectShape(20, 20, 8, 8, 0, 255, 0, 255)) == Result.Success
    let wiped = e.frame()
    check wiped.at(5, 5) == 0'u32 and wiped.at(24, 24) == 0xFF00FF00'u32
    e.finish()

suite "scene composition":
  test "opacity layering: the layer is composited as one":
    let e = newEnv()
    let sc = newScene()
    check sc.opacity(128) == Result.Success
    check sc.add(rectShape(4, 4, 16, 16, 255, 0, 0, 255)) == Result.Success
    check sc.add(rectShape(12, 12, 16, 16, 0, 0, 255, 255)) == Result.Success
    check e.c.add(sc) == Result.Success
    let f = e.frame()
    let both = f.at(16, 16)  # overlap: only the top rect shows
    check abs(aa(both) - 128) <= 3 and bb(both) > 50 and rr(both) < 10
    let top = f.at(6, 6)
    check abs(aa(top) - 128) <= 3 and rr(top) > 50 and bb(top) < 10
    check f.at(1, 1) == 0'u32 and f.at(30, 30) == 0'u32
    e.finish()

  test "alpha mask, inverse alpha, luma and subtract":
    for (m, insideVisible) in [(MaskMethod.Alpha, true), (MaskMethod.InvAlpha, false),
        (MaskMethod.Luma, true), (MaskMethod.Subtract, false)]:
      let e = newEnv()
      let content = rectShape(0, 0, 32, 32, 0, 255, 0, 255)
      let maskShape = rectShape(8, 8, 16, 16, 255, 255, 255, 255)
      check content.mask(maskShape, m) == Result.Success
      check e.c.add(content) == Result.Success
      let f = e.frame()
      let inside = f.at(16, 16)
      let outside = f.at(3, 3)
      if insideVisible:
        check inside == 0xFF00FF00'u32
        check aa(outside) == 0
      else:
        check aa(inside) == 0
        if m == MaskMethod.InvAlpha:
          check outside == 0xFF00FF00'u32
      e.finish()

  test "clipped shape":
    let e = newEnv()
    let content = rectShape(0, 0, 32, 32, 0, 255, 0, 255)
    check content.clip(rectShape(8, 8, 12, 12, 255, 0, 0, 255)) == Result.Success
    check e.c.add(content) == Result.Success
    let f = e.frame()
    check f.at(12, 12) == 0xFF00FF00'u32 and f.at(19, 19) == 0xFF00FF00'u32
    check f.at(4, 12) == 0'u32 and f.at(24, 12) == 0'u32 and f.at(0, 0) == 0'u32
    e.finish()

  test "non native blend (multiply) of a scene":
    let e = newEnv()
    check e.c.add(rectShape(0, 0, 32, 32, 255, 255, 0, 255)) == Result.Success
    let sc = newScene()
    check sc.blend(BlendMethod.Multiply) == Result.Success
    check sc.add(rectShape(8, 8, 16, 16, 0, 255, 255, 255)) == Result.Success
    check e.c.add(sc) == Result.Success
    let f = e.frame()
    check f.at(2, 2) == 0xFF00FFFF'u32  # untouched yellow (ABGR: r=255 g=255)
    let mid = f.at(16, 16)  # yellow * cyan = green
    check gg(mid) > 240 and rr(mid) < 12 and bb(mid) < 12 and aa(mid) == 255
    e.finish()

  test "a scene with blend and mask together (rearranged passes)":
    let e = newEnv()
    check e.c.add(rectShape(0, 0, 32, 32, 255, 255, 0, 255)) == Result.Success
    let sc = newScene()
    check sc.blend(BlendMethod.Multiply) == Result.Success
    check sc.add(rectShape(0, 0, 32, 32, 0, 255, 255, 255)) == Result.Success
    check sc.mask(rectShape(8, 8, 16, 16, 255, 255, 255, 255), MaskMethod.Alpha) ==
      Result.Success
    check e.c.add(sc) == Result.Success
    let f = e.frame()
    let inside = f.at(16, 16)  # multiplied inside the mask
    check gg(inside) > 240 and rr(inside) < 12 and bb(inside) < 12
    check f.at(3, 3) == 0xFF00FFFF'u32  # outside the mask the backdrop is untouched
    check getError() == GlNoError
    e.finish()

suite "scene effects":
  proc blurred(sigma: float): Frame =
    let e = newEnv()
    let sc = newScene()
    check sc.add(rectShape(10, 10, 12, 12, 255, 0, 0, 255)) == Result.Success
    if sigma > 0: check sc.gaussianBlur(sigma) == Result.Success
    check e.c.add(sc) == Result.Success
    result = e.frame()
    e.finish()

  test "gaussian blur softens the edges":
    let sharp = blurred(0)
    let soft = blurred(2)
    check aa(sharp.at(8, 16)) == 0 and aa(sharp.at(16, 16)) == 255
    check aa(soft.at(8, 16)) in 8 .. 120 and aa(soft.at(16, 16)) > 230
    check aa(soft.at(12, 10)) in 80 .. 200  # on the edge
    check soft.at(0, 0) == 0'u32 and soft.at(31, 31) == 0'u32

  test "drop shadow is offset and tinted":
    let e = newEnv()
    let sc = newScene()
    check sc.add(rectShape(4, 8, 10, 12, 255, 0, 0, 255)) == Result.Success
    check sc.dropShadow(0, 0, 255, 255, 90.0, 8.0, 1.0) == Result.Success
    check e.c.add(sc) == Result.Success
    let f = e.frame()
    check f.at(8, 14) == 0xFF0000FF'u32  # the shape stays on top
    let shadow = f.at(19, 14)
    check bb(shadow) > 200 and aa(shadow) > 200 and rr(shadow) < 40
    check aa(f.at(28, 14)) == 0 and aa(f.at(8, 2)) == 0
    e.finish()

  test "fill effect replaces the colour":
    let e = newEnv()
    let sc = newScene()
    check sc.add(rectShape(8, 8, 16, 16, 255, 0, 0, 255)) == Result.Success
    check sc.fill(0, 255, 0, 255) == Result.Success
    check e.c.add(sc) == Result.Success
    let f = e.frame()
    check f.at(16, 16) == 0xFF00FF00'u32 and f.at(2, 2) == 0'u32
    e.finish()

suite "targets and lifetime":
  test "retarget to another framebuffer and size, and back":
    let e = newEnv()
    let sc = newScene()
    check sc.opacity(200) == Result.Success
    check sc.add(rectShape(0, 0, 32, 32, 255, 0, 0, 255)) == Result.Success
    check sc.add(rectShape(2, 2, 8, 8, 0, 0, 255, 255)) == Result.Success
    check e.c.add(sc) == Result.Success
    check aa(e.frame().at(20, 20)) > 190

    let fbo2 = genFramebuffer()
    bindFramebuffer(GlFramebuffer, fbo2)
    let color2 = genRenderbuffer()
    bindRenderbuffer(GlRenderbuffer, color2)
    renderbufferStorage(GlRenderbuffer, GlRgba8, 16, 16)
    framebufferRenderbuffer(GlFramebuffer, GlColorAttachment0, GlRenderbuffer, color2)
    let depth2 = genRenderbuffer()
    bindRenderbuffer(GlRenderbuffer, depth2)
    renderbufferStorage(GlRenderbuffer, GlDepth24Stencil8, 16, 16)
    framebufferRenderbuffer(GlFramebuffer, GlDepthStencilAttachment, GlRenderbuffer, depth2)
    check checkFramebufferStatus(GlFramebuffer) == GlFramebufferComplete

    check e.r.target(0, ctx.dc, ctx.rc, fbo2, 16, 16, Abgr) == Result.Success
    check e.c.retarget(16, 16, Abgr) == Result.Success
    check e.c.update() == Result.Success and e.c.draw() == Result.Success and e.c.sync() ==
      Result.Success
    let small = readFbo(fbo2, 16, 16)
    check aa(small.at(12, 12)) > 190 and rr(small.at(12, 12)) > 150
    check bb(small.at(5, 5)) > 150  # the blue rect shows on top, scaled by nothing
    check getError() == GlNoError

    check e.r.target(0, ctx.dc, ctx.rc, ctx.fbo, uint32(W), uint32(H), Abgr) == Result.Success
    check e.c.retarget(uint32(W), uint32(H), Abgr) == Result.Success
    check aa(e.frame().at(30, 30)) > 190

    e.finish()
    deleteFramebuffer(fbo2)
    deleteRenderbuffer(color2)
    deleteRenderbuffer(depth2)

  test "repeated frames of a composited scene do not grow the GL object count":
    let e = newEnv()
    check e.c.add(rectShape(0, 0, 32, 32, 255, 255, 0, 255)) == Result.Success
    let sc = newScene()
    check sc.opacity(180) == Result.Success
    check sc.blend(BlendMethod.Multiply) == Result.Success
    check sc.gaussianBlur(1.0) == Result.Success
    let moving = rectShape(6, 6, 14, 14, 0, 255, 255, 255)
    check moving.mask(rectShape(4, 4, 20, 20, 255, 255, 255, 255), MaskMethod.Alpha) ==
      Result.Success
    check sc.add(moving) == Result.Success
    check e.c.add(sc) == Result.Success
    discard e.frame()
    discard e.frame()  # pools and programs exist now
    var live = -1
    for i in 0 ..< 8:
      discard moving.translate(float32(i mod 3), 0)
      discard e.frame()
      if live < 0: live = glLiveObjects()
      check glLiveObjects() == live
    check getError() == GlNoError
    e.finish()

  test "no GL objects are left after destroy":
    check getError() == GlNoError
    check glLiveObjects() == baseline

wglDestroy(ctx)
