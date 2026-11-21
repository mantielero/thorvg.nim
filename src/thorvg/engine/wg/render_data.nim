## Render data structures for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgRenderData.h/.cpp (paints, settings, effects).
## Stage buffers and batch ranges are in `render_buffers.nim`.

import std/[math, options]
import ../../core/[types, geom, path]
import ../../core/fill as fillmod
import ../../renderer/[render, effect, trim]
import ../gl/[gpu_path, gpu_dash]
import ./[wg_ffi, wg_common, bind_groups, shader_types, mesh, tessellator, texture_mgr]

type Fill = fillmod.Fill
type FillKind = fillmod.FillKind

type
  WgRenderRegion* = Region

  WgRenderSettingsType* = enum
    rstNone = 0
    rstSolid = 1
    rstLinear = 2
    rstRadial = 3
    rstConic = 4

  WgGradientTexture* = object
    texture*: WGPUTexture
    textureView*: WGPUTextureView
    bindGroup*: WGPUBindGroup

  RenderColor* = RGBA

  WgSolidFill* = object
    colorIdx*: uint32
    color*: RenderColor
    opacity*: uint8

  WgRenderSettings* = object
    bindGroupIdx*: uint32
    settings*: WgShaderTypePaintSettings
    gradientDataTex*: WgGradientTexture
    fillType*: WgRenderSettingsType
    opacityMultiplier*: float32
    valid*: bool
    opaque*: bool
    spread*: FillSpread

  WgPaint* = ref object of RenderData
    viewport*: Region
    clips*: seq[WgPaint]
    transform*: Matrix

  WgShapeData* = object
    setting*: WgRenderSettings
    solid*: WgSolidFill
    mesh*: WgMesh
    bbox*: BBox

  WgStrokeData* = object
    setting*: WgRenderSettings
    solid*: WgSolidFill
    mesh*: WgMesh
    bboxMesh*: WgMesh
    bbox*: BBox

  WgShape* = ref object of WgPaint
    shape*: WgShapeData
    stroke*: WgStrokeData
    bboxMesh*: WgMesh
    bbox*: BBox
    strokeViewMatIdx*: uint32
    fillRule*: FillRule
    convex*: bool
    strokeFirst*: bool
    strokeOverlapFree*: bool

  WgImage* = ref object of WgPaint
    surface*: RenderSurface
    setting*: WgRenderSettings
    texture*: WGPUTexture
    bindGroup*: WGPUBindGroup
    mesh*: WgMesh
    stamp*: uint16
    filter*: FilterMethod

  WgRenderEffect* = ref object of effect.EffectData
    bindGroupParams*: WGPUBindGroup
    bufferParams*: WGPUBuffer
    extend*: uint32
    offset*: Point

  WgRenderEffectPool* = ref object
    pool*: seq[WgRenderEffect]
    list*: seq[WgRenderEffect]

func premultiply(c: uint8, a: uint8): uint8 {.inline.} =
  uint8((uint32(c) * uint32(a) + 0xff'u32) shr 8)

func packedColor*(s: WgSolidFill): RenderColor =
  RGBA(r: s.color.r, g: s.color.g, b: s.color.b, a: premultiply(s.color.a, s.opacity))


func isFiniteF32*(x: float32): bool {.inline.} =
  x == x and x != Inf and x != NegInf

#************************************************************************
# WgGradientTexture
#************************************************************************

proc update*(gt: var WgGradientTexture; ctx: var WgContext; fill: Fill; currentSpread: var FillSpread): bool =
  var gradientData: WgShaderTypeGradientData
  let opaque = gradientData.update(fill)
  let bytesPerRow = uint32(WG_TEXTURE_GRADIENT_SIZE * 4)
  let texHandleChanged = ctx.allocateTexture(gt.texture, uint32(WG_TEXTURE_GRADIENT_SIZE), 1'u32,
      WGPUTextureFormat_RGBA8Unorm, addr gradientData.data[0], bytesPerRow, uint64(bytesPerRow))
  if texHandleChanged:
    ctx.releaseTextureView(gt.textureView)
    gt.textureView = ctx.createTextureView(gt.texture)
  let spread = if fill.kind == FillKind.Conic: FillSpread.Repeat else: fill.spread
  if texHandleChanged or currentSpread != spread:
    var sampler = ctx.samplerLinearClamp
    if spread == FillSpread.Reflect: sampler = ctx.samplerLinearMirror
    if spread == FillSpread.Repeat: sampler = ctx.samplerLinearRepeat
    ctx.layouts.releaseBindGroup(gt.bindGroup)
    gt.bindGroup = ctx.layouts.createBindGroupTexSampled(sampler, gt.textureView)
    currentSpread = spread
  opaque

proc release*(gt: var WgGradientTexture; ctx: var WgContext) =
  ctx.layouts.releaseBindGroup(gt.bindGroup)
  ctx.releaseTextureView(gt.textureView)
  ctx.releaseTexture(gt.texture)

#************************************************************************
# WgRenderSettings
#************************************************************************

proc update*(s: var WgRenderSettings; cs: ColorSpace; opacity: uint8): uint8 =
  let effectiveOpacity = uint8(float32(opacity) * s.opacityMultiplier)
  s.settings.options.update(cs, effectiveOpacity)
  effectiveOpacity

proc update*(s: var WgRenderSettings; ctx: var WgContext; fill: Fill; transform: ptr Matrix; updateColorRamp: bool) =
  s.settings.gradient.update(fill, transform)
  if updateColorRamp:
    s.opaque = s.gradientDataTex.update(ctx, fill, s.spread)
  case fill.kind
  of FillKind.Linear: s.fillType = rstLinear
  of FillKind.Radial: s.fillType = rstRadial
  of FillKind.Conic: s.fillType = rstConic

proc release*(s: var WgRenderSettings; ctx: var WgContext) =
  s.gradientDataTex.release(ctx)

#************************************************************************
# WgPaint / WgShape
#************************************************************************

proc assign*(p: WgPaint; clips: openArray[RenderData]) =
  p.clips.setLen(0)
  for c in clips:
    if c of WgPaint:
      p.clips.add(WgPaint(c))

proc expand*(s: WgShape; bb: BBox) =
  s.bbox.min.x = min(s.bbox.min.x, bb.min.x)
  s.bbox.min.y = min(s.bbox.min.y, bb.min.y)
  s.bbox.max.x = max(s.bbox.max.x, bb.max.x)
  s.bbox.max.y = max(s.bbox.max.y, bb.max.y)

proc region*(s: WgShape): Region =
  Region(xMin: int32(round(s.bbox.min.x)), yMin: int32(round(s.bbox.min.y)),
         xMax: int32(round(s.bbox.max.x)), yMax: int32(round(s.bbox.max.y)))

proc reset*(s: WgShape) =
  s.clips.setLen(0)
  s.stroke.mesh.clear()
  s.stroke.bboxMesh.clear()
  s.stroke.bbox = initBBox()
  s.shape.mesh.clear()
  s.shape.bbox = initBBox()
  s.bboxMesh.clear()
  s.bbox = initBBox()

proc release*(s: WgShape; ctx: var WgContext) =
  s.reset()
  s.stroke.setting.release(ctx)
  s.shape.setting.release(ctx)

proc updateStyle*(s: WgShape; rshape: RenderShape; vport: Region;
                  shapeOpacity, strokeOpacity, opacity: uint8) =
  let shapeAlpha = if rshape.fill.isSome: 255'u8 else: rshape.color.a
  s.shape.setting.valid = rshape.fill.isSome or (uint32(shapeAlpha) * uint32(opacity) > 0'u32)
  let strokeAlpha = if rshape.stroke.isSome and rshape.stroke.get.fill.isSome: 255'u8
                    elif rshape.stroke.isSome: rshape.stroke.get.color.a
                    else: 0'u8
  s.stroke.setting.valid = rshape.stroke.isSome and (uint32(strokeAlpha) * uint32(opacity) > 0'u32)
  s.shape.solid.opacity = shapeOpacity
  s.stroke.solid.opacity = strokeOpacity
  s.fillRule = rshape.rule
  s.viewport = vport

proc update*(s: WgShape; rshape: RenderShape; transform: Matrix; flag: RenderUpdateFlags) =
  s.reset()
  s.convex = false
  s.strokeFirst = rshape.strokeFirst()
  s.shape.setting.opacityMultiplier = 1.0'f32
  s.stroke.setting.opacityMultiplier = 1.0'f32

  # optimize path
  var optPath = RenderPath()
  var optStrokePath = RenderPath()
  let strokeWidth = rshape.strokeWidth()
  let wantLocal = isFiniteF32(strokeWidth) and not zero(strokeWidth)
  var optPathThin = false
  var optPathSkipFill = false

  if rshape.trimpath() and rshape.stroke.isSome:
    var trimmed = RenderPath()
    if rshape.stroke.get.trim.trim(rshape.path, trimmed):
      let res = gpuOptimize(trimmed, transform, wantLocal)
      optPath = res.transformed
      optStrokePath = res.local
      optPathThin = res.thin
      optPathSkipFill = res.skipFill
    else:
      optPath.clear()
  else:
    let res = gpuOptimize(rshape.path, transform, wantLocal)
    optPath = res.transformed
    optStrokePath = res.local
    optPathThin = res.thin
    optPathSkipFill = res.skipFill

  let updatePath = (RenderUpdateFlag.Transform in flag) or (RenderUpdateFlag.Path in flag)

  # update fill
  if updatePath or (RenderUpdateFlag.Color in flag) or (RenderUpdateFlag.Gradient in flag):
    if optPathSkipFill:
      s.shape.mesh.clear()
    else:
      var bbox = initBBox()
      if optPathThin and zero(rshape.strokeWidth()):
        var stroker = initWgStroker(addr s.shape.mesh, MIN_WG_STROKE_WIDTH, StrokeCap.Butt, StrokeJoin.Bevel)
        stroker.run(optPath, true)
        bbox = stroker.getBBox()
        s.shape.setting.opacityMultiplier = MIN_WG_STROKE_ALPHA
      else:
        var tess = initWgBWTessellator(addr s.shape.mesh)
        tess.tessellate(optPath)
        s.convex = tess.convex
        bbox = tess.getBBox()
      if s.shape.mesh.ibuffer.len == 0:
        s.shape.mesh.clear()
      else:
        s.shape.bbox = bbox
        s.expand(bbox)

  # update stroke
  if rshape.stroke.isSome and (updatePath or (RenderUpdateFlag.Stroke in flag) or (RenderUpdateFlag.GradientStroke in flag)):
    let stroke = rshape.stroke.get
    let qualityScale0 = scaling(transform)
    var qualityScale = if isFiniteF32(qualityScale0) and not zero(qualityScale0): qualityScale0 else: 1.0'f32
    var strokeWidthWorld = strokeWidth * qualityScale
    if not isFiniteF32(strokeWidthWorld): strokeWidthWorld = strokeWidth
    if not isFiniteF32(strokeWidthWorld): strokeWidthWorld = 0.0'f32
    if not zero(strokeWidthWorld):
      var stroker = initWgStroker(addr s.stroke.mesh, strokeWidth, stroke.cap, stroke.join, stroke.miterlimit, qualityScale)
      var dashed = RenderPath()
      if gpuStrokeDash(rshape, Matrix(), false, dashed): # matrix/applyTransform not used as identity path in Nim API? adapt: use identity
        stroker.run(dashed)
      else:
        stroker.run(optStrokePath)
      s.strokeOverlapFree = stroker.overlapFree
      s.stroke.setting.opacityMultiplier = 1.0'f32
      if s.stroke.mesh.ibuffer.len == 0:
        s.stroke.mesh.clear()
      else:
        let bbox = stroker.getBBox()
        s.stroke.bbox = bbox
        s.stroke.bboxMesh.bbox(bbox.min, bbox.max)
        let strokeBounds = gpuTransformBounds(stroker.bounds(), transform)
        s.expand(BBox(
          min: Point(x: float32(strokeBounds.xMin), y: float32(strokeBounds.yMin)),
          max: Point(x: float32(strokeBounds.xMax), y: float32(strokeBounds.yMax))))

  if s.shape.mesh.vbuffer.len == 0 and s.stroke.mesh.vbuffer.len == 0:
    s.bbox = BBox(min: Point(x: 0.0'f32, y: 0.0'f32), max: Point(x: 0.0'f32, y: 0.0'f32))
  s.bboxMesh.bbox(s.bbox.min, s.bbox.max)

#************************************************************************
# WgImage
#************************************************************************

proc update*(img: WgImage; surface: RenderSurface; transform: Matrix) =
  img.mesh.imageBox(float32(surface.w), float32(surface.h), transform)

proc setup*(img: WgImage; texture: WGPUTexture; bindGroup: WGPUBindGroup; surface: RenderSurface; filter: FilterMethod; stamp: uint16) =
  img.texture = texture
  img.bindGroup = bindGroup
  img.surface = if not isNil(texture): surface else: nil
  img.filter = filter
  img.stamp = if not isNil(texture): stamp else: 0'u16

proc reset*(img: WgImage) =
  img.texture = WGPUTexture(nil)
  img.bindGroup = WGPUBindGroup(nil)
  img.surface = nil
  img.filter = FilterMethod.Bilinear
  img.stamp = 0

proc release*(img: WgImage; textures: var WgTextureMgr; ctx: var WgContext) =
  if (not isNil(img.texture)) and img.stamp == textures.stamp and img.surface != nil:
    textures.release(ctx, img.surface, img.filter, img.texture)
  img.reset()

proc release*(img: WgImage; ctx: var WgContext) =
  img.clips.setLen(0)
  img.setting.release(ctx)
  img.reset()

proc region*(img: WgImage): Region = img.viewport

#************************************************************************
# WgRenderEffect / Pool
#************************************************************************

proc updateParams*(e: WgRenderEffect; ctx: var WgContext; params: var WgShaderTypeEffectParams) =
  if ctx.allocateBufferUniform(e.bufferParams, addr params.params[0], uint64(sizeof(params.params))):
    ctx.layouts.releaseBindGroup(e.bindGroupParams)
    e.bindGroupParams = ctx.layouts.createBindGroupBuffer1Un(e.bufferParams)

proc update*(e: WgRenderEffect; ctx: var WgContext; gaussian: GaussianBlurEffect; transform: Matrix) =
  var params: WgShaderTypeEffectParams
  if not params.update(gaussian, transform): return
  e.updateParams(ctx, params)
  e.extend = params.extend

proc update*(e: WgRenderEffect; ctx: var WgContext; dropShadow: DropShadowEffect; transform: Matrix) =
  var params: WgShaderTypeEffectParams
  if not params.update(dropShadow, transform): return
  e.updateParams(ctx, params)
  e.extend = params.extend
  e.offset = params.offset

proc update*(e: WgRenderEffect; ctx: var WgContext; fill: FillEffect) =
  var params: WgShaderTypeEffectParams
  if not params.update(fill): return
  e.updateParams(ctx, params)

proc update*(e: WgRenderEffect; ctx: var WgContext; tint: TintEffect) =
  var params: WgShaderTypeEffectParams
  if not params.update(tint): return
  e.updateParams(ctx, params)

proc update*(e: WgRenderEffect; ctx: var WgContext; tritone: TritoneEffect) =
  var params: WgShaderTypeEffectParams
  if not params.update(tritone): return
  e.updateParams(ctx, params)

proc update*(e: WgRenderEffect; ctx: var WgContext; motion: MotionBlurEffect; transform: Matrix) =
  var params: WgShaderTypeEffectParams
  if not params.update(motion, transform): return
  e.updateParams(ctx, params)
  e.offset = params.offset

proc release*(e: WgRenderEffect; ctx: var WgContext) =
  if e == nil: return
  ctx.releaseBuffer(e.bufferParams)
  ctx.layouts.releaseBindGroup(e.bindGroupParams)

proc allocate*(pool: WgRenderEffectPool; ctx: var WgContext): WgRenderEffect =
  if pool.pool.len > 0:
    result = pool.pool[^1]
    pool.pool.setLen(pool.pool.len - 1)
  else:
    result = WgRenderEffect()
    pool.list.add(result)

proc free*(pool: WgRenderEffectPool; ctx: var WgContext; rdata: WgRenderEffect) =
  if rdata != nil:
    pool.pool.add(rdata)

proc release*(pool: WgRenderEffectPool; ctx: var WgContext) =
  for p in pool.list:
    if p != nil: p.release(ctx)
  pool.pool.setLen(0)
  pool.list.setLen(0)
