## UNSAFE (exempt, DECISIONS.md E2): safe wrappers for state, drawing, textures,
## framebuffers and pixel readback. No pointer type appears in an exported
## signature: data goes in as `openArray[T]` / `seq[T]`, byte offsets as `int`.
##
## Names are the GL names without the `gl` prefix (`glClear` -> `clear`).
## Import `gl_ffi`, which re-exports this module.

import ./[gl_types, gl_raw_ffi]

type
  GlError* = object of CatchableError

# ---------------------------------------------------------------- errors

proc errorName*(e: GlEnum): string =
  case e
  of GlNoError: "GL_NO_ERROR"
  of GlInvalidEnum: "GL_INVALID_ENUM"
  of GlInvalidValue: "GL_INVALID_VALUE"
  of GlInvalidOperation: "GL_INVALID_OPERATION"
  of GlInvalidFramebufferOperation: "GL_INVALID_FRAMEBUFFER_OPERATION"
  of GlOutOfMemory: "GL_OUT_OF_MEMORY"
  else: "GL error 0x" & $e

proc getError*(): GlEnum = fnGetError()

proc checkGlError*(what, file: string, line: int) =
  ## Raises `GlError` when `glGetError` reports something.
  let e = fnGetError()
  if e != GlNoError:
    raise newException(GlError, errorName(e) & " after " & what & " (" & file & ":" &
      $line & ")")

template glCheck*(call: untyped) =
  ## Replacement of `GL_CHECK(stmt)`: runs the statement and, with `-d:glDebug`,
  ## raises `GlError` when it left a GL error behind.
  call
  when defined(glDebug):
    checkGlError(astToStr(call), instantiationInfo().filename, instantiationInfo().line)

# ---------------------------------------------------------------- state

proc cullFace*(mode: GlEnum) = fnCullFace(mode)
proc frontFace*(mode: GlEnum) = fnFrontFace(mode)
proc scissor*(x, y, w, h: int32) = fnScissor(x, y, w, h)
proc viewport*(x, y, w, h: int32) = fnViewport(x, y, w, h)
proc clear*(mask: uint32) = fnClear(mask)
proc clearColor*(r, g, b, a: float32) = fnClearColor(r, g, b, a)
proc clearStencil*(s: int32) = fnClearStencil(s)
proc clearDepth*(d: float64) = fnClearDepth(d)
proc colorMask*(r, g, b, a: bool) = fnColorMask(uint8(r), uint8(g), uint8(b), uint8(a))
proc depthMask*(flag: bool) = fnDepthMask(uint8(flag))
proc enable*(cap: GlEnum) = fnEnable(cap)
proc disable*(cap: GlEnum) = fnDisable(cap)
proc stencilFunc*(fn: GlEnum, value: int32, mask: uint32) = fnStencilFunc(fn, value, mask)
proc stencilOp*(sfail, dpfail, dppass: GlEnum) = fnStencilOp(sfail, dpfail, dppass)
proc depthFunc*(fn: GlEnum) = fnDepthFunc(fn)
proc stencilOpSeparate*(face, sfail, dpfail, dppass: GlEnum) =
  fnStencilOpSeparate(face, sfail, dpfail, dppass)
proc stencilFuncSeparate*(face, fn: GlEnum, value: int32, mask: uint32) =
  fnStencilFuncSeparate(face, fn, value, mask)
proc blendFuncSeparate*(srcRgb, dstRgb, srcA, dstA: GlEnum) =
  fnBlendFuncSeparate(srcRgb, dstRgb, srcA, dstA)
proc blendEquation*(mode: GlEnum) = fnBlendEquation(mode)
proc drawBuffer*(mode: GlEnum) = fnDrawBuffer(mode)
proc finish*() = fnFinish()
proc flush*() = fnFlush()
proc pixelStorei*(pname: GlEnum, param: int32) = fnPixelStorei(pname, param)

proc drawBuffers*(bufs: openArray[GlEnum]) =
  if bufs.len > 0: fnDrawBuffers(int32(bufs.len), unsafeAddr bufs[0])

proc getInteger*(name: GlEnum): int32 =
  ## `glGetIntegerv` for a single value.
  result = 0
  fnGetIntegerv(name, addr result)

proc getIntegers*(name: GlEnum, n: int): seq[int32] =
  ## `glGetIntegerv` for `n` values (e.g. `GlViewport` -> 4).
  result = newSeq[int32](n)
  if n > 0: fnGetIntegerv(name, addr result[0])

proc getString*(name: GlEnum): string =
  let s = fnGetString(name)
  result = if s == nil: "" else: $s

# ---------------------------------------------------------------- drawing

proc drawArrays*(mode: GlEnum, first, count: int32) = fnDrawArrays(mode, first, count)

proc drawElements*(mode: GlEnum, count: int32, ty: GlEnum, offset: int) =
  ## `offset` is a byte offset into the bound element buffer.
  fnDrawElements(mode, count, ty, cast[pointer](offset))

# ---------------------------------------------------------------- textures

proc genTextures*(n: int): seq[GlId] =
  result = newSeq[GlId](n)
  if n > 0:
    fnGenTextures(int32(n), addr result[0])
    trackGen(okTexture, n)

proc genTexture*(): GlId = genTextures(1)[0]

proc deleteTextures*(ids: openArray[GlId]) =
  if ids.len > 0:
    fnDeleteTextures(int32(ids.len), unsafeAddr ids[0])
    for id in ids:
      if id != 0: trackDel(okTexture, 1)

proc deleteTexture*(id: GlId) = deleteTextures([id])
proc bindTexture*(target: GlEnum, id: GlId) = fnBindTexture(target, id)
proc activeTexture*(unit: GlEnum) = fnActiveTexture(unit)
proc generateMipmap*(target: GlEnum) = fnGenerateMipmap(target)

proc texParameteri*(target, pname: GlEnum, param: int32) =
  fnTexParameteri(target, pname, param)

proc texImage2D*[T](target: GlEnum, level, ifmt, w, h: int32, fmt, ty: GlEnum,
    data: openArray[T]) =
  ## Uploads `data` (the caller guarantees it holds w*h pixels of `fmt`/`ty`).
  let p = if data.len > 0: cast[pointer](unsafeAddr data[0]) else: nil
  fnTexImage2D(target, level, ifmt, w, h, 0, fmt, ty, p)

proc texImage2DEmpty*(target: GlEnum, level, ifmt, w, h: int32, fmt, ty: GlEnum) =
  ## Allocates storage without uploading (`data = nullptr`).
  fnTexImage2D(target, level, ifmt, w, h, 0, fmt, ty, nil)

proc texSubImage2D*[T](target: GlEnum, level, x, y, w, h: int32, fmt, ty: GlEnum,
    data: openArray[T]) =
  if data.len > 0:
    fnTexSubImage2D(target, level, x, y, w, h, fmt, ty, cast[pointer](unsafeAddr data[0]))

# ---------------------------------------------------------------- framebuffers

proc genFramebuffers*(n: int): seq[GlId] =
  result = newSeq[GlId](n)
  if n > 0:
    fnGenFramebuffers(int32(n), addr result[0])
    trackGen(okFramebuffer, n)

proc genFramebuffer*(): GlId = genFramebuffers(1)[0]

proc deleteFramebuffers*(ids: openArray[GlId]) =
  if ids.len > 0:
    fnDeleteFramebuffers(int32(ids.len), unsafeAddr ids[0])
    for id in ids:
      if id != 0: trackDel(okFramebuffer, 1)

proc deleteFramebuffer*(id: GlId) = deleteFramebuffers([id])
proc bindFramebuffer*(target: GlEnum, id: GlId) = fnBindFramebuffer(target, id)

proc genRenderbuffers*(n: int): seq[GlId] =
  result = newSeq[GlId](n)
  if n > 0:
    fnGenRenderbuffers(int32(n), addr result[0])
    trackGen(okRenderbuffer, n)

proc genRenderbuffer*(): GlId = genRenderbuffers(1)[0]

proc deleteRenderbuffers*(ids: openArray[GlId]) =
  if ids.len > 0:
    fnDeleteRenderbuffers(int32(ids.len), unsafeAddr ids[0])
    for id in ids:
      if id != 0: trackDel(okRenderbuffer, 1)

proc deleteRenderbuffer*(id: GlId) = deleteRenderbuffers([id])
proc bindRenderbuffer*(target: GlEnum, id: GlId) = fnBindRenderbuffer(target, id)

proc renderbufferStorage*(target, fmt: GlEnum, w, h: int32) =
  fnRenderbufferStorage(target, fmt, w, h)

proc renderbufferStorageMultisample*(target: GlEnum, samples: int32, fmt: GlEnum,
    w, h: int32) =
  fnRenderbufferStorageMultisample(target, samples, fmt, w, h)

proc framebufferTexture2D*(target, att, textarget: GlEnum, tex: GlId, level: int32) =
  fnFramebufferTexture2D(target, att, textarget, tex, level)

proc framebufferRenderbuffer*(target, att, rbTarget: GlEnum, rb: GlId) =
  fnFramebufferRenderbuffer(target, att, rbTarget, rb)

proc checkFramebufferStatus*(target: GlEnum): GlEnum = fnCheckFramebufferStatus(target)

proc blitFramebuffer*(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1: int32, mask: uint32,
    filter: GlEnum) =
  fnBlitFramebuffer(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter)

proc invalidateFramebuffer*(target: GlEnum, att: openArray[GlEnum]) =
  ## GL 4.3 entry point: a no-op when the driver does not provide it.
  if fnInvalidateFramebuffer != nil and att.len > 0:
    fnInvalidateFramebuffer(target, int32(att.len), unsafeAddr att[0])

# ---------------------------------------------------------------- readback

proc readPixels*[T](x, y, w, h: int32, fmt, ty: GlEnum, buf: var openArray[T]) =
  ## Reads into `buf`; the caller sizes it for `w*h` pixels of `fmt`/`ty`.
  if buf.len > 0 and w > 0 and h > 0:
    fnReadPixels(x, y, w, h, fmt, ty, cast[pointer](addr buf[0]))

proc readPixels*(x, y, w, h: int32, buf: var seq[uint32]) =
  ## RGBA8 readback. Each word is R | G<<8 | B<<16 | A<<24 (ThorVG ABGR8888),
  ## bottom row first (GL origin).
  buf.setLen(max(int(w), 0) * max(int(h), 0))
  pixelStorei(GlPackAlignment, 4)
  readPixels(x, y, w, h, GlRgba, GlUnsignedByte, buf)
