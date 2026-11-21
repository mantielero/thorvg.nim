## Render targets and render-target pool for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgRenderTarget.h/.cpp.
## Manages RGBA8 storage textures (and optional MSAA attachments), views and bind groups,
## plus a power-of-two sized pooled allocator by region.

import ../../core/types
import ./wg_ffi
import ./wg_common
import ./bind_groups

type
  WgRenderTarget* = ref object
    texture*, textureMS*: WGPUTexture
    texView*, texViewMS*: WGPUTextureView
    bgRead*, bgWrite*: WGPUBindGroup
    bgTexture*: WGPUBindGroup       ## Nearest + repeat for general compositing and pixel-aligned effects.
    bgTextureLinear*: WGPUBindGroup ## Linear + clamp for subpixel sampling, such as motion blur.
    width*, height*: uint32

  WgRenderTargetPool* = ref object
    list*, pool*: seq[WgRenderTarget]
    width*, height*: uint32

proc renderTargetSize(value, limit: uint32): uint32 =
  var size = 1'u32
  while size < value and size < limit:
    if size > limit div 2: return limit
    size = size shl 1
  if size < limit: size else: limit

proc initialize*(t: WgRenderTarget; ctx: var WgContext; width, height: uint32; multisample: bool = true) =
  t.width = width
  t.height = height
  t.texture = ctx.createTexStorage(width, height, WGPUTextureFormat_RGBA8Unorm)
  if multisample:
    t.textureMS = ctx.createTexAttachement(width, height, WGPUTextureFormat_RGBA8Unorm, 4)
  t.texView = ctx.createTextureView(t.texture)
  if multisample:
    t.texViewMS = ctx.createTextureView(t.textureMS)
  t.bgRead = ctx.layouts.createBindGroupStrorage1RO(t.texView)
  t.bgWrite = ctx.layouts.createBindGroupStrorage1WO(t.texView)
  t.bgTexture = ctx.layouts.createBindGroupTexSampled(ctx.samplerNearestRepeat, t.texView)

proc getBindGroupTextureLinear*(t: WgRenderTarget; ctx: var WgContext): WGPUBindGroup =
  if isNil(t.bgTextureLinear):
    t.bgTextureLinear = ctx.layouts.createBindGroupTexSampled(ctx.samplerLinearClamp, t.texView)
  t.bgTextureLinear

proc release*(t: WgRenderTarget; ctx: var WgContext) =
  if t == nil: return
  ctx.layouts.releaseBindGroup(t.bgTextureLinear)
  ctx.layouts.releaseBindGroup(t.bgTexture)
  ctx.layouts.releaseBindGroup(t.bgWrite)
  ctx.layouts.releaseBindGroup(t.bgRead)
  ctx.releaseTextureView(t.texViewMS)
  ctx.releaseTexture(t.textureMS)
  ctx.releaseTextureView(t.texView)
  ctx.releaseTexture(t.texture)
  t.height = 0
  t.width = 0

#*****************************************************************************
# render target pool
#*****************************************************************************

proc initialize*(p: WgRenderTargetPool; width, height: uint32) =
  p.width = width
  p.height = height

proc allocate*(p: WgRenderTargetPool; ctx: var WgContext; region: Region): WgRenderTarget =
  let rw = if region.xMax > region.xMin: uint32(region.xMax - region.xMin) else: 1'u32
  let rh = if region.yMax > region.yMin: uint32(region.yMax - region.yMin) else: 1'u32
  let targetWidth = renderTargetSize(if rw > 1'u32: rw else: 1'u32, p.width)
  let targetHeight = renderTargetSize(if rh > 1'u32: rh else: 1'u32, p.height)
  var i = 0
  while i < p.pool.len:
    let target = p.pool[i]
    if target.width != targetWidth or target.height != targetHeight:
      inc i
      continue
    p.pool[i] = p.pool[p.pool.high]
    p.pool.setLen(p.pool.len - 1)
    return target

  # TODO: Add an eviction policy to release unused cached resources.
  let renderTarget = WgRenderTarget()
  renderTarget.initialize(ctx, targetWidth, targetHeight)
  p.list.add(renderTarget)
  renderTarget

proc release*(p: WgRenderTargetPool; ctx: var WgContext) =
  for t in p.list:
    t.release(ctx)
  p.list.setLen(0)
  p.pool.setLen(0)
  p.height = 0
  p.width = 0
