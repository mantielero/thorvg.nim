## UNSAFE (exempt, DECISIONS.md E2): table of OpenGL entry points and its loader.
##
## Mirrors `glInit()` of tvgGl.cpp for the desktop GL target. A context must be
## current when `glInit` runs (the version check needs it), exactly like the C++ engine.
##
## Windows: loads `opengl32.dll`, looks up with `wglGetProcAddress` first (GL >= 1.2
## and extensions), then falls back to opengl32 exports (GL 1.0/1.1).
## Linux: loads `libGL.so.1` (fallback `libGL.so`), looks up with `glXGetProcAddressARB`
## first, then falls back to libGL exports.
##
## Only the safe wrappers in `gl_core_ffi` / `gl_buffers_ffi` use these raw
## procedure variables; import `gl_ffi` instead of this module.

import std/dynlib
import ./gl_types

const
  RequiredMajor* = 3
  RequiredMinor* = 3

when defined(windows):
  {.pragma: glcc, stdcall.}
else:
  {.pragma: glcc, cdecl.}

type
  GlObjKind* = enum
    okBuffer, okTexture, okVertexArray, okFramebuffer, okRenderbuffer, okShader, okProgram

type
  GetProcFn = proc(name: cstring): pointer {.glcc.}

var
  # GL 1.0
  fnCullFace*: proc(mode: GlEnum) {.glcc.}
  fnFrontFace*: proc(mode: GlEnum) {.glcc.}
  fnScissor*: proc(x, y, w, h: int32) {.glcc.}
  fnTexParameteri*: proc(target, pname: GlEnum, param: int32) {.glcc.}
  fnTexImage2D*: proc(target: GlEnum, level, ifmt, w, h, border: int32, fmt, ty: GlEnum,
    data: pointer) {.glcc.}
  fnDrawBuffer*: proc(mode: GlEnum) {.glcc.}
  fnClear*: proc(mask: uint32) {.glcc.}
  fnClearColor*: proc(r, g, b, a: float32) {.glcc.}
  fnClearStencil*: proc(s: int32) {.glcc.}
  fnClearDepth*: proc(d: float64) {.glcc.}
  fnColorMask*: proc(r, g, b, a: uint8) {.glcc.}
  fnDepthMask*: proc(flag: uint8) {.glcc.}
  fnDisable*: proc(cap: GlEnum) {.glcc.}
  fnEnable*: proc(cap: GlEnum) {.glcc.}
  fnStencilFunc*: proc(fn: GlEnum, value: int32, mask: uint32) {.glcc.}
  fnStencilOp*: proc(sfail, dpfail, dppass: GlEnum) {.glcc.}
  fnDepthFunc*: proc(fn: GlEnum) {.glcc.}
  fnGetError*: proc(): GlEnum {.glcc.}
  fnGetIntegerv*: proc(name: GlEnum, p: ptr int32) {.glcc.}
  fnGetString*: proc(name: GlEnum): cstring {.glcc.}
  fnViewport*: proc(x, y, w, h: int32) {.glcc.}
  fnFinish*: proc() {.glcc.}
  fnFlush*: proc() {.glcc.}
  fnPixelStorei*: proc(pname: GlEnum, param: int32) {.glcc.}
  fnReadPixels*: proc(x, y, w, h: int32, fmt, ty: GlEnum, data: pointer) {.glcc.}
  # GL 1.1 - 1.5
  fnDrawArrays*: proc(mode: GlEnum, first, count: int32) {.glcc.}
  fnDrawElements*: proc(mode: GlEnum, count: int32, ty: GlEnum, offset: pointer) {.glcc.}
  fnBindTexture*: proc(target: GlEnum, id: GlId) {.glcc.}
  fnDeleteTextures*: proc(n: int32, ids: ptr GlId) {.glcc.}
  fnGenTextures*: proc(n: int32, ids: ptr GlId) {.glcc.}
  fnTexSubImage2D*: proc(target: GlEnum, level, x, y, w, h: int32, fmt, ty: GlEnum,
    data: pointer) {.glcc.}
  fnActiveTexture*: proc(unit: GlEnum) {.glcc.}
  fnBlendFuncSeparate*: proc(srcRgb, dstRgb, srcA, dstA: GlEnum) {.glcc.}
  fnBlendEquation*: proc(mode: GlEnum) {.glcc.}
  fnBindBuffer*: proc(target: GlEnum, id: GlId) {.glcc.}
  fnDeleteBuffers*: proc(n: int32, ids: ptr GlId) {.glcc.}
  fnGenBuffers*: proc(n: int32, ids: ptr GlId) {.glcc.}
  fnBufferData*: proc(target: GlEnum, size: int, data: pointer, usage: GlEnum) {.glcc.}
  fnBufferSubData*: proc(target: GlEnum, offset, size: int, data: pointer) {.glcc.}
  fnGetBufferSubData*: proc(target: GlEnum, offset, size: int, data: pointer) {.glcc.}
  # GL 2.0
  fnDrawBuffers*: proc(n: int32, bufs: ptr GlEnum) {.glcc.}
  fnStencilOpSeparate*: proc(face, sfail, dpfail, dppass: GlEnum) {.glcc.}
  fnStencilFuncSeparate*: proc(face, fn: GlEnum, value: int32, mask: uint32) {.glcc.}
  fnAttachShader*: proc(prog, shader: GlId) {.glcc.}
  fnCompileShader*: proc(shader: GlId) {.glcc.}
  fnCreateProgram*: proc(): GlId {.glcc.}
  fnCreateShader*: proc(ty: GlEnum): GlId {.glcc.}
  fnDeleteProgram*: proc(prog: GlId) {.glcc.}
  fnDeleteShader*: proc(shader: GlId) {.glcc.}
  fnDisableVertexAttribArray*: proc(index: uint32) {.glcc.}
  fnEnableVertexAttribArray*: proc(index: uint32) {.glcc.}
  fnGetAttribLocation*: proc(prog: GlId, name: cstring): int32 {.glcc.}
  fnGetProgramiv*: proc(prog: GlId, pname: GlEnum, p: ptr int32) {.glcc.}
  fnGetProgramInfoLog*: proc(prog: GlId, maxLen: int32, len: ptr int32, log: cstring) {.glcc.}
  fnGetShaderiv*: proc(shader: GlId, pname: GlEnum, p: ptr int32) {.glcc.}
  fnGetShaderInfoLog*: proc(shader: GlId, maxLen: int32, len: ptr int32, log: cstring) {.glcc.}
  fnGetUniformLocation*: proc(prog: GlId, name: cstring): int32 {.glcc.}
  fnGetUniformfv*: proc(prog: GlId, loc: int32, p: ptr float32) {.glcc.}
  fnLinkProgram*: proc(prog: GlId) {.glcc.}
  fnShaderSource*: proc(shader: GlId, count: int32, src: ptr cstring, len: ptr int32) {.glcc.}
  fnUseProgram*: proc(prog: GlId) {.glcc.}
  fnUniform1f*: proc(loc: int32, v: float32) {.glcc.}
  fnUniform1fv*: proc(loc, count: int32, v: ptr float32) {.glcc.}
  fnUniform2fv*: proc(loc, count: int32, v: ptr float32) {.glcc.}
  fnUniform3fv*: proc(loc, count: int32, v: ptr float32) {.glcc.}
  fnUniform4fv*: proc(loc, count: int32, v: ptr float32) {.glcc.}
  fnUniform1iv*: proc(loc, count: int32, v: ptr int32) {.glcc.}
  fnUniform2iv*: proc(loc, count: int32, v: ptr int32) {.glcc.}
  fnUniform3iv*: proc(loc, count: int32, v: ptr int32) {.glcc.}
  fnUniform4iv*: proc(loc, count: int32, v: ptr int32) {.glcc.}
  fnUniformMatrix3fv*: proc(loc, count: int32, transpose: uint8, v: ptr float32) {.glcc.}
  fnVertexAttrib4f*: proc(index: uint32, x, y, z, w: float32) {.glcc.}
  fnVertexAttribPointer*: proc(index: uint32, size: int32, ty: GlEnum, norm: uint8,
    stride: int32, offset: pointer) {.glcc.}
  # GL 3.0 / 3.1
  fnBindBufferRange*: proc(target: GlEnum, index: uint32, id: GlId, offset, size: int) {.glcc.}
  fnBindRenderbuffer*: proc(target: GlEnum, id: GlId) {.glcc.}
  fnDeleteRenderbuffers*: proc(n: int32, ids: ptr GlId) {.glcc.}
  fnGenRenderbuffers*: proc(n: int32, ids: ptr GlId) {.glcc.}
  fnRenderbufferStorage*: proc(target, fmt: GlEnum, w, h: int32) {.glcc.}
  fnRenderbufferStorageMultisample*: proc(target: GlEnum, samples: int32, fmt: GlEnum,
    w, h: int32) {.glcc.}
  fnInvalidateFramebuffer*: proc(target: GlEnum, n: int32, att: ptr GlEnum) {.glcc.}
  fnBindFramebuffer*: proc(target: GlEnum, id: GlId) {.glcc.}
  fnDeleteFramebuffers*: proc(n: int32, ids: ptr GlId) {.glcc.}
  fnGenFramebuffers*: proc(n: int32, ids: ptr GlId) {.glcc.}
  fnFramebufferTexture2D*: proc(target, att, textarget: GlEnum, tex: GlId, level: int32) {.glcc.}
  fnFramebufferRenderbuffer*: proc(target, att, rbTarget: GlEnum, rb: GlId) {.glcc.}
  fnCheckFramebufferStatus*: proc(target: GlEnum): GlEnum {.glcc.}
  fnBlitFramebuffer*: proc(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1: int32, mask: uint32,
    filter: GlEnum) {.glcc.}
  fnGenerateMipmap*: proc(target: GlEnum) {.glcc.}
  fnBindVertexArray*: proc(id: GlId) {.glcc.}
  fnDeleteVertexArrays*: proc(n: int32, ids: ptr GlId) {.glcc.}
  fnGenVertexArrays*: proc(n: int32, ids: ptr GlId) {.glcc.}
  fnGetUniformBlockIndex*: proc(prog: GlId, name: cstring): uint32 {.glcc.}
  fnUniformBlockBinding*: proc(prog: GlId, index, binding: uint32) {.glcc.}

var
  libGl: LibHandle
  getProc: GetProcFn
  loadOk: bool
  loaded: bool
  missing: string
  live: array[GlObjKind, int]

proc isUsable(p: pointer): bool =
  ## Some drivers return 1, 2, 3 or -1 from `wglGetProcAddress` for unknown names.
  let v = cast[int](p)
  p != nil and v notin -1 .. 3

proc fetch(name: string): pointer =
  result = nil
  if getProc != nil: result = getProc(cstring(name))
  if not isUsable(result): result = libGl.symAddr(cstring(name))
  if not isUsable(result): result = nil

proc load[T](fn: var T, name: string): bool =
  let p = fetch(name)
  if p != nil: fn = cast[T](p)
  elif missing.len == 0: missing = name
  result = p != nil

template req(fn: untyped, name: string) =
  loadOk = loadOk and load(fn, name)

template opt(fn: untyped, name: string) =
  discard load(fn, name)
  missing = ""

proc loadCore() =
  req(fnCullFace, "glCullFace")
  req(fnFrontFace, "glFrontFace")
  req(fnScissor, "glScissor")
  req(fnTexParameteri, "glTexParameteri")
  req(fnTexImage2D, "glTexImage2D")
  req(fnDrawBuffer, "glDrawBuffer")
  req(fnClear, "glClear")
  req(fnClearColor, "glClearColor")
  req(fnClearStencil, "glClearStencil")
  req(fnClearDepth, "glClearDepth")
  req(fnColorMask, "glColorMask")
  req(fnDepthMask, "glDepthMask")
  req(fnDisable, "glDisable")
  req(fnEnable, "glEnable")
  req(fnStencilFunc, "glStencilFunc")
  req(fnStencilOp, "glStencilOp")
  req(fnDepthFunc, "glDepthFunc")
  req(fnGetError, "glGetError")
  req(fnGetIntegerv, "glGetIntegerv")
  req(fnGetString, "glGetString")
  req(fnViewport, "glViewport")
  req(fnFinish, "glFinish")
  req(fnFlush, "glFlush")
  req(fnPixelStorei, "glPixelStorei")
  req(fnReadPixels, "glReadPixels")
  req(fnDrawArrays, "glDrawArrays")
  req(fnDrawElements, "glDrawElements")
  req(fnBindTexture, "glBindTexture")
  req(fnDeleteTextures, "glDeleteTextures")
  req(fnGenTextures, "glGenTextures")
  req(fnTexSubImage2D, "glTexSubImage2D")
  req(fnActiveTexture, "glActiveTexture")
  req(fnBlendFuncSeparate, "glBlendFuncSeparate")
  req(fnBlendEquation, "glBlendEquation")
  req(fnBindBuffer, "glBindBuffer")
  req(fnDeleteBuffers, "glDeleteBuffers")
  req(fnGenBuffers, "glGenBuffers")
  req(fnBufferData, "glBufferData")
  req(fnBufferSubData, "glBufferSubData")
  req(fnGetBufferSubData, "glGetBufferSubData")

proc loadShaders() =
  req(fnDrawBuffers, "glDrawBuffers")
  req(fnStencilOpSeparate, "glStencilOpSeparate")
  req(fnStencilFuncSeparate, "glStencilFuncSeparate")
  req(fnAttachShader, "glAttachShader")
  req(fnCompileShader, "glCompileShader")
  req(fnCreateProgram, "glCreateProgram")
  req(fnCreateShader, "glCreateShader")
  req(fnDeleteProgram, "glDeleteProgram")
  req(fnDeleteShader, "glDeleteShader")
  req(fnDisableVertexAttribArray, "glDisableVertexAttribArray")
  req(fnEnableVertexAttribArray, "glEnableVertexAttribArray")
  req(fnGetAttribLocation, "glGetAttribLocation")
  req(fnGetProgramiv, "glGetProgramiv")
  req(fnGetProgramInfoLog, "glGetProgramInfoLog")
  req(fnGetShaderiv, "glGetShaderiv")
  req(fnGetShaderInfoLog, "glGetShaderInfoLog")
  req(fnGetUniformLocation, "glGetUniformLocation")
  req(fnGetUniformfv, "glGetUniformfv")
  req(fnLinkProgram, "glLinkProgram")
  req(fnShaderSource, "glShaderSource")
  req(fnUseProgram, "glUseProgram")
  req(fnUniform1f, "glUniform1f")
  req(fnUniform1fv, "glUniform1fv")
  req(fnUniform2fv, "glUniform2fv")
  req(fnUniform3fv, "glUniform3fv")
  req(fnUniform4fv, "glUniform4fv")
  req(fnUniform1iv, "glUniform1iv")
  req(fnUniform2iv, "glUniform2iv")
  req(fnUniform3iv, "glUniform3iv")
  req(fnUniform4iv, "glUniform4iv")
  req(fnUniformMatrix3fv, "glUniformMatrix3fv")
  req(fnVertexAttrib4f, "glVertexAttrib4f")
  req(fnVertexAttribPointer, "glVertexAttribPointer")

proc loadFramebuffers() =
  req(fnBindBufferRange, "glBindBufferRange")
  req(fnBindRenderbuffer, "glBindRenderbuffer")
  req(fnDeleteRenderbuffers, "glDeleteRenderbuffers")
  req(fnGenRenderbuffers, "glGenRenderbuffers")
  req(fnRenderbufferStorage, "glRenderbufferStorage")
  req(fnRenderbufferStorageMultisample, "glRenderbufferStorageMultisample")
  req(fnBindFramebuffer, "glBindFramebuffer")
  req(fnDeleteFramebuffers, "glDeleteFramebuffers")
  req(fnGenFramebuffers, "glGenFramebuffers")
  req(fnFramebufferTexture2D, "glFramebufferTexture2D")
  req(fnFramebufferRenderbuffer, "glFramebufferRenderbuffer")
  req(fnCheckFramebufferStatus, "glCheckFramebufferStatus")
  req(fnBlitFramebuffer, "glBlitFramebuffer")
  req(fnGenerateMipmap, "glGenerateMipmap")
  req(fnBindVertexArray, "glBindVertexArray")
  req(fnDeleteVertexArrays, "glDeleteVertexArrays")
  req(fnGenVertexArrays, "glGenVertexArrays")
  req(fnGetUniformBlockIndex, "glGetUniformBlockIndex")
  req(fnUniformBlockBinding, "glUniformBlockBinding")

proc glInit*(): bool =
  ## Loads every entry point and checks that the current context is GL >= 3.3
  ## (`TVG_REQUIRE_GL_*`). Needs a current context. Safe to call repeatedly.
  loadOk = true
  missing = ""
  if libGl == nil:
    when defined(windows):
      libGl = loadLib("opengl32.dll")
    else:
      libGl = loadLib("libGL.so.1")
      if libGl == nil: libGl = loadLib("libGL.so")
  if libGl == nil:
    when defined(windows):
      missing = "opengl32.dll"
    else:
      missing = "libGL.so.1"
    loadOk = false
  else:
    if getProc == nil:
      when defined(windows):
        getProc = cast[GetProcFn](libGl.symAddr("wglGetProcAddress"))
        if getProc == nil: getProc = cast[GetProcFn](libGl.symAddr("wglGetProcAddressARB"))
      else:
        getProc = cast[GetProcFn](libGl.symAddr("glXGetProcAddressARB"))
        if getProc == nil: getProc = cast[GetProcFn](libGl.symAddr("glXGetProcAddress"))
    if getProc == nil:
      when defined(windows):
        missing = "wglGetProcAddress"
      else:
        missing = "glXGetProcAddressARB"
      loadOk = false
  if loadOk:
    loadCore()
    loadShaders()
    loadFramebuffers()
    opt(fnInvalidateFramebuffer, "glInvalidateFramebuffer") # GL 4.3: optional
  if loadOk:
    var major, minor: int32
    fnGetIntegerv(GlMajorVersion, addr major)
    fnGetIntegerv(GlMinorVersion, addr minor)
    if major < RequiredMajor or (major == RequiredMajor and minor < RequiredMinor):
      missing = "OpenGL " & $major & "." & $minor & " < " & $RequiredMajor & "." &
        $RequiredMinor
      loadOk = false
  loaded = loadOk
  result = loaded

proc glInitError*(): string =
  ## Name of the first missing entry point (or the version problem) of the last `glInit`.
  missing

proc glReady*(): bool = loaded

proc glTerm*() =
  ## Forgets the loaded state; the DLL stays mapped (other WGL users share it).
  loaded = false
  getProc = nil

proc trackGen*(k: GlObjKind, n: int) = live[k] += n

proc trackDel*(k: GlObjKind, n: int) = live[k] -= n

proc glLiveObjects*(k: GlObjKind): int =
  ## Objects created minus objects deleted through the safe wrappers.
  live[k]

proc glLiveObjects*(): int =
  for k in GlObjKind: result += live[k]
