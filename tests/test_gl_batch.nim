## G2c: GL solid batch and stencil-cover batch (`solid_batch`, `stencil_batch`), no GL needed.
## The bit-exact comparison with the C++ original lives in `tests/gl/batch_compare.ps1`;
## these are hand-derived expectations.
import std/[unittest, options]
import thorvg/core/[types, geom]
import thorvg/renderer/render
import thorvg/engine/gl/[gl_common, gl_ffi, gpu_buffer, program, render_pass, render_target,
  render_task, solid_batch, stencil_batch]

const Tri = [0'f32, 0, 10, 0, 0, 10]  # three vertices

func region(x0, y0, x1, y1: int32): Region = Region(xMin: x0, yMin: y0, xMax: x1, yMax: y1)

type Env = object
  stage: GlStageBuffer
  pass: GlRenderPass
  color, image, stencilProg: GlProgram

proc newEnv(vp = region(0, 0, 100, 100)): Env =
  Env(stage: newCpuStageBuffer(256),
    pass: newGlRenderPass(GlRenderTarget(viewport: vp, width: uint32(vp.sw),
      height: uint32(vp.sh), fbo: 1)),
    color: newOfflineGlProgram(), image: newOfflineGlProgram(), stencilProg: newOfflineGlProgram())

proc mkShape(opacity = 255'u32, verts: openArray[float32] = Tri,
    idx: openArray[uint32] = [0'u32, 1, 2]): GlShape =
  result = newGlShape(RenderShape())
  result.opacity = opacity
  result.geometry.fill.vertex = @verts
  result.geometry.fill.index = @idx

proc mkImage(tex, opacity: uint32): GlImage =
  result = newGlImage(RenderSurface())
  result.texId = tex
  result.opacity = opacity
  result.geometry.fill.vertex = @[0'f32, 0, 0, 0, 10, 0, 1, 0, 0, 10, 0, 1]
  result.geometry.fill.index = @[0'u32, 1, 2]

proc solid(e: Env, b: var GlSolidBatch, s: GlShape, color: RGBA, depth: int32,
    viewRegion = region(0, 0, 50, 50), viewBounds = region(0, 0, 100, 100),
    blend = BlendMethod.Normal) =
  b.draw(e.stage, e.pass, e.color, blend, s, color, depth, viewRegion, viewBounds)

proc mkStencil(bbox: Region, clipped = false): GlShape =
  result = mkShape()
  result.geometry.fillBBox = bbox
  result.geometry.transform(Matrix(e11: 1, e22: 1, e33: 1))
  if clipped: result.clips.add RenderData(nil)

proc cover(e: Env): GlRenderTask =
  result = newGlRenderTask(e.color)
  result.setViewMatrix(e.pass.getViewMatrix())

proc stencil(e: Env, b: var GlStencilCoverBatch, s: GlShape, mode = GlStencilMode.FillNonZero,
    viewBounds = region(0, 0, 100, 100), color = some(RGBA(r: 1, g: 2, b: 3, a: 255))): GlRenderTask =
  result = e.cover()
  let prep = b.prepare(e.stage, e.pass, e.stencilProg, result, s, RenderUpdateFlag.Path, mode,
    color, viewBounds)
  b.draw(e.pass, result, prep)

let red = RGBA(r: 255, g: 0, b: 0, a: 255)
let blue = RGBA(r: 0, g: 0, b: 255, a: 255)

suite "solid batch":
  test "first draw emits a constant color task":
    let e = newEnv()
    var b: GlSolidBatch
    e.solid(b, mkShape(128), red, 3, region(10, 10, 60, 60), region(0, 0, 40, 40))
    check e.pass.taskCount == 1
    let t = e.pass.lastTask()
    check t.program == e.color
    check t.vertexLayout.len == 1
    check t.vertexLayout[0].stride == 8 and t.vertexLayout[0].offset == 0
    check t.vertexLayout[0].arrayBufferId == 1
    check t.indexCnt == 3 and t.indexOffset == 0
    check t.drawDepth == 3.0'f32
    check t.viewport == region(10, 10, 40, 40)
    check t.useVertexColor and t.useViewMatrix
    # alpha = MULTIPLY(255, 128) = 128
    check t.vertexColor == [1.0'f32, 0.0'f32, 0.0'f32, 128.0'f32 / 255.0'f32]
    check e.stage.stage.len == 6 and e.stage.index == @[0'u32, 1, 2]
    check e.stage.aux.len == 0

  test "opacity above 255 is truncated to uint8":
    let e = newEnv()
    var b: GlSolidBatch
    e.solid(b, mkShape(256 + 255), red, 1)
    check e.pass.lastTask().vertexColor[3] == 1.0'f32

  test "empty geometry draws nothing":
    let e = newEnv()
    var b: GlSolidBatch
    e.solid(b, mkShape(255, [], []), red, 1)
    e.solid(b, mkShape(255, Tri, []), red, 1)
    check e.pass.taskCount == 0 and e.stage.stage.len == 0

  test "second draw promotes to per vertex colors, third appends":
    let e = newEnv()
    var b: GlSolidBatch
    e.solid(b, mkShape(), red, 1, region(0, 0, 10, 10))
    e.solid(b, mkShape(), blue, 2, region(30, 30, 50, 50))
    check e.pass.taskCount == 1
    let t = e.pass.lastTask()
    check t.vertexLayout.len == 2
    check t.vertexLayout[1].index == 1 and t.vertexLayout[1].size == 4
    check t.vertexLayout[1].stride == 4 and t.vertexLayout[1].offset == 0
    check t.vertexLayout[1].ty == GlUnsignedByte and t.vertexLayout[1].normalized
    check t.vertexLayout[1].arrayBufferId == 2
    check t.indexCnt == 6 and t.drawDepth == 2.0'f32
    check t.viewport == region(0, 0, 50, 50)
    check e.stage.index == @[0'u32, 1, 2, 3, 4, 5]
    check e.stage.aux == @[rgbaWord(255, 0, 0, 255), rgbaWord(255, 0, 0, 255),
      rgbaWord(255, 0, 0, 255), rgbaWord(0, 0, 255, 255), rgbaWord(0, 0, 255, 255),
      rgbaWord(0, 0, 255, 255)]
    e.solid(b, mkShape(), red, 3)
    check e.pass.taskCount == 1
    check e.pass.lastTask().indexCnt == 9
    check e.stage.aux.len == 9 and e.stage.aux[8] == rgbaWord(255, 0, 0, 255)
    check e.stage.stage.len == 18

  test "other blend, view bounds, task or clear start a new task":
    let e = newEnv()
    var b: GlSolidBatch
    e.solid(b, mkShape(), red, 1)
    e.solid(b, mkShape(), red, 1, blend = BlendMethod.Multiply)
    check e.pass.taskCount == 2 and e.pass.lastTask().blendMethod == BlendMethod.Multiply
    e.solid(b, mkShape(), red, 1, viewBounds = region(0, 0, 90, 90), blend = BlendMethod.Multiply)
    check e.pass.taskCount == 3
    e.pass.addRenderTask(newGlRenderTask(e.color))
    e.solid(b, mkShape(), red, 1, viewBounds = region(0, 0, 90, 90), blend = BlendMethod.Multiply)
    check e.pass.taskCount == 5
    e.solid(b, mkShape(), red, 1, viewBounds = region(0, 0, 90, 90), blend = BlendMethod.Multiply)
    check e.pass.taskCount == 5
    b.clear()
    e.solid(b, mkShape(), red, 1, viewBounds = region(0, 0, 90, 90), blend = BlendMethod.Multiply)
    check e.pass.taskCount == 6

  test "images: opacity block, texture binding, merge by texture and opacity":
    let e = newEnv()
    var b: GlSolidBatch
    b.draw(e.stage, e.pass, e.image, BlendMethod.Normal, mkImage(9, 256 + 7), 1,
      region(0, 0, 10, 10), region(0, 0, 100, 100))
    let t = e.pass.lastTask()
    check t.bindResources.len == 2
    check t.bindResources[0].kind == GlBindingKind.UniformBuffer
    check t.bindResources[0].uniformBlock == GlShaderUniformBlock.ColorInfo
    check t.bindResources[0].bindPoint == 1 and t.bindResources[0].resourceId == 1
    check t.bindResources[0].bufferOffset == 0 and t.bindResources[0].bufferRange == 16
    check e.stage.stage[0] == 7  # opacity block {7, 0, 0, 0}
    check t.bindResources[1].kind == GlBindingKind.Texture
    check t.bindResources[1].bindPoint == 0 and t.bindResources[1].resourceId == 9
    check t.vertexLayout.len == 2 and t.vertexLayout[0].offset == 16
    check t.vertexLayout[1].offset == 24 and t.vertexLayout[1].stride == 16
    check not t.useVertexColor
    for (tex, opacity, tasks) in [(9'u32, 263'u32, 1), (9'u32, 7'u32, 2), (10'u32, 7'u32, 3),
        (10'u32, 7'u32, 3)]:
      b.draw(e.stage, e.pass, e.image, BlendMethod.Normal, mkImage(tex, opacity), 1,
        region(0, 0, 10, 10), region(0, 0, 100, 100))
      check e.pass.taskCount == tasks

suite "stencil cover batch":
  test "viewportRegion flips y":
    check viewportRegion(region(0, 0, 100, 100), region(10, 10, 30, 30)) == region(10, 70, 30, 90)
    check viewportRegion(region(5, 5, 105, 55), region(10, 10, 30, 30)) == region(5, 25, 25, 45)

  test "mode None only fills the cover":
    let e = newEnv()
    var b: GlStencilCoverBatch
    let c = e.stencil(b, mkStencil(region(0, 0, 10, 10)), GlStencilMode.None)
    check e.pass.taskCount == 1 and e.pass.lastTask() == c
    check c.vertexLayout.len == 1 and c.indexCnt == 3

  test "single shape: stencil task and bbox cover quad":
    let e = newEnv()
    var b: GlStencilCoverBatch
    let c = e.stencil(b, mkStencil(region(10, 10, 30, 30)))
    check e.pass.taskCount == 1
    let t = GlStencilCoverTask(e.pass.lastTask())
    check t.stencilMode == GlStencilMode.FillNonZero
    check t.stencilTasks.len == 1 and t.coverTasks == @[c]
    check t.stencilTasks[0].program == e.stencilProg
    check t.stencilTasks[0].indexCnt == 3 and t.stencilTasks[0].vertexLayout.len == 1
    check c.viewport == region(10, 70, 30, 90)
    check c.useDrawArrays and c.arrayMode == GlTriangles and c.indexCnt == 6
    check c.vertexLayout.len == 2 and c.vertexLayout[0].stride == 12
    check c.vertexLayout[1].offset == 8 and c.vertexLayout[1].arrayBufferId == 2
    check e.stage.aux.len == 18
    check e.stage.aux[2] == rgbaWord(1, 2, 3, 255)
    check e.stage.aux[0] == floatBits(10.0'f32) and e.stage.aux[16] == floatBits(30.0'f32)

  test "no color: position only cover layout":
    let e = newEnv()
    var b: GlStencilCoverBatch
    let c = e.stencil(b, mkStencil(region(10, 10, 30, 30)), color = none(RGBA))
    check c.vertexLayout.len == 1 and c.vertexLayout[0].stride == 8
    check e.stage.aux.len == 12

  test "disjoint shapes merge, covers merge, indices are rebased":
    let e = newEnv()
    var b: GlStencilCoverBatch
    discard e.stencil(b, mkStencil(region(10, 10, 30, 30)))
    discard e.stencil(b, mkStencil(region(40, 10, 60, 30)))
    check e.pass.taskCount == 1
    let t = GlStencilCoverTask(e.pass.lastTask())
    check t.stencilTasks.len == 1 and t.coverTasks.len == 1
    check t.stencilTasks[0].indexCnt == 6 and t.stencilTasks[0].indexOffset == 0
    check t.coverTasks[0].indexCnt == 12
    check t.coverTasks[0].viewport == region(10, 70, 60, 90)
    check e.stage.index == @[0'u32, 1, 2, 3, 4, 5]

  test "covers with a binding are not merged but stencils are":
    let e = newEnv()
    var b: GlStencilCoverBatch
    discard e.stencil(b, mkStencil(region(10, 10, 30, 30)))
    let c = e.cover()
    c.addBindResource(textureBinding(0, 5, GlShaderUniform.Texture))
    let prep = b.prepare(e.stage, e.pass, e.stencilProg, c, mkStencil(region(40, 10, 60, 30)),
      RenderUpdateFlag.Path, GlStencilMode.FillNonZero, some(RGBA(a: 255)), region(0, 0, 100, 100))
    check prep.merge
    b.draw(e.pass, c, prep)
    let t = GlStencilCoverTask(e.pass.lastTask())
    check t.stencilTasks.len == 1 and t.coverTasks.len == 2

  test "overlap, mode, clip, pass and clear break the batch":
    let e = newEnv()
    var b: GlStencilCoverBatch
    discard e.stencil(b, mkStencil(region(10, 10, 30, 30)))
    discard e.stencil(b, mkStencil(region(20, 20, 40, 40)))
    check e.pass.taskCount == 2
    discard e.stencil(b, mkStencil(region(50, 10, 60, 30)), GlStencilMode.FillEvenOdd)
    check e.pass.taskCount == 3
    discard e.stencil(b, mkStencil(region(70, 10, 80, 30)), GlStencilMode.FillEvenOdd)
    check e.pass.taskCount == 3
    discard e.stencil(b, mkStencil(region(85, 10, 90, 30), clipped = true), GlStencilMode.FillEvenOdd)
    check e.pass.taskCount == 4
    b.clear()
    discard e.stencil(b, mkStencil(region(10, 50, 30, 60), clipped = true), GlStencilMode.FillEvenOdd)
    check e.pass.taskCount == 5
    # an invalid (empty) bbox is never merged and does not open the batch
    discard e.stencil(b, mkStencil(region(40, 50, 40, 60)), GlStencilMode.FillEvenOdd)
    discard e.stencil(b, mkStencil(region(60, 50, 70, 60)), GlStencilMode.FillEvenOdd)
    check e.pass.taskCount == 7
    # a task added by someone else closes the batch
    e.pass.addRenderTask(newGlRenderTask(e.color))
    discard e.stencil(b, mkStencil(region(80, 50, 90, 60)), GlStencilMode.FillEvenOdd)
    check e.pass.taskCount == 9

  test "region limit of 512 shapes per task":
    let e = newEnv(region(0, 0, 3000, 100))
    var b: GlStencilCoverBatch
    for i in 0'i32 ..< 530:
      discard e.stencil(b, mkStencil(region(i * 5, 0, i * 5 + 4, 50)),
        viewBounds = region(0, 0, 3000, 100))
    check e.pass.taskCount == 2
    check GlStencilCoverTask(e.pass.lastTask()).coverTasks[0].indexCnt == 108'u32

  test "vertex limit of 262144 per task":
    let e = newEnv(region(0, 0, 3000, 100))
    var b: GlStencilCoverBatch
    var big = mkStencil(region(0, 0, 4, 50))
    big.geometry.fill.vertex = newSeq[float32](150000 * 2)
    discard e.stencil(b, big)
    big.geometry.fillBBox = region(10, 0, 14, 50)
    discard e.stencil(b, big)
    check e.pass.taskCount == 2
