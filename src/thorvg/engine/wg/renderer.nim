## WebGPU (WG) renderer for ThorVG (W6).
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgRenderer.h/.cpp.
## Wires W2..W5 context/compositor/tasks/batches/targets/pools into RenderMethod overrides.
## Runtime build/link/parity blocked without wgpu-native headers/libs (R-WG-1/2).

import std/[math, options]
import ../../core/[types, geom]
import ../../renderer/[render, effect]
import ../gl/gpu_probe
import ./[wg_types, wg_ffi, wg_common, render_data,
       render_target, texture_mgr, compositor, render_task, solid_batch, stencil_batch]

type
  WgPaintPool* = object
    list*: seq[WgPaint]    ## full list of created paints
    shapes*: seq[WgShape]  ## reuse list
    images*: seq[WgImage]  ## reuse list

  WgRenderer* = ref object of RenderMethod
    # main surface / target
    mSurface*: RenderSurface
    mRenderTargetRoot*: WgRenderTarget
    mCompositorList*: seq[WgCompose]
    mRenderTargetStack*: seq[WgRenderTarget]
    mSceneTaskStack*: seq[WgSceneTask]
    mRenderTaskList*: seq[WgRenderTask]
    mSolidBatch*: WgSolidBatch
    mStencilBatch*: WgStencilBatch
    mRenderTargetPool*: WgRenderTargetPool
    mPaintPool*: WgPaintPool
    mEffectPool*: WgRenderEffectPool
    mTextures*: WgTextureMgr
    mContext*: WgContext
    mCompositor*: WgCompositor
    mBlendMethod*: BlendMethod

    # disposable data list
    mDisposedPaints*: seq[RenderData]

    # gpu handles
    targetTexture*: WGPUTexture
    surfaceTexture*: WGPUSurfaceTexture
    surface*: WGPUSurface

    mClearBuffer*: bool

var
  wgRendererCnt* = -1

proc asWgRenderer*(m: RenderMethod): WgRenderer =
  ## Checked downcast like `engine/gl/renderer.asGlRenderer`.
  if m of WgRenderer: WgRenderer(m) else: nil

# ---- paint pool ---------------------------------------------------------

proc shape*(pool: var WgPaintPool): WgShape =
  if pool.shapes.len > 0:
    result = pool.shapes[^1]
    pool.shapes.setLen(pool.shapes.len - 1)
    return
  result = WgShape()
  pool.list.add(WgPaint(result))

proc image*(pool: var WgPaintPool): WgImage =
  if pool.images.len > 0:
    result = pool.images[^1]
    pool.images.setLen(pool.images.len - 1)
    return
  result = WgImage()
  pool.list.add(WgPaint(result))

proc recycle*(pool: var WgPaintPool; shape: WgShape) =
  if shape != nil: pool.shapes.add(shape)

proc recycle*(pool: var WgPaintPool; image: WgImage) =
  if image != nil: pool.images.add(image)

proc release*(pool: var WgPaintPool; ctx: var WgContext) =
  for p in pool.list:
    if p of WgShape:
      WgShape(p).release(ctx)
    elif p of WgImage:
      WgImage(p).release(ctx)
  pool.shapes.setLen(0)
  pool.images.setLen(0)
  pool.list.setLen(0)

# ---- intersector helpers ------------------------------------------------

proc regionW(r: Region): int32 = r.xMax - r.xMin
proc regionH(r: Region): int32 = r.yMax - r.yMin

proc intersectClips(clips: seq[WgPaint]; pt: Point): bool =
  for c in clips:
    if not (c of WgShape): return false
    let clip = WgShape(c)
    let mesh = clip.shape.mesh
    if not inside(clip.shape.bbox, pt): return false
    if not gpuPointInFillMesh(pt, mesh.vbuffer, mesh.ibuffer, clip.fillRule):
      return false
  true

proc intersectsShapeData(shape: WgShape; region: Region): bool =
  let validFill = shape.shape.setting.valid and shape.shape.mesh.ibuffer.len > 0
  var validStroke = shape.stroke.setting.valid and shape.stroke.mesh.ibuffer.len > 0
  if (not validFill) and (not validStroke): return false

  var itransform: Matrix
  if validStroke and not inverse(shape.transform, itransform):
    validStroke = false
  let sizeX = int(regionW(region))
  let sizeY = int(regionH(region))

  for y in 0 ..< sizeY:
    let py = if (y mod 2) == 0: y else: sizeY - y - (sizeY mod 2)
    for x in 0 ..< sizeX:
      let pt = Point(x: float32(x) + float32(region.xMin), y: float32(py) + float32(region.yMin))
      var hit = false
      if validFill:
        let mesh = shape.shape.mesh
        hit = inside(shape.shape.bbox, pt) and gpuPointInFillMesh(pt, mesh.vbuffer, mesh.ibuffer, shape.fillRule)
      if (not hit) and validStroke:
        let p = pt * itransform
        let mesh = shape.stroke.mesh
        hit = inside(shape.stroke.bbox, p) and gpuPointInAnyMesh(p, mesh.vbuffer, mesh.ibuffer, mesh.ibuffer.len)
      if hit and intersectClips(shape.clips, pt):
        return true
  false

proc intersectsImageData(image: WgImage; region: Region): bool =
  if image.mesh.ibuffer.len < 6: return false
  let mesh = image.mesh
  var triangle: array[6, Point]
  for i in 0 ..< 6:
    let idx = int(mesh.ibuffer[i])
    if idx < 0 or idx >= mesh.vbuffer.len: return false
    triangle[i] = mesh.vbuffer[idx]

  let sizeX = int(regionW(region))
  let sizeY = int(regionH(region))
  for y in 0 ..< sizeY:
    let py = if (y mod 2) == 0: y else: sizeY - y - (sizeY mod 2)
    for x in 0 ..< sizeX:
      let pt = Point(x: float32(x) + float32(region.xMin), y: float32(py) + float32(region.yMin))
      if gpuPointInQuad(pt, triangle) and intersectClips(image.clips, pt):
        return true
  false

# ---- internal helpers ---------------------------------------------------

proc releaseSurfaceTexture(r: WgRenderer) =
  if not isNil(r.surfaceTexture.texture):
    wgpuTextureRelease(r.surfaceTexture.texture)
    r.surfaceTexture.texture = WGPUTexture(nil)

proc clearTargets(r: WgRenderer) =
  r.releaseSurfaceTexture()
  if not isNil(r.surface):
    wgpuSurfaceUnconfigure(r.surface)
  r.targetTexture = WGPUTexture(nil)
  r.surface = WGPUSurface(nil)
  if r.mSurface != nil:
    r.mSurface.stride = 0
    r.mSurface.w = 0
    r.mSurface.h = 0

proc disposeObjects(r: WgRenderer) =
  if r.mDisposedPaints.len == 0: return
  for p in r.mDisposedPaints:
    if p == nil: continue
    let paint = cast[WgPaint](p)
    if paint == nil: continue
    paint.clips.setLen(0)
    if paint of WgShape:
      let shape = WgShape(paint)
      shape.reset()
      r.mPaintPool.recycle(shape)
    elif paint of WgImage:
      let image = WgImage(paint)
      image.release(r.mTextures, r.mContext)
      r.mPaintPool.recycle(image)
  r.mDisposedPaints.setLen(0)

proc release(r: WgRenderer) =
  if isNil(r.mContext.queue): return

  r.disposeObjects()
  r.mTextures.clear(r.mContext)

  # clear render data paint pools
  r.mPaintPool.release(r.mContext)
  if r.mEffectPool != nil: r.mEffectPool.release(r.mContext)

  # clear render pool
  if r.mRenderTargetPool != nil: r.mRenderTargetPool.release(r.mContext)

  # clear rendering tree stacks
  r.mCompositorList.setLen(0)
  r.mRenderTargetStack.setLen(0)
  if r.mRenderTargetRoot != nil:
    r.mRenderTargetRoot.release(r.mContext)

  # release context handles
  r.mCompositor.release(r.mContext)
  r.mContext.release()

  # release gpu handles
  r.clearTargets()

proc surfaceConfigure(r: WgRenderer; rsurface: var RenderSurface; wsurface: WGPUSurface; ctx: var WgContext) =
  # Retire the previous frame before native reconfiguration resets its presentation state.
  r.releaseSurfaceTexture()
  r.surface = wsurface

  var surfaceConfig = WGPUSurfaceConfiguration(
    device: ctx.device,
    format: ctx.format,
    usage: WGPUTextureUsage_RenderAttachment,
    width: rsurface.w,
    height: rsurface.h,
    alphaMode: (if rsurface.opaque: WGPUCompositeAlphaMode_Opaque else: WGPUCompositeAlphaMode_Auto),
    presentMode: WGPUPresentMode_Fifo
  )

  # Query capabilities when available; fall back to conservative defaults.
  if not isNil(ctx.adapter):
    var caps: WGPUSurfaceCapabilities
    if wgpuSurfaceGetCapabilities(wsurface, ctx.adapter, addr caps) == WGPUStatus_Success:
      if caps.formatCount > 0 and caps.formats != nil:
        let fmts = cast[ptr UncheckedArray[WGPUTextureFormat]](caps.formats)
        var chosen = fmts[0]
        for i in 0 ..< int(caps.formatCount):
          let f = fmts[i]
          if f == WGPUTextureFormat_BGRA8Unorm or f == WGPUTextureFormat_RGBA8Unorm:
            chosen = f; break
        surfaceConfig.format = chosen
        ctx.format = chosen
      if caps.alphaModeCount > 0 and caps.alphaModes != nil:
        let modes = cast[ptr UncheckedArray[WGPUCompositeAlphaMode]](caps.alphaModes)
        var alpha = modes[0]
        let want = if rsurface.opaque: WGPUCompositeAlphaMode_Opaque else: WGPUCompositeAlphaMode_Auto
        for i in 0 ..< int(caps.alphaModeCount):
          if modes[i] == want: alpha = want; break
        surfaceConfig.alphaMode = alpha
      if caps.presentModeCount > 0 and caps.presentModes != nil:
        let pms = cast[ptr UncheckedArray[WGPUPresentMode]](caps.presentModes)
        var pm = pms[0]
        for i in 0 ..< int(caps.presentModeCount):
          if pms[i] == WGPUPresentMode_Fifo: pm = WGPUPresentMode_Fifo; break
        for i in 0 ..< int(caps.presentModeCount):
          if pms[i] == WGPUPresentMode_Immediate and pm != WGPUPresentMode_Fifo:
            pm = WGPUPresentMode_Immediate
        surfaceConfig.presentMode = pm
      wgpuSurfaceCapabilitiesFreeMembers(caps)

  let premultiplied = (rsurface.cs != ColorSpace.ABGR8888S)
  rsurface.premultiplied = premultiplied
  wgpuSurfaceConfigure(wsurface, addr surfaceConfig)

proc newWgRenderer*(threads: uint32 = 0; op: uint32 = 0): WgRenderer =
  ## Creates a WG renderer instance (W6 scaffolding; requires a bound/initialized context via target).
  if wgRendererCnt == -1:
    # TODO: initialize global engine resources when needed
    wgRendererCnt = 0
  inc wgRendererCnt
  result = WgRenderer(
    mSurface: RenderSurface(),
    mRenderTargetRoot: WgRenderTarget(),
    mRenderTargetPool: WgRenderTargetPool(),
    mPaintPool: WgPaintPool(),
    mEffectPool: WgRenderEffectPool(),
    mTextures: initWgTextureMgr(),
    mBlendMethod: BlendMethod.Normal
  )

proc destroy*(r: WgRenderer) =
  ## Releases renderer resources and decrements the renderer refcount (C++ dtor semantics, best-effort).
  if r == nil: return
  r.release()
  dec wgRendererCnt
  if wgRendererCnt < 0: wgRendererCnt = 0

proc termWgRenderer*(): bool =
  ## Global engine termination hook (C++ `WgRenderer::term`). Returns false while renderers are alive.
  if wgRendererCnt > 0:
    return false
  wgRendererCnt = -1
  # TODO: clean up global resources when W8/runtime integration is complete
  true

# ---- RenderMethod overrides ---------------------------------------------

method preUpdate*(r: WgRenderer): bool =
  if r.mContext.invalid(): return false
  true

method prepareShape*(r: WgRenderer, rshape: RenderShape, data: RenderData,
    transform: Matrix, clips: seq[RenderData], opacity: uint8,
    flags: RenderUpdateFlags, clipper: bool): RenderData =
  var shape: WgShape
  var updFlags = flags
  if data == nil or not (data of WgShape):
    shape = r.mPaintPool.shape()
    updFlags = {low(RenderUpdateFlag)..high(RenderUpdateFlag)}
  else:
    shape = WgShape(data)

  # update geometry
  if RenderUpdateFlag.Transform in updFlags or RenderUpdateFlag.Path in updFlags or RenderUpdateFlag.Stroke in updFlags:
    shape.update(rshape, transform, updFlags)

  # update transform
  if RenderUpdateFlag.Transform in updFlags:
    shape.transform = transform

  # update paint settings
  let fillOpacity = shape.shape.setting.update(r.mSurface.cs, opacity)
  let strokeOpacity = shape.stroke.setting.update(r.mSurface.cs, opacity)
  shape.viewport = r.vport
  shape.assign(clips)
  shape.updateStyle(rshape, r.vport, fillOpacity, strokeOpacity, opacity)

  # shape paint
  if shape.shape.setting.valid:
    if rshape.fill.isSome and (RenderUpdateFlag.Gradient in updFlags or RenderUpdateFlag.Transform in updFlags):
      var tm = transform
      shape.shape.setting.update(r.mContext, rshape.fill.get, addr tm, RenderUpdateFlag.Gradient in updFlags)
    elif RenderUpdateFlag.Color in updFlags or RenderUpdateFlag.Gradient in updFlags:
      shape.shape.solid.color = rshape.color
      shape.shape.setting.fillType = rstSolid

  # stroke paint
  if shape.stroke.setting.valid and rshape.stroke.isSome:
    let rs = rshape.stroke.get
    if rs.fill.isSome and (RenderUpdateFlag.GradientStroke in updFlags or RenderUpdateFlag.Transform in updFlags):
      shape.stroke.setting.update(r.mContext, rs.fill.get, nil, RenderUpdateFlag.GradientStroke in updFlags)
    elif RenderUpdateFlag.Stroke in updFlags or RenderUpdateFlag.GradientStroke in updFlags:
      shape.stroke.solid.color = rs.color
      shape.stroke.setting.fillType = rstSolid

  if RenderUpdateFlag.Clip in updFlags:
    shape.assign(clips)

  RenderData(shape)

method prepareImage*(r: WgRenderer, surface: RenderSurface, data: RenderData,
    transform: Matrix, clips: seq[RenderData], opacity: uint8,
    filter: FilterMethod, flags: RenderUpdateFlags): RenderData =
  var image: WgImage
  var updFlags = flags
  if data == nil or not (data of WgImage):
    image = r.mPaintPool.image()
    updFlags = {low(RenderUpdateFlag)..high(RenderUpdateFlag)}
  else:
    image = WgImage(data)

  # update paint settings
  image.viewport = r.vport
  image.transform = transform
  discard image.setting.update(surface.cs, opacity)

  if RenderUpdateFlag.Transform in updFlags or RenderUpdateFlag.Image in updFlags:
    image.update(surface, transform)

  # reload texture
  let cacheStale = isNil(image.texture) or (image.stamp != r.mTextures.stamp)
  let refreshTex = (RenderUpdateFlag.Image in updFlags)
  let needUpdate = cacheStale or refreshTex or (image.surface != surface) or (image.filter != filter)
  if needUpdate:
    image.release(r.mTextures, r.mContext)
    let entry = r.mTextures.retain(r.mContext, surface, filter, refreshTex)
    if entry != nil:
      image.setup(entry.texture, entry.bindGroup, surface, filter, r.mTextures.stamp)

  if RenderUpdateFlag.Clip in updFlags:
    image.assign(clips)

  RenderData(image)

method postUpdate*(r: WgRenderer): bool =
  if r.mContext.invalid(): return false
  r.mTextures.flushPreprocess(r.mContext)

method preRender*(r: WgRenderer): bool =
  if r.mContext.invalid(): return false

  r.mSolidBatch = initWgSolidBatch()
  r.mStencilBatch = initWgStencilBatch()
  r.mCompositor.reset(r.mContext)

  r.mRenderTargetStack.setLen(0)
  r.mRenderTargetStack.add(r.mRenderTargetRoot)

  # create root compose settings
  let compose = WgCompose()
  compose.aabb = Region(xMin: 0, yMin: 0, xMax: int32(r.mSurface.w), yMax: int32(r.mSurface.h))
  compose.blend = BlendMethod.Normal
  compose.meth = MaskMethod.None
  compose.opacity = 255'u8
  compose.flags = {}
  r.mCompositorList.add(compose)

  # create root scene
  let sceneTask = initWgSceneTask(r.mRenderTargetRoot, compose, nil)
  r.mRenderTaskList.add(WgRenderTask(sceneTask))
  r.mSceneTaskStack.add(sceneTask)
  true

method renderShape*(r: WgRenderer, data: RenderData): bool =
  if data == nil or not (data of WgShape): return false
  let shape = WgShape(data)
  if r.mSceneTaskStack.len == 0: return false
  let sceneTask = r.mSceneTaskStack[^1]

  if r.mSolidBatch.draw(sceneTask, shape, r.mBlendMethod, r.mRenderTaskList): return true
  if r.mStencilBatch.draw(sceneTask, shape, r.mBlendMethod, r.mRenderTaskList): return true

  let paintTask = initWgPaintTask(WgPaint(shape), r.mBlendMethod)
  sceneTask.children.add(WgRenderTask(paintTask))
  r.mRenderTaskList.add(WgRenderTask(paintTask))
  true

method renderImage*(r: WgRenderer, data: RenderData): bool =
  if data == nil or not (data of WgImage): return false
  let image = WgImage(data)
  if r.mSceneTaskStack.len == 0: return false
  let sceneTask = r.mSceneTaskStack[^1]
  if r.mSolidBatch.draw(sceneTask, image, r.mBlendMethod, r.mRenderTaskList): return true

  let paintTask = initWgPaintTask(WgPaint(image), r.mBlendMethod)
  sceneTask.children.add(WgRenderTask(paintTask))
  r.mRenderTaskList.add(WgRenderTask(paintTask))
  true

method postRender*(r: WgRenderer): bool =
  if r.mSceneTaskStack.len == 0 or r.mContext.invalid(): return false
  let sceneTaskRoot = r.mSceneTaskStack[^1]
  sceneTaskRoot.stage(r.mCompositor)

  # flush stage data to gpu
  r.mCompositor.flush(r.mContext)

  r.mCompositor.beginCommands(r.mContext)
  sceneTaskRoot.clearBuffer = r.mClearBuffer
  sceneTaskRoot.run(r.mContext, r.mCompositor)
  r.mCompositor.submitCommands(r.mContext)

  # clear the render tasks tree
  discard r.mSceneTaskStack.pop()
  if r.mRenderTargetStack.len > 0:
    discard r.mRenderTargetStack.pop()
  r.mRenderTaskList.setLen(0)
  r.mCompositorList.setLen(0)
  true

method dispose*(r: WgRenderer, data: RenderData) =
  if isNil(r.mContext.queue) or data == nil: return
  r.mDisposedPaints.add(data)

method region*(r: WgRenderer, data: RenderData): Region =
  if data == nil: return Region()
  if data of WgShape: return region(WgShape(data))
  if data of WgImage: return region(WgImage(data))
  Region()

method bounds*(r: WgRenderer, data: RenderData, pt4: var array[4, Point], m: Matrix): bool =
  if data == nil or not (data of WgShape): return false
  let shape = WgShape(data)
  if not shape.stroke.setting.valid: return false
  var bbox = initBBox()
  let verts = shape.stroke.mesh.vbuffer
  for i in 0 ..< verts.len:
    let pt = verts[i] * m
    bbox.min.x = min(bbox.min.x, pt.x)
    bbox.min.y = min(bbox.min.y, pt.y)
    bbox.max.x = max(bbox.max.x, pt.x)
    bbox.max.y = max(bbox.max.y, pt.y)
  pt4[0] = bbox.min
  pt4[1] = Point(x: bbox.max.x, y: bbox.min.y)
  pt4[2] = bbox.max
  pt4[3] = Point(x: bbox.min.x, y: bbox.max.y)
  true

method blend*(r: WgRenderer, m: BlendMethod): bool =
  r.mBlendMethod = if m == BlendMethod.Composition: BlendMethod.Normal else: m
  true

method colorSpace*(r: WgRenderer): ColorSpace =
  if r.mSurface != nil: r.mSurface.cs else: ColorSpace.Unknown

method mainSurface*(r: WgRenderer): RenderSurface =
  r.mSurface

method clear*(r: WgRenderer): bool =
  if r.mContext.invalid(): return false
  r.mClearBuffer = true
  true

method sync*(r: WgRenderer): bool =
  if r.mContext.invalid(): return false
  r.disposeObjects()

  # if texture buffer used
  var dstTexture = r.targetTexture
  if not isNil(r.surface):
    r.releaseSurfaceTexture()
    wgpuSurfaceGetCurrentTexture(r.surface, addr r.surfaceTexture)
    let st = r.surfaceTexture.status
    if st != WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal and st != WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal:
      r.releaseSurfaceTexture()
      return false
    dstTexture = r.surfaceTexture.texture

  if isNil(dstTexture):
    return false

  # insure that surface and offscreen target have the same size
  if wgpuTextureGetWidth(dstTexture) == r.mRenderTargetRoot.width and
     wgpuTextureGetHeight(dstTexture) == r.mRenderTargetRoot.height:
    let dstTextureView = r.mContext.createTextureView(dstTexture)
    var commandEncoder = r.mContext.createCommandEncoder()
    # show root offscreen buffer
    r.mCompositor.blit(r.mContext, commandEncoder, r.mRenderTargetRoot, dstTextureView, r.mSurface.premultiplied, r.mClearBuffer)
    r.mContext.submitCommandEncoder(commandEncoder)
    r.mContext.releaseCommandEncoder(commandEncoder)
    var dv = dstTextureView
    r.mContext.releaseTextureView(dv)

  if not isNil(r.surface):
    discard wgpuSurfacePresent(r.surface)
    r.releaseSurfaceTexture()

  r.mClearBuffer = false
  true

# composition --------------------------------------------------------------

method target*(r: WgRenderer, region: Region, cs: ColorSpace, flags: CompositionFlags): RenderCompositor =
  # create and setup compose data
  let compose = WgCompose()
  let full = Region(xMin: 0, yMin: 0, xMax: int32(r.mSurface.w), yMax: int32(r.mSurface.h))
  compose.aabb = intersect(region, full)
  compose.flags = flags
  compose.meth = MaskMethod.None
  compose.opacity = 255'u8
  compose.blend = BlendMethod.Normal
  r.mCompositorList.add(compose)
  RenderCompositor(compose)

method beginComposite*(r: WgRenderer, cmp: RenderCompositor, m: MaskMethod, opacity: uint8): bool =
  if cmp == nil or not (cmp of WgCompose): return false
  let compose = WgCompose(cmp)
  # allocate new render target and push to the render tree stack
  let newRenderTarget = r.mRenderTargetPool.allocate(r.mContext, compose.aabb)
  r.mRenderTargetStack.add(newRenderTarget)
  # current and new scenes
  if r.mSceneTaskStack.len == 0: return false
  let curSceneTask = r.mSceneTaskStack[^1]
  let newSceneTask = initWgSceneTask(newRenderTarget, compose, curSceneTask)

  let blending = CompositionFlag.Blending in compose.flags
  let masking = CompositionFlag.Masking in compose.flags
  # setup masking and blending scenes configuration
  if blending and masking:
    # new scene task must be as masked but not blended
    newSceneTask.compose.meth = curSceneTask.compose.meth
    newSceneTask.compose.opacity = 255'u8
    newSceneTask.compose.blend = BlendMethod.Normal
    newSceneTask.maskScene = curSceneTask.maskScene
    newSceneTask.dstScene = curSceneTask
    # cur scene task must be blended but not masked
    curSceneTask.compose.meth = MaskMethod.None
    curSceneTask.compose.opacity = opacity
    curSceneTask.compose.blend = r.mBlendMethod
    curSceneTask.maskScene = nil
  elif m != MaskMethod.None:
    # new scene task must be masked
    compose.masked = true
    newSceneTask.compose.masked = true
    newSceneTask.compose.meth = m
    newSceneTask.compose.opacity = opacity
    newSceneTask.compose.blend = BlendMethod.Normal
    newSceneTask.maskScene = curSceneTask
    newSceneTask.dstScene = curSceneTask.dstScene
    # cur scene task must not be blended
    curSceneTask.dstScene = nil
  else:
    # new scene task must be blended
    newSceneTask.compose.meth = MaskMethod.None
    newSceneTask.compose.opacity = opacity
    newSceneTask.compose.blend = r.mBlendMethod
    newSceneTask.maskScene = nil
    newSceneTask.dstScene = curSceneTask

  curSceneTask.children.add(WgRenderTask(newSceneTask))
  r.mRenderTaskList.add(WgRenderTask(newSceneTask))
  r.mSceneTaskStack.add(newSceneTask)
  true

method endComposite*(r: WgRenderer, cmp: RenderCompositor): bool =
  if cmp == nil or not (cmp of WgCompose): return false
  # pop targets and scenes from render tree
  if r.mRenderTargetStack.len > 0:
    r.mRenderTargetPool.pool.add(r.mRenderTargetStack[^1])
    discard r.mRenderTargetStack.pop()
  if r.mSceneTaskStack.len > 0:
    discard r.mSceneTaskStack.pop()
  # in a case of masked target we must pop mask targets and scenes also
  let compose = WgCompose(cmp)
  if compose.masked:
    if r.mRenderTargetStack.len > 0:
      r.mRenderTargetPool.pool.add(r.mRenderTargetStack[^1])
      discard r.mRenderTargetStack.pop()
    if r.mSceneTaskStack.len > 0:
      discard r.mSceneTaskStack.pop()
  true

# post effects -------------------------------------------------------------

method effectPrepare*(r: WgRenderer, effect: RenderEffect, tm: Matrix) =
  if effect == nil: return
  if effect.rd == nil:
    effect.rd = r.mEffectPool.allocate(r.mContext)
  if effect.rd == nil or not (effect.rd of WgRenderEffect): return
  let rdata = WgRenderEffect(effect.rd)

  case effect.kind
  of SceneEffect.GaussianBlur:
    if effect of GaussianBlurEffect:
      rdata.update(r.mContext, GaussianBlurEffect(effect), tm)
  of SceneEffect.DropShadow:
    if effect of DropShadowEffect:
      rdata.update(r.mContext, DropShadowEffect(effect), tm)
  of SceneEffect.Fill:
    if effect of FillEffect:
      rdata.update(r.mContext, FillEffect(effect))
  of SceneEffect.Tint:
    if effect of TintEffect:
      rdata.update(r.mContext, TintEffect(effect))
  of SceneEffect.Tritone:
    if effect of TritoneEffect:
      rdata.update(r.mContext, TritoneEffect(effect))
  of SceneEffect.MotionBlur:
    if effect of MotionBlurEffect:
      rdata.update(r.mContext, MotionBlurEffect(effect), tm)
  of SceneEffect.Clear:
    discard

method effectRegion*(r: WgRenderer, effect: RenderEffect): bool =
  if effect == nil or effect.rd == nil or not (effect.rd of WgRenderEffect): return false
  let rdata = WgRenderEffect(effect.rd)

  case effect.kind
  of SceneEffect.GaussianBlur:
    if effect of GaussianBlurEffect:
      let gaussian = GaussianBlurEffect(effect)
      if gaussian.direction != 2'u8:
        gaussian.extend.xMin = -int32(rdata.extend)
        gaussian.extend.xMax = int32(rdata.extend)
      if gaussian.direction != 1'u8:
        gaussian.extend.yMin = -int32(rdata.extend)
        gaussian.extend.yMax = int32(rdata.extend)
      return true
  of SceneEffect.DropShadow:
    if effect of DropShadowEffect:
      let dropShadow = DropShadowEffect(effect)
      dropShadow.extend.xMin = -int32(ceil(float32(rdata.extend) + abs(rdata.offset.x)))
      dropShadow.extend.yMin = -int32(ceil(float32(rdata.extend) + abs(rdata.offset.y)))
      dropShadow.extend.xMax = int32(floor(float32(rdata.extend) + abs(rdata.offset.x)))
      dropShadow.extend.yMax = int32(floor(float32(rdata.extend) + abs(rdata.offset.y)))
      return true
  of SceneEffect.MotionBlur:
    let x = int32(ceil(abs(rdata.offset.x) * 0.5'f32))
    let y = int32(ceil(abs(rdata.offset.y) * 0.5'f32))
    effect.extend = Region(xMin: -x, yMin: -y, xMax: x, yMax: y)
    return true
  else:
    discard
  false

method effectRender*(r: WgRenderer, cmp: RenderCompositor, effect: RenderEffect, direct: bool): bool =
  if r.mSceneTaskStack.len == 0 or effect == nil: return false
  let sceneTask = r.mSceneTaskStack[^1]
  sceneTask.effects.add(effect)
  true

method effectDispose*(r: WgRenderer, effect: RenderEffect) =
  if effect == nil or effect.rd == nil: return
  if effect.rd of WgRenderEffect:
    r.mEffectPool.free(r.mContext, WgRenderEffect(effect.rd))
  effect.rd = nil

# intersections ------------------------------------------------------------

method intersectsShape*(r: WgRenderer, data: RenderData, region: Region): bool =
  if data == nil or not (data of WgShape): return false
  let shape = WgShape(data)
  let bbox = Region(
    xMin: int32(shape.bbox.min.x), yMin: int32(shape.bbox.min.y),
    xMax: int32(shape.bbox.max.x), yMax: int32(shape.bbox.max.y))
  if intersected(region, bbox):
    if contained(bbox, region): return true
    return intersectsShapeData(shape, intersect(region, bbox))
  false

method intersectsImage*(r: WgRenderer, data: RenderData, region: Region): bool =
  if data == nil or not (data of WgImage): return false
  intersectsImageData(WgImage(data), region)

# WG-specific external target ---------------------------------------------

proc target*(r: WgRenderer; ctx: WgCanvasContext; target: pointer; w, h: uint32; cs: ColorSpace; typ: int = 0): Result =
  let opaque = (cs == ColorSpace.XBGR8888)
  if cs != ColorSpace.ABGR8888 and cs != ColorSpace.ABGR8888S and (not opaque): return Result.NonSupport
  if opaque and typ != 0: return Result.InvalidArguments

  if ctx.instance == nil or ctx.device == nil or target == nil:
    r.release()
    return Result.Success

  if w == 0'u32 or h == 0'u32: return Result.InvalidArguments

  var outCs = cs
  if opaque: outCs = ColorSpace.ABGR8888 # Opaque surface composition uses the internal ABGR format.

  # context has been changed, need to recreate all instances
  if (pointer(r.mContext.device) != ctx.device) or (pointer(r.mContext.instance) != ctx.instance) or
     (pointer(r.mContext.adapter) != ctx.adapter):
    r.release()
    r.mContext.initialize(ctx)
    r.mRenderTargetPool.initialize(w, h)
    r.mRenderTargetRoot.initialize(r.mContext, w, h)
    r.mCompositor.initialize(r.mContext, w, h)
  # update render targets dimensions
  elif (r.mSurface.w != w) or (r.mSurface.h != h) or
       (if typ == 0: (pointer(r.surface) != target) else: (pointer(r.targetTexture) != target)):
    r.mRenderTargetPool.release(r.mContext)
    r.mRenderTargetRoot.release(r.mContext)
    r.clearTargets()
    r.mRenderTargetPool.initialize(w, h)
    r.mRenderTargetRoot.initialize(r.mContext, w, h)
    r.mCompositor.resize(r.mContext, w, h)

  r.mSurface.stride = w
  r.mSurface.w = w
  r.mSurface.h = h
  # Keep alpha for internal composition; opaque mode only affects surface presentation.
  r.mSurface.cs = outCs
  r.mSurface.premultiplied = true # TODO: v1 backward compat; align with actual alpha mode later.
  r.mSurface.opaque = opaque

  # configure surface (must be called after context creation)
  if typ == 0:
    r.surfaceConfigure(r.mSurface, cast[WGPUSurface](target), r.mContext)
  else:
    r.targetTexture = cast[WGPUTexture](target)

  Result.Success
