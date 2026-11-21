## Stroke border helpers: float math, border point lists, arcs and export.
##
## Ported from the static helpers of `src/renderer/cpu_engine/tvgSwStroke.cpp`
## (`_borderClose`, `_borderCubicTo`, `_borderLineTo`, `_borderMoveTo`, `_borderArcTo`,
## `_exportBorderOutline`). Used only by `stroke.nim`.
## Differences: a border keeps `pts` and `tags` as parallel `seq`s (no manual growth),
## `std::remainderf` is emulated exactly through float64.

import std/math
import ../../core/[types, geom, path]
import ./common

const
  TagPoint* = 1'u8
  TagCubic* = 2'u8
  TagBegin* = 4'u8
  TagEnd* = 8'u8

{.push floatChecks: off.}

func sideToRotate*(s: int): float32 = MathPi2 - float32(s) * MathPi

func tiny*(pt: Point): bool =
  const Epsilon = 2.0'f32 / 64.0'f32
  abs(pt.x) < Epsilon and abs(pt.y) < Epsilon

func remainderf*(x, y: float32): float32 =
  ## IEEE remainder (`x - n*y`, n = x/y rounded to even); NaN for non finite `x` or zero `y`.
  if classify(x) in {fcNan, fcInf, fcNegInf} or y == 0.0'f32:
    return float32(NaN)
  let xd = float64(x)
  let yd = float64(y)
  let q = xd / yd
  var n = floor(q)
  let d = q - n
  if d > 0.5 or (d == 0.5 and n mod 2.0 != 0.0): n += 1.0
  float32(xd - n * yd)

func mean*(angle1, angle2: float32): float32 =
  angle1 + remainderf(angle2 - angle1, Math2Pi) * 0.5'f32

func rotate*(pt: var Point, radian: float32) =
  if zero(radian): return
  let cosv = cos(radian)
  let sinv = sin(radian)
  pt = Point(x: pt.x * cosv - pt.y * sinv, y: pt.x * sinv + pt.y * cosv)

func newBorder*(): SwStrokeBorder = SwStrokeBorder(start: -1)

func resetBorder*(b: SwStrokeBorder) =
  b.pts.setLen(0)
  b.tags.setLen(0)
  b.start = -1
  b.movable = false

func push(b: SwStrokeBorder, pt: Point, tag: uint8) =
  b.pts.add pt
  b.tags.add tag

func truncate(b: SwStrokeBorder, count: int) =
  b.pts.setLen(count)
  b.tags.setLen(count)

func reverseRange[T](a: var seq[T], first, last: int) =
  var i = first
  var j = last
  while i < j:
    swap(a[i], a[j])
    inc i
    dec j

func borderClose*(b: SwStrokeBorder, reverse: bool) =
  let start = int(b.start)
  var count = b.pts.len

  #Don't record empty paths!
  if count <= start + 1:
    b.truncate(start)
  else:
    # Copy the last point to the start of this sub-path,
    # since it contains the adjusted starting coordinates
    dec count
    let last = b.pts[count]
    b.truncate(count)
    b.pts[start] = last
    if reverse:
      b.pts.reverseRange(start + 1, count - 1)
      b.tags.reverseRange(start + 1, count - 1)
    b.tags[start] = b.tags[start] or TagBegin
    b.tags[count - 1] = b.tags[count - 1] or TagEnd
  b.start = -1
  b.movable = false

func borderCubicTo*(b: SwStrokeBorder, ctrl1, ctrl2, to: Point) =
  b.push(ctrl1, TagCubic)
  b.push(ctrl2, TagCubic)
  b.push(to, TagPoint)
  b.movable = false

func borderLineTo*(b: SwStrokeBorder, to: Point, movable: bool) =
  if b.movable:
    b.pts[^1] = to  # move last point
    b.movable = movable
  elif b.pts.len > 0 and tiny(b.pts[^1] - to):
    discard  # don't add zero-length line_to
  else:
    b.push(to, TagPoint)
    b.movable = movable

func borderMoveTo*(b: SwStrokeBorder, to: Point) =
  if b.start >= 0: b.borderClose(false)  # close current open path if any
  b.start = int32(b.pts.len)
  b.movable = false
  b.borderLineTo(to, false)

func borderArcTo*(stroke: SwStroke, side: int) =
  let border = stroke.borders[side]
  var rotate = sideToRotate(side)
  let angleStart = stroke.angleIn + rotate
  var angleDiff = remainderf(stroke.angleOut - stroke.angleIn, Math2Pi)
  if classify(angleDiff) in {fcNan, fcInf, fcNegInf}: return
  if equal(angleDiff, MathPi): angleDiff = -rotate * 2.0'f32

  var a = Point(x: stroke.width, y: 0.0'f32)
  a.rotate(angleStart)
  a += stroke.center

  var total = angleDiff
  var angle = angleStart
  rotate = if angleDiff >= 0: MathPi2 else: -MathPi2

  while not zero(total):
    var step = total
    if step > MathPi2: step = MathPi2
    elif step < -MathPi2: step = -MathPi2

    let next = angle + step
    let theta = abs(step) * 0.5'f32

    # compute end point
    var b = Point(x: stroke.width, y: 0.0'f32)
    b.rotate(next)
    b += stroke.center

    # compute first and second control points
    let length = stroke.width * (4.0'f32 / 3.0'f32) * tan(theta * 0.5'f32)
    var a2 = Point(x: length, y: 0.0'f32)
    a2.rotate(angle + rotate)
    a2 += a
    var b2 = Point(x: length, y: 0.0'f32)
    b2.rotate(next - rotate)
    b2 += b

    border.borderCubicTo(a2, b2, b)  # add cubic arc

    a = b  # process the rest of the arc?
    total -= step
    angle = next

  border.movable = false

func exportBorderOutline*(border: SwStrokeBorder, path: var RenderPath) =
  var start = Point()
  var i = 0
  while i < border.pts.len:
    let tag = border.tags[i]
    if (tag and TagBegin) != 0:
      start = border.pts[i]
      path.moveTo(start)
    elif (tag and TagCubic) != 0:
      # borderClose() moved the last point to the start of the sub-path, so a closing
      # cubic keeps only its two controls and ends at the start point.
      if (border.tags[i + 1] and TagEnd) != 0:
        path.cubicTo(border.pts[i], border.pts[i + 1], start)
        i += 1
      else:
        path.cubicTo(border.pts[i], border.pts[i + 1], border.pts[i + 2])
        i += 2
    else:
      path.lineTo(border.pts[i])
    if (border.tags[i] and TagEnd) != 0: path.close()
    inc i

{.pop.}
