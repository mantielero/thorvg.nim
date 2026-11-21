## OpenGL demo: renders the shared demo scene with the GL backend.
##
##   demo_gl [--size WxH] [--out file.bmp|.png|.ppm] [--no-window]
##
## Linux: GLFW window+GL 3.3 context, renders to FBO and blits to screen.
## Windows: WGL offscreen context, readback, presented via display/window.
## Shows FPS in the window title.

import std/[os, times]
import thorvg/core/types
import thorvg/renderer/[canvas, render]
import thorvg/engine/gl/[glcanvas, gl_ffi, wgl_ffi]
import ./[common, demo_scene]

proc readbackFbo(w, h: int): RenderSurface =
  var pixels = newSeq[uint32](w * h)
  readPixels(0, 0, int32(w), int32(h), pixels)
  result = newSurface(uint32(w), uint32(h), ColorSpace.ABGR8888S)
  result.premultiplied = true
  for y in 0..<h:
    let srcY = h - 1 - y
    for x in 0..<w:
      result.data[y * w + x] = pixels[srcY * w + x]

when defined(windows):
  import thorvg/display/window

  proc main() =
    let opts = parseOptions(400, 300)
    let (ok, ctx0) = wglCreateOffscreen(opts.width, opts.height)
    if not ok:
      quit("demo_gl: could not create GL 3.3+ offscreen context.", 1)
    var ctx = ctx0
    try:
      let c = newGlCanvas(ctx.dc, ctx.rc, ctx.fbo, opts.width, opts.height)
      buildDemoScene(c)
      check c.update(); check c.draw(); check c.sync()
      discard wglMakeCurrent(ctx.dc, ctx.rc)
      let surf = readbackFbo(opts.width, opts.height)
      if opts.outFile.len > 0:
        saveImage(opts.outFile, surf)
        echo "saved: ", opts.outFile
      if opts.noWindow:
        c.destroy()
        return
      let win = openWindow("ThorVG OpenGL demo - FPS: ...", opts.width, opts.height)
      var frames = 0
      var last = epochTime()
      while win.pollEvents():
        if win.keyPressed(KeyEscape):
          win.close(); break
        check c.update(); check c.draw(); check c.sync()
        discard wglMakeCurrent(ctx.dc, ctx.rc)
        win.present(readbackFbo(opts.width, opts.height))
        inc frames
        let now = epochTime()
        if now - last >= 1.0:
          let fps = frames.float / (now - last)
          frames = 0; last = now
          win.setTitle("ThorVG OpenGL demo - FPS: " & $int(fps))
        sleep(1)
      c.destroy()
    finally:
      wglDestroy(ctx)
      glTerm()
  main()

else:
  # Linux: use GLFW for both window and GL context to avoid GLFW+SDL2 conflicts.
  {.passL: "-lglfw".}

  type
    GLFWwindow = pointer
    GLFWmonitor = pointer

  const
    GLFW_FALSE = 0'i32
    GLFW_TRUE = 1'i32
    GLFW_VISIBLE = 0x00020004'i32
    GLFW_RESIZABLE = 0x00020003'i32
    GLFW_CONTEXT_VERSION_MAJOR = 0x00022002'i32
    GLFW_CONTEXT_VERSION_MINOR = 0x00022003'i32
    GLFW_OPENGL_PROFILE = 0x00022008'i32
    GLFW_OPENGL_CORE_PROFILE = 0x00032001'i32
    GLFW_OPENGL_COMPAT_PROFILE = 0x00032002'i32
    GLFW_PRESS = 1'i32
    GLFW_KEY_ESCAPE = 256'i32

  {.push cdecl, importc, dynlib: "libglfw.so.3(|.4|.2|.1|.0)".}
  proc glfwInit(): int32
  proc glfwTerminate()
  proc glfwWindowHint(hint, value: int32)
  proc glfwDefaultWindowHints()
  proc glfwCreateWindow(width, height: int32; title: cstring; monitor: GLFWmonitor; share: GLFWwindow): GLFWwindow
  proc glfwDestroyWindow(window: GLFWwindow)
  proc glfwMakeContextCurrent(window: GLFWwindow)
  proc glfwWindowShouldClose(window: GLFWwindow): int32
  proc glfwSetWindowShouldClose(window: GLFWwindow; value: int32)
  proc glfwSwapBuffers(window: GLFWwindow)
  proc glfwPollEvents()
  proc glfwSetWindowTitle(window: GLFWwindow; title: cstring)
  proc glfwGetKey(window: GLFWwindow; key: int32): int32
  {.pop.}

  proc createFbo(w, h: int): (GlId, GlId, GlId) =
    let (ww, hh) = (int32(w), int32(h))
    let fbo = genFramebuffer()
    bindFramebuffer(GlFramebuffer, fbo)
    let colorRb = genRenderbuffer()
    bindRenderbuffer(GlRenderbuffer, colorRb)
    renderbufferStorage(GlRenderbuffer, GlRgba8, ww, hh)
    framebufferRenderbuffer(GlFramebuffer, GlColorAttachment0, GlRenderbuffer, colorRb)
    let depthRb = genRenderbuffer()
    bindRenderbuffer(GlRenderbuffer, depthRb)
    renderbufferStorage(GlRenderbuffer, GlDepth24Stencil8, ww, hh)
    framebufferRenderbuffer(GlFramebuffer, GlDepthStencilAttachment, GlRenderbuffer, depthRb)
    if checkFramebufferStatus(GlFramebuffer) != GlFramebufferComplete:
      quit("demo_gl: FBO incomplete", 1)
    viewport(0, 0, ww, hh)
    (fbo, colorRb, depthRb)

  proc destroyFbo(fbo, colorRb, depthRb: GlId) =
    bindFramebuffer(GlFramebuffer, 0)
    deleteFramebuffer(fbo)
    deleteRenderbuffer(colorRb)
    deleteRenderbuffer(depthRb)

  proc main() =
    let opts = parseOptions(400, 300)
    if glfwInit() != GLFW_TRUE:
      quit("demo_gl: glfwInit failed (need display/OpenGL).", 1)
    var win: GLFWwindow = nil
    for (profile, label) in [(GLFW_OPENGL_CORE_PROFILE, "3.3 core"), (GLFW_OPENGL_COMPAT_PROFILE, "3.3 compat")]:
      glfwDefaultWindowHints()
      glfwWindowHint(GLFW_VISIBLE, if opts.noWindow: GLFW_FALSE else: GLFW_TRUE)
      glfwWindowHint(GLFW_RESIZABLE, GLFW_FALSE)
      glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3)
      glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3)
      glfwWindowHint(GLFW_OPENGL_PROFILE, profile)
      win = glfwCreateWindow(int32(opts.width), int32(opts.height), "ThorVG OpenGL demo - FPS: ...", nil, nil)
      if win != nil: break
    if win == nil:
      glfwTerminate()
      quit("demo_gl: could not create GLFW GL 3.3+ window/context.", 1)

    glfwMakeContextCurrent(win)
    if not glReady() and not glInit():
      glfwDestroyWindow(win); glfwTerminate()
      quit("demo_gl: GL init failed: " & glInitError(), 1)

    let (fbo, colorRb, depthRb) = createFbo(opts.width, opts.height)
    let c = newGlCanvas(0, cast[int](win), fbo, opts.width, opts.height)
    buildDemoScene(c)
    check c.update(); check c.draw(); check c.sync()

    if opts.outFile.len > 0:
      discard wglMakeCurrent(0, cast[int](win))
      bindFramebuffer(GlReadFramebuffer, fbo)
      saveImage(opts.outFile, readbackFbo(opts.width, opts.height))
      echo "saved: ", opts.outFile

    if opts.noWindow:
      c.destroy()
      destroyFbo(fbo, colorRb, depthRb)
      glfwDestroyWindow(win)
      glfwTerminate()
      glTerm()
      return

    var frames = 0
    var last = epochTime()
    while glfwWindowShouldClose(win) == 0:
      glfwPollEvents()
      if glfwGetKey(win, GLFW_KEY_ESCAPE) == GLFW_PRESS:
        glfwSetWindowShouldClose(win, 1)
      check c.update(); check c.draw(); check c.sync()
      # Blit ThorVG FBO to default framebuffer.
      bindFramebuffer(GlReadFramebuffer, fbo)
      bindFramebuffer(GlDrawFramebuffer, 0)
      blitFramebuffer(0, 0, int32(opts.width), int32(opts.height),
                      0, 0, int32(opts.width), int32(opts.height),
                      uint32(GlColorBufferBit), GlNearest)
      bindFramebuffer(GlFramebuffer, fbo)
      glfwSwapBuffers(win)
      inc frames
      let now = epochTime()
      if now - last >= 1.0:
        let fps = frames.float / (now - last)
        frames = 0; last = now
        glfwSetWindowTitle(win, ("ThorVG OpenGL demo - FPS: " & $int(fps)).cstring)
      sleep(1)

    c.destroy()
    destroyFbo(fbo, colorRb, depthRb)
    glfwDestroyWindow(win)
    glfwTerminate()
    glTerm()

  main()
