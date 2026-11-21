## Render tasks for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgRenderTask.h/.cpp (W5).
## Task hierarchy for paint, batch and scene rendering. Batch shapes/images and
## composition are staged via `WgCompositor`.

import std/math
import ../../core/[types, geom]
import ../../renderer/[render, effect]
import ./[wg_common, mesh, render_data, render_buffers, render_target, compositor]

type
  WgRenderTask* = ref object of RootObj
    parent*: WgRenderTask

  WgPaintTask* = ref object of WgRenderTask
    renderPaint*: WgPaint
    blendMethod*: BlendMethod

  WgBatchTask* = ref object of WgRenderTask
    shapes*: seq[WgShape]
    solidRange*: WgSolidBatchRange
    stencilRange*: WgStencilBatchRange
    blend*: BlendMethod
    stencilBatch*: bool

  WgImageBatchTask* = ref object of WgRenderTask
    images*: seq[WgImage]
    range*: WgImageBatchRange
    blend*: BlendMethod

  WgSceneTask* = ref object of WgRenderTask
    children*: seq[WgRenderTask]
    dstScene*: WgSceneTask
    maskScene*: WgSceneTask
    targetState*: WgRenderTargetState
    compose*: WgCompose
    composeMesh*: WgMesh
    effectMesh*: WgMesh
    effects*: seq[RenderEffect]
    clearBuffer*: bool

# ---- base helpers -------------------------------------------------------

method stage*(task: WgRenderTask; compositor: var WgCompositor) {.base.} = discard
method run*(task: WgRenderTask; ctx: var WgContext; compositor: var WgCompositor) {.base.} = discard

proc vport*(task: WgPaintTask): Region {.inline.} =
  if task.renderPaint == nil: Region() else: task.renderPaint.viewport

proc paintRegion(p: WgPaint): Region =
  if p == nil: return Region()
  if p of WgShape: return region(WgShape(p))
  if p of WgImage: return region(WgImage(p))
  p.viewport

proc aabb*(task: WgPaintTask): Region {.inline.} =
  paintRegion(task.renderPaint)

proc push*(parent, child: WgRenderTask) =
  if parent == nil or child == nil: return
  if parent of WgSceneTask:
    WgSceneTask(parent).children.add(child)
  child.parent = parent

# ---- WgBatchTask --------------------------------------------------------

proc initWgBatchTask*(first, second: WgShape; stencilBatch: bool): WgBatchTask =
  result = WgBatchTask(stencilBatch: stencilBatch, blend: BlendMethod.Normal)
  result.shapes = @[first, second]

method stage*(task: WgBatchTask; compositor: var WgCompositor) =
  if task.stencilBatch:
    compositor.requestStencilBatch(task.shapes, task.stencilRange)
  else:
    compositor.requestSolidBatch(task.shapes, task.solidRange)

method run*(task: WgBatchTask; ctx: var WgContext; compositor: var WgCompositor) =
  if task.stencilBatch:
    compositor.renderStencilBatch(task.shapes, task.stencilRange)
  else:
    compositor.renderSolidBatch(task.solidRange)

# ---- WgImageBatchTask ---------------------------------------------------

proc initWgImageBatchTask*(first, second: WgImage): WgImageBatchTask =
  result = WgImageBatchTask()
  result.images = @[first, second]

method stage*(task: WgImageBatchTask; compositor: var WgCompositor) =
  compositor.requestImageBatch(task.images, task.range)

method run*(task: WgImageBatchTask; ctx: var WgContext; compositor: var WgCompositor) =
  if task.images.len > 0:
    compositor.renderImageBatch(task.images[0], task.range)

# ---- WgPaintTask --------------------------------------------------------

proc initWgPaintTask*(paint: WgPaint; blendMethod: BlendMethod): WgPaintTask =
  WgPaintTask(renderPaint: paint, blendMethod: blendMethod)

method stage*(task: WgPaintTask; compositor: var WgCompositor) =
  if task.renderPaint == nil: return
  if task.renderPaint of WgShape:
    compositor.requestShape(WgShape(task.renderPaint))
  elif task.renderPaint of WgImage:
    compositor.requestImage(WgImage(task.renderPaint))

method run*(task: WgPaintTask; ctx: var WgContext; compositor: var WgCompositor) =
  if task.renderPaint == nil: return
  if task.renderPaint of WgShape:
    compositor.renderShape(ctx, WgShape(task.renderPaint), task.blendMethod)
  elif task.renderPaint of WgImage:
    compositor.renderImage(ctx, WgImage(task.renderPaint), task.blendMethod)

# ---- WgSceneTask --------------------------------------------------------

proc initWgSceneTask*(renderTarget: WgRenderTarget; compose: WgCompose; parent: WgSceneTask): WgSceneTask =
  result = WgSceneTask(dstScene: parent, compose: compose)
  result.targetState.target = renderTarget
  if compose != nil:
    result.targetState.bounds = compose.aabb
  elif renderTarget != nil:
    result.targetState.bounds = Region(xMin: 0, yMin: 0, xMax: int32(renderTarget.width), yMax: int32(renderTarget.height))
  result.parent = if parent != nil: WgRenderTask(parent) else: nil

proc mTransform*(task: WgSceneTask): Matrix {.inline.} =
  if task.compose == nil: identity() else: task.compose.transform

proc vport*(task: WgSceneTask): Region {.inline.} =
  task.targetState.bounds

proc aabb*(task: WgSceneTask): Region =
  if task.compose == nil or task.dstScene == nil:
    return task.vport()
  let w = task.vport().xMax - task.vport().xMin
  let h = task.vport().yMax - task.vport().yMin
  let m = task.compose.transform
  var p1 = Point(x: float32(task.vport().xMin), y: float32(task.vport().yMin)) * m
  var p2 = Point(x: float32(task.vport().xMin) + float32(w), y: float32(task.vport().yMin)) * m
  var p3 = Point(x: float32(task.vport().xMin) + float32(w), y: float32(task.vport().yMin) + float32(h)) * m
  var p4 = Point(x: float32(task.vport().xMin), y: float32(task.vport().yMin) + float32(h)) * m
  let expanded = Region(
    xMin: int32(floor(min(min(p1.x, p2.x), min(p3.x, p4.x)))),
    yMin: int32(floor(min(min(p1.y, p2.y), min(p3.y, p4.y)))),
    xMax: int32(ceil(max(max(p1.x, p2.x), max(p3.x, p4.x)))),
    yMax: int32(ceil(max(max(p1.y, p2.y), max(p3.y, p4.y))))
  )
  intersect(task.dstScene.aabb(), expanded)

proc runEffect(task: WgSceneTask; ctx: var WgContext; compositor: var WgCompositor; effect: RenderEffect) =
  if effect == nil: return
  case effect.kind
  of SceneEffect.GaussianBlur:
    if effect of GaussianBlurEffect:
      discard compositor.gaussianBlur(ctx, task.targetState, GaussianBlurEffect(effect), task.effectMesh)
  of SceneEffect.DropShadow:
    if effect of DropShadowEffect:
      discard compositor.dropShadow(ctx, task.targetState, DropShadowEffect(effect), task.effectMesh)
  of SceneEffect.Fill:
    if effect of FillEffect:
      discard compositor.fillEffect(ctx, task.targetState, FillEffect(effect), task.effectMesh)
  of SceneEffect.Tint:
    if effect of TintEffect:
      discard compositor.tintEffect(ctx, task.targetState, TintEffect(effect), task.effectMesh)
  of SceneEffect.Tritone:
    if effect of TritoneEffect:
      discard compositor.tritoneEffect(ctx, task.targetState, TritoneEffect(effect), task.effectMesh)
  of SceneEffect.MotionBlur:
    if effect of MotionBlurEffect:
      discard compositor.motionBlur(ctx, task.targetState, MotionBlurEffect(effect), task.effectMesh)
  of SceneEffect.Clear:
    discard

proc runChildren(task: WgSceneTask; ctx: var WgContext; compositor: var WgCompositor) =
  for child in task.children:
    compositor.beginRenderPassMS(ctx, task.targetState, false)
    child.run(ctx, compositor)

method stage*(task: WgSceneTask; compositor: var WgCompositor) =
  if invalid(task.targetState.bounds): return
  let dstPtr = if task.dstScene != nil: addr task.dstScene.targetState else: nil
  let maskPtr = if task.maskScene != nil: addr task.maskScene.targetState else: nil
  compositor.requestScene(task.targetState, task.composeMesh, task.effectMesh, dstPtr, maskPtr, task.effects.len > 0)
  for child in task.children:
    child.stage(compositor)

method run*(task: WgSceneTask; ctx: var WgContext; compositor: var WgCompositor) =
  if invalid(task.targetState.bounds): return
  compositor.beginRenderPassMS(ctx, task.targetState, task.clearBuffer)
  task.runChildren(ctx, compositor)
  compositor.endRenderPass()

  for effect in task.effects:
    task.runEffect(ctx, compositor, effect)

  if task.dstScene == nil or task.compose == nil:
    return

  if task.compose.meth == MaskMethod.None:
    compositor.beginRenderPassMS(ctx, task.dstScene.targetState, false)
    compositor.renderScene(ctx, task.targetState.target, task.compose, task.composeMesh)
  elif task.maskScene != nil:
    compositor.beginRenderPassMS(ctx, task.dstScene.targetState, false)
    compositor.composeScene(ctx, task.targetState.target, task.maskScene.targetState.target, task.compose, task.composeMesh)
