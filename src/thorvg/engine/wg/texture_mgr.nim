## Texture cache for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgTextureMgr.h/.cpp.
## Caches textures per (RenderSurface, FilterMethod) with ref-counting and optional
## CPU->GPU preprocess (premultiply / BGR swizzle) queued for compute passes.

import ../../core/types
import ../../renderer/render
import ./wg_ffi
import ./wg_common
import ./bind_groups
# import ./shader_src  # needed for full preprocess pipeline; stubbed in W3 compile-check

type
  WgTexPrep* = enum
    tpNone = 0
    tpPremultiply = 1
    tpBgr = 2
    tpQueued = 4

  WgTextureEntry* = ref object
    texture*: WGPUTexture
    textureView*: WGPUTextureView
    bindGroup*: WGPUBindGroup
    preprocess*: set[WgTexPrep]
    refCnt*: uint32

  WgSurfaceEntry* = ref object
    surface*: RenderSurface
    bilinear*: seq[WgTextureEntry]
    nearest*: seq[WgTextureEntry]

  WgTextureMgr* = object
    surfaces*: seq[WgSurfaceEntry]
    prepShader*: WGPUShaderModule
    prepLayout*: WGPUPipelineLayout
    prepPremultBgr*: WGPUComputePipeline
    prepPremult*: WGPUComputePipeline
    prepStaging*: WGPUTexture
    prepStagingView*: WGPUTextureView
    prepStagingBindGroup*: WGPUBindGroup
    prepRequests*: seq[WgTextureEntry]
    prepStagingWidth*: uint32
    prepStagingHeight*: uint32
    stamp*: uint16

func initWgTextureMgr*(): WgTextureMgr =
  WgTextureMgr(stamp: 1'u16)

proc entries(se: WgSurfaceEntry; filter: FilterMethod): var seq[WgTextureEntry] =
  if filter == FilterMethod.Bilinear:
    result = se.bilinear
  else:
    result = se.nearest

func findEntry(entries: seq[WgTextureEntry]; texture: WGPUTexture): WgTextureEntry =
  for e in entries:
    if e.texture == texture: return e
  nil

func textureFormat*(surface: RenderSurface): WGPUTextureFormat =
  if surface.cs == ColorSpace.ABGR8888 or surface.cs == ColorSpace.ABGR8888S:
    return WGPUTextureFormat_RGBA8Unorm
  if surface.cs == ColorSpace.ARGB8888 or surface.cs == ColorSpace.ARGB8888S:
    return if surface.premultiplied: WGPUTextureFormat_BGRA8Unorm else: WGPUTextureFormat_RGBA8Unorm
  WGPUTextureFormat_R8Unorm

func matches(entry: WgTextureEntry; surface: RenderSurface; format: WGPUTextureFormat): bool =
  (not isNil(entry.texture)) and
    wgpuTextureGetWidth(entry.texture) == surface.w and
    wgpuTextureGetHeight(entry.texture) == surface.h and
    wgpuTextureGetFormat(entry.texture) == format

proc upload*(ctx: var WgContext; entry: WgTextureEntry; surface: RenderSurface; filter: FilterMethod) =
  var preprocess: set[WgTexPrep] = {}
  if tpQueued in entry.preprocess: preprocess.incl(tpQueued)
  if surface.channelSize == 4'u8:
    if not surface.premultiplied: preprocess.incl(tpPremultiply)
    if (not surface.premultiplied) and (surface.cs == ColorSpace.ARGB8888 or surface.cs == ColorSpace.ARGB8888S):
      preprocess.incl(tpBgr)
  entry.preprocess = preprocess

  let bytesPerRow = surface.stride * uint32(channelSize(surface.cs))
  let dataSize = uint64(bytesPerRow) * uint64(surface.h)
  var dataPtr: pointer = nil
  if surface.data.len > 0:
    dataPtr = cast[pointer](unsafeAddr surface.data[0])
  elif surface.buf8.len > 0:
    dataPtr = cast[pointer](unsafeAddr surface.buf8[0])
  if not ctx.allocateTexture(entry.texture, surface.w, surface.h, textureFormat(surface), dataPtr, bytesPerRow, dataSize):
    return
  ctx.releaseTextureView(entry.textureView)
  entry.textureView = ctx.createTextureView(entry.texture)
  ctx.layouts.releaseBindGroup(entry.bindGroup)
  let sampler = if filter == FilterMethod.Bilinear: ctx.samplerLinearClamp else: ctx.samplerNearestClamp
  entry.bindGroup = ctx.layouts.createBindGroupTexSampled(sampler, entry.textureView)

proc find*(mgr: var WgTextureMgr; surface: RenderSurface): WgSurfaceEntry =
  for e in mgr.surfaces:
    if e.surface == surface: return e
  nil

proc retain*(mgr: var WgTextureMgr; ctx: var WgContext; surface: RenderSurface;
             filter: FilterMethod; refreshTexture: bool): WgTextureEntry =
  var se = mgr.find(surface)
  if se == nil:
    se = WgSurfaceEntry(surface: surface)
    mgr.surfaces.add(se)

  var list = addr entries(se, filter)
  let format = textureFormat(surface)
  var entry: WgTextureEntry = nil
  if list[].len > 0:
    entry = list[][^1]
  if entry != nil and refreshTexture and (not matches(entry, surface, format)) and entry.refCnt > 0:
    entry = WgTextureEntry()
    list[].add(entry)
  elif entry == nil:
    entry = WgTextureEntry()
    list[].add(entry)
  if isNil(entry.texture) or refreshTexture:
    upload(ctx, entry, surface, filter)

  if (tpQueued in entry.preprocess) and not (tpPremultiply in entry.preprocess or tpBgr in entry.preprocess):
    # remove from prepRequests
    var i = 0
    while i < mgr.prepRequests.len:
      if mgr.prepRequests[i] == entry:
        mgr.prepRequests[i] = mgr.prepRequests[^1]
        mgr.prepRequests.setLen(mgr.prepRequests.len - 1)
        break
      inc i
    entry.preprocess.excl(tpQueued)
  elif (not isNil(entry.texture)) and (tpPremultiply in entry.preprocess or tpBgr in entry.preprocess) and not (tpQueued in entry.preprocess):
    entry.preprocess.incl(tpQueued)
    mgr.prepRequests.add(entry)

  inc entry.refCnt
  result = entry

proc releaseEntry*(ctx: var WgContext; entry: WgTextureEntry) =
  ctx.layouts.releaseBindGroup(entry.bindGroup)
  ctx.releaseTextureView(entry.textureView)
  ctx.releaseTexture(entry.texture)
  entry.refCnt = 0

proc release*(mgr: var WgTextureMgr; ctx: var WgContext; surface: RenderSurface;
              filter: FilterMethod; texture: WGPUTexture) =
  let se = mgr.find(surface)
  if se == nil: return
  var list = addr entries(se, filter)
  let entry = findEntry(list[], texture)
  if entry == nil: return
  if entry.refCnt > 0: dec entry.refCnt
  if entry.refCnt > 0: return

  if tpQueued in entry.preprocess:
    var i = 0
    while i < mgr.prepRequests.len:
      if mgr.prepRequests[i] == entry:
        mgr.prepRequests[i] = mgr.prepRequests[^1]
        mgr.prepRequests.setLen(mgr.prepRequests.len - 1)
        break
      inc i
    entry.preprocess.excl(tpQueued)

  releaseEntry(ctx, entry)
  # remove from list
  var j = 0
  while j < list[].len:
    if list[][j] == entry:
      list[][j] = list[][^1]
      list[].setLen(list[].len - 1)
      break
    inc j
  if se.bilinear.len == 0 and se.nearest.len == 0:
    var k = 0
    while k < mgr.surfaces.len:
      if mgr.surfaces[k] == se:
        mgr.surfaces[k] = mgr.surfaces[^1]
        mgr.surfaces.setLen(mgr.surfaces.len - 1)
        break
      inc k

proc flushPreprocess*(mgr: var WgTextureMgr; ctx: var WgContext): bool =
  ## Stubbed for W0-W7 compile-check: real preprocess requires compute pipeline
  ## descriptors and shader module creation against the target wgpu-native API.
  ## Marks queued entries as processed to keep state consistent.
  if mgr.prepRequests.len == 0: return true
  for entry in mgr.prepRequests:
    entry.preprocess.excl(tpQueued)
    entry.preprocess.excl(tpPremultiply)
    entry.preprocess.excl(tpBgr)
  mgr.prepRequests.setLen(0)
  true

proc clear*(mgr: var WgTextureMgr; ctx: var WgContext) =
  mgr.prepRequests.setLen(0)
  ctx.layouts.releaseBindGroup(mgr.prepStagingBindGroup)
  ctx.releaseTextureView(mgr.prepStagingView)
  ctx.releaseTexture(mgr.prepStaging)
  mgr.prepStagingWidth = 0
  mgr.prepStagingHeight = 0
  if not isNil(mgr.prepPremult): wgpuComputePipelineRelease(mgr.prepPremult)
  if not isNil(mgr.prepPremultBgr): wgpuComputePipelineRelease(mgr.prepPremultBgr)
  mgr.prepPremult = WGPUComputePipeline(nil)
  mgr.prepPremultBgr = WGPUComputePipeline(nil)
  if not isNil(mgr.prepLayout): wgpuPipelineLayoutRelease(mgr.prepLayout)
  mgr.prepLayout = WGPUPipelineLayout(nil)
  if not isNil(mgr.prepShader): wgpuShaderModuleRelease(mgr.prepShader)
  mgr.prepShader = WGPUShaderModule(nil)

  for se in mgr.surfaces:
    for e in se.bilinear:
      releaseEntry(ctx, e)
    for e in se.nearest:
      releaseEntry(ctx, e)
  mgr.surfaces.setLen(0)
  if mgr.stamp == high(uint16): mgr.stamp = 1'u16 else: inc mgr.stamp
