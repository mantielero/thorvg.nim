## GL render tasks (port of tvgGlRenderTask.cpp/.h, first half: base task, stencil/cover,
## compose, blit, draw-blit and clip tasks). The blend and effect tasks are in `task_blend.nim`.
##
## C++ `GlRenderTask*` ownership becomes plain `ref`s: a task owns the tasks it lists (`tasks`,
## `stencilTasks`, `clipTask`, ...), nothing is deleted by hand. The C++ virtual `run` is
## `method run(task, state: var GlStateCache)`; `GlRenderTask::run` called explicitly by a
## subclass is `runTask`, `GlComposeTask::run` is `runCompose`. `GlStateCache` is move-only, so
## the cache is always passed explicitly as `var`.
##
## API (what G4a/G4b/G4c use):
## - `GlVertexLayout`, `GlBindingResource` (`uniformBinding(bindPoint, block, bufferId, offset,
##   size)` / `textureBinding(bindPoint, textureId, uniform)` build the two C++ constructors;
##   `kind` is the C++ `type` tag). Offsets/ranges are `int` byte counts (C++ `uint32_t`).
## - `GlRenderTask`: `newGlRenderTask(program, blendMethod)`, `addVertexLayout`,
##   `setVertexColor`, `addBindResource`, `setDrawRange(offset, count)`, `setViewport`,
##   `setDrawDepth(int32)`, `setViewMatrix`, public fields (`useDrawArrays`, `arrayMode`...),
##   `method normalizeDrawDepth`, `method run`.
## - `GlStencilCoverTask` (`newGlStencilCoverTask(stencil, cover, mode)`, lists are public),
##   `GlComposeTask` (`initCompose` for subclasses, `setRenderSize`, `getSelfFbo`,
##   `getResolveFboId`, `onResolve`), `GlBlitTask` (`colorTex`, `targetViewport`),
##   `GlDrawBlitTask` (`prevTask`, `setParentSize`), `GlClipTask`.
## - `GlRenderPass.endRenderPass[T]` (render_pass.nim) creates the compose-task subclasses.

import ../../core/[types, geom]
import ./[gl_common, gl_ffi, program, render_target, state_cache]
from ./shader import logGlError

type
  GlVertexLayout* = object
    index*, size*, stride*: uint32
    offset*: int
    ty*: GlEnum = GlFloat
    normalized*: bool
    arrayBufferId*: GlId  ## VBO supplying this attribute; always required

  GlBindingKind* {.pure.} = enum
    UniformBuffer, Texture

  GlBindingResource* = object
    kind*: GlBindingKind
    uniform*: GlShaderUniform           ## texture bindings
    uniformBlock*: GlShaderUniformBlock ## uniform buffer bindings
    bindPoint*: uint32  ## texture unit, or uniform buffer binding index
    resourceId*: GlId   ## texture id for `Texture`, UBO id for `UniformBuffer`
    bufferOffset*, bufferRange*: int

  GlRenderTask* = ref object of RootObj
    program*: GlProgram
    drawDepth*: float32
    viewport*: Region
    indexCnt*, indexOffset*: uint32
    vertexLayout*: seq[GlVertexLayout]
    bindResources*: seq[GlBindingResource]
    arrayOffset*: uint32
    arrayMode*: GlEnum = GlTriangles
    viewMatrix*: Matrix
    vertexColor*: array[4, float32]
    useViewMatrix*, useVertexColor*, useDrawArrays*: bool
    blendMethod*: BlendMethod = BlendMethod.Normal

  GlStencilCoverTask* = ref object of GlRenderTask
    stencilTasks*, coverTasks*: seq[GlRenderTask]
    stencilMode*: GlStencilMode

  GlComposeTask* = ref object of GlRenderTask
    targetFbo*: GlId
    fbo*: GlRenderTarget
    tasks*: seq[GlRenderTask]
    renderWidth*, renderHeight*: uint32
    clearBuffer*: bool = true

  GlBlitTask* = ref object of GlComposeTask
    colorTex*: GlId
    targetViewport*: Region

  GlDrawBlitTask* = ref object of GlComposeTask
    prevTask*: GlRenderTask
    parentWidth*, parentHeight*: uint32

  GlClipTask* = ref object of GlRenderTask
    clipTask*, maskTask*: GlRenderTask

func uniformBinding*(bindPoint: uint32, blk: GlShaderUniformBlock, bufferId: GlId,
    offset, size: int): GlBindingResource =
  GlBindingResource(kind: GlBindingKind.UniformBuffer, uniformBlock: blk,
    bindPoint: bindPoint, resourceId: bufferId, bufferOffset: offset, bufferRange: size)

func textureBinding*(bindPoint: uint32, textureId: GlId,
    uniform: GlShaderUniform): GlBindingResource =
  GlBindingResource(kind: GlBindingKind.Texture, uniform: uniform, bindPoint: bindPoint,
    resourceId: textureId)

# ---------------------------------------------------------------- GlRenderTask

proc newGlRenderTask*(program: GlProgram, blendMethod = BlendMethod.Normal): GlRenderTask =
  GlRenderTask(program: program, blendMethod: blendMethod)

proc addVertexLayout*(t: GlRenderTask, layout: GlVertexLayout) =
  doAssert layout.arrayBufferId != 0
  t.vertexLayout.add layout

proc setVertexColor*(t: GlRenderTask, r, g, b, a: float32) =
  t.useVertexColor = true
  t.vertexColor = [r, g, b, a]

proc addBindResource*(t: GlRenderTask, binding: GlBindingResource) =
  if binding.kind == GlBindingKind.UniformBuffer:
    doAssert t.program != nil
    if t.program.getUniformBlockIndex(binding.uniformBlock) < 0: return
    if not t.program.setUniformBlockBinding(binding.uniformBlock, binding.bindPoint):
      logGlError "Conflicting uniform block binding for program " & $t.program.getProgramId()
      return
  t.bindResources.add binding

proc setDrawRange*(t: GlRenderTask, offset, count: uint32) =
  t.useDrawArrays = false
  t.indexOffset = offset
  t.indexCnt = count

proc setViewport*(t: GlRenderTask, vp: Region) =
  t.viewport = vp
  t.viewport.xMax = max(vp.xMin, vp.xMax)
  t.viewport.yMax = max(vp.yMin, vp.yMax)

proc setDrawDepth*(t: GlRenderTask, depth: int32) = t.drawDepth = float32(depth)

proc setViewMatrix*(t: GlRenderTask, matrix: Matrix) =
  t.viewMatrix = matrix
  t.useViewMatrix = true

method normalizeDrawDepth*(t: GlRenderTask, maxDepth: int32) {.base.} =
  t.drawDepth = t.drawDepth / float32(maxDepth)

proc setBlendFunc(state: var GlStateCache, m: BlendMethod) =
  ## Native blending on premultiplied shader output.
  case m
  of BlendMethod.Normal:
    state.blendFuncSeparate(GlOne, GlOneMinusSrcAlpha, GlOne, GlOneMinusSrcAlpha)
  of BlendMethod.Screen:
    state.blendFuncSeparate(GlOne, GlOneMinusSrcColor, GlOne, GlOneMinusSrcAlpha)
  of BlendMethod.Exclusion:
    state.blendFuncSeparate(GlOneMinusDstColor, GlOneMinusSrcColor, GlOne, GlOneMinusSrcAlpha)
  of BlendMethod.Add:  # Porter-Duff lighter: add both RGB and alpha.
    state.blendFuncSeparate(GlOne, GlOne, GlOne, GlOne)
  else: discard

proc runTask*(t: GlRenderTask, state: var GlStateCache) =
  ## `GlRenderTask::run`: bind the program, uniforms, layout, bindings, blend; draw.
  state.useProgram(t.program.getProgramId())

  let dLoc = t.program.getUniformLocation(GlShaderUniform.Depth)
  if dLoc >= 0:
    glCheck(uniform1f(dLoc, t.drawDepth))

  let vLoc = t.program.getUniformLocation(GlShaderUniform.ViewMatrix)
  if vLoc >= 0:
    let matrix = if t.useViewMatrix: t.viewMatrix else: identity()
    glCheck(uniformMatrix3fv(vLoc, getMatrix3(matrix)))

  state.scissor(t.viewport.xMin, t.viewport.yMin, t.viewport.sw, t.viewport.sh)

  state.beginVertexLayout()
  var hasVertexColorLayout = false
  for layout in t.vertexLayout:
    doAssert layout.arrayBufferId != 0
    if layout.index == 1: hasVertexColorLayout = true
    state.setVertexAttribPointer(layout.index, int32(layout.size), layout.ty,
      layout.normalized, int32(layout.stride), layout.offset, layout.arrayBufferId)
  if t.useVertexColor and not hasVertexColorLayout:
    state.setVertexAttrib4f(1, t.vertexColor[0], t.vertexColor[1], t.vertexColor[2],
      t.vertexColor[3])
  state.endVertexLayout()

  for binding in t.bindResources:
    if binding.kind == GlBindingKind.Texture:
      state.bindTexture2D(GlTexture0 + binding.bindPoint, binding.resourceId)
      t.program.setSampler(binding.uniform, int32(binding.bindPoint))
    else:
      glCheck(bindBufferRange(GlUniformBuffer, binding.bindPoint, binding.resourceId,
        binding.bufferOffset, binding.bufferRange))

  state.setBlendFunc(t.blendMethod)

  if t.useDrawArrays:
    glCheck(drawArrays(t.arrayMode, int32(t.arrayOffset), int32(t.indexCnt)))
  else:
    glCheck(drawElements(GlTriangles, int32(t.indexCnt), GlUnsignedInt, int(t.indexOffset)))

method run*(t: GlRenderTask, state: var GlStateCache) {.base.} =
  t.runTask(state)

# ---------------------------------------------------------------- GlStencilCoverTask

proc newGlStencilCoverTask*(stencil, cover: GlRenderTask,
    mode: GlStencilMode): GlStencilCoverTask =
  GlStencilCoverTask(stencilTasks: @[stencil], coverTasks: @[cover], stencilMode: mode)

method run*(t: GlStencilCoverTask, state: var GlStateCache) =
  state.enable(GlStencilTest)

  if t.stencilMode == GlStencilMode.Stroke:
    state.stencilFunc(GlNotequal, 0x1, 0xFF)
    state.stencilOp(GlKeep, GlKeep, GlReplace)
  else:
    state.stencilFuncSeparate(GlFront, GlAlways, 0x0, 0xFF)
    state.stencilOpSeparate(GlFront, GlKeep, GlKeep, GlIncrWrap)

    state.stencilFuncSeparate(GlBack, GlAlways, 0x0, 0xFF)
    state.stencilOpSeparate(GlBack, GlKeep, GlKeep, GlDecrWrap)
  state.colorMask(false, false, false, false)

  for p in t.stencilTasks: p.run(state)

  if t.stencilMode == GlStencilMode.FillEvenOdd:
    state.stencilFunc(GlNotequal, 0x00, 0x01)
    state.stencilOp(GlReplace, GlKeep, GlReplace)
  else:
    state.stencilFunc(GlNotequal, 0x0, 0xFF)
    state.stencilOp(GlKeep, GlKeep, GlReplace)

  state.colorMask(true, true, true, true)

  for p in t.coverTasks: p.run(state)

  state.disable(GlStencilTest)

method normalizeDrawDepth*(t: GlStencilCoverTask, maxDepth: int32) =
  for p in t.coverTasks: p.normalizeDrawDepth(maxDepth)
  for p in t.stencilTasks: p.normalizeDrawDepth(maxDepth)

# ---------------------------------------------------------------- GlComposeTask

proc initCompose*(t: GlComposeTask, program: GlProgram, target: GlId, fbo: GlRenderTarget,
    tasks: sink seq[GlRenderTask]) =
  ## `GlComposeTask::GlComposeTask`: the task takes over the list.
  t.program = program
  t.targetFbo = target
  t.fbo = fbo
  t.tasks = tasks

proc newGlComposeTask*(program: GlProgram, target: GlId, fbo: GlRenderTarget,
    tasks: sink seq[GlRenderTask]): GlComposeTask =
  result = GlComposeTask()
  result.initCompose(program, target, fbo, tasks)

proc setRenderSize*(t: GlComposeTask, width, height: uint32) =
  t.renderWidth = width
  t.renderHeight = height

func getSelfFbo*(t: GlComposeTask): GlId = t.fbo.fbo
func getResolveFboId*(t: GlComposeTask): GlId = t.fbo.resolvedFbo

proc onResolve*(t: GlComposeTask, state: var GlStateCache) =
  let w = int32(t.renderWidth)
  let h = int32(t.renderHeight)
  state.bindFramebuffer(GlReadFramebuffer, t.getSelfFbo())
  state.bindFramebuffer(GlDrawFramebuffer, t.getResolveFboId())
  glCheck(blitFramebuffer(0, 0, w, h, 0, 0, w, h, GlColorBufferBit, GlNearest))

proc runCompose*(t: GlComposeTask, state: var GlStateCache) =
  ## `GlComposeTask::run`: clear the target, run the child tasks, resolve the MSAA buffer.
  state.bindFramebuffer(GlFramebuffer, t.getSelfFbo())

  # we must clear all area of fbo
  let fw = int32(t.fbo.width)
  let fh = int32(t.fbo.height)
  state.viewport(0, 0, fw, fh)
  state.scissor(0, 0, fw, fh)
  state.clearColor(0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32)
  state.clearStencil(0)
  state.clearDepth(0.0)
  state.depthMask(true)

  glCheck(clear(GlColorBufferBit or GlStencilBufferBit or GlDepthBufferBit))
  state.depthMask(false)
  state.viewport(0, 0, int32(t.renderWidth), int32(t.renderHeight))
  state.scissor(0, 0, int32(t.renderWidth), int32(t.renderHeight))

  for p in t.tasks: p.run(state)

  # reset scissor box
  state.scissor(0, 0, fw, fh)
  t.onResolve(state)

method run*(t: GlComposeTask, state: var GlStateCache) =
  t.runCompose(state)

# ---------------------------------------------------------------- GlBlitTask

proc newGlBlitTask*(program: GlProgram, target: GlId, fbo: GlRenderTarget,
    tasks: sink seq[GlRenderTask]): GlBlitTask =
  result = GlBlitTask(colorTex: fbo.colorTex)
  result.initCompose(program, target, fbo, tasks)

method run*(t: GlBlitTask, state: var GlStateCache) =
  t.runCompose(state)

  state.bindFramebuffer(GlFramebuffer, t.targetFbo)
  state.viewport(t.targetViewport.xMin, t.targetViewport.yMin, t.targetViewport.sw,
    t.targetViewport.sh)

  if t.clearBuffer:
    state.clearColor(0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32)
    glCheck(clear(GlColorBufferBit))

  state.disable(GlDepthTest)
  state.enable(GlBlend)

  t.runTask(state)

# ---------------------------------------------------------------- GlDrawBlitTask

proc newGlDrawBlitTask*(program: GlProgram, target: GlId, fbo: GlRenderTarget,
    tasks: sink seq[GlRenderTask]): GlDrawBlitTask =
  result = GlDrawBlitTask()
  result.initCompose(program, target, fbo, tasks)

proc setParentSize*(t: GlDrawBlitTask, width, height: uint32) =
  t.parentWidth = width
  t.parentHeight = height

method run*(t: GlDrawBlitTask, state: var GlStateCache) =
  if t.prevTask != nil: t.prevTask.run(state)

  t.runCompose(state)

  state.bindFramebuffer(GlFramebuffer, t.targetFbo)
  state.viewport(0, 0, int32(t.parentWidth), int32(t.parentHeight))
  state.scissor(0, 0, int32(t.parentWidth), int32(t.parentHeight))

  t.runTask(state)

# ---------------------------------------------------------------- GlClipTask

proc newGlClipTask*(clip, mask: GlRenderTask): GlClipTask =
  GlClipTask(clipTask: clip, maskTask: mask)

method run*(t: GlClipTask, state: var GlStateCache) =
  state.enable(GlStencilTest)
  state.colorMask(false, false, false, false)
  # draw clip path as normal stencil mask
  state.stencilFuncSeparate(GlFront, GlAlways, 0x1, 0xFF)
  state.stencilOpSeparate(GlFront, GlKeep, GlKeep, GlIncrWrap)

  state.stencilFuncSeparate(GlBack, GlAlways, 0x1, 0xFF)
  state.stencilOpSeparate(GlBack, GlKeep, GlKeep, GlDecrWrap)

  t.clipTask.run(state)

  # draw clip mask
  state.depthMask(true)
  state.stencilFunc(GlEqual, 0x0, 0xFF)
  state.stencilOp(GlReplace, GlKeep, GlReplace)

  t.maskTask.run(state)

  state.colorMask(true, true, true, true)
  state.depthMask(false)
  state.disable(GlStencilTest)

method normalizeDrawDepth*(t: GlClipTask, maxDepth: int32) =
  t.clipTask.normalizeDrawDepth(maxDepth)
  t.maskTask.normalizeDrawDepth(maxDepth)
