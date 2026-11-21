## G4c: GL scene effects (effects.nim): uniform/region computation (no GL needed) and one pixel
## test per effect on a real multisampled `GlRenderPass` (needs a GL 3.3 context from wgl_ffi;
## the GL part exits 0 with a message when none can be created).
import std/unittest
import thorvg/core/[types, geom]
import thorvg/renderer/[render, effect]
import thorvg/engine/gl/[gl_ffi, wgl_ffi, state_cache, program, programs, gl_common, gpu_buffer,
  render_target, render_task, task_blend, render_pass, task_draw, effects]

const
  W = 32'i32
  H = 32'i32
  Eps = 1e-6'f32

func near(a, b: float32, tol = Eps): bool = abs(a - b) <= tol

# ---------------------------------------------------------------- uniforms and regions

suite "update and region":
  let fx = newGlEffect(newCpuStageBuffer())

  test "gaussian blur: kernel, quality and region by direction":
    let e = genGaussianBlur(2.0, 0, 0, 100)
    fx.update(e, identity())
    check e.valid
    let d = GlBlurData(e.rd)
    check d.uniforms() == [2.0'f32, 1.0, 4.0, 1.0]
    check fx.region(e)
    check e.extend == Region(xMin: -4, yMin: -4, xMax: 4, yMax: 4)

    var tm = identity()
    tm.e11 = 3.0
    tm.e12 = 4.0  # scale 5
    let q = genGaussianBlur(1.0, 0, 0, 50)
    fx.update(q, tm)
    check GlBlurData(q.rd).uniforms() == [1.0'f32, 5.0, 10.0, 2.0]
    let q2 = genGaussianBlur(1.0, 0, 0, 10)
    fx.update(q2, tm)
    check GlBlurData(q2.rd).quality == 3.0'f32
    # the step never exceeds the radius
    let tiny = genGaussianBlur(0.5, 0, 0, 10)
    fx.update(tiny, identity())
    check GlBlurData(tiny.rd).extend == 1.0'f32 and GlBlurData(tiny.rd).quality == 1.0'f32

    let h = genGaussianBlur(2.0, 1, 0, 100)
    fx.update(h, identity())
    check fx.region(h)
    check h.extend == Region(xMin: -4, yMin: 0, xMax: 4, yMax: 0)
    let v = genGaussianBlur(2.0, 2, 0, 100)
    fx.update(v, identity())
    check fx.region(v)
    check v.extend == Region(xMin: 0, yMin: -4, xMax: 0, yMax: 4)

  test "gaussian blur: zero sigma is invalid and has no region":
    let e = genGaussianBlur(0.0, 0, 0, 50)
    fx.update(e, identity())
    check not e.valid and e.rd == nil
    check not fx.region(e)

  test "motion blur: offset, samples and region":
    let e = genMotionBlur(10.0, 0.0, 50)
    fx.update(e, identity())
    check e.valid
    let d = GlMotionBlurData(e.rd)
    check near(d.offset[0], 10.0) and near(d.offset[1], 0.0) and d.samples == 9.0'f32
    check d.uniforms()[3] == 0.0'f32
    check fx.region(e)
    check e.extend == Region(xMin: -5, yMin: 0, xMax: 5, yMax: 0)
    let up = genMotionBlur(10.0, 90.0, 50)
    fx.update(up, identity())
    check near(GlMotionBlurData(up.rd).offset[1], -10.0)  # framebuffer y is flipped
    check fx.region(up)
    check up.extend == Region(xMin: 0, yMin: -5, xMax: 0, yMax: 5)
    let none = genMotionBlur(0.0, 0.0, 50)
    fx.update(none, identity())
    check not none.valid and none.rd == nil

  test "drop shadow: premultiplied color, flipped offset, extend":
    let e = genDropShadow(255, 128, 0, 128, 90.0, 4.0, 2.0, 100)
    fx.update(e, identity())
    check e.valid
    let d = GlDropShadowData(e.rd)
    let a = 128.0'f32 / 255.0'f32
    check near(d.color[3], a) and near(d.color[0], a) and near(d.color[1], 128.0'f32 / 255.0'f32 * a)
    check d.color[2] == 0.0'f32
    check near(d.offset[0], -4.0, 1e-5) and near(d.offset[1], 0.0, 1e-5)
    check near(d.extend, 12.0, 1e-5) and d.quality == 1.0'f32
    check d.sigma == 2.0'f32 and d.scale == 1.0'f32
    let u = d.uniforms()
    check u.len == 12 and u[0] == 2.0'f32 and u[4] == d.color[0] and u[9] == d.offset[1]
    check u[10] == 0.0'f32 and u[11] == 0.0'f32
    check fx.region(e)
    check e.extend == Region(xMin: -12, yMin: -12, xMax: 12, yMax: 12)
    let up = genDropShadow(0, 0, 0, 255, 0.0, 4.0, 0.0, 100)
    fx.update(up, identity())
    check near(GlDropShadowData(up.rd).offset[1], -4.0, 1e-5)  # angle 0: shadow goes up
    check near(GlDropShadowData(up.rd).extend, 8.0, 1e-5)
    let off = genDropShadow(0, 0, 0, 0, 0.0, 4.0, 2.0, 100)
    fx.update(off, identity())
    check not off.valid and off.rd == nil

  test "fill, tint and tritone parameters":
    let f = genFill(255, 128, 0, 64)
    fx.update(f, identity())
    check f.valid
    let p = GlParamsData(f.rd).params
    check p[0] == 1.0'f32 and p[1] == 128.0'f32 / 255.0'f32 and p[2] == 0.0'f32
    check p[3] == 64.0'f32 / 255.0'f32
    check not fx.region(f)

    let t = genTint(10, 20, 30, 200, 210, 220, 100.0)
    fx.update(t, identity())
    check t.valid
    let q = GlParamsData(t.rd).params
    check q[0] == 10.0'f32 / 255.0'f32 and q[2] == 30.0'f32 / 255.0'f32 and q[3] == 0.0'f32
    check q[4] == 200.0'f32 / 255.0'f32 and q[6] == 220.0'f32 / 255.0'f32 and q[7] == 0.0'f32
    check q[8] == 255.0'f32 / 255.0'f32  # intensity 100 -> 255
    check not fx.region(t)
    let zero = genTint(0, 0, 0, 255, 255, 255, 0.0)
    fx.update(zero, identity())
    check not zero.valid and zero.rd == nil

    let r = genTritone([1, 2, 3], [4, 5, 6], [7, 8, 9], 100)
    fx.update(r, identity())
    check r.valid
    let s = GlParamsData(r.rd).params
    check s[0] == 1.0'f32 / 255.0'f32 and s[2] == 3.0'f32 / 255.0'f32 and s[3] == 0.0'f32
    check s[4] == 4.0'f32 / 255.0'f32 and s[6] == 6.0'f32 / 255.0'f32 and s[7] == 0.0'f32
    check s[8] == 7.0'f32 / 255.0'f32 and s[10] == 9.0'f32 / 255.0'f32
    check s[11] == 100.0'f32 / 255.0'f32
    check not fx.region(r)
    let opaque = genTritone([1, 2, 3], [4, 5, 6], [7, 8, 9], 255)
    fx.update(opaque, identity())
    check not opaque.valid and opaque.rd == nil

  test "parameters are reused, region needs prepare, dispose clears":
    let e = genFill(1, 2, 3, 4)
    fx.update(e, identity())
    let first = e.rd
    e.color = [9'u8, 8, 7, 6]
    fx.update(e, identity())
    check e.rd == first
    check GlParamsData(e.rd).params[0] == 9.0'f32 / 255.0'f32
    dispose(e)
    check e.rd == nil
    let b = genGaussianBlur(2.0, 0, 0, 50)
    check not fx.region(b)  # never prepared
    check not fx.region(genMotionBlur(5.0, 0.0, 50))
    check not fx.region(genDropShadow(0, 0, 0, 255, 0.0, 1.0, 1.0, 50))
    let pools = newSeq[GlRenderTargetPool]()
    var cache: GlStateCache
    check not fx.render(b, newGlRenderPass(nil), pools, cache)

  test "ensureEffectPools makes two pools":
    var pools: seq[GlRenderTargetPool]
    ensureEffectPools(pools, 64, 32)
    check pools.len == 2
    ensureEffectPools(pools, 64, 32)
    check pools.len == 2

# ---------------------------------------------------------------- GL part

let (created, ctxInit) = wglCreateOffscreen(int(W), int(H))
if not created:
  echo "SKIP: no GL 3.3 context could be created"
  quit(0)

var ctx = ctxInit
let baseline = glLiveObjects()

const
  PxNone = 0'u32

func full(): Region = initRegion(0, 0, W, H)

proc readFbo(fbo: GlId): seq[uint32] =
  bindFramebuffer(GlReadFramebuffer, fbo)
  readPixels(0, 0, W, H, result)

func at(px: seq[uint32], x, y: int): uint32 =
  ## Pixel (x, y) with y counted from the top, as the drawing coordinates.
  px[(int(H) - 1 - y) * int(W) + x]

func chan(px: uint32, i: int): int = int((px shr (8 * i)) and 0xFF)

func word(r, g, b, a: int): uint32 =
  uint32(r) or (uint32(g) shl 8) or (uint32(b) shl 16) or (uint32(a) shl 24)

proc rect(x0, y0, x1, y1: float32): GlGeometry =
  result = initGlGeometry()
  result.fill.vertex = @[x0, y0, x1, y0, x0, y1, x1, y1]
  result.fill.index = @[0'u32, 1, 2, 2, 1, 3]

proc makeProgram(index: RenderTypes): GlProgram = newGlProgram(initShaderSources()[ord(index)])

proc colorRect(pass: GlRenderPass, prog: GlProgram, stage: GlStageBuffer,
    x0, y0, x1, y1: float32, r, g, b: float32) =
  let t = newGlRenderTask(prog)
  rect(x0, y0, x1, y1).draw(t, stage, {RenderUpdateFlag.Path})
  t.setVertexColor(r, g, b, 1)
  t.setViewMatrix(pass.getViewMatrix())
  t.setViewport(full())
  t.setDrawDepth(int32(pass.nextDrawDepth()))
  pass.addRenderTask t

type
  Content = proc(pass: GlRenderPass, stage: GlStageBuffer, colorProg: GlProgram)
  Inspect = proc(pass: GlRenderPass, stage: GlStageBuffer)

proc drawEffect(re: RenderEffect, tm: Matrix, content: Content,
    inspect: Inspect = nil): seq[uint32] =
  ## Prepares `re`, draws `content` into a pass, appends the effect, blits to the offscreen fbo.
  var cache: GlStateCache
  cache.enable(GlScissorTest)
  cache.enable(GlBlend)
  let pool = newGlRenderTargetPool(uint32(W), uint32(H))
  var blendPool: seq[GlRenderTargetPool]
  ensureEffectPools(blendPool, uint32(W), uint32(H))
  let stage = newGlStageBuffer()
  let fx = newGlEffect(stage)
  let colorProg = makeProgram(rtColor)
  let blitProg = makeProgram(rtBlit)
  let rt = pool.getRenderTarget(cache, full(), ctx.fbo)
  let pass = newGlRenderPass(rt)
  fx.update(re, tm)
  check re.valid
  discard fx.region(re)
  content(pass, stage, colorProg)
  let before = pass.taskCount()
  check fx.render(re, pass, blendPool, cache)
  check pass.taskCount() == before + 1
  if inspect != nil: inspect(pass, stage)

  let blit = pass.endRenderPass[:GlBlitTask](blitProg, ctx.fbo)
  blit.targetViewport = full()
  blit.setViewport(full())
  let quad = [-1'f32, 1, 0, 1,  -1, -1, 0, 0,  1, 1, 1, 1,  1, -1, 1, 0]
  let vo = stage.push(quad)
  let io = stage.pushIndex([0'u32, 1, 2, 2, 1, 3])
  let vb = stage.getBufferId()
  blit.addVertexLayout(GlVertexLayout(index: 0, size: 2, stride: 16, offset: vo,
    arrayBufferId: vb))
  blit.addVertexLayout(GlVertexLayout(index: 1, size: 2, stride: 16, offset: vo + 8,
    arrayBufferId: vb))
  blit.setDrawRange(uint32(io), 6)
  blit.addBindResource(textureBinding(0, blit.colorTex, GlShaderUniform.SourceTexture))
  check stage.flushToGPU(cache)
  stage.bindStage(cache)
  blit.run(cache)
  check getError() == GlNoError
  result = readFbo(ctx.fbo)
  cache.invalidate()
  dispose(re)
  fx.destroy()
  for p in blendPool: p.destroy(cache)
  pool.destroy(cache)
  cache.invalidate()

proc contentRect(x0, y0, x1, y1: float32, r, g, b: float32): Content =
  result = proc(pass: GlRenderPass, stage: GlStageBuffer, colorProg: GlProgram) =
    colorRect(pass, colorProg, stage, x0, y0, x1, y1, r, g, b)

proc sumChannel(px: seq[uint32], i: int): int =
  for p in px: result += p.chan(i)

suite "pixels":
  test "gaussian blur of one bright pixel is symmetric and keeps its energy":
    let px = drawEffect(genGaussianBlur(2.0, 0, 0, 100), identity(),
      contentRect(16, 16, 17, 17, 1, 0, 0))
    for d in 1 .. 6:
      check px.at(16 - d, 16) == px.at(16 + d, 16)
      check px.at(16, 16 - d) == px.at(16, 16 + d)
      check px.at(16 - d, 16 - d) == px.at(16 + d, 16 + d)
    check px.at(16, 16).chan(0) < 255 and px.at(16, 16).chan(0) > 5  # ~ 255 / (2 pi sigma^2)
    check px.at(16, 16).chan(0) >= px.at(17, 16).chan(0)
    check px.at(17, 16).chan(0) > px.at(19, 16).chan(0)
    check px.at(16, 16).chan(1) == 0 and px.at(16, 16).chan(2) == 0
    check px.at(16, 16).chan(3) == px.at(16, 16).chan(0)  # premultiplied red: r == a
    check px.at(2, 2) == PxNone and px.at(29, 29) == PxNone
    check abs(sumChannel(px, 0) - 255) <= 20
    check abs(sumChannel(px, 3) - 255) <= 20

  test "gaussian blur direction: horizontal spreads only in x, vertical only in y":
    let h = drawEffect(genGaussianBlur(2.0, 1, 0, 100), identity(),
      contentRect(16, 16, 17, 17, 1, 0, 0))
    check h.at(14, 16).chan(0) > 0 and h.at(18, 16).chan(0) > 0
    check h.at(16, 15) == PxNone and h.at(16, 17) == PxNone
    check h.at(14, 16) == h.at(18, 16)
    let v = drawEffect(genGaussianBlur(2.0, 2, 0, 100), identity(),
      contentRect(16, 16, 17, 17, 1, 0, 0))
    check v.at(16, 14).chan(0) > 0 and v.at(16, 18).chan(0) > 0
    check v.at(15, 16) == PxNone and v.at(17, 16) == PxNone
    check v.at(16, 14) == v.at(16, 18)

  test "fill gives the exact color on covered pixels":
    let px = drawEffect(genFill(0, 255, 0, 255), identity(),
      contentRect(8, 8, 24, 24, 1, 0, 0))
    check px.at(8, 8) == word(0, 255, 0, 255) and px.at(23, 23) == word(0, 255, 0, 255)
    check px.at(16, 16) == word(0, 255, 0, 255)
    check px.at(7, 16) == PxNone and px.at(24, 16) == PxNone and px.at(16, 7) == PxNone
    let half = drawEffect(genFill(255, 0, 0, 128), identity(),
      contentRect(8, 8, 24, 24, 0, 0, 1))
    # shader: fill * orig.a * fill.a with fill = (1, 0, 0, 128/255) -> r 128, a 64
    check abs(half.at(16, 16).chan(0) - 128) <= 1 and abs(half.at(16, 16).chan(3) - 64) <= 1
    check half.at(16, 16).chan(1) == 0 and half.at(16, 16).chan(2) == 0

  test "tint maps by luma between black and white":
    let gray = drawEffect(genTint(0, 0, 0, 255, 255, 255, 100.0), identity(),
      contentRect(8, 8, 24, 24, 1, 0, 0))
    let g = gray.at(16, 16)
    # luma(red) = 0.2126 -> 54.2
    check abs(g.chan(0) - 54) <= 1 and abs(g.chan(1) - 54) <= 1 and abs(g.chan(2) - 54) <= 1
    check g.chan(3) == 255 and gray.at(4, 4) == PxNone
    let duo = drawEffect(genTint(255, 0, 0, 0, 0, 255, 100.0), identity(),
      contentRect(8, 8, 24, 24, 1, 0, 0))
    let d = duo.at(16, 16)
    check abs(d.chan(0) - 201) <= 1 and d.chan(1) == 0 and abs(d.chan(2) - 54) <= 1

  test "tritone maps shadow, midtone and highlight":
    let content = proc(pass: GlRenderPass, stage: GlStageBuffer, colorProg: GlProgram) =
      colorRect(pass, colorProg, stage, 4, 8, 14, 24, 1, 0, 0)    # luma 0.2126 (shadow side)
      colorRect(pass, colorProg, stage, 18, 8, 28, 24, 0, 1, 0)   # luma 0.7152 (highlight side)
    let px = drawEffect(genTritone([0, 0, 0], [255, 0, 0], [255, 255, 255], 0), identity(),
      content)
    let dark = px.at(8, 16)   # t = 0.4252 between shadow (black) and midtone (red)
    check abs(dark.chan(0) - 108) <= 1 and dark.chan(1) == 0 and dark.chan(2) == 0
    let bright = px.at(22, 16)  # t = 0.4304 between midtone and highlight (white)
    check bright.chan(0) == 255 and abs(bright.chan(1) - 110) <= 1
    check abs(bright.chan(2) - 110) <= 1 and bright.chan(3) == 255
    check px.at(1, 1) == PxNone

  test "drop shadow without blur is the shifted copy under the original":
    # angle 90: the shadow moves 5 px right; opaque blue shadow color
    let px = drawEffect(genDropShadow(0, 0, 255, 255, 90.0, 5.0, 0.0, 100), identity(),
      contentRect(6, 10, 10, 14, 1, 0, 0))
    check px.at(7, 12) == word(255, 0, 0, 255)           # the original stays on top
    check px.at(12, 12) == word(0, 0, 255, 255)           # the shadow, 5 px to the right
    check px.at(14, 13) == word(0, 0, 255, 255)
    check px.at(10, 12) == PxNone and px.at(15, 12) == PxNone
    check px.at(12, 9) == PxNone and px.at(12, 14) == PxNone
    let up = drawEffect(genDropShadow(0, 0, 255, 255, 0.0, 5.0, 0.0, 100), identity(),
      contentRect(10, 14, 14, 18, 1, 0, 0))              # angle 0: the shadow moves up
    check up.at(11, 15) == word(255, 0, 0, 255)
    check up.at(11, 10) == word(0, 0, 255, 255)
    check up.at(11, 13) == PxNone and up.at(11, 8) == PxNone

  test "drop shadow with blur is soft and keeps the original opaque":
    let px = drawEffect(genDropShadow(0, 0, 0, 255, 90.0, 6.0, 2.0, 100), identity(),
      contentRect(6, 10, 14, 18, 1, 0, 0))
    check px.at(10, 14) == word(255, 0, 0, 255)
    let edge = px.at(20, 14)  # the shadow edge (x = 14 + 6) is half covered
    check edge.chan(3) > 60 and edge.chan(3) < 200
    check edge.chan(0) == 0 and edge.chan(1) == 0 and edge.chan(2) == 0
    check px.at(18, 14).chan(3) > px.at(21, 14).chan(3)
    check px.at(18, 14).chan(3) > px.at(23, 14).chan(3)
    check px.at(31, 14) == PxNone and px.at(18, 1) == PxNone

  test "motion blur spreads along the vector and keeps its energy":
    let px = drawEffect(genMotionBlur(8.0, 0.0, 100), identity(),
      contentRect(16, 16, 17, 17, 1, 0, 0))
    for d in 1 .. 6:
      check px.at(16 - d, 16) == px.at(16 + d, 16)
    check px.at(14, 16).chan(0) > 0 and px.at(18, 16).chan(0) > 0
    check px.at(16, 15) == PxNone and px.at(16, 17) == PxNone
    check px.at(10, 16) == PxNone and px.at(22, 16) == PxNone
    check abs(sumChannel(px, 0) - 255) <= 12
    let vert = drawEffect(genMotionBlur(8.0, 90.0, 100), identity(),
      contentRect(16, 16, 17, 17, 1, 0, 0))
    check vert.at(16, 14).chan(0) > 0 and vert.at(16, 18).chan(0) > 0
    check vert.at(15, 16) == PxNone and vert.at(17, 16) == PxNone
    check vert.at(16, 13) == vert.at(16, 19)

  test "uniform blocks are aligned in the stage buffer and describe the task":
    let content = contentRect(8, 8, 24, 24, 1, 0, 0)
    let inspect = proc(pass: GlRenderPass, stage: GlStageBuffer) =
      let task = pass.lastTask()
      check task of GlGaussianBlurTask
      let blur = GlGaussianBlurTask(task)
      check blur.horzTask.bindResources.len == 2 and blur.vertTask.bindResources.len == 2
      let params = blur.horzTask.bindResources[0]
      check params.uniformBlock == GlShaderUniformBlock.Gaussian and params.bufferRange == 16
      check params.bufferOffset mod int(getInteger(GlUniformBufferOffsetAlignment)) == 0
      let o = params.bufferOffset div 4
      check near(bitsFloat(stage.stage[o]), 2.0) and near(bitsFloat(stage.stage[o + 2]), 4.0)
      let vp = blur.horzTask.bindResources[1]
      check vp.uniformBlock == GlShaderUniformBlock.Viewport and vp.bufferRange == 16
      let v = vp.bufferOffset div 4
      check near(bitsFloat(stage.stage[v + 2]), float32(W)) and
        near(bitsFloat(stage.stage[v + 3]), float32(H))
      check blur.horzTask.indexCnt == 6 and blur.horzTask.vertexLayout[0].stride == 8
      check blur.vertTask.bindResources[0].bufferOffset == params.bufferOffset
      check blur.effect.direction == 0 and blur.viewport == full()
    discard drawEffect(genGaussianBlur(2.0, 0, 0, 100), identity(), content, inspect)

  test "effects other than blur add a single effect task":
    let content = contentRect(8, 8, 24, 24, 1, 0, 0)
    let inspect = proc(pass: GlRenderPass, stage: GlStageBuffer) =
      check pass.lastTask() of GlEffectTask
      let t = GlEffectTask(pass.lastTask())
      check t.bindResources.len == 1 and t.vertexLayout.len == 1
      check t.bindResources[0].uniformBlock == GlShaderUniformBlock.Params
      check t.bindResources[0].bufferRange == 48
    discard drawEffect(genTint(0, 0, 0, 255, 255, 255, 100.0), identity(), content, inspect)

  test "no GL object leaked":
    check glLiveObjects() == baseline
    check getError() == GlNoError

wglDestroy(ctx)
