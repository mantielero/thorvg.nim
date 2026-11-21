## WebGPU context and resource helpers for the WG engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgCommon.h/.cpp.
## Wraps device/queue/samplers, texture & buffer allocation/upload, and command submission.

import ./wg_ffi
import ./bind_groups

type
  WgContext* = object
    instance*: WGPUInstance
    adapter*: WGPUAdapter
    device*: WGPUDevice
    queue*: WGPUQueue
    format*: WGPUTextureFormat
    samplerNearestClamp*: WGPUSampler
    samplerNearestRepeat*: WGPUSampler
    samplerLinearRepeat*: WGPUSampler
    samplerLinearMirror*: WGPUSampler
    samplerLinearClamp*: WGPUSampler
    layouts*: WgBindGroupLayouts

proc createSampler*(ctx: var WgContext; filter: WGPUFilterMode; mipmapFilter: WGPUMipmapFilterMode;
                    addrMode: WGPUAddressMode; anisotropy: uint16 = 1): WGPUSampler =
  var desc = WGPUSamplerDescriptor(
    addressModeU: addrMode, addressModeV: addrMode, addressModeW: addrMode,
    magFilter: filter, minFilter: filter, mipmapFilter: mipmapFilter,
    lodMinClamp: 0.0'f32, lodMaxClamp: 32.0'f32, maxAnisotropy: anisotropy
  )
  wgpuDeviceCreateSampler(ctx.device, addr desc)

proc releaseQueue*(ctx: var WgContext; queue: var WGPUQueue) =
  if not isNil(queue):
    wgpuQueueRelease(queue)
    queue = WGPUQueue(nil)

proc releaseSampler*(ctx: var WgContext; sampler: var WGPUSampler) =
  if not isNil(sampler):
    wgpuSamplerRelease(sampler)
    sampler = WGPUSampler(nil)

proc releaseTextureView*(ctx: var WgContext; textureView: var WGPUTextureView) =
  if not isNil(textureView):
    wgpuTextureViewRelease(textureView)
    textureView = WGPUTextureView(nil)

proc releaseTexture*(ctx: var WgContext; texture: var WGPUTexture) =
  if not isNil(texture):
    wgpuTextureDestroy(texture)
    wgpuTextureRelease(texture)
    texture = WGPUTexture(nil)

proc releaseBuffer*(ctx: var WgContext; buffer: var WGPUBuffer) =
  if not isNil(buffer):
    wgpuBufferDestroy(buffer)
    wgpuBufferRelease(buffer)
    buffer = WGPUBuffer(nil)

proc createTexture*(ctx: var WgContext; width, height: uint32; format: WGPUTextureFormat): WGPUTexture =
  var desc = WGPUTextureDescriptor(
    usage: WGPUTextureUsage_CopyDst or WGPUTextureUsage_TextureBinding,
    dimension: WGPUTextureDimension_2D,
    size: WGPUExtent3D(width: width, height: height, depthOrArrayLayers: 1),
    format: format, mipLevelCount: 1, sampleCount: 1
  )
  wgpuDeviceCreateTexture(ctx.device, addr desc)

proc createTexStorage*(ctx: var WgContext; width, height: uint32; format: WGPUTextureFormat): WGPUTexture =
  var desc = WGPUTextureDescriptor(
    usage: WGPUTextureUsage_CopySrc or WGPUTextureUsage_CopyDst or
           WGPUTextureUsage_TextureBinding or WGPUTextureUsage_StorageBinding or
           WGPUTextureUsage_RenderAttachment,
    dimension: WGPUTextureDimension_2D,
    size: WGPUExtent3D(width: width, height: height, depthOrArrayLayers: 1),
    format: format, mipLevelCount: 1, sampleCount: 1
  )
  wgpuDeviceCreateTexture(ctx.device, addr desc)

proc createTexAttachement*(ctx: var WgContext; width, height: uint32; format: WGPUTextureFormat; sc: uint32): WGPUTexture =
  var desc = WGPUTextureDescriptor(
    usage: WGPUTextureUsage_RenderAttachment,
    dimension: WGPUTextureDimension_2D,
    size: WGPUExtent3D(width: width, height: height, depthOrArrayLayers: 1),
    format: format, mipLevelCount: 1, sampleCount: sc
  )
  wgpuDeviceCreateTexture(ctx.device, addr desc)

proc createTextureView*(ctx: var WgContext; texture: WGPUTexture): WGPUTextureView =
  var desc = WGPUTextureViewDescriptor(
    format: wgpuTextureGetFormat(texture),
    dimension: WGPUTextureViewDimension_2D,
    baseMipLevel: 0, mipLevelCount: 1,
    baseArrayLayer: 0, arrayLayerCount: 1,
    aspect: WGPUTextureAspect_All
  )
  wgpuTextureCreateView(texture, addr desc)

proc allocateTexture*(ctx: var WgContext; texture: var WGPUTexture; width, height: uint32;
                      format: WGPUTextureFormat; data: pointer; bytesPerRow: uint32; dataSize: uint64): bool =
  if (not isNil(texture)) and wgpuTextureGetWidth(texture) == width and
     wgpuTextureGetHeight(texture) == height and wgpuTextureGetFormat(texture) == format:
    var copyTextureInfo = WGPUTexelCopyTextureInfo(texture: texture)
    var copyBufferLayout = WGPUTexelCopyBufferLayout(bytesPerRow: bytesPerRow, rowsPerImage: height)
    var writeSize = WGPUExtent3D(width: width, height: height, depthOrArrayLayers: 1)
    wgpuQueueWriteTexture(ctx.queue, addr copyTextureInfo, data, csize_t(dataSize), addr copyBufferLayout, addr writeSize)
    false
  else:
    ctx.releaseTexture(texture)
    texture = ctx.createTexture(width, height, format)
    var copyTextureInfo = WGPUTexelCopyTextureInfo(texture: texture)
    var copyBufferLayout = WGPUTexelCopyBufferLayout(bytesPerRow: bytesPerRow, rowsPerImage: height)
    var writeSize = WGPUExtent3D(width: width, height: height, depthOrArrayLayers: 1)
    wgpuQueueWriteTexture(ctx.queue, addr copyTextureInfo, data, csize_t(dataSize), addr copyBufferLayout, addr writeSize)
    true

proc allocateBufferUniform*(ctx: var WgContext; buffer: var WGPUBuffer; data: pointer; capacity, size: uint64): bool =
  if capacity == 0'u64 or isNil(ctx.device) or isNil(ctx.queue): return false
  var changed = false
  if isNil(buffer) or wgpuBufferGetSize(buffer) < capacity:
    ctx.releaseBuffer(buffer)
    var desc = WGPUBufferDescriptor(usage: WGPUBufferUsage_CopyDst or WGPUBufferUsage_Uniform, size: capacity)
    buffer = wgpuDeviceCreateBuffer(ctx.device, addr desc)
    changed = true
  if isNil(buffer): return false
  if size != 0'u64 and data != nil:
    wgpuQueueWriteBuffer(ctx.queue, buffer, 0'u64, data, csize_t(size))
  changed

proc allocateBufferUniform*(ctx: var WgContext; buffer: var WGPUBuffer; data: pointer; size: uint64): bool =
  ctx.allocateBufferUniform(buffer, data, size, size)

proc allocateBufferVertex*(ctx: var WgContext; buffer: var WGPUBuffer; data: pointer; size: uint64): bool =
  if size == 0'u64 or isNil(ctx.device) or isNil(ctx.queue) or data == nil: return false
  if (not isNil(buffer)) and wgpuBufferGetSize(buffer) >= size:
    wgpuQueueWriteBuffer(ctx.queue, buffer, 0'u64, data, csize_t(size))
    false
  else:
    ctx.releaseBuffer(buffer)
    var desc = WGPUBufferDescriptor(usage: WGPUBufferUsage_CopyDst or WGPUBufferUsage_Vertex, size: size)
    buffer = wgpuDeviceCreateBuffer(ctx.device, addr desc)
    if isNil(buffer): return false
    wgpuQueueWriteBuffer(ctx.queue, buffer, 0'u64, data, csize_t(size))
    true

proc allocateBufferIndex*(ctx: var WgContext; buffer: var WGPUBuffer; data: ptr uint32; size: uint64): bool =
  if (not isNil(buffer)) and wgpuBufferGetSize(buffer) >= size:
    wgpuQueueWriteBuffer(ctx.queue, buffer, 0'u64, data, csize_t(size))
    false
  else:
    ctx.releaseBuffer(buffer)
    var desc = WGPUBufferDescriptor(usage: WGPUBufferUsage_CopyDst or WGPUBufferUsage_Index, size: size)
    buffer = wgpuDeviceCreateBuffer(ctx.device, addr desc)
    wgpuQueueWriteBuffer(ctx.queue, buffer, 0'u64, data, csize_t(size))
    true

proc createCommandEncoder*(ctx: var WgContext): WGPUCommandEncoder =
  var desc = WGPUCommandEncoderDescriptor()
  wgpuDeviceCreateCommandEncoder(ctx.device, addr desc)

proc submitCommandEncoder*(ctx: var WgContext; encoder: WGPUCommandEncoder) =
  var cbDesc = WGPUCommandBufferDescriptor()
  let commandsBuffer = wgpuCommandEncoderFinish(encoder, addr cbDesc)
  var cmd = commandsBuffer
  wgpuQueueSubmit(ctx.queue, 1, addr cmd)
  wgpuCommandBufferRelease(commandsBuffer)

proc releaseCommandEncoder*(ctx: var WgContext; encoder: var WGPUCommandEncoder) =
  if not isNil(encoder):
    wgpuCommandEncoderRelease(encoder)
    encoder = WGPUCommandEncoder(nil)

proc submit*(ctx: var WgContext) =
  wgpuQueueSubmit(ctx.queue, 0, nil)

proc invalid*(ctx: WgContext): bool =
  isNil(ctx.instance) or isNil(ctx.device)

proc processEvents*(ctx: var WgContext) {.inline.} =
  ## Pump wgpu-native events. Prefer this over wgpuInstanceWaitAny on builds where WaitAny is unimplemented.
  if not isNil(ctx.instance): wgpuInstanceProcessEvents(ctx.instance)

proc poll*(ctx: var WgContext; wait: bool = false): bool {.inline.} =
  ## wgpu-native extension: poll device queue. Returns true when queue is empty.
  if isNil(ctx.device): return false
  wgpuDevicePoll(ctx.device, WGPUBool(if wait: 1'u32 else: 0'u32), nil) != WGPUBool(0'u32)

proc initialize*(ctx: var WgContext; wctx: WgCanvasContext) =
  ctx.instance = WGPUInstance(wctx.instance)
  ctx.adapter = WGPUAdapter(wctx.adapter)
  ctx.device = WGPUDevice(wctx.device)
  ctx.format = WGPUTextureFormat_BGRA8Unorm
  ctx.queue = wgpuDeviceGetQueue(ctx.device)

  ctx.samplerNearestClamp = ctx.createSampler(WGPUFilterMode_Nearest, WGPUMipmapFilterMode_Nearest, WGPUAddressMode_ClampToEdge, 1)
  ctx.samplerNearestRepeat = ctx.createSampler(WGPUFilterMode_Nearest, WGPUMipmapFilterMode_Nearest, WGPUAddressMode_Repeat)
  ctx.samplerLinearRepeat = ctx.createSampler(WGPUFilterMode_Linear, WGPUMipmapFilterMode_Linear, WGPUAddressMode_Repeat, 4)
  ctx.samplerLinearMirror = ctx.createSampler(WGPUFilterMode_Linear, WGPUMipmapFilterMode_Linear, WGPUAddressMode_MirrorRepeat, 4)
  ctx.samplerLinearClamp = ctx.createSampler(WGPUFilterMode_Linear, WGPUMipmapFilterMode_Linear, WGPUAddressMode_ClampToEdge, 4)

  ctx.layouts.initialize(ctx.device)

proc release*(ctx: var WgContext) =
  ctx.layouts.release()
  ctx.releaseSampler(ctx.samplerLinearClamp)
  ctx.releaseSampler(ctx.samplerLinearMirror)
  ctx.releaseSampler(ctx.samplerLinearRepeat)
  ctx.releaseSampler(ctx.samplerNearestRepeat)
  ctx.releaseSampler(ctx.samplerNearestClamp)
  ctx.releaseQueue(ctx.queue)
