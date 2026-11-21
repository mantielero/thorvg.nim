## Gradient parsing and resolution of the SVG loader: `<linearGradient>`, `<radialGradient>`,
## `<stop>`, `href` inheritance between gradients and the assignment of gradients to the
## paints that reference them.
##
## Ported from the gradient section of `modules/svg/tvgSvgLoader.cpp`. The per-coordinate
## handler tables of the original (`linear_tags`, `radialTags`) are loops over
## `SvgStyleGradient.coord` (see `nodes`). The recalculation divides and multiplies by the
## viewport, so float checks are off here like in the original (a zero-size viewport gives
## inf/nan instead of an exception).

import std/[options, math]
import ../../core/[types, geom]
import ./[nodes, util, color, xml, parser_value]

{.push floatChecks: off.}

type GradientCoord = enum
  ## Index of a gradient coordinate (the order of the `coord` array).
  gcCx, gcCy, gcFx, gcFy, gcR, gcFr

func coordFlag(kind: SvgGradientType, i: int): SvgGradientFlag =
  if kind == SvgGradientType.Linear: LinearFlags[i] else: RadialFlags[i]

func coordCount(kind: SvgGradientType): int =
  if kind == SvgGradientType.Linear: 4 else: 6

func viewDiagonal(ctx: SvgParserContext): float32 =
  ## The reference length of radii: the viewport diagonal over sqrt(2).
  let g = ctx.parser.global
  sqrt(g.h * g.h + g.w * g.w) / sqrt(2.0'f32)

func coordScale(ctx: SvgParserContext, kind: SvgGradientType, i: int): float32 =
  ## Reference length of coordinate `i`: x-like -> width, y-like -> height, radii -> diagonal.
  if kind == SvgGradientType.Radial and i >= ord(gcR): viewDiagonal(ctx)
  elif i mod 2 == 0: ctx.parser.global.w
  else: ctx.parser.global.h

func recalc(ctx: SvgParserContext, grad: SvgStyleGradient, i: int, userSpace: bool) =
  ## `_recalc<Kind><Coord>Attr`: user-space lengths become fractions of the viewport.
  if userSpace and not grad.isPercentage[i]:
    grad.coord[i] = grad.coord[i] / coordScale(ctx, grad.kind, i)

func recalcInherited(ctx: SvgParserContext, grad: SvgStyleGradient, i: int, userSpace: bool) =
  ## `_recalcInherited<Kind><Coord>Attr`: the inherited value changes unit system.
  if grad.isPercentage[i]: return
  if userSpace: grad.coord[i] = grad.coord[i] / coordScale(ctx, grad.kind, i)
  else: grad.coord[i] = grad.coord[i] * coordScale(ctx, grad.kind, i)

func coordIndex(kind: SvgGradientType, key: string): int =
  ## Index of the coordinate attribute `key`, -1 when it is none.
  if kind == SvgGradientType.Linear:
    case key
    of "x1": 0
    of "y1": 1
    of "x2": 2
    of "y2": 3
    else: -1
  else:
    case key
    of "cx": 0
    of "cy": 1
    of "fx": 2
    of "fy": 3
    of "r": 4
    of "fr": 5
    else: -1

proc parseGradientAttr(ctx: SvgParserContext, key, value: string): bool =
  ## `_attrParse{Linear,Radial}GradientNode`.
  let grad = ctx.parser.styleGrad
  let i = coordIndex(grad.kind, key)
  if i >= 0:
    grad.coord[i] = gradientFloat(ctx, value, grad.isPercentage[i])
    if grad.kind == SvgGradientType.Radial:
      case i
      of ord(gcCx), ord(gcCy):
        let f = i + 2 # fx follows cx, fy follows cy unless parsed explicitly
        if not (if i == ord(gcCx): ctx.parser.parsedFx else: ctx.parser.parsedFy):
          grad.coord[f] = grad.coord[i]
          grad.isPercentage[f] = grad.isPercentage[i]
      of ord(gcFx): ctx.parser.parsedFx = true
      of ord(gcFy): ctx.parser.parsedFy = true
      else: discard
    grad.flags.incl coordFlag(grad.kind, i)
    return true
  case key
  of "id": grad.id = value
  of "spreadMethod":
    grad.spread = toSpreadValue(value)
    grad.flags.incl SvgGradientFlag.SpreadMethod
  of "href", "xlink:href": grad.refId = idFromHref(value)
  of "gradientUnits":
    if value == "userSpaceOnUse": grad.userSpace = true
    grad.flags.incl SvgGradientFlag.GradientUnits
  of "gradientTransform":
    var m = identity()
    grad.transform = if parseTransform(value, m): some(m) else: none(Matrix)
  else: return false
  true

proc createGradient*(ctx: SvgParserContext, kind: SvgGradientType, attrs: string,
                     parse: AttrParser): SvgStyleGradient =
  ## `_createLinearGradient` / `_createRadialGradient`: defaults are fractions of the viewport.
  let grad = SvgStyleGradient(kind: kind)
  ctx.parser.styleGrad = grad
  if kind == SvgGradientType.Linear:
    grad.coord[2] = 1.0'f32
    grad.isPercentage[2] = true
  else:
    for i in 0 .. 3: grad.coord[i] = 0.5'f32
    grad.coord[ord(gcR)] = 0.5'f32
    for i in 0 .. 5: grad.isPercentage[i] = true
    ctx.parser.parsedFx = false
    ctx.parser.parsedFy = false
  discard parse(attrs, proc(key, value: string): bool = parseGradientAttr(ctx, key, value))
  for i in 0 ..< coordCount(kind): recalc(ctx, grad, i, grad.userSpace)
  grad

func findLatestColor(ctx: SvgParserContext, c: var RGBA): bool =
  ## The nearest `color` set on the open elements (for `stop-color: currentColor`).
  var parent = if ctx.stack.len > 0: ctx.stack[^1] else: ctx.doc
  while parent != nil:
    if parent.style.curColorSet:
      c = parent.style.color
      return true
    parent = parent.parent
  false

proc stopCurrentColor(ctx: SvgParserContext) =
  var latest: RGBA
  if findLatestColor(ctx, latest):
    ctx.parser.gradStop.r = latest.r
    ctx.parser.gradStop.g = latest.g
    ctx.parser.gradStop.b = latest.b

proc setStopColor(ctx: SvgParserContext, value: string): bool =
  ## `_toColor(value, stop->r, stop->g, stop->b, nullptr)`: the alpha is not touched.
  var c = RGBA(r: ctx.parser.gradStop.r, g: ctx.parser.gradStop.g, b: ctx.parser.gradStop.b,
               a: ctx.parser.gradStop.a)
  result = toColor(value, c)
  if result:
    ctx.parser.gradStop.r = c.r
    ctx.parser.gradStop.g = c.g
    ctx.parser.gradStop.b = c.b

proc parseStopStyle(ctx: SvgParserContext, key, value: string): bool =
  ## `_attrParseStopsStyle`: declarations of `style=""` win over attributes.
  if key == "stop-opacity":
    ctx.parser.gradStop.a = uint8(toOpacity(value) and 0xff)
    ctx.parser.flags.incl SvgStopStyleFlag.StopOpacity
  elif key == "stop-color":
    if value == "currentColor": stopCurrentColor(ctx)
    elif setStopColor(ctx, value): ctx.parser.flags.incl SvgStopStyleFlag.StopColor
  else: return false
  true

proc parseStopAttr*(ctx: SvgParserContext, key, value: string): bool =
  ## `_attrParseStops`.
  if key == "offset": ctx.parser.gradStop.offset = toOffset(value)
  elif key == "stop-opacity":
    if SvgStopStyleFlag.StopOpacity notin ctx.parser.flags:
      ctx.parser.gradStop.a = uint8(toOpacity(value) and 0xff)
  elif key == "stop-color":
    if value == "currentColor": stopCurrentColor(ctx)
    elif SvgStopStyleFlag.StopColor notin ctx.parser.flags: discard setStopColor(ctx, value)
  elif key == "style":
    discard xmlParseW3CAttribute(value, proc(k, v: string): bool = parseStopStyle(ctx, k, v))
  else: return false
  true

proc inheritGradient(ctx: SvgParserContext, dst, src: SvgStyleGradient) =
  ## `_inheritGradient`: fills what `dst` did not set from the gradient it refers to.
  if dst == nil or src == nil: return
  if SvgGradientFlag.SpreadMethod notin dst.flags and SvgGradientFlag.SpreadMethod in src.flags:
    dst.spread = src.spread
    dst.flags.incl SvgGradientFlag.SpreadMethod
  let gradUnitSet = SvgGradientFlag.GradientUnits in dst.flags
  if not gradUnitSet and SvgGradientFlag.GradientUnits in src.flags:
    dst.userSpace = src.userSpace
    dst.flags.incl SvgGradientFlag.GradientUnits
  if dst.transform.isNone and src.transform.isSome: dst.transform = src.transform

  for i in 0 ..< coordCount(dst.kind):
    let flag = coordFlag(dst.kind, i)
    let coordSet = flag in dst.flags
    if not coordSet and flag in src.flags:
      dst.coord[i] = src.coord[i]
      dst.isPercentage[i] = src.isPercentage[i]
      dst.flags.incl flag
    let radial = dst.kind == SvgGradientType.Radial
    # units not set directly, coordinate set
    if not gradUnitSet and coordSet:
      recalc(ctx, dst, i, dst.userSpace)
      # without fx/fy the focal point follows the center
      if radial and i == ord(gcCx) and SvgGradientFlag.Fx notin dst.flags:
        dst.coord[ord(gcFx)] = dst.coord[ord(gcCx)]
      if radial and i == ord(gcCy) and SvgGradientFlag.Fy notin dst.flags:
        dst.coord[ord(gcFy)] = dst.coord[ord(gcCy)]
    # units set, coordinate not set directly
    if dst.userSpace == src.userSpace: continue
    if gradUnitSet and not coordSet:
      if radial and i == ord(gcFx) and SvgGradientFlag.Fx notin dst.flags: continue
      if radial and i == ord(gcFy) and SvgGradientFlag.Fy notin dst.flags: continue
      recalcInherited(ctx, dst, i, dst.userSpace)
  if dst.stops.len == 0: dst.stops = src.stops

func cloneGradient(src: SvgStyleGradient): SvgStyleGradient =
  if src == nil: return nil
  SvgStyleGradient(id: src.id, refId: src.refId, kind: src.kind, coord: src.coord,
                   isPercentage: src.isPercentage, transform: src.transform, stops: src.stops,
                   flags: src.flags, spread: src.spread, userSpace: src.userSpace)

func resolveGradient(ctx: SvgParserContext, gradients: seq[SvgStyleGradient],
                     id: string): SvgStyleGradient =
  ## A private copy of the gradient `id`, completed from the gradient it refers to.
  for p in gradients:
    if p.id.len > 0 and p.id == id:
      result = cloneGradient(p)
      break
  if result != nil and result.refId.len > 0:
    for p in gradients:
      if p.id.len > 0 and p.id == result.refId:
        inheritGradient(ctx, result, p)
        break

proc updateGradient*(ctx: SvgParserContext, node: SvgNode, gradients: seq[SvgStyleGradient]) =
  ## `_updateGradient`: gives every leaf its fill/stroke gradient.
  if node.child.len > 0:
    for p in node.child: updateGradient(ctx, p, gradients)
    return
  if node.style.fill.paint.url.len > 0:
    let grad = resolveGradient(ctx, gradients, node.style.fill.paint.url)
    if grad != nil: node.style.fill.paint.gradient = grad
  if node.style.stroke.paint.url.len > 0:
    let grad = resolveGradient(ctx, gradients, node.style.stroke.paint.url)
    if grad != nil: node.style.stroke.paint.gradient = grad

{.pop.}
