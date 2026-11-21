## GL stage buffer: CPU-side arrays flushed to GL buffers (port of tvgGlGpuBuffer.cpp/.h).
##
## The C++ stage buffer is three byte arrays (`mStageBuffer`, `mAuxBuffer`, `mIndexBuffer`)
## addressed by byte offsets. Here each array is a `seq[uint32]` of 32-bit words (every datum the
## engine stores is 4-byte granular) and every offset / size is still a BYTE count (`int`), so the
## offsets handed to `GlVertexLayout` / `GlBindingResource` are unchanged.
##
## - `stage`: vertices and uniform blocks (`push`, `reserve`, aligned for UBO offsets on request)
## - `aux`: per-vertex colors, one word per vertex (`rgbaWord`, little endian R | G<<8 | B<<16 | A<<24)
## - `index`: `uint32` element indices
##
## `reserve*` extends the array with zero words and returns the byte offset; the caller then
## writes `s.stage[offset div 4 + i]` (floats through `floatBits`, re-exported from `gl_ffi`).

import ./[gl_ffi, state_cache]

type
  GlGpuBuffer* = object
    ## One GL buffer object, deleted with the value (move-only).
    id: GlId

  GlVertexArray = object
    ## One VAO, deleted with the value (move-only).
    id: GlId

  GlStageBufferObj* = object
    vao: GlVertexArray
    gpuBuffer, gpuAuxBuffer, gpuIndexBuffer: GlGpuBuffer
    stage*, aux*, index*: seq[uint32]
    opacityOffsets: array[256, int]  ## -1 = not pushed since the last flush
    alignment: int                   ## GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT, 0 = unknown
    cpuOnly: bool                    ## `newCpuStageBuffer`: no GL objects, fake buffer ids

  GlStageBuffer* = ref GlStageBufferObj

# ---------------------------------------------------------------- GlGpuBuffer

proc `=destroy`*(b: GlGpuBuffer) =
  if b.id != 0 and glReady():
    try: deleteBuffer(b.id)
    except Exception: discard

proc `=copy`*(a: var GlGpuBuffer, b: GlGpuBuffer) {.error.}

proc initGlGpuBuffer*(): GlGpuBuffer =
  ## `GlGpuBuffer::GlGpuBuffer`: generates the buffer object.
  var id = 0'u32
  glCheck((id = genBuffer()))
  doAssert id != 0
  result = GlGpuBuffer(id: id)

func getBufferId*(b: GlGpuBuffer): GlId = b.id

proc updateBufferData*[T](b: GlGpuBuffer, target: GlEnum, data: openArray[T]) =
  ## `glBufferData(target, size, data, GL_STATIC_DRAW)`; the buffer must be bound to `target`.
  glCheck(bufferData(target, data, GlStaticDraw))

# ---------------------------------------------------------------- GlStageBuffer

proc `=destroy`(v: GlVertexArray) =
  if v.id != 0 and glReady():
    try: deleteVertexArray(v.id)
    except Exception: discard

proc `=copy`(a: var GlVertexArray, b: GlVertexArray) {.error.}

proc newGlStageBuffer*(): GlStageBuffer =
  ## Needs a current GL context (generates a VAO and three buffers). The GL objects are
  ## released by the move-only members (`GlVertexArray`, `GlGpuBuffer`) with the object.
  result = GlStageBuffer()
  for o in result.opacityOffsets.mitems: o = -1
  var newVao = 0'u32
  glCheck((newVao = genVertexArray()))
  result.vao = GlVertexArray(id: newVao)
  result.gpuBuffer = initGlGpuBuffer()
  result.gpuAuxBuffer = initGlGpuBuffer()
  result.gpuIndexBuffer = initGlGpuBuffer()

proc newCpuStageBuffer*(alignment = 256): GlStageBuffer =
  ## GL-free stage buffer for tests and oracles (no context needed): only the arrays exist, the
  ## UBO offset alignment is `alignment`, the buffer ids are fake (stage 1, aux 2, index 3) and
  ## `flushToGPU` just empties the arrays.
  result = GlStageBuffer(alignment: alignment, cpuOnly: true)
  for o in result.opacityOffsets.mitems: o = -1

func getBufferId*(s: GlStageBuffer): GlId =
  if s.cpuOnly: 1 else: s.gpuBuffer.getBufferId()
func getAuxBufferId*(s: GlStageBuffer): GlId =
  if s.cpuOnly: 2 else: s.gpuAuxBuffer.getBufferId()
func getIndexBufferId*(s: GlStageBuffer): GlId =
  if s.cpuOnly: 3 else: s.gpuIndexBuffer.getBufferId()
func vaoId*(s: GlStageBuffer): GlId = s.vao.id

func stageSize*(s: GlStageBuffer): int = s.stage.len * 4
  ## Bytes currently in the stage array (C++ `mStageBuffer.count`).

func auxSize*(s: GlStageBuffer): int = s.aux.len * 4
func indexSize*(s: GlStageBuffer): int = s.index.len * 4

func rgbaWord*(r, g, b, a: uint8): uint32 =
  ## One `tvg::RGBA` as the little-endian word that `GL_UNSIGNED_BYTE` x4 reads back.
  uint32(r) or (uint32(g) shl 8) or (uint32(b) shl 16) or (uint32(a) shl 24)

proc alignOffset(s: GlStageBuffer) =
  ## Pads the stage array up to the next UBO offset alignment (`GlStageBuffer::alignOffset`).
  if s.alignment == 0:
    glCheck((s.alignment = int(getInteger(GlUniformBufferOffsetAlignment))))
  let bytes = s.stage.len * 4
  if s.alignment > 0 and bytes mod s.alignment != 0:
    s.stage.setLen(s.stage.len + (s.alignment - bytes mod s.alignment) div 4)

proc reserve*(s: GlStageBuffer, size: int, alignGpuOffset = false): int =
  ## Appends `size` zero bytes (a multiple of 4) to the stage array; returns their byte offset.
  doAssert size mod 4 == 0
  if alignGpuOffset: s.alignOffset()
  result = s.stage.len * 4
  s.stage.setLen(s.stage.len + size div 4)

proc reserveAux*(s: GlStageBuffer, size: int): int =
  doAssert size mod 4 == 0
  result = s.aux.len * 4
  s.aux.setLen(s.aux.len + size div 4)

proc reserveIndex*(s: GlStageBuffer, size: int): int =
  doAssert size mod 4 == 0
  result = s.index.len * 4
  s.index.setLen(s.index.len + size div 4)

proc push*(s: GlStageBuffer, data: openArray[float32], alignGpuOffset = false): int =
  ## Appends the floats to the stage array; returns the byte offset.
  result = s.reserve(data.len * 4, alignGpuOffset)
  for i, v in data: s.stage[result div 4 + i] = floatBits(v)

proc push*(s: GlStageBuffer, data: openArray[uint32], alignGpuOffset = false): int =
  result = s.reserve(data.len * 4, alignGpuOffset)
  for i, v in data: s.stage[result div 4 + i] = v

proc push*(s: GlStageBuffer, data: openArray[int32], alignGpuOffset = false): int =
  result = s.reserve(data.len * 4, alignGpuOffset)
  for i, v in data: s.stage[result div 4 + i] = int32Bits(v)

proc pushAux*(s: GlStageBuffer, data: openArray[uint32]): int =
  ## Appends packed RGBA words (`rgbaWord`) to the aux array.
  result = s.reserveAux(data.len * 4)
  for i, v in data: s.aux[result div 4 + i] = v

proc pushIndex*(s: GlStageBuffer, data: openArray[uint32]): int =
  result = s.reserveIndex(data.len * 4)
  for i, v in data: s.index[result div 4 + i] = v

proc getImageOpacityOffset*(s: GlStageBuffer, opacity: uint8): int =
  ## Aligned offset of the `GlImageOpacityBlock {opacity, 0, 0, 0}`, pushed once per flush.
  if s.opacityOffsets[opacity] < 0:
    s.opacityOffsets[opacity] = s.push([int32(opacity), 0'i32, 0'i32, 0'i32], true)
  result = s.opacityOffsets[opacity]

proc clear(s: GlStageBuffer) =
  s.stage.setLen(0)
  s.aux.setLen(0)
  s.index.setLen(0)

proc flushToGPU*(s: GlStageBuffer, state: var GlStateCache): bool =
  ## Uploads the three arrays (GL_STATIC_DRAW) and empties them. False (and nothing uploaded)
  ## when there is nothing to draw: no vertices at all, or no indices.
  for o in s.opacityOffsets.mitems: o = -1
  if s.cpuOnly:
    s.clear()
    return true
  if (s.stage.len == 0 and s.aux.len == 0) or s.index.len == 0:
    s.clear()
    return false

  state.bindVertexArray(s.vao.id)
  if s.stage.len > 0:
    state.bindBuffer(GlArrayBuffer, s.gpuBuffer.getBufferId())
    s.gpuBuffer.updateBufferData(GlArrayBuffer, s.stage)
  if s.aux.len > 0:
    state.bindBuffer(GlArrayBuffer, s.gpuAuxBuffer.getBufferId())
    s.gpuAuxBuffer.updateBufferData(GlArrayBuffer, s.aux)
  state.bindBuffer(GlElementArrayBuffer, s.gpuIndexBuffer.getBufferId())
  s.gpuIndexBuffer.updateBufferData(GlElementArrayBuffer, s.index)
  s.clear()
  result = true

proc bindStage*(s: GlStageBuffer, state: var GlStateCache) =
  ## C++ `GlStageBuffer::bind` (`bind` is a Nim keyword).
  state.bindVertexArray(s.vao.id)
  state.bindBuffer(GlArrayBuffer, s.gpuBuffer.getBufferId())
  state.bindBuffer(GlElementArrayBuffer, s.gpuIndexBuffer.getBufferId())

proc unbind*(s: GlStageBuffer, state: var GlStateCache) =
  state.bindVertexArray(s.vao.id)
  state.bindBuffer(GlArrayBuffer, 0)
  glCheck(bindBuffer(GlUniformBuffer, 0))
  state.bindBuffer(GlElementArrayBuffer, 0)
  state.bindVertexArray(0)
