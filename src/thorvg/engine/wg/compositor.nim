## Compositor for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgCompositor.h/.cpp (W5 core).
## Manages render passes, staging buffers, render targets, batching requests and
## high-level shape/image/scene rendering and composition.

import std/math
import ../../core/[types, geom]
import ../../renderer/[render, effect]
import ./[wg_types, wg_ffi, wg_common, bind_groups, mesh, shader_types,
        render_data, render_buffers, render_target, pipelines]

type
  WgDepthStencilAttachment* = object
    width*, height*, sampleCount*: uint32
    texture*: WGPUTexture
    view*: WGPUTextureView

  WgRenderTargetState* = object
    target*: WgRenderTarget
    bounds*: Region
    transformOffset*: int

  WgCompose* = ref object of RenderCompositor
    renderTarget*: WgRenderTarget
    blend*: BlendMethod
    aabb*: Region
    transform*: Matrix  ## Scene/world transform used by WG composition tasks.
    flags*: CompositionFlags
    masked*: bool

  WgCompositor* = object
    pipelines*: WgPipelines

    # global resources
    viewMatWidth*, viewMatHeight*: uint32
    bufferViewMat*: WGPUBuffer
    bindGroupViewMat*: WGPUBindGroup
    bufferOpacities*: WGPUBuffer
    bindGroupOpacities*: array[256, WGPUBindGroup]

    # composition intermediates and helpers
    meshDataBlit*: WgMesh
    targetTemp0*, targetTemp1*: WgRenderTarget
    bindGroupStorageTemp*: WGPUBindGroup
    width*, height*: uint32

    # stage buffers
    stageBufferGeometry*: WgStageBufferGeometry
    stageBufferPaint*: WgStageBufferUniform[WgShaderTypePaintSettings]
    stageBufferSolidColor*: WgStageBufferSolidColor
    stageBufferViewMat*: WgStageBufferUniform[WgShaderTypeMat4x4fBlock]

    # current pass
    commandEncoder*: WGPUCommandEncoder
    renderPassEncoder*: WGPURenderPassEncoder
    currentTargetState*: ptr WgRenderTargetState
    renderPassCount*: uint32

    # cached depth-stencil attachments
    depthStencilAttachments*: seq[WgDepthStencilAttachment]

# helpers
template rx(r: Region): int32 = r.xMin
template ry(r: Region): int32 = r.yMin
template rw(r: Region): uint32 = (if r.xMax > r.xMin: uint32(r.xMax - r.xMin) else: 0'u32)
template rh(r: Region): uint32 = (if r.yMax > r.yMin: uint32(r.yMax - r.yMin) else: 0'u32)

proc clampi(v, lo, hi: int32): int32 = max(lo, min(hi, v))

proc gradientPipeline(pipelines: var WgPipelines; t: WgRenderSettingsType; convex: bool): WGPURenderPipeline =
  case t
  of rstLinear: (if convex: pipelines.linearConv else: pipelines.linear)
  of rstRadial: (if convex: pipelines.radialConv else: pipelines.radial)
  of rstConic:  (if convex: pipelines.conicConv  else: pipelines.conic)
  else: WGPURenderPipeline(nil)

proc gradientBlendPipeline(pipelines: var WgPipelines; ctx: var WgContext; t: WgRenderSettingsType; blendMethod: BlendMethod): WGPURenderPipeline =
  case t
  of rstLinear: pipelines.linearBlend(ctx, blendMethod)
  of rstRadial: pipelines.radialBlend(ctx, blendMethod)
  of rstConic:  pipelines.conicBlend(ctx, blendMethod)
  else: WGPURenderPipeline(nil)

# forward declarations
proc flush*(comp: var WgCompositor; ctx: var WgContext)
proc copyBackdrop*(comp: var WgCompositor; ctx: var WgContext; blendMethod: BlendMethod): bool

proc updateViewMat*(comp: var WgCompositor; ctx: var WgContext; width, height: uint32) =
  if (not isNil(comp.bindGroupViewMat)) and comp.viewMatWidth == width and comp.viewMatHeight == height:
    return
  var viewMat = initWgShaderTypeMat4x4f(int(width), int(height))
  let bufferChanged = ctx.allocateBufferUniform(comp.bufferViewMat, addr viewMat, uint64(sizeof(viewMat)))
  if bufferChanged or isNil(comp.bindGroupViewMat):
    ctx.layouts.releaseBindGroup(comp.bindGroupViewMat)
    comp.bindGroupViewMat = ctx.layouts.createBindGroupBuffer1Un(comp.bufferViewMat)
  comp.viewMatWidth = width
  comp.viewMatHeight = height

proc initPools*(comp: var WgCompositor; ctx: var WgContext) =
  const stride = 256'u32
  var opacities = newSeq[byte](int(256'u32 * stride))
  for i in 0 ..< 256:
    let v = float32(i) / 255.0'f32
    let off = int(uint32(i) * stride)
    copyMem(addr opacities[off], unsafeAddr v, sizeof(float32))
  let dataPtr = if opacities.len > 0: addr opacities[0] else: nil
  discard ctx.allocateBufferUniform(comp.bufferOpacities, dataPtr, uint64(opacities.len))
  for i in 0'u32 ..< 256'u32:
    comp.bindGroupOpacities[int(i)] = ctx.layouts.createBindGroupBuffer1Un(comp.bufferOpacities, uint64(i * stride), uint64(sizeof(float32)))

proc releasePools*(comp: var WgCompositor; ctx: var WgContext) =
  for i in 0 ..< 256:
    ctx.layouts.releaseBindGroup(comp.bindGroupOpacities[i])
  ctx.releaseBuffer(comp.bufferOpacities)

proc getDepthStencilView*(comp: var WgCompositor; ctx: var WgContext; width, height, sampleCount: uint32): WGPUTextureView =
  for a in comp.depthStencilAttachments:
    if a.width == width and a.height == height and a.sampleCount == sampleCount:
      return a.view
  let texture = ctx.createTexAttachement(width, height, WGPUTextureFormat_Depth24PlusStencil8, sampleCount)
  let view = ctx.createTextureView(texture)
  comp.depthStencilAttachments.add(WgDepthStencilAttachment(width: width, height: height, sampleCount: sampleCount, texture: texture, view: view))
  view

proc resize*(comp: var WgCompositor; ctx: var WgContext; width, height: uint32) =
  if comp.width != width or comp.height != height:
    ctx.layouts.releaseBindGroup(comp.bindGroupStorageTemp)
    comp.targetTemp1.release(ctx)
    comp.targetTemp0.release(ctx)
    for a in comp.depthStencilAttachments.mitems:
      ctx.releaseTextureView(a.view)
      ctx.releaseTexture(a.texture)
    comp.depthStencilAttachments.setLen(0)

  comp.width = width
  comp.height = height

  if width > 0'u32 and height > 0'u32:
    comp.updateViewMat(ctx, width, height)
    comp.targetTemp0.initialize(ctx, width, height, false)
    comp.targetTemp1.initialize(ctx, width, height, false)
    comp.bindGroupStorageTemp = ctx.layouts.createBindGroupStrorage2RO(comp.targetTemp0.texView, comp.targetTemp1.texView)

proc initialize*(comp: var WgCompositor; ctx: var WgContext; width, height: uint32) =
  if comp.targetTemp0 == nil: comp.targetTemp0 = WgRenderTarget()
  if comp.targetTemp1 == nil: comp.targetTemp1 = WgRenderTarget()
  comp.pipelines.initialize(ctx)
  comp.initPools(ctx)
  comp.updateViewMat(ctx, width, height)
  comp.resize(ctx, width, height)
  comp.meshDataBlit.blitBox()
  flush(comp, ctx)

proc release*(comp: var WgCompositor; ctx: var WgContext) =
  comp.resize(ctx, 0, 0)
  comp.releasePools(ctx)
  ctx.layouts.releaseBindGroup(comp.bindGroupViewMat)
  ctx.releaseBuffer(comp.bufferViewMat)
  comp.viewMatWidth = 0; comp.viewMatHeight = 0
  comp.stageBufferSolidColor.release(ctx)
  comp.stageBufferPaint.release(ctx)
  comp.stageBufferViewMat.release(ctx)
  comp.stageBufferGeometry.release(ctx)
  comp.pipelines.release(ctx)

proc beginCommands*(comp: var WgCompositor; ctx: var WgContext) =
  comp.commandEncoder = ctx.createCommandEncoder()
  comp.renderPassCount = 0

proc submitCommands*(comp: var WgCompositor; ctx: var WgContext) =
  ctx.submitCommandEncoder(comp.commandEncoder)
  ctx.releaseCommandEncoder(comp.commandEncoder)

proc endRenderPass*(comp: var WgCompositor) =
  if not isNil(comp.renderPassEncoder):
    wgpuRenderPassEncoderEnd(comp.renderPassEncoder)
    wgpuRenderPassEncoderRelease(comp.renderPassEncoder)
    comp.renderPassEncoder = WGPURenderPassEncoder(nil)

proc beginPass*(comp: var WgCompositor; ctx: var WgContext; desc: var WGPURenderPassDescriptor) =
  const maxPasses = 512'u32
  if comp.renderPassCount == maxPasses:
    comp.submitCommands(ctx)
    comp.beginCommands(ctx)
  inc comp.renderPassCount
  comp.renderPassEncoder = wgpuCommandEncoderBeginRenderPass(comp.commandEncoder, addr desc)

proc beginRenderPassMS*(comp: var WgCompositor; ctx: var WgContext; targetState: var WgRenderTargetState; clearBuffer: bool) =
  let target = targetState.target
  if (not isNil(comp.renderPassEncoder)) and (comp.currentTargetState == addr targetState) and (not clearBuffer):
    return
  comp.endRenderPass()
  comp.currentTargetState = addr targetState
  var depthStencilAttachment = WGPURenderPassDepthStencilAttachment(
    view: comp.getDepthStencilView(ctx, target.width, target.height, 4),
    depthLoadOp: WGPULoadOp_Clear,
    depthStoreOp: WGPUStoreOp_Discard,
    depthClearValue: 1.0'f32,
    stencilLoadOp: WGPULoadOp_Clear,
    stencilStoreOp: WGPUStoreOp_Discard,
    stencilClearValue: 0'u32)
  var colorAttachment = WGPURenderPassColorAttachment(
    view: target.texViewMS,
    depthSlice: WGPU_DEPTH_SLICE_UNDEFINED,
    resolveTarget: target.texView,
    loadOp: (if clearBuffer: WGPULoadOp_Clear else: WGPULoadOp_Load),
    storeOp: WGPUStoreOp_Store,
    clearValue: WGPUColor(r: 0.0, g: 0.0, b: 0.0, a: 0.0))
  var renderPassDesc = WGPURenderPassDescriptor(colorAttachmentCount: 1, colorAttachments: addr colorAttachment,
    depthStencilAttachment: addr depthStencilAttachment)
  comp.beginPass(ctx, renderPassDesc)
  # assert(renderPassEncoder)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 0'u32, comp.stageBufferGeometry.vbuffer_gpu,
    uint64(targetState.transformOffset), uint64(4 * sizeof(float32)))

proc beginRenderPass*(comp: var WgCompositor; ctx: var WgContext; target: WgRenderTarget; clearBuffer: bool) =
  # assert isNil(renderPassEncoder)
  comp.currentTargetState = nil
  var depthStencilAttachment = WGPURenderPassDepthStencilAttachment(
    view: comp.getDepthStencilView(ctx, target.width, target.height, 1),
    depthLoadOp: WGPULoadOp_Load,
    depthStoreOp: WGPUStoreOp_Discard,
    stencilLoadOp: WGPULoadOp_Load,
    stencilStoreOp: WGPUStoreOp_Discard)
  var colorAttachment = WGPURenderPassColorAttachment(
    view: target.texView,
    depthSlice: WGPU_DEPTH_SLICE_UNDEFINED,
    loadOp: (if clearBuffer: WGPULoadOp_Clear else: WGPULoadOp_Load),
    storeOp: WGPUStoreOp_Store,
    clearValue: WGPUColor(r: 0.0, g: 0.0, b: 0.0, a: 0.0))
  var renderPassDesc = WGPURenderPassDescriptor(colorAttachmentCount: 1, colorAttachments: addr colorAttachment,
    depthStencilAttachment: addr depthStencilAttachment)
  comp.beginPass(ctx, renderPassDesc)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 0'u32, comp.stageBufferGeometry.vbuffer_gpu, 0'u64, uint64(4 * sizeof(float32)))

proc setScissorRegion*(comp: var WgCompositor; region: Region) =
  if comp.currentTargetState == nil: return
  let bounds = comp.currentTargetState[].bounds
  let x0 = clampi(region.xMin, bounds.xMin, bounds.xMax) - bounds.xMin
  let y0 = clampi(region.yMin, bounds.yMin, bounds.yMax) - bounds.yMin
  let x1 = clampi(region.xMax, bounds.xMin, bounds.xMax) - bounds.xMin
  let y1 = clampi(region.yMax, bounds.yMin, bounds.yMax) - bounds.yMin
  let w = if x1 > x0: uint32(x1 - x0) else: 0'u32
  let h = if y1 > y0: uint32(y1 - y0) else: 0'u32
  wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, uint32(x0), uint32(y0), w, h)

proc copyBackdrop*(comp: var WgCompositor; ctx: var WgContext; blendMethod: BlendMethod): bool =
  case blendMethod
  of BlendMethod.Screen, BlendMethod.Exclusion, BlendMethod.Add: return false
  else: discard
  comp.endRenderPass()
  let src = comp.currentTargetState[].target
  var texSrc = WGPUTexelCopyTextureInfo(texture: src.texture)
  var texDst = WGPUTexelCopyTextureInfo(texture: comp.targetTemp0.texture)
  var copySize = WGPUExtent3D(width: src.width, height: src.height, depthOrArrayLayers: 1)
  wgpuCommandEncoderCopyTextureToTexture(comp.commandEncoder, addr texSrc, addr texDst, addr copySize)
  comp.beginRenderPassMS(ctx, comp.currentTargetState[], false)
  true

proc reset*(comp: var WgCompositor; ctx: var WgContext) =
  comp.currentTargetState = nil
  comp.stageBufferGeometry.clear()
  comp.stageBufferSolidColor.clear()
  comp.stageBufferPaint.clear()
  comp.stageBufferViewMat.clear()

proc flush*(comp: var WgCompositor; ctx: var WgContext) =
  comp.stageBufferGeometry.appendMesh(comp.meshDataBlit)
  comp.stageBufferGeometry.flush(ctx)
  comp.stageBufferSolidColor.flush(ctx)
  comp.stageBufferPaint.flush(ctx)
  comp.stageBufferViewMat.flush(ctx)
  ctx.submit()

proc requestQuad*(comp: var WgCompositor; mesh: var WgMesh; src, dst: WgRenderTargetState; mask: ptr WgRenderTargetState) =
  mesh.blitBox()
  if mask != nil:
    if mesh.tbuffer.len < 8: mesh.tbuffer.setLen(8)
  for i in 0 ..< 4:
    let uv = mesh.tbuffer[i]
    let x = float32(src.bounds.xMin) + uv.x * float32(rw(src.bounds))
    let y = float32(src.bounds.yMin) + uv.y * float32(rh(src.bounds))
    mesh.vbuffer[i] = Point(
      x: (x - float32(dst.bounds.xMin)) * 2.0'f32 / float32(dst.target.width) - 1.0'f32,
      y: 1.0'f32 - (y - float32(dst.bounds.yMin)) * 2.0'f32 / float32(dst.target.height))
    mesh.tbuffer[i] = Point(x: uv.x * float32(rw(src.bounds)) / float32(src.target.width),
                            y: uv.y * float32(rh(src.bounds)) / float32(src.target.height))
    if mask != nil:
      mesh.tbuffer[i + 4] = Point(x: (x - float32(mask[].bounds.xMin)) / float32(mask[].target.width),
                                  y: (y - float32(mask[].bounds.yMin)) / float32(mask[].target.height))
  comp.stageBufferGeometry.appendMesh(mesh)

proc requestScene*(comp: var WgCompositor; targetState: var WgRenderTargetState; mesh, effectMesh: var WgMesh;
                   dst: ptr WgRenderTargetState; mask: ptr WgRenderTargetState; effects: bool) =
  let adjust = [float32(comp.width) / float32(targetState.target.width),
                float32(comp.height) / float32(targetState.target.height),
                (float32(comp.width) - 2.0'f32 * float32(targetState.bounds.xMin)) / float32(targetState.target.width) - 1.0'f32,
                1.0'f32 - (float32(comp.height) - 2.0'f32 * float32(targetState.bounds.yMin)) / float32(targetState.target.height)]
  targetState.transformOffset = comp.stageBufferGeometry.vbuffer.count
  comp.stageBufferGeometry.vbuffer.appendBytes(unsafeAddr adjust[0], sizeof(adjust))
  if dst != nil:
    comp.requestQuad(mesh, targetState, dst[], mask)
  if effects:
    var scratch = WgRenderTargetState(target: comp.targetTemp0, bounds: Region(xMin: 0, yMin: 0, xMax: int32(comp.width), yMax: int32(comp.height)))
    comp.requestQuad(effectMesh, scratch, targetState, nil)

proc copyEffectTexture*(comp: var WgCompositor; ctx: var WgContext; dst: WgRenderTarget; src: WgRenderTargetState; clear: bool = false) =
  if clear:
    comp.beginRenderPass(ctx, dst, true)
    comp.endRenderPass()
  var texSrc = WGPUTexelCopyTextureInfo(texture: src.target.texture)
  var texDst = WGPUTexelCopyTextureInfo(texture: dst.texture, origin: WGPUOrigin3D(x: uint32(max(src.bounds.xMin, 0'i32)), y: uint32(max(src.bounds.yMin, 0'i32)), z: 0))
  var size = WGPUExtent3D(width: rw(src.bounds), height: rh(src.bounds), depthOrArrayLayers: 1)
  wgpuCommandEncoderCopyTextureToTexture(comp.commandEncoder, addr texSrc, addr texDst, addr size)

proc requestShape*(comp: var WgCompositor; shape: WgShape) =
  comp.stageBufferGeometry.appendShape(shape)
  let ss = shape.shape.setting
  if ss.fillType == rstSolid:
    shape.shape.solid.colorIdx = comp.stageBufferSolidColor.append(shape.shape.solid.packedColor())
  else:
    shape.shape.setting.bindGroupIdx = comp.stageBufferPaint.append(ss.settings)

  if shape.stroke.mesh.vbuffer.len > 0:
    var viewMatrix = identity()
    viewMatrix.e11 = 2.0'f32 / float32(comp.width)
    viewMatrix.e22 = -2.0'f32 / float32(comp.height)
    viewMatrix.e13 = -1.0'f32
    viewMatrix.e23 = 1.0'f32
    var strokeViewMat = WgShaderTypeMat4x4fBlock()
    strokeViewMat.matrix.update(viewMatrix * shape.transform)
    strokeViewMat.matrix.mat[14] = 128.0'f32 / 255.0'f32
    shape.strokeViewMatIdx = comp.stageBufferViewMat.append(strokeViewMat)

  if shape.stroke.setting.valid and shape.stroke.mesh.vbuffer.len > 0:
    let sts = shape.stroke.setting
    if sts.fillType == rstSolid:
      shape.stroke.solid.colorIdx = comp.stageBufferSolidColor.append(shape.stroke.solid.packedColor())
    else:
      shape.stroke.setting.bindGroupIdx = comp.stageBufferPaint.append(sts.settings)

  for p in shape.clips:
    if p of WgShape:
      comp.requestShape(WgShape(p))

proc requestImage*(comp: var WgCompositor; image: WgImage) =
  comp.stageBufferGeometry.appendImage(image)
  image.setting.bindGroupIdx = comp.stageBufferPaint.append(image.setting.settings)
  for p in image.clips:
    if p of WgShape:
      comp.requestShape(WgShape(p))

proc requestSolidBatch*(comp: var WgCompositor; renderShapes: openArray[WgShape]; range: var WgSolidBatchRange) =
  comp.stageBufferGeometry.appendSolidBatch(renderShapes, comp.stageBufferSolidColor, range)
  if renderShapes.len > 0:
    range.viewport = renderShapes[0].viewport

proc requestImageBatch*(comp: var WgCompositor; renderImages: openArray[WgImage]; range: var WgImageBatchRange) =
  comp.stageBufferGeometry.appendImageBatch(renderImages, range)
  if renderImages.len > 0:
    let image = renderImages[0]
    image.setting.bindGroupIdx = comp.stageBufferPaint.append(image.setting.settings)
    range.viewport = image.viewport

proc requestStencilBatch*(comp: var WgCompositor; renderShapes: openArray[WgShape]; range: var WgStencilBatchRange) =
  comp.stageBufferGeometry.appendStencilBatch(renderShapes, range)
  if renderShapes.len == 0: return
  range.viewport = renderShapes[0].viewport
  range.fillRule = renderShapes[0].fillRule
  range.solidOnly = true

  var pendingColorCount = 0'u32
  var colorsStarted = false
  for rdata in renderShapes:
    let settings = rdata.shape.setting
    let count = uint32(rdata.bboxMesh.vbuffer.len)
    if settings.fillType == rstSolid:
      if not colorsStarted:
        range.colorOffset = comp.stageBufferSolidColor.vbuffer.len * sizeof(RenderColor)
        if pendingColorCount > 0'u32:
          comp.stageBufferSolidColor.appendRepeated(RenderColor(), pendingColorCount)
        colorsStarted = true
      comp.stageBufferSolidColor.appendRepeated(rdata.shape.solid.packedColor(), count)
    else:
      range.solidOnly = false
      rdata.shape.setting.bindGroupIdx = comp.stageBufferPaint.append(settings.settings)
      if colorsStarted:
        comp.stageBufferSolidColor.appendRepeated(RenderColor(), count)
      else:
        pendingColorCount += count

# ---- draw helpers (forward-declared via procs below) --------------------

proc drawMesh*(comp: var WgCompositor; ctx: var WgContext; mesh: var WgMesh) =
  let icount = uint32(mesh.ibuffer.len)
  if icount == 0'u32: return
  let vsize = uint64(mesh.vbuffer.len * sizeof(Point))
  let isize = uint64(icount) * uint64(sizeof(uint32))
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 1'u32, comp.stageBufferGeometry.vbuffer_gpu, uint64(mesh.voffset), vsize)
  wgpuRenderPassEncoderSetIndexBuffer(comp.renderPassEncoder, comp.stageBufferGeometry.ibuffer_gpu, WGPUIndexFormat_Uint32, uint64(mesh.ioffset), isize)
  wgpuRenderPassEncoderDrawIndexed(comp.renderPassEncoder, icount, 1, 0, 0, 0)

proc drawMeshSolid*(comp: var WgCompositor; ctx: var WgContext; mesh: var WgMesh; solidColorInd: uint32) =
  let icount = uint32(mesh.ibuffer.len)
  if icount == 0'u32: return
  let vsize = uint64(mesh.vbuffer.len * sizeof(Point))
  let isize = uint64(icount) * uint64(sizeof(uint32))
  let csize = uint64(sizeof(RenderColor))
  let coffset = uint64(solidColorInd) * csize
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 1'u32, comp.stageBufferGeometry.vbuffer_gpu, uint64(mesh.voffset), vsize)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 2'u32, comp.stageBufferSolidColor.vbuffer_gpu, coffset, csize)
  wgpuRenderPassEncoderSetIndexBuffer(comp.renderPassEncoder, comp.stageBufferGeometry.ibuffer_gpu, WGPUIndexFormat_Uint32, uint64(mesh.ioffset), isize)
  wgpuRenderPassEncoderDrawIndexed(comp.renderPassEncoder, icount, 1, 0, 0, 0)

proc drawMeshImage*(comp: var WgCompositor; ctx: var WgContext; mesh: var WgMesh) =
  let icount = uint32(mesh.ibuffer.len)
  if icount == 0'u32: return
  let vsize = uint64(mesh.vbuffer.len * sizeof(Point))
  let isize = uint64(icount) * uint64(sizeof(uint32))
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 1'u32, comp.stageBufferGeometry.vbuffer_gpu, uint64(mesh.voffset), vsize)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 2'u32, comp.stageBufferGeometry.vbuffer_gpu, uint64(mesh.toffset), vsize)
  wgpuRenderPassEncoderSetIndexBuffer(comp.renderPassEncoder, comp.stageBufferGeometry.ibuffer_gpu, WGPUIndexFormat_Uint32, uint64(mesh.ioffset), isize)
  wgpuRenderPassEncoderDrawIndexed(comp.renderPassEncoder, icount, 1, 0, 0, 0)

# forward declarations for mutual calls
proc renderClipPath*(comp: var WgCompositor; ctx: var WgContext; paint: WgPaint)
proc clearClipPath*(comp: var WgCompositor; ctx: var WgContext; paint: WgPaint)
proc drawShape*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape)
proc blendShape*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape; blendMethod: BlendMethod)
proc clipShape*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape; blendMethod: BlendMethod)
proc drawStrokes*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape)
proc blendStrokes*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape; blendMethod: BlendMethod)
proc drawImage*(comp: var WgCompositor; ctx: var WgContext; rdata: WgImage)
proc blendImage*(comp: var WgCompositor; ctx: var WgContext; rdata: WgImage; blendMethod: BlendMethod)
proc clipImage*(comp: var WgCompositor; ctx: var WgContext; rdata: WgImage; blendMethod: BlendMethod)
proc drawScene*(comp: var WgCompositor; ctx: var WgContext; scene: WgRenderTarget; compose: WgCompose; mesh: var WgMesh)
proc blendScene*(comp: var WgCompositor; ctx: var WgContext; scene: WgRenderTarget; compose: WgCompose; mesh: var WgMesh)

proc drawShape*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape) =
  if (not rdata.shape.setting.valid) or rdata.shape.mesh.vbuffer.len == 0 or invalid(rdata.viewport): return
  let settings = rdata.shape.setting
  let convex = rdata.convex
  comp.setScissorRegion(rdata.viewport)
  if not convex:
    let stencilPipeline = if rdata.fillRule == FillRule.NonZero: comp.pipelines.nonzero else: comp.pipelines.evenodd
    wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, stencilPipeline)
    comp.drawMesh(ctx, rdata.shape.mesh)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  if settings.fillType == rstSolid:
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, if convex: comp.pipelines.solidConv else: comp.pipelines.solid)
    var meshRef = if convex: addr rdata.shape.mesh else: addr rdata.bboxMesh
    comp.drawMeshSolid(ctx, meshRef[], rdata.shape.solid.colorIdx)
  else:
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.stageBufferPaint[settings.bindGroupIdx], 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, settings.gradientDataTex.bindGroup, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, gradientPipeline(comp.pipelines, settings.fillType, convex))
    var meshRef = if convex: addr rdata.shape.mesh else: addr rdata.bboxMesh
    comp.drawMesh(ctx, meshRef[])

proc blendShape*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape; blendMethod: BlendMethod) =
  if (not rdata.shape.setting.valid) or rdata.shape.mesh.vbuffer.len == 0 or invalid(rdata.viewport): return
  let settings = rdata.shape.setting
  let copied = comp.copyBackdrop(ctx, blendMethod)
  comp.setScissorRegion(rdata.viewport)
  let stencilPipeline = if rdata.fillRule == FillRule.NonZero: comp.pipelines.nonzero else: comp.pipelines.evenodd
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, stencilPipeline)
  comp.drawMesh(ctx, rdata.shape.mesh)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  if settings.fillType == rstSolid:
    if copied: wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.targetTemp0.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.solidBlend(ctx, blendMethod))
    comp.drawMeshSolid(ctx, rdata.bboxMesh, rdata.shape.solid.colorIdx)
  else:
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.stageBufferPaint[settings.bindGroupIdx], 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, settings.gradientDataTex.bindGroup, 0, nil)
    if copied: wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 3'u32, comp.targetTemp0.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, gradientBlendPipeline(comp.pipelines, ctx, settings.fillType, blendMethod))
    comp.drawMesh(ctx, rdata.bboxMesh)

proc clipShape*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape; blendMethod: BlendMethod) =
  if (not rdata.shape.setting.valid) or rdata.shape.mesh.vbuffer.len == 0 or invalid(rdata.viewport): return
  let settings = rdata.shape.setting
  comp.setScissorRegion(rdata.viewport)
  let stencilPipeline = if rdata.fillRule == FillRule.NonZero: comp.pipelines.nonzero else: comp.pipelines.evenodd
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, stencilPipeline)
  comp.drawMesh(ctx, rdata.shape.mesh)
  # merge depth and stencil
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[128], 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.mergeDepthStencil)
  comp.drawMesh(ctx, rdata.bboxMesh)
  # fill
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  if settings.fillType == rstSolid:
    let pipe = if blendMethod == BlendMethod.Normal: comp.pipelines.solid else: comp.pipelines.solidBlend(ctx, blendMethod)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, pipe)
    comp.drawMeshSolid(ctx, rdata.bboxMesh, rdata.shape.solid.colorIdx)
  else:
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.stageBufferPaint[settings.bindGroupIdx], 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, settings.gradientDataTex.bindGroup, 0, nil)
    let pipe = if blendMethod == BlendMethod.Normal: gradientPipeline(comp.pipelines, settings.fillType, false)
               else: gradientBlendPipeline(comp.pipelines, ctx, settings.fillType, blendMethod)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, pipe)
    comp.drawMesh(ctx, rdata.bboxMesh)

proc stencilStrokes(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape) =
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 255'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.stageBufferViewMat[rdata.strokeViewMatIdx], 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.direct)
  comp.drawMesh(ctx, rdata.stroke.mesh)
  if rdata.clips.len > 0:
    wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[128], 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.mergeDepthStencil)
    comp.drawMesh(ctx, rdata.bboxMesh)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)

proc drawStrokes*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape) =
  if (not rdata.stroke.setting.valid) or rdata.stroke.mesh.vbuffer.len == 0 or invalid(rdata.viewport): return
  let settings = rdata.stroke.setting
  let solid = settings.fillType == rstSolid
  let direct = rdata.strokeOverlapFree or (rdata.stroke.solid.opacity == 255'u8 and
    (if solid: rdata.stroke.solid.color.a == 255'u8 else: settings.opaque))
  let clipped = rdata.clips.len > 0
  let strokeView = comp.stageBufferViewMat[rdata.strokeViewMatIdx]
  comp.setScissorRegion(rdata.viewport)
  var meshPtr = addr rdata.stroke.mesh
  var pipeline: WGPURenderPipeline
  if direct:
    pipeline = if clipped: comp.pipelines.clippedStroke(ctx, settings.fillType)
               elif solid: comp.pipelines.solidConv
               else: gradientPipeline(comp.pipelines, settings.fillType, true)
  else:
    comp.stencilStrokes(ctx, rdata)
    meshPtr = addr rdata.stroke.bboxMesh
    pipeline = if solid: comp.pipelines.solid else: gradientPipeline(comp.pipelines, settings.fillType, false)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, strokeView, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, pipeline)
  if solid:
    comp.drawMeshSolid(ctx, meshPtr[], rdata.stroke.solid.colorIdx)
  else:
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.stageBufferPaint[settings.bindGroupIdx], 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, settings.gradientDataTex.bindGroup, 0, nil)
    comp.drawMesh(ctx, meshPtr[])

proc blendStrokes*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape; blendMethod: BlendMethod) =
  if (not rdata.stroke.setting.valid) or rdata.stroke.mesh.vbuffer.len == 0 or invalid(rdata.viewport): return
  let settings = rdata.stroke.setting
  let strokeView = comp.stageBufferViewMat[rdata.strokeViewMatIdx]
  let copied = comp.copyBackdrop(ctx, blendMethod)
  comp.setScissorRegion(rdata.viewport)
  comp.stencilStrokes(ctx, rdata)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, strokeView, 0, nil)
  if settings.fillType == rstSolid:
    if copied: wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.targetTemp0.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.solidBlend(ctx, blendMethod))
    comp.drawMeshSolid(ctx, rdata.stroke.bboxMesh, rdata.stroke.solid.colorIdx)
  else:
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.stageBufferPaint[settings.bindGroupIdx], 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, settings.gradientDataTex.bindGroup, 0, nil)
    if copied: wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 3'u32, comp.targetTemp0.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, gradientBlendPipeline(comp.pipelines, ctx, settings.fillType, blendMethod))
    comp.drawMesh(ctx, rdata.stroke.bboxMesh)

proc drawImage*(comp: var WgCompositor; ctx: var WgContext; rdata: WgImage) =
  if invalid(rdata.viewport) or isNil(rdata.bindGroup): return
  let settings = rdata.setting
  comp.setScissorRegion(rdata.viewport)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.stageBufferPaint[settings.bindGroupIdx], 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, rdata.bindGroup, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.imageDirect)
  comp.drawMeshImage(ctx, rdata.mesh)

proc blendImage*(comp: var WgCompositor; ctx: var WgContext; rdata: WgImage; blendMethod: BlendMethod) =
  if invalid(rdata.viewport) or isNil(rdata.bindGroup): return
  let settings = rdata.setting
  let copied = comp.copyBackdrop(ctx, blendMethod)
  comp.setScissorRegion(rdata.viewport)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 255'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.direct)
  comp.drawMeshImage(ctx, rdata.mesh)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.stageBufferPaint[settings.bindGroupIdx], 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, rdata.bindGroup, 0, nil)
  if copied: wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 3'u32, comp.targetTemp0.bgTexture, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.imageBlend(ctx, blendMethod))
  comp.drawMeshImage(ctx, rdata.mesh)

proc clipImage*(comp: var WgCompositor; ctx: var WgContext; rdata: WgImage; blendMethod: BlendMethod) =
  if invalid(rdata.viewport) or isNil(rdata.bindGroup): return
  let settings = rdata.setting
  comp.setScissorRegion(rdata.viewport)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 255'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.direct)
  comp.drawMeshImage(ctx, rdata.mesh)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[128], 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.mergeDepthStencil)
  comp.drawMeshImage(ctx, rdata.mesh)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.stageBufferPaint[settings.bindGroupIdx], 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, rdata.bindGroup, 0, nil)
  let pipe = if blendMethod == BlendMethod.Normal: comp.pipelines.image else: comp.pipelines.imageBlend(ctx, blendMethod)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, pipe)
  comp.drawMeshImage(ctx, rdata.mesh)

proc drawScene*(comp: var WgCompositor; ctx: var WgContext; scene: WgRenderTarget; compose: WgCompose; mesh: var WgMesh) =
  comp.setScissorRegion(compose.aabb)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, scene.bgTexture, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[int(compose.opacity)], 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.scene)
  comp.drawMeshImage(ctx, mesh)

proc blendScene*(comp: var WgCompositor; ctx: var WgContext; scene: WgRenderTarget; compose: WgCompose; mesh: var WgMesh) =
  let copied = comp.copyBackdrop(ctx, compose.blend)
  comp.setScissorRegion(compose.aabb)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, scene.bgTexture, 0, nil)
  if copied:
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.targetTemp0.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, comp.bindGroupOpacities[int(compose.opacity)], 0, nil)
  else:
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[int(compose.opacity)], 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.sceneBlend(ctx, compose.blend))
  comp.drawMeshImage(ctx, mesh)

proc renderShape*(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape; blendMethod: BlendMethod) =
  let clipped = rdata.clips.len > 0
  var blend = blendMethod
  if clipped:
    comp.renderClipPath(ctx, rdata)
    if blend != BlendMethod.Screen and blend != BlendMethod.Exclusion and blend != BlendMethod.Add:
      blend = BlendMethod.Normal
  if rdata.strokeFirst:
    if blend == BlendMethod.Normal: comp.drawStrokes(ctx, rdata) else: comp.blendStrokes(ctx, rdata, blend)
  if clipped:
    comp.clipShape(ctx, rdata, blend)
  elif blend == BlendMethod.Normal:
    comp.drawShape(ctx, rdata)
  else:
    comp.blendShape(ctx, rdata, blend)
  if not rdata.strokeFirst:
    if blend == BlendMethod.Normal: comp.drawStrokes(ctx, rdata) else: comp.blendStrokes(ctx, rdata, blend)
  if clipped:
    comp.clearClipPath(ctx, rdata)

proc renderSolidBatch*(comp: var WgCompositor; range: WgSolidBatchRange) =
  let vertexSize = uint64(range.geom.vertexCount) * uint64(sizeof(Point))
  let colorSize = uint64(range.geom.vertexCount) * uint64(sizeof(RenderColor))
  let indexSize = uint64(range.geom.indexCount) * uint64(sizeof(uint32))
  comp.setScissorRegion(range.viewport)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.solidBatch)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 1'u32, comp.stageBufferGeometry.vbuffer_gpu, uint64(range.geom.vertexOffset), vertexSize)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 2'u32, comp.stageBufferSolidColor.vbuffer_gpu, uint64(range.colorOffset), colorSize)
  wgpuRenderPassEncoderSetIndexBuffer(comp.renderPassEncoder, comp.stageBufferGeometry.ibuffer_gpu, WGPUIndexFormat_Uint32, uint64(range.geom.indexOffset), indexSize)
  wgpuRenderPassEncoderDrawIndexed(comp.renderPassEncoder, range.geom.indexCount, 1, 0, 0, 0)

proc renderImageBatch*(comp: var WgCompositor; image: WgImage; range: WgImageBatchRange) =
  let vertexSize = uint64(range.geom.vertexCount) * uint64(sizeof(Point))
  let indexSize = uint64(range.geom.indexCount) * uint64(sizeof(uint32))
  comp.setScissorRegion(range.viewport)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.stageBufferPaint[image.setting.bindGroupIdx], 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, image.bindGroup, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.imageDirect)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 1'u32, comp.stageBufferGeometry.vbuffer_gpu, uint64(range.geom.vertexOffset), vertexSize)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 2'u32, comp.stageBufferGeometry.vbuffer_gpu, uint64(range.texCoordOffset), vertexSize)
  wgpuRenderPassEncoderSetIndexBuffer(comp.renderPassEncoder, comp.stageBufferGeometry.ibuffer_gpu, WGPUIndexFormat_Uint32, uint64(range.geom.indexOffset), indexSize)
  wgpuRenderPassEncoderDrawIndexed(comp.renderPassEncoder, range.geom.indexCount, 1, 0, 0, 0)

proc renderStencilBatch*(comp: var WgCompositor; renderShapes: openArray[WgShape]; range: WgStencilBatchRange) =
  let stencilVertexSize = uint64(range.stencil.vertexCount) * uint64(sizeof(Point))
  let stencilIndexSize = uint64(range.stencil.indexCount) * uint64(sizeof(uint32))
  let coverVertexSize = uint64(range.cover.vertexCount) * uint64(sizeof(Point))
  let coverIndexSize = uint64(range.cover.indexCount) * uint64(sizeof(uint32))
  comp.setScissorRegion(range.viewport)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, if range.fillRule == FillRule.NonZero: comp.pipelines.nonzero else: comp.pipelines.evenodd)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 1'u32, comp.stageBufferGeometry.vbuffer_gpu, uint64(range.stencil.vertexOffset), stencilVertexSize)
  wgpuRenderPassEncoderSetIndexBuffer(comp.renderPassEncoder, comp.stageBufferGeometry.ibuffer_gpu, WGPUIndexFormat_Uint32, uint64(range.stencil.indexOffset), stencilIndexSize)
  wgpuRenderPassEncoderDrawIndexed(comp.renderPassEncoder, range.stencil.indexCount, 1, 0, 0, 0)

  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 1'u32, comp.stageBufferGeometry.vbuffer_gpu, uint64(range.cover.vertexOffset), coverVertexSize)
  wgpuRenderPassEncoderSetIndexBuffer(comp.renderPassEncoder, comp.stageBufferGeometry.ibuffer_gpu, WGPUIndexFormat_Uint32, uint64(range.cover.indexOffset), coverIndexSize)

  if range.solidOnly:
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.solidStencilBatch)
    wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 2'u32, comp.stageBufferSolidColor.vbuffer_gpu, uint64(range.colorOffset), uint64(range.cover.vertexCount) * uint64(sizeof(RenderColor)))
    wgpuRenderPassEncoderDrawIndexed(comp.renderPassEncoder, range.cover.indexCount, 1, 0, 0, 0)
    return

  var firstIndex = 0'u32
  var colorsBound = false
  var i = 0
  while i < renderShapes.len:
    var rdata = renderShapes[i]
    let settings = rdata.shape.setting
    let batchFirstIndex = firstIndex
    while true:
      let indexCount = uint32(rdata.bboxMesh.ibuffer.len)
      firstIndex += indexCount
      inc i
      if i >= renderShapes.len or settings.fillType != rstSolid:
        break
      rdata = renderShapes[i]
      if rdata.shape.setting.fillType != rstSolid:
        break
    if settings.fillType == rstSolid:
      if not colorsBound:
        wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 2'u32, comp.stageBufferSolidColor.vbuffer_gpu, uint64(range.colorOffset), uint64(range.cover.vertexCount) * uint64(sizeof(RenderColor)))
        colorsBound = true
      wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.solidStencilBatch)
    else:
      wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.stageBufferPaint[settings.bindGroupIdx], 0, nil)
      wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, settings.gradientDataTex.bindGroup, 0, nil)
      wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, gradientPipeline(comp.pipelines, settings.fillType, false))
    wgpuRenderPassEncoderDrawIndexed(comp.renderPassEncoder, firstIndex - batchFirstIndex, 1, batchFirstIndex, 0, 0)

proc renderImage*(comp: var WgCompositor; ctx: var WgContext; rdata: WgImage; blendMethod: BlendMethod) =
  var blend = blendMethod
  if rdata.clips.len > 0:
    comp.renderClipPath(ctx, rdata)
    if blend != BlendMethod.Screen and blend != BlendMethod.Exclusion and blend != BlendMethod.Add:
      blend = BlendMethod.Normal
    comp.clipImage(ctx, rdata, blend)
    comp.clearClipPath(ctx, rdata)
  elif blend != BlendMethod.Normal:
    comp.blendImage(ctx, rdata, blend)
  else:
    comp.drawImage(ctx, rdata)

proc renderScene*(comp: var WgCompositor; ctx: var WgContext; scene: WgRenderTarget; compose: WgCompose; mesh: var WgMesh) =
  if compose.blend != BlendMethod.Normal:
    comp.blendScene(ctx, scene, compose, mesh)
  else:
    comp.drawScene(ctx, scene, compose, mesh)

proc composeScene*(comp: var WgCompositor; ctx: var WgContext; src, mask: WgRenderTarget; cmp: WgCompose; mesh: var WgMesh) =
  comp.setScissorRegion(cmp.aabb)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, src.bgTexture, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, mask.bgTexture, 0, nil)
  let idx = int(cmp.meth)
  if idx >= 0 and idx < comp.pipelines.sceneCompose.len:
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.sceneCompose[idx])
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 3'u32, comp.stageBufferGeometry.vbuffer_gpu, uint64(mesh.toffset) + uint64(4 * sizeof(Point)), uint64(4 * sizeof(Point)))
  comp.drawMeshImage(ctx, mesh)

proc markupClipPath(comp: var WgCompositor; ctx: var WgContext; rdata: WgShape) =
  comp.setScissorRegion(rdata.viewport)
  if rdata.stroke.mesh.vbuffer.len > 0:
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.stageBufferViewMat[rdata.strokeViewMatIdx], 0, nil)
    wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 255'u32)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.direct)
    comp.drawMesh(ctx, rdata.stroke.mesh)
  elif rdata.shape.mesh.vbuffer.len > 0:
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
    let stencilPipeline = if rdata.fillRule == FillRule.NonZero: comp.pipelines.nonzero else: comp.pipelines.evenodd
    wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, stencilPipeline)
    comp.drawMesh(ctx, rdata.shape.mesh)

proc renderClipPath*(comp: var WgCompositor; ctx: var WgContext; paint: WgPaint) =
  if paint.clips.len == 0: return
  let rdata0 = WgShape(paint.clips[0])
  comp.markupClipPath(ctx, rdata0)
  wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[128], 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.copyStencilToDepth)
  comp.drawMesh(ctx, rdata0.bboxMesh)
  for i in 1 ..< paint.clips.len:
    let rdata = WgShape(paint.clips[i])
    comp.markupClipPath(ctx, rdata)
    wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[190], 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.copyStencilToDepthInterm)
    comp.drawMesh(ctx, rdata.bboxMesh)
    wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 1'u32)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[190], 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.copyDepthToStencil)
    comp.drawMesh(ctx, rdata.bboxMesh)
    wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[255], 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.clearDepth)
    comp.drawMesh(ctx, rdata.bboxMesh)
    wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[255], 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.clearDepth)
    comp.drawMesh(ctx, rdata0.bboxMesh)
    wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[128], 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.copyStencilToDepth)
    comp.drawMesh(ctx, rdata.bboxMesh)

proc clearClipPath*(comp: var WgCompositor; ctx: var WgContext; paint: WgPaint) =
  if comp.currentTargetState == nil: return
  let bounds = comp.currentTargetState[].bounds
  wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, 0'u32, 0'u32, rw(bounds), rh(bounds))
  for p in paint.clips:
    let rdata = WgShape(p)
    wgpuRenderPassEncoderSetStencilReference(comp.renderPassEncoder, 0'u32)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.bindGroupViewMat, 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.bindGroupOpacities[255], 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.clearDepth)
    comp.drawMesh(ctx, rdata.bboxMesh)

proc blit*(comp: var WgCompositor; ctx: var WgContext; encoder: WGPUCommandEncoder; src: WgRenderTarget; dstView: WGPUTextureView; premultiplied, clearBuffer: bool) =
  var depthStencilAttachment = WGPURenderPassDepthStencilAttachment(
    view: comp.getDepthStencilView(ctx, src.width, src.height, 1),
    depthLoadOp: WGPULoadOp_Load, depthStoreOp: WGPUStoreOp_Discard,
    stencilLoadOp: WGPULoadOp_Load, stencilStoreOp: WGPUStoreOp_Discard)
  var colorAttachment = WGPURenderPassColorAttachment(
    view: dstView, depthSlice: WGPU_DEPTH_SLICE_UNDEFINED,
    loadOp: (if clearBuffer: WGPULoadOp_Clear else: WGPULoadOp_Load),
    storeOp: WGPUStoreOp_Store, clearValue: WGPUColor(r: 0.0, g: 0.0, b: 0.0, a: 0.0))
  var renderPassDesc = WGPURenderPassDescriptor(colorAttachmentCount: 1, colorAttachments: addr colorAttachment,
    depthStencilAttachment: addr depthStencilAttachment)
  comp.renderPassEncoder = wgpuCommandEncoderBeginRenderPass(encoder, addr renderPassDesc)
  wgpuRenderPassEncoderSetVertexBuffer(comp.renderPassEncoder, 0'u32, comp.stageBufferGeometry.vbuffer_gpu, 0'u64, uint64(4 * sizeof(float32)))
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, src.bgTexture, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, if premultiplied: comp.pipelines.blit else: comp.pipelines.blitUnpremultiplied)
  comp.drawMeshImage(ctx, comp.meshDataBlit)
  wgpuRenderPassEncoderEnd(comp.renderPassEncoder)
  wgpuRenderPassEncoderRelease(comp.renderPassEncoder)
  comp.renderPassEncoder = WGPURenderPassEncoder(nil)

# ---- effects ------------------------------------------------------------

proc effectData(effect: RenderEffect): WgRenderEffect =
  if effect == nil or effect.rd == nil: return nil
  if effect.rd of WgRenderEffect: WgRenderEffect(effect.rd) else: nil

proc motionBlur*(comp: var WgCompositor; ctx: var WgContext; targetState: WgRenderTargetState; motion: MotionBlurEffect; mesh: var WgMesh): bool =
  let eff = effectData(motion)
  if eff == nil: return false
  let aabb = targetState.bounds
  let dst = targetState.target
  var region = [float32(rx(aabb)), float32(ry(aabb)), float32(rw(aabb)), float32(rh(aabb))]
  wgpuQueueWriteBuffer(ctx.queue, eff.bufferParams, uint64(4 * sizeof(float32)), addr region[0], csize_t(sizeof(region)))
  comp.copyEffectTexture(ctx, comp.targetTemp0, targetState)
  comp.beginRenderPass(ctx, dst, false)
  wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, 0'u32, 0'u32, rw(aabb), rh(aabb))
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp0.getBindGroupTextureLinear(ctx), 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, eff.bindGroupParams, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectMotionBlur)
  comp.drawMeshImage(ctx, mesh)
  comp.endRenderPass()
  true

proc gaussianBlur*(comp: var WgCompositor; ctx: var WgContext; targetState: WgRenderTargetState; blur: GaussianBlurEffect; mesh: var WgMesh): bool =
  let eff = effectData(blur)
  if eff == nil: return false
  let aabb = targetState.bounds
  let dst = targetState.target
  comp.copyEffectTexture(ctx, comp.targetTemp0, targetState, true)
  if blur.direction == 0'u8: # both
    comp.beginRenderPass(ctx, comp.targetTemp1, true)
    wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, uint32(max(rx(aabb), 0)), uint32(max(ry(aabb), 0)), rw(aabb), rh(aabb))
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp0.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, eff.bindGroupParams, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectGaussianHorz)
    comp.drawMeshImage(ctx, comp.meshDataBlit)
    comp.endRenderPass()
    comp.beginRenderPass(ctx, dst, false)
    wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, 0'u32, 0'u32, rw(aabb), rh(aabb))
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp1.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, eff.bindGroupParams, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectGaussianVert)
    comp.drawMeshImage(ctx, mesh)
    comp.endRenderPass()
  elif blur.direction == 1'u8: # horizontal
    comp.beginRenderPass(ctx, dst, false)
    wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, 0'u32, 0'u32, rw(aabb), rh(aabb))
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp0.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, eff.bindGroupParams, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectGaussianHorz)
    comp.drawMeshImage(ctx, mesh)
    comp.endRenderPass()
  elif blur.direction == 2'u8: # vertical
    comp.beginRenderPass(ctx, dst, false)
    wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, 0'u32, 0'u32, rw(aabb), rh(aabb))
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp0.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, eff.bindGroupParams, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectGaussianVert)
    comp.drawMeshImage(ctx, mesh)
    comp.endRenderPass()
  true

proc dropShadow*(comp: var WgCompositor; ctx: var WgContext; targetState: WgRenderTargetState; shadow: DropShadowEffect; mesh: var WgMesh): bool =
  let eff = effectData(shadow)
  if eff == nil: return false
  let aabb = targetState.bounds
  let dst = targetState.target
  comp.copyEffectTexture(ctx, comp.targetTemp1, targetState, true)
  if not zero(shadow.sigma):
    comp.beginRenderPass(ctx, comp.targetTemp0, true)
    wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, uint32(max(rx(aabb), 0)), uint32(max(ry(aabb), 0)), rw(aabb), rh(aabb))
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp1.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, eff.bindGroupParams, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectGaussianHorz)
    comp.drawMeshImage(ctx, comp.meshDataBlit)
    comp.endRenderPass()
    comp.beginRenderPass(ctx, comp.targetTemp1, false)
    wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, uint32(max(rx(aabb), 0)), uint32(max(ry(aabb), 0)), rw(aabb), rh(aabb))
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp0.bgTexture, 0, nil)
    wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, eff.bindGroupParams, 0, nil)
    wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectGaussianVert)
    comp.drawMeshImage(ctx, comp.meshDataBlit)
    comp.endRenderPass()
  comp.copyEffectTexture(ctx, comp.targetTemp0, targetState)
  comp.beginRenderPass(ctx, dst, false)
  wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, 0'u32, 0'u32, rw(aabb), rh(aabb))
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp0.bgTexture, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, comp.targetTemp1.bgTexture, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 2'u32, eff.bindGroupParams, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectDropShadow)
  comp.drawMeshImage(ctx, mesh)
  comp.endRenderPass()
  true

proc fillEffect*(comp: var WgCompositor; ctx: var WgContext; targetState: WgRenderTargetState; fill: FillEffect; mesh: var WgMesh): bool =
  let eff = effectData(fill)
  if eff == nil: return false
  let aabb = targetState.bounds
  comp.copyEffectTexture(ctx, comp.targetTemp0, targetState)
  comp.beginRenderPass(ctx, targetState.target, false)
  wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, 0'u32, 0'u32, rw(aabb), rh(aabb))
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp0.bgTexture, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, eff.bindGroupParams, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectFill)
  comp.drawMeshImage(ctx, mesh)
  comp.endRenderPass()
  true

proc tintEffect*(comp: var WgCompositor; ctx: var WgContext; targetState: WgRenderTargetState; tint: TintEffect; mesh: var WgMesh): bool =
  let eff = effectData(tint)
  if eff == nil: return false
  let aabb = targetState.bounds
  comp.copyEffectTexture(ctx, comp.targetTemp0, targetState)
  comp.beginRenderPass(ctx, targetState.target, false)
  wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, 0'u32, 0'u32, rw(aabb), rh(aabb))
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp0.bgTexture, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, eff.bindGroupParams, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectTint)
  comp.drawMeshImage(ctx, mesh)
  comp.endRenderPass()
  true

proc tritoneEffect*(comp: var WgCompositor; ctx: var WgContext; targetState: WgRenderTargetState; tritone: TritoneEffect; mesh: var WgMesh): bool =
  let eff = effectData(tritone)
  if eff == nil: return false
  let aabb = targetState.bounds
  comp.copyEffectTexture(ctx, comp.targetTemp0, targetState)
  comp.beginRenderPass(ctx, targetState.target, false)
  wgpuRenderPassEncoderSetScissorRect(comp.renderPassEncoder, 0'u32, 0'u32, rw(aabb), rh(aabb))
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 0'u32, comp.targetTemp0.bgTexture, 0, nil)
  wgpuRenderPassEncoderSetBindGroup(comp.renderPassEncoder, 1'u32, eff.bindGroupParams, 0, nil)
  wgpuRenderPassEncoderSetPipeline(comp.renderPassEncoder, comp.pipelines.effectTritone)
  comp.drawMeshImage(ctx, mesh)
  comp.endRenderPass()
  true
