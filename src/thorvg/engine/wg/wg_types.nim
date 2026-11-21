## Safe types and aliases for the Nim port of ThorVG's WebGPU (wgpu-native) engine.
##
## Port target: upstream/src/renderer/gpu_engine/wg (tvgWgCommon.h, WgCanvas API).
## Values/types verified against installed wgpu-native headers:
##   /usr/include/webgpu/webgpu.h, /usr/include/webgpu/wgpu.h
## Keep this in sync when upgrading wgpu-native (R-WG-2).

type
  ## Opaque WebGPU handles (C: pointers to impl structs). Distinct pointers prevent mixing.
  WGPUInstance* = distinct pointer
  WGPUAdapter* = distinct pointer
  WGPUDevice* = distinct pointer
  WGPUQueue* = distinct pointer
  WGPUSurface* = distinct pointer
  WGPUBuffer* = distinct pointer
  WGPUTexture* = distinct pointer
  WGPUTextureView* = distinct pointer
  WGPUSampler* = distinct pointer
  WGPUBindGroupLayout* = distinct pointer
  WGPUBindGroup* = distinct pointer
  WGPUPipelineLayout* = distinct pointer
  WGPURenderPipeline* = distinct pointer
  WGPUComputePipeline* = distinct pointer
  WGPUShaderModule* = distinct pointer
  WGPUCommandEncoder* = distinct pointer
  WGPUCommandBuffer* = distinct pointer
  WGPURenderPassEncoder* = distinct pointer
  WGPUComputePassEncoder* = distinct pointer
  WGPUQuerySet* = distinct pointer
  WGPURenderBundle* = distinct pointer
  WGPURenderBundleEncoder* = distinct pointer

  ## Base scalar types (webgpu.h)
  WGPUFlags* = uint64
  WGPUBool* = uint32
  WGPUSubmissionIndex* = uint64

  WGPUFuture* {.bycopy.} = object
    id*: uint64

  ## Common enum/flag types (distinct uint32/uint64 as appropriate)
  WGPUTextureFormat* = distinct uint32
  WGPUTextureDimension* = distinct uint32
  WGPUTextureViewDimension* = distinct uint32
  WGPUTextureAspect* = distinct uint32
  WGPUAddressMode* = distinct uint32
  WGPUFilterMode* = distinct uint32
  WGPUMipmapFilterMode* = distinct uint32
  WGPUCompareFunction* = distinct uint32
  WGPUStencilOperation* = distinct uint32
  WGPUPrimitiveTopology* = distinct uint32
  WGPUFrontFace* = distinct uint32
  WGPUCullMode* = distinct uint32
  WGPUIndexFormat* = distinct uint32
  WGPUVertexStepMode* = distinct uint32
  WGPUVertexFormat* = distinct uint32
  WGPULoadOp* = distinct uint32
  WGPUStoreOp* = distinct uint32
  WGPUBlendOperation* = distinct uint32
  WGPUBlendFactor* = distinct uint32
  WGPUBufferBindingType* = distinct uint32
  WGPUSamplerBindingType* = distinct uint32
  WGPUTextureSampleType* = distinct uint32
  WGPUStorageTextureAccess* = distinct uint32
  WGPUOptionalBool* = distinct uint32
  WGPUCompositeAlphaMode* = distinct uint32
  WGPUPresentMode* = distinct uint32
  WGPUSurfaceGetCurrentTextureStatus* = distinct uint32
  WGPUSType* = distinct uint32
  WGPUCallbackMode* = distinct uint32
  WGPUWaitStatus* = distinct uint32
  WGPUFeatureLevel* = distinct uint32
  WGPUPowerPreference* = distinct uint32
  WGPUBackendType* = distinct uint32
  WGPUStatus* = distinct uint32
  WGPURequestAdapterStatus* = distinct uint32
  WGPURequestDeviceStatus* = distinct uint32
  WGPUQueueWorkDoneStatus* = distinct uint32
  WGPUErrorType* = distinct uint32
  WGPUDeviceLostReason* = distinct uint32
  WGPUAdapterType* = distinct uint32

  ## Flag/bitfield types (WGPUFlags = uint64 in webgpu.h)
  WGPUBufferUsage* = distinct WGPUFlags
  WGPUTextureUsage* = distinct WGPUFlags
  WGPUShaderStage* = distinct WGPUFlags
  WGPUColorWriteMask* = distinct WGPUFlags
  WGPUMapMode* = distinct WGPUFlags

template isNil*(h: WGPUInstance): bool = pointer(h) == nil
template isNil*(h: WGPUAdapter): bool = pointer(h) == nil
template isNil*(h: WGPUDevice): bool = pointer(h) == nil
template isNil*(h: WGPUQueue): bool = pointer(h) == nil
template isNil*(h: WGPUSurface): bool = pointer(h) == nil
template isNil*(h: WGPUBuffer): bool = pointer(h) == nil
template isNil*(h: WGPUTexture): bool = pointer(h) == nil
template isNil*(h: WGPUTextureView): bool = pointer(h) == nil
template isNil*(h: WGPUSampler): bool = pointer(h) == nil
template isNil*(h: WGPUBindGroupLayout): bool = pointer(h) == nil
template isNil*(h: WGPUBindGroup): bool = pointer(h) == nil
template isNil*(h: WGPUPipelineLayout): bool = pointer(h) == nil
template isNil*(h: WGPURenderPipeline): bool = pointer(h) == nil
template isNil*(h: WGPUComputePipeline): bool = pointer(h) == nil
template isNil*(h: WGPUShaderModule): bool = pointer(h) == nil
template isNil*(h: WGPUCommandEncoder): bool = pointer(h) == nil
template isNil*(h: WGPUCommandBuffer): bool = pointer(h) == nil
template isNil*(h: WGPURenderPassEncoder): bool = pointer(h) == nil
template isNil*(h: WGPUComputePassEncoder): bool = pointer(h) == nil
template isNil*(h: WGPUQuerySet): bool = pointer(h) == nil

template defHandleEq(T: typedesc): untyped =
  template `==`*(a, b: T): bool = pointer(a) == pointer(b)

defHandleEq(WGPUInstance)
defHandleEq(WGPUAdapter)
defHandleEq(WGPUDevice)
defHandleEq(WGPUQueue)
defHandleEq(WGPUSurface)
defHandleEq(WGPUBuffer)
defHandleEq(WGPUTexture)
defHandleEq(WGPUTextureView)
defHandleEq(WGPUSampler)
defHandleEq(WGPUBindGroupLayout)
defHandleEq(WGPUBindGroup)
defHandleEq(WGPUPipelineLayout)
defHandleEq(WGPURenderPipeline)
defHandleEq(WGPUComputePipeline)
defHandleEq(WGPUShaderModule)
defHandleEq(WGPUCommandEncoder)
defHandleEq(WGPUCommandBuffer)
defHandleEq(WGPURenderPassEncoder)
defHandleEq(WGPUComputePassEncoder)
defHandleEq(WGPUQuerySet)
defHandleEq(WGPURenderBundle)
defHandleEq(WGPURenderBundleEncoder)

# Distinct flag operators
template `==`*(a, b: WGPUBufferUsage): bool = WGPUFlags(a) == WGPUFlags(b)
template `==`*(a, b: WGPUTextureUsage): bool = WGPUFlags(a) == WGPUFlags(b)
template `==`*(a, b: WGPUShaderStage): bool = WGPUFlags(a) == WGPUFlags(b)
template `==`*(a, b: WGPUColorWriteMask): bool = WGPUFlags(a) == WGPUFlags(b)
template `==`*(a, b: WGPUMapMode): bool = WGPUFlags(a) == WGPUFlags(b)
template `or`*(a, b: WGPUBufferUsage): WGPUBufferUsage = WGPUBufferUsage(WGPUFlags(a) or WGPUFlags(b))
template `or`*(a, b: WGPUTextureUsage): WGPUTextureUsage = WGPUTextureUsage(WGPUFlags(a) or WGPUFlags(b))
template `or`*(a, b: WGPUShaderStage): WGPUShaderStage = WGPUShaderStage(WGPUFlags(a) or WGPUFlags(b))
template `or`*(a, b: WGPUColorWriteMask): WGPUColorWriteMask = WGPUColorWriteMask(WGPUFlags(a) or WGPUFlags(b))
template `or`*(a, b: WGPUMapMode): WGPUMapMode = WGPUMapMode(WGPUFlags(a) or WGPUFlags(b))
template `and`*(a, b: WGPUBufferUsage): WGPUBufferUsage = WGPUBufferUsage(WGPUFlags(a) and WGPUFlags(b))
template `and`*(a, b: WGPUTextureUsage): WGPUTextureUsage = WGPUTextureUsage(WGPUFlags(a) and WGPUFlags(b))
template `and`*(a, b: WGPUShaderStage): WGPUShaderStage = WGPUShaderStage(WGPUFlags(a) and WGPUFlags(b))
template `and`*(a, b: WGPUColorWriteMask): WGPUColorWriteMask = WGPUColorWriteMask(WGPUFlags(a) and WGPUFlags(b))

# Distinct enum equality (uint32-backed)
template defEq(T: typedesc): untyped =
  template `==`*(a, b: T): bool = uint32(a) == uint32(b)

defEq(WGPUTextureFormat)
defEq(WGPUTextureDimension)
defEq(WGPUTextureViewDimension)
defEq(WGPUTextureAspect)
defEq(WGPUAddressMode)
defEq(WGPUFilterMode)
defEq(WGPUMipmapFilterMode)
defEq(WGPUCompareFunction)
defEq(WGPUStencilOperation)
defEq(WGPUPrimitiveTopology)
defEq(WGPUFrontFace)
defEq(WGPUCullMode)
defEq(WGPUIndexFormat)
defEq(WGPUVertexStepMode)
defEq(WGPUVertexFormat)
defEq(WGPULoadOp)
defEq(WGPUStoreOp)
defEq(WGPUBlendOperation)
defEq(WGPUBlendFactor)
defEq(WGPUBufferBindingType)
defEq(WGPUSamplerBindingType)
defEq(WGPUTextureSampleType)
defEq(WGPUStorageTextureAccess)
defEq(WGPUOptionalBool)
defEq(WGPUCompositeAlphaMode)
defEq(WGPUPresentMode)
defEq(WGPUSurfaceGetCurrentTextureStatus)
defEq(WGPUSType)
defEq(WGPUCallbackMode)
defEq(WGPUWaitStatus)
defEq(WGPUFeatureLevel)
defEq(WGPUPowerPreference)
defEq(WGPUBackendType)
defEq(WGPUStatus)
defEq(WGPURequestAdapterStatus)
defEq(WGPURequestDeviceStatus)
defEq(WGPUQueueWorkDoneStatus)
defEq(WGPUErrorType)
defEq(WGPUDeviceLostReason)
defEq(WGPUAdapterType)

const
  WGPU_TRUE* = WGPUBool(1)
  WGPU_FALSE* = WGPUBool(0)
  WGPU_DEPTH_SLICE_UNDEFINED*: uint32 = 0xFFFF_FFFF'u32

  # Texture formats (webgpu.h)
  WGPUTextureFormat_Undefined* = WGPUTextureFormat(0x00000000'u32)
  WGPUTextureFormat_R8Unorm* = WGPUTextureFormat(0x00000001'u32)
  WGPUTextureFormat_RGBA8Unorm* = WGPUTextureFormat(0x00000016'u32)
  WGPUTextureFormat_RGBA8UnormSrgb* = WGPUTextureFormat(0x00000017'u32)
  WGPUTextureFormat_BGRA8Unorm* = WGPUTextureFormat(0x0000001B'u32)
  WGPUTextureFormat_BGRA8UnormSrgb* = WGPUTextureFormat(0x0000001C'u32)
  WGPUTextureFormat_Depth24Plus* = WGPUTextureFormat(0x0000002E'u32)
  WGPUTextureFormat_Depth24PlusStencil8* = WGPUTextureFormat(0x0000002F'u32)
  WGPUTextureFormat_Depth32Float* = WGPUTextureFormat(0x00000030'u32)

  # Buffer/texture/shader stage flags (uint64)
  WGPUBufferUsage_None* = WGPUBufferUsage(0x0000000000000000'u64)
  WGPUBufferUsage_MapRead* = WGPUBufferUsage(0x0000000000000001'u64)
  WGPUBufferUsage_MapWrite* = WGPUBufferUsage(0x0000000000000002'u64)
  WGPUBufferUsage_CopySrc* = WGPUBufferUsage(0x0000000000000004'u64)
  WGPUBufferUsage_CopyDst* = WGPUBufferUsage(0x0000000000000008'u64)
  WGPUBufferUsage_Index* = WGPUBufferUsage(0x0000000000000010'u64)
  WGPUBufferUsage_Vertex* = WGPUBufferUsage(0x0000000000000020'u64)
  WGPUBufferUsage_Uniform* = WGPUBufferUsage(0x0000000000000040'u64)
  WGPUBufferUsage_Storage* = WGPUBufferUsage(0x0000000000000080'u64)
  WGPUBufferUsage_Indirect* = WGPUBufferUsage(0x0000000000000100'u64)
  WGPUBufferUsage_QueryResolve* = WGPUBufferUsage(0x0000000000000200'u64)

  WGPUTextureUsage_None* = WGPUTextureUsage(0x0000000000000000'u64)
  WGPUTextureUsage_CopySrc* = WGPUTextureUsage(0x0000000000000001'u64)
  WGPUTextureUsage_CopyDst* = WGPUTextureUsage(0x0000000000000002'u64)
  WGPUTextureUsage_TextureBinding* = WGPUTextureUsage(0x0000000000000004'u64)
  WGPUTextureUsage_StorageBinding* = WGPUTextureUsage(0x0000000000000008'u64)
  WGPUTextureUsage_RenderAttachment* = WGPUTextureUsage(0x0000000000000010'u64)

  WGPUShaderStage_None* = WGPUShaderStage(0x0000000000000000'u64)
  WGPUShaderStage_Vertex* = WGPUShaderStage(0x0000000000000001'u64)
  WGPUShaderStage_Fragment* = WGPUShaderStage(0x0000000000000002'u64)
  WGPUShaderStage_Compute* = WGPUShaderStage(0x0000000000000004'u64)

  WGPUColorWriteMask_None* = WGPUColorWriteMask(0x0000000000000000'u64)
  WGPUColorWriteMask_Red* = WGPUColorWriteMask(0x0000000000000001'u64)
  WGPUColorWriteMask_Green* = WGPUColorWriteMask(0x0000000000000002'u64)
  WGPUColorWriteMask_Blue* = WGPUColorWriteMask(0x0000000000000004'u64)
  WGPUColorWriteMask_Alpha* = WGPUColorWriteMask(0x0000000000000008'u64)
  WGPUColorWriteMask_All* = WGPUColorWriteMask(0x000000000000000F'u64)

  # Texture/view/sampler enums
  WGPUTextureDimension_Undefined* = WGPUTextureDimension(0x00000000'u32)
  WGPUTextureDimension_1D* = WGPUTextureDimension(0x00000001'u32)
  WGPUTextureDimension_2D* = WGPUTextureDimension(0x00000002'u32)
  WGPUTextureDimension_3D* = WGPUTextureDimension(0x00000003'u32)

  WGPUTextureViewDimension_Undefined* = WGPUTextureViewDimension(0x00000000'u32)
  WGPUTextureViewDimension_1D* = WGPUTextureViewDimension(0x00000001'u32)
  WGPUTextureViewDimension_2D* = WGPUTextureViewDimension(0x00000002'u32)
  WGPUTextureViewDimension_2DArray* = WGPUTextureViewDimension(0x00000003'u32)
  WGPUTextureViewDimension_Cube* = WGPUTextureViewDimension(0x00000004'u32)
  WGPUTextureViewDimension_CubeArray* = WGPUTextureViewDimension(0x00000005'u32)
  WGPUTextureViewDimension_3D* = WGPUTextureViewDimension(0x00000006'u32)

  WGPUTextureAspect_Undefined* = WGPUTextureAspect(0x00000000'u32)
  WGPUTextureAspect_All* = WGPUTextureAspect(0x00000001'u32)
  WGPUTextureAspect_StencilOnly* = WGPUTextureAspect(0x00000002'u32)
  WGPUTextureAspect_DepthOnly* = WGPUTextureAspect(0x00000003'u32)

  WGPUAddressMode_Undefined* = WGPUAddressMode(0x00000000'u32)
  WGPUAddressMode_ClampToEdge* = WGPUAddressMode(0x00000001'u32)
  WGPUAddressMode_Repeat* = WGPUAddressMode(0x00000002'u32)
  WGPUAddressMode_MirrorRepeat* = WGPUAddressMode(0x00000003'u32)

  WGPUFilterMode_Undefined* = WGPUFilterMode(0x00000000'u32)
  WGPUFilterMode_Nearest* = WGPUFilterMode(0x00000001'u32)
  WGPUFilterMode_Linear* = WGPUFilterMode(0x00000002'u32)

  WGPUMipmapFilterMode_Undefined* = WGPUMipmapFilterMode(0x00000000'u32)
  WGPUMipmapFilterMode_Nearest* = WGPUMipmapFilterMode(0x00000001'u32)
  WGPUMipmapFilterMode_Linear* = WGPUMipmapFilterMode(0x00000002'u32)

  # Pipeline/render enums
  WGPUPrimitiveTopology_Undefined* = WGPUPrimitiveTopology(0x00000000'u32)
  WGPUPrimitiveTopology_PointList* = WGPUPrimitiveTopology(0x00000001'u32)
  WGPUPrimitiveTopology_LineList* = WGPUPrimitiveTopology(0x00000002'u32)
  WGPUPrimitiveTopology_LineStrip* = WGPUPrimitiveTopology(0x00000003'u32)
  WGPUPrimitiveTopology_TriangleList* = WGPUPrimitiveTopology(0x00000004'u32)
  WGPUPrimitiveTopology_TriangleStrip* = WGPUPrimitiveTopology(0x00000005'u32)

  WGPUFrontFace_Undefined* = WGPUFrontFace(0x00000000'u32)
  WGPUFrontFace_CCW* = WGPUFrontFace(0x00000001'u32)
  WGPUFrontFace_CW* = WGPUFrontFace(0x00000002'u32)

  WGPUCullMode_Undefined* = WGPUCullMode(0x00000000'u32)
  WGPUCullMode_None* = WGPUCullMode(0x00000001'u32)
  WGPUCullMode_Front* = WGPUCullMode(0x00000002'u32)
  WGPUCullMode_Back* = WGPUCullMode(0x00000003'u32)

  WGPUIndexFormat_Undefined* = WGPUIndexFormat(0x00000000'u32)
  WGPUIndexFormat_Uint16* = WGPUIndexFormat(0x00000001'u32)
  WGPUIndexFormat_Uint32* = WGPUIndexFormat(0x00000002'u32)

  WGPUVertexStepMode_Undefined* = WGPUVertexStepMode(0x00000000'u32)
  WGPUVertexStepMode_Vertex* = WGPUVertexStepMode(0x00000001'u32)
  WGPUVertexStepMode_Instance* = WGPUVertexStepMode(0x00000002'u32)

  WGPUVertexFormat_Undefined* = WGPUVertexFormat(0x00000000'u32)
  WGPUVertexFormat_Unorm8x4* = WGPUVertexFormat(0x00000009'u32)
  WGPUVertexFormat_Float32x2* = WGPUVertexFormat(0x0000001D'u32)
  WGPUVertexFormat_Float32x3* = WGPUVertexFormat(0x0000001E'u32)
  WGPUVertexFormat_Float32x4* = WGPUVertexFormat(0x0000001F'u32)

  WGPULoadOp_Undefined* = WGPULoadOp(0x00000000'u32)
  WGPULoadOp_Load* = WGPULoadOp(0x00000001'u32)
  WGPULoadOp_Clear* = WGPULoadOp(0x00000002'u32)
  WGPUStoreOp_Undefined* = WGPUStoreOp(0x00000000'u32)
  WGPUStoreOp_Store* = WGPUStoreOp(0x00000001'u32)
  WGPUStoreOp_Discard* = WGPUStoreOp(0x00000002'u32)

  WGPUCompareFunction_Undefined* = WGPUCompareFunction(0x00000000'u32)
  WGPUCompareFunction_Never* = WGPUCompareFunction(0x00000001'u32)
  WGPUCompareFunction_Less* = WGPUCompareFunction(0x00000002'u32)
  WGPUCompareFunction_Equal* = WGPUCompareFunction(0x00000003'u32)
  WGPUCompareFunction_LessEqual* = WGPUCompareFunction(0x00000004'u32)
  WGPUCompareFunction_Greater* = WGPUCompareFunction(0x00000005'u32)
  WGPUCompareFunction_NotEqual* = WGPUCompareFunction(0x00000006'u32)
  WGPUCompareFunction_GreaterEqual* = WGPUCompareFunction(0x00000007'u32)
  WGPUCompareFunction_Always* = WGPUCompareFunction(0x00000008'u32)

  WGPUStencilOperation_Undefined* = WGPUStencilOperation(0x00000000'u32)
  WGPUStencilOperation_Keep* = WGPUStencilOperation(0x00000001'u32)
  WGPUStencilOperation_Zero* = WGPUStencilOperation(0x00000002'u32)
  WGPUStencilOperation_Replace* = WGPUStencilOperation(0x00000003'u32)
  WGPUStencilOperation_Invert* = WGPUStencilOperation(0x00000004'u32)
  WGPUStencilOperation_IncrementClamp* = WGPUStencilOperation(0x00000005'u32)
  WGPUStencilOperation_DecrementClamp* = WGPUStencilOperation(0x00000006'u32)
  WGPUStencilOperation_IncrementWrap* = WGPUStencilOperation(0x00000007'u32)
  WGPUStencilOperation_DecrementWrap* = WGPUStencilOperation(0x00000008'u32)

  WGPUBlendOperation_Undefined* = WGPUBlendOperation(0x00000000'u32)
  WGPUBlendOperation_Add* = WGPUBlendOperation(0x00000001'u32)
  WGPUBlendOperation_Subtract* = WGPUBlendOperation(0x00000002'u32)
  WGPUBlendOperation_ReverseSubtract* = WGPUBlendOperation(0x00000003'u32)
  WGPUBlendOperation_Min* = WGPUBlendOperation(0x00000004'u32)
  WGPUBlendOperation_Max* = WGPUBlendOperation(0x00000005'u32)

  WGPUBlendFactor_Undefined* = WGPUBlendFactor(0x00000000'u32)
  WGPUBlendFactor_Zero* = WGPUBlendFactor(0x00000001'u32)
  WGPUBlendFactor_One* = WGPUBlendFactor(0x00000002'u32)
  WGPUBlendFactor_Src* = WGPUBlendFactor(0x00000003'u32)
  WGPUBlendFactor_OneMinusSrc* = WGPUBlendFactor(0x00000004'u32)
  WGPUBlendFactor_SrcAlpha* = WGPUBlendFactor(0x00000005'u32)
  WGPUBlendFactor_OneMinusSrcAlpha* = WGPUBlendFactor(0x00000006'u32)
  WGPUBlendFactor_Dst* = WGPUBlendFactor(0x00000007'u32)
  WGPUBlendFactor_OneMinusDst* = WGPUBlendFactor(0x00000008'u32)
  WGPUBlendFactor_DstAlpha* = WGPUBlendFactor(0x00000009'u32)
  WGPUBlendFactor_OneMinusDstAlpha* = WGPUBlendFactor(0x0000000A'u32)

  # Binding/layout enums
  WGPUBufferBindingType_BindingNotUsed* = WGPUBufferBindingType(0x00000000'u32)
  WGPUBufferBindingType_Undefined* = WGPUBufferBindingType(0x00000001'u32)
  WGPUBufferBindingType_Uniform* = WGPUBufferBindingType(0x00000002'u32)
  WGPUBufferBindingType_Storage* = WGPUBufferBindingType(0x00000003'u32)
  WGPUBufferBindingType_ReadOnlyStorage* = WGPUBufferBindingType(0x00000004'u32)

  WGPUSamplerBindingType_BindingNotUsed* = WGPUSamplerBindingType(0x00000000'u32)
  WGPUSamplerBindingType_Undefined* = WGPUSamplerBindingType(0x00000001'u32)
  WGPUSamplerBindingType_Filtering* = WGPUSamplerBindingType(0x00000002'u32)
  WGPUSamplerBindingType_NonFiltering* = WGPUSamplerBindingType(0x00000003'u32)
  WGPUSamplerBindingType_Comparison* = WGPUSamplerBindingType(0x00000004'u32)

  WGPUTextureSampleType_BindingNotUsed* = WGPUTextureSampleType(0x00000000'u32)
  WGPUTextureSampleType_Undefined* = WGPUTextureSampleType(0x00000001'u32)
  WGPUTextureSampleType_Float* = WGPUTextureSampleType(0x00000002'u32)
  WGPUTextureSampleType_UnfilterableFloat* = WGPUTextureSampleType(0x00000003'u32)
  WGPUTextureSampleType_Depth* = WGPUTextureSampleType(0x00000004'u32)
  WGPUTextureSampleType_Sint* = WGPUTextureSampleType(0x00000005'u32)
  WGPUTextureSampleType_Uint* = WGPUTextureSampleType(0x00000006'u32)

  WGPUStorageTextureAccess_BindingNotUsed* = WGPUStorageTextureAccess(0x00000000'u32)
  WGPUStorageTextureAccess_Undefined* = WGPUStorageTextureAccess(0x00000001'u32)
  WGPUStorageTextureAccess_WriteOnly* = WGPUStorageTextureAccess(0x00000002'u32)
  WGPUStorageTextureAccess_ReadOnly* = WGPUStorageTextureAccess(0x00000003'u32)
  WGPUStorageTextureAccess_ReadWrite* = WGPUStorageTextureAccess(0x00000004'u32)

  # Misc enums
  WGPUOptionalBool_False* = WGPUOptionalBool(0x00000000'u32)
  WGPUOptionalBool_True* = WGPUOptionalBool(0x00000001'u32)
  WGPUOptionalBool_Undefined* = WGPUOptionalBool(0x00000002'u32)

  WGPUCompositeAlphaMode_Auto* = WGPUCompositeAlphaMode(0x00000000'u32)
  WGPUCompositeAlphaMode_Opaque* = WGPUCompositeAlphaMode(0x00000001'u32)
  WGPUCompositeAlphaMode_Premultiplied* = WGPUCompositeAlphaMode(0x00000002'u32)
  WGPUCompositeAlphaMode_Unpremultiplied* = WGPUCompositeAlphaMode(0x00000003'u32)
  WGPUCompositeAlphaMode_Inherit* = WGPUCompositeAlphaMode(0x00000004'u32)

  WGPUPresentMode_Undefined* = WGPUPresentMode(0x00000000'u32)
  WGPUPresentMode_Fifo* = WGPUPresentMode(0x00000001'u32)
  WGPUPresentMode_FifoRelaxed* = WGPUPresentMode(0x00000002'u32)
  WGPUPresentMode_Immediate* = WGPUPresentMode(0x00000003'u32)
  WGPUPresentMode_Mailbox* = WGPUPresentMode(0x00000004'u32)

  WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal* = WGPUSurfaceGetCurrentTextureStatus(0x00000001'u32)
  WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal* = WGPUSurfaceGetCurrentTextureStatus(0x00000002'u32)
  WGPUSurfaceGetCurrentTextureStatus_Timeout* = WGPUSurfaceGetCurrentTextureStatus(0x00000003'u32)
  WGPUSurfaceGetCurrentTextureStatus_Outdated* = WGPUSurfaceGetCurrentTextureStatus(0x00000004'u32)
  WGPUSurfaceGetCurrentTextureStatus_Lost* = WGPUSurfaceGetCurrentTextureStatus(0x00000005'u32)
  WGPUSurfaceGetCurrentTextureStatus_Error* = WGPUSurfaceGetCurrentTextureStatus(0x00000006'u32)

  WGPUStatus_Success* = WGPUStatus(0x00000001'u32)
  WGPUStatus_Error* = WGPUStatus(0x00000002'u32)

  WGPUSType_ShaderSourceSPIRV* = WGPUSType(0x00000001'u32)
  WGPUSType_ShaderSourceWGSL* = WGPUSType(0x00000002'u32)
  WGPUSType_RenderPassMaxDrawCount* = WGPUSType(0x00000003'u32)
  WGPUSType_SurfaceSourceMetalLayer* = WGPUSType(0x00000004'u32)
  WGPUSType_SurfaceSourceWindowsHWND* = WGPUSType(0x00000005'u32)
  WGPUSType_SurfaceSourceXlibWindow* = WGPUSType(0x00000006'u32)
  WGPUSType_SurfaceSourceWaylandSurface* = WGPUSType(0x00000007'u32)
  WGPUSType_SurfaceSourceAndroidNativeWindow* = WGPUSType(0x00000008'u32)
  WGPUSType_SurfaceSourceXCBWindow* = WGPUSType(0x00000009'u32)

  WGPUCallbackMode_WaitAnyOnly* = WGPUCallbackMode(0x00000001'u32)
  WGPUCallbackMode_AllowProcessEvents* = WGPUCallbackMode(0x00000002'u32)
  WGPUCallbackMode_AllowSpontaneous* = WGPUCallbackMode(0x00000003'u32)

  WGPUWaitStatus_Success* = WGPUWaitStatus(0x00000001'u32)
  WGPUWaitStatus_TimedOut* = WGPUWaitStatus(0x00000002'u32)
  WGPUWaitStatus_Error* = WGPUWaitStatus(0x00000003'u32)

  WGPUFeatureLevel_Undefined* = WGPUFeatureLevel(0x00000000'u32)
  WGPUFeatureLevel_Compatibility* = WGPUFeatureLevel(0x00000001'u32)
  WGPUFeatureLevel_Core* = WGPUFeatureLevel(0x00000002'u32)

  WGPUPowerPreference_Undefined* = WGPUPowerPreference(0x00000000'u32)
  WGPUPowerPreference_LowPower* = WGPUPowerPreference(0x00000001'u32)
  WGPUPowerPreference_HighPerformance* = WGPUPowerPreference(0x00000002'u32)

  WGPUBackendType_Undefined* = WGPUBackendType(0x00000000'u32)
  WGPUBackendType_Null* = WGPUBackendType(0x00000001'u32)
  WGPUBackendType_WebGPU* = WGPUBackendType(0x00000002'u32)
  WGPUBackendType_D3D11* = WGPUBackendType(0x00000003'u32)
  WGPUBackendType_D3D12* = WGPUBackendType(0x00000004'u32)
  WGPUBackendType_Metal* = WGPUBackendType(0x00000005'u32)
  WGPUBackendType_Vulkan* = WGPUBackendType(0x00000006'u32)
  WGPUBackendType_OpenGL* = WGPUBackendType(0x00000007'u32)
  WGPUBackendType_OpenGLES* = WGPUBackendType(0x00000008'u32)

  WGPURequestAdapterStatus_Success* = WGPURequestAdapterStatus(0x00000001'u32)
  WGPURequestAdapterStatus_CallbackCancelled* = WGPURequestAdapterStatus(0x00000002'u32)
  WGPURequestAdapterStatus_Unavailable* = WGPURequestAdapterStatus(0x00000003'u32)
  WGPURequestAdapterStatus_Error* = WGPURequestAdapterStatus(0x00000004'u32)

  WGPURequestDeviceStatus_Success* = WGPURequestDeviceStatus(0x00000001'u32)
  WGPURequestDeviceStatus_CallbackCancelled* = WGPURequestDeviceStatus(0x00000002'u32)
  WGPURequestDeviceStatus_Error* = WGPURequestDeviceStatus(0x00000003'u32)

  WGPUQueueWorkDoneStatus_Success* = WGPUQueueWorkDoneStatus(0x00000001'u32)
  WGPUQueueWorkDoneStatus_CallbackCancelled* = WGPUQueueWorkDoneStatus(0x00000002'u32)
  WGPUQueueWorkDoneStatus_Error* = WGPUQueueWorkDoneStatus(0x00000003'u32)

type
  WgCanvasContext* = object ## Mirrors tvg::WgCanvas::Context (thorvg.h)
    instance*: pointer      ## WGPUInstance
    adapter*: pointer       ## WGPUAdapter
    device*: pointer        ## WGPUDevice
