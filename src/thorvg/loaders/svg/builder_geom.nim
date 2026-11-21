## SVG scene builder, part 1: shared context, boxes and matrices, shape recognition and
## gradient fills.
##
## Ported from the first half of `modules/svg/tvgSvgBuilder.cpp`. The builder modules call
## each other recursively in the original; here the recursion goes through the two
## callbacks of `BuildCtx` (`sceneBuild`, `patternChild`), which `builder.nim` sets, so
## the modules form a plain dependency chain
## (`builder_geom` <- `builder_comp` <- `builder_image` / `builder_text` /
## `builder_pattern` <- `builder`).
##
## Differences with C++: paint ownership (`Paint::rel`, the image buffers kept in the
## context, the accessor list) is gone; `_bounds` of a paint without bounds is the empty
## box at the origin (C++ leaves it uninitialized).

import std/[math, options]
import ../../core/[types, geom, fill]
import ../../renderer/[paint, shape, scene]
import ./[nodes, pathdata]

type
  SceneBuilder* = proc (ctx: BuildCtx, node: SvgNode, vBox: Box, mask: bool,
                        depth: int): Scene {.nimcall.}
  PatternChildBuilder* = proc (ctx: BuildCtx, node: SvgNode, vBox: Box): Paint {.nimcall.}

  BuildCtx* = ref object
    global*: Box ## the parser's percentage reference box
    svgPath*: string ## directory (with the trailing separator) of the svg file
    sceneBuild*: SceneBuilder
    patternChild*: PatternChildBuilder

export scene

func affine*(a, b, c, d, e, f: float32): Matrix =
  ## `{a, b, c, d, e, f, 0, 0, 1}` in the row order of the original matrix literal.
  Matrix(e11: a, e12: b, e13: c, e21: d, e22: e, e23: f, e33: 1.0'f32)

proc boxOf*(p: Paint): Box =
  ## `_bounds`: the stroke-less bounds of a paint (zeros when it has none).
  var x, y, w, h: float32
  discard p.bounds(x, y, w, h)
  Box(x: x, y: y, w: w, h: h)

func objectBoundingBox*(ratio, bounds: Box): Box =
  Box(x: bounds.x + ratio.x * bounds.w, y: bounds.y + ratio.y * bounds.h,
      w: ratio.w * bounds.w, h: ratio.h * bounds.h)

func validBox*(b: Box): bool = b.w > 0.0'f32 and b.h > 0.0'f32

func isGroupType*(kind: SvgNodeType): bool =
  kind in {SvgNodeType.Doc, SvgNodeType.G, SvgNodeType.Use, SvgNodeType.ClipPath,
           SvgNodeType.Symbol, SvgNodeType.Filter}

func useTransform*(node: SvgNode): Matrix =
  result = identity()
  if node.transform.isSome: result = node.transform.get
  if node.use.x != 0.0'f32 or node.use.y != 0.0'f32:
    result = result * affine(1, 0, node.use.x, 0, 1, node.use.y)

# ---- aspect ratio and symbols ------------------------------------------------

func aspectRatioMatrix*(align: AspectRatioAlign, meetOrSlice: AspectRatioMeetOrSlice,
                        width, height: float32, box: Box): Matrix =
  var sx = width / box.w
  var sy = height / box.h
  var tvx = box.x * sx
  var tvy = box.y * sy
  if align == AspectRatioAlign.None: return affine(sx, 0, -tvx, 0, sy, -tvy)
  if meetOrSlice == AspectRatioMeetOrSlice.Meet:
    if sx < sy: sy = sx else: sx = sy
  else:
    if sx < sy: sx = sy else: sy = sx
  tvx = box.x * sx
  tvy = box.y * sy
  let tvw = box.w * sx
  let tvh = box.h * sy
  case align
  of AspectRatioAlign.XMidYMin: tvx -= (width - tvw) * 0.5'f32
  of AspectRatioAlign.XMaxYMin: tvx -= width - tvw
  of AspectRatioAlign.XMinYMid: tvy -= (height - tvh) * 0.5'f32
  of AspectRatioAlign.XMidYMid:
    tvx -= (width - tvw) * 0.5'f32
    tvy -= (height - tvh) * 0.5'f32
  of AspectRatioAlign.XMaxYMid:
    tvx -= width - tvw
    tvy -= (height - tvh) * 0.5'f32
  of AspectRatioAlign.XMinYMax: tvy -= height - tvh
  of AspectRatioAlign.XMidYMax:
    tvx -= (width - tvw) * 0.5'f32
    tvy -= height - tvh
  of AspectRatioAlign.XMaxYMax:
    tvx -= width - tvw
    tvy -= height - tvh
  else: discard
  affine(sx, 0, -tvx, 0, sy, -tvy)

func symbolSize*(node: SvgNode, vBox: Box): (float32, float32) =
  ## Width and height of the viewport a `use` gives to its symbol.
  let symbol = node.use.symbol.symbol
  var width = if symbol.hasWidth: symbol.w else: vBox.w
  if node.use.isWidthSet: width = node.use.w
  var height = if symbol.hasHeight: symbol.h else: vBox.h
  if node.use.isHeightSet: height = node.use.h
  (width, height)

func symbolTransform*(node: SvgNode, vBox: Box): Matrix =
  let symbolNode = node.use.symbol
  let symbol = symbolNode.symbol
  let (width, height) = symbolSize(node, vBox)
  let vw = if symbol.hasViewBox: symbol.vw else: width
  let vh = if symbol.hasViewBox: symbol.vh else: height
  var mViewBox = identity()
  if (not equal(width, vw) or not equal(height, vh)) and vw > 0.0'f32 and vh > 0.0'f32:
    mViewBox = aspectRatioMatrix(symbol.align, symbol.meetOrSlice, width, height,
                                 Box(x: symbol.vx, y: symbol.vy, w: vw, h: vh))
  elif not zero(symbol.vx) or not zero(symbol.vy):
    mViewBox = affine(1, 0, -symbol.vx, 0, 1, -symbol.vy)
  var sceneTransform = mViewBox
  if symbolNode.transform.isSome: sceneTransform = symbolNode.transform.get * mViewBox
  useTransform(node) * sceneTransform

# ---- shapes -------------------------------------------------------------------

proc appendRect(shape: Shape, x, y, w, h: float32, rx, ry: float32) =
  var rx = rx
  var ry = ry
  let halfW = w * 0.5'f32
  let halfH = h * 0.5'f32
  if rx > halfW: rx = halfW
  if ry > halfH: ry = halfH
  if rx == 0.0'f32 and ry == 0.0'f32:
    discard shape.moveTo(x, y)
    discard shape.lineTo(x + w, y)
    discard shape.lineTo(x + w, y + h)
    discard shape.lineTo(x, y + h)
    discard shape.close()
    return
  let hrx = rx * PathKappa
  let hry = ry * PathKappa
  discard shape.moveTo(x + rx, y)
  discard shape.lineTo(x + w - rx, y)
  discard shape.cubicTo(x + w - rx + hrx, y, x + w, y + ry - hry, x + w, y + ry)
  discard shape.lineTo(x + w, y + h - ry)
  discard shape.cubicTo(x + w, y + h - ry + hry, x + w - rx + hrx, y + h, x + w - rx, y + h)
  discard shape.lineTo(x + rx, y + h)
  discard shape.cubicTo(x + rx - hrx, y + h, x, y + h - ry + hry, x, y + h - ry)
  discard shape.lineTo(x, y + ry)
  discard shape.cubicTo(x, y + ry - hry, x + rx - hrx, y, x + rx, y)
  discard shape.close()

proc appendCircle(shape: Shape, cx, cy, rx, ry: float32) =
  var rx = rx
  var ry = ry
  # unspecified or invalid radii come from the other axis (SVG 2)
  if rx < 0.0'f32: rx = ry
  elif ry < 0.0'f32: ry = rx
  if rx <= 0.0'f32 or ry <= 0.0'f32: return
  let rxK = rx * PathKappa
  let ryK = ry * PathKappa
  discard shape.moveTo(cx + rx, cy)
  discard shape.cubicTo(cx + rx, cy + ryK, cx + rxK, cy + ry, cx, cy + ry)
  discard shape.cubicTo(cx - rxK, cy + ry, cx - rx, cy + ryK, cx - rx, cy)
  discard shape.cubicTo(cx - rx, cy - ryK, cx - rxK, cy - ry, cx, cy - ry)
  discard shape.cubicTo(cx + rxK, cy - ry, cx + rx, cy - ryK, cx + rx, cy)
  discard shape.close()

proc appendPoints(shape: Shape, pts: seq[float32], closed: bool) =
  if pts.len < 2: return
  discard shape.moveTo(pts[0], pts[1])
  var i = 2
  while i + 1 < pts.len:
    discard shape.lineTo(pts[i], pts[i + 1])
    i += 2
  if closed: discard shape.close()

proc recognizeShape*(node: SvgNode, shape: Shape): bool =
  ## `_recognizeShape`: false for a node that is not a shape or has an invalid path.
  case node.kind
  of SvgNodeType.Path:
    if node.path.len > 0 and not parsePath(node.path, shape.rs.path): return false
  of SvgNodeType.Ellipse:
    let e = node.ellipse
    appendCircle(shape, e.cx, e.cy, e.rx, e.ry)
  of SvgNodeType.Polygon: appendPoints(shape, node.polygon.pts, true)
  of SvgNodeType.Polyline: appendPoints(shape, node.polygon.pts, false)
  of SvgNodeType.Circle:
    appendCircle(shape, node.circle.cx, node.circle.cy, node.circle.r, node.circle.r)
  of SvgNodeType.Rect:
    let r = node.rect
    appendRect(shape, r.x, r.y, r.w, r.h, r.rx, r.ry)
  of SvgNodeType.Line:
    discard shape.moveTo(node.line.x1, node.line.y1)
    discard shape.lineTo(node.line.x2, node.line.y2)
  else: return false
  true

proc appendClipShape*(node: SvgNode, shape: Shape, transform: Option[Matrix]): bool =
  ## `_appendClipShape`: adds the node's outline; the `transform` (or else the node's own
  ## transform) is applied directly to the new points.
  let first = shape.rs.path.pts.len
  if not recognizeShape(node, shape): return false
  let m = if transform.isSome: transform else: node.transform
  if m.isSome:
    for i in first ..< shape.rs.path.pts.len:
      shape.rs.path.pts[i] = shape.rs.path.pts[i] * m.get
  true

# ---- gradients ------------------------------------------------------------------

func transformMultiply(m: Matrix, grad: var Matrix) =
  grad.e13 = grad.e13 * m.e11 + m.e13
  grad.e12 *= m.e11
  grad.e11 *= m.e11
  grad.e23 = grad.e23 * m.e22 + m.e23
  grad.e22 *= m.e22
  grad.e21 *= m.e22

func lowByte*(v: int): uint8 =
  ## C `static_cast<uint8_t>(int)`: keeps the low 8 bits (odd opacities wrap).
  uint8(v and 0xff)

func wrapInt32(v: int64): int =
  ## Wraps to the C `int` range, as 32-bit signed arithmetic does in practice.
  let u = v and 0xFFFFFFFF'i64
  if u >= 0x80000000'i64: int(u - 0x100000000'i64) else: int(u)

func gradientStops(g: SvgStyleGradient, opacity: int): seq[ColorStop] =
  var prev = 0.0'f32
  for cs in g.stops:
    var s = ColorStop(offset: cs.offset, r: cs.r, g: cs.g, b: cs.b,
                      a: lowByte(wrapInt32(int64(cs.a) * int64(opacity)) div 255))
    # offset corner cases: https://svgwg.org/svg2-draft/pservers.html#StopNotes
    if cs.offset < prev: s.offset = prev
    elif cs.offset > 1.0'f32: s.offset = 1.0'f32
    prev = s.offset
    result.add s

func finishGradient(f: var Fill, g: SvgStyleGradient, vBox: Box, opacity: int): bool =
  ## The part of the two gradient builders after the coordinates: transform, validity, stops.
  if g.transform.isSome: f.transform = g.transform.get
  if not g.userSpace:
    let m = affine(vBox.w, 0, vBox.x, 0, vBox.h, vBox.y)
    if g.transform.isSome: transformMultiply(m, f.transform)
    else: f.transform = m
  # a non-invertible gradient transform paints nothing
  let det = float64(f.transform.e11) * float64(f.transform.e22) -
            float64(f.transform.e12) * float64(f.transform.e21)
  if abs(det) <= 2.220446049250313e-16: return false
  f.spread = g.spread
  f.stops = gradientStops(g, opacity)
  true

func diagonal(w, h: float32): float32 = sqrt(w * w + h * h) / sqrt(2.0'f32)

func applyGradient*(g: SvgStyleGradient, vBox, viewport: Box, opacity: int): Option[Fill] =
  ## `_applyLinearGradientProperty` / `_applyRadialGradientProperty` (none = no paint).
  if g.stops.len == 0: return none(Fill)
  var f: Fill
  let c = g.coord
  let pc = g.isPercentage
  template ux(i: int): float32 = c[i] * (if pc[i]: vBox.w else: viewport.w)
  template uy(i: int): float32 = c[i] * (if pc[i]: vBox.h else: viewport.h)
  template ud(i: int): float32 =
    c[i] * (if pc[i]: diagonal(vBox.w, vBox.h) else: diagonal(viewport.w, viewport.h))
  if g.kind == SvgGradientType.Linear:
    let X1 = ord(LinearCoord.X1)
    let Y1 = ord(LinearCoord.Y1)
    let X2 = ord(LinearCoord.X2)
    let Y2 = ord(LinearCoord.Y2)
    f = if g.userSpace: linearGradient(ux(X1), uy(Y1), ux(X2), uy(Y2))
        else: linearGradient(c[X1], c[Y1], c[X2], c[Y2])
  else:
    let Cx = ord(RadialCoord.Cx)
    let Cy = ord(RadialCoord.Cy)
    let Fx = ord(RadialCoord.Fx)
    let Fy = ord(RadialCoord.Fy)
    let R = ord(RadialCoord.R)
    let Fr = ord(RadialCoord.Fr)
    f = if g.userSpace: radialGradient(ux(Cx), uy(Cy), ud(R), ux(Fx), uy(Fy), ud(Fr))
        else: radialGradient(c[Cx], c[Cy], c[R], c[Fx], c[Fy], c[Fr])
  if finishGradient(f, g, vBox, opacity): some(f) else: none(Fill)
