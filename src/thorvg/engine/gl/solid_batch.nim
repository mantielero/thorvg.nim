## GL solid batch: merges consecutive solid color / image draws of one render pass into one
## render task (port of tvgGlSolidBatch.cpp/.h). Pure CPU: it only fills the `GlStageBuffer`
## arrays and builds `GlRenderTask`s, no GL call is made.
##
## The C++ takes the `GlRenderer` and reads `currentPass()`, `mBlendMethod`, `mGpuBuffer` and
## `mPrograms[RT_Color / RT_Image]` from it; here the caller passes them explicitly:
## `stage`, `pass`, `program` (the color or the image program) and `blendMethod`.
##
## - `draw(batch, stage, pass, program, blendMethod, shape, color, depth, viewRegion, viewBounds)`
## - `draw(batch, stage, pass, program, blendMethod, image, depth, viewRegion, viewBounds)`
## - `clear(batch)`: `*this = {}`.
##
## The first draw (or any draw that cannot be merged) emits a new task with a constant vertex
## color (position only layout); the second draw promotes it to a per vertex color layout in the
## aux array; later draws only append. Images merge only with the same texture and opacity.

import ../../core/[types, geom]
import ../../renderer/render
import ./[gl_common, gl_ffi, gpu_buffer, program, render_pass, render_task, task_draw]

type
  GlSolidBatch* = object
    task*: GlRenderTask
    viewBounds*: Region
    color*: RGBA
    vertexCount*: uint32
    texId*: uint32
    opacity*: uint32

  GlSolidDrawData* = object
    ## C++ `GlSolidBatch::DrawData`.
    drawable*: GlDrawable
    program*: GlProgram
    flag*: RenderUpdateFlag
    color*: RGBA
    texId*: uint32
    opacity*: uint32
    vertexSize*: uint32

proc clear*(b: var GlSolidBatch) = b = GlSolidBatch()

func appendable(b: GlSolidBatch, pass: GlRenderPass, data: GlSolidDrawData,
    viewBounds: Region): bool =
  if b.task == nil or pass.lastTask() != b.task: return false
  if b.task.program != data.program: return false
  if not (b.viewBounds == viewBounds): return false
  if data.flag == RenderUpdateFlag.Image and (b.texId != data.texId or
      b.opacity != data.opacity): return false
  true

proc buildColors(stage: GlStageBuffer, offset: int, count: uint32, color: RGBA) =
  let word = rgbaWord(color.r, color.g, color.b, color.a)
  for i in 0 ..< int(count): stage.aux[offset div 4 + i] = word

proc emit(b: var GlSolidBatch, stage: GlStageBuffer, pass: GlRenderPass,
    blendMethod: BlendMethod, data: GlSolidDrawData, depth: int32,
    viewRegion, viewBounds: Region, vertexCount: uint32) =
  let drawTask = newGlRenderTask(data.program, blendMethod)
  drawTask.setViewMatrix(pass.getViewMatrix())
  drawTask.setDrawDepth(depth)

  if data.flag == RenderUpdateFlag.Image:
    drawTask.addBindResource(uniformBinding(1, GlShaderUniformBlock.ColorInfo,
      stage.getBufferId(), stage.getImageOpacityOffset(uint8(data.opacity and 0xff'u32)),
      sizeof(GlImageOpacityBlock)))

  data.drawable.geometry.draw(drawTask, stage, {data.flag})

  if data.flag == RenderUpdateFlag.Image:
    drawTask.addBindResource(textureBinding(0, data.texId, GlShaderUniform.Texture))
  else:
    drawTask.setVertexColor(float32(data.color.r) / 255.0'f32, float32(data.color.g) / 255.0'f32,
      float32(data.color.b) / 255.0'f32, float32(data.color.a) / 255.0'f32)

  drawTask.setViewport(intersect(viewRegion, viewBounds))
  pass.addRenderTask(drawTask)

  b.task = drawTask
  b.viewBounds = viewBounds
  b.color = data.color
  b.vertexCount = vertexCount
  b.texId = data.texId
  b.opacity = data.opacity

proc appendGeometry(b: GlSolidBatch, stage: GlStageBuffer, data: GlSolidDrawData) =
  template buffer: untyped = data.drawable.geometry.fill
  let vertexOffset = stage.reserve(buffer.vertex.len * 4)
  let indexOffset = stage.reserveIndex(buffer.index.len * 4)
  for i, v in buffer.vertex: stage.stage[vertexOffset div 4 + i] = floatBits(v)
  for i, v in buffer.index: stage.index[indexOffset div 4 + i] = v + b.vertexCount

proc commit(b: var GlSolidBatch, depth: int32, viewRegion: Region, vertexCount,
    indexCount: uint32) =
  b.vertexCount += vertexCount
  b.task.setDrawRange(b.task.indexOffset, b.task.indexCnt + indexCount)
  b.task.setDrawDepth(depth)

  var viewport = b.task.viewport
  viewport = add(viewport, viewRegion)
  viewport = intersect(viewport, b.viewBounds)
  b.task.setViewport(viewport)

proc promote(b: var GlSolidBatch, stage: GlStageBuffer, data: GlSolidDrawData, depth: int32,
    viewRegion: Region, vertexCount, indexCount: uint32) =
  b.appendGeometry(stage, data)

  let totalVertexCount = b.vertexCount + vertexCount
  let colorOffset = stage.reserveAux(int(totalVertexCount) * 4)
  buildColors(stage, colorOffset, b.vertexCount, b.color)
  buildColors(stage, colorOffset + int(b.vertexCount) * 4, vertexCount, data.color)

  b.task.addVertexLayout(GlVertexLayout(index: 1, size: 4, stride: 4, offset: colorOffset,
    ty: GlUnsignedByte, normalized: true, arrayBufferId: stage.getAuxBufferId()))
  b.commit(depth, viewRegion, vertexCount, indexCount)

proc append(b: var GlSolidBatch, stage: GlStageBuffer, data: GlSolidDrawData, depth: int32,
    viewRegion: Region, vertexCount, indexCount: uint32) =
  b.appendGeometry(stage, data)

  if data.flag == RenderUpdateFlag.Color:
    let colorOffset = stage.reserveAux(int(vertexCount) * 4)
    buildColors(stage, colorOffset, vertexCount, data.color)

  b.commit(depth, viewRegion, vertexCount, indexCount)

proc draw(b: var GlSolidBatch, stage: GlStageBuffer, pass: GlRenderPass,
    blendMethod: BlendMethod, data: GlSolidDrawData, depth: int32,
    viewRegion, viewBounds: Region) =
  template buffer: untyped = data.drawable.geometry.fill
  let vertexCount = uint32(buffer.vertex.len) div data.vertexSize
  let indexCount = uint32(buffer.index.len)

  if not b.appendable(pass, data, viewBounds) or b.task.blendMethod != blendMethod:
    b.emit(stage, pass, blendMethod, data, depth, viewRegion, viewBounds, vertexCount)
  elif b.task.vertexLayout.len == 1:
    b.promote(stage, data, depth, viewRegion, vertexCount, indexCount)
  else:
    b.append(stage, data, depth, viewRegion, vertexCount, indexCount)

proc draw*(b: var GlSolidBatch, stage: GlStageBuffer, pass: GlRenderPass, program: GlProgram,
    blendMethod: BlendMethod, shape: GlShape, color: RGBA, depth: int32,
    viewRegion, viewBounds: Region) =
  ## Solid fill of `shape.geometry.fill` with `color` (alpha scaled by the shape opacity);
  ## `program` is the color program.
  if shape.geometry.fill.vertex.len div 2 == 0 or shape.geometry.fill.index.len == 0: return

  var batchColor = color
  batchColor.a = multiply(color.a, uint8(shape.opacity and 0xff'u32))
  b.draw(stage, pass, blendMethod, GlSolidDrawData(drawable: shape, program: program,
    flag: RenderUpdateFlag.Color, color: batchColor, vertexSize: 2), depth, viewRegion,
    viewBounds)

proc draw*(b: var GlSolidBatch, stage: GlStageBuffer, pass: GlRenderPass, program: GlProgram,
    blendMethod: BlendMethod, image: GlImage, depth: int32, viewRegion, viewBounds: Region) =
  ## Textured quad(s) of `image.geometry.fill`; `program` is the image program.
  b.draw(stage, pass, blendMethod, GlSolidDrawData(drawable: image, program: program,
    flag: RenderUpdateFlag.Image, texId: image.texId, opacity: image.opacity, vertexSize: 4),
    depth, viewRegion, viewBounds)
