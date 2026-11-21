## GL stencil-and-cover batch: merges consecutive non-overlapping stencil-then-cover fills of one
## render pass into one `GlStencilCoverTask` (port of tvgGlStencilCoverBatch.cpp/.h; the C++ class
## is `GlStencilCoverBatch`). Pure CPU: only the stage buffer arrays and render tasks are built.
##
## The C++ reads `currentPass()`, `mGpuBuffer` and `mPrograms[RT_Stencil]` from the `GlRenderer`;
## here `prepare` takes `stage`, `pass` and `stencilProgram` explicitly.
##
## - `prepare(batch, stage, pass, stencilProgram, cover, shape, flag, mode, color, viewBounds)`:
##   fills `cover` (bbox quad, solid colored when `color` is some) and builds the stencil task
##   (mode `None`: `cover` just receives the geometry, no stencil task). Returns the
##   `GlStencilPreparation` consumed by `draw`.
## - `draw(batch, pass, cover, preparation)`: appends to the open batch task when
##   `preparation.merge`, otherwise emits a new stencil-cover task.
## - `clear(batch)`: closes the batch (the C++ calls it between unrelated paints).
## - `viewportRegion(vp, bbox)`: `GlRenderer::viewportRegion` (GL y-flipped scissor box).
##
## The C++ `uint32_t* indices` into the index array is the byte offset `indices` into
## `stage.index` here (see `merge`).

import std/options
import ../../core/[types, geom]
import ../../renderer/render
import ./[gl_common, gl_ffi, gpu_buffer, gpu_path, program, render_pass, render_task,
  task_draw]

const
  BatchRegionMaxCount = 512
  BatchRegionResetThreshold = 128
  BatchVertexMaxCount = 262144'u32
  BatchIndexMaxCount = 1048576'u32
  CoverVertexCount = 6'u32

type
  GlStencilCoverBatch* = object
    pass: GlRenderPass
    task: GlStencilCoverTask
    stencilTask: GlRenderTask
    mode: GlStencilMode
    bounds: seq[Region]  ## sorted by min along the sort axis
    stencilViewBounds, coverViewBounds: Region
    vertexCount, indexOffset, indexCount: uint32
    clipped, ySorted, open: bool

  GlStencilPreparation* = object
    ## Short-lived state consumed by `draw` (C++ `Preparation`).
    stencil*: GlRenderTask
    shape: GlShape        ## owner of the stencil geometry buffer
    stroke: bool          ## the buffer is `geometry.stroke`
    indices: int          ## byte offset of the stencil indices in `stage.index`
    stage: GlStageBuffer
    bounds*, viewBounds*: Region
    mode*: GlStencilMode
    clipped*, merge*: bool

func viewportRegion*(vp, bbox: Region): Region =
  let x = bbox.xMin - vp.xMin
  let y = bbox.yMin - vp.yMin
  let w = bbox.sw
  let h = bbox.sh
  let yGl = vp.sh - y - h
  Region(xMin: x, yMin: yGl, xMax: x + w, yMax: yGl + h)

proc clear*(b: var GlStencilCoverBatch) =
  b.pass = nil
  b.task = nil
  b.stencilTask = nil
  b.mode = GlStencilMode.None
  b.bounds.setLen(0)
  b.stencilViewBounds = Region()
  b.coverViewBounds = Region()
  b.vertexCount = 0
  b.indexOffset = 0
  b.indexCount = 0
  b.clipped = false
  b.ySorted = false
  b.open = false

# ---------------------------------------------------------------- stencil buffer access

func buffersVertexCount(p: GlStencilPreparation): uint32 =
  uint32((if p.stroke: p.shape.geometry.stroke.vertex.len
          else: p.shape.geometry.fill.vertex.len) div 2)

func buffersIndexCount(p: GlStencilPreparation): uint32 =
  uint32(if p.stroke: p.shape.geometry.stroke.index.len else: p.shape.geometry.fill.index.len)

func buffersIndex(p: GlStencilPreparation, i: int): uint32 =
  if p.stroke: p.shape.geometry.stroke.index[i] else: p.shape.geometry.fill.index[i]

# ---------------------------------------------------------------- cover layouts

proc addCoverPositionLayout(task: GlRenderTask, stage: GlStageBuffer, bbox: Region) =
  let x0 = floatBits(float32(bbox.xMin))
  let y0 = floatBits(float32(bbox.yMin))
  let x1 = floatBits(float32(bbox.xMax))
  let y1 = floatBits(float32(bbox.yMax))
  let offset = stage.pushAux([x0, y0, x0, y1, x1, y0, x1, y0, x0, y1, x1, y1])
  task.addVertexLayout(GlVertexLayout(index: 0, size: 2, stride: 8, offset: offset,
    ty: GlFloat, normalized: false, arrayBufferId: stage.getAuxBufferId()))

proc addCoverSolidLayout(task: GlRenderTask, stage: GlStageBuffer, bbox: Region, color: RGBA) =
  let x0 = floatBits(float32(bbox.xMin))
  let y0 = floatBits(float32(bbox.yMin))
  let x1 = floatBits(float32(bbox.xMax))
  let y1 = floatBits(float32(bbox.yMax))
  let c = rgbaWord(color.r, color.g, color.b, color.a)
  let offset = stage.pushAux([x0, y0, c, x0, y1, c, x1, y0, c, x1, y0, c, x0, y1, c, x1, y1, c])
  let auxBuffer = stage.getAuxBufferId()
  task.addVertexLayout(GlVertexLayout(index: 0, size: 2, stride: 12, offset: offset,
    ty: GlFloat, normalized: false, arrayBufferId: auxBuffer))
  task.addVertexLayout(GlVertexLayout(index: 1, size: 4, stride: 12, offset: offset + 8,
    ty: GlUnsignedByte, normalized: true, arrayBufferId: auxBuffer))

proc drawStencilGeometry(task: GlRenderTask, stage: GlStageBuffer,
    buffer: GlGeometryBuffer): int =
  ## Returns the byte offset of the index block in `stage.index`.
  let vertexOffset = stage.push(buffer.vertex)
  let indexOffset = stage.reserveIndex(buffer.index.len * 4)
  for i, v in buffer.index: stage.index[indexOffset div 4 + i] = v
  task.addVertexLayout(GlVertexLayout(index: 0, size: 2, stride: 8, offset: vertexOffset,
    ty: GlFloat, normalized: false, arrayBufferId: stage.getBufferId()))
  task.setDrawRange(uint32(indexOffset), uint32(buffer.index.len))
  indexOffset

func solidCoverLayout(layouts: seq[GlVertexLayout]): bool =
  if layouts.len != 2: return false
  let position = layouts[0]
  let color = layouts[1]
  if position.index != 0 or position.size != 2 or position.ty != GlFloat or
      position.normalized: return false
  if color.index != 1 or color.size != 4 or color.ty != GlUnsignedByte or
      not color.normalized: return false
  if position.stride != color.stride: return false
  if position.arrayBufferId == 0 or position.arrayBufferId != color.arrayBufferId: return false
  if color.offset != position.offset + 8: return false
  true

# ---------------------------------------------------------------- bounds list

func intersects(b: GlStencilCoverBatch, bounds: Region): bool =
  let lo = if b.ySorted: bounds.yMin else: bounds.xMin
  let hi = if b.ySorted: bounds.yMax else: bounds.xMax
  for p in b.bounds:
    let pMin = if b.ySorted: p.yMin else: p.xMin
    let pMax = if b.ySorted: p.yMax else: p.xMax
    if pMax > lo:
      if pMin >= hi: break
      if p.intersected(bounds): return true
  false

proc addBounds(b: var GlStencilCoverBatch, bounds: Region) =
  var p = b.bounds.len
  let lo = if b.ySorted: bounds.yMin else: bounds.xMin
  b.bounds.setLen(p + 1)
  while p > 0 and (if b.ySorted: b.bounds[p - 1].yMin else: b.bounds[p - 1].xMin) > lo:
    b.bounds[p] = b.bounds[p - 1]
    dec p
  b.bounds[p] = bounds

func mergeable*(b: GlStencilCoverBatch, pass: GlRenderPass, mode: GlStencilMode, clipped: bool,
    bounds: Region, incomingVertexCount, incomingIndexCount: uint32): bool =
  ## `GlStencilCoverBatch::mergeable`; the counts are those of the incoming stencil buffer.
  if not b.open: return false
  if b.pass != pass: return false
  if pass.lastTask() != GlRenderTask(b.task): return false
  if b.mode != mode: return false
  if b.clipped != clipped: return false
  if bounds.invalid: return false
  if b.bounds.len >= BatchRegionMaxCount: return false
  if incomingVertexCount > BatchVertexMaxCount or
      b.vertexCount > BatchVertexMaxCount - incomingVertexCount: return false
  if incomingIndexCount > BatchIndexMaxCount or
      b.indexCount > BatchIndexMaxCount - incomingIndexCount: return false
  not b.intersects(bounds)

# ---------------------------------------------------------------- prepare

proc prepare*(b: GlStencilCoverBatch, stage: GlStageBuffer, pass: GlRenderPass,
    stencilProgram: GlProgram, cover: GlRenderTask, shape: GlShape, flag: RenderUpdateFlag,
    mode: GlStencilMode, color: Option[RGBA], viewBounds: Region): GlStencilPreparation =
  result = GlStencilPreparation(mode: mode, stage: stage, shape: shape)
  if mode == GlStencilMode.None:
    shape.geometry.draw(cover, stage, {flag})
    return

  let stroke = flag == RenderUpdateFlag.Stroke or flag == RenderUpdateFlag.GradientStroke
  let bbox = if stroke: shape.geometry.strokeBBox else: shape.geometry.fillBBox
  result.stroke = stroke
  result.bounds = if stroke: gpuTransformBounds(bbox, shape.geometry.matrix) else: bbox
  result.bounds = intersect(result.bounds, viewBounds)
  result.viewBounds = viewBounds
  result.clipped = shape.clips.len != 0

  cover.setViewport(viewportRegion(pass.getViewport(), result.bounds))

  if color.isSome: addCoverSolidLayout(cover, stage, bbox, color.get())
  else: addCoverPositionLayout(cover, stage, bbox)
  cover.useDrawArrays = true
  cover.arrayMode = GlTriangles
  cover.arrayOffset = 0
  cover.indexCnt = CoverVertexCount
  # Cache this before writing stencil indices; the batch needs the
  # pre-mutation answer to keep the index stream mergeable.
  result.merge = b.mergeable(pass, mode, result.clipped, result.bounds,
    result.buffersVertexCount, result.buffersIndexCount)

  result.stencil = newGlRenderTask(stencilProgram)
  result.stencil.setViewMatrix(cover.viewMatrix)
  result.stencil.drawDepth = cover.drawDepth
  result.indices = if stroke: drawStencilGeometry(result.stencil, stage,
      shape.geometry.stroke)
    else: drawStencilGeometry(result.stencil, stage, shape.geometry.fill)
  result.stencil.setViewport(cover.viewport)

# ---------------------------------------------------------------- draw

proc setStencilMergeTarget(b: var GlStencilCoverBatch, stencil: GlRenderTask,
    viewBounds: Region, incomingVertexCount: uint32) =
  b.stencilTask = stencil
  b.stencilViewBounds = viewBounds
  b.vertexCount = incomingVertexCount
  b.indexOffset = stencil.indexOffset
  b.indexCount = stencil.indexCnt

proc merge(b: var GlStencilCoverBatch, stencil: GlRenderTask, viewBounds: Region,
    p: GlStencilPreparation): bool =
  let incomingVertexCount = p.buffersVertexCount
  if b.stencilTask == nil or b.vertexCount == 0 or incomingVertexCount == 0: return false
  if not (b.stencilViewBounds == viewBounds): return false
  if b.stencilTask.program != stencil.program: return false
  if b.stencilTask.useViewMatrix != stencil.useViewMatrix: return false
  if b.stencilTask.useViewMatrix and not (b.stencilTask.viewMatrix == stencil.viewMatrix):
    return false

  if b.stencilTask.vertexLayout.len != 1 or stencil.vertexLayout.len != 1: return false
  let layout = b.stencilTask.vertexLayout[0]
  let appendLayout = stencil.vertexLayout[0]
  if layout.index != appendLayout.index or layout.size != appendLayout.size or
      layout.stride != appendLayout.stride: return false
  if layout.offset + int(b.vertexCount) * int(layout.stride) != appendLayout.offset or
      layout.ty != appendLayout.ty or layout.normalized != appendLayout.normalized:
    return false
  if layout.arrayBufferId != appendLayout.arrayBufferId: return false

  let expectedIndexOffset = int(b.indexOffset) + int(b.indexCount) * 4
  if int(stencil.indexOffset) != expectedIndexOffset: return false

  for i in 0 ..< int(p.buffersIndexCount):
    p.stage.index[p.indices div 4 + i] = p.buffersIndex(i) + b.vertexCount
  b.indexCount += stencil.indexCnt
  b.vertexCount += incomingVertexCount
  b.stencilTask.indexOffset = b.indexOffset
  b.stencilTask.indexCnt = b.indexCount
  b.stencilTask.drawDepth = stencil.drawDepth
  b.stencilTask.viewport = add(b.stencilTask.viewport, stencil.viewport)
  true

proc mergeCover(b: var GlStencilCoverBatch, cover: GlRenderTask, viewBounds: Region): bool =
  if b.task.coverTasks.len == 0: return false
  if not (b.coverViewBounds == viewBounds): return false

  let dst = b.task.coverTasks[^1]
  if dst.program != cover.program: return false
  if dst.blendMethod != cover.blendMethod: return false
  if dst.bindResources.len != 0 or cover.bindResources.len != 0: return false
  if not dst.useDrawArrays or not cover.useDrawArrays: return false
  if dst.arrayMode != GlTriangles or cover.arrayMode != GlTriangles: return false
  if dst.useVertexColor or cover.useVertexColor: return false
  if dst.useViewMatrix != cover.useViewMatrix: return false
  if dst.useViewMatrix and not (dst.viewMatrix == cover.viewMatrix): return false

  if not solidCoverLayout(dst.vertexLayout) or not solidCoverLayout(cover.vertexLayout):
    return false

  let position = dst.vertexLayout[0]
  let coverPosition = cover.vertexLayout[0]
  let color = dst.vertexLayout[1]
  let coverColor = cover.vertexLayout[1]
  if position.stride != coverPosition.stride or
      position.arrayBufferId != coverPosition.arrayBufferId: return false
  if color.stride != coverColor.stride or color.arrayBufferId != coverColor.arrayBufferId:
    return false

  let rows = int(dst.arrayOffset) + int(dst.indexCnt)
  let dstEnd = position.offset + rows * int(position.stride)
  let coverStart = coverPosition.offset + int(cover.arrayOffset) * int(coverPosition.stride)
  let colorEnd = color.offset + rows * int(color.stride)
  let coverColorStart = coverColor.offset + int(cover.arrayOffset) * int(coverColor.stride)
  if dstEnd != coverStart or colorEnd != coverColorStart: return false

  dst.indexCnt += cover.indexCnt
  dst.viewport = add(dst.viewport, cover.viewport)
  dst.drawDepth = cover.drawDepth
  true

proc append(b: var GlStencilCoverBatch, cover: GlRenderTask, p: GlStencilPreparation) =
  if not b.mergeCover(cover, p.viewBounds):
    b.task.coverTasks.add cover
    b.coverViewBounds = p.viewBounds
  if not b.merge(p.stencil, p.viewBounds, p):
    b.task.stencilTasks.add p.stencil
    b.setStencilMergeTarget(p.stencil, p.viewBounds, p.buffersVertexCount)
  b.addBounds(p.bounds)

proc emitSingle(b: var GlStencilCoverBatch, pass: GlRenderPass, cover: GlRenderTask,
    p: GlStencilPreparation) =
  let task = newGlStencilCoverTask(p.stencil, cover, p.mode)
  pass.addRenderTask(task)

  b.pass = pass
  b.task = task
  b.mode = p.mode
  b.clipped = p.clipped
  b.ySorted = pass.getViewport().sh > pass.getViewport().sw
  b.coverViewBounds = p.viewBounds
  b.bounds.setLen(0)
  b.setStencilMergeTarget(p.stencil, p.viewBounds, p.buffersVertexCount)
  b.open = p.bounds.valid
  if b.open: b.addBounds(p.bounds)

proc draw*(b: var GlStencilCoverBatch, pass: GlRenderPass, cover: GlRenderTask,
    preparation: GlStencilPreparation) =
  if preparation.stencil == nil:
    pass.addRenderTask(cover)
    return

  if preparation.merge: b.append(cover, preparation)
  else: b.emitSingle(pass, cover, preparation)
