## Dashed stroke outlines: cuts a path into the "on" parts of a dash pattern.
##
## Ported from the `_dash*` / `_genDashOutline` functions of
## `src/renderer/cpu_engine/tvgSwShape.cpp`. The dash path is built in a fresh
## `RenderPath` (the C++ uses a pooled one) and returned as a float `SwOutline`.
## The C++ walks raw `cmds`/`pts` pointers; here `ci`/`pi` are indices.

import std/[math, options]
import ../../core/[types, geom, bezier, path]
import ../../renderer/[render, trim]
import ./common

const DashPatternThreshold* = 0.001'f32

type
  Line = object
    pt1, pt2: Point

  DashStroke = object
    path: RenderPath
    curLen: float32
    curIdx: int
    ptStart, ptCur: Point
    pattern: seq[float32]
    curOpGap, move: bool

func exactLength(l: Line): float32 =
  let dx = l.pt2.x - l.pt1.x
  let dy = l.pt2.y - l.pt1.y
  sqrt(dx * dx + dy * dy)

func split(l: Line, at: float32, left, right: var Line) =
  # a zero-length segment never gets here (len > curLen > 0); guard anyway (H2)
  let len = l.exactLength()
  let dx = if len == 0.0'f32: 0.0'f32 else: ((l.pt2.x - l.pt1.x) / len) * at
  let dy = if len == 0.0'f32: 0.0'f32 else: ((l.pt2.y - l.pt1.y) / len) * at
  left.pt1 = l.pt1
  left.pt2 = Point(x: left.pt1.x + dx, y: left.pt1.y + dy)
  right.pt1 = left.pt2
  right.pt2 = l.pt2

proc nextDash(dash: var DashStroke) =
  dash.curIdx = (dash.curIdx + 1) mod dash.pattern.len
  dash.curLen = dash.pattern[dash.curIdx]
  dash.curOpGap = not dash.curOpGap

proc drawPoint(dash: var DashStroke, start: Point) =
  if dash.move or dash.pattern[dash.curIdx] < FloatEpsilon:
    dash.path.moveTo(start)
    dash.move = false
  dash.path.lineTo(start)

proc dashLineTo(dash: var DashStroke, to: Point, validPoint: bool) =
  var cur = Line(pt1: dash.ptCur, pt2: to)
  var len = cur.exactLength()
  if zero(len):
    dash.ptCur = to
    return

  if len <= dash.curLen:
    dash.curLen -= len
    if not dash.curOpGap:
      if dash.move:
        dash.path.moveTo(dash.ptCur)
        dash.move = false
      dash.path.lineTo(to)
  else:
    # draw the current line partially
    while len - dash.curLen > DashPatternThreshold:
      var left, right: Line
      if dash.curLen > 0:
        len -= dash.curLen
        cur.split(dash.curLen, left, right)
        if not dash.curOpGap:
          if dash.move or dash.pattern[dash.curIdx] - dash.curLen < FloatEpsilon:
            dash.path.moveTo(left.pt1)
            dash.move = false
          dash.path.lineTo(left.pt2)
      else:
        if validPoint and not dash.curOpGap: dash.drawPoint(cur.pt1)
        right = cur
      dash.nextDash()
      cur = right
      dash.ptCur = cur.pt1
      dash.move = true
    # leftovers
    dash.curLen -= len
    if not dash.curOpGap:
      if dash.move:
        dash.path.moveTo(cur.pt1)
        dash.move = false
      dash.path.lineTo(cur.pt2)
    if dash.curLen < DashPatternThreshold and not zero(len):
      dash.nextDash()
      dash.move = true
  dash.ptCur = to

proc dashCubicTo(dash: var DashStroke, ctrl1, ctrl2, to: Point, validPoint: bool) =
  var cur = initBezier(dash.ptCur, ctrl1, ctrl2, to)
  var len = cur.length()
  if zero(len):
    dash.ptCur = to
    return

  if len <= dash.curLen:
    dash.curLen -= len
    if not dash.curOpGap:
      if dash.move:
        dash.path.moveTo(dash.ptCur)
        dash.move = false
      dash.path.cubicTo(ctrl1, ctrl2, to)
  else:
    var overflow = false
    while not overflow and (len - dash.curLen) > DashPatternThreshold:
      var left, right: Bezier
      if dash.curLen > 0:
        let remaining = len - dash.curLen
        if not (remaining < len):
          overflow = true         # C++: "Dash data overflow!" and break
        else:
          len = remaining
          cur.split(dash.curLen, left, right)
          if not dash.curOpGap:
            if dash.move or dash.pattern[dash.curIdx] - dash.curLen < FloatEpsilon:
              dash.path.moveTo(left.start)
              dash.move = false
            dash.path.cubicTo(left.ctrl1, left.ctrl2, left.`end`)
      else:
        if validPoint and not dash.curOpGap: dash.drawPoint(cur.start)
        right = cur
      if not overflow:
        dash.nextDash()
        cur = right
        dash.ptCur = right.start
        dash.move = true
    # leftovers
    dash.curLen -= len
    if not dash.curOpGap:
      if dash.move:
        dash.path.moveTo(cur.start)
        dash.move = false
      dash.path.cubicTo(cur.ctrl1, cur.ctrl2, cur.`end`)
    if dash.curLen < DashPatternThreshold and not zero(len):
      dash.nextDash()
      dash.move = true
  dash.ptCur = to

proc rotateTail[T](arr: var seq[T], from0, to0: int) =
  ## Moves `arr[from0 ..< to0]` behind the last element (rotation of `arr[from0..^1]`).
  let head = arr[from0 ..< to0]
  let tailStart = arr.len - head.len
  for i in from0 ..< tailStart: arr[i] = arr[i + head.len]
  for i, v in head: arr[tailStart + i] = v

proc dashClose(dash: var DashStroke, validPoint: bool, cmdBegin, ptBegin: int) =
  dash.dashLineTo(dash.ptStart, validPoint)
  # join the first and the last dashes across the seam only when both touch the start point
  if dash.path.cmds.len > cmdBegin + 1 and
      closed(dash.path.pts[ptBegin], dash.ptStart, DashPatternThreshold) and
      closed(dash.path.pts[^1], dash.ptStart, DashPatternThreshold):
    # locate the end of the first dash
    var cmdEnd = cmdBegin + 1
    var ptEnd = ptBegin + 1
    while cmdEnd < dash.path.cmds.len and dash.path.cmds[cmdEnd] != PathCommand.MoveTo:
      ptEnd += (if dash.path.cmds[cmdEnd] == PathCommand.CubicTo: 3 else: 1)
      inc cmdEnd
    # move the first dash behind the last to join them at the start point
    if cmdEnd < dash.path.cmds.len:
      dash.path.cmds[cmdBegin] = PathCommand.LineTo
      dash.path.pts.rotateTail(ptBegin, ptEnd)
      dash.path.cmds.rotateTail(cmdBegin, cmdEnd)
  # the next sub-path may continue without moveTo
  dash.move = true

proc dashMoveTo(dash: var DashStroke, offIdx: int, offset: float32, pt: Point) =
  dash.curIdx = offIdx mod dash.pattern.len
  dash.curLen = dash.pattern[dash.curIdx] - offset
  dash.curOpGap = offIdx mod 2 == 1
  dash.ptStart = pt
  dash.ptCur = pt
  dash.move = true

proc genDashOutline*(rshape: RenderShape, trimmed: bool): SwOutline =
  ## Outline (float points) of the dashes of `rshape.path`; nil if there is nothing
  ## to dash (no stroke, empty path or empty trim result).
  if rshape.stroke.isNone: return nil
  let rs = rshape.stroke.get
  var src: RenderPath
  if trimmed:
    if not rs.trim.trim(rshape.path, src): return nil
  else:
    src = rshape.path
  if src.cmds.len == 0 or src.empty: return nil

  var dash = DashStroke(pattern: rs.dash.pattern)
  let cnt = dash.pattern.len
  if cnt == 0: return nil
  var offset = rs.dash.offset

  var offIdx = 0
  if not zero(offset):
    var length = rs.dash.length
    let isOdd = cnt mod 2 == 1
    if isOdd: length *= 2
    offset = offset mod length
    if offset < 0: offset += length
    while offIdx < cnt * (if isOdd: 2 else: 1):
      let curPattern = dash.pattern[offIdx mod cnt]
      if offset < curPattern: break
      offset -= curPattern
      inc offIdx

  var cmdBegin = 0
  var ptBegin = 0
  var ci = 0
  var pi = 0
  # must begin with moveTo
  if src.cmds[0] == PathCommand.MoveTo:
    dash.dashMoveTo(offIdx, offset, src.pts[0])
    ci = 1
    pi = 1

  # zero length segment with non-butt cap still should be rendered as a point
  let validPoint = rs.cap != StrokeCap.Butt
  for _ in 1 ..< src.cmds.len:
    case src.cmds[ci]
    of PathCommand.Close:
      dash.dashClose(validPoint, cmdBegin, ptBegin)
      cmdBegin = dash.path.cmds.len
      ptBegin = dash.path.pts.len
    of PathCommand.MoveTo:
      dash.dashMoveTo(offIdx, offset, src.pts[pi])
      cmdBegin = dash.path.cmds.len
      ptBegin = dash.path.pts.len
      inc pi
    of PathCommand.LineTo:
      dash.dashLineTo(src.pts[pi], validPoint)
      inc pi
    of PathCommand.CubicTo:
      dash.dashCubicTo(src.pts[pi], src.pts[pi + 1], src.pts[pi + 2], validPoint)
      pi += 3
    inc ci

  SwOutline(cmds: dash.path.cmds, fpts: dash.path.pts, fillRule: rshape.rule)
