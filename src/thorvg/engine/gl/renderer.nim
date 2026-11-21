## GL renderer core, part 1: the `GlRenderer` object and its infrastructure (port of the first
## half of `tvgGlRenderer.cpp/.h`, unit G4a). Part 2 is `renderer_draw.nim` (drawing) and part 3
## `renderer_prepare.nim` (the `RenderMethod` overrides).
##
## `GlRenderer` is a `ref object of RenderMethod` with every field exported: G4b (target / sync /
## composition / effects) and the tests build on them. `GlStateCache` is move-only, so the
## renderer owns it (`r.state`) and passes it as `var` to the helpers. Batches, effects and
## render-target pools take the pass, stage buffer and programs as explicit arguments.
##
## Needs a current GL context for `newGlRenderer` (it creates the stage buffer), `initShaders`
## and everything that draws. Desktop GL only (the GLES branches are not ported).
##
## Fields (C++ name -> Nim name): `textures`; `mDisplay/mSurface/mContext` -> `display`,
## `drawSurface` (HDC), `context` (HGLRC); `surface`; `mTargetFboId` -> `targetFboId`;
## `mStateCache` -> `state`; `mGpuBuffer` -> `stage`; `mRootTarget` -> `rootTarget`; `mEffect` ->
## `effect`; `mPrograms` -> `programs`; `mComposePool`, `mBlendPool`, `mRenderPassStack` ->
## `composePool`, `blendPool`, `passStack`; `mComposeStack` -> `composeStack`; `mSolidBatch` ->
## `solidBatch`; `mStencilCoverBatch` -> `stencilBatch`; `mDisposed.textures` -> `disposed`;
## `mBlendMethod`, `mClearBuffer` keep their names.
##
## Implemented here: `newGlRenderer`, `destroy` (the C++ destructor), `currentContext`, `flush`,
## `clearDisposes`, `disposeTexture`, `destroy(GlImage, renderer)`, `initShaders`,
## `getBlendProgram`, `currentPass`, `createPrimitiveTask`, `bindBlendTarget`,
## `beginComplexBlending`, `endBlendingCompose`, `prepareCmpTask`.
##
## G4b (DONE, import `renderer_sync` to link the methods): `renderer_comp.nim` has
## `target(region, cs, flags)`, `beginComposite`, `endComposite`, `endRenderPass(cmp)`,
## `prepareBlitTask`, `effectPrepare/Region/Render/Dispose`; `renderer_sync.nim` has
## `target(display, surface, context, fboId, w, h, cs)`, `sync`, `clear`, `newGlTargetRenderer`.
## The damage / partial / dirty-region methods are not part of the Nim `RenderMethod`.

import ../../core/[types, geom]
import ../../renderer/render
import ./[effects, gl_common, gl_ffi, gpu_buffer, program, programs, render_pass, render_target,
  render_task, solid_batch, state_cache, stencil_batch, task_blend, texture_mgr, wgl_ffi]

export gl_common, gl_ffi, programs, solid_batch, stencil_batch, state_cache, texture_mgr

const
  RectIndex* = [0'u32, 1, 2, 2, 1, 3]  ## two triangles of a quad (`RECT_INDEX`)
  RectIndexCount* = 6'u32

type
  GlRenderer* = ref object of RenderMethod
    textures*: TextureMgr
    display*, drawSurface*, context*: int  ## EGL display / HDC / HGLRC handles (0 = unset)
    surface*: RenderSurface
    targetFboId*: GlId
    state*: GlStateCache
    stage*: GlStageBuffer
    rootTarget*: GlRenderTarget
    effect*: GlEffect
    programs*: seq[GlProgram]              ## `RtNone` slots, blend programs are lazy
    composePool*, blendPool*: seq[GlRenderTargetPool]
    passStack*: seq[GlRenderPass]
    composeStack*: seq[GlCompositor]
    solidBatch*: GlSolidBatch
    stencilBatch*: GlStencilCoverBatch
    disposed*: seq[GlId]                   ## textures deleted on the next flush
    mBlendMethod*: BlendMethod
    mClearBuffer*: bool

proc newGlRenderer*(stage: GlStageBuffer = nil): GlRenderer =
  ## `GlRenderer()`. A nil `stage` creates one (a GL context must be current).
  let buffer = if stage == nil: newGlStageBuffer() else: stage
  GlRenderer(surface: RenderSurface(), rootTarget: newGlRenderTarget(), stage: buffer,
    effect: newGlEffect(buffer), mBlendMethod: BlendMethod.Normal)

proc asGlRenderer*(m: RenderMethod): GlRenderer =
  ## `m` as a GL renderer, nil for another engine (G5; the type name is shadowed by the
  ## `GL_RENDERER` constant of gl_types in importing modules, so the downcast lives here).
  if m != nil and m of GlRenderer: GlRenderer(m) else: nil

proc disposeTexture*(r: GlRenderer, texId: GlId) =
  if texId != 0: r.disposed.add texId

proc destroy*(image: GlImage, r: GlRenderer) =
  ## `GlImage::destroy`: gives back the texture reference if this renderer still owns it.
  if image.texId != 0 and image.stamp == r.textures.stamp:
    r.disposeTexture(r.textures.release(image.surface, image.filter, image.texId))

proc clearDisposes*(r: GlRenderer) =
  for texId in r.disposed: glCheck(deleteTexture(texId))
  r.disposed.setLen(0)
  r.passStack.setLen(0)
  r.solidBatch.clear()
  r.stencilBatch.clear()

proc flush*(r: GlRenderer) =
  r.clearDisposes()
  r.rootTarget.reset(r.state)
  for p in r.composePool: p.destroy(r.state)
  r.composePool.setLen(0)
  for p in r.blendPool: p.destroy(r.state)
  r.blendPool.setLen(0)
  r.composeStack.setLen(0)

proc currentContext*(r: GlRenderer): bool =
  ## Makes the renderer's context current (WGL branch of the C++).
  if wglCurrentContext() == r.context: return true
  wglMakeCurrent(r.drawSurface, r.context)

proc destroy*(r: GlRenderer) =
  ## `~GlRenderer` (explicit: the caller owns the GL teardown order).
  if r.context != 0: discard r.currentContext()
  r.flush()
  r.textures.clear()
  for p in r.programs:
    if p != nil: p.destroy()
  r.programs.setLen(0)
  r.effect.destroy()

proc initShaders*(r: GlRenderer) =
  ## The eager programs; the custom blend slots stay nil until `getBlendProgram`.
  let sources = initShaderSources()
  r.programs = newSeq[GlProgram](RtNone)
  for i, src in sources: r.programs[i] = newGlProgram(src)

proc getBlendProgram*(r: GlRenderer, method0: BlendMethod, source: BlendSource): GlProgram =
  ## Custom blend program of (method, source), built on first use.
  let index = blendProgramIndex(method0, source)
  if r.programs[index] == nil: r.programs[index] = newGlProgram(blendProgramSource(method0, source))
  r.programs[index]

proc currentPass*(r: GlRenderer): GlRenderPass =
  if r.passStack.len == 0: nil else: r.passStack[^1]

proc blendTargetPool(r: GlRenderer, index: int): GlRenderTargetPool =
  ## `mBlendPool[index]`, creating the missing pools up to it.
  while r.blendPool.len <= index:
    r.blendPool.add newGlRenderTargetPool(r.surface.w, r.surface.h)
  r.blendPool[index]

proc createPrimitiveTask*(r: GlRenderer, rtype: RenderTypes, source: BlendSource,
    viewRegion: Region, dstCopyFbo: var GlRenderTarget): GlRenderTask =
  ## A native blend draws straight into the pass; any other one copies the destination region
  ## first (`GlDirectBlendTask`).
  dstCopyFbo = nil
  if isNativeBlend(r.mBlendMethod): return newGlRenderTask(r.programs[ord(rtype)], r.mBlendMethod)

  dstCopyFbo = r.blendTargetPool(0).getRenderTarget(r.state, viewRegion)
  let program = r.getBlendProgram(r.mBlendMethod, source)
  newGlDirectBlendTask(program, r.currentPass().fbo, dstCopyFbo, viewRegion)

proc bindBlendTarget*(r: GlRenderer, task: GlRenderTask, dstCopyFbo: GlRenderTarget,
    viewRegion: Region, binding: uint32) =
  if dstCopyFbo == nil: return
  let region = [float32(viewRegion.xMin), float32(viewRegion.yMin), float32(dstCopyFbo.width),
    float32(dstCopyFbo.height)]
  let offset = r.stage.push(region, true)
  task.addBindResource(uniformBinding(binding, GlShaderUniformBlock.BlendRegion,
    r.stage.getBufferId(), offset, 16))
  task.addBindResource(textureBinding(0, dstCopyFbo.colorTex, GlShaderUniform.DestinationTexture))

proc beginComplexBlending*(r: GlRenderer, vp: Region, bounds: Region): bool =
  ## Opens a scratch pass for a non native blend; false when nothing needs to be composed.
  if isNativeBlend(r.mBlendMethod) or vp.invalid: return false
  let clipped = bounds.intersect(vp)
  if clipped.invalid: return false

  let blendFbo = r.blendTargetPool(0).getRenderTarget(r.state, clipped)
  r.passStack.add newGlRenderPass(blendFbo)
  true

proc prepareCmpTask*(r: GlRenderer, task: GlRenderTask, vp: Region, cmpWidth, cmpHeight: uint32) =
  ## Full quad (position + uv) of `vp` inside the current pass, for compose-like tasks.
  let passVp = r.currentPass().getViewport()
  let taskVp = vp.intersect(passVp)

  let x = taskVp.xMin - passVp.xMin
  var y = taskVp.yMin - passVp.yMin
  let w = taskVp.sw
  let h = taskVp.sh

  let rw = float32(passVp.sw)
  let rh = float32(passVp.sh)
  let l = float32(x)
  let t = rh - float32(y)
  let rt = float32(x + w)
  let b = rh - float32(y) - float32(h)

  # map vp ltrb to -1:1
  let left = (l / rw) * 2.0'f32 - 1.0'f32
  let top = (t / rh) * 2.0'f32 - 1.0'f32
  let right = (rt / rw) * 2.0'f32 - 1.0'f32
  let bottom = (b / rh) * 2.0'f32 - 1.0'f32

  let uw = float32(w) / float32(cmpWidth)
  let uh = float32(h) / float32(cmpHeight)

  let vertices = [left, top, 0.0'f32, uh,  left, bottom, 0.0'f32, 0.0'f32,
    right, top, uw, uh,  right, bottom, uw, 0.0'f32]
  let vertexOffset = r.stage.push(vertices)
  let indexOffset = r.stage.pushIndex(RectIndex)
  let buffer = r.stage.getBufferId()

  task.addVertexLayout(GlVertexLayout(index: 0, size: 2, stride: 16, offset: vertexOffset,
    ty: GlFloat, normalized: false, arrayBufferId: buffer))
  task.addVertexLayout(GlVertexLayout(index: 1, size: 2, stride: 16, offset: vertexOffset + 8,
    ty: GlFloat, normalized: false, arrayBufferId: buffer))
  task.setDrawRange(uint32(indexOffset), RectIndexCount)
  y = passVp.sh - y - h
  task.setViewport(Region(xMin: x, yMin: y, xMax: x + w, yMax: y + h))

proc endBlendingCompose*(r: GlRenderer, stencilTask: GlRenderTask) =
  ## Closes the scratch pass of `beginComplexBlending` and queues the complex blend task.
  let blendPass = r.passStack.pop()
  let pass = r.currentPass()
  blendPass.setDrawDepth(int32(pass.nextDrawDepth()))

  let composeTask = blendPass.endRenderPass[:GlComposeTask](nil, pass.getFboId())

  let vp = blendPass.getViewport()
  let dstCopyFbo = r.blendTargetPool(1).getRenderTarget(r.state, vp)

  let x = vp.xMin
  let y = pass.getViewport().sh - vp.yMin - vp.sh
  stencilTask.setViewport(Region(xMin: x, yMin: y, xMax: x + vp.sw, yMax: y + vp.sh))

  stencilTask.setDrawDepth(int32(pass.nextDrawDepth()))
  stencilTask.setViewMatrix(pass.getViewMatrix())

  let program = r.getBlendProgram(r.mBlendMethod, BlendSource.Image)
  let task = newGlComplexBlendTask(program, pass.fbo, dstCopyFbo, stencilTask, composeTask)
  r.prepareCmpTask(task, vp, blendPass.getFboWidth(), blendPass.getFboHeight())
  task.setDrawDepth(int32(pass.nextDrawDepth()))

  # src and dst texture
  task.addBindResource(textureBinding(1, blendPass.fbo.colorTex, GlShaderUniform.SourceTexture))
  task.addBindResource(textureBinding(2, dstCopyFbo.colorTex, GlShaderUniform.DestinationTexture))

  pass.addRenderTask(task)
