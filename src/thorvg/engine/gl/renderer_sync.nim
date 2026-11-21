## GL renderer part 5: target, clear and sync (port of `GlRenderer::target(display, surface,
## context, id, w, h, cs)`, `clear`, `sync` of tvgGlRenderer.cpp, unit G4b).
##
## Import this module to get the complete GL renderer (it re-exports `renderer_comp` and so
## `renderer_prepare`, `renderer_draw`, `renderer`).
##
## - `target(r, display, surface, context, fboId, w, h, cs)`: binds the renderer to a GL context
##   (WGL: `surface` = HDC, `context` = HGLRC, handles as `int`) and the user framebuffer
##   `fboId` (needs colour + depth24/stencil8). Only `ColorSpace.ABGR8888S` is supported.
## - `clear`: the next `sync` clears the user framebuffer before blitting.
## - `sync`: runs the whole render-pass stack, resolves the root target into the user
##   framebuffer and restores the cache (`invalidate`).
## - `newGlTargetRenderer(dc, rc, fboId, w, h)`: a ready renderer (nil when the target fails).
##   `glInit()` must have succeeded; the context is made current.

import ../../core/[types, geom]
import ../../renderer/render
import ./[gl_ffi, gpu_buffer, programs, render_pass, render_target, render_task, renderer_comp,
  state_cache, texture_mgr, wgl_ffi]

export renderer_comp

proc target*(r: GlRenderer, display, surface, context: int, fboId: GlId, w, h: uint32,
    cs: ColorSpace): Result =
  ## The GL target of the renderer (`GlCanvas::target` calls this). Handles are 0 when unset.
  if cs != ColorSpace.ABGR8888S: return Result.NonSupport

  # context zero is invalid
  if context == 0 or w == 0 or h == 0: return Result.InvalidArguments

  r.state.invalidate()

  if r.context != 0:
    discard r.currentContext()
    if r.context != context: r.textures.clear()

  r.flush()

  r.surface.stride = w
  r.surface.w = w
  r.surface.h = h
  r.surface.setup(cs)
  r.vport = Region(xMin: 0, yMin: 0, xMax: int32(w), yMax: int32(h))

  r.display = display
  r.drawSurface = surface
  r.context = context
  r.targetFboId = fboId

  if not r.currentContext(): return Result.InsufficientCondition
  # cached values belong to the previous context: numeric ids can be reused by the new one
  r.state.invalidate()

  r.rootTarget.viewport = r.vport
  r.rootTarget.init(r.state, w, h, fboId)
  r.state.invalidate()
  Result.Success

method clear*(r: GlRenderer): bool =
  if r.rootTarget.invalid: return false

  r.mClearBuffer = true
  true

method sync*(r: GlRenderer): bool =
  # State can also be touched while preparing textures and render targets: invalidate even
  # for an empty sync so the next render replays every assumption.
  r.state.invalidate()

  # nothing to be done
  if r.passStack.len == 0: return true

  discard r.currentContext()

  # Only the state ThorVG establishes itself; applications sharing the context must reset
  # any other GL state that can affect rendering before calling sync().
  r.state.enable(GlBlend)
  r.state.enable(GlScissorTest)
  glCheck(cullFace(GlFrontAndBack))
  glCheck(frontFace(GlCcw))
  r.state.enable(GlDepthTest)
  r.state.depthFunc(GlGreater)

  let task = r.passStack[0].endRenderPass[:GlBlitTask](r.programs[ord(rtBlit)], r.targetFboId)
  r.prepareBlitTask(task)
  task.clearBuffer = r.mClearBuffer
  task.targetViewport = Region(xMin: 0, yMin: 0, xMax: int32(r.surface.w),
    yMax: int32(r.surface.h))

  if r.stage.flushToGPU(r.state):
    r.stage.bindStage(r.state)
    task.run(r.state)
  r.stage.unbind(r.state)

  r.state.disable(GlScissorTest)
  r.state.invalidate()
  r.clearDisposes()

  # the clear flag is a one-shot
  r.mClearBuffer = false
  true

proc newGlTargetRenderer*(dc, rc: int, fboId: GlId, w, h: int): GlRenderer =
  ## A renderer already bound to the context `rc` (device context `dc`) and framebuffer
  ## `fboId`; nil when the context cannot be made current or `target` fails.
  if w <= 0 or h <= 0 or not wglMakeCurrent(dc, rc): return nil
  let r = newGlRenderer()
  if r.target(0, dc, rc, fboId, uint32(w), uint32(h), ColorSpace.ABGR8888S) != Result.Success:
    r.destroy()
    return nil
  r
