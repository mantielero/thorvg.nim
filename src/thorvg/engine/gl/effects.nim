## GL scene effects (port of tvgGlEffect.cpp/.h): Gaussian blur (H/V/both), drop shadow, motion
## blur, fill, tint and tritone. The effect tasks themselves (`GlGaussianBlurTask`,
## `GlEffectDropShadowTask`, `GlEffectTask`) were ported with the render tasks in `task_blend.nim`.
##
## Independent of the renderer: `GlEffect` only keeps the shared `GlStageBuffer` and the lazily
## built programs. Everything else is passed explicitly by the caller (`renderer_comp`, G4b):
##
## - `ensureEffectPools(blendPool, width, height)`: C++ `GlRenderer::prepare(effect)` makes sure
##   `mBlendPool` holds two `GlRenderTargetPool`s sized like the main surface.
## - `effect.update(re, transform)` = `GlRenderer::prepare(RenderEffect*)` after the pools exist
##   (`effectPrepare`): fills `re.rd` (an `EffectData` subclass below) and `re.valid`.
## - `effect.region(re)` = `effectRegion`: sets `re.extend`; false for fill/tint/tritone and when
##   the effect was never prepared (`rd == nil`).
## - `effect.render(re, pass, blendPool, state)` = `effectRender`: `pass` is `currentPass()`,
##   `state` the renderer's `GlStateCache`. Pushes the quad and the uniform blocks into the
##   stage buffer and appends one task to the pass; false when nothing was added.
## - `dispose(re)` = `effectDispose` (C++ frees `rd`). `destroy(effect)` deletes the programs
##   (needs the GL context; also done by the `GlProgram` hooks).
##
## The uniform block layouts (std140) are the C++ structs: blur 16 bytes, motion blur 16, drop
## shadow 48 and color params 48 bytes; `uniforms(data)` returns exactly those floats.

import std/math
import ../../core/[types, geom]
import ../../renderer/effect
import ./[gl_ffi, gpu_buffer, program, programs, render_pass, render_target, render_task,
  state_cache, task_blend]
from ./shader import logGlError

type
  GlBlurData* = ref object of EffectData  ## `GlGaussianBlur`
    sigma*, scale*, extend*, quality*: float32

  GlMotionBlurData* = ref object of EffectData  ## `GlMotionBlur`
    offset*: array[2, float32]
    samples*: float32

  GlDropShadowData* = ref object of EffectData  ## `GlDropShadow`
    sigma*, scale*, extend*, quality*: float32
    color*: array[4, float32]   ## premultiplied
    offset*: array[2, float32]

  GlParamsData* = ref object of EffectData  ## `GlEffectParams` (fill, tint, tritone)
    params*: array[12, float32]

  GlEffect* = ref object
    stage: GlStageBuffer  ## shared with the renderer
    programs: array[EffectProgram, GlProgram]

const
  BlurBlockSize = 16
  MotionBlockSize = 16
  DropShadowBlockSize = 48
  ParamsBlockSize = 48
  ViewportBlockSize = 16
  QuadVertices = [-1.0'f32, 1.0, 1.0, 1.0, 1.0, -1.0, -1.0, -1.0]
  QuadIndices = [0'u32, 1, 2, 0, 2, 3]

{.push floatChecks: false.}

func toRegionInt(v: float32): int32 =
  ## C++ float -> int32 conversion (truncation), saturated instead of undefined.
  if v >= 2147483520.0'f32: high(int32)
  elif v <= -2147483520.0'f32: low(int32)
  elif v != v: low(int32)
  else: int32(v)

func blurQuality(quality: uint8, extend: float32): float32 =
  var step = 1.0'f32
  if quality <= 33: step = 3.0'f32
  elif quality <= 66: step = 2.0'f32
  let radius = max(int(min(extend, 1.0e9'f32)), 1)
  min(step, float32(radius))

func scaleOf(tm: Matrix): float32 = sqrt(tm.e11 * tm.e11 + tm.e12 * tm.e12)

# ---------------------------------------------------------------- uniform data

func uniforms*(d: GlBlurData): array[4, float32] = [d.sigma, d.scale, d.extend, d.quality]

func uniforms*(d: GlMotionBlurData): array[4, float32] =
  [d.offset[0], d.offset[1], d.samples, 0.0'f32]

func uniforms*(d: GlDropShadowData): array[12, float32] =
  [d.sigma, d.scale, d.extend, d.quality, d.color[0], d.color[1], d.color[2], d.color[3],
   d.offset[0], d.offset[1], 0.0'f32, 0.0'f32]

# ---------------------------------------------------------------- update (per effect)

proc updateBlur(e: GaussianBlurEffect, tm: Matrix) =
  let scale = scaleOf(tm)
  let extend = 2 * e.sigma * scale
  e.valid = not zero(extend)
  if e.valid:
    let blur = if e.rd of GlBlurData: GlBlurData(e.rd) else: GlBlurData()
    blur.sigma = e.sigma
    blur.scale = scale
    blur.extend = extend
    blur.quality = blurQuality(e.quality, extend)
    e.rd = blur

proc updateMotionBlur(e: MotionBlurEffect, tm: Matrix) =
  var offset: Point
  var samples: int
  if e.update(tm, offset, samples):
    let blur = if e.rd of GlMotionBlurData: GlMotionBlurData(e.rd) else: GlMotionBlurData()
    blur.offset = [offset.x, -offset.y]  # framebuffer Y runs opposite to scene Y
    blur.samples = float32(samples)
    e.rd = blur

proc updateDropShadow(e: DropShadowEffect, tm: Matrix) =
  var offset: Point
  if e.update(tm, offset):
    let shadow = if e.rd of GlDropShadowData: GlDropShadowData(e.rd) else: GlDropShadowData()
    let scale = scaleOf(tm)
    shadow.sigma = e.sigma
    shadow.scale = scale
    # the shader blends itself (GL_BLEND disabled): the color is premultiplied
    shadow.color[3] = float32(e.color[3]) / 255.0'f32
    for i in 0 ..< 3:
      shadow.color[i] = float32(e.color[i]) / 255.0'f32 * shadow.color[3]
    shadow.offset = [-offset.x, offset.y]
    let ax = e.sigma * scale + abs(offset.x)
    let ay = e.sigma * scale + abs(offset.y)
    shadow.extend = 2 * (if ax < ay: ay else: ax)  # std::max
    shadow.quality = blurQuality(e.quality, shadow.extend)
    e.rd = shadow

proc paramsOf(e: RenderEffect): GlParamsData =
  if e.rd of GlParamsData: GlParamsData(e.rd) else: GlParamsData()

func byteUnit(v: uint8): float32 = float32(v) / 255.0'f32

proc updateFill(e: FillEffect) =
  let p = paramsOf(e)
  for i in 0 ..< 4: p.params[i] = byteUnit(e.color[i])
  e.rd = p
  e.valid = true

proc updateTint(e: TintEffect) =
  e.valid = e.intensity > 0
  if e.valid:
    let p = paramsOf(e)
    for i in 0 ..< 3:
      p.params[i] = byteUnit(e.black[i])
      p.params[4 + i] = byteUnit(e.white[i])
    p.params[3] = 0.0'f32
    p.params[7] = 0.0'f32
    p.params[8] = byteUnit(e.intensity)
    e.rd = p

proc updateTritone(e: TritoneEffect) =
  e.valid = e.blender < 255
  if e.valid:
    let p = paramsOf(e)
    for i in 0 ..< 3:
      p.params[i] = byteUnit(e.shadow[i])
      p.params[4 + i] = byteUnit(e.midtone[i])
      p.params[8 + i] = byteUnit(e.highlight[i])
    p.params[3] = 0.0'f32
    p.params[7] = 0.0'f32
    p.params[11] = byteUnit(e.blender)
    e.rd = p

# ---------------------------------------------------------------- region (per effect)

proc regionBlur(e: GaussianBlurEffect): bool =
  let extend = toRegionInt(GlBlurData(e.rd).extend)
  if e.direction != 2:
    e.extend.xMin = -extend
    e.extend.xMax = extend
  if e.direction != 1:
    e.extend.yMin = -extend
    e.extend.yMax = extend
  true

proc regionMotionBlur(e: MotionBlurEffect): bool =
  let blur = GlMotionBlurData(e.rd)
  let x = toRegionInt(ceil(abs(blur.offset[0]) * 0.5'f32))
  let y = toRegionInt(ceil(abs(blur.offset[1]) * 0.5'f32))
  e.extend = Region(xMin: -x, yMin: -y, xMax: x, yMax: y)
  true

proc regionDropShadow(e: DropShadowEffect): bool =
  let extend = toRegionInt(GlDropShadowData(e.rd).extend)
  e.extend = Region(xMin: -extend, yMin: -extend, xMax: extend, yMax: extend)
  true

{.pop.}

# ---------------------------------------------------------------- public: update / region

proc newGlEffect*(stage: GlStageBuffer): GlEffect =
  ## `GlEffect(GlStageBuffer*)`: `stage` is the renderer's stage buffer.
  GlEffect(stage: stage)

proc ensureEffectPools*(blendPool: var seq[GlRenderTargetPool], width, height: uint32) =
  ## Grows the blend pool list to the two pools the effects need.
  while blendPool.len < 2: blendPool.add newGlRenderTargetPool(width, height)

proc update*(g: GlEffect, e: RenderEffect, tm: Matrix) =
  case e.kind
  of SceneEffect.MotionBlur: updateMotionBlur(MotionBlurEffect(e), tm)
  of SceneEffect.GaussianBlur: updateBlur(GaussianBlurEffect(e), tm)
  of SceneEffect.DropShadow: updateDropShadow(DropShadowEffect(e), tm)
  of SceneEffect.Fill: updateFill(FillEffect(e))
  of SceneEffect.Tint: updateTint(TintEffect(e))
  of SceneEffect.Tritone: updateTritone(TritoneEffect(e))
  of SceneEffect.Clear: discard

proc region*(g: GlEffect, e: RenderEffect): bool =
  if e.rd == nil: return false
  case e.kind
  of SceneEffect.MotionBlur: regionMotionBlur(MotionBlurEffect(e))
  of SceneEffect.GaussianBlur: regionBlur(GaussianBlurEffect(e))
  of SceneEffect.DropShadow: regionDropShadow(DropShadowEffect(e))
  else: false

proc dispose*(e: RenderEffect) =
  e.rd = nil

proc destroy*(g: GlEffect) =
  ## `~GlEffect`: deletes the programs.
  for p in g.programs.mitems:
    if p != nil: p.destroy()
    p = nil

# ---------------------------------------------------------------- render

proc getProgram(g: GlEffect, which: EffectProgram): GlProgram =
  if g.programs[which] == nil:
    g.programs[which] = newGlProgram(effectSource(which))
    if not g.programs[which].isValid:
      logGlError "Effect program " & $which & " failed to build"
  g.programs[which]

type EffectPass = object
  ## What every effect task needs: the destination target and where the quad lives.
  stage: GlStageBuffer
  voffset, ioffset: int
  vp: Region

proc layout(p: EffectPass): GlVertexLayout =
  GlVertexLayout(index: 0, size: 2, stride: 8, offset: p.voffset, ty: GlFloat,
    normalized: false, arrayBufferId: p.stage.getBufferId())

proc blurTask(p: EffectPass, prog: GlProgram, paramsOffset, viewportOffset: int): GlRenderTask =
  ## One Gaussian pass (horizontal or vertical): `Gaussian` + `Viewport` blocks and the quad.
  let buffer = p.stage.getBufferId()
  result = newGlRenderTask(prog)
  result.addBindResource(uniformBinding(0, GlShaderUniformBlock.Gaussian, buffer, paramsOffset,
    BlurBlockSize))
  result.addBindResource(uniformBinding(1, GlShaderUniformBlock.Viewport, buffer,
    viewportOffset, ViewportBlockSize))
  result.addVertexLayout(p.layout())
  result.setDrawRange(uint32(p.ioffset), 6)

proc viewportBlock(vp: Region): array[4, float32] =
  [0.0'f32, 0.0'f32, float32(vp.sw), float32(vp.sh)]

proc renderBlur(g: GlEffect, e: GaussianBlurEffect, p: EffectPass, dst: GlRenderTarget,
    pools: openArray[GlRenderTargetPool], state: var GlStateCache): GlRenderTask =
  let blurV = g.getProgram(EffectProgram.GaussianV)
  let blurH = g.getProgram(EffectProgram.GaussianH)
  let copy0 = pools[0].getRenderTarget(state, p.vp)
  let copy1 = pools[1].getRenderTarget(state, p.vp)

  let blurOffset = g.stage.push(GlBlurData(e.rd).uniforms(), true)
  let viewportOffset = g.stage.push(viewportBlock(p.vp), true)

  let task = newGlGaussianBlurTask(dst, copy0, copy1)
  task.effect = e
  task.setViewport(Region(xMin: 0, yMin: 0, xMax: p.vp.sw, yMax: p.vp.sh))
  task.horzTask = blurTask(p, blurH, blurOffset, viewportOffset)
  task.vertTask = blurTask(p, blurV, blurOffset, viewportOffset)
  task

proc renderMotionBlur(g: GlEffect, e: MotionBlurEffect, p: EffectPass, dst: GlRenderTarget,
    pools: openArray[GlRenderTargetPool], state: var GlStateCache): GlRenderTask =
  let prog = g.getProgram(EffectProgram.MotionBlur)
  let copy = pools[0].getRenderTarget(state, p.vp)
  let paramsOffset = g.stage.push(GlMotionBlurData(e.rd).uniforms(), true)
  let viewportOffset = g.stage.push(viewportBlock(p.vp), true)
  let buffer = g.stage.getBufferId()

  let task = newGlEffectTask(prog, dst, copy)
  task.setViewport(Region(xMin: 0, yMin: 0, xMax: p.vp.sw, yMax: p.vp.sh))
  task.addBindResource(uniformBinding(0, GlShaderUniformBlock.Params, buffer, paramsOffset,
    MotionBlockSize))
  task.addBindResource(uniformBinding(1, GlShaderUniformBlock.Viewport, buffer, viewportOffset,
    ViewportBlockSize))
  task.addVertexLayout(p.layout())
  task.setDrawRange(uint32(p.ioffset), 6)
  task

proc renderDropShadow(g: GlEffect, e: DropShadowEffect, p: EffectPass, dst: GlRenderTarget,
    pools: openArray[GlRenderTargetPool], state: var GlStateCache): GlRenderTask =
  let blurV = g.getProgram(EffectProgram.GaussianV)
  let blurH = g.getProgram(EffectProgram.GaussianH)
  let shadowProg = g.getProgram(EffectProgram.DropShadow)
  let copy0 = pools[0].getRenderTarget(state, p.vp)
  let copy1 = pools[1].getRenderTarget(state, p.vp)

  let paramsOffset = g.stage.push(GlDropShadowData(e.rd).uniforms(), true)
  let viewportOffset = g.stage.push(viewportBlock(p.vp), true)

  let task = newGlEffectDropShadowTask(shadowProg, dst, copy0, copy1)
  task.effect = e
  task.setViewport(Region(xMin: 0, yMin: 0, xMax: p.vp.sw, yMax: p.vp.sh))
  task.addBindResource(uniformBinding(0, GlShaderUniformBlock.DropShadow,
    g.stage.getBufferId(), paramsOffset, DropShadowBlockSize))
  task.addVertexLayout(p.layout())
  task.setDrawRange(uint32(p.ioffset), 6)
  # the blur passes read the leading `GlGaussianBlur` part of the drop shadow block
  task.horzTask = blurTask(p, blurH, paramsOffset, viewportOffset)
  task.vertTask = blurTask(p, blurV, paramsOffset, viewportOffset)
  task

proc renderColor(g: GlEffect, e: RenderEffect, p: EffectPass, dst: GlRenderTarget,
    pools: openArray[GlRenderTargetPool], state: var GlStateCache): GlRenderTask =
  ## Fill, tint and tritone: one pass with the `Params` block.
  let which = case e.kind
    of SceneEffect.Fill: EffectProgram.Fill
    of SceneEffect.Tint: EffectProgram.Tint
    else: EffectProgram.Tritone
  let prog = g.getProgram(which)
  let copy = pools[0].getRenderTarget(state, p.vp)
  let paramsOffset = g.stage.push(GlParamsData(e.rd).params, true)

  let task = newGlEffectTask(prog, dst, copy)
  task.setViewport(Region(xMin: 0, yMin: 0, xMax: p.vp.sw, yMax: p.vp.sh))
  task.addBindResource(uniformBinding(0, GlShaderUniformBlock.Params, g.stage.getBufferId(),
    paramsOffset, ParamsBlockSize))
  task.addVertexLayout(p.layout())
  task.setDrawRange(uint32(p.ioffset), 6)
  task

proc render*(g: GlEffect, e: RenderEffect, pass: GlRenderPass,
    blendPool: openArray[GlRenderTargetPool], state: var GlStateCache): bool =
  ## Appends the effect task to `pass`; `blendPool` needs two pools (`ensureEffectPools`).
  if pass.isEmpty or e.rd == nil or e.kind == SceneEffect.Clear: return false
  doAssert blendPool.len >= 2
  let p = EffectPass(stage: g.stage, vp: pass.getViewport(),
    voffset: g.stage.push(QuadVertices), ioffset: g.stage.pushIndex(QuadIndices))
  let dst = pass.fbo
  var output: GlRenderTask
  case e.kind
  of SceneEffect.MotionBlur:
    output = g.renderMotionBlur(MotionBlurEffect(e), p, dst, blendPool, state)
  of SceneEffect.GaussianBlur:
    output = g.renderBlur(GaussianBlurEffect(e), p, dst, blendPool, state)
  of SceneEffect.DropShadow:
    output = g.renderDropShadow(DropShadowEffect(e), p, dst, blendPool, state)
  else:
    output = g.renderColor(e, p, dst, blendPool, state)
  pass.addRenderTask output
  true
