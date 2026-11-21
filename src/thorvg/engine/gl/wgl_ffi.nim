## UNSAFE (exempt, DECISIONS.md E2): Desktop GL offscreen context creation.
## Windows: WGL hidden window + GL 3.3 context + FBO.
## Linux: GLFW hidden window + GL 3.3 context + FBO.
## API name `WglContext`/`wgl*` kept for compatibility with existing tests/tools.
##
## The context provides an app FBO (RGBA8 + DEPTH24_STENCIL8) bound on creation,
## as expected by `GlRenderer::target(..., fbo, ...)`.

import ./[gl_types, gl_ffi]

when defined(windows):
  ## UNSAFE (exempt, DECISIONS.md E2): WGL context creation for tests, tools and the
  ## GL parity driver. A hidden window gets a pixel format and a GL context
  ## (`wglCreateContextAttribsARB` 3.3 core, then 3.3 compatibility, then the plain
  ## legacy context), and an offscreen FBO (RGBA8 + DEPTH24_STENCIL8 renderbuffers)
  ## is created and bound, which is what `GlRenderer::target(..., fbo, ...)` expects.
  ##
  ## Handles are plain `int` (HWND / HDC / HGLRC): the engine only needs
  ## `wglCurrentContext` / `wglMakeCurrent`; no pointer leaves this module.
  ## No message loop is needed: the window is never shown.


  type
    Handle = pointer
    WndProc = proc(h: Handle, msg: uint32, wp: uint, lp: int): int {.stdcall.}
    WndClassA {.bycopy.} = object
      style: uint32
      lpfnWndProc: WndProc
      cbClsExtra, cbWndExtra: int32
      hInstance, hIcon, hCursor, hbrBackground: pointer
      lpszMenuName, lpszClassName: cstring
    PixelFormatDescriptor {.bycopy.} = object
      nSize, nVersion: uint16
      dwFlags: uint32
      iPixelType, cColorBits, cRedBits, cRedShift, cGreenBits, cGreenShift,
        cBlueBits, cBlueShift, cAlphaBits, cAlphaShift, cAccumBits,
        cAccumRedBits, cAccumGreenBits, cAccumBlueBits, cAccumAlphaBits,
        cDepthBits, cStencilBits, cAuxBuffers, iLayerType, bReserved: uint8
      dwLayerMask, dwVisibleMask, dwDamageMask: uint32
    CreateAttribsFn = proc(dc, share: Handle, attribs: ptr int32): Handle {.stdcall.}

    WglContext* = object
      ## An offscreen GL context. All handles are 0 when unset.
      hwnd*, dc*, rc*: int
      fbo*: GlId                  ## app FBO (RGBA8 + DEPTH24_STENCIL8), bound on creation
      colorRb*, depthRb*: GlId
      width*, height*: int
      mode*: string               ## "3.3 core", "3.3 compat" or "legacy"

  {.push stdcall, dynlib: "user32.dll".}
  proc registerClassA(c: ptr WndClassA): uint16 {.importc: "RegisterClassA".}
  proc createWindowExA(exStyle: uint32, cls, title: cstring, style: uint32,
      x, y, w, h: int32, parent, menu, inst, param: pointer): Handle
      {.importc: "CreateWindowExA".}
  proc defWindowProcA(h: Handle, msg: uint32, wp: uint, lp: int): int
      {.importc: "DefWindowProcA".}
  proc getDC(h: Handle): Handle {.importc: "GetDC".}
  proc releaseDC(h, dc: Handle): int32 {.importc: "ReleaseDC".}
  proc destroyWindow(h: Handle): int32 {.importc: "DestroyWindow".}
  {.pop.}
  {.push stdcall, dynlib: "gdi32.dll".}
  proc choosePixelFormat(dc: Handle, p: ptr PixelFormatDescriptor): int32
      {.importc: "ChoosePixelFormat".}
  proc setPixelFormat(dc: Handle, f: int32, p: ptr PixelFormatDescriptor): int32
      {.importc: "SetPixelFormat".}
  {.pop.}
  {.push stdcall, dynlib: "kernel32.dll".}
  proc getModuleHandleA(name: cstring): Handle {.importc: "GetModuleHandleA".}
  {.pop.}
  {.push stdcall, dynlib: "opengl32.dll".}
  proc rawCreateContext(dc: Handle): Handle {.importc: "wglCreateContext".}
  proc rawDeleteContext(rc: Handle): int32 {.importc: "wglDeleteContext".}
  proc rawMakeCurrent(dc, rc: Handle): int32 {.importc: "wglMakeCurrent".}
  proc rawGetProcAddress(name: cstring): pointer {.importc: "wglGetProcAddress".}
  proc rawGetCurrentContext(): Handle {.importc: "wglGetCurrentContext".}
  proc rawGetCurrentDC(): Handle {.importc: "wglGetCurrentDC".}
  {.pop.}

  const
    ClassName = "ThorvgNimGlWindow"
    WsOverlappedWindow = 0x00CF0000'u32  # never shown: no WS_VISIBLE
    PfdFlags = 0x04'u32 or 0x20'u32 or 0x01'u32  # DRAW_TO_WINDOW | SUPPORT_OPENGL | DOUBLEBUFFER
    CtxMajor = 0x2091'i32
    CtxMinor = 0x2092'i32
    CtxProfile = 0x9126'i32

  proc toH(v: int): Handle = cast[Handle](v)
  proc toInt(h: Handle): int = cast[int](h)

  proc wglCurrentContext*(): int =
    ## HGLRC current on this thread (0 when none).
    toInt(rawGetCurrentContext())

  proc wglCurrentDc*(): int =
    ## HDC bound to the current context (0 when none).
    toInt(rawGetCurrentDC())

  proc wglMakeCurrent*(c: WglContext): bool =
    rawMakeCurrent(toH(c.dc), toH(c.rc)) != 0

  proc wglMakeCurrent*(dc, rc: int): bool =
    rawMakeCurrent(toH(dc), toH(rc)) != 0

  proc wglReleaseCurrent*() =
    discard rawMakeCurrent(nil, nil)

  proc createHiddenWindow(c: var WglContext): bool =
    let inst = getModuleHandleA(nil)
    var wc = WndClassA(lpfnWndProc: defWindowProcA, hInstance: inst,
      lpszClassName: ClassName)
    discard registerClassA(addr wc)  # fails harmlessly when the class already exists
    let hw = createWindowExA(0, ClassName, "thorvg gl", WsOverlappedWindow, 0, 0, 64, 64,
      nil, nil, inst, nil)
    let dc = if hw != nil: getDC(hw) else: nil
    var pfd = PixelFormatDescriptor(nSize: uint16(sizeof(PixelFormatDescriptor)),
      nVersion: 1, dwFlags: PfdFlags, cColorBits: 32, cDepthBits: 24, cStencilBits: 8)
    let pf = if dc != nil: choosePixelFormat(dc, addr pfd) else: 0'i32
    result = pf > 0 and setPixelFormat(dc, pf, addr pfd) != 0
    c.hwnd = toInt(hw)
    c.dc = toInt(dc)

  proc createContext(c: var WglContext): bool =
    ## Core 3.3, else compatibility 3.3, else the legacy context.
    let dc = toH(c.dc)
    let legacy = rawCreateContext(dc)
    if legacy == nil: return false
    discard rawMakeCurrent(dc, legacy)
    var ctx: Handle = nil
    c.mode = "legacy"
    let createAttribs = cast[CreateAttribsFn](rawGetProcAddress("wglCreateContextAttribsARB"))
    if createAttribs != nil:
      for profile in [1'i32, 2'i32]:
        if ctx == nil:
          var attribs = [CtxMajor, 3, CtxMinor, 3, CtxProfile, profile, 0]
          ctx = createAttribs(dc, nil, addr attribs[0])
          if ctx != nil: c.mode = if profile == 1: "3.3 core" else: "3.3 compat"
    if ctx != nil:
      discard rawMakeCurrent(nil, nil)
      discard rawDeleteContext(legacy)
    else:
      ctx = legacy
    discard rawMakeCurrent(dc, ctx)
    c.rc = toInt(ctx)
    result = true

  proc createFbo(c: var WglContext, w, h: int): bool =
    let (ww, hh) = (int32(w), int32(h))
    c.fbo = genFramebuffer()
    bindFramebuffer(GlFramebuffer, c.fbo)
    c.colorRb = genRenderbuffer()
    bindRenderbuffer(GlRenderbuffer, c.colorRb)
    renderbufferStorage(GlRenderbuffer, GlRgba8, ww, hh)
    framebufferRenderbuffer(GlFramebuffer, GlColorAttachment0, GlRenderbuffer, c.colorRb)
    c.depthRb = genRenderbuffer()
    bindRenderbuffer(GlRenderbuffer, c.depthRb)
    renderbufferStorage(GlRenderbuffer, GlDepth24Stencil8, ww, hh)
    framebufferRenderbuffer(GlFramebuffer, GlDepthStencilAttachment, GlRenderbuffer, c.depthRb)
    c.width = w
    c.height = h
    result = checkFramebufferStatus(GlFramebuffer) == GlFramebufferComplete
    viewport(0, 0, ww, hh)

  proc wglDestroy*(c: var WglContext) =
    ## Releases the FBO, the context, the DC and the window. Safe on a zeroed value.
    if c.rc != 0:
      if rawMakeCurrent(toH(c.dc), toH(c.rc)) != 0 and glReady():
        bindFramebuffer(GlFramebuffer, 0)
        deleteFramebuffer(c.fbo)
        deleteRenderbuffer(c.colorRb)
        deleteRenderbuffer(c.depthRb)
      discard rawMakeCurrent(nil, nil)
      discard rawDeleteContext(toH(c.rc))
    if c.dc != 0 and c.hwnd != 0: discard releaseDC(toH(c.hwnd), toH(c.dc))
    if c.hwnd != 0: discard destroyWindow(toH(c.hwnd))
    c = WglContext()

  proc wglCreateOffscreen*(w, h: int): (bool, WglContext) =
    ## Creates a hidden window + GL context (made current) + `w x h` FBO (bound).
    ## Loads the GL entry points with `glInit()`. Returns `(false, _)` (everything
    ## released) when no context, no GL 3.3, or no complete FBO is available.
    var c = WglContext()
    var ok = w > 0 and h > 0 and createHiddenWindow(c) and createContext(c)
    ok = ok and glInit() and createFbo(c, w, h)
    if not ok: wglDestroy(c)
    result = (ok, c)
else:
  ## UNSAFE (exempt, DECISIONS.md E2): Linux GL offscreen context creation using GLFW.
  ## Provides the same API shape as the Windows WGL implementation so existing
  ## tests/tools using `WglContext` / `wglCreateOffscreen` work on Linux.
  ##
  ## The context is a hidden GLFW window with an OpenGL 3.3+ context and an FBO
  ## (RGBA8 + DEPTH24_STENCIL8), bound on creation. `rc` stores the GLFWwindow*
  ## as int; `dc` is unused (0). `wglMakeCurrent(dc,rc)` makes that window current.


  {.passL: "-lglfw".}

  type
    GLFWwindow = pointer
    GLFWmonitor = pointer

    WglContext* = object
      ## Cross-platform offscreen GL context (WGL name kept for API compat).
      ## On Linux: `rc` = GLFWwindow*, `dc` = 0.
      hwnd*, dc*, rc*: int
      fbo*: GlId
      colorRb*, depthRb*: GlId
      width*, height*: int
      mode*: string

  const
    GLFW_FALSE = 0'i32
    GLFW_TRUE = 1'i32
    GLFW_VISIBLE = 0x00020004'i32
    GLFW_CONTEXT_VERSION_MAJOR = 0x00022002'i32
    GLFW_CONTEXT_VERSION_MINOR = 0x00022003'i32
    GLFW_OPENGL_PROFILE = 0x00022008'i32
    GLFW_OPENGL_CORE_PROFILE = 0x00032001'i32
    GLFW_OPENGL_COMPAT_PROFILE = 0x00032002'i32

  {.push cdecl, importc, dynlib: "libglfw.so.3(|.4|.2|.1|.0)".}
  proc glfwInit(): int32
  proc glfwTerminate()
  proc glfwWindowHint(hint, value: int32)
  proc glfwCreateWindow(width, height: int32; title: cstring; monitor: GLFWmonitor; share: GLFWwindow): GLFWwindow
  proc glfwDestroyWindow(window: GLFWwindow)
  proc glfwMakeContextCurrent(window: GLFWwindow)
  proc glfwGetCurrentContext(): GLFWwindow
  proc glfwDefaultWindowHints()
  {.pop.}

  var glfwInitialized = false

  proc ensureGlfw(): bool =
    if not glfwInitialized:
      glfwInitialized = glfwInit() == GLFW_TRUE
    glfwInitialized

  proc wglCurrentContext*(): int = cast[int](glfwGetCurrentContext())

  proc wglCurrentDc*(): int = 0

  proc wglMakeCurrent*(dc, rc: int): bool =
    discard dc
    if rc == 0:
      glfwMakeContextCurrent(nil)
      return true
    glfwMakeContextCurrent(cast[GLFWwindow](rc))
    true

  proc wglMakeCurrent*(c: WglContext): bool = wglMakeCurrent(c.dc, c.rc)

  proc wglReleaseCurrent*() = glfwMakeContextCurrent(nil)

  proc createFbo(c: var WglContext, w, h: int): bool =
    let (ww, hh) = (int32(w), int32(h))
    c.fbo = genFramebuffer()
    bindFramebuffer(GlFramebuffer, c.fbo)
    c.colorRb = genRenderbuffer()
    bindRenderbuffer(GlRenderbuffer, c.colorRb)
    renderbufferStorage(GlRenderbuffer, GlRgba8, ww, hh)
    framebufferRenderbuffer(GlFramebuffer, GlColorAttachment0, GlRenderbuffer, c.colorRb)
    c.depthRb = genRenderbuffer()
    bindRenderbuffer(GlRenderbuffer, c.depthRb)
    renderbufferStorage(GlRenderbuffer, GlDepth24Stencil8, ww, hh)
    framebufferRenderbuffer(GlFramebuffer, GlDepthStencilAttachment, GlRenderbuffer, c.depthRb)
    c.width = w
    c.height = h
    result = checkFramebufferStatus(GlFramebuffer) == GlFramebufferComplete
    viewport(0, 0, ww, hh)

  proc createContext(c: var WglContext, w, h: int): bool =
    if not ensureGlfw(): return false
    # Try core 3.3, then compat 3.3.
    for (profile, label) in [(GLFW_OPENGL_CORE_PROFILE, "3.3 core"), (GLFW_OPENGL_COMPAT_PROFILE, "3.3 compat")]:
      glfwDefaultWindowHints()
      glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE)
      glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3)
      glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3)
      glfwWindowHint(GLFW_OPENGL_PROFILE, profile)
      let win = glfwCreateWindow(int32(max(w, 1)), int32(max(h, 1)), "thorvg-gl", nil, nil)
      if win != nil:
        c.rc = cast[int](win)
        c.mode = label
        glfwMakeContextCurrent(win)
        return true
    # Fallback: default context.
    glfwDefaultWindowHints()
    glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE)
    let win = glfwCreateWindow(int32(max(w, 1)), int32(max(h, 1)), "thorvg-gl", nil, nil)
    if win != nil:
      c.rc = cast[int](win)
      c.mode = "legacy"
      glfwMakeContextCurrent(win)
      return true
    false

  proc wglDestroy*(c: var WglContext) =
    if c.rc != 0:
      glfwMakeContextCurrent(cast[GLFWwindow](c.rc))
      if glReady():
        bindFramebuffer(GlFramebuffer, 0)
        deleteFramebuffer(c.fbo)
        deleteRenderbuffer(c.colorRb)
        deleteRenderbuffer(c.depthRb)
      glfwMakeContextCurrent(nil)
      glfwDestroyWindow(cast[GLFWwindow](c.rc))
    c = WglContext()

  proc wglCreateOffscreen*(w, h: int): (bool, WglContext) =
    var c = WglContext()
    var ok = w > 0 and h > 0 and createContext(c, w, h)
    ok = ok and glInit() and createFbo(c, w, h)
    if not ok: wglDestroy(c)
    (ok, c)
