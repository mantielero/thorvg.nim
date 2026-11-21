## Scene paint: an ordered container of child paints.
##
## Ported from `src/renderer/tvgScene.h` / `tvgScene.cpp`. Scene effects (blur, shadow,
## tint, ...) are added with `gaussianBlur` & co. (`Scene::add(SceneEffect, ...)`);
## partial rendering is out of scope (DECISIONS.md D5).
## Removing a child releases its engine data (`disposeRender`).

import std/math
import ../core/[types, geom]
import ./[render, paint, effect]

type Scene* = ref object of Paint
  paints*: seq[Paint]       ## children, drawn in order
  effects: seq[RenderEffect]  ## post effects, applied in order
  vport: Region             ## region of the scene (updated by update/bounds)
  fsize: Point              ## fixed scene size
  fixed: bool               ## true: fixed scene size, false: dynamic size
  vdirty: bool
  cmpOpacity: uint8         ## opacity applied when the scene is composited

proc newScene*(): Scene =
  result = Scene()
  initPaint(result)

proc size*(s: Scene, w, h: float32) =
  ## Fixed size of the scene; a non-positive size makes it dynamic again.
  s.fsize = pt(w, h)
  s.fixed = w > 0 and h > 0

# ---- Paint behaviour -----------------------------------------------------------

method kind*(s: Scene): PaintKind = PaintKind.Scene

proc needComposition(s: Scene, opacity: uint8): bool =
  if opacity == 0 or s.paints.len == 0: return false
  # Post effects, masking and blending may require composition.
  if s.effects.len > 0: s.mark CompositionFlag.PostProcessing
  if s.maskTarget != nil: s.mark CompositionFlag.Masking
  if s.blendMethod != BlendMethod.Normal: s.mark CompositionFlag.Blending
  # Half translucent requires intermediate composition.
  if opacity == 255: return s.cmpFlags != {}
  # Only a shape or picture may not require composition.
  if s.paints.len == 1:
    let k = s.paints[0].kind
    if k == PaintKind.Shape or k == PaintKind.Picture: return s.cmpFlags != {}
  s.mark CompositionFlag.Opacity
  true

method updateImpl*(s: Scene, r: RenderMethod, tm: Matrix, clips: var seq[RenderData],
    opacity: uint8, flags: RenderUpdateFlags, clipper: bool): bool =
  if s.paints.len == 0: return true
  var op = opacity
  if s.needComposition(op):
    s.cmpOpacity = op
    op = 255
  for c in s.paints: discard c.update(r, tm, clips, op, flags, false)
  for e in s.effects: r.effectPrepare(e, tm)
  s.vport = r.vport
  if s.fixed:
    let p = s.fsize * tm
    s.vport = intersect(s.vport, Region(xMin: int32(round(tm.e13)),
      yMin: int32(round(tm.e23)), xMax: int32(round(p.x)), yMax: int32(round(p.y))))
  else:
    s.vdirty = true
  true

method renderImpl*(s: Scene, r: RenderMethod, flags: CompositionFlags): bool =
  if s.paints.len == 0: return true
  # a parent already in composition mode may parasitize its surface
  let incomposite = CompositionFlag.PostProcessing in flags and s.effects.len == 0
  var cmp: RenderCompositor = nil
  result = true
  discard r.blend(s.blendMethod)
  if not incomposite and s.cmpFlags != {}:
    cmp = r.target(s.regionImpl(), r.colorSpace(), s.cmpFlags)
    discard r.beginComposite(cmp, MaskMethod.None, s.cmpOpacity)
  for c in s.paints: result = c.render(r, s.cmpFlags) and result
  if cmp != nil:
    # apply the post effects; a single one may compose straight into the origin surface
    let direct = s.effects.len == 1 and CompositionFlag.PostProcessing in s.cmpFlags
    for e in s.effects:
      if e.valid: discard r.effectRender(cmp, e, direct)
    discard r.endComposite(cmp)

method regionImpl*(s: Scene): Region =
  if s.paints.len == 0: return Region()
  if not s.vdirty: return s.vport
  s.vdirty = false
  var merged = Region(xMin: high(int32), yMin: high(int32), xMax: 0, yMax: 0)
  for c in s.paints:
    let region = c.paintRegion()
    if region.xMin < merged.xMin: merged.xMin = region.xMin
    if merged.xMax < region.xMax: merged.xMax = region.xMax
    if region.yMin < merged.yMin: merged.yMin = region.yMin
    if merged.yMax < region.yMax: merged.yMax = region.yMax
  # extends the region if the post effects require; each effect expands the output
  # of the preceding ones
  for e in s.effects:
    if not e.valid or not s.renderer.effectRegion(e): continue
    merged.xMin += e.extend.xMin
    merged.yMin += e.extend.yMin
    merged.xMax += e.extend.xMax
    merged.yMax += e.extend.yMax
  s.vport = intersect(s.vport, merged)
  s.vport

method boundsImpl*(s: Scene, pt4: var array[4, Point], m: Matrix, obb: bool): bool =
  if s.paints.len == 0: return false
  var lo = pt(FltMax, FltMax)
  var hi = pt(-FltMax, -FltMax)
  for c in s.paints:
    var tmp: array[4, Point]
    if c.paintBounds(tmp, if obb: identity() else: m, false):
      for q in tmp:
        lo = min(lo, q)
        hi = max(hi, q)
      result = true
  pt4[0] = lo
  pt4[1] = pt(hi.x, lo.y)
  pt4[2] = hi
  pt4[3] = pt(lo.x, hi.y)
  if obb:
    for i in 0 ..< 4: pt4[i] = pt4[i] * m

method intersectsImpl*(s: Scene, region: Region, visibleOnly: bool): bool =
  if s.renderer == nil or not s.regionImpl().intersected(region): return false
  for c in s.paints:
    if c.intersects(region, visibleOnly): return true
  false

method duplicateImpl*(s: Scene): Paint =
  let dup = newScene()
  for c in s.paints:
    let cd = c.duplicate()
    cd.attachTo(dup)
    dup.paints.add cd
  for e in s.effects:
    let ed = e.duplicate()
    if ed != nil: dup.effects.add ed
  if s.fixed: dup.size(s.fsize.x, s.fsize.y)
  dup

method releaseChildren*(s: Scene) =
  for c in s.paints: c.disposeRender()

# ---- children ------------------------------------------------------------------

proc add*(s: Scene, target: Paint, at: Paint = nil): Result =
  ## Appends `target`, or inserts it before `at`. A paint can have one parent only.
  if target == nil: return Result.InvalidArguments
  if target.parent != nil: return Result.InsufficientCondition
  var idx = s.paints.len
  if at != nil:
    idx = s.paints.find(at)
    if idx < 0: return Result.InvalidArguments
  target.mark RenderUpdateFlag.Transform  # relocated to the scene space
  s.paints.insert(target, idx)
  target.attachTo(s)
  Result.Success

proc detach(c: Paint) =
  c.attachTo(nil)
  c.disposeRender()

proc remove*(s: Scene, p: Paint): Result =
  if p == nil or p.parent != Paint(s): return Result.InsufficientCondition
  let idx = s.paints.find(p)
  if idx < 0: return Result.InsufficientCondition
  s.paints.delete(idx)
  p.detach()
  Result.Success

proc clear*(s: Scene): Result =
  ## Removes every child (`Scene::remove(nullptr)`).
  for c in s.paints: c.detach()
  s.paints.setLen(0)
  Result.Success

# ---- effects -------------------------------------------------------------------

proc addEffect(s: Scene, e: RenderEffect): Result =
  s.effects.add e
  Result.Success

proc clearEffects*(s: Scene): Result =
  ## Removes every effect (`Scene::add(SceneEffect::Clear)`).
  if s.renderer != nil:
    for e in s.effects: s.renderer.effectDispose(e)
  s.effects.setLen(0)
  Result.Success

proc gaussianBlur*(s: Scene, sigma: float, direction = 0, border = 0,
    quality = 100): Result =
  ## Gaussian blur: `direction` 0 both, 1 horizontal, 2 vertical; `border` 0
  ## duplicate, 1 wrap; `quality` 0..100.
  s.addEffect genGaussianBlur(sigma, direction, border, quality)

proc dropShadow*(s: Scene, r, g, b, a: int, angle, distance, sigma: float,
    quality = 100): Result =
  ## Blurred, offset copy of the scene drawn under it.
  s.addEffect genDropShadow(r, g, b, a, angle, distance, sigma, quality)

proc fill*(s: Scene, r, g, b, a: int): Result =
  ## Replaces the colors of the scene by one color, keeping its alpha.
  s.addEffect genFill(r, g, b, a)

proc tint*(s: Scene, blackR, blackG, blackB, whiteR, whiteG, whiteB: int,
    intensity: float): Result =
  ## Duotone: maps the luma between the black and white colors (`intensity` 0..100).
  s.addEffect genTint(blackR, blackG, blackB, whiteR, whiteG, whiteB, intensity)

proc tritone*(s: Scene, shadow, midtone, highlight: array[3, int], blender = 0): Result =
  ## Three color mapping of the luma; `blender` 0..255 keeps part of the original.
  s.addEffect genTritone(shadow, midtone, highlight, blender)

proc motionBlur*(s: Scene, distance, angle: float, quality = 100): Result =
  ## Linear blur along `angle` (degrees) over `distance` pixels.
  s.addEffect genMotionBlur(distance, angle, quality)