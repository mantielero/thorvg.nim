## G3a: GL render tasks, blend tasks, render pass and `GlGeometry.draw`
## (render_task.nim, task_blend.nim, render_pass.nim, task_draw.nim).
## Needs a GL 3.3 context from wgl_ffi; exits 0 with a message when none can be created.
## The scenes run a real `GlRenderPass` into a multisampled target and blit the result into the
## offscreen framebuffer, which is read back.
import std/unittest
import thorvg/core/[types, geom]
import thorvg/renderer/render
import thorvg/engine/gl/[gl_ffi, wgl_ffi, state_cache, program, programs, gl_common,
  gpu_buffer, render_target, render_task, task_blend, render_pass, task_draw]

const
  W = 16'i32
  H = 16'i32
  # RGBA8 readback words: R | G<<8 | B<<16 | A<<24
  PxRed = 0xFF0000FF'u32
  PxNone = 0'u32

let (created, ctxInit) = wglCreateOffscreen(int(W), int(H))
if not created:
  echo "SKIP: no GL 3.3 context could be created"
  quit(0)

var ctx = ctxInit

let baseline = glLiveObjects()

func full(): Region = initRegion(0, 0, W, H)

proc readFbo(fbo: GlId): seq[uint32] =
  ## Raw readback of a framebuffer (the caller invalidates its state cache afterwards).
  bindFramebuffer(GlReadFramebuffer, fbo)
  readPixels(0, 0, W, H, result)

func at(px: seq[uint32], x, y: int): uint32 =
  ## Pixel (x, y) with y counted from the top, as the drawing coordinates.
  px[(int(H) - 1 - y) * int(W) + x]

proc rect(x0, y0, x1, y1: float32): GlGeometry =
  result = initGlGeometry()
  result.fill.vertex = @[x0, y0, x1, y0, x0, y1, x1, y1]
  result.fill.index = @[0'u32, 1, 2, 2, 1, 3]

proc makeProgram(index: RenderTypes): GlProgram = newGlProgram(initShaderSources()[ord(index)])

proc setup(cache: var GlStateCache) =
  cache.enable(GlScissorTest)
  cache.enable(GlBlend)

proc shapeTask(pass: GlRenderPass, prog: GlProgram, stage: GlStageBuffer,
    g: GlGeometry): GlRenderTask =
  ## A task drawing `g` in the pass: colour, view matrix, viewport and the next depth.
  result = newGlRenderTask(prog)
  g.draw(result, stage, {RenderUpdateFlag.Path})
  result.setViewMatrix(pass.getViewMatrix())
  result.setViewport(full())
  result.setDrawDepth(int32(pass.nextDrawDepth()))

proc blitTask(pass: GlRenderPass, prog: GlProgram, stage: GlStageBuffer): GlBlitTask =
  ## `endRenderPass[GlBlitTask]` into the offscreen framebuffer plus the full-screen quad.
  result = pass.endRenderPass[:GlBlitTask](prog, ctx.fbo)
  result.targetViewport = full()
  result.setViewport(full())
  let quad = [-1'f32, 1, 0, 1,  -1, -1, 0, 0,  1, 1, 1, 1,  1, -1, 1, 0]
  let vo = stage.push(quad)
  let io = stage.pushIndex([0'u32, 1, 2, 2, 1, 3])
  let vb = stage.getBufferId()
  result.addVertexLayout(GlVertexLayout(index: 0, size: 2, stride: 16, offset: vo,
    arrayBufferId: vb))
  result.addVertexLayout(GlVertexLayout(index: 1, size: 2, stride: 16, offset: vo + 8,
    arrayBufferId: vb))
  result.setDrawRange(uint32(io), 6)
  result.addBindResource(textureBinding(0, result.colorTex, GlShaderUniform.SourceTexture))

proc runBlit(cache: var GlStateCache, stage: GlStageBuffer, blit: GlBlitTask): seq[uint32] =
  check stage.flushToGPU(cache)
  stage.bindStage(cache)
  blit.run(cache)
  check getError() == GlNoError
  result = readFbo(ctx.fbo)
  cache.invalidate()

proc drawScene(build: proc(pass: GlRenderPass, stage: GlStageBuffer, pool: GlRenderTargetPool,
    cache: var GlStateCache)): seq[uint32] =
  ## Runs a pass built by `build` and returns the blitted pixels.
  var cache: GlStateCache
  setup(cache)
  let pool = newGlRenderTargetPool(uint32(W), uint32(H))
  let stage = newGlStageBuffer()
  let blitProg = makeProgram(rtBlit)
  let rt = pool.getRenderTarget(cache, full(), ctx.fbo)
  let pass = newGlRenderPass(rt)
  build(pass, stage, pool, cache)
  let blit = blitTask(pass, blitProg, stage)
  result = runBlit(cache, stage, blit)
  pool.destroy(cache)

suite "render pass":
  test "view matrix maps the pass viewport to clip space (y flipped)":
    var cache: GlStateCache
    let pool = newGlRenderTargetPool(uint32(W), uint32(H))
    let pass = newGlRenderPass(pool.getRenderTarget(cache, initRegion(4, 2, 12, 10), ctx.fbo))
    let m = pass.getViewMatrix()
    check abs(m.e11 - 0.25'f32) < 1e-6 and abs(m.e22 + 0.25'f32) < 1e-6
    check abs(m.e13 - (-1.0'f32 - 4 * 0.25'f32)) < 1e-6
    check abs(m.e23 - (1.0'f32 + 2 * 0.25'f32)) < 1e-6
    check pass.getFboWidth() == 8'u32 and pass.getFboHeight() == 8'u32  # pow2 of the viewport
    check pass.getViewport().sw == 8
    check not pass.isEmpty() and newGlRenderPass(nil).isEmpty()
    check pass.nextDrawDepth() == 1 and pass.nextDrawDepth() == 2
    pass.setDrawDepth(10)
    check pass.nextDrawDepth() == 11
    pool.destroy(cache)
    cache.invalidate()

  test "task list: add, lastTask, takeLastTask":
    let pass = newGlRenderPass(nil)
    check pass.lastTask() == nil and pass.takeLastTask() == nil
    let a = newGlRenderTask(nil)
    let b = newGlRenderTask(nil)
    pass.addRenderTask a
    pass.addRenderTask b
    check pass.taskCount() == 2 and pass.lastTask() == b
    check pass.takeLastTask() == b and pass.lastTask() == a
    check pass.taskCount() == 1

  test "endRenderPass normalizes draw depths and moves the tasks":
    var cache: GlStateCache
    let pool = newGlRenderTargetPool(uint32(W), uint32(H))
    let pass = newGlRenderPass(pool.getRenderTarget(cache, full(), ctx.fbo))
    let t1 = newGlRenderTask(nil)
    let stencil = newGlRenderTask(nil)
    let cover = newGlRenderTask(nil)
    let sc = newGlStencilCoverTask(stencil, cover, GlStencilMode.FillNonZero)
    let t3 = newGlRenderTask(nil)
    for t in [t1, GlRenderTask(sc), t3]:
      pass.addRenderTask t
      t.setDrawDepth(int32(pass.nextDrawDepth()))
    stencil.setDrawDepth(2)
    cover.setDrawDepth(2)
    let cmp = pass.endRenderPass[:GlComposeTask](nil, 0)
    check cmp.tasks.len == 3 and pass.taskCount() == 0
    check t1.drawDepth == 0.25'f32 and t3.drawDepth == 0.75'f32
    check stencil.drawDepth == 0.5'f32 and cover.drawDepth == 0.5'f32
    check cmp.renderWidth == 16'u32 and cmp.renderHeight == 16'u32
    # the other task kinds instantiate the same generic
    let draw = pass.endRenderPass[:GlDrawBlitTask](nil, 0)
    let blend = pass.endRenderPass[:GlSceneBlendTask](nil, 0)
    check draw.tasks.len == 0 and blend.tasks.len == 0
    let blit = pass.endRenderPass[:GlBlitTask](nil, 0)
    check blit.colorTex == pass.getTextureId()
    pool.destroy(cache)
    cache.invalidate()

suite "task basics":
  test "bindings, vertex colour, viewport and depth setters":
    let colorProg = makeProgram(rtColor)
    let t = newGlRenderTask(colorProg)
    t.setVertexColor(0.25, 0.5, 0.75, 1.0)
    check t.useVertexColor and t.vertexColor == [0.25'f32, 0.5, 0.75, 1.0]
    t.setViewport(Region(xMin: 3, yMin: 4, xMax: 1, yMax: 2))
    check t.viewport.xMax == 3 and t.viewport.yMax == 4  # empty regions are clamped
    t.setDrawDepth(3)
    t.normalizeDrawDepth(4)
    check t.drawDepth == 0.75'f32
    t.setDrawRange(6, 12)
    check not t.useDrawArrays and t.indexOffset == 6 and t.indexCnt == 12
    t.addBindResource(textureBinding(1, 7, GlShaderUniform.SourceTexture))
    check t.bindResources.len == 1 and t.bindResources[0].kind == GlBindingKind.Texture
    # the colour program has no such block: the binding is dropped
    t.addBindResource(uniformBinding(2, GlShaderUniformBlock.Viewport, 5, 0, 64))
    check t.bindResources.len == 1
    let grad = newGlRenderTask(makeProgram(rtLinGradient))
    grad.addBindResource(uniformBinding(3, GlShaderUniformBlock.GradientInfo, 5, 256, 400))
    check grad.bindResources.len == 1
    check grad.bindResources[0].bufferOffset == 256 and grad.bindResources[0].bufferRange == 400
    check getError() == GlNoError

  test "GlGeometry.draw: shape, stroke and image layouts":
    var cache: GlStateCache
    let stage = newGlStageBuffer()
    var g = rect(0, 0, 4, 4)
    g.stroke.vertex = @[0'f32, 0, 1, 0, 0, 1]
    g.stroke.index = @[0'u32, 1, 2]
    let fill = newGlRenderTask(nil)
    g.draw(fill, stage, {RenderUpdateFlag.Path})
    check fill.vertexLayout.len == 1 and fill.vertexLayout[0].stride == 8
    check fill.vertexLayout[0].size == 2 and fill.vertexLayout[0].offset == 0
    check fill.indexCnt == 6 and fill.indexOffset == 0 and not fill.useDrawArrays
    let stroke = newGlRenderTask(nil)
    g.draw(stroke, stage, {RenderUpdateFlag.Stroke})
    check stroke.indexCnt == 3 and stroke.vertexLayout[0].offset == 32
    check stroke.indexOffset == 24
    let gstroke = newGlRenderTask(nil)
    g.draw(gstroke, stage, {RenderUpdateFlag.GradientStroke})
    check gstroke.indexCnt == 3
    let image = newGlRenderTask(nil)
    g.draw(image, stage, {RenderUpdateFlag.Image})
    check image.vertexLayout.len == 2 and image.vertexLayout[0].stride == 16
    check image.vertexLayout[1].index == 1 and
      image.vertexLayout[1].offset == image.vertexLayout[0].offset + 8
    check image.indexCnt == 6
    check fill.vertexLayout[0].arrayBufferId == stage.getBufferId()
    check stage.flushToGPU(cache)
    cache.invalidate()
    check getError() == GlNoError

suite "pixels":
  test "colour task: covered and uncovered pixels, y axis":
    let px = drawScene(proc(pass: GlRenderPass, stage: GlStageBuffer,
        pool: GlRenderTargetPool, cache: var GlStateCache) =
      let t = shapeTask(pass, makeProgram(rtColor), stage, rect(4, 2, 12, 10))
      t.setVertexColor(1, 0, 0, 1)
      pass.addRenderTask t)
    check px.at(6, 4) == PxRed and px.at(4, 2) == PxRed and px.at(11, 9) == PxRed
    check px.at(3, 4) == PxNone and px.at(12, 4) == PxNone
    check px.at(6, 1) == PxNone and px.at(6, 10) == PxNone and px.at(6, 13) == PxNone

  test "stencil+cover task, even-odd leaves the overlap uncovered":
    for mode in [GlStencilMode.FillEvenOdd, GlStencilMode.FillNonZero]:
      let px = drawScene(proc(pass: GlRenderPass, stage: GlStageBuffer,
          pool: GlRenderTargetPool, cache: var GlStateCache) =
        let stencilProg = makeProgram(rtStencil)
        let colorProg = makeProgram(rtColor)
        var g = rect(2, 2, 10, 10)  # two overlapping rectangles in one fill
        g.fill.vertex.add [6'f32, 6, 14, 6, 6, 14, 14, 14]
        g.fill.index.add [4'u32, 5, 6, 6, 5, 7]
        let st = shapeTask(pass, stencilProg, stage, g)
        let cv = shapeTask(pass, colorProg, stage, rect(0, 0, 16, 16))
        cv.setVertexColor(1, 0, 0, 1)
        pass.addRenderTask newGlStencilCoverTask(st, cv, mode))
      check px.at(4, 4) == PxRed and px.at(12, 12) == PxRed
      check px.at(14, 2) == PxNone and px.at(2, 14) == PxNone
      check px.at(8, 8) == (if mode == GlStencilMode.FillEvenOdd: PxNone else: PxRed)

  test "clip task keeps only the inside of the clip shape":
    let px = drawScene(proc(pass: GlRenderPass, stage: GlStageBuffer,
        pool: GlRenderTargetPool, cache: var GlStateCache) =
      cache.enable(GlDepthTest)
      cache.depthFunc(GlGreater)
      # the shape gets the lower depth, the clip the higher one (depth func GREATER)
      let shape = shapeTask(pass, makeProgram(rtColor), stage, rect(0, 0, 16, 16))
      shape.setVertexColor(1, 0, 0, 1)
      let stencilProg = makeProgram(rtStencil)
      let clip = shapeTask(pass, stencilProg, stage, rect(2, 2, 10, 10))
      let mask = shapeTask(pass, stencilProg, stage, rect(-1, -1, 17, 17))
      mask.setDrawDepth(clip.drawDepth.int32)
      pass.addRenderTask newGlClipTask(clip, mask)
      pass.addRenderTask shape)
    check px.at(5, 5) == PxRed and px.at(2, 2) == PxRed and px.at(9, 9) == PxRed
    check px.at(12, 5) == PxNone and px.at(5, 12) == PxNone and px.at(0, 0) == PxNone

  test "direct blend task copies the region of the destination and redraws it":
    var cache: GlStateCache
    setup(cache)
    let pool = newGlRenderTargetPool(uint32(W), uint32(H))
    let stage = newGlStageBuffer()
    let colorProg = makeProgram(rtColor)
    let blitProg = makeProgram(rtBlit)
    let dst = pool.getRenderTarget(cache, full(), ctx.fbo)
    let copy = newGlRenderTarget()
    copy.init(cache, uint32(W), uint32(H), ctx.fbo)
    # red 4x4 square at x, y in [4, 8) (y from the top of the pass: [8, 12))
    let pass = newGlRenderPass(dst)
    let t = shapeTask(pass, colorProg, stage, rect(4, 8, 8, 12))
    t.setVertexColor(1, 0, 0, 1)
    pass.addRenderTask t
    let cmp = pass.endRenderPass[:GlComposeTask](nil, 0)
    # the copy region [4, 12)^2 (GL coordinates) is drawn back stretched over the whole target
    let region = initRegion(4, 4, 12, 12)
    let direct = newGlDirectBlendTask(blitProg, dst, copy, region)
    direct.setViewport(full())
    let quad = [-1'f32, 1, 0, 0.5,  -1, -1, 0, 0,  1, 1, 0.5, 0.5,  1, -1, 0.5, 0]
    let vo = stage.push(quad)
    let io = stage.pushIndex([0'u32, 1, 2, 2, 1, 3])
    direct.addVertexLayout(GlVertexLayout(index: 0, size: 2, stride: 16, offset: vo,
      arrayBufferId: stage.getBufferId()))
    direct.addVertexLayout(GlVertexLayout(index: 1, size: 2, stride: 16, offset: vo + 8,
      arrayBufferId: stage.getBufferId()))
    direct.setDrawRange(uint32(io), 6)
    direct.addBindResource(textureBinding(0, copy.colorTex, GlShaderUniform.SourceTexture))
    check stage.flushToGPU(cache)
    stage.bindStage(cache)
    cmp.run(cache)
    direct.run(cache)
    check getError() == GlNoError
    check cache.drawFramebuffer.value == dst.fbo
    # resolve the multisampled result and read it
    bindFramebuffer(GlReadFramebuffer, dst.fbo)
    bindFramebuffer(GlDrawFramebuffer, dst.resolvedFbo)
    blitFramebuffer(0, 0, W, H, 0, 0, W, H, GlColorBufferBit, GlNearest)
    let px = readFbo(dst.resolvedFbo)
    check px.at(3, 12) == PxRed and px.at(2, 13) == PxRed  # GL (3, 3), (2, 2) -> red
    check px.at(12, 3) == PxNone and px.at(14, 1) == PxNone
    copy.reset(cache)
    pool.destroy(cache)
    cache.invalidate()
    check getError() == GlNoError

  test "no GL object leaked":
    check glLiveObjects() == baseline
    check getError() == GlNoError

wglDestroy(ctx)

