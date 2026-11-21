## GL renderer core, part 2: drawing (port of `GlRenderer::drawPrimitive`, `drawClip`,
## `renderShape`, `renderImage` and the helpers of tvgGlRenderer.cpp, unit G4a).
##
## Everything here only records render tasks into the current pass (CPU side); the GL work
## happens when G4b's `sync` runs the pass. See `renderer.nim` for the object and for the G4b
## TODO list. Exported: `packGradientBlock`, `drawPrimitive` (solid and gradient), `drawClip`,
## `skipRender`, and the `renderShape` / `renderImage` overrides.

import std/options
import ../../core/[types, geom, fill]
import ../../renderer/render
import ./[geometry, gl_common, gl_ffi, gpu_buffer, gpu_path, program, render_pass, render_target, render_task, renderer,
  stencil_batch, task_draw]

const
  NoiseLevel = 0.5'f32
  IdentityVertex = [-1.0'f32, 1, -1, -1, 1, 1, 1, -1]

func sameRegion(a, b: Region): bool =
  a.xMin == b.xMin and a.yMin == b.yMin and a.xMax == b.xMax and a.yMax == b.yMax

func isStroke(flag: RenderUpdateFlag): bool =
  flag == RenderUpdateFlag.Stroke or flag == RenderUpdateFlag.GradientStroke

func packGradientBlock*(stopInfo: var array[4, float32],
    stopPoints: var array[MaxGradientStops, float32],
    stopColors: var array[4 * MaxGradientStops, float32], stops: openArray[ColorStop],
    stopCnt: int, spread: FillSpread, alpha: float32): bool =
  ## `_packGradientBlock`: fills the shared part of the gradient blocks (stop count, noise,
  ## spread, offsets, premultiplied-free colors). Returns true if the gradient is fully opaque.
  stopInfo[1] = NoiseLevel
  stopInfo[2] = float32(ord(spread))

  result = alpha == 1.0'f32
  var nStops = 0
  for i in 0 ..< stopCnt:
    if nStops > 0 and stopPoints[nStops - 1] > stops[i].offset:
      result = false
      continue

    let index = nStops
    inc nStops
    stopPoints[index] = stops[i].offset
    stopColors[index * 4 + 0] = float32(stops[i].r) / 255.0'f32
    stopColors[index * 4 + 1] = float32(stops[i].g) / 255.0'f32
    stopColors[index * 4 + 2] = float32(stops[i].b) / 255.0'f32
    stopColors[index * 4 + 3] = float32(stops[i].a) / 255.0'f32 * alpha
    result = result and stops[i].a == 255
  stopInfo[0] = float32(nStops)

func skipRender*(clips: seq[RenderData]): bool =
  ## Clip masks are intersected, so one empty clip makes the paint invisible.
  for p in clips:
    let clip = GlShape(p)
    let flag = if clip.geometry.stroke.vertex.len > 0: RenderUpdateFlag.Stroke
               else: RenderUpdateFlag.Path
    if not clip.geometry.drawable({flag}): return true

func viewMatrixOf(g: GlGeometry, viewMatrix: Matrix, flag: RenderUpdateFlag): Matrix =
  ## Most meshes are in world space; local strokes fold the model matrix into the view matrix.
  if flag.isStroke: viewMatrix * g.matrix else: viewMatrix

proc primitiveBounds(shape: GlShape, flag: RenderUpdateFlag, vp: Region,
    viewBounds, bbox: var Region): bool =
  ## Shared prologue of both `drawPrimitive`s: false when nothing is visible.
  viewBounds = shape.geometry.viewport.intersect(vp)
  if viewBounds.invalid: return false
  let box = if flag.isStroke: gpuTransformBounds(shape.geometry.strokeBBox, shape.geometry.matrix)
            else: shape.geometry.fillBBox
  bbox = box.intersect(viewBounds)
  bbox.valid

proc drawPrimitive*(r: GlRenderer, shape: GlShape, c: RGBA, flag: RenderUpdateFlag,
    depth: int32) =
  ## Solid color fill or stroke of `shape`.
  if not shape.geometry.drawable({flag}): return

  let blendShape = r.mBlendMethod != BlendMethod.Normal
  let pass = r.currentPass()
  let vp = pass.getViewport()
  var viewBounds, bbox: Region
  if not primitiveBounds(shape, flag, vp, viewBounds, bbox): return

  let viewRegion = viewportRegion(vp, bbox)
  var stencilMode = shape.geometry.stencilMode({flag})
  let stroke = flag.isStroke

  if not stroke and isNativeBlend(r.mBlendMethod) and stencilMode == GlStencilMode.None and
      shape.clips.len == 0:
    r.solidBatch.draw(r.stage, pass, r.programs[ord(rtColor)], r.mBlendMethod, shape, c, depth,
      viewRegion, viewportRegion(vp, viewBounds))
    return

  if shape.clips.len > 0: r.solidBatch.clear()

  var dstCopyFbo: GlRenderTarget
  let task = r.createPrimitiveTask(rtColor, BlendSource.Solid, viewRegion, dstCopyFbo)
  task.setViewMatrix(viewMatrixOf(shape.geometry, pass.getViewMatrix(), flag))
  task.setDrawDepth(depth)

  var a = multiply(c.a, uint8(shape.opacity and 0xff'u32))
  if flag == RenderUpdateFlag.Stroke:
    let strokeWidth = shape.geometry.strokeRenderWidth
    if strokeWidth < MinGlStrokeWidth:
      let alpha = strokeWidth / MinGlStrokeWidth
      a = multiply(a, uint8(alpha * 255.0'f32))
  let color = RGBA(r: c.r, g: c.g, b: c.b, a: a)

  # A copied destination can be overwritten repeatedly. Native blending must keep stencil
  # coverage even for opaque, overlapping strokes.
  if stroke and (dstCopyFbo != nil or (not blendShape and a == 255)):
    stencilMode = GlStencilMode.None

  if stencilMode == GlStencilMode.None:
    task.setVertexColor(float32(color.r) / 255.0'f32, float32(color.g) / 255.0'f32,
      float32(color.b) / 255.0'f32, float32(color.a) / 255.0'f32)
  task.setViewport(viewRegion)

  let preparation = r.stencilBatch.prepare(r.stage, pass, r.programs[ord(rtStencil)], task,
    shape, flag, stencilMode, some(color), viewBounds)
  # Keep BlendRegion on the existing solid-shape blend UBO slot.
  r.bindBlendTarget(task, dstCopyFbo, viewRegion, 2)
  r.stencilBatch.draw(pass, task, preparation)

func linearWords(b: GlLinearGradientBlock): seq[float32] =
  result = @[]
  result.add b.nStops
  result.add b.startPos
  result.add b.endPos
  result.add b.stopPoints
  result.add b.stopColors
  result.add b.invTransform

func radialWords(b: GlRadialGradientBlock): seq[float32] =
  result = @[]
  result.add b.nStops
  result.add b.centerPos
  result.add b.radius
  result.add [0.0'f32, 0.0'f32]  # `alignas(16)` padding of the stop points
  result.add b.stopPoints
  result.add b.stopColors
  result.add b.invTransform

func conicWords(b: GlConicGradientBlock): seq[float32] =
  result = @[]
  result.add b.nStops
  result.add b.stopPoints
  result.add b.stopColors
  result.add b.invTransform

proc gradientInverse(shape: GlShape, fill: Fill, flag: RenderUpdateFlag): Matrix =
  ## World/local position -> gradient space (`inv(fill) * inv(shape)`; gradient strokes already
  ## get local positions, so no shape inverse there).
  discard inverse(fill.transform, result)
  if flag != RenderUpdateFlag.GradientStroke:
    result = result * shape.geometry.itransform()
  if fill.kind == FillKind.Conic: result = gpuConicTransform(fill.center, fill.angle) * result

proc drawPrimitive*(r: GlRenderer, shape: GlShape, fill: Fill, flag: RenderUpdateFlag,
    depth: int32) =
  ## Gradient fill or stroke of `shape`.
  if not shape.geometry.drawable({flag}): return

  let pass = r.currentPass()
  let vp = pass.getViewport()
  var viewBounds, bbox: Region
  if not primitiveBounds(shape, flag, vp, viewBounds, bbox): return

  let stopCnt = min(fill.stops.len, MaxGradientStops)
  if stopCnt < 1: return

  var fx, fy, fr: float32
  var taskType = rtLinGradient
  var blendSource = BlendSource.LinearGradient
  case fill.kind
  of FillKind.Linear: discard
  of FillKind.Radial:
    # Uncorrectable radial gradients use the last stop as a solid color.
    if not fill.correct(fx, fy, fr):
      let stop = fill.stops[^1]
      let solidFlag = if flag == RenderUpdateFlag.GradientStroke: RenderUpdateFlag.Stroke
                      else: RenderUpdateFlag.Color
      r.drawPrimitive(shape, RGBA(r: stop.r, g: stop.g, b: stop.b, a: stop.a), solidFlag, depth)
      return
    taskType = rtRadGradient
    blendSource = BlendSource.RadialGradient
  of FillKind.Conic:
    taskType = rtConGradient
    blendSource = BlendSource.ConicGradient

  let viewRegion = viewportRegion(vp, bbox)
  var dstCopyFbo: GlRenderTarget
  let task = r.createPrimitiveTask(taskType, blendSource, viewRegion, dstCopyFbo)
  task.setViewMatrix(viewMatrixOf(shape.geometry, pass.getViewMatrix(), flag))
  task.setDrawDepth(depth)
  task.setViewport(viewRegion)

  let invMat3 = getMatrix3Std140(gradientInverse(shape, fill, flag))
  var alpha = float32(shape.opacity) / 255.0'f32
  if flag == RenderUpdateFlag.GradientStroke:
    let strokeWidth = shape.geometry.strokeRenderWidth
    if strokeWidth < MinGlStrokeWidth: alpha *= strokeWidth / MinGlStrokeWidth

  var opaque: bool
  var words: seq[float32]
  case fill.kind
  of FillKind.Linear:
    var blk: GlLinearGradientBlock
    opaque = packGradientBlock(blk.nStops, blk.stopPoints, blk.stopColors, fill.stops, stopCnt,
      fill.spread, alpha)
    blk.startPos = [fill.p1.x, fill.p1.y]
    blk.endPos = [fill.p2.x, fill.p2.y]
    blk.invTransform = invMat3
    words = linearWords(blk)
  of FillKind.Radial:
    var blk: GlRadialGradientBlock
    opaque = packGradientBlock(blk.nStops, blk.stopPoints, blk.stopColors, fill.stops, stopCnt,
      fill.spread, alpha)
    blk.centerPos = [fx, fy, fill.center.x, fill.center.y]
    blk.radius = [fr, fill.r]
    blk.invTransform = invMat3
    words = radialWords(blk)
  of FillKind.Conic:
    var blk: GlConicGradientBlock
    opaque = packGradientBlock(blk.nStops, blk.stopPoints, blk.stopColors, fill.stops, stopCnt,
      FillSpread.Pad, alpha)
    blk.invTransform = invMat3
    words = conicWords(blk)

  let gradientOffset = r.stage.push(words, true)
  task.addBindResource(uniformBinding(2, GlShaderUniformBlock.GradientInfo,
    r.stage.getBufferId(), gradientOffset, words.len * 4))
  r.bindBlendTarget(task, dstCopyFbo, viewRegion, 3)

  var stencilMode = shape.geometry.stencilMode({flag})
  if flag.isStroke and (dstCopyFbo != nil or (r.mBlendMethod == BlendMethod.Normal and opaque)):
    stencilMode = GlStencilMode.None
  let preparation = r.stencilBatch.prepare(r.stage, pass, r.programs[ord(rtStencil)], task,
    shape, flag, stencilMode, none(RGBA), viewBounds)
  r.stencilBatch.draw(pass, task, preparation)

proc drawClip*(r: GlRenderer, clips: seq[RenderData], viewBounds: Region) =
  ## One clip task (stencil of the clip shape + full-view mask) per clip, intersected.
  if viewBounds.invalid: return

  # Clip is a render boundary.
  r.stencilBatch.clear()

  let pass = r.currentPass()
  let buffer = r.stage.getBufferId()
  let identityVertexOffset = r.stage.push(IdentityVertex)
  let identityIndexOffset = r.stage.pushIndex(RectIndex)

  var clipDepths = newSeq[int32](clips.len)
  for i in countdown(clips.len - 1, 0): clipDepths[i] = int32(pass.nextDrawDepth())

  let passViewport = pass.getViewport()
  let viewMatrix = pass.getViewMatrix()
  let viewRegion = viewportRegion(passViewport, viewBounds)

  for i in 0 ..< clips.len:
    let shape = GlShape(clips[i])
    let flag = if shape.geometry.stroke.vertex.len > 0: RenderUpdateFlag.Stroke
               else: RenderUpdateFlag.Path

    let clipTask = newGlRenderTask(r.programs[ord(rtStencil)])
    clipTask.setDrawDepth(clipDepths[i])
    clipTask.setViewMatrix(viewMatrixOf(shape.geometry, viewMatrix, flag))
    shape.geometry.draw(clipTask, r.stage, {flag})

    let clipBounds = shape.geometry.bounds().intersect(viewBounds)
    clipTask.setViewport(viewportRegion(passViewport, clipBounds))

    let maskTask = newGlRenderTask(r.programs[ord(rtStencil)])
    maskTask.setDrawDepth(clipDepths[i])
    maskTask.addVertexLayout(GlVertexLayout(index: 0, size: 2, stride: 8,
      offset: identityVertexOffset, ty: GlFloat, normalized: false, arrayBufferId: buffer))
    maskTask.setDrawRange(uint32(identityIndexOffset), RectIndexCount)
    maskTask.setViewport(viewRegion)

    pass.addRenderTask(newGlClipTask(clipTask, maskTask))

method renderImage*(r: GlRenderer, data: RenderData): bool =
  let image = GlImage(data)
  if image == nil: return false

  var pass = r.currentPass()
  if pass == nil: return false
  if pass.isEmpty: return true

  var vp = pass.getViewport()
  let bbox = image.geometry.viewport.intersect(vp)
  if bbox.invalid: return true
  if not image.geometry.drawable({RenderUpdateFlag.Image}): return true
  if skipRender(image.clips): return true

  let drawDepth = int32(pass.nextDrawDepth())

  let nativeBlend = isNativeBlend(r.mBlendMethod)
  if pass.fbo == r.rootTarget and nativeBlend and image.clips.len == 0 and
      sameRegion(image.geometry.viewport, vp):
    let viewRegion = viewportRegion(vp, bbox)
    r.solidBatch.draw(r.stage, pass, r.programs[ord(rtImage)], r.mBlendMethod, image, drawDepth,
      viewRegion, viewRegion)
    return true

  if image.clips.len > 0: r.drawClip(image.clips, bbox)

  let task = newGlRenderTask(r.programs[ord(rtImage)],
    if nativeBlend: r.mBlendMethod else: BlendMethod.Normal)
  task.setDrawDepth(drawDepth)
  image.geometry.draw(task, r.stage, {RenderUpdateFlag.Image})

  let complexBlend = r.beginComplexBlending(bbox, image.geometry.bounds())
  pass = r.currentPass()
  if complexBlend: vp = pass.getViewport()
  task.setViewMatrix(pass.getViewMatrix())

  let info = [image.opacity, 0'u32, 0, 0]
  task.addBindResource(uniformBinding(1, GlShaderUniformBlock.ColorInfo, r.stage.getBufferId(),
    r.stage.push(info, true), 16))

  # texture id
  task.addBindResource(textureBinding(0, image.texId, GlShaderUniform.Texture))
  task.setViewport(viewportRegion(vp, bbox.intersect(vp)))
  pass.addRenderTask(task)

  if complexBlend:
    let stencil = newGlRenderTask(r.programs[ord(rtStencil)])
    image.geometry.draw(stencil, r.stage, {RenderUpdateFlag.Image})
    r.endBlendingCompose(stencil)

  true

method renderShape*(r: GlRenderer, data: RenderData): bool =
  let shape = GlShape(data)
  if shape == nil: return false

  let pass = r.currentPass()
  if pass == nil: return false
  if pass.isEmpty or (not shape.valid.fill and not shape.valid.stroke): return true

  let bbox = shape.geometry.viewport.intersect(pass.getViewport())
  if bbox.invalid: return true
  if skipRender(shape.clips): return true

  var drawDepth1, drawDepth2 = 0'i32
  if shape.valid.fill: drawDepth1 = int32(pass.nextDrawDepth())
  if shape.valid.stroke: drawDepth2 = int32(pass.nextDrawDepth())

  if shape.clips.len > 0: r.drawClip(shape.clips, bbox)

  template processFill() =
    if shape.valid.fill:
      if shape.rshape.fill.isSome:
        r.drawPrimitive(shape, shape.rshape.fill.get, RenderUpdateFlag.Gradient, drawDepth1)
      elif shape.rshape.color.a > 0:
        r.drawPrimitive(shape, shape.rshape.color, RenderUpdateFlag.Color, drawDepth1)

  template processStroke() =
    if shape.valid.stroke:
      let stroke = shape.rshape.stroke.get
      if stroke.fill.isSome:
        r.drawPrimitive(shape, stroke.fill.get, RenderUpdateFlag.GradientStroke, drawDepth2)
      elif stroke.color.a > 0:
        r.drawPrimitive(shape, stroke.color, RenderUpdateFlag.Stroke, drawDepth2)

  if shape.rshape.strokeFirst:
    processStroke()
    processFill()
  else:
    processFill()
    processStroke()
  true
