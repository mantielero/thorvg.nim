## GL renderer part 4: compositing and scene effects (port of the composition half of
## tvgGlRenderer.cpp, unit G4b). Part 5 is `renderer_sync.nim` (target / sync / clear).
##
## `RenderMethod` overrides added here: `target(region, cs, flags)` (composite target),
## `beginComposite`, `endComposite`, `effectPrepare`, `effectRegion`, `effectRender`,
## `effectDispose`. Plain procs: `endRenderPass(r, cmp)` (ends the compose pass(es) into the
## parent pass: mask, scene blend or draw-blit) and `prepareBlitTask`.
##
## Methods living in another module than the type only dispatch when that module is part of
## the program: import `renderer_sync` (it re-exports this module and `renderer_prepare`) to get
## the whole GL renderer.
##
## Effects hooks (D-G4c-1): `effectPrepare` = `ensureEffectPools` + `effect.update`,
## `effectRegion` = `effect.region`, `effectRender` = `effect.render(effect, currentPass(),
## blendPool, state)` (`cmp` and `direct` are unused as in C++), `effectDispose` = `dispose`.

import ../../core/[types, geom]
import ../../renderer/[render, effect]
import ./[effects, gl_common, gpu_buffer, program, programs, render_pass, render_target,
  render_task, renderer_prepare, task_blend]

export renderer_prepare

func uw(r: Region): uint32 = uint32(max(r.sw, 0))
func uh(r: Region): uint32 = uint32(max(r.sh, 0))

proc prepareBlitTask*(r: GlRenderer, task: GlBlitTask) =
  ## Full-surface quad of the final blit into the user framebuffer.
  r.prepareCmpTask(task, Region(xMin: 0, yMin: 0, xMax: int32(r.surface.w),
    yMax: int32(r.surface.h)), r.surface.w, r.surface.h)
  task.addBindResource(textureBinding(0, task.colorTex, GlShaderUniform.SourceTexture))

func maskProgramIndex(m: MaskMethod): int =
  ## Index into `programs` of the mask program (-1: none).
  case m
  of MaskMethod.Alpha: ord(rtMaskAlpha)
  of MaskMethod.InvAlpha: ord(rtMaskAlphaInv)
  of MaskMethod.Luma: ord(rtMaskLuma)
  of MaskMethod.InvLuma: ord(rtMaskLumaInv)
  of MaskMethod.Add: ord(rtMaskAdd)
  of MaskMethod.Subtract: ord(rtMaskSub)
  of MaskMethod.Intersect: ord(rtMaskIntersect)
  of MaskMethod.Difference: ord(rtMaskDifference)
  of MaskMethod.Lighten: ord(rtMaskLighten)
  of MaskMethod.Darken: ord(rtMaskDarken)
  of MaskMethod.None: -1

proc colorInfoBinding(r: GlRenderer, binding: uint32, opacity: uint8): GlBindingResource =
  let info = [uint32(opacity), 0'u32, 0, 0]
  uniformBinding(binding, GlShaderUniformBlock.ColorInfo, r.stage.getBufferId(),
    r.stage.push(info, true), 16)

proc rearrangeBlendMask(r: GlRenderer, cmp: GlCompositor) =
  ## Blending + masking in one compositor: the self scene is masked but not blended, the
  ## previous scene is blended but not masked (the stack order becomes prev, mask, self).
  if r.passStack.len < 3 or r.composeStack.len == 0: return
  let selfPass = r.passStack.pop()
  let prevPass = r.passStack.pop()
  let maskPass = r.passStack.pop()
  r.passStack.add prevPass
  r.passStack.add maskPass
  r.passStack.add selfPass

  let prevCompose = r.composeStack[^1]
  let opacity = cmp.opacity
  let blendMethod = cmp.blendMethod
  cmp.meth = prevCompose.meth
  cmp.opacity = 255
  cmp.blendMethod = BlendMethod.Normal
  prevCompose.meth = MaskMethod.None
  prevCompose.opacity = opacity
  prevCompose.blendMethod = blendMethod

proc composeMask(r: GlRenderer, cmp: GlCompositor) =
  let selfPass = r.passStack.pop()
  let maskPass = r.passStack.pop()  # the mask is pushed first
  let index = maskProgramIndex(cmp.meth)
  let pass = r.currentPass()
  if index >= 0 and pass != nil and not selfPass.isEmpty and not maskPass.isEmpty:
    let program = r.programs[index]
    let prevTask = maskPass.endRenderPass[:GlComposeTask](nil, pass.getFboId())
    prevTask.setDrawDepth(int32(pass.nextDrawDepth()))
    prevTask.setRenderSize(cmp.bbox.uw, cmp.bbox.uh)
    prevTask.setViewport(cmp.bbox)

    let task = selfPass.endRenderPass[:GlDrawBlitTask](program, pass.getFboId())
    task.setRenderSize(cmp.bbox.uw, cmp.bbox.uh)
    task.prevTask = prevTask
    r.prepareCmpTask(task, cmp.bbox, selfPass.getFboWidth(), selfPass.getFboHeight())
    task.addBindResource(textureBinding(0, selfPass.getTextureId(),
      GlShaderUniform.SourceTexture))
    task.addBindResource(textureBinding(1, maskPass.getTextureId(),
      GlShaderUniform.MaskTexture))
    task.setDrawDepth(int32(pass.nextDrawDepth()))
    let vp = pass.getViewport()
    task.setParentSize(uint32(max(vp.sw, 0)), uint32(max(vp.sh, 0)))
    pass.addRenderTask(task)

proc composeSceneBlend(r: GlRenderer, cmp: GlCompositor) =
  ## Non native blend of a whole scene (`GlSceneBlendTask`).
  let renderPass = r.passStack.pop()
  let pass = r.currentPass()
  if pass != nil and not renderPass.isEmpty:
    ensureEffectPools(r.blendPool, r.surface.w, r.surface.h)
    let dstCopyFbo = r.blendPool[1].getRenderTarget(r.state, renderPass.getViewport())
    let program = r.getBlendProgram(cmp.blendMethod, BlendSource.Scene)
    let task = renderPass.endRenderPass[:GlSceneBlendTask](program, pass.getFboId())
    task.srcFbo = pass.fbo
    task.dstCopyFbo = dstCopyFbo
    task.setRenderSize(cmp.bbox.uw, cmp.bbox.uh)
    r.prepareCmpTask(task, cmp.bbox, renderPass.getFboWidth(), renderPass.getFboHeight())
    task.setDrawDepth(int32(pass.nextDrawDepth()))
    task.addBindResource(r.colorInfoBinding(0, cmp.opacity))
    task.addBindResource(textureBinding(0, renderPass.getTextureId(),
      GlShaderUniform.SourceTexture))
    task.addBindResource(textureBinding(1, dstCopyFbo.colorTex,
      GlShaderUniform.DestinationTexture))
    let vp = pass.getViewport()
    task.setParentSize(uint32(max(vp.sw, 0)), uint32(max(vp.sh, 0)))
    pass.addRenderTask(task)

proc composeDrawBlit(r: GlRenderer, cmp: GlCompositor) =
  ## Plain (or natively blended) composition: the pass is drawn as an image with the opacity.
  let renderPass = r.passStack.pop()
  let pass = r.currentPass()
  if pass != nil and not renderPass.isEmpty:
    let task = renderPass.endRenderPass[:GlDrawBlitTask](r.programs[ord(rtImage)],
      pass.getFboId())
    task.blendMethod = cmp.blendMethod
    task.setRenderSize(cmp.bbox.uw, cmp.bbox.uh)
    r.prepareCmpTask(task, cmp.bbox, renderPass.getFboWidth(), renderPass.getFboHeight())
    task.setDrawDepth(int32(pass.nextDrawDepth()))
    task.setViewMatrix(identity())
    task.addBindResource(r.colorInfoBinding(1, cmp.opacity))
    task.addBindResource(textureBinding(0, renderPass.getTextureId(), GlShaderUniform.Texture))
    let vp = pass.getViewport()
    task.setParentSize(uint32(max(vp.sw, 0)), uint32(max(vp.sh, 0)))
    pass.addRenderTask(task)

proc endRenderPass*(r: GlRenderer, cmp: RenderCompositor) =
  ## Ends the compose pass(es) of `cmp` and queues the task that draws them into the parent.
  let glCmp = GlCompositor(cmp)
  if glCmp.flags * {CompositionFlag.Blending, CompositionFlag.Masking} ==
      {CompositionFlag.Blending, CompositionFlag.Masking}:
    r.rearrangeBlendMask(glCmp)

  if glCmp.meth != MaskMethod.None: r.composeMask(glCmp)
  elif not isNativeBlend(glCmp.blendMethod): r.composeSceneBlend(glCmp)
  else: r.composeDrawBlit(glCmp)

# ---------------------------------------------------------------- RenderMethod overrides

method target*(r: GlRenderer, region: Region, cs: ColorSpace,
    flags: CompositionFlags): RenderCompositor =
  let pass = r.currentPass()
  if pass == nil or pass.isEmpty: return nil

  let vp = region.intersect(pass.getViewport())
  let cmp = newGlCompositor(vp, flags)
  r.composeStack.add cmp
  cmp

method beginComposite*(r: GlRenderer, cmp: RenderCompositor, m: MaskMethod,
    opacity: uint8): bool =
  if cmp == nil or r.passStack.len == 0: return false

  let glCmp = GlCompositor(cmp)
  glCmp.meth = m
  glCmp.opacity = opacity
  glCmp.blendMethod = r.mBlendMethod

  let index = r.passStack.len - 1
  while r.composePool.len <= index:
    r.composePool.add newGlRenderTargetPool(r.surface.w, r.surface.h)

  if glCmp.bbox.valid:
    r.passStack.add newGlRenderPass(r.composePool[index].getRenderTarget(r.state, glCmp.bbox))
  else:
    r.passStack.add newGlRenderPass(nil)
  true

method endComposite*(r: GlRenderer, cmp: RenderCompositor): bool =
  if r.composeStack.len == 0 or RenderCompositor(r.composeStack[^1]) != cmp: return false

  # end the current render pass
  let current = r.composeStack.pop()
  r.endRenderPass(current)
  true

method effectPrepare*(r: GlRenderer, effect: RenderEffect, tm: Matrix) =
  # the effects need the two intermediate target pools
  ensureEffectPools(r.blendPool, r.surface.w, r.surface.h)
  r.effect.update(effect, tm)

method effectRegion*(r: GlRenderer, effect: RenderEffect): bool =
  r.effect.region(effect)

method effectRender*(r: GlRenderer, cmp: RenderCompositor, effect: RenderEffect,
    direct: bool): bool =
  let pass = r.currentPass()
  if pass == nil: return false
  ensureEffectPools(r.blendPool, r.surface.w, r.surface.h)
  r.effect.render(effect, pass, r.blendPool, r.state)

method effectDispose*(r: GlRenderer, effect: RenderEffect) =
  effects.dispose(effect)
