## UNSAFE (exempt, *_ffi.nim): raw wgpu-native (WebGPU C API) bindings.
##
## Port of upstream/src/renderer/gpu_engine/wg FFI surface. Types/proc signatures follow
## the WebGPU C header style used by upstream (WGPUStringView, chained shader source, etc.).
## Verify against the exact <webgpu/webgpu.h> / wgpu-native version linked (R-WG-2).
## This module declares `importc` symbols; building/linking requires wgpu-native headers/lib.

import ./wg_types
export wg_types

type
  WGPUStringView* {.bycopy.} = object
    data*: cstring
    length*: csize_t

  WGPUChainedStruct* {.bycopy.} = object
    next*: ptr WGPUChainedStruct
    sType*: WGPUSType

  WGPUExtent3D* {.bycopy.} = object
    width*: uint32
    height*: uint32
    depthOrArrayLayers*: uint32

  WGPUOrigin3D* {.bycopy.} = object
    x*: uint32
    y*: uint32
    z*: uint32

  WGPUColor* {.bycopy.} = object
    r*, g*, b*, a*: float64

  ## Shader
  WGPUShaderSourceWGSL* {.bycopy.} = object
    chain*: WGPUChainedStruct
    code*: WGPUStringView

  WGPUShaderModuleDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView

  ## Pipeline layout / bind groups
  WGPUPipelineLayoutDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    bindGroupLayoutCount*: csize_t
    bindGroupLayouts*: ptr WGPUBindGroupLayout
    immediateSize*: uint32

  WGPUBufferBindingLayout* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    `type`*: WGPUBufferBindingType
    hasDynamicOffset*: uint32 ## WGPUBool
    minBindingSize*: uint64

  WGPUSamplerBindingLayout* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    `type`*: WGPUSamplerBindingType

  WGPUTextureBindingLayout* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    sampleType*: WGPUTextureSampleType
    viewDimension*: WGPUTextureViewDimension
    multisampled*: uint32 ## WGPUBool

  WGPUStorageTextureBindingLayout* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    access*: WGPUStorageTextureAccess
    format*: WGPUTextureFormat
    viewDimension*: WGPUTextureViewDimension

  WGPUBindGroupLayoutEntry* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    binding*: uint32
    visibility*: WGPUShaderStage
    bindingArraySize*: uint32
    buffer*: WGPUBufferBindingLayout
    sampler*: WGPUSamplerBindingLayout
    texture*: WGPUTextureBindingLayout
    storageTexture*: WGPUStorageTextureBindingLayout

  WGPUBindGroupLayoutDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    entryCount*: csize_t
    entries*: ptr WGPUBindGroupLayoutEntry

  WGPUBindGroupEntry* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    binding*: uint32
    buffer*: WGPUBuffer
    offset*: uint64
    size*: uint64
    sampler*: WGPUSampler
    textureView*: WGPUTextureView

  WGPUBindGroupDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    layout*: WGPUBindGroupLayout
    entryCount*: csize_t
    entries*: ptr WGPUBindGroupEntry

  ## Vertex
  WGPUVertexAttribute* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    format*: WGPUVertexFormat
    offset*: uint64
    shaderLocation*: uint32

  WGPUVertexBufferLayout* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    stepMode*: WGPUVertexStepMode
    arrayStride*: uint64
    attributeCount*: csize_t
    attributes*: ptr WGPUVertexAttribute

  WGPUVertexState* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    module*: WGPUShaderModule
    entryPoint*: WGPUStringView
    constantCount*: csize_t
    constants*: pointer
    bufferCount*: csize_t
    buffers*: ptr WGPUVertexBufferLayout

  WGPUPrimitiveState* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    topology*: WGPUPrimitiveTopology
    stripIndexFormat*: WGPUIndexFormat
    frontFace*: WGPUFrontFace
    cullMode*: WGPUCullMode
    unclippedDepth*: uint32

  WGPUStencilFaceState* {.bycopy.} = object
    compare*: WGPUCompareFunction
    failOp*: WGPUStencilOperation
    depthFailOp*: WGPUStencilOperation
    passOp*: WGPUStencilOperation

  WGPUDepthStencilState* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    format*: WGPUTextureFormat
    depthWriteEnabled*: WGPUOptionalBool
    depthCompare*: WGPUCompareFunction
    stencilFront*: WGPUStencilFaceState
    stencilBack*: WGPUStencilFaceState
    stencilReadMask*: uint32
    stencilWriteMask*: uint32
    depthBias*: int32
    depthBiasSlopeScale*: float32
    depthBiasClamp*: float32

  WGPUBlendComponent* {.bycopy.} = object
    operation*: WGPUBlendOperation
    srcFactor*: WGPUBlendFactor
    dstFactor*: WGPUBlendFactor

  WGPUBlendState* {.bycopy.} = object
    color*: WGPUBlendComponent
    alpha*: WGPUBlendComponent

  WGPUColorTargetState* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    format*: WGPUTextureFormat
    blend*: ptr WGPUBlendState
    writeMask*: WGPUColorWriteMask

  WGPUFragmentState* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    module*: WGPUShaderModule
    entryPoint*: WGPUStringView
    constantCount*: csize_t
    constants*: pointer
    targetCount*: csize_t
    targets*: ptr WGPUColorTargetState

  WGPUMultisampleState* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    count*: uint32
    mask*: uint32
    alphaToCoverageEnabled*: uint32

  WGPURenderPipelineDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    layout*: WGPUPipelineLayout
    vertex*: WGPUVertexState
    primitive*: WGPUPrimitiveState
    depthStencil*: ptr WGPUDepthStencilState
    multisample*: WGPUMultisampleState
    fragment*: ptr WGPUFragmentState

  WGPUComputeState* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    module*: WGPUShaderModule
    entryPoint*: WGPUStringView
    constantCount*: csize_t
    constants*: pointer

  WGPUComputePipelineDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    layout*: WGPUPipelineLayout
    compute*: WGPUComputeState

  ## Resources
  WGPUBufferDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    usage*: WGPUBufferUsage
    size*: uint64
    mappedAtCreation*: uint32

  WGPUTextureDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    usage*: WGPUTextureUsage
    dimension*: WGPUTextureDimension
    size*: WGPUExtent3D
    format*: WGPUTextureFormat
    mipLevelCount*: uint32
    sampleCount*: uint32
    viewFormatCount*: csize_t
    viewFormats*: ptr WGPUTextureFormat

  WGPUTextureViewDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    format*: WGPUTextureFormat
    dimension*: WGPUTextureViewDimension
    baseMipLevel*: uint32
    mipLevelCount*: uint32
    baseArrayLayer*: uint32
    arrayLayerCount*: uint32
    aspect*: WGPUTextureAspect
    usage*: WGPUTextureUsage

  WGPUSamplerDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    addressModeU*: WGPUAddressMode
    addressModeV*: WGPUAddressMode
    addressModeW*: WGPUAddressMode
    magFilter*: WGPUFilterMode
    minFilter*: WGPUFilterMode
    mipmapFilter*: WGPUMipmapFilterMode
    lodMinClamp*: float32
    lodMaxClamp*: float32
    compare*: WGPUCompareFunction
    maxAnisotropy*: uint16

  ## Commands / queue / passes
  WGPUCommandEncoderDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView

  WGPUCommandBufferDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView

  WGPUTexelCopyTextureInfo* {.bycopy.} = object
    texture*: WGPUTexture
    mipLevel*: uint32
    origin*: WGPUOrigin3D
    aspect*: WGPUTextureAspect

  WGPUTexelCopyBufferLayout* {.bycopy.} = object
    offset*: uint64
    bytesPerRow*: uint32
    rowsPerImage*: uint32

  WGPUTexelCopyBufferInfo* {.bycopy.} = object
    layout*: WGPUTexelCopyBufferLayout
    buffer*: WGPUBuffer

  WGPURenderPassColorAttachment* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    view*: WGPUTextureView
    depthSlice*: uint32
    resolveTarget*: WGPUTextureView
    loadOp*: WGPULoadOp
    storeOp*: WGPUStoreOp
    clearValue*: WGPUColor

  WGPURenderPassDepthStencilAttachment* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    view*: WGPUTextureView
    depthLoadOp*: WGPULoadOp
    depthStoreOp*: WGPUStoreOp
    depthClearValue*: float32
    depthReadOnly*: WGPUBool
    stencilLoadOp*: WGPULoadOp
    stencilStoreOp*: WGPUStoreOp
    stencilClearValue*: uint32
    stencilReadOnly*: WGPUBool

  WGPURenderPassDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    colorAttachmentCount*: csize_t
    colorAttachments*: ptr WGPURenderPassColorAttachment
    depthStencilAttachment*: ptr WGPURenderPassDepthStencilAttachment
    occlusionQuerySet*: WGPUQuerySet
    timestampWrites*: pointer

  WGPUComputePassDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    timestampWrites*: pointer

  ## Surface (subset)
  WGPUSurfaceTexture* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    texture*: WGPUTexture
    status*: WGPUSurfaceGetCurrentTextureStatus

  WGPUSurfaceConfiguration* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    device*: WGPUDevice
    format*: WGPUTextureFormat
    usage*: WGPUTextureUsage
    width*: uint32
    height*: uint32
    viewFormatCount*: csize_t
    viewFormats*: ptr WGPUTextureFormat
    alphaMode*: WGPUCompositeAlphaMode
    presentMode*: WGPUPresentMode

  ## W8 init/surface/sync structs (webgpu.h modern API)
  WGPURequestAdapterCallback* = proc (status: WGPURequestAdapterStatus; adapter: WGPUAdapter;
    message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.}
  WGPURequestDeviceCallback* = proc (status: WGPURequestDeviceStatus; device: WGPUDevice;
    message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.}
  WGPUQueueWorkDoneCallback* = proc (status: WGPUQueueWorkDoneStatus;
    message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.}
  WGPUMapAsyncStatus* = enum
    WGPUMapAsyncStatus_Success = 0x00000001
    WGPUMapAsyncStatus_CallbackCancelled = 0x00000002
    WGPUMapAsyncStatus_Error = 0x00000003
    WGPUMapAsyncStatus_Aborted = 0x00000004
    WGPUMapAsyncStatus_Force32 = 0x7FFFFFFF
  WGPUMapMode* = distinct WGPUFlags
  WGPUBufferMapCallback* = proc (status: WGPUMapAsyncStatus;
    message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.}
  WGPUDeviceLostCallback* = proc (device: ptr WGPUDevice; reason: WGPUDeviceLostReason;
    message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.}
  WGPUUncapturedErrorCallback* = proc (device: ptr WGPUDevice; errType: WGPUErrorType;
    message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.}

  WGPUInstanceDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    requiredFeatureCount*: csize_t
    requiredFeatures*: pointer ## WGPUInstanceFeatureName const *
    requiredLimits*: pointer    ## WGPUInstanceLimits const *

  WGPURequestAdapterOptions* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    featureLevel*: WGPUFeatureLevel
    powerPreference*: WGPUPowerPreference
    forceFallbackAdapter*: WGPUBool
    backendType*: WGPUBackendType
    compatibleSurface*: WGPUSurface

  WGPURequestAdapterCallbackInfo* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    mode*: WGPUCallbackMode
    callback*: WGPURequestAdapterCallback
    userdata1*: pointer
    userdata2*: pointer

  WGPUAdapterInfo* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    vendor*: WGPUStringView
    architecture*: WGPUStringView
    device*: WGPUStringView
    description*: WGPUStringView
    backendType*: WGPUBackendType
    adapterType*: WGPUAdapterType
    vendorID*: uint32
    deviceID*: uint32
    subgroupMinSize*: uint32
    subgroupMaxSize*: uint32

  WGPULimits* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    maxTextureDimension1D*: uint32
    maxTextureDimension2D*: uint32
    maxTextureDimension3D*: uint32
    maxTextureArrayLayers*: uint32
    maxBindGroups*: uint32
    maxBindGroupsPlusVertexBuffers*: uint32
    maxBindingsPerBindGroup*: uint32
    maxDynamicUniformBuffersPerPipelineLayout*: uint32
    maxDynamicStorageBuffersPerPipelineLayout*: uint32
    maxSampledTexturesPerShaderStage*: uint32
    maxSamplersPerShaderStage*: uint32
    maxStorageBuffersPerShaderStage*: uint32
    maxStorageTexturesPerShaderStage*: uint32
    maxUniformBuffersPerShaderStage*: uint32
    maxUniformBufferBindingSize*: uint64
    maxStorageBufferBindingSize*: uint64
    minUniformBufferOffsetAlignment*: uint32
    minStorageBufferOffsetAlignment*: uint32
    maxVertexBuffers*: uint32
    maxBufferSize*: uint64
    maxVertexAttributes*: uint32
    maxVertexBufferArrayStride*: uint32
    maxInterStageShaderVariables*: uint32
    maxColorAttachments*: uint32
    maxColorAttachmentBytesPerSample*: uint32
    maxComputeWorkgroupStorageSize*: uint32
    maxComputeInvocationsPerWorkgroup*: uint32
    maxComputeWorkgroupSizeX*: uint32
    maxComputeWorkgroupSizeY*: uint32
    maxComputeWorkgroupSizeZ*: uint32
    maxComputeWorkgroupsPerDimension*: uint32
    maxImmediateSize*: uint32

  WGPUQueueDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView

  WGPUDeviceLostCallbackInfo* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    mode*: WGPUCallbackMode
    callback*: WGPUDeviceLostCallback
    userdata1*: pointer
    userdata2*: pointer

  WGPUUncapturedErrorCallbackInfo* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    callback*: WGPUUncapturedErrorCallback
    userdata1*: pointer
    userdata2*: pointer

  WGPUDeviceDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView
    requiredFeatureCount*: csize_t
    requiredFeatures*: pointer ## WGPUFeatureName const *
    requiredLimits*: ptr WGPULimits
    defaultQueue*: WGPUQueueDescriptor
    deviceLostCallbackInfo*: WGPUDeviceLostCallbackInfo
    uncapturedErrorCallbackInfo*: WGPUUncapturedErrorCallbackInfo

  WGPURequestDeviceCallbackInfo* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    mode*: WGPUCallbackMode
    callback*: WGPURequestDeviceCallback
    userdata1*: pointer
    userdata2*: pointer

  WGPUQueueWorkDoneCallbackInfo* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    mode*: WGPUCallbackMode
    callback*: WGPUQueueWorkDoneCallback
    userdata1*: pointer
    userdata2*: pointer

  WGPUBufferMapCallbackInfo* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    mode*: WGPUCallbackMode
    callback*: WGPUBufferMapCallback
    userdata1*: pointer
    userdata2*: pointer

  WGPUFutureWaitInfo* {.bycopy.} = object
    future*: WGPUFuture
    completed*: WGPUBool

  WGPUSurfaceDescriptor* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    label*: WGPUStringView

  WGPUSurfaceSourceWindowsHWND* {.bycopy.} = object
    chain*: WGPUChainedStruct
    hinstance*: pointer
    hwnd*: pointer

  WGPUSurfaceSourceXlibWindow* {.bycopy.} = object
    chain*: WGPUChainedStruct
    display*: pointer
    window*: uint64

  WGPUSurfaceSourceWaylandSurface* {.bycopy.} = object
    chain*: WGPUChainedStruct
    display*: pointer
    surface*: pointer

  WGPUSurfaceCapabilities* {.bycopy.} = object
    nextInChain*: ptr WGPUChainedStruct
    usages*: WGPUTextureUsage
    formatCount*: csize_t
    formats*: ptr WGPUTextureFormat
    presentModeCount*: csize_t
    presentModes*: ptr WGPUPresentMode
    alphaModeCount*: csize_t
    alphaModes*: ptr WGPUCompositeAlphaMode

{.push importc, cdecl.}

proc wgpuDeviceCreateShaderModule*(device: WGPUDevice; descriptor: ptr WGPUShaderModuleDescriptor): WGPUShaderModule
proc wgpuDeviceCreatePipelineLayout*(device: WGPUDevice; descriptor: ptr WGPUPipelineLayoutDescriptor): WGPUPipelineLayout
proc wgpuDeviceCreateRenderPipeline*(device: WGPUDevice; descriptor: ptr WGPURenderPipelineDescriptor): WGPURenderPipeline
proc wgpuDeviceCreateComputePipeline*(device: WGPUDevice; descriptor: ptr WGPUComputePipelineDescriptor): WGPUComputePipeline
proc wgpuDeviceCreateBindGroupLayout*(device: WGPUDevice; descriptor: ptr WGPUBindGroupLayoutDescriptor): WGPUBindGroupLayout
proc wgpuDeviceCreateBindGroup*(device: WGPUDevice; descriptor: ptr WGPUBindGroupDescriptor): WGPUBindGroup
proc wgpuDeviceCreateBuffer*(device: WGPUDevice; descriptor: ptr WGPUBufferDescriptor): WGPUBuffer
proc wgpuDeviceCreateTexture*(device: WGPUDevice; descriptor: ptr WGPUTextureDescriptor): WGPUTexture
proc wgpuDeviceCreateSampler*(device: WGPUDevice; descriptor: ptr WGPUSamplerDescriptor): WGPUSampler
proc wgpuDeviceCreateCommandEncoder*(device: WGPUDevice; descriptor: ptr WGPUCommandEncoderDescriptor = nil): WGPUCommandEncoder
proc wgpuDeviceGetQueue*(device: WGPUDevice): WGPUQueue

proc wgpuTextureCreateView*(texture: WGPUTexture; descriptor: ptr WGPUTextureViewDescriptor = nil): WGPUTextureView
proc wgpuTextureGetFormat*(texture: WGPUTexture): WGPUTextureFormat
proc wgpuTextureGetWidth*(texture: WGPUTexture): uint32
proc wgpuTextureGetHeight*(texture: WGPUTexture): uint32
proc wgpuTextureDestroy*(texture: WGPUTexture)
proc wgpuTextureRelease*(texture: WGPUTexture)
proc wgpuTextureViewRelease*(textureView: WGPUTextureView)
proc wgpuSamplerRelease*(sampler: WGPUSampler)
proc wgpuBufferDestroy*(buffer: WGPUBuffer)
proc wgpuBufferRelease*(buffer: WGPUBuffer)
proc wgpuBufferGetSize*(buffer: WGPUBuffer): uint64
proc wgpuBufferMapAsync*(buffer: WGPUBuffer; mode: WGPUMapMode; offset, size: csize_t; callbackInfo: WGPUBufferMapCallbackInfo): WGPUFuture
proc wgpuBufferGetMappedRange*(buffer: WGPUBuffer; offset, size: csize_t): pointer
proc wgpuBufferGetConstMappedRange*(buffer: WGPUBuffer; offset, size: csize_t): pointer
proc wgpuBufferUnmap*(buffer: WGPUBuffer)
proc wgpuBindGroupRelease*(group: WGPUBindGroup)
proc wgpuBindGroupLayoutRelease*(layout: WGPUBindGroupLayout)
proc wgpuPipelineLayoutRelease*(layout: WGPUPipelineLayout)
proc wgpuRenderPipelineRelease*(pipeline: WGPURenderPipeline)
proc wgpuComputePipelineRelease*(pipeline: WGPUComputePipeline)
proc wgpuShaderModuleRelease*(shaderModule: WGPUShaderModule)
proc wgpuCommandEncoderRelease*(encoder: WGPUCommandEncoder)
proc wgpuCommandBufferRelease*(commandBuffer: WGPUCommandBuffer)
proc wgpuRenderPassEncoderRelease*(pass: WGPURenderPassEncoder)
proc wgpuComputePassEncoderRelease*(pass: WGPUComputePassEncoder)
proc wgpuQueueRelease*(queue: WGPUQueue)

proc wgpuQueueWriteBuffer*(queue: WGPUQueue; buffer: WGPUBuffer; bufferOffset: uint64; data: pointer; size: csize_t)
proc wgpuQueueWriteTexture*(queue: WGPUQueue; destination: ptr WGPUTexelCopyTextureInfo; data: pointer; dataSize: csize_t; dataLayout: ptr WGPUTexelCopyBufferLayout; writeSize: ptr WGPUExtent3D)
proc wgpuQueueSubmit*(queue: WGPUQueue; commandCount: csize_t; commands: ptr WGPUCommandBuffer)

proc wgpuCommandEncoderFinish*(encoder: WGPUCommandEncoder; descriptor: ptr WGPUCommandBufferDescriptor = nil): WGPUCommandBuffer
proc wgpuCommandEncoderBeginRenderPass*(encoder: WGPUCommandEncoder; descriptor: ptr WGPURenderPassDescriptor): WGPURenderPassEncoder
proc wgpuCommandEncoderBeginComputePass*(encoder: WGPUCommandEncoder; descriptor: ptr WGPUComputePassDescriptor = nil): WGPUComputePassEncoder
proc wgpuCommandEncoderCopyTextureToBuffer*(encoder: WGPUCommandEncoder; source: ptr WGPUTexelCopyTextureInfo; destination: ptr WGPUTexelCopyBufferInfo; copySize: ptr WGPUExtent3D)
proc wgpuCommandEncoderCopyTextureToTexture*(encoder: WGPUCommandEncoder; source: ptr WGPUTexelCopyTextureInfo; destination: ptr WGPUTexelCopyTextureInfo; copySize: ptr WGPUExtent3D)

proc wgpuRenderPassEncoderSetPipeline*(pass: WGPURenderPassEncoder; pipeline: WGPURenderPipeline)
proc wgpuRenderPassEncoderSetBindGroup*(pass: WGPURenderPassEncoder; groupIndex: uint32; group: WGPUBindGroup; dynamicOffsetCount: csize_t = 0; dynamicOffsets: ptr uint32 = nil)
proc wgpuRenderPassEncoderSetVertexBuffer*(pass: WGPURenderPassEncoder; slot: uint32; buffer: WGPUBuffer; offset: uint64 = 0; size: uint64 = uint64(high(uint64)))
proc wgpuRenderPassEncoderSetIndexBuffer*(pass: WGPURenderPassEncoder; buffer: WGPUBuffer; format: WGPUIndexFormat; offset: uint64 = 0; size: uint64 = uint64(high(uint64)))
proc wgpuRenderPassEncoderSetScissorRect*(pass: WGPURenderPassEncoder; x, y, width, height: uint32)
proc wgpuRenderPassEncoderSetStencilReference*(pass: WGPURenderPassEncoder; reference: uint32)
proc wgpuRenderPassEncoderDrawIndexed*(pass: WGPURenderPassEncoder; indexCount: uint32; instanceCount: uint32 = 1; firstIndex: uint32 = 0; baseVertex: int32 = 0; firstInstance: uint32 = 0)
proc wgpuRenderPassEncoderEnd*(pass: WGPURenderPassEncoder)

proc wgpuComputePassEncoderSetPipeline*(pass: WGPUComputePassEncoder; pipeline: WGPUComputePipeline)
proc wgpuComputePassEncoderSetBindGroup*(pass: WGPUComputePassEncoder; groupIndex: uint32; group: WGPUBindGroup; dynamicOffsetCount: csize_t = 0; dynamicOffsets: ptr uint32 = nil)
proc wgpuComputePassEncoderDispatchWorkgroups*(pass: WGPUComputePassEncoder; workgroupCountX: uint32; workgroupCountY: uint32 = 1; workgroupCountZ: uint32 = 1)
proc wgpuComputePassEncoderEnd*(pass: WGPUComputePassEncoder)

proc wgpuSurfaceConfigure*(surface: WGPUSurface; config: ptr WGPUSurfaceConfiguration)
proc wgpuSurfaceUnconfigure*(surface: WGPUSurface)
proc wgpuSurfaceGetCurrentTexture*(surface: WGPUSurface; surfaceTexture: ptr WGPUSurfaceTexture)
proc wgpuSurfacePresent*(surface: WGPUSurface): WGPUStatus
proc wgpuSurfaceGetCapabilities*(surface: WGPUSurface; adapter: WGPUAdapter; capabilities: ptr WGPUSurfaceCapabilities): WGPUStatus
proc wgpuSurfaceCapabilitiesFreeMembers*(capabilities: WGPUSurfaceCapabilities)
proc wgpuSurfaceRelease*(surface: WGPUSurface)

proc wgpuCreateInstance*(descriptor: ptr WGPUInstanceDescriptor = nil): WGPUInstance
proc wgpuInstanceRelease*(instance: WGPUInstance)
proc wgpuInstanceCreateSurface*(instance: WGPUInstance; descriptor: ptr WGPUSurfaceDescriptor): WGPUSurface
proc wgpuInstanceRequestAdapter*(instance: WGPUInstance; options: ptr WGPURequestAdapterOptions = nil;
  callbackInfo: WGPURequestAdapterCallbackInfo): WGPUFuture
proc wgpuInstanceProcessEvents*(instance: WGPUInstance)
proc wgpuInstanceWaitAny*(instance: WGPUInstance; futureCount: csize_t; futures: ptr WGPUFutureWaitInfo; timeoutNS: uint64): WGPUWaitStatus

proc wgpuAdapterRelease*(adapter: WGPUAdapter)
proc wgpuAdapterRequestDevice*(adapter: WGPUAdapter; descriptor: ptr WGPUDeviceDescriptor = nil;
  callbackInfo: WGPURequestDeviceCallbackInfo): WGPUFuture
proc wgpuAdapterGetLimits*(adapter: WGPUAdapter; limits: ptr WGPULimits): WGPUStatus
proc wgpuAdapterHasFeature*(adapter: WGPUAdapter; feature: uint32): WGPUBool
proc wgpuAdapterGetInfo*(adapter: WGPUAdapter; info: ptr WGPUAdapterInfo): WGPUStatus
proc wgpuAdapterInfoFreeMembers*(adapterInfo: WGPUAdapterInfo)

proc wgpuDeviceRelease*(device: WGPUDevice)
proc wgpuQueueOnSubmittedWorkDone*(queue: WGPUQueue; callbackInfo: WGPUQueueWorkDoneCallbackInfo): WGPUFuture

# wgpu-native extension (wgpu.h)
proc wgpuDevicePoll*(device: WGPUDevice; wait: WGPUBool; submissionIndex: ptr WGPUSubmissionIndex = nil): WGPUBool

{.pop.}

const
  WGPUMapMode_Read* = WGPUMapMode(0x0000000000000001'u64)
  WGPUMapMode_Write* = WGPUMapMode(0x0000000000000002'u64)
  WGPU_STRLEN*: csize_t = csize_t.high

proc wgpuSV*(s: cstring): WGPUStringView {.inline.} =
  WGPUStringView(data: s, length: WGPU_STRLEN)

proc wgpuSV*(s: string): WGPUStringView {.inline.} =
  if s.len == 0: WGPUStringView(data: nil, length: 0)
  else: WGPUStringView(data: cstring(s), length: csize_t(s.len))
