## Stroker: turns an outline into the two borders of its stroke and exports them.
##
## Ported from `src/renderer/cpu_engine/tvgSwStroke.cpp` (the FreeType-style stroker,
## float version of ThorVG 1.2).
## API: `strokeReset(stroke, rshape, transform)`, `strokeParseOutline(stroke, outline)`
## (reads `outline.cmds` + `outline.fpts`, false on a path starting with a cubic) and
## `strokeExportOutline(stroke)` (returns an outline with `cmds` + `fpts`; `pts` stays empty
## until `utilExport` converts it). Border helpers live in `strokeborder.nim`.
## `std::remainderf` and the NaN guards need `floatChecks: off` (DECISIONS H2).

import std/[math, options]
import ../../core/[types, geom, path]
import ../../renderer/render
import ./[common, strokeborder]

{.push floatChecks: off.}

proc outside(stroke: SwStroke, side: int, length: float32) =
  let border = stroke.borders[side]
  if stroke.join == StrokeJoin.Round:
    stroke.borderArcTo(side)
    return
  # this is a mitered (pointed) or beveled (truncated) corner
  let rotate = sideToRotate(side)
  var bevel = stroke.join == StrokeJoin.Bevel
  var phi = 0.0'f32
  var thcos = 0.0'f32

  if not bevel:
    var theta = remainderf(stroke.angleOut - stroke.angleIn, Math2Pi)
    if equal(theta, MathPi):
      theta = rotate
      phi = stroke.angleIn
    else:
      theta *= 0.5'f32
      phi = stroke.angleIn + theta + rotate
    thcos = cos(theta)
    if stroke.miterlimit * thcos < 1.0'f32: bevel = true  # is miter limit exceeded?

  if bevel:  # this is a bevel (broken angle)
    var delta = Point(x: stroke.width, y: 0.0'f32)
    delta.rotate(stroke.angleOut + rotate)
    delta += stroke.center
    border.movable = false
    border.borderLineTo(delta, false)
  else:  # this is a miter (intersection)
    var delta = Point(x: stroke.width / thcos, y: 0.0'f32)
    delta.rotate(phi)
    delta += stroke.center
    border.borderLineTo(delta, false)
    # Now add and end point. Only needed if not lineto (lineLength is zero for curves)
    if zero(length):
      delta = Point(x: stroke.width, y: 0.0'f32)
      delta.rotate(stroke.angleOut + rotate)
      delta += stroke.center
      border.borderLineTo(delta, false)

proc inside(stroke: SwStroke, side: int, length: float32) =
  let border = stroke.borders[side]
  let theta = remainderf(stroke.angleOut - stroke.angleIn, Math2Pi) * 0.5'f32
  var intersect = false

  # Only intersect borders if between two line_to's and both
  # lines are long enough (line length is zero for curves).
  if border.movable and length > 0.0'f32:
    let minLength = abs(stroke.width * tan(theta))  # minimum required length of lines
    if stroke.length >= minLength and length >= minLength: intersect = true

  let rotate = sideToRotate(side)
  var delta: Point
  if not intersect:
    delta = Point(x: stroke.width, y: 0.0'f32)
    delta.rotate(stroke.angleOut + rotate)
    delta += stroke.center
    border.movable = false
  else:
    let phi = stroke.angleIn + theta  # median angle
    let thcos = cos(theta)
    delta = Point(x: stroke.width / thcos, y: 0.0'f32)
    delta.rotate(phi + rotate)
    delta += stroke.center
  border.borderLineTo(delta, false)

proc processCorner(stroke: SwStroke, length: float32) =
  let turn = remainderf(stroke.angleOut - stroke.angleIn, Math2Pi)
  # no specific corner processing is required if the turn is 0
  if not zero(turn):
    # when we turn to the right, the inside side is 0 otherwise, the inside is 1
    let inside = if turn < 0.0'f32: 1 else: 0
    stroke.inside(inside, length)
    stroke.outside(1 - inside, length)

proc firstSubPath(stroke: SwStroke, startAngle, length: float32) =
  var delta = Point(x: stroke.width, y: 0.0'f32)
  delta.rotate(startAngle + MathPi2)
  stroke.borders[0].borderMoveTo(stroke.center + delta)
  stroke.borders[1].borderMoveTo(stroke.center - delta)
  # Save angle, position and line length for last join (lineLength is zero for curves)
  stroke.subPathAngle = startAngle
  stroke.firstPt = false
  stroke.subPathLength = length

proc lineTo(stroke: SwStroke, to: Point) =
  var delta = to - stroke.center

  # a zero-length lineto is a no-op
  if zero(delta):
    # round and square caps are expected to be drawn as a dot even for zero-length lines
    if stroke.firstPt and stroke.cap != StrokeCap.Butt: stroke.firstSubPath(0.0'f32, 0.0'f32)
    return

  let length = length(delta)
  let angle = atan(delta)
  delta = Point(x: stroke.width, y: 0.0'f32)
  delta.rotate(angle + MathPi2)

  if stroke.firstPt:
    # first segment of a subpath: add a point to each border at its starting location
    stroke.firstSubPath(angle, length)
  else:
    stroke.angleOut = angle  # process the current corner
    stroke.processCorner(length)

  # now add a line segment to both the inside and outside paths
  for side in 0 ..< 2:
    stroke.borders[side].borderLineTo(to + delta, true)  # the ends of lineto borders are movable
    delta = Point(x: -delta.x, y: -delta.y)

  stroke.angleIn = angle
  stroke.center = to
  stroke.length = length

proc cubicAngle(base: openArray[Point], off: int, angleIn, angleMid, angleOut: var float32): int =
  ## -1: ignorable, 0: small enough to add directly, 1: needs splitting.
  let d1 = base[off + 2] - base[off + 3]
  let d2 = base[off + 1] - base[off + 2]
  let d3 = base[off] - base[off + 1]

  if tiny(d1):
    if tiny(d2):
      if tiny(d3):
        angleIn = 0.0'f32
        angleMid = 0.0'f32
        angleOut = 0.0'f32
        return -1
      angleIn = atan(d3)
      angleMid = angleIn
      angleOut = angleIn
    elif tiny(d3):
      angleIn = atan(d2)
      angleMid = angleIn
      angleOut = angleIn
    else:
      angleIn = atan(d2)
      angleMid = angleIn
      angleOut = atan(d3)
  elif tiny(d2):
    if tiny(d3):
      angleIn = atan(d1)
      angleMid = angleIn
      angleOut = angleIn
    else:
      angleIn = atan(d1)
      angleOut = atan(d3)
      angleMid = mean(angleIn, angleOut)
  elif tiny(d3):
    angleIn = atan(d1)
    angleMid = atan(d2)
    angleOut = angleMid
  else:
    angleIn = atan(d1)
    angleMid = atan(d2)
    angleOut = atan(d3)

  let theta1 = abs(remainderf(angleMid - angleIn, Math2Pi))
  let theta2 = abs(remainderf(angleOut - angleMid, Math2Pi))
  if theta1 < MathPi / 8.0'f32 and theta2 < MathPi / 8.0'f32: 0 else: 1

proc splitCubic(base: var openArray[Point], off: int) =
  let p01 = (base[off] + base[off + 1]) * 0.5'f32
  let p12 = (base[off + 1] + base[off + 2]) * 0.5'f32
  let p23 = (base[off + 2] + base[off + 3]) * 0.5'f32
  let p012 = (p01 + p12) * 0.5'f32
  let p123 = (p12 + p23) * 0.5'f32
  let mid = (p012 + p123) * 0.5'f32
  base[off + 6] = base[off + 3]
  base[off + 1] = p01
  base[off + 2] = p012
  base[off + 3] = mid
  base[off + 4] = p123
  base[off + 5] = p23

proc wideBorderCubic(border: SwStrokeBorder, arc: openArray[Point], off: int,
                     c1, c2, endPt: Point, alpha0: float32): bool =
  ## Handles a border radius greater than the radius of curvature of the original arc.
  ## True if the border was fully emitted here.
  let start = border.pts[^1]
  let alpha1 = atan(endPt - start)
  # is the direction of the border arc opposite to that of the original arc?
  if not (abs(remainderf(alpha1 - alpha0, Math2Pi)) > MathPi2): return false
  # use the sine rule to find the intersection point
  let beta = atan(arc[off + 3] - start)
  let gamma = atan(arc[off] - endPt)
  let blen = length(endPt - start)
  let sinA = abs(sin(alpha1 - gamma))
  let sinB = abs(sin(beta - gamma))
  let alen = (blen * sinA) / sinB
  var delta = Point(x: alen, y: 0.0'f32)
  delta.rotate(beta)
  delta += start
  # circumnavigate the negative sector backwards
  border.movable = false
  border.borderLineTo(delta, false)
  border.borderLineTo(endPt, false)
  border.borderCubicTo(c2, c1, start)
  border.borderLineTo(endPt, false)  # and then move to the endpoint
  true

proc cubicTo(stroke: SwStroke, ctrl1, ctrl2, to: Point) =
  var bezStack: array[37, Point]
  const Limit = 32
  var arc = 0
  var firstArc = true
  bezStack[0] = to
  bezStack[1] = ctrl2
  bezStack[2] = ctrl1
  bezStack[3] = stroke.center
  let join = stroke.join  # backup

  while arc >= 0:
    # initialize with current direction
    var angleIn = stroke.angleIn
    var angleOut = angleIn
    var angleMid = angleIn
    let valid = cubicAngle(bezStack, arc, angleIn, angleMid, angleOut)

    if valid > 0 and arc < Limit:  # valid size: split
      if stroke.firstPt: stroke.angleIn = angleIn
      splitCubic(bezStack, arc)
      arc += 3
    elif valid < 0 and arc == 0:  # ignorable size
      stroke.center = to
      # round and square caps are expected to be drawn as a dot even for zero-length lines
      if stroke.firstPt and stroke.cap != StrokeCap.Butt: stroke.firstSubPath(0.0'f32, 0.0'f32)
      return
    else:  # small size
      if firstArc:
        firstArc = false
        if stroke.firstPt:  # process corner if necessary
          stroke.firstSubPath(angleIn, 0.0'f32)
        else:
          stroke.angleOut = angleIn
          stroke.processCorner(0.0'f32)
      elif abs(remainderf(angleIn - stroke.angleIn, Math2Pi)) > (MathPi / 8.0'f32) / 4.0'f32:
        # if the deviation from one arc to the next is too great add a round corner
        stroke.center = bezStack[arc + 3]
        stroke.angleOut = angleIn
        stroke.join = StrokeJoin.Round
        stroke.processCorner(0.0'f32)
        stroke.join = join  # reinstate line join style

      # the arc's angle is small enough; we can add it directly to each border
      let theta1 = remainderf(angleMid - angleIn, Math2Pi) * 0.5'f32
      let theta2 = remainderf(angleOut - angleMid, Math2Pi) * 0.5'f32
      let phi1 = mean(angleIn, angleMid)
      let phi2 = mean(angleMid, angleOut)
      let length1 = stroke.width / cos(theta1)
      let length2 = stroke.width / cos(theta2)
      var alpha0 = 0.0'f32

      # compute direction of original arc
      if stroke.handleWideStrokes: alpha0 = atan(bezStack[arc] - bezStack[arc + 3])

      for side in 0 ..< 2:
        let border = stroke.borders[side]
        let rotate = sideToRotate(side)

        # compute bezier points
        var c1 = Point(x: length1, y: 0.0'f32)
        c1.rotate(phi1 + rotate)
        c1 += bezStack[arc + 2]
        var c2 = Point(x: length2, y: 0.0'f32)
        c2.rotate(phi2 + rotate)
        c2 += bezStack[arc + 1]
        var endPt = Point(x: stroke.width, y: 0.0'f32)
        endPt.rotate(angleOut + rotate)
        endPt += bezStack[arc]

        let wide = stroke.handleWideStrokes and
                   border.wideBorderCubic(bezStack, arc, c1, c2, endPt, alpha0)
        if not wide: border.borderCubicTo(c1, c2, endPt)
      arc -= 3
      stroke.angleIn = angleOut
  stroke.center = to

proc addCap(stroke: SwStroke, angle: float32, side: int) =
  let rotate = sideToRotate(side)
  let border = stroke.borders[side]
  var delta = Point(x: stroke.width, y: 0.0'f32)

  if stroke.cap == StrokeCap.Square:
    delta.rotate(angle)
    var delta2 = Point(x: stroke.width, y: 0.0'f32)
    delta2.rotate(angle + rotate)
    delta = delta + (stroke.center + delta2)
    border.borderLineTo(delta, false)

    delta = Point(x: stroke.width, y: 0.0'f32)
    delta.rotate(angle)
    delta2 = Point(x: stroke.width, y: 0.0'f32)
    delta2.rotate(angle - rotate)
    delta = delta + (delta2 + stroke.center)
    border.borderLineTo(delta, false)
  elif stroke.cap == StrokeCap.Round:
    stroke.angleIn = angle
    stroke.angleOut = angle + MathPi
    stroke.borderArcTo(side)
  else:  # Butt
    delta.rotate(angle + rotate)
    delta += stroke.center
    border.borderLineTo(delta, false)

    delta = Point(x: stroke.width, y: 0.0'f32)
    delta.rotate(angle - rotate)
    delta += stroke.center
    border.borderLineTo(delta, false)

proc addReverseLeft(stroke: SwStroke, opened: bool) =
  let right = stroke.borders[0]
  let left = stroke.borders[1]
  if left.pts.len - int(left.start) <= 0: return

  var i = left.pts.len - 1
  while i >= int(left.start):
    right.pts.add left.pts[i]
    var tag = left.tags[i]
    if opened:
      tag = tag and not (TagBegin or TagEnd)
    else:
      # switch begin/end tags if necessary
      let ttag = tag and (TagBegin or TagEnd)
      if ttag == TagBegin or ttag == TagEnd: tag = tag xor (TagBegin or TagEnd)
    right.tags.add tag
    dec i

  left.pts.setLen(int(left.start))
  left.tags.setLen(int(left.start))
  right.movable = false
  left.movable = false

proc beginSubPath(stroke: SwStroke, to: Point, closed: bool) =
  # We cannot process the first point because there is not enough information
  # regarding its corner/cap. Later, it will be processed in endSubPath()
  stroke.firstPt = true
  stroke.center = to
  stroke.closedSubPath = closed

  # Determine if we need to check whether the border radius is greater than the radius of
  # curvature of a curve. This is only required if bevel joins or butt caps may be created
  # because round & miter joins and round & square caps cover the negative sector.
  stroke.handleWideStrokes = stroke.join != StrokeJoin.Round or
                             (not stroke.closedSubPath and stroke.cap == StrokeCap.Butt)
  stroke.subPathStart = to
  stroke.angleIn = 0.0'f32

proc endSubPath(stroke: SwStroke) =
  let right = stroke.borders[0]
  let left = stroke.borders[1]

  # A closed subpath without any length leaves only the start point on each border.
  # Stroke it like a zero-length open line, so round/square caps still draw a dot.
  let zeroLength = right.pts.len == int(right.start) + 1 and left.pts.len == int(left.start) + 1

  if stroke.closedSubPath and not zeroLength:
    # close the path if needed
    if not (stroke.center == stroke.subPathStart): stroke.lineTo(stroke.subPathStart)

    # process the corner
    stroke.angleOut = stroke.subPathAngle
    let turn = remainderf(stroke.angleOut - stroke.angleIn, Math2Pi)

    # No specific corner processing is required if the turn is 0
    if not zero(turn):
      let inside = if turn < 0: 1 else: 0  # when we turn to the right, the inside is 0
      stroke.inside(inside, stroke.subPathLength)
      stroke.outside(1 - inside, stroke.subPathLength)
    right.borderClose(false)
    left.borderClose(true)
  else:
    # an opened path: add a cap between right & left, add the reverse of left,
    # then add a final cap between left & right
    stroke.addCap(stroke.angleIn, 0)
    stroke.addReverseLeft(true)  # add reversed points from 'left' to 'right'
    stroke.center = stroke.subPathStart
    stroke.addCap(stroke.subPathAngle + MathPi, 0)  # the final cap
    right.borderClose(false)  # the left one is rewind and doesn't need further processing

# ---------------------------------------------------------------- public API

proc strokeReset*(stroke: SwStroke, rshape: RenderShape, transform: Matrix) =
  ## Takes width, cap, miter limit and join from `rshape` and clears both borders.
  let rs = if rshape.stroke.isSome: rshape.stroke.get else: initStroke()
  stroke.width = rs.width * 0.5'f32
  stroke.cap = rs.cap
  stroke.miterlimit = rs.miterlimit
  stroke.join = rs.join
  for side in 0 ..< 2:
    if stroke.borders[side] == nil: stroke.borders[side] = newBorder()
    else: stroke.borders[side].resetBorder()

proc strokeParseOutline*(stroke: SwStroke, outline: SwOutline): bool =
  ## Builds the borders of the outline; false if a contour starts with a cubic.
  let cmds {.cursor.} = outline.cmds
  let pts {.cursor.} = outline.fpts
  var ci = 0
  var pi = 0
  var start = Point()

  while ci < cmds.len:
    if cmds[ci] == PathCommand.Close:
      inc ci
    else:
      # Treat an initial LineTo as MoveTo when no points have been consumed yet.
      if cmds[ci] == PathCommand.MoveTo or pi == 0:
        # A contour cannot start with a cubic control point
        if cmds[ci] == PathCommand.CubicTo: return false
        start = pts[pi]
        inc pi
        inc ci

      # Find the subpath end and determine whether it is closed before beginning it.
      var last = ci
      while last < cmds.len and cmds[last] != PathCommand.MoveTo and
          cmds[last] != PathCommand.Close:
        inc last
      let closed = last < cmds.len and cmds[last] == PathCommand.Close
      stroke.beginSubPath(start, closed)

      while ci < last:
        if cmds[ci] == PathCommand.LineTo:
          stroke.lineTo(pts[pi])
          inc pi
        else:
          stroke.cubicTo(pts[pi], pts[pi + 1], pts[pi + 2])
          pi += 3
        inc ci
      if closed: stroke.lineTo(start)
      if not stroke.firstPt: stroke.endSubPath()
  true

proc strokeExportOutline*(stroke: SwStroke): SwOutline =
  ## Exports the right then left border as one non-zero outline (float points only).
  var p: RenderPath
  stroke.borders[0].exportBorderOutline(p)
  stroke.borders[1].exportBorderOutline(p)
  SwOutline(cmds: p.cmds, fpts: p.pts, fillRule: FillRule.NonZero)

{.pop.}
