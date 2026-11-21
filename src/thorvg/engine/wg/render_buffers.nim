## Staging/geometry buffers and batch ranges for the WG (WebGPU) engine.
##
## Port of staging/buffer parts of upstream/src/renderer/gpu_engine/wg/tvgWgRenderData.h/.cpp.
## Holds CPU-side staging arrays and GPU buffer handles for geometry, solid colors and uniforms.

import ../../core/[types, geom]
import ./[wg_ffi, wg_common, bind_groups, mesh, render_data]

type
  WgGeometryRange* = object
    vertexOffset*: int
    indexOffset*: int
    vertexCount*: uint32
    indexCount*: uint32

  WgSolidBatchRange* = object
    geom*: WgGeometryRange
    colorOffset*: int
    viewport*: Region

  WgImageBatchRange* = object
    geom*: WgGeometryRange
    texCoordOffset*: int
    viewport*: Region

  WgStencilBatchRange* = object
    stencil*: WgGeometryRange
    cover*: WgGeometryRange
    colorOffset*: int
    viewport*: Region
    fillRule*: FillRule
    solidOnly*: bool

  ByteBuffer* = object
    data*: seq[byte]
    count*: int

  WgStageBufferGeometry* = object
    vbuffer*: ByteBuffer
    ibuffer*: ByteBuffer
    vbuffer_gpu*: WGPUBuffer
    ibuffer_gpu*: WGPUBuffer

  WgStageBufferSolidColor* = object
    vbuffer*: seq[RenderColor]
    vbuffer_gpu*: WGPUBuffer

  WgStageBufferUniformBase* = object
    bbuffer*: seq[WGPUBindGroup]

proc clear*(b: var ByteBuffer) {.inline.} = b.count = 0

proc growTo*(b: var ByteBuffer; needed: int) =
  if b.data.len < needed:
    var newCap = if b.data.len == 0: 256 else: b.data.len
    while newCap < needed: newCap = newCap * 2
    b.data.setLen(newCap)

proc appendBytes*(b: var ByteBuffer; src: pointer; size: int) =
  if size <= 0: return
  b.growTo(b.count + size)
  if src != nil:
    copyMem(addr b.data[b.count], src, size)
  inc(b.count, size)

proc appendPointSeq*(b: var ByteBuffer; pts: seq[Point]): int =
  ## Appends points as raw bytes; returns byte offset of appended block.
  result = b.count
  if pts.len == 0: return
  b.appendBytes(unsafeAddr pts[0], pts.len * sizeof(Point))

proc appendIndexSeq*(b: var ByteBuffer; idx: seq[uint32]): int =
  result = b.count
  if idx.len == 0: return
  b.appendBytes(unsafeAddr idx[0], idx.len * sizeof(uint32))

#************************************************************************
# WgStageBufferGeometry
#************************************************************************

proc clear*(s: var WgStageBufferGeometry) =
  s.vbuffer.clear()
  s.ibuffer.clear()

proc release*(s: var WgStageBufferGeometry; ctx: var WgContext) =
  ctx.releaseBuffer(s.vbuffer_gpu)
  ctx.releaseBuffer(s.ibuffer_gpu)

proc flush*(s: var WgStageBufferGeometry; ctx: var WgContext) =
  let vptr = if s.vbuffer.count > 0: addr s.vbuffer.data[0] else: nil
  let iptr = if s.ibuffer.count > 0: cast[ptr uint32](addr s.ibuffer.data[0]) else: nil
  discard ctx.allocateBufferVertex(s.vbuffer_gpu, vptr, uint64(s.vbuffer.count))
  discard ctx.allocateBufferIndex(s.ibuffer_gpu, iptr, uint64(s.ibuffer.count))

proc appendMesh*(s: var WgStageBufferGeometry; mesh: var WgMesh) =
  if mesh.vbuffer.len > 0:
    mesh.voffset = s.vbuffer.count
    discard s.vbuffer.appendPointSeq(mesh.vbuffer)
  if mesh.tbuffer.len > 0:
    mesh.toffset = s.vbuffer.count
    discard s.vbuffer.appendPointSeq(mesh.tbuffer)
  if mesh.ibuffer.len > 0:
    mesh.ioffset = s.ibuffer.count
    discard s.ibuffer.appendIndexSeq(mesh.ibuffer)

proc appendShape*(s: var WgStageBufferGeometry; shape: WgShape) =
  s.appendMesh(shape.shape.mesh)
  s.appendMesh(shape.stroke.mesh)
  s.appendMesh(shape.stroke.bboxMesh)
  s.appendMesh(shape.bboxMesh)

proc appendImage*(s: var WgStageBufferGeometry; image: WgImage) =
  s.appendMesh(image.mesh)

proc appendBatch*(s: var WgStageBufferGeometry; shapes: openArray[WgShape]; range: var WgGeometryRange; cover: bool) =
  var vertexCount = 0'u32
  var indexCount = 0'u32
  for shape in shapes:
    let mesh = if cover: shape.bboxMesh else: shape.shape.mesh
    vertexCount += uint32(mesh.vbuffer.len)
    indexCount += uint32(mesh.ibuffer.len)

  let vertexBytes = int(vertexCount) * sizeof(Point)
  let indexBytes = int(indexCount) * sizeof(uint32)
  s.vbuffer.growTo(s.vbuffer.count + vertexBytes)
  s.ibuffer.growTo(s.ibuffer.count + indexBytes)

  range.vertexOffset = s.vbuffer.count
  range.indexOffset = s.ibuffer.count
  range.vertexCount = vertexCount
  range.indexCount = indexCount

  var baseVertex = 0'u32
  for shape in shapes:
    let mesh = if cover: shape.bboxMesh else: shape.shape.mesh
    let meshVertexBytes = mesh.vbuffer.len * sizeof(Point)
    if meshVertexBytes > 0:
      copyMem(addr s.vbuffer.data[s.vbuffer.count], unsafeAddr mesh.vbuffer[0], meshVertexBytes)
      inc(s.vbuffer.count, meshVertexBytes)
    for idx in mesh.ibuffer:
      let adjusted = idx + baseVertex
      copyMem(addr s.ibuffer.data[s.ibuffer.count], unsafeAddr adjusted, sizeof(uint32))
      inc(s.ibuffer.count, sizeof(uint32))
    baseVertex += uint32(mesh.vbuffer.len)

proc appendImageBatch*(s: var WgStageBufferGeometry; images: openArray[WgImage]; range: var WgImageBatchRange) =
  var vertexCount = 0'u32
  var indexCount = 0'u32
  for img in images:
    let mesh = img.mesh
    vertexCount += uint32(mesh.vbuffer.len)
    indexCount += uint32(mesh.ibuffer.len)

  let vertexBytes = int(vertexCount) * sizeof(Point)
  let indexBytes = int(indexCount) * sizeof(uint32)
  s.vbuffer.growTo(s.vbuffer.count + vertexBytes * 2)
  s.ibuffer.growTo(s.ibuffer.count + indexBytes)

  range.geom.vertexOffset = s.vbuffer.count
  range.texCoordOffset = s.vbuffer.count + vertexBytes
  range.geom.indexOffset = s.ibuffer.count
  range.geom.vertexCount = vertexCount
  range.geom.indexCount = indexCount

  # vertices
  var offV = range.geom.vertexOffset
  for img in images:
    let mesh = img.mesh
    let bytes = mesh.vbuffer.len * sizeof(Point)
    if bytes > 0:
      copyMem(addr s.vbuffer.data[offV], unsafeAddr mesh.vbuffer[0], bytes)
      inc(offV, bytes)
  # texcoords
  var offT = range.texCoordOffset
  for img in images:
    let mesh = img.mesh
    let bytes = mesh.tbuffer.len * sizeof(Point)
    if bytes > 0:
      copyMem(addr s.vbuffer.data[offT], unsafeAddr mesh.tbuffer[0], bytes)
      inc(offT, bytes)
  s.vbuffer.count = range.texCoordOffset + vertexBytes

  # indices
  var baseVertex = 0'u32
  for img in images:
    let mesh = img.mesh
    for idx in mesh.ibuffer:
      let adjusted = idx + baseVertex
      copyMem(addr s.ibuffer.data[s.ibuffer.count], unsafeAddr adjusted, sizeof(uint32))
      inc(s.ibuffer.count, sizeof(uint32))
    baseVertex += uint32(mesh.vbuffer.len)

proc appendStencilBatch*(s: var WgStageBufferGeometry; shapes: openArray[WgShape]; range: var WgStencilBatchRange) =
  s.appendBatch(shapes, range.stencil, false)
  s.appendBatch(shapes, range.cover, true)

#************************************************************************
# WgStageBufferSolidColor
#************************************************************************

proc append*(s: var WgStageBufferSolidColor; value: RenderColor): uint32 =
  s.vbuffer.add(value)
  uint32(s.vbuffer.len - 1)

proc appendRepeated*(s: var WgStageBufferSolidColor; value: RenderColor; count: uint32) =
  for _ in 0 ..< int(count):
    s.vbuffer.add(value)

proc clear*(s: var WgStageBufferSolidColor) =
  s.vbuffer.setLen(0)

proc release*(s: var WgStageBufferSolidColor; ctx: var WgContext) =
  ctx.releaseBuffer(s.vbuffer_gpu)

proc flush*(s: var WgStageBufferSolidColor; ctx: var WgContext) =
  if s.vbuffer.len > 0:
    discard ctx.allocateBufferVertex(s.vbuffer_gpu, addr s.vbuffer[0], uint64(s.vbuffer.len * sizeof(RenderColor)))

proc appendSolidBatch*(s: var WgStageBufferGeometry; shapes: openArray[WgShape];
                      colors: var WgStageBufferSolidColor; range: var WgSolidBatchRange) =
  s.appendBatch(shapes, range.geom, false)
  range.colorOffset = colors.vbuffer.len * sizeof(RenderColor)
  for shape in shapes:
    colors.appendRepeated(shape.shape.solid.packedColor(), uint32(shape.shape.mesh.vbuffer.len))

#************************************************************************
# Uniform stage buffers
#************************************************************************

proc releaseBindGroups*(b: var WgStageBufferUniformBase; ctx: var WgContext) =
  for i in 0 ..< b.bbuffer.len:
    ctx.layouts.releaseBindGroup(b.bbuffer[i])
  b.bbuffer.setLen(0)

proc flushBase*(b: var WgStageBufferUniformBase; ctx: var WgContext; buffer: var WGPUBuffer;
                data: pointer; reserved, count: uint64; stride: uint64) =
  if ctx.allocateBufferUniform(buffer, data, reserved, count * stride):
    b.releaseBindGroups(ctx)
  var i = uint32(b.bbuffer.len)
  while uint64(i) < count:
    b.bbuffer.add(ctx.layouts.createBindGroupBuffer1Un(buffer, uint64(i) * stride, stride))
    inc i

type
  WgStageBufferUniform*[T] = object
    base*: WgStageBufferUniformBase
    ubuffer*: seq[T]
    ubuffer_gpu*: WGPUBuffer

proc append*[T](s: var WgStageBufferUniform[T]; value: T): uint32 =
  s.ubuffer.add(value)
  uint32(s.ubuffer.len - 1)

proc clear*[T](s: var WgStageBufferUniform[T]) =
  s.ubuffer.setLen(0)

proc release*[T](s: var WgStageBufferUniform[T]; ctx: var WgContext) =
  ctx.releaseBuffer(s.ubuffer_gpu)
  s.base.releaseBindGroups(ctx)

proc flush*[T](s: var WgStageBufferUniform[T]; ctx: var WgContext) =
  let count = uint64(s.ubuffer.len)
  let dataPtr = if s.ubuffer.len > 0: addr s.ubuffer[0] else: nil
  let byteCount = count * uint64(sizeof(T))
  # `seq.cap` is not available in Nim 2.x; use current byte size as reserved hint.
  s.base.flushBase(ctx, s.ubuffer_gpu, dataPtr, byteCount, count, uint64(sizeof(T)))

proc `[]`*[T](s: WgStageBufferUniform[T]; index: uint32): WGPUBindGroup {.inline.} =
  s.base.bbuffer[int(index)]
