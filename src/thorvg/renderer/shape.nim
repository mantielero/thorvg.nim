## Shape paint: a vector path with fill and stroke (wraps a `RenderShape`).
##
## Ported from `src/renderer/tvgShape.h` / `tvgShape.cpp`. Gradients are plain
## `Fill` values (copied on assignment), so there is no gradient ownership
## handling. Like the original, `moveTo` does not flag the path as changed.

import std/[options, math]
import ../core/[types, geom, path, fill]
import ./[render, paint]

type Shape* = ref object of Paint
  rs*: RenderShape
  cmpOpacity: uint8       ## opacity applied when the shape is composited

proc newShape*(): Shape =
  result = Shape()
  initPaint(result)

# ---- Paint behaviour -----------------------------------------------------------

method kind*(s: Shape): PaintKind = PaintKind.Shape
method skipUpdate*(s: Shape, flags: RenderUpdateFlags): bool = flags == {}

method fastRect*(s: Shape, pts: var array[4, Point]): bool =
  if s.rs.trimpath() or s.rs.path.pts.len != 4: return false
  for i in 0 ..< 4: pts[i] = s.rs.path.pts[i]
  true

method solidAlpha*(s: Shape, a: var uint8): bool =
  a = s.rs.color.a
  s.rs.fill.isNone

method strokeless*(s: Shape): bool = s.rs.strokeWidth() == 0.0'f32

proc needComposition(s: Shape, opacity: uint8): bool =
  ## Composition is only necessary when both fill and stroke are visible.
  if opacity == 0: return false
  if s.rs.stroke.isNone: return false
  let st = s.rs.stroke.get
  if st.width < FloatEpsilon or (st.fill.isNone and st.color.a == 0): return false
  if s.rs.fill.isNone and s.rs.color.a == 0: return false
  if opacity < 255:  # translucent fill & stroke
    s.mark CompositionFlag.Opacity
    return true
  let target = s.maskTarget
  if target == nil: return false
  if (target.opacity == 255 or target.opacity == 0) and target of Shape and
      target.kind == PaintKind.Shape:
    let ts = Shape(target)
    if ts.rs.fill.isNone:
      let c = ts.rs.color
      if c.a == 0 or c.a == 255:
        if s.maskMethod == MaskMethod.Luma or s.maskMethod == MaskMethod.InvLuma:
          if (c.r == 255 and c.g == 255 and c.b == 255) or (c.r == 0 and c.g == 0 and c.b == 0):
            return false
        else: return false
  s.mark CompositionFlag.Masking
  true

method updateImpl*(s: Shape, r: RenderMethod, tm: Matrix, clips: var seq[RenderData],
    opacity: uint8, flags: RenderUpdateFlags, clipper: bool): bool =
  var op = opacity
  if s.needComposition(op):
    # A translucent shape does an intermediate composition with that opacity.
    s.cmpOpacity = op
    op = 255
  s.rd = r.prepareShape(s.rs, s.rd, tm, clips, op, flags, clipper)
  true

method renderImpl*(s: Shape, r: RenderMethod, flags: CompositionFlags): bool =
  if s.rd == nil: return false
  var cmp: RenderCompositor = nil
  discard r.blend(s.blendMethod)
  if s.cmpFlags != {}:
    cmp = r.target(s.regionImpl(), r.colorSpace(), s.cmpFlags)
    discard r.beginComposite(cmp, MaskMethod.None, s.cmpOpacity)
  result = r.renderShape(s.rd)
  if cmp != nil: discard r.endComposite(cmp)

method regionImpl*(s: Shape): Region = s.renderer.region(s.rd)

method boundsImpl*(s: Shape, pt4: var array[4, Point], m: Matrix, obb: bool): bool =
  var fallback = true
  if s.renderer != nil and s.rs.strokeWidth() > 0.0'f32:
    if s.renderer.bounds(s.rd, pt4, if obb: identity() else: m): fallback = false
  if fallback:  # legacy path, loaders still depend on it
    var box: BBox
    if not (if obb: s.rs.path.bounds(box) else: s.rs.path.bounds(box, m)): return false
    if s.rs.stroke.isSome:
      # Geometric mean for feathering; joins and caps are not considered.
      let sx = sqrt(m.e11 * m.e11 + m.e21 * m.e21)
      let sy = sqrt(m.e12 * m.e12 + m.e22 * m.e22)
      let feather = s.rs.stroke.get.width * sqrt(sx * sy)
      box.min.x -= feather * 0.5'f32
      box.min.y -= feather * 0.5'f32
      box.max.x += feather * 0.5'f32
      box.max.y += feather * 0.5'f32
    pt4[0] = box.min
    pt4[1] = pt(box.max.x, box.min.y)
    pt4[2] = box.max
    pt4[3] = pt(box.min.x, box.max.y)
  if obb:
    for i in 0 ..< 4: pt4[i] = pt4[i] * m
  true

method intersectsImpl*(s: Shape, region: Region, visibleOnly: bool): bool =
  if s.rd == nil or s.renderer == nil: return false
  s.renderer.intersectsShape(s.rd, region)

method duplicateImpl*(s: Shape): Paint =
  let dup = newShape()
  dup.rs = s.rs
  dup

# ---- path ----------------------------------------------------------------------

proc path*(s: Shape): lent RenderPath = s.rs.path

proc reset*(s: Shape): Result =
  ## Clears the path (colors and stroke are kept).
  s.rs.path.clear()
  s.mark RenderUpdateFlag.Path
  Result.Success

proc appendPath*(s: Shape, cmds: openArray[PathCommand], pts: openArray[Point]): Result =
  if cmds.len == 0 or pts.len == 0: return Result.InvalidArguments
  s.rs.path.cmds.add cmds
  s.rs.path.pts.add pts
  s.mark RenderUpdateFlag.Path
  Result.Success

proc moveTo*(s: Shape, x, y: float32): Result =
  s.rs.path.moveTo(pt(x, y))
  Result.Success

proc lineTo*(s: Shape, x, y: float32): Result =
  s.rs.path.lineTo(pt(x, y))
  s.mark RenderUpdateFlag.Path
  Result.Success

proc cubicTo*(s: Shape, cx1, cy1, cx2, cy2, x, y: float32): Result =
  s.rs.path.cubicTo(pt(cx1, cy1), pt(cx2, cy2), pt(x, y))
  s.mark RenderUpdateFlag.Path
  Result.Success

proc close*(s: Shape): Result =
  s.rs.path.close()
  s.mark RenderUpdateFlag.Path
  Result.Success

proc appendCircle*(s: Shape, cx, cy, rx, ry: float32, cw = true): Result =
  s.rs.path.addCircle(cx, cy, rx, ry, cw)
  s.mark RenderUpdateFlag.Path
  Result.Success

proc appendRect*(s: Shape, x, y, w, h: float32, rx = 0.0'f32, ry = 0.0'f32,
    cw = true): Result =
  s.rs.path.addRect(x, y, w, h, rx, ry, cw)
  s.mark RenderUpdateFlag.Path
  Result.Success

proc fillRule*(s: Shape, r: FillRule): Result =
  s.rs.rule = r
  Result.Success

proc fillRule*(s: Shape): FillRule = s.rs.rule

# ---- fill ----------------------------------------------------------------------

proc fill*(s: Shape, r, g, b, a: uint8): Result =
  ## Solid fill; replaces any gradient.
  if s.rs.fill.isSome:
    s.rs.fill = none(Fill)
    s.mark RenderUpdateFlag.Gradient
  let c = RGBA(r: r, g: g, b: b, a: a)
  if c != s.rs.color:
    s.rs.color = c
    s.mark RenderUpdateFlag.Color
  Result.Success

proc fill*(s: Shape, f: Fill): Result =
  s.rs.fill = some(f)
  s.mark RenderUpdateFlag.Gradient
  Result.Success

proc fill*(s: Shape): Option[Fill] = s.rs.fill
proc fillColor*(s: Shape): RGBA = s.rs.color

# ---- stroke --------------------------------------------------------------------

proc ensureStroke(s: Shape) =
  if s.rs.stroke.isNone: s.rs.stroke = some(initStroke())

proc order*(s: Shape, strokeFirst: bool): Result =
  s.ensureStroke()
  s.rs.stroke.get.first = strokeFirst
  s.mark RenderUpdateFlag.Stroke
  Result.Success

proc strokeWidth*(s: Shape, width: float32): Result =
  s.ensureStroke()
  s.rs.stroke.get.width = max(width, 0.0'f32)
  s.mark RenderUpdateFlag.Stroke
  Result.Success

proc strokeWidth*(s: Shape): float32 = s.rs.strokeWidth()

proc strokeFill*(s: Shape, r, g, b, a: uint8): Result =
  s.ensureStroke()
  if s.rs.stroke.get.fill.isSome:
    s.rs.stroke.get.fill = none(Fill)
    s.mark RenderUpdateFlag.GradientStroke
  s.rs.stroke.get.color = RGBA(r: r, g: g, b: b, a: a)
  s.mark RenderUpdateFlag.Stroke
  Result.Success

proc strokeFill*(s: Shape, f: Fill): Result =
  s.ensureStroke()
  s.rs.stroke.get.fill = some(f)
  s.rs.stroke.get.color.a = 0
  s.mark RenderUpdateFlag.Stroke
  s.mark RenderUpdateFlag.GradientStroke
  Result.Success

proc strokeFill*(s: Shape): Option[Fill] =
  if s.rs.stroke.isSome: s.rs.stroke.get.fill else: none(Fill)

proc strokeFillColor*(s: Shape, c: var RGBA): Result =
  ## InsufficientCondition when the shape has no stroke.
  if s.rs.stroke.isNone: return Result.InsufficientCondition
  c = s.rs.stroke.get.color
  Result.Success

proc strokeDash*(s: Shape, pattern: openArray[float32], offset: float32 = 0.0'f32): Result =
  ## Sets the dash pattern (negative values count as 0); empty clears the dash.
  s.ensureStroke()
  var dash = RenderDash(offset: offset)
  for v in pattern:
    dash.pattern.add max(v, 0.0'f32)
    dash.length += dash.pattern[^1]
  s.rs.stroke.get.dash = dash
  s.mark RenderUpdateFlag.Stroke
  Result.Success

proc strokeDash*(s: Shape, offset: var float32): seq[float32] =
  if s.rs.stroke.isNone: return @[]
  offset = s.rs.stroke.get.dash.offset
  s.rs.stroke.get.dash.pattern

proc strokeCap*(s: Shape, cap: StrokeCap): Result =
  s.ensureStroke()
  s.rs.stroke.get.cap = cap
  s.mark RenderUpdateFlag.Stroke
  Result.Success

proc strokeCap*(s: Shape): StrokeCap =
  if s.rs.stroke.isSome: s.rs.stroke.get.cap else: StrokeCap.Square

proc strokeJoin*(s: Shape, join: StrokeJoin): Result =
  s.ensureStroke()
  s.rs.stroke.get.join = join
  s.mark RenderUpdateFlag.Stroke
  Result.Success

proc strokeJoin*(s: Shape): StrokeJoin =
  if s.rs.stroke.isSome: s.rs.stroke.get.join else: StrokeJoin.Bevel

proc strokeMiterlimit*(s: Shape, miterlimit: float32): Result =
  ## A negative miter limit is illegal (SVG2).
  if miterlimit < 0.0'f32: return Result.InvalidArguments
  s.ensureStroke()
  s.rs.stroke.get.miterlimit = miterlimit
  s.mark RenderUpdateFlag.Stroke
  Result.Success

proc strokeMiterlimit*(s: Shape): float32 =
  if s.rs.stroke.isSome: s.rs.stroke.get.miterlimit else: 4.0'f32

proc trimpath*(s: Shape, begin, `end`: float32, simultaneous = true): Result =
  if s.rs.stroke.isNone:
    if begin == 0.0'f32 and `end` == 1.0'f32: return Result.Success
    s.ensureStroke()
  let t = s.rs.stroke.get.trim
  if equal(t.begin, begin) and equal(t.`end`, `end`) and t.simultaneous == simultaneous:
    return Result.Success
  s.rs.stroke.get.trim = RenderTrimPath(begin: begin, `end`: `end`,
                                        simultaneous: simultaneous)
  s.mark RenderUpdateFlag.Path
  Result.Success

proc trimpathRange*(s: Shape, begin, `end`: var float32): bool =
  ## Current trim range; the result is the `simultaneous` flag.
  if s.rs.stroke.isSome:
    begin = s.rs.stroke.get.trim.begin
    `end` = s.rs.stroke.get.trim.`end`
    return s.rs.stroke.get.trim.simultaneous
  begin = 0.0'f32
  `end` = 1.0'f32
  false
