## GL blend and effect tasks (port of tvgGlRenderTask.cpp/.h, second half; desktop GL branch,
## `THORVG_GL_TARGET_GL`): `GlSceneBlendTask`, `GlDirectBlendTask`, `GlComplexBlendTask`,
## `GlGaussianBlurTask`, `GlEffectDropShadowTask` and `GlEffectTask`.
##
## All of them copy part of a destination `GlRenderTarget` into the `resolvedFbo` of a copy
## target and then draw with a custom program that samples the copy. The `GlRenderTarget`s are
## shared refs (owned by the pools of the renderer). Constructors mirror the C++ ones; the
## fields the renderer fills in afterwards (`srcFbo`, `dstCopyFbo`, `horzTask`, `vertTask`,
## `effect`, `setParentSize`, `setRenderSize` through `GlRenderPass.endRenderPass[T]`) are public.
## `GlSceneBlendTask` is created by `endRenderPass[GlSceneBlendTask](program, targetFbo)`.
##
## The GLES branches of the C++ (`clearColorTarget`, partial buffers) are not ported.

import ../../core/[types, geom]
import ../../renderer/effect
import ./[gl_ffi, program, render_target, render_task, state_cache]

type
  GlSceneBlendTask* = ref object of GlComposeTask
    srcFbo*, dstCopyFbo*: GlRenderTarget
    parentWidth*, parentHeight*: uint32

  GlDirectBlendTask* = ref object of GlRenderTask
    dstFbo*, dstCopyFbo*: GlRenderTarget
    copyRegion*: Region

  GlComplexBlendTask* = ref object of GlRenderTask
    dstFbo*, dstCopyFbo*: GlRenderTarget
    stencilTask*: GlRenderTask
    composeTask*: GlComposeTask

  GlGaussianBlurTask* = ref object of GlRenderTask
    horzTask*, vertTask*: GlRenderTask
    effect*: GaussianBlurEffect
    dstFbo*, dstCopyFbo0*, dstCopyFbo1*: GlRenderTarget

  GlEffectDropShadowTask* = ref object of GlRenderTask
    horzTask*, vertTask*: GlRenderTask
    effect*: DropShadowEffect
    dstFbo*, dstCopyFbo0*, dstCopyFbo1*: GlRenderTarget

  GlEffectTask* = ref object of GlRenderTask
    dstFbo*, dstCopyFbo*: GlRenderTarget

proc blit(w, h: int32, filter: GlEnum) =
  glCheck(blitFramebuffer(0, 0, w, h, 0, 0, w, h, GlColorBufferBit, filter))

# ---------------------------------------------------------------- GlSceneBlendTask

proc newGlSceneBlendTask*(program: GlProgram, target: GlId, fbo: GlRenderTarget,
    tasks: sink seq[GlRenderTask]): GlSceneBlendTask =
  result = GlSceneBlendTask()
  result.initCompose(program, target, fbo, tasks)

proc setParentSize*(t: GlSceneBlendTask, width, height: uint32) =
  t.parentWidth = width
  t.parentHeight = height

method run*(t: GlSceneBlendTask, state: var GlStateCache) =
  t.runCompose(state)

  if t.srcFbo.width == 0 or t.srcFbo.height == 0: return

  let vp = t.viewport
  let dstW = int32(t.dstCopyFbo.width)
  let dstH = int32(t.dstCopyFbo.height)

  state.bindFramebuffer(GlReadFramebuffer, t.targetFbo)
  state.bindFramebuffer(GlDrawFramebuffer, t.dstCopyFbo.resolvedFbo)
  state.viewport(0, 0, dstW, dstH)
  state.scissor(0, 0, dstW, dstH)
  glCheck(blitFramebuffer(vp.xMin, vp.yMin, vp.xMax, vp.yMax, 0, 0, vp.sw, vp.sh,
    GlColorBufferBit, GlLinear))

  state.bindFramebuffer(GlFramebuffer, t.targetFbo)
  state.viewport(0, 0, int32(t.parentWidth), int32(t.parentHeight))
  state.scissor(0, 0, int32(t.parentWidth), int32(t.parentHeight))

  state.disable(GlDepthTest)
  state.disable(GlBlend)
  t.runTask(state)
  state.enable(GlBlend)
  state.enable(GlDepthTest)

# ---------------------------------------------------------------- GlDirectBlendTask

proc newGlDirectBlendTask*(program: GlProgram, dstFbo, dstCopyFbo: GlRenderTarget,
    copyRegion: Region): GlDirectBlendTask =
  GlDirectBlendTask(program: program, dstFbo: dstFbo, dstCopyFbo: dstCopyFbo,
    copyRegion: copyRegion)

method run*(t: GlDirectBlendTask, state: var GlStateCache) =
  let width = t.copyRegion.sw
  let height = t.copyRegion.sh
  if width <= 0 or height <= 0: return

  let x = t.copyRegion.xMin
  let y = t.copyRegion.yMin
  if t.dstFbo.width == 0 or t.dstFbo.height == 0: return

  state.bindFramebuffer(GlReadFramebuffer, t.dstFbo.fbo)
  state.bindFramebuffer(GlDrawFramebuffer, t.dstCopyFbo.resolvedFbo)

  state.viewport(0, 0, width, height)
  state.scissor(0, 0, width, height)
  glCheck(blitFramebuffer(x, y, x + width, y + height, 0, 0, width, height,
    GlColorBufferBit, GlLinear))
  state.bindFramebuffer(GlFramebuffer, t.dstFbo.fbo)
  state.viewport(0, 0, t.dstFbo.viewport.sw, t.dstFbo.viewport.sh)

  state.disable(GlBlend)
  t.runTask(state)
  state.enable(GlBlend)

# ---------------------------------------------------------------- GlComplexBlendTask

proc newGlComplexBlendTask*(program: GlProgram, dstFbo, dstCopyFbo: GlRenderTarget,
    stencilTask: GlRenderTask, composeTask: GlComposeTask): GlComplexBlendTask =
  GlComplexBlendTask(program: program, dstFbo: dstFbo, dstCopyFbo: dstCopyFbo,
    stencilTask: stencilTask, composeTask: composeTask)

method run*(t: GlComplexBlendTask, state: var GlStateCache) =
  t.composeTask.run(state)

  if t.dstFbo.width == 0 or t.dstFbo.height == 0: return

  state.bindFramebuffer(GlReadFramebuffer, t.dstFbo.fbo)
  state.bindFramebuffer(GlDrawFramebuffer, t.dstCopyFbo.resolvedFbo)

  let vp = t.viewport
  let dstVp = t.dstFbo.viewport
  # copy the current fbo to the dstCopyFbo
  state.viewport(0, 0, dstVp.sw, dstVp.sh)
  state.scissor(0, 0, dstVp.sw, dstVp.sh)
  glCheck(blitFramebuffer(vp.xMin, vp.yMin, vp.xMax, vp.yMax, 0, 0, vp.sw, vp.sh,
    GlColorBufferBit, GlLinear))

  state.bindFramebuffer(GlFramebuffer, t.dstFbo.fbo)

  state.enable(GlStencilTest)
  state.colorMask(false, false, false, false)
  state.stencilFuncSeparate(GlFront, GlAlways, 0x0, 0xFF)
  state.stencilOpSeparate(GlFront, GlKeep, GlKeep, GlIncrWrap)

  state.stencilFuncSeparate(GlBack, GlAlways, 0x0, 0xFF)
  state.stencilOpSeparate(GlBack, GlKeep, GlKeep, GlDecrWrap)

  t.stencilTask.run(state)

  state.colorMask(true, true, true, true)
  state.stencilFunc(GlNotequal, 0x0, 0xFF)
  state.stencilOp(GlReplace, GlKeep, GlReplace)

  state.disable(GlBlend)

  t.runTask(state)

  state.disable(GlStencilTest)
  state.enable(GlBlend)

method normalizeDrawDepth*(t: GlComplexBlendTask, maxDepth: int32) =
  t.stencilTask.normalizeDrawDepth(maxDepth)
  t.drawDepth = t.drawDepth / float32(maxDepth)

# ---------------------------------------------------------------- GlGaussianBlurTask

proc newGlGaussianBlurTask*(dstFbo, dstCopyFbo0, dstCopyFbo1: GlRenderTarget): GlGaussianBlurTask =
  GlGaussianBlurTask(dstFbo: dstFbo, dstCopyFbo0: dstCopyFbo0, dstCopyFbo1: dstCopyFbo1)

method run*(t: GlGaussianBlurTask, state: var GlStateCache) =
  let width = int32(t.dstFbo.width)
  let height = int32(t.dstFbo.height)

  state.viewport(0, 0, width, height)
  state.scissor(0, 0, width, height)
  # we need to make a full copy of dst to intermediate buffers to be sure that they don't
  # contain prev data.
  state.bindFramebuffer(GlReadFramebuffer, t.dstFbo.fbo)
  state.bindFramebuffer(GlDrawFramebuffer, t.dstCopyFbo0.resolvedFbo)
  blit(width, height, GlNearest)
  state.bindFramebuffer(GlFramebuffer, t.dstFbo.fbo)

  state.disable(GlBlend)
  state.depthFunc(GlAlways)
  if t.effect.direction == 0:
    state.bindFramebuffer(GlReadFramebuffer, t.dstFbo.fbo)
    state.bindFramebuffer(GlDrawFramebuffer, t.dstCopyFbo1.resolvedFbo)
    blit(width, height, GlNearest)
    # horizontal blur
    state.bindFramebuffer(GlFramebuffer, t.dstCopyFbo1.resolvedFbo)
    t.horzTask.setViewport(t.viewport)
    t.horzTask.addBindResource(textureBinding(0, t.dstCopyFbo0.colorTex,
      GlShaderUniform.SourceTexture))
    t.horzTask.run(state)
    # vertical blur
    state.bindFramebuffer(GlFramebuffer, t.dstFbo.fbo)
    t.vertTask.setViewport(t.viewport)
    t.vertTask.addBindResource(textureBinding(0, t.dstCopyFbo1.colorTex,
      GlShaderUniform.SourceTexture))
    t.vertTask.run(state)
  elif t.effect.direction == 1:  # horizontal
    t.horzTask.setViewport(t.viewport)
    t.horzTask.addBindResource(textureBinding(0, t.dstCopyFbo0.colorTex,
      GlShaderUniform.SourceTexture))
    t.horzTask.run(state)
  elif t.effect.direction == 2:  # vertical
    t.vertTask.setViewport(t.viewport)
    t.vertTask.addBindResource(textureBinding(0, t.dstCopyFbo0.colorTex,
      GlShaderUniform.SourceTexture))
    t.vertTask.run(state)
  state.depthFunc(GlGreater)
  state.enable(GlBlend)

# ---------------------------------------------------------------- GlEffectDropShadowTask

proc newGlEffectDropShadowTask*(program: GlProgram, dstFbo, dstCopyFbo0,
    dstCopyFbo1: GlRenderTarget): GlEffectDropShadowTask =
  GlEffectDropShadowTask(program: program, dstFbo: dstFbo, dstCopyFbo0: dstCopyFbo0,
    dstCopyFbo1: dstCopyFbo1)

method run*(t: GlEffectDropShadowTask, state: var GlStateCache) =
  let width = int32(t.dstFbo.width)
  let height = int32(t.dstFbo.height)

  t.addBindResource(textureBinding(0, t.dstCopyFbo0.colorTex, GlShaderUniform.SourceTexture))
  t.addBindResource(textureBinding(1, t.dstCopyFbo1.colorTex, GlShaderUniform.BlurTexture))

  state.viewport(0, 0, width, height)
  state.scissor(0, 0, width, height)

  # we need to make a full copy of dst to intermediate buffers to be sure that they don't
  # contain prev data.
  state.bindFramebuffer(GlReadFramebuffer, t.dstFbo.fbo)
  state.bindFramebuffer(GlDrawFramebuffer, t.dstCopyFbo0.resolvedFbo)
  blit(width, height, GlNearest)
  state.bindFramebuffer(GlReadFramebuffer, t.dstFbo.fbo)
  state.bindFramebuffer(GlDrawFramebuffer, t.dstCopyFbo1.resolvedFbo)
  blit(width, height, GlNearest)

  state.disable(GlBlend)
  state.depthFunc(GlAlways)
  # when sigma is 0, no blur is applied, and the original image is used directly as the shadow.
  if not zero(t.effect.sigma):
    # horizontal blur
    state.bindFramebuffer(GlFramebuffer, t.dstCopyFbo0.resolvedFbo)
    t.horzTask.setViewport(t.viewport)
    t.horzTask.addBindResource(textureBinding(0, t.dstCopyFbo1.colorTex,
      GlShaderUniform.SourceTexture))
    t.horzTask.run(state)
    # vertical blur
    state.bindFramebuffer(GlFramebuffer, t.dstCopyFbo1.resolvedFbo)
    t.vertTask.setViewport(t.viewport)
    t.vertTask.addBindResource(textureBinding(0, t.dstCopyFbo0.colorTex,
      GlShaderUniform.SourceTexture))
    t.vertTask.run(state)
    # copy original image to intermediate buffer
    state.bindFramebuffer(GlReadFramebuffer, t.dstFbo.fbo)
    state.bindFramebuffer(GlDrawFramebuffer, t.dstCopyFbo0.resolvedFbo)
    blit(width, height, GlNearest)
  # run drop shadow effect
  state.bindFramebuffer(GlFramebuffer, t.dstFbo.fbo)
  t.runTask(state)
  state.depthFunc(GlGreater)
  state.enable(GlBlend)

# ---------------------------------------------------------------- GlEffectTask

proc newGlEffectTask*(program: GlProgram, dstFbo, dstCopyFbo: GlRenderTarget): GlEffectTask =
  GlEffectTask(program: program, dstFbo: dstFbo, dstCopyFbo: dstCopyFbo)

method run*(t: GlEffectTask, state: var GlStateCache) =
  let width = int32(t.dstFbo.width)
  let height = int32(t.dstFbo.height)
  # get targets handles and pass to shader
  t.addBindResource(textureBinding(0, t.dstCopyFbo.colorTex, GlShaderUniform.SourceTexture))

  state.viewport(0, 0, width, height)
  state.scissor(0, 0, width, height)
  # we need to make a full copy of dst to intermediate buffers to be sure that they don't
  # contain prev data.
  state.bindFramebuffer(GlReadFramebuffer, t.dstFbo.fbo)
  state.bindFramebuffer(GlDrawFramebuffer, t.dstCopyFbo.resolvedFbo)
  blit(width, height, GlNearest)
  state.bindFramebuffer(GlFramebuffer, t.dstFbo.fbo)

  # run the single-pass effect
  state.disable(GlBlend)
  state.depthFunc(GlAlways)
  t.runTask(state)
  state.depthFunc(GlGreater)
  state.enable(GlBlend)
