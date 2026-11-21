## Solid batch grouping for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgSolidBatch.h/.cpp (W5/W6).

import ../../core/[types, geom]
import ./[wg_ffi, render_data, render_task]

type
  WgSolidBatchKind* = enum sbkNone, sbkShape, sbkPicture

  WgSolidBatch* = object
    sceneTask*: WgSceneTask
    task*: WgRenderTask
    first*: WgPaint
    viewport*: Region
    kind*: WgSolidBatchKind
    batched*: bool

proc initWgSolidBatch*(): WgSolidBatch = WgSolidBatch()

proc eligibleShape(rdata: WgShape; blendMethod: BlendMethod): bool =
  if blendMethod != BlendMethod.Normal: return false
  if rdata == nil: return false
  if (not rdata.shape.setting.valid) or rdata.shape.setting.fillType != rstSolid: return false
  if (not rdata.convex) or invalid(rdata.viewport) or rdata.clips.len > 0: return false
  if rdata.shape.mesh.vbuffer.len == 0 or rdata.shape.mesh.ibuffer.len == 0: return false
  if rdata.stroke.setting.valid and rdata.stroke.mesh.ibuffer.len > 0: return false
  true

proc eligibleImage(rdata: WgImage; blendMethod: BlendMethod): bool =
  if blendMethod != BlendMethod.Normal: return false
  if rdata == nil: return false
  if invalid(rdata.viewport) or rdata.clips.len > 0 or isNil(rdata.bindGroup): return false
  if rdata.mesh.vbuffer.len == 0 or rdata.mesh.ibuffer.len == 0: return false
  true

proc regionsEq(a, b: Region): bool =
  a.xMin == b.xMin and a.yMin == b.yMin and a.xMax == b.xMax and a.yMax == b.yMax

proc appendable(batch: WgSolidBatch; sceneTask: WgSceneTask; rdata: WgPaint;
                renderTaskList: seq[WgRenderTask]): bool =
  if batch.sceneTask != sceneTask: return false
  if sceneTask.children.len == 0 or sceneTask.children[^1] != batch.task: return false
  if renderTaskList.len == 0 or renderTaskList[^1] != batch.task: return false
  if not regionsEq(batch.viewport, rdata.viewport): return false
  true

proc emitSingle(sceneTask: WgSceneTask; rdata: WgPaint; renderTaskList: var seq[WgRenderTask]): WgRenderTask =
  result = WgRenderTask(initWgPaintTask(rdata, BlendMethod.Normal))
  sceneTask.children.add(result)
  renderTaskList.add(result)

proc promote(sceneTask: WgSceneTask; task: WgRenderTask; batchTask: WgRenderTask;
             renderTaskList: var seq[WgRenderTask]): WgRenderTask =
  # Tasks are staged only after the tree is complete, so replacing its tail is safe.
  sceneTask.children[sceneTask.children.high] = batchTask
  renderTaskList[renderTaskList.high] = batchTask
  result = batchTask

proc draw*(batch: var WgSolidBatch; sceneTask: WgSceneTask; rdata: WgShape;
           blendMethod: BlendMethod; renderTaskList: var seq[WgRenderTask]): bool =
  if not eligibleShape(rdata, blendMethod): return false

  if batch.kind != sbkShape or not appendable(batch, sceneTask, WgPaint(rdata), renderTaskList):
    batch.task = emitSingle(sceneTask, WgPaint(rdata), renderTaskList)
    batch.sceneTask = sceneTask
    batch.first = WgPaint(rdata)
    batch.viewport = rdata.viewport
    batch.kind = sbkShape
    batch.batched = false
    return true

  if not batch.batched:
    batch.task = promote(sceneTask, batch.task, WgRenderTask(initWgBatchTask(WgShape(batch.first), rdata, false)), renderTaskList)
    batch.batched = true
  else:
    WgBatchTask(batch.task).shapes.add(rdata)
  true

proc draw*(batch: var WgSolidBatch; sceneTask: WgSceneTask; rdata: WgImage;
           blendMethod: BlendMethod; renderTaskList: var seq[WgRenderTask]): bool =
  if not eligibleImage(rdata, blendMethod): return false

  var canAppend = (batch.kind == sbkPicture) and appendable(batch, sceneTask, WgPaint(rdata), renderTaskList)
  if canAppend:
    let firstImg = WgImage(batch.first)
    canAppend = (firstImg.bindGroup == rdata.bindGroup) and
                (firstImg.setting.settings.options.vec[3] == rdata.setting.settings.options.vec[3])
  if not canAppend:
    batch.task = emitSingle(sceneTask, WgPaint(rdata), renderTaskList)
    batch.sceneTask = sceneTask
    batch.first = WgPaint(rdata)
    batch.viewport = rdata.viewport
    batch.kind = sbkPicture
    batch.batched = false
    return true

  if not batch.batched:
    batch.task = promote(sceneTask, batch.task, WgRenderTask(initWgImageBatchTask(WgImage(batch.first), rdata)), renderTaskList)
    batch.batched = true
  else:
    WgImageBatchTask(batch.task).images.add(rdata)
  true
