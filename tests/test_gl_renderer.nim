## G4a: GL renderer core (renderer.nim, renderer_draw.nim, renderer_prepare.nim).
## Needs a GL 3.3 context from wgl_ffi; exits 0 with a message when none can be created.
## A `GlRenderer` is built by hand (no canvas): shapes and images go through the
## `prepareShape` / `prepareImage` / `renderShape` / `renderImage` overrides, then the root pass
## is executed into the offscreen framebuffer by `present`, a TEST-ONLY stand-in for the `sync`
## that G4b adds. The pixels are read back and checked at interior points.
import std/[unittest, options]
import thorvg/core/[types, geom, path, fill]
import thorvg/renderer/render
import thorvg/engine/gl/[renderer_prepare, gl_ffi, wgl_ffi, render_task, render_pass,
  gpu_buffer, program, programs, render_target]

const
  W = 32'i32
  H = 32'i32
  AllFlags = {RenderUpdateFlag.low .. RenderUpdateFlag.high}
  Red = RGBA(r: 255, a: 255)

let (created, ctxInit) = wglCreateOffscreen(int(W), int(H))
if not created:
  echo "SKIP: no GL 3.3 context could be created"
  quit(0)

var ctx = ctxInit

let baseline = glLiveObjects()

func pt(x, y: float32): Point = Point(x: x, y: y)
func full(): Region = initRegion(0, 0, W, H)

func rect(x, y, w, h: float32): RenderPath =
  result.moveTo(pt(x, y))
  result.lineTo(pt(x + w, y))
  result.lineTo(pt(x + w, y + h))
  result.lineTo(pt(x, y + h))
  result.close()

func filled(p: RenderPath, c: RGBA): RenderShape = RenderShape(path: p, color: c)

func stroked(p: RenderPath, width: float32, c: RGBA): RenderShape =
  var st = initStroke()
  st.width = width
  st.color = c
  RenderShape(path: p, color: RGBA(), stroke: some(st))

func withFill(rs: RenderShape, f: Fill): RenderShape =
  result = rs
  result.fill = some(f)

func chan(px: uint32, shift: int): int = int((px shr shift) and 0xff'u32)
func rr(px: uint32): int = chan(px, 0)
func gg(px: uint32): int = chan(px, 8)
func bb(px: uint32): int = chan(px, 16)
func aa(px: uint32): int = chan(px, 24)

func at(px: seq[uint32], x, y: int): uint32 =
  ## Pixel (x, y) with y counted from the top.
  px[(int(H) - 1 - y) * int(W) + x]

proc newTestRenderer(): GlRenderer =
  ## What G4b's `target(...)` will do: surface, context handles, root target.
  result = newGlRenderer()
  result.drawSurface = ctx.dc
  result.context = ctx.rc
  result.targetFboId = ctx.fbo
  result.surface = newSurface(uint32(W), uint32(H), ColorSpace.ABGR8888S)
  result.vport = full()
  result.rootTarget.viewport = full()
  result.rootTarget.init(result.state, uint32(W), uint32(H), ctx.fbo)
  result.state.invalidate()

proc prep(r: GlRenderer, rs: RenderShape, clips: seq[RenderData] = @[], clipper = false,
    opacity = 255'u8): RenderData =
  r.prepareShape(rs, nil, IdentityMatrix, clips, opacity, AllFlags, clipper)

proc present(r: GlRenderer): seq[uint32] =
  ## TEST ONLY (replaced by G4b's `sync`): ends the root pass into the offscreen framebuffer
  ## and reads it back.
  r.state.invalidate()
  r.state.enable(GlBlend)
  r.state.enable(GlScissorTest)
  r.state.enable(GlDepthTest)
  r.state.depthFunc(GlGreater)
  let task = r.passStack[0].endRenderPass[:GlBlitTask](r.programs[ord(rtBlit)], ctx.fbo)
  r.prepareCmpTask(task, full(), uint32(W), uint32(H))
  task.addBindResource(textureBinding(0, task.colorTex, GlShaderUniform.SourceTexture))
  task.targetViewport = full()
  check r.stage.flushToGPU(r.state)
  r.stage.bindStage(r.state)
  task.run(r.state)
  r.stage.unbind(r.state)
  check getError() == GlNoError
  bindFramebuffer(GlReadFramebuffer, ctx.fbo)
  readPixels(0, 0, W, H, result)
  r.state.disable(GlScissorTest)
  r.state.invalidate()
  r.clearDisposes()

proc draw(r: GlRenderer, items: openArray[RenderData]): seq[uint32] =
  ## One frame: `preRender`, render every item in order, `present`.
  check r.preUpdate()
  check r.preRender()
  for d in items:
    if d of GlImage: check r.renderImage(d)
    else: check r.renderShape(d)
  result = r.present()

proc finish(r: GlRenderer, items: openArray[RenderData]) =
  for d in items: r.dispose(d)
  r.destroy()

suite "helpers":
  test "packGradientBlock keeps ordered stops and reports opacity":
    var info: array[4, float32]
    var points: array[MaxGradientStops, float32]
    var colors: array[4 * MaxGradientStops, float32]
    let stops = [ColorStop(offset: 0.0, r: 255, a: 255), ColorStop(offset: 0.5, g: 255, a: 255),
      ColorStop(offset: 0.25, b: 255, a: 255), ColorStop(offset: 1.0, r: 255, b: 255, a: 255)]
    let opaque = packGradientBlock(info, points, colors, stops, 4, FillSpread.Repeat, 1.0)
    check not opaque  # a stop was dropped
    check info[0] == 3.0'f32 and info[1] == 0.5'f32 and info[2] == 2.0'f32
    check points[0] == 0.0'f32 and points[1] == 0.5'f32 and points[2] == 1.0'f32
    check colors[0] == 1.0'f32 and colors[5] == 1.0'f32 and colors[8] == 1.0'f32
    check colors[11] == 1.0'f32
    var info2: array[4, float32]
    check packGradientBlock(info2, points, colors, stops.toOpenArray(0, 1), 2,
      FillSpread.Pad, 1.0)
    check not packGradientBlock(info2, points, colors, stops.toOpenArray(0, 1), 2,
      FillSpread.Pad, 0.5)
    check colors[3] == 0.5'f32

  test "blend maps Composition to Normal":
    let r = newTestRenderer()
    check r.blend(BlendMethod.Multiply) and r.mBlendMethod == BlendMethod.Multiply
    check r.blend(BlendMethod.Composition) and r.mBlendMethod == BlendMethod.Normal
    r.destroy()

  test "program table: eager programs, lazy blend programs":
    let r = newTestRenderer()
    check r.preRender()
    check r.programs.len == RtNone and r.programs[ord(rtColor)] != nil
    check r.programs[ord(rtBlit)] != nil and r.programs[ord(rtBlend)] == nil
    let p = r.getBlendProgram(BlendMethod.Multiply, BlendSource.Solid)
    check p != nil and p.isValid and r.getBlendProgram(BlendMethod.Multiply,
      BlendSource.Solid) == p
    r.clearDisposes()
    r.destroy()

  test "an opacity of 0 defers the update; later flags are merged":
    let r = newTestRenderer()
    let d = r.prep(filled(rect(4, 4, 8, 8), Red), opacity = 0)
    let shape = GlShape(d)
    check shape.opacity == 0 and shape.geometry.fill.index.len == 0
    check not r.intersectsShape(d, full())
    let d2 = r.prepareShape(filled(rect(4, 4, 8, 8), Red), d, IdentityMatrix, @[], 255'u8,
      {}, false)
    check d2 == d and shape.geometry.fill.index.len == 6 and shape.opacity == 255
    let reg = r.region(d)
    check reg.xMin == 4 and reg.yMin == 4 and reg.xMax == 12 and reg.yMax == 12
    check r.intersectsShape(d, initRegion(6, 6, 8, 8))
    check not r.intersectsShape(d, initRegion(20, 20, 24, 24))
    r.finish([d])

suite "pixels":
  test "solid rect":
    let r = newTestRenderer()
    let d = r.prep(filled(rect(4, 6, 16, 10), Red))
    let px = r.draw([d])
    check px.at(8, 10) == 0xFF0000FF'u32 and px.at(4, 6) == 0xFF0000FF'u32
    check px.at(19, 15) == 0xFF0000FF'u32
    check px.at(2, 10) == 0'u32 and px.at(21, 10) == 0'u32 and px.at(8, 4) == 0'u32
    check px.at(8, 17) == 0'u32
    r.finish([d])

  test "stroke: the line is covered, the interior is not":
    let r = newTestRenderer()
    let d = r.prep(stroked(rect(8, 8, 16, 16), 4, Red))
    let px = r.draw([d])
    check px.at(7, 16) == 0xFF0000FF'u32 and px.at(16, 7) == 0xFF0000FF'u32
    check px.at(24, 16) == 0xFF0000FF'u32 and px.at(16, 24) == 0xFF0000FF'u32
    check px.at(16, 16) == 0'u32 and px.at(12, 12) == 0'u32
    check px.at(2, 2) == 0'u32 and px.at(30, 16) == 0'u32
    r.finish([d])

  test "linear gradient runs red to blue":
    let r = newTestRenderer()
    var f = linearGradient(4, 0, 28, 0)
    f.stops = @[ColorStop(offset: 0, r: 255, a: 255), ColorStop(offset: 1, b: 255, a: 255)]
    let d = r.prep(withFill(filled(rect(4, 4, 24, 24), RGBA()), f))
    let px = r.draw([d])
    let left = px.at(6, 16)
    let right = px.at(26, 16)
    check rr(left) > 200 and bb(left) < 60 and aa(left) == 255
    check bb(right) > 200 and rr(right) < 60 and aa(right) == 255
    check px.at(2, 16) == 0'u32 and px.at(16, 30) == 0'u32
    r.finish([d])

  test "radial gradient: white center, red rim":
    let r = newTestRenderer()
    var f = radialGradient(16, 16, 12)
    f.stops = @[ColorStop(offset: 0, r: 255, g: 255, b: 255, a: 255),
      ColorStop(offset: 1, r: 255, a: 255)]
    let d = r.prep(withFill(filled(rect(4, 4, 24, 24), RGBA()), f))
    let px = r.draw([d])
    check gg(px.at(16, 16)) > 220 and rr(px.at(16, 16)) > 240
    check gg(px.at(25, 16)) < 90 and rr(px.at(25, 16)) > 240
    check px.at(2, 2) == 0'u32
    r.finish([d])

  test "conic gradient and the uncorrectable radial fallback draw":
    let r = newTestRenderer()
    var c = conicGradient(16, 16, 0)
    c.stops = @[ColorStop(offset: 0, r: 255, a: 255), ColorStop(offset: 1, b: 255, a: 255)]
    var tiny = radialGradient(16, 16, 0.001)  # r < 0.02: the last stop paints solid
    tiny.stops = @[ColorStop(offset: 0, r: 255, a: 255), ColorStop(offset: 1, g: 255, a: 255)]
    let d1 = r.prep(withFill(filled(rect(2, 2, 12, 12), RGBA()), c))
    let d2 = r.prep(withFill(filled(rect(18, 18, 12, 12), RGBA()), tiny))
    let px = r.draw([d1, d2])
    check aa(px.at(8, 8)) == 255 and aa(px.at(24, 24)) == 255
    check px.at(24, 24) == 0xFF00FF00'u32
    check px.at(8, 24) == 0'u32
    r.finish([d1, d2])

  test "image: the texture is sampled inside its quad":
    let r = newTestRenderer()
    let surf = newSurface(4, 4, ColorSpace.ABGR8888S)
    for i in 0 ..< surf.data.len: surf.data[i] = 0xFF00FF00'u32  # opaque green
    let m = Matrix(e11: 4, e22: 4, e13: 8, e23: 8, e33: 1)
    let img = r.prepareImage(surf, nil, m, @[], 255'u8, FilterMethod.Bilinear, AllFlags)
    check img != nil and GlImage(img).texId != 0
    let px = r.draw([img])
    check px.at(16, 16) == 0xFF00FF00'u32 and px.at(9, 9) == 0xFF00FF00'u32
    check px.at(4, 16) == 0'u32 and px.at(16, 25) == 0'u32
    check r.intersectsImage(img, initRegion(10, 10, 12, 12))
    check not r.intersectsImage(img, initRegion(0, 0, 4, 4))
    r.finish([img])

  test "clipped shape shows only the clip interior":
    let r = newTestRenderer()
    let clip = r.prep(filled(rect(8, 8, 12, 12), Red), clipper = true)
    let d = r.prep(filled(rect(0, 0, 32, 32), RGBA(g: 255, a: 255)), clips = @[clip])
    let px = r.draw([d])
    check px.at(12, 12) == 0xFF00FF00'u32 and px.at(8, 8) == 0xFF00FF00'u32
    check px.at(19, 19) == 0xFF00FF00'u32
    check px.at(4, 12) == 0'u32 and px.at(24, 12) == 0'u32 and px.at(12, 24) == 0'u32
    check px.at(0, 0) == 0'u32
    r.finish([d, clip])

  test "an empty clip hides the paint":
    let r = newTestRenderer()
    let clip = r.prep(filled(RenderPath(), Red), clipper = true)
    let d = r.prep(filled(rect(0, 0, 32, 32), Red), clips = @[clip])
    let px = r.draw([d])
    for p in px: check p == 0'u32
    r.finish([d, clip])

  test "non native blend (multiply) takes the copy-destination path":
    let r = newTestRenderer()
    let back = r.prep(filled(rect(0, 0, 32, 32), RGBA(r: 255, g: 255, a: 255)))
    let front = r.prep(filled(rect(8, 8, 16, 16), RGBA(g: 255, b: 255, a: 255)))
    check r.preUpdate() and r.preRender()
    check r.renderShape(back)
    check r.blend(BlendMethod.Multiply)
    check r.renderShape(front)
    check r.blend(BlendMethod.Normal)
    let px = r.present()
    check px.at(2, 2) == 0xFF00FFFF'u32
    check gg(px.at(16, 16)) > 200 and rr(px.at(16, 16)) < 40 and bb(px.at(16, 16)) < 40
    r.finish([back, front])

proc lifecycle(): int =
  ## A whole renderer life: returns the GL objects still alive while `r` is in scope.
  let r = newTestRenderer()
  let surf = newSurface(2, 2, ColorSpace.ABGR8888S)
  let img = r.prepareImage(surf, nil, Matrix(e11: 8, e22: 8, e33: 1), @[], 255'u8,
    FilterMethod.Bilinear, AllFlags)
  let d = r.prep(filled(rect(4, 4, 8, 8), Red))
  discard r.draw([img, d])
  check r.textures.surfaceCount == 1
  r.finish([img, d])
  check r.textures.surfaceCount == 0
  glLiveObjects() - baseline

suite "lifetime":
  test "no leaked GL objects after dispose and destroy, no GL error":
    let aliveWithRenderer = lifecycle()
    check getError() == GlNoError
    # what remains while the renderer object lives is its stage buffer (VAO + 3 buffers)
    check aliveWithRenderer == 4
    check glLiveObjects() == baseline

wglDestroy(ctx)