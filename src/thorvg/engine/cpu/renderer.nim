## `SwRenderer`: the software (CPU) engine front end, plus `newSwCanvas`.
##
## Ported from `src/renderer/cpu_engine/tvgSwRenderer.cpp/.h` and `tvgSwCanvas.cpp`.
## The renderer subclasses `RenderMethod` and overrides its methods. Differences from
## C++ (DECISIONS.md D-T20-*): paints are prepared synchronously (no task scheduler),
## scene effects run scalar in `effects*.nim` (D-L1-*), no partial rendering (every frame is a full draw), no memory pool,
## and the target buffer is owned by the renderer (`SwSurface.data`), readable through
## `pixels` / `swSurface`. Composition targets are cached surfaces whose
## `compositor.image.surface` points back at themselves (D-T12b-4).
##
## Typical use: `let canvas = newSwCanvas(200, 200)`, add paints, `draw`, `sync`, then
## read `swSurface(canvas)` (e.g. with `display/imageio.writeBmp`).

import std/options
import ../../core/[types, geom]
import ../../renderer/[render, canvas, effect]
import ./[common, raster, blend, shape, rle_clip, swtask]
import ./[effects, effects_shadow, effects_color]

type SwRenderer* = ref object of RenderMethod
  surface*: SwSurface           ## active surface (the main one or a composition target)
  main: SwSurface               ## the target set by `target`
  antiAlias*: bool
  compositors: seq[SwSurface]   ## cache of composition render targets

proc newSwRenderer*(aliased = false): SwRenderer =
  ## `aliased` turns anti-aliasing off (`EngineOption::Aliased`).
  rasterInit()
  SwRenderer(antiAlias: not aliased)

proc clearCompositors(r: SwRenderer) =
  for s in r.compositors: s.compositor.image.surface = nil  # break the self reference
  r.compositors.setLen(0)

proc target*(r: SwRenderer, data: sink seq[uint32], stride, w, h: uint32,
    cs: ColorSpace = ColorSpace.ARGB8888): Result =
  ## Sets the pixel buffer (`stride` and `w` in pixels) the renderer draws into.
  if data.len == 0 or stride == 0 or w == 0 or h == 0 or w > stride or
      data.len < int(stride) * int(h): return Result.InvalidArguments
  if cs != ColorSpace.ABGR8888 and cs != ColorSpace.ABGR8888S and
      cs != ColorSpace.ARGB8888 and cs != ColorSpace.ARGB8888S: return Result.NonSupport
  r.clearCompositors()
  let s = SwSurface(data: data, stride: stride, w: w, h: h, cs: cs, channelSize: 4,
                    premultiplied: true)
  r.main = s
  r.surface = s
  rasterCompositor(s)

proc target*(r: SwRenderer, w, h: uint32, cs: ColorSpace = ColorSpace.ARGB8888): Result =
  ## Allocates a zeroed `w` x `h` target buffer.
  if w == 0 or h == 0: return Result.InvalidArguments
  r.target(newSeq[uint32](int(w) * int(h)), w, w, h, cs)

proc pixels*(r: SwRenderer): RenderSurface =
  ## The target surface (nil before `target`).
  r.main

# ---- RenderMethod: frame life cycle ---------------------------------------------

method preUpdate*(r: SwRenderer): bool = r.surface != nil
method postUpdate*(r: SwRenderer): bool = true
method preRender*(r: SwRenderer): bool = r.surface != nil

method postRender*(r: SwRenderer): bool =
  # unmultiply the alpha if the target wants straight colors
  if r.surface.cs == ColorSpace.ABGR8888S or r.surface.cs == ColorSpace.ARGB8888S:
    rasterUnpremultiplySurface(r.surface)
  true

method clear*(r: SwRenderer): bool =
  r.main != nil and rasterClear(r.main, 0, 0, int(r.main.w), int(r.main.h))

method sync*(r: SwRenderer): bool = true  # rendering is synchronous

method colorSpace*(r: SwRenderer): ColorSpace =
  if r.surface != nil: r.surface.cs else: ColorSpace.Unknown

method mainSurface*(r: SwRenderer): RenderSurface = r.surface

# ---- RenderMethod: preparation --------------------------------------------------

proc prepareCommon(r: SwRenderer, t: SwTask, tm: Matrix, clips: seq[RenderData],
    opacity: uint8, flags: RenderUpdateFlags, skip: bool) =
  let sfc = r.surface
  t.clipBox = intersect(r.vport, Region(xMin: 0, yMin: 0, xMax: int32(sfc.w),
                                        yMax: int32(sfc.h)))
  t.transform = tm
  t.opacity = opacity
  t.flags = flags
  t.valid = false
  if t.ready(skip): return
  if flags != {}:  # the merged `t.flags` only matter when something changed now
    if t.isImage: runImageTask(t, clips, sfc)
    else: runShapeTask(t, clips, sfc, r.antiAlias)

method prepareShape*(r: SwRenderer, rshape: RenderShape, data: RenderData, transform: Matrix,
    clips: seq[RenderData], opacity: uint8, flags: RenderUpdateFlags,
    clipper: bool): RenderData =
  if r.surface == nil: return data
  let t = if data != nil: SwTask(data) else: newShapeTask()
  t.rshape = rshape
  t.clipper = clipper
  r.prepareCommon(t, transform, clips, opacity, flags, opacity == 0 and not clipper)
  t

method prepareImage*(r: SwRenderer, surface: RenderSurface, data: RenderData,
    transform: Matrix, clips: seq[RenderData], opacity: uint8, filter: FilterMethod,
    flags: RenderUpdateFlags): RenderData =
  if r.surface == nil: return data
  let t = if data != nil: SwTask(data) else: newImageTask(surface)
  t.image.filter = filter
  r.prepareCommon(t, transform, clips, opacity, flags, opacity == 0)
  t

method dispose*(r: SwRenderer, data: RenderData) =
  if data != nil:  # memory is garbage collected: drop the caches
    let t = SwTask(data)
    if t.shape != nil: shapeFree(t.shape)
    t.shape = nil
    t.image = nil

method region*(r: SwRenderer, data: RenderData): Region =
  if data != nil: SwTask(data).bbox else: Region()

method bounds*(r: SwRenderer, data: RenderData, pt4: var array[4, Point], m: Matrix): bool =
  if data == nil: return false
  let t = SwTask(data)
  t.shape != nil and shapeStrokeBBox(t.shape, t.rshape, pt4, m)

method blend*(r: SwRenderer, m: BlendMethod): bool =
  if r.surface == nil: return false
  if r.surface.blendMethod == m: return true
  r.surface.blendMethod = m
  r.surface.blender = blenderFor(m)
  true

# ---- RenderMethod: drawing ------------------------------------------------------

proc fillShape(t: SwTask, sfc: SwSurface, bbox: Region) =
  if t.rshape.fill.isSome:
    discard rasterGradientShape(sfc, t.shape, bbox, t.rshape.fill.get, t.opacity)
  else:
    var c = t.rshape.color
    c.a = multiply(t.opacity, c.a)
    if c.a > 0: discard rasterShape(sfc, t.shape, bbox, c)

proc strokeShape(t: SwTask, sfc: SwSurface, bbox: Region) =
  if t.rshape.stroke.isNone: return
  if t.rshape.stroke.get.fill.isSome:
    discard rasterGradientStroke(sfc, t.shape, bbox, t.rshape.stroke.get.fill.get, t.opacity)
  else:
    var c = t.rshape.stroke.get.color
    c.a = multiply(t.opacity, c.a)
    if c.a > 0: discard rasterStroke(sfc, t.shape, bbox, c)

method renderShape*(r: SwRenderer, data: RenderData): bool =
  if data == nil: return false
  let t = SwTask(data)
  if t.valid:
    if t.rshape.strokeFirst:
      strokeShape(t, r.surface, t.bbox)
      fillShape(t, r.surface, t.shape.bbox)
    else:
      fillShape(t, r.surface, t.shape.bbox)
      strokeShape(t, r.surface, t.bbox)
  true

proc request(r: SwRenderer, channelSize: int, square: bool): SwSurface =
  ## A free composition surface (cached) of the main surface size.
  let w = if square: max(r.surface.w, r.surface.h) else: r.surface.w
  let h = if square: max(r.surface.w, r.surface.h) else: r.surface.h
  for cur in r.compositors:
    if cur.compositor.valid and int(cur.compositor.image.channelSize) == channelSize and
        cur.w == w and cur.h == h: return cur
  # a new composition inherits the attributes of the active surface
  let sfc = r.surface
  result = SwSurface(stride: w, w: w, h: h, cs: sfc.cs, channelSize: uint8(channelSize),
                     premultiplied: sfc.premultiplied, opaque: sfc.opaque, join: sfc.join,
                     alphas: sfc.alphas, blender: sfc.blender, blendMethod: sfc.blendMethod)
  if channelSize == 1: result.buf8 = newSeq[uint8](int(w) * int(h))
  else: result.data = newSeq[uint32](int(w) * int(h))
  result.compositor = SwCompositor(valid: true, image: SwImage(surface: result, w: w, h: h,
    stride: w, direct: true, channelSize: uint8(channelSize)))
  r.compositors.add result

proc rasterTaskImage(r: SwRenderer, img: SwImage, tm: Matrix, bbox: Region,
    opacity: uint8): bool =
  let sfc = r.surface
  if bbox.invalid or bbox.xMin >= int32(sfc.w) or bbox.yMin >= int32(sfc.h): return true
  if img.rle != nil:
    if img.rle.invalid: return true
    if img.direct: return rasterDirectRleImage(sfc, img, bbox, opacity)
    if img.scaled: return rasterScaledRleImage(sfc, img, tm, bbox, opacity)
    # an intermediate buffer for rle clipping
    let cmp = r.request(4, false)
    cmp.compositor.meth = MaskMethod.None
    cmp.compositor.valid = true
    cmp.compositor.image.rle = img.rle
    discard rasterClear(cmp, int(bbox.xMin), int(bbox.yMin), int(bbox.sw), int(bbox.sh))
    discard rasterTexmapPolygon(cmp, img, tm, bbox, 255)
    return rasterDirectRleImage(sfc, cmp.compositor.image, bbox, opacity)
  if img.direct: rasterDirectImage(sfc, img, bbox, opacity)
  elif img.scaled: rasterScaledImage(sfc, img, tm, bbox, opacity)
  else: rasterTexmapPolygon(sfc, img, tm, bbox, opacity)

method renderImage*(r: SwRenderer, data: RenderData): bool =
  if data == nil: return false
  let t = SwTask(data)
  if t.valid: discard r.rasterTaskImage(t.image, t.transform, t.bbox, t.opacity)
  true

# ---- RenderMethod: composition --------------------------------------------------

method target*(r: SwRenderer, region: Region, cs: ColorSpace,
    flags: CompositionFlags): RenderCompositor =
  let bbox = intersect(region, Region(xMin: 0, yMin: 0, xMax: int32(r.surface.w),
                                      yMax: int32(r.surface.h)))
  if bbox.invalid: return nil
  let cmp = r.request(int(channelSize(cs)), CompositionFlag.PostProcessing in flags)
  cmp.compositor.recoverSfc = r.surface
  cmp.compositor.recoverCmp = r.surface.compositor
  cmp.compositor.valid = false
  cmp.compositor.bbox = bbox
  discard rasterClear(cmp, int(bbox.xMin), int(bbox.yMin), int(bbox.sw), int(bbox.sh))
  r.surface = cmp  # switch the render target
  cmp.compositor

method beginComposite*(r: SwRenderer, cmp: RenderCompositor, m: MaskMethod,
    opacity: uint8): bool =
  if cmp == nil: return false
  let p = SwCompositor(cmp)
  p.meth = m
  p.opacity = opacity
  if m != MaskMethod.None:  # the current context
    r.surface = p.recoverSfc
    r.surface.compositor = p
  true

method endComposite*(r: SwRenderer, cmp: RenderCompositor): bool =
  if cmp == nil: return false
  let p = SwCompositor(cmp)
  r.surface = p.recoverSfc  # recover the context
  r.surface.compositor = p.recoverCmp
  if p.valid: return true  # only a surface in use can be composited
  p.valid = true
  if p.meth == MaskMethod.None:  # default is alpha blending
    return rasterDirectImage(r.surface, p.image, p.bbox, p.opacity)
  true

# ---- RenderMethod: scene effects ------------------------------------------------

method effectPrepare*(r: SwRenderer, effect: RenderEffect, tm: Matrix) =
  case effect.kind
  of SceneEffect.MotionBlur: motionBlurUpdate(MotionBlurEffect(effect), tm)
  of SceneEffect.GaussianBlur: gaussianBlurUpdate(GaussianBlurEffect(effect), tm)
  of SceneEffect.DropShadow: dropShadowUpdate(DropShadowEffect(effect), tm)
  of SceneEffect.Fill: fillUpdate(FillEffect(effect))
  of SceneEffect.Tint: tintUpdate(TintEffect(effect))
  of SceneEffect.Tritone: tritoneUpdate(TritoneEffect(effect))
  of SceneEffect.Clear: discard

method effectRegion*(r: SwRenderer, effect: RenderEffect): bool =
  if effect.rd == nil: return false
  case effect.kind
  of SceneEffect.MotionBlur: motionBlurRegion(MotionBlurEffect(effect))
  of SceneEffect.GaussianBlur: gaussianBlurRegion(GaussianBlurEffect(effect))
  of SceneEffect.DropShadow: dropShadowRegion(DropShadowEffect(effect))
  else: false

method effectRender*(r: SwRenderer, cmp: RenderCompositor, effect: RenderEffect,
    direct: bool): bool =
  let p = SwCompositor(cmp)
  if p.image.channelSize != 4: return false  # grayscale effects are not supported
  # any composition (masking, blending) prevents the direct rendering
  let masking = p.recoverCmp != nil and p.recoverCmp.meth != MaskMethod.None
  let direct = direct and not (p.recoverSfc.channelSize != 4 or masking or
                               p.recoverSfc.blender != nil)
  let cs = int(r.surface.channelSize)
  case effect.kind
  of SceneEffect.MotionBlur:
    result = effectMotionBlur(p, r.request(cs, true), MotionBlurEffect(effect))
  of SceneEffect.GaussianBlur:
    result = effectGaussianBlur(p, r.request(cs, true), GaussianBlurEffect(effect))
  of SceneEffect.DropShadow:
    let cmp1 = r.request(cs, true)
    cmp1.compositor.valid = false  # prevent a conflict with the cmp2 request
    let cmp2 = r.request(cs, true)
    result = effectDropShadow(p, cmp1, cmp2, DropShadowEffect(effect), direct)
    cmp1.compositor.valid = true
  of SceneEffect.Fill: result = effectFill(p, FillEffect(effect), direct)
  of SceneEffect.Tint: result = effectTint(p, TintEffect(effect), direct)
  of SceneEffect.Tritone: result = effectTritone(p, TritoneEffect(effect), direct)
  of SceneEffect.Clear: result = false

method effectDispose*(r: SwRenderer, effect: RenderEffect) =
  effect.rd = nil

# ---- RenderMethod: queries ------------------------------------------------------

method intersectsShape*(r: SwRenderer, data: RenderData, region: Region): bool =
  let t = SwTask(data)
  if not t.valid or not t.bbox.intersected(region): return false
  if rleIntersect(t.shape.strokeRle, region): return true
  t.shape.fastTrack or rleIntersect(t.shape.rle, region)

method intersectsImage*(r: SwRenderer, data: RenderData, region: Region): bool =
  let t = SwTask(data)
  if not t.valid or not t.bbox.intersected(region): return false
  # aabb & obb transformed image intersection
  let rad = radian(t.transform)
  if rad > 0.0'f32 and rad < MathPi:
    let aabb = [pt(float32(region.xMin), float32(region.yMin)),
                pt(float32(region.xMax), float32(region.yMin)),
                pt(float32(region.xMax), float32(region.yMax)),
                pt(float32(region.xMin), float32(region.yMax))]
    let w = float32(t.image.w)
    let h = float32(t.image.h)
    let obb = [pt(0.0'f32, 0.0'f32) * t.transform, pt(w, 0.0'f32) * t.transform,
               pt(w, h) * t.transform, pt(0.0'f32, h) * t.transform]
    proc project(poly: array[4, Point], axis: Point, lo, hi: var float32) =
      lo = dot(poly[0], axis)
      hi = lo
      for i in 1 ..< 4:
        let d = dot(poly[i], axis)
        if d < lo: lo = d
        if d > hi: hi = d
    for i in 0 ..< 4:
      var edge = if i < 2: aabb[(i + 1) mod 4] - aabb[i] else: obb[(i - 2 + 1) mod 4] - obb[i - 2]
      normalize(edge)
      var minA, maxA, minB, maxB: float32
      project(aabb, edge, minA, maxA)
      project(obb, edge, minB, maxB)
      if maxA < minB or maxB < minA: return false
  if t.image.rle != nil: rleIntersect(t.image.rle, region) else: true

# ---- canvas front end (SwCanvas) ------------------------------------------------

proc target*(c: Canvas, w, h: uint32, cs: ColorSpace = ColorSpace.ARGB8888): Result =
  ## `SwCanvas::target`: (re)allocates the pixel buffer of a software canvas.
  if c.renderer == nil or not (c.renderer of SwRenderer): return Result.InsufficientCondition
  let res = SwRenderer(c.renderer).target(w, h, cs)
  if res != Result.Success: return res
  c.retarget(w, h, cs)

proc newSwCanvas*(w, h: int, cs = ColorSpace.ARGB8888): Canvas =
  ## A canvas drawing with the CPU engine into a fresh `w` x `h` buffer.
  ## Raises `ValueError` for a non-positive size or an unsupported color space.
  if w <= 0 or h <= 0: raise newException(ValueError, "invalid canvas size")
  result = newCanvas(newSwRenderer())
  if result.target(uint32(w), uint32(h), cs) != Result.Success:
    raise newException(ValueError, "unsupported color space " & $cs)

proc swSurface*(c: Canvas): RenderSurface =
  ## The pixel surface of a software canvas (nil for other engines): valid after `sync`.
  if c.renderer != nil and c.renderer of SwRenderer: SwRenderer(c.renderer).main else: nil
