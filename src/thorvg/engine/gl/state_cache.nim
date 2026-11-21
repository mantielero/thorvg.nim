## GL state cache: filters redundant GL state changes (port of tvgGlStateCache.cpp/.h).
##
## Every setter compares its arguments with the last value this cache sent to the driver and
## skips the GL call when they are equal. `invalidate()` only forgets the CPU-side knowledge
## (it issues no GL call): call it when something else may have touched the context.
##
## Same names as the C++ (`GlStateCache::bindTexture2D` -> `bindTexture2D(cache, ...)`); the
## C++ `CachedValue<T>` is `CachedValue[T]` (`matches` / `store` / `invalidate`).

import ./gl_ffi

type
  CachedValue*[T] = object
    value*: T
    valid*: bool

  RectState* = tuple[x, y, width, height: int32]
    ## Arguments shared by glViewport() and glScissor().
  BlendFuncState* = tuple[source, destination, sourceAlpha, destinationAlpha: GlEnum]
  ColorMaskState* = tuple[red, green, blue, alpha: bool]
  StencilFuncState* = tuple[function: GlEnum, reference: int32, mask: uint32]
  StencilOpState* = tuple[stencilFail, depthFail, depthPass: GlEnum]
  ClearColorState* = tuple[red, green, blue, alpha: float32]
  VertexPointerState* = tuple[size: int32, ty: GlEnum, normalized: bool, stride: int32,
    offset: int, sourceBuffer: GlId]
  VertexConstantState* = tuple[x, y, z, w: float32]

  BufferBindingState* = object
    target*: GlEnum
    buffer*: CachedValue[GlId]

  TextureBindingState* = object
    textureUnit*: GlEnum
    texture*: CachedValue[GlId]

  CapabilityState* = object
    capability*: GlEnum
    enabled*: CachedValue[bool]

  VertexAttributeState* = object
    enabled*: CachedValue[bool]
    attribPointer*: CachedValue[VertexPointerState]
    constant*: CachedValue[VertexConstantState]
    known*: bool  ## index has cache-managed OpenGL state
    used*: bool   ## index is used by the current vertex layout

  GlStateCache* = object
    program*: CachedValue[GlId]
    vertexArray*: CachedValue[GlId]
    elementArrayBuffer*: CachedValue[GlId]
    buffers*: seq[BufferBindingState]
    activeTextureUnit*: CachedValue[GlEnum]
    textures*: seq[TextureBindingState]
    vertexAttributes*: seq[VertexAttributeState]
    viewportState*: CachedValue[RectState]
    scissorState*: CachedValue[RectState]
    readFramebuffer*: CachedValue[GlId]
    drawFramebuffer*: CachedValue[GlId]
    capabilities*: seq[CapabilityState]
    blendFunction*: CachedValue[BlendFuncState]
    depthFunction*: CachedValue[GlEnum]
    depthWriteEnabled*: CachedValue[bool]
    colorWriteMask*: CachedValue[ColorMaskState]
    frontStencilFunction*: CachedValue[StencilFuncState]
    backStencilFunction*: CachedValue[StencilFuncState]
    frontStencilOperation*: CachedValue[StencilOpState]
    backStencilOperation*: CachedValue[StencilOpState]
    clearColorState*: CachedValue[ClearColorState]
    clearStencilValue*: CachedValue[int32]
    clearDepthValue*: CachedValue[float64]

proc `=copy`*(a: var GlStateCache, b: GlStateCache) {.error.}
  ## Like the C++ deleted copy constructor: a cache describes ONE context.

func matches*[T](c: CachedValue[T], candidate: T): bool =
  c.valid and c.value == candidate

func store*[T](c: var CachedValue[T], candidate: T) =
  ## C++ `CachedValue::set`.
  c.value = candidate
  c.valid = true

func invalidate*[T](c: var CachedValue[T]) =
  c.valid = false

# ---------------------------------------------------------------- lookups

proc bufferBindingIndex*(c: var GlStateCache, target: GlEnum): int =
  ## Position of the binding of `target` in `c.buffers` (appended when new).
  for i in 0 ..< c.buffers.len:
    if c.buffers[i].target == target: return i
  c.buffers.add BufferBindingState(target: target)
  result = c.buffers.high

proc textureBindingIndex*(c: var GlStateCache, textureUnit: GlEnum): int =
  for i in 0 ..< c.textures.len:
    if c.textures[i].textureUnit == textureUnit: return i
  c.textures.add TextureBindingState(textureUnit: textureUnit)
  result = c.textures.high

proc capabilityIndex*(c: var GlStateCache, value: GlEnum): int =
  for i in 0 ..< c.capabilities.len:
    if c.capabilities[i].capability == value: return i
  c.capabilities.add CapabilityState(capability: value)
  result = c.capabilities.high

proc vertexAttributeIndex*(c: var GlStateCache, index: uint32): int =
  ## Grows the attribute table up to `index` and marks it `known`.
  while c.vertexAttributes.len <= int(index):
    c.vertexAttributes.add VertexAttributeState()
  c.vertexAttributes[int(index)].known = true
  result = int(index)

# ---------------------------------------------------------------- invalidation

proc invalidateVertexArrayState*(c: var GlStateCache) =
  c.elementArrayBuffer.invalidate()
  for a in c.vertexAttributes.mitems:
    a.enabled.invalidate()
    a.attribPointer.invalidate()
    a.used = false

proc invalidateVertexConstants*(c: var GlStateCache) =
  for a in c.vertexAttributes.mitems: a.constant.invalidate()

proc invalidate*(c: var GlStateCache) =
  ## Forgets CPU-side assumptions only; deliberately issues no GL reset. Applications sharing
  ## the context must restore external state before `GlRenderer.sync()`.
  c.program.invalidate()
  c.vertexArray.invalidate()
  c.invalidateVertexArrayState()
  c.invalidateVertexConstants()
  for b in c.buffers.mitems: b.buffer.invalidate()

  c.activeTextureUnit.invalidate()
  for b in c.textures.mitems: b.texture.invalidate()

  c.viewportState.invalidate()
  c.scissorState.invalidate()
  c.readFramebuffer.invalidate()
  c.drawFramebuffer.invalidate()

  for s in c.capabilities.mitems: s.enabled.invalidate()
  c.blendFunction.invalidate()
  c.depthFunction.invalidate()
  c.depthWriteEnabled.invalidate()
  c.colorWriteMask.invalidate()

  c.frontStencilFunction.invalidate()
  c.backStencilFunction.invalidate()
  c.frontStencilOperation.invalidate()
  c.backStencilOperation.invalidate()

  c.clearColorState.invalidate()
  c.clearStencilValue.invalidate()
  c.clearDepthValue.invalidate()

# ---------------------------------------------------------------- setters

proc setCapability*(c: var GlStateCache, value: GlEnum, enabled: bool) =
  let i = c.capabilityIndex(value)
  if c.capabilities[i].enabled.matches(enabled): return
  if enabled: glCheck(enable(value))
  else: glCheck(disable(value))
  c.capabilities[i].enabled.store(enabled)

proc enable*(c: var GlStateCache, cap: GlEnum) = c.setCapability(cap, true)
proc disable*(c: var GlStateCache, cap: GlEnum) = c.setCapability(cap, false)

proc useProgram*(c: var GlStateCache, value: GlId) =
  if c.program.matches(value): return
  glCheck(useProgram(value))
  c.program.store(value)

proc bindVertexArray*(c: var GlStateCache, value: GlId) =
  if c.vertexArray.matches(value): return
  glCheck(bindVertexArray(value))
  c.vertexArray.store(value)
  c.invalidateVertexArrayState()

proc bindBuffer*(c: var GlStateCache, target: GlEnum, buffer: GlId) =
  if target == GlElementArrayBuffer:
    if c.elementArrayBuffer.matches(buffer): return
    glCheck(bindBuffer(target, buffer))
    c.elementArrayBuffer.store(buffer)
  else:
    let i = c.bufferBindingIndex(target)
    if c.buffers[i].buffer.matches(buffer): return
    glCheck(bindBuffer(target, buffer))
    c.buffers[i].buffer.store(buffer)

proc bindTexture2D*(c: var GlStateCache, textureUnit: GlEnum, texture: GlId) =
  if not c.activeTextureUnit.matches(textureUnit):
    glCheck(activeTexture(textureUnit))
    c.activeTextureUnit.store(textureUnit)
  let i = c.textureBindingIndex(textureUnit)
  if c.textures[i].texture.matches(texture): return
  glCheck(bindTexture(GlTexture2D, texture))
  c.textures[i].texture.store(texture)

# ---------------------------------------------------------------- vertex layout

proc beginVertexLayout*(c: var GlStateCache) =
  for a in c.vertexAttributes.mitems: a.used = false

proc disableVertexAttribute(index: uint32, a: var VertexAttributeState) =
  if a.enabled.matches(false): return
  glCheck(disableVertexAttribArray(index))
  a.enabled.store(false)

proc enableVertexAttribute(index: uint32, a: var VertexAttributeState) =
  if a.enabled.matches(true): return
  glCheck(enableVertexAttribArray(index))
  a.enabled.store(true)

proc setVertexAttribPointer*(c: var GlStateCache, index: uint32, size: int32, ty: GlEnum,
    normalized: bool, stride: int32, offset: int, sourceBuffer: GlId) =
  c.bindBuffer(GlArrayBuffer, sourceBuffer)
  let i = c.vertexAttributeIndex(index)
  c.vertexAttributes[i].used = true
  # A draw with an enabled array leaves the generic attribute value undefined.
  # Replay the constant if this attribute later transitions back to constant mode.
  c.vertexAttributes[i].constant.invalidate()
  enableVertexAttribute(index, c.vertexAttributes[i])
  let state: VertexPointerState = (size, ty, normalized, stride, offset, sourceBuffer)
  if c.vertexAttributes[i].attribPointer.matches(state): return
  glCheck(vertexAttribPointer(index, size, ty, normalized, stride, offset))
  c.vertexAttributes[i].attribPointer.store(state)

proc setVertexAttrib4f*(c: var GlStateCache, index: uint32, x, y, z, w: float32) =
  let i = c.vertexAttributeIndex(index)
  c.vertexAttributes[i].used = true
  disableVertexAttribute(index, c.vertexAttributes[i])
  let constant: VertexConstantState = (x, y, z, w)
  if c.vertexAttributes[i].constant.matches(constant): return
  glCheck(vertexAttrib4f(index, x, y, z, w))
  c.vertexAttributes[i].constant.store(constant)

proc endVertexLayout*(c: var GlStateCache) =
  for i in 0 ..< c.vertexAttributes.len:
    if c.vertexAttributes[i].known and not c.vertexAttributes[i].used:
      disableVertexAttribute(uint32(i), c.vertexAttributes[i])

# ---------------------------------------------------------------- viewport, framebuffers

proc viewport*(c: var GlStateCache, x, y, width, height: int32) =
  let state: RectState = (x, y, width, height)
  if c.viewportState.matches(state): return
  glCheck(viewport(x, y, width, height))
  c.viewportState.store(state)

proc scissor*(c: var GlStateCache, x, y, width, height: int32) =
  let state: RectState = (x, y, width, height)
  if c.scissorState.matches(state): return
  glCheck(scissor(x, y, width, height))
  c.scissorState.store(state)

proc bindFramebuffer*(c: var GlStateCache, target: GlEnum, framebuffer: GlId) =
  if target == GlFramebuffer:
    if c.readFramebuffer.matches(framebuffer) and c.drawFramebuffer.matches(framebuffer): return
    glCheck(bindFramebuffer(target, framebuffer))
    c.readFramebuffer.store(framebuffer)
    c.drawFramebuffer.store(framebuffer)
  elif target == GlReadFramebuffer:
    if c.readFramebuffer.matches(framebuffer): return
    glCheck(bindFramebuffer(target, framebuffer))
    c.readFramebuffer.store(framebuffer)
  elif target == GlDrawFramebuffer:
    if c.drawFramebuffer.matches(framebuffer): return
    glCheck(bindFramebuffer(target, framebuffer))
    c.drawFramebuffer.store(framebuffer)
  else:
    glCheck(bindFramebuffer(target, framebuffer))

# ---------------------------------------------------------------- blend, depth

proc blendFuncSeparate*(c: var GlStateCache, source, destination, sourceAlpha,
    destinationAlpha: GlEnum) =
  let state: BlendFuncState = (source, destination, sourceAlpha, destinationAlpha)
  if c.blendFunction.matches(state): return
  glCheck(blendFuncSeparate(source, destination, sourceAlpha, destinationAlpha))
  c.blendFunction.store(state)

proc depthFunc*(c: var GlStateCache, function: GlEnum) =
  if c.depthFunction.matches(function): return
  glCheck(depthFunc(function))
  c.depthFunction.store(function)

proc depthMask*(c: var GlStateCache, enabled: bool) =
  if c.depthWriteEnabled.matches(enabled): return
  glCheck(depthMask(enabled))
  c.depthWriteEnabled.store(enabled)

proc colorMask*(c: var GlStateCache, red, green, blue, alpha: bool) =
  let state: ColorMaskState = (red, green, blue, alpha)
  if c.colorWriteMask.matches(state): return
  glCheck(colorMask(red, green, blue, alpha))
  c.colorWriteMask.store(state)

# ---------------------------------------------------------------- stencil

proc stencilFunc*(c: var GlStateCache, function: GlEnum, reference: int32, mask: uint32) =
  let state: StencilFuncState = (function, reference, mask)
  if c.frontStencilFunction.matches(state) and c.backStencilFunction.matches(state): return
  glCheck(stencilFunc(function, reference, mask))
  c.frontStencilFunction.store(state)
  c.backStencilFunction.store(state)

proc stencilFuncSeparate*(c: var GlStateCache, face, function: GlEnum, reference: int32,
    mask: uint32) =
  let state: StencilFuncState = (function, reference, mask)
  if face == GlFront:
    if c.frontStencilFunction.matches(state): return
    glCheck(stencilFuncSeparate(face, function, reference, mask))
    c.frontStencilFunction.store(state)
  elif face == GlBack:
    if c.backStencilFunction.matches(state): return
    glCheck(stencilFuncSeparate(face, function, reference, mask))
    c.backStencilFunction.store(state)
  elif face == GlFrontAndBack:
    if c.frontStencilFunction.matches(state) and c.backStencilFunction.matches(state): return
    glCheck(stencilFuncSeparate(face, function, reference, mask))
    c.frontStencilFunction.store(state)
    c.backStencilFunction.store(state)
  else:
    glCheck(stencilFuncSeparate(face, function, reference, mask))

proc stencilOp*(c: var GlStateCache, stencilFail, depthFail, depthPass: GlEnum) =
  let state: StencilOpState = (stencilFail, depthFail, depthPass)
  if c.frontStencilOperation.matches(state) and c.backStencilOperation.matches(state): return
  glCheck(stencilOp(stencilFail, depthFail, depthPass))
  c.frontStencilOperation.store(state)
  c.backStencilOperation.store(state)

proc stencilOpSeparate*(c: var GlStateCache, face, stencilFail, depthFail, depthPass: GlEnum) =
  let state: StencilOpState = (stencilFail, depthFail, depthPass)
  if face == GlFront:
    if c.frontStencilOperation.matches(state): return
    glCheck(stencilOpSeparate(face, stencilFail, depthFail, depthPass))
    c.frontStencilOperation.store(state)
  elif face == GlBack:
    if c.backStencilOperation.matches(state): return
    glCheck(stencilOpSeparate(face, stencilFail, depthFail, depthPass))
    c.backStencilOperation.store(state)
  elif face == GlFrontAndBack:
    if c.frontStencilOperation.matches(state) and c.backStencilOperation.matches(state): return
    glCheck(stencilOpSeparate(face, stencilFail, depthFail, depthPass))
    c.frontStencilOperation.store(state)
    c.backStencilOperation.store(state)
  else:
    glCheck(stencilOpSeparate(face, stencilFail, depthFail, depthPass))

# ---------------------------------------------------------------- clear values

proc clearColor*(c: var GlStateCache, red, green, blue, alpha: float32) =
  let state: ClearColorState = (red, green, blue, alpha)
  if c.clearColorState.matches(state): return
  glCheck(clearColor(red, green, blue, alpha))
  c.clearColorState.store(state)

proc clearStencil*(c: var GlStateCache, value: int32) =
  if c.clearStencilValue.matches(value): return
  glCheck(clearStencil(value))
  c.clearStencilValue.store(value)

proc clearDepth*(c: var GlStateCache, value: float64) =
  if c.clearDepthValue.matches(value): return
  glCheck(clearDepth(value))
  c.clearDepthValue.store(value)
