## Bind group layouts and bind groups for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgBindGroups.h/.cpp.
## Creates/reuses layout objects and helper constructors for bind groups used by
## pipelines, textures and uniform/storage buffers.

import ./wg_ffi

type
  WgBindGroupLayouts* = object
    device*: WGPUDevice
    layoutTexSampled*: WGPUBindGroupLayout
    layoutTexSampledBuff1Un*: WGPUBindGroupLayout
    layoutTexSampledBuff2Un*: WGPUBindGroupLayout
    layoutTexStrorage1WO*: WGPUBindGroupLayout
    layoutTexStrorage1RO*: WGPUBindGroupLayout
    layoutTexStrorage2RO*: WGPUBindGroupLayout
    layoutTexStrorage3RO*: WGPUBindGroupLayout
    layoutBuffer1Un*: WGPUBindGroupLayout
    layoutBuffer2Un*: WGPUBindGroupLayout
    layoutBuffer3Un*: WGPUBindGroupLayout

proc createBindGroupTexSampled*(l: WgBindGroupLayouts; sampler: WGPUSampler; texView: WGPUTextureView): WGPUBindGroup =
  var entries = [
    WGPUBindGroupEntry(binding: 0'u32, sampler: sampler),
    WGPUBindGroupEntry(binding: 1'u32, textureView: texView)
  ]
  var desc = WGPUBindGroupDescriptor(
    layout: l.layoutTexSampled,
    entryCount: csize_t(entries.len),
    entries: addr entries[0]
  )
  wgpuDeviceCreateBindGroup(l.device, addr desc)

proc createBindGroupTexSampledBuff1Un*(l: WgBindGroupLayouts; sampler: WGPUSampler; texView: WGPUTextureView; buff: WGPUBuffer): WGPUBindGroup =
  var entries = [
    WGPUBindGroupEntry(binding: 0'u32, sampler: sampler),
    WGPUBindGroupEntry(binding: 1'u32, textureView: texView),
    WGPUBindGroupEntry(binding: 2'u32, buffer: buff, size: wgpuBufferGetSize(buff))
  ]
  var desc = WGPUBindGroupDescriptor(
    layout: l.layoutTexSampledBuff1Un,
    entryCount: csize_t(entries.len),
    entries: addr entries[0]
  )
  wgpuDeviceCreateBindGroup(l.device, addr desc)

proc createBindGroupTexSampledBuff2Un*(l: WgBindGroupLayouts; sampler: WGPUSampler; texView: WGPUTextureView;
                                       buff0, buff1: WGPUBuffer): WGPUBindGroup =
  var entries = [
    WGPUBindGroupEntry(binding: 0'u32, sampler: sampler),
    WGPUBindGroupEntry(binding: 1'u32, textureView: texView),
    WGPUBindGroupEntry(binding: 2'u32, buffer: buff0, size: wgpuBufferGetSize(buff0)),
    WGPUBindGroupEntry(binding: 3'u32, buffer: buff1, size: wgpuBufferGetSize(buff1))
  ]
  var desc = WGPUBindGroupDescriptor(
    layout: l.layoutTexSampledBuff2Un,
    entryCount: csize_t(entries.len),
    entries: addr entries[0]
  )
  wgpuDeviceCreateBindGroup(l.device, addr desc)

proc createBindGroupStrorage1WO*(l: WgBindGroupLayouts; texView: WGPUTextureView): WGPUBindGroup =
  var entries = [WGPUBindGroupEntry(binding: 0'u32, textureView: texView)]
  var desc = WGPUBindGroupDescriptor(
    layout: l.layoutTexStrorage1WO,
    entryCount: csize_t(entries.len),
    entries: addr entries[0]
  )
  wgpuDeviceCreateBindGroup(l.device, addr desc)

proc createBindGroupStrorage1RO*(l: WgBindGroupLayouts; texView: WGPUTextureView): WGPUBindGroup =
  var entries = [WGPUBindGroupEntry(binding: 0'u32, textureView: texView)]
  var desc = WGPUBindGroupDescriptor(
    layout: l.layoutTexStrorage1RO,
    entryCount: csize_t(entries.len),
    entries: addr entries[0]
  )
  wgpuDeviceCreateBindGroup(l.device, addr desc)

proc createBindGroupStrorage2RO*(l: WgBindGroupLayouts; texView0, texView1: WGPUTextureView): WGPUBindGroup =
  var entries = [
    WGPUBindGroupEntry(binding: 0'u32, textureView: texView0),
    WGPUBindGroupEntry(binding: 1'u32, textureView: texView1)
  ]
  var desc = WGPUBindGroupDescriptor(
    layout: l.layoutTexStrorage2RO,
    entryCount: csize_t(entries.len),
    entries: addr entries[0]
  )
  wgpuDeviceCreateBindGroup(l.device, addr desc)

proc createBindGroupStrorage3RO*(l: WgBindGroupLayouts; texView0, texView1, texView2: WGPUTextureView): WGPUBindGroup =
  var entries = [
    WGPUBindGroupEntry(binding: 0'u32, textureView: texView0),
    WGPUBindGroupEntry(binding: 1'u32, textureView: texView1),
    WGPUBindGroupEntry(binding: 2'u32, textureView: texView2)
  ]
  var desc = WGPUBindGroupDescriptor(
    layout: l.layoutTexStrorage3RO,
    entryCount: csize_t(entries.len),
    entries: addr entries[0]
  )
  wgpuDeviceCreateBindGroup(l.device, addr desc)

proc createBindGroupBuffer1Un*(l: WgBindGroupLayouts; buff: WGPUBuffer; offset, size: uint64): WGPUBindGroup =
  var entries = [WGPUBindGroupEntry(binding: 0'u32, buffer: buff, offset: offset, size: size)]
  var desc = WGPUBindGroupDescriptor(
    layout: l.layoutBuffer1Un,
    entryCount: csize_t(entries.len),
    entries: addr entries[0]
  )
  wgpuDeviceCreateBindGroup(l.device, addr desc)

proc createBindGroupBuffer1Un*(l: WgBindGroupLayouts; buff: WGPUBuffer): WGPUBindGroup =
  createBindGroupBuffer1Un(l, buff, 0'u64, wgpuBufferGetSize(buff))

proc createBindGroupBuffer2Un*(l: WgBindGroupLayouts; buff0, buff1: WGPUBuffer): WGPUBindGroup =
  var entries = [
    WGPUBindGroupEntry(binding: 0'u32, buffer: buff0, size: wgpuBufferGetSize(buff0)),
    WGPUBindGroupEntry(binding: 1'u32, buffer: buff1, size: wgpuBufferGetSize(buff1))
  ]
  var desc = WGPUBindGroupDescriptor(
    layout: l.layoutBuffer2Un,
    entryCount: csize_t(entries.len),
    entries: addr entries[0]
  )
  wgpuDeviceCreateBindGroup(l.device, addr desc)

proc createBindGroupBuffer3Un*(l: WgBindGroupLayouts; buff0, buff1, buff2: WGPUBuffer): WGPUBindGroup =
  var entries = [
    WGPUBindGroupEntry(binding: 0'u32, buffer: buff0, size: wgpuBufferGetSize(buff0)),
    WGPUBindGroupEntry(binding: 1'u32, buffer: buff1, size: wgpuBufferGetSize(buff1)),
    WGPUBindGroupEntry(binding: 2'u32, buffer: buff2, size: wgpuBufferGetSize(buff2))
  ]
  var desc = WGPUBindGroupDescriptor(
    layout: l.layoutBuffer3Un,
    entryCount: csize_t(entries.len),
    entries: addr entries[0]
  )
  wgpuDeviceCreateBindGroup(l.device, addr desc)

proc releaseBindGroup*(l: var WgBindGroupLayouts; bindGroup: var WGPUBindGroup) =
  if not isNil(bindGroup): wgpuBindGroupRelease(bindGroup)
  bindGroup = WGPUBindGroup(nil)

proc releaseBindGroupLayout*(l: var WgBindGroupLayouts; bindGroupLayout: var WGPUBindGroupLayout) =
  if not isNil(bindGroupLayout): wgpuBindGroupLayoutRelease(bindGroupLayout)
  bindGroupLayout = WGPUBindGroupLayout(nil)

proc initialize*(l: var WgBindGroupLayouts; device: WGPUDevice) =
  l.device = device

  let visibilityVert = WGPUShaderStage_Vertex or WGPUShaderStage_Fragment or WGPUShaderStage_Compute
  let visibilityFrag = WGPUShaderStage_Fragment or WGPUShaderStage_Compute
  let sampler = WGPUSamplerBindingLayout(`type`: WGPUSamplerBindingType_Filtering)
  let texture = WGPUTextureBindingLayout(sampleType: WGPUTextureSampleType_Float, viewDimension: WGPUTextureViewDimension_2D)
  let storageTextureWO = WGPUStorageTextureBindingLayout(
    access: WGPUStorageTextureAccess_WriteOnly,
    format: WGPUTextureFormat_RGBA8Unorm,
    viewDimension: WGPUTextureViewDimension_2D
  )
  let bufferUniform = WGPUBufferBindingLayout(`type`: WGPUBufferBindingType_Uniform)

  var entriesTexSampledBufferUniforms = [
    WGPUBindGroupLayoutEntry(binding: 0'u32, visibility: visibilityFrag, sampler: sampler),
    WGPUBindGroupLayoutEntry(binding: 1'u32, visibility: visibilityFrag, texture: texture),
    WGPUBindGroupLayoutEntry(binding: 2'u32, visibility: visibilityVert, buffer: bufferUniform),
    WGPUBindGroupLayoutEntry(binding: 3'u32, visibility: visibilityVert, buffer: bufferUniform)
  ]
  var layoutDescTexSampled = WGPUBindGroupLayoutDescriptor(entryCount: 2, entries: addr entriesTexSampledBufferUniforms[0])
  var layoutDescTexSampledBuff1Un = WGPUBindGroupLayoutDescriptor(entryCount: 3, entries: addr entriesTexSampledBufferUniforms[0])
  var layoutDescTexSampledBuff2Un = WGPUBindGroupLayoutDescriptor(entryCount: 4, entries: addr entriesTexSampledBufferUniforms[0])
  l.layoutTexSampled = wgpuDeviceCreateBindGroupLayout(device, addr layoutDescTexSampled)
  l.layoutTexSampledBuff1Un = wgpuDeviceCreateBindGroupLayout(device, addr layoutDescTexSampledBuff1Un)
  l.layoutTexSampledBuff2Un = wgpuDeviceCreateBindGroupLayout(device, addr layoutDescTexSampledBuff2Un)

  var entriesTexStoragesWO = [
    WGPUBindGroupLayoutEntry(binding: 0'u32, visibility: visibilityFrag, storageTexture: storageTextureWO)
  ]
  var layoutDescTexStrorage1WO = WGPUBindGroupLayoutDescriptor(entryCount: 1, entries: addr entriesTexStoragesWO[0])
  l.layoutTexStrorage1WO = wgpuDeviceCreateBindGroupLayout(device, addr layoutDescTexStrorage1WO)

  var entriesTexStoragesRO = [
    WGPUBindGroupLayoutEntry(binding: 0'u32, visibility: visibilityFrag, texture: texture),
    WGPUBindGroupLayoutEntry(binding: 1'u32, visibility: visibilityFrag, texture: texture),
    WGPUBindGroupLayoutEntry(binding: 2'u32, visibility: visibilityFrag, texture: texture)
  ]
  var layoutDescTexStorages1RO = WGPUBindGroupLayoutDescriptor(entryCount: 1, entries: addr entriesTexStoragesRO[0])
  var layoutDescTexStorages2RO = WGPUBindGroupLayoutDescriptor(entryCount: 2, entries: addr entriesTexStoragesRO[0])
  var layoutDescTexStorages3RO = WGPUBindGroupLayoutDescriptor(entryCount: 3, entries: addr entriesTexStoragesRO[0])
  l.layoutTexStrorage1RO = wgpuDeviceCreateBindGroupLayout(device, addr layoutDescTexStorages1RO)
  l.layoutTexStrorage2RO = wgpuDeviceCreateBindGroupLayout(device, addr layoutDescTexStorages2RO)
  l.layoutTexStrorage3RO = wgpuDeviceCreateBindGroupLayout(device, addr layoutDescTexStorages3RO)

  var entriesBufferUniform = [
    WGPUBindGroupLayoutEntry(binding: 0'u32, visibility: visibilityVert, buffer: bufferUniform),
    WGPUBindGroupLayoutEntry(binding: 1'u32, visibility: visibilityVert, buffer: bufferUniform),
    WGPUBindGroupLayoutEntry(binding: 2'u32, visibility: visibilityVert, buffer: bufferUniform)
  ]
  var layoutDescBufferUniforms1Un = WGPUBindGroupLayoutDescriptor(entryCount: 1, entries: addr entriesBufferUniform[0])
  var layoutDescBufferUniforms2Un = WGPUBindGroupLayoutDescriptor(entryCount: 2, entries: addr entriesBufferUniform[0])
  var layoutDescBufferUniforms3Un = WGPUBindGroupLayoutDescriptor(entryCount: 3, entries: addr entriesBufferUniform[0])
  l.layoutBuffer1Un = wgpuDeviceCreateBindGroupLayout(device, addr layoutDescBufferUniforms1Un)
  l.layoutBuffer2Un = wgpuDeviceCreateBindGroupLayout(device, addr layoutDescBufferUniforms2Un)
  l.layoutBuffer3Un = wgpuDeviceCreateBindGroupLayout(device, addr layoutDescBufferUniforms3Un)

proc release*(l: var WgBindGroupLayouts) =
  l.releaseBindGroupLayout(l.layoutBuffer3Un)
  l.releaseBindGroupLayout(l.layoutBuffer2Un)
  l.releaseBindGroupLayout(l.layoutBuffer1Un)
  l.releaseBindGroupLayout(l.layoutTexStrorage3RO)
  l.releaseBindGroupLayout(l.layoutTexStrorage2RO)
  l.releaseBindGroupLayout(l.layoutTexStrorage1RO)
  l.releaseBindGroupLayout(l.layoutTexStrorage1WO)
  l.releaseBindGroupLayout(l.layoutTexSampledBuff1Un)
  l.releaseBindGroupLayout(l.layoutTexSampledBuff2Un)
  l.releaseBindGroupLayout(l.layoutTexSampled)
  l.device = WGPUDevice(nil)
