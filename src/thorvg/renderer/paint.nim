## Paint base class: transform, opacity, blend, clipper, mask and the generic
## update / render / bounds / duplicate orchestration shared by all paints.
##
## Ported from `src/renderer/tvgPaint.h` / `tvgPaint.cpp` (`Paint::Impl`).
## Per-kind behaviour (the C++ `PAINT_METHOD` switch) is a set of base `method`s
## that Shape / Scene / Picture / Text override. Deviations (DECISIONS.md): no
## manual ref counting (Nim refs own everything; a removed paint releases its
## engine data), `parent` is a non-owning `{.cursor.}` like the C++ raw pointer (a
## strong parent makes ORC's cycle collector overflow the stack here), no
## damage/partial-render hooks.

import ../core/[types, geom]
import ./render

const AllUpdateFlags* = {RenderUpdateFlag.Path, RenderUpdateFlag.Color,
  RenderUpdateFlag.Gradient, RenderUpdateFlag.Stroke, RenderUpdateFlag.Transform,
  RenderUpdateFlag.Image, RenderUpdateFlag.GradientStroke, RenderUpdateFlag.Blend,
  RenderUpdateFlag.Clip, RenderUpdateFlag.Children}

type
  Transform* = object
    m*: Matrix            ## input matrix
    degree*: float32      ## rotation degree
    scale*: float32       ## scale factor
    overriding*: bool     ## user transform?

  Paint* = ref object of RootObj
    id*: uint32
    parent* {.cursor.}: Paint
    clipper*: Paint       ## always a Shape
    maskTarget*: Paint
    maskMethod*: MaskMethod
    renderer*: RenderMethod
    rd*: RenderData
    tr*: Transform
    renderFlags*: RenderUpdateFlags
    cmpFlags*: CompositionFlags
    blendMethod*: BlendMethod
    fastTrack*: bool      ## composited through the viewport (ContextFlag::FastTrack)
    opacity*: uint8
    hidden*: bool

# ---- per-kind behaviour ------------------------------------------------------

method kind*(p: Paint): PaintKind {.base.} = PaintKind.Shape

method skipUpdate*(p: Paint, flags: RenderUpdateFlags): bool {.base.} = false

method updateImpl*(p: Paint, r: RenderMethod, tm: Matrix, clips: var seq[RenderData],
    opacity: uint8, flags: RenderUpdateFlags, clipper: bool): bool {.base.} = true

method renderImpl*(p: Paint, r: RenderMethod, flags: CompositionFlags): bool {.base.} = true
method regionImpl*(p: Paint): Region {.base.} = Region()

method boundsImpl*(p: Paint, pt4: var array[4, Point], m: Matrix,
    obb: bool): bool {.base.} = false

method intersectsImpl*(p: Paint, region: Region, visibleOnly: bool): bool {.base.} = false
method duplicateImpl*(p: Paint): Paint {.base.} = nil
method releaseChildren*(p: Paint) {.base.} = discard
  ## Disposes the engine data of nested paints (scene children, picture content).

method fastRect*(p: Paint, pts: var array[4, Point]): bool {.base.} = false
  ## Shape only: true (with its 4 points) when it is a rectangle candidate.

method solidAlpha*(p: Paint, a: var uint8): bool {.base.} = false
  ## Shape only: true (with the fill alpha) when it has no gradient fill.

method strokeless*(p: Paint): bool {.base.} = false
  ## Shape only: true when the stroke width is 0.

# ---- construction / state ------------------------------------------------------

proc initPaint*(p: Paint) =
  ## `Paint::Impl::reset` for a new paint.
  p.clipper = nil
  p.maskTarget = nil
  p.maskMethod = MaskMethod.None
  p.tr = Transform(m: identity(), degree: 0.0'f32, scale: 1.0'f32)
  p.parent = nil
  p.blendMethod = BlendMethod.Normal
  p.renderFlags = {}
  p.fastTrack = false
  p.opacity = 255
  p.id = 0
  p.hidden = false

proc mark*(p: Paint, flag: RenderUpdateFlag) = p.renderFlags.incl flag
proc mark*(p: Paint, flag: CompositionFlag) = p.cmpFlags.incl flag
proc marked*(p: Paint, flag: RenderUpdateFlag): bool = flag in p.renderFlags

proc attachTo*(p: Paint, parent: Paint) =
  p.parent = parent
  if p.clipper != nil: p.clipper.attachTo(parent)
  if p.maskTarget != nil: p.maskTarget.attachTo(parent)

proc disposeRender*(p: Paint) =
  ## Releases the engine data of this paint (and nested paints) and forgets the
  ## renderer, so the paint can be added to another canvas later.
  if p.renderer != nil:
    if p.rd != nil: p.renderer.dispose(p.rd)
    p.rd = nil
    p.renderer = nil
    p.renderFlags = AllUpdateFlags
  p.releaseChildren()
  if p.clipper != nil: p.clipper.disposeRender()
  if p.maskTarget != nil: p.maskTarget.disposeRender()

# ---- transform / properties --------------------------------------------------------

func update(t: var Transform) =
  if t.overriding: return
  t.m.e11 = 1.0'f32
  t.m.e12 = 0.0'f32
  t.m.e21 = 0.0'f32
  t.m.e22 = 1.0'f32
  t.m.e31 = 0.0'f32
  t.m.e32 = 0.0'f32
  t.m.e33 = 1.0'f32
  scale(t.m, pt(t.scale, t.scale))
  rotate(t.m, t.degree)

proc transform*(p: Paint): Matrix =
  ## The current local matrix (recomputed when rotation/scale changed).
  if RenderUpdateFlag.Transform in p.renderFlags: p.tr.update()
  p.tr.m

proc transform*(p: Paint, m: Matrix): Result =
  p.tr.m = m
  p.tr.overriding = true
  p.mark RenderUpdateFlag.Transform
  Result.Success

proc rotate*(p: Paint, degree: float32): Result =
  if p.tr.overriding: return Result.InsufficientCondition
  if not equal(degree, p.tr.degree):
    p.tr.degree = degree
    p.mark RenderUpdateFlag.Transform
  Result.Success

proc scale*(p: Paint, factor: float32): Result =
  if p.tr.overriding: return Result.InsufficientCondition
  if not equal(factor, p.tr.scale):
    p.tr.scale = factor
    p.mark RenderUpdateFlag.Transform
  Result.Success

proc translate*(p: Paint, x, y: float32): Result =
  if p.tr.overriding: return Result.InsufficientCondition
  if not (equal(x, p.tr.m.e13) and equal(y, p.tr.m.e23)):
    p.tr.m.e13 = x
    p.tr.m.e23 = y
    p.mark RenderUpdateFlag.Transform
  Result.Success

proc ptransform*(p: Paint): Matrix =
  ## Product of all ancestors' matrices.
  result = identity()
  var q = p
  while q.parent != nil:
    q = q.parent
    result = q.transform() * result

proc opacity*(p: Paint, o: uint8): Result =
  if p.opacity != o:
    p.opacity = o
    p.mark RenderUpdateFlag.Color
  Result.Success

proc blend*(p: Paint, m: BlendMethod): Result =
  if p.blendMethod != m:
    p.blendMethod = m
    p.mark RenderUpdateFlag.Blend
  Result.Success

proc visible*(p: Paint, on: bool): Result =
  p.hidden = not on
  Result.Success

proc visible*(p: Paint): bool = not p.hidden

proc clip*(p: Paint, clp: Paint): Result =
  ## Sets (or with nil removes) the clipper; it must be a parentless Shape.
  if clp != nil and (clp.parent != nil or clp.kind != PaintKind.Shape):
    return Result.InsufficientCondition
  p.clipper = clp
  if clp != nil: clp.attachTo(p.parent)
  Result.Success

proc mask*(p: Paint, target: Paint, m: MaskMethod): Result =
  if target != nil and target.parent != nil: return Result.InsufficientCondition
  p.maskTarget = nil
  p.maskMethod = MaskMethod.None
  if m == MaskMethod.None:
    return if target != nil: Result.InvalidArguments else: Result.Success
  if target == nil: return Result.InvalidArguments
  p.maskTarget = target
  p.maskMethod = m
  target.attachTo(p.parent)
  Result.Success

proc mask*(p: Paint, target: var Paint): MaskMethod =
  target = p.maskTarget
  p.maskMethod

# ---- composition fast track ----------------------------------------------------------

func sign(p1, p2, p3: Point): float32 =
  (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)

func pointInConvexQuad(p: Point, quad: array[4, Point]): bool =
  let b1 = sign(p, quad[0], quad[1]) < 0.0'f32
  let b2 = sign(p, quad[1], quad[2]) < 0.0'f32
  let b3 = sign(p, quad[2], quad[3]) < 0.0'f32
  let b4 = sign(p, quad[3], quad[0]) < 0.0'f32
  b1 == b2 and b2 == b3 and b3 == b4

func clipRect(pts: array[4, Point], m: Matrix, before: Region): bool =
  ## True if the quad is a superset of the current viewport region.
  var c: array[4, Point]
  for i in 0 ..< 4: c[i] = pts[i] * m
  pointInConvexQuad(pt(float32(before.xMin), float32(before.yMin)), c) and
    pointInConvexQuad(pt(float32(before.xMax), float32(before.yMin)), c) and
    pointInConvexQuad(pt(float32(before.xMax), float32(before.yMax)), c) and
    pointInConvexQuad(pt(float32(before.xMin), float32(before.yMax)), c)

proc maskFastTrack(r: RenderMethod, target: Paint, pm: Matrix, before: Region): bool =
  ## `_compFastTrack`: replaces a rectangle clip/mask by a viewport restriction.
  var pts: array[4, Point]
  if not target.fastRect(pts): return false
  let tm = pm * target.transform()
  if rightAngle(tm) and not skewed(tm):
    let rectA = equal(pts[0].x, pts[1].x) and equal(pts[1].y, pts[2].y) and
      equal(pts[2].x, pts[3].x) and equal(pts[0].y, pts[3].y)
    let rectB = equal(pts[1].x, pts[2].x) and equal(pts[0].y, pts[1].y) and
      equal(pts[0].x, pts[3].x) and equal(pts[2].y, pts[3].y)
    if rectA or rectB:
      var v1 = pts[0] * tm
      var v2 = pts[2] * tm
      if v1.x > v2.x: swap(v1.x, v2.x)
      if v1.y > v2.y: swap(v1.y, v2.y)
      var after = Region(xMin: int32(nearbyint(v1.x)), yMin: int32(nearbyint(v1.y)),
                         xMax: int32(nearbyint(v2.x)), yMax: int32(nearbyint(v2.y)))
      if after.xMax < after.xMin: after.xMax = after.xMin
      if after.yMax < after.yMin: after.yMax = after.yMin
      r.vport = intersect(after, before)
      return true
  clipRect(pts, tm, before)

# ---- update / render / bounds ----------------------------------------------------------

proc paintRegion*(p: Paint): Region =
  ## Pixel bounds of the paint as prepared by the engine (empty before update).
  if p.renderer == nil: Region() else: p.regionImpl()

proc update*(p: Paint, r: RenderMethod, pm: Matrix, clips: var seq[RenderData],
    opacity: uint8, flags: RenderUpdateFlags, clipper = false): RenderData =
  ## Prepares the paint (and its mask / clipper) with the engine.
  if p.skipUpdate(flags + p.renderFlags): return p.rd
  p.cmpFlags = {}  # must clear after the rendering
  p.renderer = r
  if RenderUpdateFlag.Transform in p.renderFlags: p.tr.update()

  # 1. Composition pre processing
  var viewport = Region()
  var fast = false
  if p.maskTarget != nil:
    let target = p.maskTarget
    target.fastTrack = false
    var a = 0'u8
    if target.kind == PaintKind.Shape and target.solidAlpha(a) and
        target.maskTarget == nil:
      let m = p.maskMethod
      if (m == MaskMethod.Alpha and a == 255 and target.opacity == 255) or
          (m == MaskMethod.InvAlpha and (a == 0 or target.opacity == 0)):
        viewport = r.vport
        fast = maskFastTrack(r, target, pm, viewport)
        if fast: target.fastTrack = true
    if not fast: discard target.update(r, pm, clips, 255, flags, false)

  # 2. Clipping
  if p.clipper != nil:
    let pclip = p.clipper
    pclip.fastTrack = false
    viewport = r.vport
    if pclip.clipper == nil and pclip.strokeless() and
        maskFastTrack(r, pclip, pm, viewport):
      pclip.fastTrack = true
      fast = true
    else:
      p.mark RenderUpdateFlag.Clip
      var noClip: seq[RenderData] = @[]
      clips.add pclip.update(r, pm, noClip, 255, flags, true)

  # 3. Main update
  let op = multiply(opacity, p.opacity)
  discard p.updateImpl(r, pm * p.tr.m, clips, op, flags + p.renderFlags, clipper)

  # 4. Composition post processing
  if fast: r.vport = viewport
  elif p.clipper != nil: clips.setLen(clips.len - 1)
  p.renderFlags = {}
  p.rd

proc render*(p: Paint, r: RenderMethod, flags: CompositionFlags = {}): bool =
  ## Draws the paint; masks are composited through `target`/`beginComposite`.
  if p.hidden or p.opacity == 0: return true
  var cmp: RenderCompositor = nil
  if p.maskTarget != nil and not p.maskTarget.fastTrack:
    var region = p.regionImpl()
    var m = p
    while m != nil and m.maskTarget != nil:
      if maskRegionMerging(m.maskMethod): region = add(region, m.maskTarget.paintRegion())
      if region.invalid: return true
      m = m.maskTarget
    cmp = r.target(region, maskToColorSpace(r, p.maskMethod), {CompositionFlag.Masking})
    if r.beginComposite(cmp, MaskMethod.None, 255): discard p.maskTarget.render(r)
  if cmp != nil: discard r.beginComposite(cmp, p.maskMethod, p.maskTarget.opacity)
  result = p.renderImpl(r, flags)
  if cmp != nil: discard r.endComposite(cmp)

proc paintBounds*(p: Paint, pt4: var array[4, Point], pm: Matrix, obb: bool): bool =
  ## Corner points of the paint; `pm` is the parent matrix (identity for none).
  p.boundsImpl(pt4, pm * p.transform(), obb)

proc intersects*(p: Paint, region: Region, visibleOnly: bool): bool =
  if visibleOnly and p.hidden: return false
  if p.renderer != nil: return p.intersectsImpl(region, visibleOnly)
  false

proc intersects*(p: Paint, x, y, w, h: int, visibleOnly = false): bool =
  if w <= 0 or h <= 0: return false
  p.intersects(Region(xMin: int32(x), yMin: int32(y), xMax: int32(x + w),
                      yMax: int32(y + h)), visibleOnly)

proc bounds*(p: Paint, x, y, w, h: var float32): Result =
  ## Axis-aligned bounds in canvas space.
  var pt4: array[4, Point]
  if not p.paintBounds(pt4, p.ptransform(), false): return Result.InsufficientCondition
  var box = initBBox()
  for q in pt4:
    box.min = min(box.min, q)
    box.max = max(box.max, q)
  x = box.min.x
  y = box.min.y
  w = box.max.x - box.min.x
  h = box.max.y - box.min.y
  Result.Success

proc bounds*(p: Paint, pt4: var array[4, Point]): Result =
  ## Oriented bounding box (4 corners) in canvas space.
  if p.paintBounds(pt4, p.ptransform(), true): Result.Success
  else: Result.InsufficientCondition

proc duplicate*(p: Paint): Paint =
  ## Deep copy (not attached to any parent or renderer).
  result = p.duplicateImpl()
  if p.maskTarget != nil: discard result.mask(p.maskTarget.duplicate(), p.maskMethod)
  if p.clipper != nil: discard result.clip(p.clipper.duplicate())
  result.tr = p.tr
  result.blendMethod = p.blendMethod
  result.opacity = p.opacity
  result.hidden = p.hidden
  result.renderFlags = AllUpdateFlags
