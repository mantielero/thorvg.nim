## Render pipelines and shader/layout setup for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgPipelines.h/.cpp.
## Creates render pipelines, shader modules and pipeline layouts used by stencil,
## shape/image/scene rendering, composition/blending and effects.

import ../../core/types
import ./wg_ffi
import ./wg_common
import ./shader_src
import ./render_data

const
  shaderBlendNames*: array[18, cstring] = [
    cstring"fs_main_Normal",
    cstring"fs_main_Multiply",
    cstring"fs_main",          # Screen
    cstring"fs_main_Overlay",
    cstring"fs_main_Darken",
    cstring"fs_main_Lighten",
    cstring"fs_main_ColorDodge",
    cstring"fs_main_ColorBurn",
    cstring"fs_main_HardLight",
    cstring"fs_main_SoftLight",
    cstring"fs_main_Difference",
    cstring"fs_main",          # Exclusion
    cstring"fs_main_Hue",
    cstring"fs_main_Saturation",
    cstring"fs_main_Color",
    cstring"fs_main_Luminosity",
    cstring"fs_main",          # Add
    cstring"fs_main_Normal"    # reserved Hardmix padding
  ]

# Vertex attributes/layouts (mirrors upstream static definitions)
var vertexAttributePos* = WGPUVertexAttribute(format: WGPUVertexFormat_Float32x2, offset: 0'u64, shaderLocation: 0'u32)
var vertexAttributeColor* = WGPUVertexAttribute(format: WGPUVertexFormat_Unorm8x4, offset: 0'u64, shaderLocation: 1'u32)
var vertexAttributeTex* = WGPUVertexAttribute(format: WGPUVertexFormat_Float32x2, offset: 0'u64, shaderLocation: 1'u32)
var vertexAttributeAdjust* = WGPUVertexAttribute(format: WGPUVertexFormat_Float32x4, offset: 0'u64, shaderLocation: 2'u32)
var vertexAttributeMaskTex* = WGPUVertexAttribute(format: WGPUVertexFormat_Float32x2, offset: 0'u64, shaderLocation: 3'u32)

var vertexAttributesPosArr* = [vertexAttributePos]
var vertexAttributesColorArr* = [vertexAttributeColor]
var vertexAttributesTexArr* = [vertexAttributeTex]

var vertexBufferLayoutPos* = WGPUVertexBufferLayout(stepMode: WGPUVertexStepMode_Vertex, arrayStride: 8'u64, attributeCount: 1, attributes: addr vertexAttributesPosArr[0])
var vertexBufferLayoutColor* = WGPUVertexBufferLayout(stepMode: WGPUVertexStepMode_Instance, arrayStride: 4'u64, attributeCount: 1, attributes: addr vertexAttributesColorArr[0]) # sizeof(RenderColor)=4
var vertexBufferLayoutColorBatch* = WGPUVertexBufferLayout(stepMode: WGPUVertexStepMode_Vertex, arrayStride: 4'u64, attributeCount: 1, attributes: addr vertexAttributesColorArr[0])
var vertexBufferLayoutTex* = WGPUVertexBufferLayout(stepMode: WGPUVertexStepMode_Vertex, arrayStride: 8'u64, attributeCount: 1, attributes: addr vertexAttributesTexArr[0])
var vertexBufferLayoutAdjust* = WGPUVertexBufferLayout(stepMode: WGPUVertexStepMode_Instance, arrayStride: 16'u64, attributeCount: 1, attributes: addr vertexAttributeAdjust)
var vertexBufferLayoutMaskTex* = WGPUVertexBufferLayout(stepMode: WGPUVertexStepMode_Vertex, arrayStride: 8'u64, attributeCount: 1, attributes: addr vertexAttributeMaskTex)

var vertexBufferLayoutsSolidArr* = [vertexBufferLayoutAdjust, vertexBufferLayoutPos, vertexBufferLayoutColor]
var vertexBufferLayoutsSolidBatchArr* = [vertexBufferLayoutAdjust, vertexBufferLayoutPos, vertexBufferLayoutColorBatch]
var vertexBufferLayoutsShapeArr* = [vertexBufferLayoutAdjust, vertexBufferLayoutPos]
var vertexBufferLayoutsImageArr* = [vertexBufferLayoutAdjust, vertexBufferLayoutPos, vertexBufferLayoutTex]
var vertexBufferLayoutsComposeArr* = [vertexBufferLayoutAdjust, vertexBufferLayoutPos, vertexBufferLayoutTex, vertexBufferLayoutMaskTex]

proc depthOnlyState*(compare: WGPUCompareFunction): WGPUDepthStencilState =
  let stencil = WGPUStencilFaceState(
    compare: WGPUCompareFunction_Always,
    failOp: WGPUStencilOperation_Keep,
    depthFailOp: WGPUStencilOperation_Keep,
    passOp: WGPUStencilOperation_Keep
  )
  WGPUDepthStencilState(
    format: WGPUTextureFormat_Depth24PlusStencil8,
    depthWriteEnabled: WGPUOptionalBool_False,
    depthCompare: compare,
    stencilFront: stencil,
    stencilBack: stencil,
    stencilReadMask: 0'u32,
    stencilWriteMask: 0'u32
  )

type
  WgPipelines* = object
    # stencil markup
    nonzero*: WGPURenderPipeline
    evenodd*: WGPURenderPipeline
    direct*: WGPURenderPipeline
    # clip path markup
    copyStencilToDepth*: WGPURenderPipeline        # depth 0.50, clear stencil
    copyStencilToDepthInterm*: WGPURenderPipeline  # depth 0.75, clear stencil
    copyDepthToStencil*: WGPURenderPipeline        # depth 0.50 and 0.75, update stencil
    mergeDepthStencil*: WGPURenderPipeline         # depth 0.75, update stencil
    clearDepth*: WGPURenderPipeline                # depth 1.00, clear stencil
    # normal blend
    solid*: WGPURenderPipeline
    radial*: WGPURenderPipeline
    linear*: WGPURenderPipeline
    conic*: WGPURenderPipeline
    solidConv*: WGPURenderPipeline
    solidBatch*: WGPURenderPipeline
    solidStencilBatch*: WGPURenderPipeline
    radialConv*: WGPURenderPipeline
    linearConv*: WGPURenderPipeline
    conicConv*: WGPURenderPipeline
    strokeClip*: array[4, WGPURenderPipeline]
    image*: WGPURenderPipeline
    imageDirect*: WGPURenderPipeline
    scene*: WGPURenderPipeline
    # custom blend
    solidBlends*: array[18, WGPURenderPipeline]
    radialBlends*: array[18, WGPURenderPipeline]
    linearBlends*: array[18, WGPURenderPipeline]
    conicBlends*: array[18, WGPURenderPipeline]
    imageBlends*: array[18, WGPURenderPipeline]
    sceneBlends*: array[18, WGPURenderPipeline]
    # compose
    sceneCompose*: array[11, WGPURenderPipeline]
    # blit
    blit*: WGPURenderPipeline
    blitUnpremultiplied*: WGPURenderPipeline
    # effects
    effectGaussianVert*: WGPURenderPipeline
    effectGaussianHorz*: WGPURenderPipeline
    effectDropShadow*: WGPURenderPipeline
    effectFill*: WGPURenderPipeline
    effectTint*: WGPURenderPipeline
    effectTritone*: WGPURenderPipeline
    effectMotionBlur*: WGPURenderPipeline

    # shaders helpers
    shaderStencil*: WGPUShaderModule
    shaderDepth*: WGPUShaderModule
    # shaders normal blend
    shaderSolid*: WGPUShaderModule
    shaderRadial*: WGPUShaderModule
    shaderLinear*: WGPUShaderModule
    shaderConic*: WGPUShaderModule
    shaderImage*: WGPUShaderModule
    shaderScene*: WGPUShaderModule
    # shaders custom blend
    shaderSolidBlend*: WGPUShaderModule
    shaderRadialBlend*: WGPUShaderModule
    shaderLinearBlend*: WGPUShaderModule
    shaderConicBlend*: WGPUShaderModule
    shaderImageBlend*: WGPUShaderModule
    shaderSceneBlend*: WGPUShaderModule
    # shader scene compose
    shaderSceneCompose*: WGPUShaderModule
    # shader blit
    shaderBlit*: WGPUShaderModule
    # shader effects
    shaderShadow*: WGPUShaderModule
    shaderEffects*: WGPUShaderModule

    # layouts helpers
    layoutStencil*: WGPUPipelineLayout
    layoutDepth*: WGPUPipelineLayout
    # layouts normal blend
    layoutSolid*: WGPUPipelineLayout
    layoutGradient*: WGPUPipelineLayout
    layoutImage*: WGPUPipelineLayout
    layoutScene*: WGPUPipelineLayout
    # layouts custom blend
    layoutSolidBlend*: WGPUPipelineLayout
    layoutGradientBlend*: WGPUPipelineLayout
    layoutImageBlend*: WGPUPipelineLayout
    layoutSceneBlend*: WGPUPipelineLayout
    # layouts scene compose
    layoutSceneCompose*: WGPUPipelineLayout
    # layouts blit
    layoutBlit*: WGPUPipelineLayout
    # layouts effects
    layoutShadow*: WGPUPipelineLayout
    layoutEffects*: WGPUPipelineLayout

proc createShaderModule*(p: var WgPipelines; device: WGPUDevice; label, code: cstring): WGPUShaderModule =
  var shaderSourceWGSL = WGPUShaderSourceWGSL(
    chain: WGPUChainedStruct(sType: WGPUSType_ShaderSourceWGSL),
    code: WGPUStringView(data: code, length: WGPU_STRLEN)
  )
  var desc = WGPUShaderModuleDescriptor(
    nextInChain: cast[ptr WGPUChainedStruct](addr shaderSourceWGSL),
    label: WGPUStringView(data: label, length: WGPU_STRLEN)
  )
  wgpuDeviceCreateShaderModule(device, addr desc)

proc createPipelineLayout*(p: var WgPipelines; device: WGPUDevice; bindGroupLayouts: ptr WGPUBindGroupLayout; count: uint32): WGPUPipelineLayout =
  var desc = WGPUPipelineLayoutDescriptor(
    bindGroupLayoutCount: csize_t(count),
    bindGroupLayouts: bindGroupLayouts
  )
  wgpuDeviceCreatePipelineLayout(device, addr desc)

proc createRenderPipeline*(p: var WgPipelines; device: WGPUDevice; pipelineLabel: cstring;
                           shaderModule: WGPUShaderModule; vsEntryPoint, fsEntryPoint: cstring;
                           pipelineLayout: WGPUPipelineLayout;
                           vertexBufferLayouts: ptr WGPUVertexBufferLayout; vertexBufferLayoutsCount: uint32;
                           writeMask: WGPUColorWriteMask; colorTargetFormat: WGPUTextureFormat;
                           blendState: var WGPUBlendState; depthStencilState: var WGPUDepthStencilState;
                           multisampleState: WGPUMultisampleState): WGPURenderPipeline =
  var colorTargetState = WGPUColorTargetState(
    format: colorTargetFormat,
    blend: addr blendState,
    writeMask: writeMask
  )
  var primitiveState = WGPUPrimitiveState(topology: WGPUPrimitiveTopology_TriangleList)
  var vertexState = WGPUVertexState(
    module: shaderModule,
    entryPoint: WGPUStringView(data: vsEntryPoint, length: WGPU_STRLEN),
    bufferCount: csize_t(vertexBufferLayoutsCount),
    buffers: vertexBufferLayouts
  )
  var fragmentState = WGPUFragmentState(
    module: shaderModule,
    entryPoint: WGPUStringView(data: fsEntryPoint, length: WGPU_STRLEN),
    targetCount: 1,
    targets: addr colorTargetState
  )
  var desc = WGPURenderPipelineDescriptor(
    label: WGPUStringView(data: pipelineLabel, length: WGPU_STRLEN),
    layout: pipelineLayout,
    vertex: vertexState,
    primitive: primitiveState,
    depthStencil: addr depthStencilState,
    multisample: multisampleState,
    fragment: addr fragmentState
  )
  wgpuDeviceCreateRenderPipeline(device, addr desc)

proc releaseRenderPipeline*(p: var WgPipelines; renderPipeline: var WGPURenderPipeline) =
  if not isNil(renderPipeline):
    wgpuRenderPipelineRelease(renderPipeline)
    renderPipeline = WGPURenderPipeline(nil)

proc releasePipelineLayout*(p: var WgPipelines; pipelineLayout: var WGPUPipelineLayout) =
  if not isNil(pipelineLayout):
    wgpuPipelineLayoutRelease(pipelineLayout)
    pipelineLayout = WGPUPipelineLayout(nil)

proc releaseShaderModule*(p: var WgPipelines; shaderModule: var WGPUShaderModule) =
  if not isNil(shaderModule):
    wgpuShaderModuleRelease(shaderModule)
    shaderModule = WGPUShaderModule(nil)

proc makeDepthStencilState*(p: var WgPipelines; depthCompare: WGPUCompareFunction; depthWriteEnabled: WGPUOptionalBool;
                            stencilFunctionFrnt: WGPUCompareFunction; stencilOperationFrnt: WGPUStencilOperation;
                            stencilFunctionBack: WGPUCompareFunction; stencilOperationBack: WGPUStencilOperation): WGPUDepthStencilState =
  WGPUDepthStencilState(
    format: WGPUTextureFormat_Depth24PlusStencil8,
    depthWriteEnabled: depthWriteEnabled,
    depthCompare: depthCompare,
    stencilFront: WGPUStencilFaceState(compare: stencilFunctionFrnt, failOp: stencilOperationFrnt, depthFailOp: WGPUStencilOperation_Zero, passOp: stencilOperationFrnt),
    stencilBack:  WGPUStencilFaceState(compare: stencilFunctionBack, failOp: stencilOperationBack, depthFailOp: WGPUStencilOperation_Zero, passOp: stencilOperationBack),
    stencilReadMask: 0xFFFFFFFF'u32,
    stencilWriteMask: 0xFFFFFFFF'u32
  )

proc makeDepthStencilState*(p: var WgPipelines; depthCompare: WGPUCompareFunction; depthWriteEnabled: WGPUOptionalBool;
                            stencilFunction: WGPUCompareFunction; stencilOperation: WGPUStencilOperation): WGPUDepthStencilState =
  p.makeDepthStencilState(depthCompare, depthWriteEnabled, stencilFunction, stencilOperation, stencilFunction, stencilOperation)

proc createBlendPipeline*(p: var WgPipelines; ctx: var WgContext; pipelineLabel: cstring;
                          shaderModuleIn: WGPUShaderModule; shaderModuleBlend: var WGPUShaderModule;
                          shaderBlendLabel, shaderBlendCode: cstring; blendMethod: BlendMethod;
                          pipelineLayout, pipelineLayoutBlend: WGPUPipelineLayout;
                          vertexBufferLayouts: ptr WGPUVertexBufferLayout; vertexBufferLayoutsCount: uint32;
                          stencilCompare: WGPUCompareFunction): WGPURenderPipeline =
  var shaderModule = shaderModuleIn
  var layoutOut = pipelineLayout
  var blendComponentSrc = WGPUBlendComponent(operation: WGPUBlendOperation_Add, srcFactor: WGPUBlendFactor_One, dstFactor: WGPUBlendFactor_Zero)
  var blendState = WGPUBlendState(color: blendComponentSrc, alpha: blendComponentSrc)
  case blendMethod
  of BlendMethod.Screen, BlendMethod.Exclusion:
    blendState.color.srcFactor = if blendMethod == BlendMethod.Screen: WGPUBlendFactor_One else: WGPUBlendFactor_OneMinusDst
    blendState.color.dstFactor = WGPUBlendFactor_OneMinusSrc
    blendState.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
  of BlendMethod.Add:
    blendState.color.dstFactor = WGPUBlendFactor_One
    blendState.alpha.dstFactor = WGPUBlendFactor_One
  else:
    if isNil(shaderModuleBlend):
      var shaderSourceBuff = $shaderBlendCode
      if pipelineLayoutBlend == p.layoutGradientBlend:
        shaderSourceBuff.add $cShaderSrc_Gradient_Blend
        shaderSourceBuff.add $cShaderSrc_BlendSourceOver
      shaderSourceBuff.add $cShaderSrc_BlendFuncs
      shaderModuleBlend = p.createShaderModule(ctx.device, shaderBlendLabel, cstring(shaderSourceBuff))
    shaderModule = shaderModuleBlend
    layoutOut = pipelineLayoutBlend

  var depthStencilState = p.makeDepthStencilState(
    WGPUCompareFunction_Always, WGPUOptionalBool_False,
    stencilCompare, WGPUStencilOperation_Zero)
  var multisampleState = WGPUMultisampleState(count: 4'u32, mask: 0xFFFFFFFF'u32, alphaToCoverageEnabled: 0'u32)
  let fsName = shaderBlendNames[ord(blendMethod)]
  p.createRenderPipeline(ctx.device, pipelineLabel, shaderModule, cstring"vs_main", fsName,
                         layoutOut, vertexBufferLayouts, vertexBufferLayoutsCount,
                         WGPUColorWriteMask_All, WGPUTextureFormat_RGBA8Unorm, blendState,
                         depthStencilState, multisampleState)

proc solidBlend*(p: var WgPipelines; ctx: var WgContext; blendMethod: BlendMethod): WGPURenderPipeline =
  let idx = ord(blendMethod)
  if idx >= 0 and idx < p.solidBlends.len:
    if isNil(p.solidBlends[idx]):
      p.solidBlends[idx] = p.createBlendPipeline(ctx, cstring"The render pipeline solid blend",
        p.shaderSolid, p.shaderSolidBlend, cstring"The shader blend solid", cstring(cShaderSrc_Solid_Blend),
        blendMethod, p.layoutSolid, p.layoutSolidBlend, addr vertexBufferLayoutsSolidArr[0], 3'u32, WGPUCompareFunction_NotEqual)
    result = p.solidBlends[idx]

proc radialBlend*(p: var WgPipelines; ctx: var WgContext; blendMethod: BlendMethod): WGPURenderPipeline =
  let idx = ord(blendMethod)
  if idx >= 0 and idx < p.radialBlends.len:
    if isNil(p.radialBlends[idx]):
      p.radialBlends[idx] = p.createBlendPipeline(ctx, cstring"The render pipeline radial blend",
        p.shaderRadial, p.shaderRadialBlend, cstring"The shader blend radial", cstring(cShaderSrc_Radial_Blend),
        blendMethod, p.layoutGradient, p.layoutGradientBlend, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUCompareFunction_NotEqual)
    result = p.radialBlends[idx]

proc linearBlend*(p: var WgPipelines; ctx: var WgContext; blendMethod: BlendMethod): WGPURenderPipeline =
  let idx = ord(blendMethod)
  if idx >= 0 and idx < p.linearBlends.len:
    if isNil(p.linearBlends[idx]):
      p.linearBlends[idx] = p.createBlendPipeline(ctx, cstring"The render pipeline linear blend",
        p.shaderLinear, p.shaderLinearBlend, cstring"The shader blend linear", cstring(cShaderSrc_Linear_Blend),
        blendMethod, p.layoutGradient, p.layoutGradientBlend, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUCompareFunction_NotEqual)
    result = p.linearBlends[idx]

proc conicBlend*(p: var WgPipelines; ctx: var WgContext; blendMethod: BlendMethod): WGPURenderPipeline =
  let idx = ord(blendMethod)
  if idx >= 0 and idx < p.conicBlends.len:
    if isNil(p.conicBlends[idx]):
      p.conicBlends[idx] = p.createBlendPipeline(ctx, cstring"The render pipeline conic blend",
        p.shaderConic, p.shaderConicBlend, cstring"The shader blend conic", cstring(cShaderSrc_Conic_Blend),
        blendMethod, p.layoutGradient, p.layoutGradientBlend, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUCompareFunction_NotEqual)
    result = p.conicBlends[idx]

proc imageBlend*(p: var WgPipelines; ctx: var WgContext; blendMethod: BlendMethod): WGPURenderPipeline =
  let idx = ord(blendMethod)
  if idx >= 0 and idx < p.imageBlends.len:
    if isNil(p.imageBlends[idx]):
      p.imageBlends[idx] = p.createBlendPipeline(ctx, cstring"The render pipeline image blend",
        p.shaderImage, p.shaderImageBlend, cstring"The shader blend image", cstring(cShaderSrc_Image_Blend),
        blendMethod, p.layoutImage, p.layoutImageBlend, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUCompareFunction_NotEqual)
    result = p.imageBlends[idx]

proc sceneBlend*(p: var WgPipelines; ctx: var WgContext; blendMethod: BlendMethod): WGPURenderPipeline =
  let idx = ord(blendMethod)
  if idx >= 0 and idx < p.sceneBlends.len:
    if isNil(p.sceneBlends[idx]):
      p.sceneBlends[idx] = p.createBlendPipeline(ctx, cstring"The render pipeline scene blend",
        p.shaderScene, p.shaderSceneBlend, cstring"The shader blend scene", cstring(cShaderSrc_Scene_Blend),
        blendMethod, p.layoutScene, p.layoutSceneBlend, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUCompareFunction_Always)
    result = p.sceneBlends[idx]

proc clippedStroke*(p: var WgPipelines; ctx: var WgContext; t: WgRenderSettingsType): WGPURenderPipeline =
  let idx = ord(t) - 1
  if idx < 0 or idx >= p.strokeClip.len: return WGPURenderPipeline(nil)
  if isNil(p.strokeClip[idx]):
    let shaders = [p.shaderSolid, p.shaderLinear, p.shaderRadial, p.shaderConic]
    let solid = (t == WgRenderSettingsType.rstSolid)
    var blendComponent = WGPUBlendComponent(operation: WGPUBlendOperation_Add, srcFactor: WGPUBlendFactor_One, dstFactor: WGPUBlendFactor_OneMinusSrcAlpha)
    var blendState = WGPUBlendState(color: blendComponent, alpha: blendComponent)
    var depthStencilState = depthOnlyState(WGPUCompareFunction_Equal)
    var multisampleState = WGPUMultisampleState(count: 4'u32, mask: 0xFFFFFFFF'u32, alphaToCoverageEnabled: 0'u32)
    let layout = if solid: p.layoutSolid else: p.layoutGradient
    let vbl = if solid: addr vertexBufferLayoutsSolidArr[0] else: addr vertexBufferLayoutsShapeArr[0]
    let vblCount: uint32 = if solid: 3'u32 else: 2'u32
    p.strokeClip[idx] = p.createRenderPipeline(ctx.device, cstring"The render pipeline clipped stroke",
      shaders[idx], cstring"vs_main", cstring"fs_main", layout, vbl, vblCount,
      WGPUColorWriteMask_All, WGPUTextureFormat_RGBA8Unorm, blendState, depthStencilState, multisampleState)
  p.strokeClip[idx]

proc initialize*(p: var WgPipelines; ctx: var WgContext) =
  let device = ctx.device
  let offscreenTargetFormat = WGPUTextureFormat_RGBA8Unorm

  var multisampleState = WGPUMultisampleState(count: 4'u32, mask: 0xFFFFFFFF'u32, alphaToCoverageEnabled: 0'u32)
  var multisampleStateX1 = WGPUMultisampleState(count: 1'u32, mask: 0xFFFFFFFF'u32, alphaToCoverageEnabled: 0'u32)

  var blendComponentSrc = WGPUBlendComponent(operation: WGPUBlendOperation_Add, srcFactor: WGPUBlendFactor_One, dstFactor: WGPUBlendFactor_Zero)
  var blendComponentNrm = WGPUBlendComponent(operation: WGPUBlendOperation_Add, srcFactor: WGPUBlendFactor_One, dstFactor: WGPUBlendFactor_OneMinusSrcAlpha)
  var blendStateSrc = WGPUBlendState(color: blendComponentSrc, alpha: blendComponentSrc)
  var blendStateNrm = WGPUBlendState(color: blendComponentNrm, alpha: blendComponentNrm)

  let layouts = ctx.layouts

  # bind group layouts helpers
  var bglStencil = [layouts.layoutBuffer1Un]
  var bglDepth = [layouts.layoutBuffer1Un, layouts.layoutBuffer1Un]

  # normal blend
  var bglSolid = [layouts.layoutBuffer1Un]
  var bglGradient = [layouts.layoutBuffer1Un, layouts.layoutBuffer1Un, layouts.layoutTexSampled]
  var bglImage = [layouts.layoutBuffer1Un, layouts.layoutBuffer1Un, layouts.layoutTexSampled]
  var bglScene = [layouts.layoutTexSampled, layouts.layoutBuffer1Un]

  # custom blend
  var bglSolidBlend = [layouts.layoutBuffer1Un, layouts.layoutTexSampled]
  var bglGradientBlend = [layouts.layoutBuffer1Un, layouts.layoutBuffer1Un, layouts.layoutTexSampled, layouts.layoutTexSampled]
  var bglImageBlend = [layouts.layoutBuffer1Un, layouts.layoutBuffer1Un, layouts.layoutTexSampled, layouts.layoutTexSampled]
  var bglSceneBlend = [layouts.layoutTexSampled, layouts.layoutTexSampled, layouts.layoutBuffer1Un]

  var bglSceneCompose = [layouts.layoutTexSampled, layouts.layoutTexSampled]
  var bglBlit = [layouts.layoutTexSampled]
  var bglShadow = [layouts.layoutTexSampled, layouts.layoutTexSampled, layouts.layoutBuffer1Un]
  var bglEffects = [layouts.layoutTexSampled, layouts.layoutBuffer1Un]

  # depth stencil states
  var depthStencilStateNonZero = p.makeDepthStencilState(WGPUCompareFunction_Always, WGPUOptionalBool_False,
    WGPUCompareFunction_Always, WGPUStencilOperation_IncrementWrap, WGPUCompareFunction_Always, WGPUStencilOperation_DecrementWrap)
  var depthStencilStateEvenOdd = p.makeDepthStencilState(WGPUCompareFunction_Always, WGPUOptionalBool_False,
    WGPUCompareFunction_Always, WGPUStencilOperation_Invert)
  var depthStencilStateDirect = p.makeDepthStencilState(WGPUCompareFunction_Always, WGPUOptionalBool_False,
    WGPUCompareFunction_Always, WGPUStencilOperation_Replace)
  var depthStencilStateCopyStencilToDepth = p.makeDepthStencilState(WGPUCompareFunction_Always, WGPUOptionalBool_True,
    WGPUCompareFunction_NotEqual, WGPUStencilOperation_Zero)
  var depthStencilStateCopyStencilToDepthInt = p.makeDepthStencilState(WGPUCompareFunction_Greater, WGPUOptionalBool_True,
    WGPUCompareFunction_NotEqual, WGPUStencilOperation_Zero)
  var depthStencilStateCopyDepthToStencil = p.makeDepthStencilState(WGPUCompareFunction_Equal, WGPUOptionalBool_False,
    WGPUCompareFunction_Always, WGPUStencilOperation_Replace)
  var depthStencilStateMergeDepthStencil = p.makeDepthStencilState(WGPUCompareFunction_Equal, WGPUOptionalBool_True,
    WGPUCompareFunction_Always, WGPUStencilOperation_Keep)
  var depthStencilStateClearDepth = p.makeDepthStencilState(WGPUCompareFunction_Always, WGPUOptionalBool_True,
    WGPUCompareFunction_Always, WGPUStencilOperation_Keep)
  var depthStencilStateShape = p.makeDepthStencilState(WGPUCompareFunction_Always, WGPUOptionalBool_False,
    WGPUCompareFunction_NotEqual, WGPUStencilOperation_Zero)
  var depthStencilStateScene = p.makeDepthStencilState(WGPUCompareFunction_Always, WGPUOptionalBool_False,
    WGPUCompareFunction_Always, WGPUStencilOperation_Zero)
  var depthStencilStateConv = depthOnlyState(WGPUCompareFunction_Always)

  # shaders
  p.shaderStencil = p.createShaderModule(device, cstring"The shader stencil", cstring(cShaderSrc_Stencil))
  p.shaderDepth = p.createShaderModule(device, cstring"The shader depth", cstring(cShaderSrc_Depth))
  p.shaderSolid = p.createShaderModule(device, cstring"The shader solid", cstring(cShaderSrc_Solid))
  p.shaderRadial = p.createShaderModule(device, cstring"The shader radial", cstring(cShaderSrc_Radial))
  p.shaderLinear = p.createShaderModule(device, cstring"The shader linear", cstring(cShaderSrc_Linear))
  p.shaderConic = p.createShaderModule(device, cstring"The shader conic", cstring(cShaderSrc_Conic))
  p.shaderImage = p.createShaderModule(device, cstring"The shader image", cstring(cShaderSrc_Image))
  p.shaderScene = p.createShaderModule(device, cstring"The shader scene", cstring(cShaderSrc_Scene))
  p.shaderSceneCompose = p.createShaderModule(device, cstring"The shader scene composition", cstring(cShaderSrc_Scene_Compose))
  p.shaderBlit = p.createShaderModule(device, cstring"The shader blit", cstring(cShaderSrc_Blit))
  p.shaderShadow = p.createShaderModule(device, cstring"The shader effects", cstring(cShaderSrc_Shadow))
  p.shaderEffects = p.createShaderModule(device, cstring"The shader effects", cstring(cShaderSrc_Effects))

  # layouts
  p.layoutStencil = p.createPipelineLayout(device, addr bglStencil[0], 1'u32)
  p.layoutDepth = p.createPipelineLayout(device, addr bglDepth[0], 2'u32)
  p.layoutSolid = p.createPipelineLayout(device, addr bglSolid[0], 1'u32)
  p.layoutGradient = p.createPipelineLayout(device, addr bglGradient[0], 3'u32)
  p.layoutImage = p.createPipelineLayout(device, addr bglImage[0], 3'u32)
  p.layoutScene = p.createPipelineLayout(device, addr bglScene[0], 2'u32)
  p.layoutSolidBlend = p.createPipelineLayout(device, addr bglSolidBlend[0], 2'u32)
  p.layoutGradientBlend = p.createPipelineLayout(device, addr bglGradientBlend[0], 4'u32)
  p.layoutImageBlend = p.createPipelineLayout(device, addr bglImageBlend[0], 4'u32)
  p.layoutSceneBlend = p.createPipelineLayout(device, addr bglSceneBlend[0], 3'u32)
  p.layoutSceneCompose = p.createPipelineLayout(device, addr bglSceneCompose[0], 2'u32)
  p.layoutBlit = p.createPipelineLayout(device, addr bglBlit[0], 1'u32)
  p.layoutShadow = p.createPipelineLayout(device, addr bglShadow[0], 3'u32)
  p.layoutEffects = p.createPipelineLayout(device, addr bglEffects[0], 2'u32)

  # pipelines
  p.nonzero = p.createRenderPipeline(device, cstring"The render pipeline nonzero", p.shaderStencil, cstring"vs_main", cstring"fs_main",
    p.layoutStencil, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_None, offscreenTargetFormat, blendStateSrc, depthStencilStateNonZero, multisampleState)
  p.evenodd = p.createRenderPipeline(device, cstring"The render pipeline even-odd", p.shaderStencil, cstring"vs_main", cstring"fs_main",
    p.layoutStencil, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_None, offscreenTargetFormat, blendStateSrc, depthStencilStateEvenOdd, multisampleState)
  p.direct = p.createRenderPipeline(device, cstring"The render pipeline direct", p.shaderStencil, cstring"vs_main", cstring"fs_main",
    p.layoutStencil, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_None, offscreenTargetFormat, blendStateSrc, depthStencilStateDirect, multisampleState)
  p.copyStencilToDepth = p.createRenderPipeline(device, cstring"The render pipeline copy stencil to depth front", p.shaderDepth, cstring"vs_main", cstring"fs_main",
    p.layoutDepth, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_None, offscreenTargetFormat, blendStateSrc, depthStencilStateCopyStencilToDepth, multisampleState)
  p.copyStencilToDepthInterm = p.createRenderPipeline(device, cstring"The render pipeline copy stencil to depth intermediate", p.shaderDepth, cstring"vs_main", cstring"fs_main",
    p.layoutDepth, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_None, offscreenTargetFormat, blendStateSrc, depthStencilStateCopyStencilToDepthInt, multisampleState)
  p.copyDepthToStencil = p.createRenderPipeline(device, cstring"The render pipeline depth to stencil", p.shaderDepth, cstring"vs_main", cstring"fs_main",
    p.layoutDepth, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_None, offscreenTargetFormat, blendStateSrc, depthStencilStateCopyDepthToStencil, multisampleState)
  p.mergeDepthStencil = p.createRenderPipeline(device, cstring"The render pipeline merge depth with stencil", p.shaderDepth, cstring"vs_main", cstring"fs_main",
    p.layoutDepth, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_None, offscreenTargetFormat, blendStateSrc, depthStencilStateMergeDepthStencil, multisampleState)
  p.clearDepth = p.createRenderPipeline(device, cstring"The render pipeline clear depth", p.shaderDepth, cstring"vs_main", cstring"fs_main",
    p.layoutDepth, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_None, offscreenTargetFormat, blendStateSrc, depthStencilStateClearDepth, multisampleState)

  p.solid = p.createRenderPipeline(device, cstring"The render pipeline solid", p.shaderSolid, cstring"vs_main", cstring"fs_main",
    p.layoutSolid, addr vertexBufferLayoutsSolidArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateShape, multisampleState)
  p.radial = p.createRenderPipeline(device, cstring"The render pipeline radial", p.shaderRadial, cstring"vs_main", cstring"fs_main",
    p.layoutGradient, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateShape, multisampleState)
  p.linear = p.createRenderPipeline(device, cstring"The render pipeline linear", p.shaderLinear, cstring"vs_main", cstring"fs_main",
    p.layoutGradient, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateShape, multisampleState)
  p.conic = p.createRenderPipeline(device, cstring"The render pipeline conic", p.shaderConic, cstring"vs_main", cstring"fs_main",
    p.layoutGradient, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateShape, multisampleState)
  p.solidConv = p.createRenderPipeline(device, cstring"The render pipeline solid", p.shaderSolid, cstring"vs_main", cstring"fs_main",
    p.layoutSolid, addr vertexBufferLayoutsSolidArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateConv, multisampleState)
  p.solidBatch = p.createRenderPipeline(device, cstring"The render pipeline solid batch", p.shaderSolid, cstring"vs_main", cstring"fs_main",
    p.layoutSolid, addr vertexBufferLayoutsSolidBatchArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateScene, multisampleState)
  p.solidStencilBatch = p.createRenderPipeline(device, cstring"The render pipeline solid stencil batch cover", p.shaderSolid, cstring"vs_main", cstring"fs_main",
    p.layoutSolid, addr vertexBufferLayoutsSolidBatchArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateShape, multisampleState)
  p.radialConv = p.createRenderPipeline(device, cstring"The render pipeline radial", p.shaderRadial, cstring"vs_main", cstring"fs_main",
    p.layoutGradient, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateConv, multisampleState)
  p.linearConv = p.createRenderPipeline(device, cstring"The render pipeline linear", p.shaderLinear, cstring"vs_main", cstring"fs_main",
    p.layoutGradient, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateConv, multisampleState)
  p.conicConv = p.createRenderPipeline(device, cstring"The render pipeline conic", p.shaderConic, cstring"vs_main", cstring"fs_main",
    p.layoutGradient, addr vertexBufferLayoutsShapeArr[0], 2'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateConv, multisampleState)
  p.image = p.createRenderPipeline(device, cstring"The render pipeline image", p.shaderImage, cstring"vs_main", cstring"fs_main",
    p.layoutImage, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateShape, multisampleState)
  p.imageDirect = p.createRenderPipeline(device, cstring"The render pipeline image direct", p.shaderImage, cstring"vs_main", cstring"fs_main",
    p.layoutImage, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateScene, multisampleState)
  p.scene = p.createRenderPipeline(device, cstring"The render pipeline scene", p.shaderScene, cstring"vs_main", cstring"fs_main",
    p.layoutScene, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateNrm, depthStencilStateScene, multisampleState)

  const shaderComposeNames = [
    cstring"fs_main_None",
    cstring"fs_main_AlphaMask",
    cstring"fs_main_InvAlphaMask",
    cstring"fs_main_LumaMask",
    cstring"fs_main_InvLumaMask",
    cstring"fs_main_AddMask",
    cstring"fs_main_SubtractMask",
    cstring"fs_main_IntersectMask",
    cstring"fs_main_DifferenceMask",
    cstring"fs_main_LightenMask",
    cstring"fs_main_DarkenMask"
  ]
  var composeBlends = [
    blendStateNrm, # None
    blendStateNrm, # AlphaMask
    blendStateNrm, # InvAlphaMask
    blendStateNrm, # LumaMask
    blendStateNrm, # InvLumaMask
    blendStateSrc, # AddMask
    blendStateSrc, # SubtractMask
    blendStateSrc, # IntersectMask
    blendStateSrc, # DifferenceMask
    blendStateSrc, # LightenMask
    blendStateSrc  # DarkenMask
  ]
  for i in 0 ..< 11:
    p.sceneCompose[i] = p.createRenderPipeline(device, cstring"The render pipeline scene composition",
      p.shaderSceneCompose, cstring"vs_main", shaderComposeNames[i], p.layoutSceneCompose,
      addr vertexBufferLayoutsComposeArr[0], 4'u32, WGPUColorWriteMask_All, offscreenTargetFormat,
      composeBlends[i], depthStencilStateScene, multisampleState)

  p.blit = p.createRenderPipeline(device, cstring"The render pipeline blit", p.shaderBlit, cstring"vs_main", cstring"fs_main",
    p.layoutBlit, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, ctx.format, blendStateSrc, depthStencilStateScene, multisampleStateX1)
  p.blitUnpremultiplied = p.createRenderPipeline(device, cstring"The render pipeline blit unpremultiplied", p.shaderBlit, cstring"vs_main", cstring"fs_main_unpremultiplied",
    p.layoutBlit, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, ctx.format, blendStateSrc, depthStencilStateScene, multisampleStateX1)

  # effects
  p.effectMotionBlur = p.createRenderPipeline(device, cstring"The render pipeline motion blur", p.shaderEffects, cstring"vs_main", cstring"fs_main_motion",
    p.layoutEffects, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateSrc, depthStencilStateScene, multisampleStateX1)
  p.effectDropShadow = p.createRenderPipeline(device, cstring"The render pipeline drop shadow", p.shaderShadow, cstring"vs_main", cstring"fs_main_shadow",
    p.layoutShadow, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateSrc, depthStencilStateScene, multisampleStateX1)
  p.effectGaussianVert = p.createRenderPipeline(device, cstring"The render pipeline gaussian vert", p.shaderEffects, cstring"vs_main", cstring"fs_main_vert",
    p.layoutEffects, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateSrc, depthStencilStateScene, multisampleStateX1)
  p.effectGaussianHorz = p.createRenderPipeline(device, cstring"The render pipeline gaussian horz", p.shaderEffects, cstring"vs_main", cstring"fs_main_horz",
    p.layoutEffects, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateSrc, depthStencilStateScene, multisampleStateX1)
  p.effectFill = p.createRenderPipeline(device, cstring"The render pipeline fill effect", p.shaderEffects, cstring"vs_main", cstring"fs_main_fill",
    p.layoutEffects, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateSrc, depthStencilStateScene, multisampleStateX1)
  p.effectTint = p.createRenderPipeline(device, cstring"The render pipeline tint effect", p.shaderEffects, cstring"vs_main", cstring"fs_main_tint",
    p.layoutEffects, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateSrc, depthStencilStateScene, multisampleStateX1)
  p.effectTritone = p.createRenderPipeline(device, cstring"The render pipeline tritone effect", p.shaderEffects, cstring"vs_main", cstring"fs_main_tritone",
    p.layoutEffects, addr vertexBufferLayoutsImageArr[0], 3'u32, WGPUColorWriteMask_All, offscreenTargetFormat, blendStateSrc, depthStencilStateScene, multisampleStateX1)

proc releaseGraphicHandles*(p: var WgPipelines; ctx: var WgContext) =
  p.releaseRenderPipeline(p.effectTritone)
  p.releaseRenderPipeline(p.effectTint)
  p.releaseRenderPipeline(p.effectFill)
  p.releaseRenderPipeline(p.effectGaussianHorz)
  p.releaseRenderPipeline(p.effectGaussianVert)
  p.releaseRenderPipeline(p.effectDropShadow)
  p.releaseRenderPipeline(p.effectMotionBlur)
  p.releaseRenderPipeline(p.blitUnpremultiplied)
  p.releaseRenderPipeline(p.blit)
  for i in 0 ..< 11: p.releaseRenderPipeline(p.sceneCompose[i])
  for i in 0 ..< 18:
    p.releaseRenderPipeline(p.sceneBlends[i])
    p.releaseRenderPipeline(p.imageBlends[i])
    p.releaseRenderPipeline(p.conicBlends[i])
    p.releaseRenderPipeline(p.linearBlends[i])
    p.releaseRenderPipeline(p.radialBlends[i])
    p.releaseRenderPipeline(p.solidBlends[i])
  for i in 0 ..< p.strokeClip.len: p.releaseRenderPipeline(p.strokeClip[i])
  p.releaseRenderPipeline(p.scene)
  p.releaseRenderPipeline(p.image)
  p.releaseRenderPipeline(p.imageDirect)
  p.releaseRenderPipeline(p.conicConv)
  p.releaseRenderPipeline(p.linearConv)
  p.releaseRenderPipeline(p.radialConv)
  p.releaseRenderPipeline(p.solidStencilBatch)
  p.releaseRenderPipeline(p.solidBatch)
  p.releaseRenderPipeline(p.solidConv)
  p.releaseRenderPipeline(p.conic)
  p.releaseRenderPipeline(p.linear)
  p.releaseRenderPipeline(p.radial)
  p.releaseRenderPipeline(p.solid)
  p.releaseRenderPipeline(p.clearDepth)
  p.releaseRenderPipeline(p.mergeDepthStencil)
  p.releaseRenderPipeline(p.copyDepthToStencil)
  p.releaseRenderPipeline(p.copyStencilToDepthInterm)
  p.releaseRenderPipeline(p.copyStencilToDepth)
  p.releaseRenderPipeline(p.direct)
  p.releaseRenderPipeline(p.evenodd)
  p.releaseRenderPipeline(p.nonzero)

  p.releasePipelineLayout(p.layoutEffects)
  p.releasePipelineLayout(p.layoutShadow)
  p.releasePipelineLayout(p.layoutBlit)
  p.releasePipelineLayout(p.layoutSceneCompose)
  p.releasePipelineLayout(p.layoutSceneBlend)
  p.releasePipelineLayout(p.layoutImageBlend)
  p.releasePipelineLayout(p.layoutGradientBlend)
  p.releasePipelineLayout(p.layoutSolidBlend)
  p.releasePipelineLayout(p.layoutScene)
  p.releasePipelineLayout(p.layoutImage)
  p.releasePipelineLayout(p.layoutGradient)
  p.releasePipelineLayout(p.layoutSolid)
  p.releasePipelineLayout(p.layoutDepth)
  p.releasePipelineLayout(p.layoutStencil)

  p.releaseShaderModule(p.shaderEffects)
  p.releaseShaderModule(p.shaderShadow)
  p.releaseShaderModule(p.shaderBlit)
  p.releaseShaderModule(p.shaderSceneCompose)
  p.releaseShaderModule(p.shaderSceneBlend)
  p.releaseShaderModule(p.shaderImageBlend)
  p.releaseShaderModule(p.shaderConicBlend)
  p.releaseShaderModule(p.shaderLinearBlend)
  p.releaseShaderModule(p.shaderRadialBlend)
  p.releaseShaderModule(p.shaderSolidBlend)
  p.releaseShaderModule(p.shaderScene)
  p.releaseShaderModule(p.shaderImage)
  p.releaseShaderModule(p.shaderConic)
  p.releaseShaderModule(p.shaderLinear)
  p.releaseShaderModule(p.shaderRadial)
  p.releaseShaderModule(p.shaderSolid)
  p.releaseShaderModule(p.shaderDepth)
  p.releaseShaderModule(p.shaderStencil)

proc release*(p: var WgPipelines; ctx: var WgContext) =
  p.releaseGraphicHandles(ctx)
