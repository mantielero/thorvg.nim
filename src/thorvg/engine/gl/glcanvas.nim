## OpenGL canvas facade (`GlCanvas` of tvgCanvas.cpp, unit G5).
##
## A separate import (`import thorvg/engine/gl/glcanvas`): the default `import thorvg` stays free
## of GL (decision D-GL-3 is pending). The canvas draws into a framebuffer object of a GL 3.3+
## context created by the application. The framebuffer needs a RGBA8 colour attachment and a
## DEPTH24_STENCIL8 attachment. Pixels are premultiplied RGBA8 (`ColorSpace.ABGR8888S` at the
## API level, as in C++).
##
## Windows: `dc` = HDC, `rc` = HGLRC (`wgl_ffi.wglCreateOffscreen`).
## Linux: `dc` = 0, `rc` = GLFWwindow* (`wgl_ffi.wglCreateOffscreen`, GLFW).
##
##   let (ok, ctx) = wglCreateOffscreen(400, 300)
##   let c = newGlCanvas(ctx.dc, ctx.rc, ctx.fbo, 400, 300)
##   check c.add(shape)            # `check` from `thorvg`
##   c.render()                    # update + draw + sync, the result is in the framebuffer
##   c.destroy()                   # BEFORE the context is destroyed
##
## `newGlCanvas` raises `ValueError` when the target cannot be set up (context cannot be made
## current, GL < 3.3, size zero). `glTerm()` is `GlRenderer::term()`: forget the loaded entry points.

import ../../core/[types]
import ../../renderer/canvas
import ./[gl_ffi, renderer_sync, wgl_ffi]

export canvas
export GlId, glTerm  # `glTerm()` = `GlRenderer::term()`: call after the last canvas was destroyed

proc target*(c: Canvas, dc, rc: int, fbo: GlId, w, h: int): Result =
  ## `GlCanvas::target(display, surface, context, id, w, h, cs)` of an existing GL canvas:
  ## binds it to another context / framebuffer / size (paints are updated again).
  let r = asGlRenderer(c.renderer)
  if r == nil: return Result.InsufficientCondition
  if w <= 0 or h <= 0: return Result.InvalidArguments
  result = r.target(0, dc, rc, fbo, uint32(w), uint32(h), ColorSpace.ABGR8888S)
  if result == Result.Success:
    result = c.retarget(uint32(w), uint32(h), ColorSpace.ABGR8888S)

proc retarget*(c: Canvas, dc, rc: int, fbo: GlId, w, h: int): Result =
  ## Same as `target` (retarget an existing GL canvas).
  c.target(dc, rc, fbo, w, h)

proc newGlCanvas*(dc, rc: int, fbo: GlId, w, h: int): Canvas =
  ## A canvas drawing with the GL engine into framebuffer `fbo` of context `rc` (device context
  ## `dc`). The context is made current and the GL entry points are loaded on first use.
  if w <= 0 or h <= 0: raise newException(ValueError, "invalid canvas size")
  if rc == 0: raise newException(ValueError, "no GL context")
  if not wglMakeCurrent(dc, rc): raise newException(ValueError, "cannot make the GL context current")
  if not glReady() and not glInit():
    raise newException(ValueError, "GL initialization failed: " & glInitError())
  let r = newGlRenderer()
  result = newCanvas(r)
  let res = result.target(dc, rc, fbo, w, h)
  if res != Result.Success:
    r.destroy()
    raise newException(ValueError, "GL target failed: " & $res)

proc destroy*(c: Canvas) =
  ## Releases the paints and every GL object of a GL canvas (the C++ destructor). The context
  ## must still exist; it is made current again when needed. No-op for other engines.
  let r = asGlRenderer(c.renderer)
  if r != nil:
    discard c.remove(nil)
    r.destroy()
