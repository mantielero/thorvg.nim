## Stencil batch grouping for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgStencilBatch.h/.cpp (W5/W6).

import std/math
import ../../core/[types, geom]
import ./[render_data, render_task]

type
  WgStencilBatch* = object
    sceneTask*: WgSceneTask
    task*: WgRenderTask
    first*: WgShape
    viewport*: Region
    fillRule*: FillRule
    ySorted*: bool
    bounds*: seq[Region]

proc initWgStencilBatch*(): WgStencilBatch = WgStencilBatch()

proc clampf64(v, lo, hi: float64): float64 =
  if v < lo: lo elif v > hi: hi else: v

proc eligible(rdata: WgShape; blendMethod: BlendMethod; bounds: var Region): bool =
  if blendMethod != BlendMethod.Normal or rdata == nil or (not rdata.shape.setting.valid): return false

  if rdata.convex or invalid(rdata.viewport) or rdata.clips.len > 0: return false
  if rdata.shape.mesh.vbuffer.len == 0 or rdata.shape.mesh.ibuffer.len == 0 or
     rdata.bboxMesh.vbuffer.len == 0 or rdata.bboxMesh.ibuffer.len == 0: return false
  if rdata.stroke.setting.valid and rdata.stroke.mesh.ibuffer.len > 0: return false

  # Clip finite geometry bounds to the viewport before rounding to the integer overlap region.
  let bbox = rdata.bbox
  if not (isFiniteF32(bbox.min.x) and isFiniteF32(bbox.min.y) and isFiniteF32(bbox.max.x) and isFiniteF32(bbox.max.y)):
    return false

  let minX = clampf64(float64(bbox.min.x), float64(rdata.viewport.xMin), float64(rdata.viewport.xMax))
  let minY = clampf64(float64(bbox.min.y), float64(rdata.viewport.yMin), float64(rdata.viewport.yMax))
  let maxX = clampf64(float64(bbox.max.x), float64(rdata.viewport.xMin), float64(rdata.viewport.xMax))
  let maxY = clampf64(float64(bbox.max.y), float64(rdata.viewport.yMin), float64(rdata.viewport.yMax))
  if maxX <= minX or maxY <= minY: return false

  bounds = Region(xMin: int32(floor(minX)), yMin: int32(floor(minY)), xMax: int32(ceil(maxX)), yMax: int32(ceil(maxY)))
  true

proc regionsEq(a, b: Region): bool =
  a.xMin == b.xMin and a.yMin == b.yMin and a.xMax == b.xMax and a.yMax == b.yMax

proc intersects(batch: WgStencilBatch; bounds: Region): bool =
  let minv = if batch.ySorted: bounds.yMin else: bounds.xMin
  let maxv = if batch.ySorted: bounds.yMax else: bounds.xMax
  for p in batch.bounds:
    let pMin = if batch.ySorted: p.yMin else: p.xMin
    let pMax = if batch.ySorted: p.yMax else: p.xMax
    if pMax <= minv: continue
    if pMin >= maxv: break
    if intersected(p, bounds): return true
  false

proc addBounds(batch: var WgStencilBatch; bounds: Region) =
  var p = batch.bounds.len
  let minv = if batch.ySorted: bounds.yMin else: bounds.xMin
  batch.bounds.add(bounds)
  while p > 0:
    let prevMin = if batch.ySorted: batch.bounds[p - 1].yMin else: batch.bounds[p - 1].xMin
    if prevMin <= minv: break
    batch.bounds[p] = batch.bounds[p - 1]
    dec p
  batch.bounds[p] = bounds

proc appendable(batch: WgStencilBatch; sceneTask: WgSceneTask; rdata: WgShape; bounds: Region;
                renderTaskList: seq[WgRenderTask]): bool =
  if batch.sceneTask != sceneTask or sceneTask.children.len == 0 or sceneTask.children[^1] != batch.task or
     renderTaskList.len == 0 or renderTaskList[^1] != batch.task: return false
  if not regionsEq(batch.viewport, rdata.viewport) or batch.fillRule != rdata.fillRule: return false
  not intersects(batch, bounds)

proc emitSingle(batch: var WgStencilBatch; sceneTask: WgSceneTask; rdata: WgShape; bounds: Region;
                renderTaskList: var seq[WgRenderTask]) =
  let task = WgRenderTask(initWgPaintTask(WgPaint(rdata), BlendMethod.Normal))
  sceneTask.children.add(task)
  renderTaskList.add(task)

  batch.sceneTask = sceneTask
  batch.task = task
  batch.first = rdata
  batch.viewport = rdata.viewport
  batch.fillRule = rdata.fillRule
  batch.ySorted = (batch.viewport.yMax - batch.viewport.yMin) > (batch.viewport.xMax - batch.viewport.xMin)
  batch.bounds.setLen(0)
  addBounds(batch, bounds)

proc promote(batch: var WgStencilBatch; rdata: WgShape; bounds: Region; renderTaskList: var seq[WgRenderTask]) =
  # assert(batch.sceneTask != nil and batch.first != nil and batch.task != nil)
  let batchTask = WgRenderTask(initWgBatchTask(batch.first, rdata, true))
  batch.sceneTask.children[batch.sceneTask.children.high] = batchTask
  renderTaskList[renderTaskList.high] = batchTask
  batch.task = batchTask
  batch.first = nil
  addBounds(batch, bounds)

proc append(batch: var WgStencilBatch; rdata: WgShape; bounds: Region) =
  WgBatchTask(batch.task).shapes.add(rdata)
  addBounds(batch, bounds)

proc draw*(batch: var WgStencilBatch; sceneTask: WgSceneTask; rdata: WgShape;
           blendMethod: BlendMethod; renderTaskList: var seq[WgRenderTask]): bool =
  var bounds: Region
  if not eligible(rdata, blendMethod, bounds): return false

  if not appendable(batch, sceneTask, rdata, bounds, renderTaskList):
    emitSingle(batch, sceneTask, rdata, bounds, renderTaskList)
    return true

  if batch.first != nil:
    promote(batch, rdata, bounds, renderTaskList)
  else:
    append(batch, rdata, bounds)
  true
