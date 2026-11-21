## `GlGeometry::draw` (from tvgGlGeometry.cpp; G2b left it for the render task layer).
##
## `draw(geometry, task, stage, flags)` pushes the vertex buffer selected by `flags` (stroke or
## gradient stroke: `geometry.stroke`, otherwise `geometry.fill`) and its indices into the
## stage buffer, then gives `task` its vertex layout and draw range. Images have two attributes
## (position + uv, stride 16); everything else one (position, stride 8). Offsets are the stage
## buffer's byte offsets, exactly like C++.

import ../../renderer/render
import ./[gl_common, gl_ffi, gpu_buffer, render_task]

proc drawBuffer(buffer: GlGeometryBuffer, task: GlRenderTask, stage: GlStageBuffer,
    flags: RenderUpdateFlags) =
  let vertexOffset = stage.push(buffer.vertex)
  let indexOffset = stage.pushIndex(buffer.index)
  let vertexBuffer = stage.getBufferId()

  if RenderUpdateFlag.Image in flags:
    # image has two attribute: [pos, uv]
    task.addVertexLayout(GlVertexLayout(index: 0, size: 2, stride: 16, offset: vertexOffset,
      ty: GlFloat, normalized: false, arrayBufferId: vertexBuffer))
    task.addVertexLayout(GlVertexLayout(index: 1, size: 2, stride: 16,
      offset: vertexOffset + 8, ty: GlFloat, normalized: false, arrayBufferId: vertexBuffer))
  else:
    task.addVertexLayout(GlVertexLayout(index: 0, size: 2, stride: 8, offset: vertexOffset,
      ty: GlFloat, normalized: false, arrayBufferId: vertexBuffer))
  task.setDrawRange(uint32(indexOffset), uint32(buffer.index.len))

proc draw*(g: GlGeometry, task: GlRenderTask, stage: GlStageBuffer, flags: RenderUpdateFlags) =
  if flags * {RenderUpdateFlag.Stroke, RenderUpdateFlag.GradientStroke} != {}:
    drawBuffer(g.stroke, task, stage, flags)
  else:
    drawBuffer(g.fill, task, stage, flags)
