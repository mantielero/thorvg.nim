## GL render pass: the ordered task list drawn into one `GlRenderTarget`
## (port of tvgGlRenderPass.cpp/.h).
##
## `GlRenderPass` is a ref (C++ `GlRenderPass*` in `mRenderPassStack`; the move constructor is
## the ref copy). A pass with a nil `fbo` is "empty" (`isEmpty`): a composition whose bbox is
## invalid. Tasks are owned by the pass until `endRenderPass` / `takeLastTask` hand them over.
##
## API:
## - `newGlRenderPass(fbo)` (nil allowed), `addRenderTask`, `takeLastTask` (pops, nil if none),
##   `lastTask` (nil if none), `isEmpty`, `getFboId`, `getTextureId`, `getViewport`,
##   `getFboWidth/Height`, `getViewMatrix`, `nextDrawDepth` (pre-increment), `setDrawDepth`.
## - `endRenderPass[T](pass, program, targetFbo): T` with `T` = `GlComposeTask`, `GlBlitTask`,
##   `GlDrawBlitTask` or `GlSceneBlendTask`: normalizes the draw depth of every task
##   (`maxDepth = depth + 1`), moves the task list into a new `T` and sets its render size to
##   the viewport size of the target (and `colorTex` for a blit task).

import ../../core/[types, geom]
import ./[gl_ffi, program, render_target, render_task]

type
  GlRenderPass* = ref object
    fbo*: GlRenderTarget
    tasks: seq[GlRenderTask]
    drawDepth: int32
    viewMatrix: Matrix

{.push floatChecks: false.}

func viewMatrixOf(vp: Region): Matrix =
  var postMatrix = identity()
  translate(postMatrix, pt(float32(-vp.xMin), float32(-vp.yMin)))

  var mvp = identity()
  mvp.e11 = 2.0'f32 / float32(vp.sw)
  mvp.e22 = -2.0'f32 / float32(vp.sh)
  mvp.e13 = -1.0'f32
  mvp.e23 = 1.0'f32
  mvp * postMatrix

{.pop.}

proc newGlRenderPass*(fbo: GlRenderTarget): GlRenderPass =
  result = GlRenderPass(fbo: fbo, viewMatrix: identity())
  if fbo != nil: result.viewMatrix = viewMatrixOf(fbo.viewport)

proc addRenderTask*(p: GlRenderPass, task: GlRenderTask) = p.tasks.add task

proc takeLastTask*(p: GlRenderPass): GlRenderTask =
  if p.tasks.len == 0: nil else: p.tasks.pop()

func lastTask*(p: GlRenderPass): GlRenderTask =
  if p.tasks.len == 0: nil else: p.tasks[^1]

func isEmpty*(p: GlRenderPass): bool = p.fbo == nil
func taskCount*(p: GlRenderPass): int = p.tasks.len
func getFboId*(p: GlRenderPass): GlId = p.fbo.fbo
func getTextureId*(p: GlRenderPass): GlId = p.fbo.colorTex
func getViewport*(p: GlRenderPass): Region = p.fbo.viewport
func getFboWidth*(p: GlRenderPass): uint32 = p.fbo.width
func getFboHeight*(p: GlRenderPass): uint32 = p.fbo.height
func getViewMatrix*(p: GlRenderPass): Matrix = p.viewMatrix

proc nextDrawDepth*(p: GlRenderPass): int =
  inc p.drawDepth
  int(p.drawDepth)

proc setDrawDepth*(p: GlRenderPass, depth: int32) = p.drawDepth = depth

proc endRenderPass*[T: GlComposeTask](p: GlRenderPass, program: GlProgram,
    targetFbo: GlId): T =
  let maxDepth = p.drawDepth + 1

  for task in p.tasks: task.normalizeDrawDepth(maxDepth)

  result = T()
  result.initCompose(program, targetFbo, p.fbo, move(p.tasks))
  p.tasks = @[]
  when T is GlBlitTask: result.colorTex = p.fbo.colorTex
  let vp = p.fbo.viewport
  result.setRenderSize(uint32(max(vp.sw, 0)), uint32(max(vp.sh, 0)))
