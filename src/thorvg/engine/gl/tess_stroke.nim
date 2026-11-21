## Stroke tessellator of the GL engine (`Stroker` of `tvgGlTessellator.cpp`).
##
## API:
##   `var s = initStroker(width, cap, join, miterLimit = 4.0, qualityScale = 1.0)`
##   `s.run(path, thinFill = false)`   appends triangles to `s.buffer` (x, y pairs + `uint32`
##                                     triangle list, see `GlGeometryBuffer`)
##   `s.bounds(): Region`              integer bounds of everything emitted (local space)
##   `s.overlapFree`                   the stroke needs no stencil pass (`strokeDirect`)
##
## The stroker OWNS its buffer (the C++ keeps a pointer); move it out afterwards:
## `g.stroke = move s.buffer`. float32 everywhere, same operation order as the original
## (bit-exact oracle: `tests/gl/geometry_compare.ps1`). Float checks are off like in C++.

import std/math
import ../../core/[types, geom, path, bezier]
import ./[gl_common, gpu_path, gpu_probe]

{.push floatChecks: false.}

type
  StrokerState = object
    firstPt, firstPtDir, prevPt, prevPtDir: Point
    firstLength, prevLength: float32
    firstIndex, prevIndex: uint32

  Stroker* = object
    buffer*: GlGeometryBuffer
    overlapFree*: bool
    width, miterLimit, qualityScale: float32
    cap: StrokeCap
    join: StrokeJoin
    thinFill: bool
    directions: uint8   ## +x, -x, +y, -y of the tessellated edges
    probe: GpuConvexProbe
    state: StrokerState
    leftTop, rightBottom: Point

func initStroker*(width: float32, cap: StrokeCap, join: StrokeJoin, miterLimit = 4.0'f32,
                  qualityScale = 1.0'f32): Stroker =
  Stroker(width: width, cap: cap, join: join, miterLimit: miterLimit, qualityScale: qualityScale)

func radius(s: Stroker): float32 {.inline.} = s.width * 0.5'f32

func bounds*(s: Stroker): Region =
  Region(xMin: toI32(floor(s.leftTop.x)), yMin: toI32(floor(s.leftTop.y)),
         xMax: toI32(ceil(s.rightBottom.x)), yMax: toI32(ceil(s.rightBottom.y)))

func pushVertex(b: var GlGeometryBuffer, x, y: float32): uint32 =
  result = uint32(b.vertex.len div 2)
  b.vertex.add x
  b.vertex.add y

func pushTriangle(b: var GlGeometryBuffer, a, bb, c: uint32) =
  b.index.add a
  b.index.add bb
  b.index.add c

func extend(s: var Stroker, a, b, c, d: Point) =
  ## Grows the bounds with a quad.
  s.leftTop.x = stdMin(s.leftTop.x, stdMin(stdMin(a.x, b.x), stdMin(c.x, d.x)))
  s.leftTop.y = stdMin(s.leftTop.y, stdMin(stdMin(a.y, b.y), stdMin(c.y, d.y)))
  s.rightBottom.x = stdMax(s.rightBottom.x, stdMax(stdMax(a.x, b.x), stdMax(c.x, d.x)))
  s.rightBottom.y = stdMax(s.rightBottom.y, stdMax(stdMax(a.y, b.y), stdMax(c.y, d.y)))

func extend(s: var Stroker, p: Point) =
  s.leftTop.x = stdMin(s.leftTop.x, p.x)
  s.leftTop.y = stdMin(s.leftTop.y, p.y)
  s.rightBottom.x = stdMax(s.rightBottom.x, p.x)
  s.rightBottom.y = stdMax(s.rightBottom.y, p.y)

func square(s: var Stroker, p, outDir: Point) =
  let normal = Point(x: -outDir.y, y: outDir.x)
  let a = p + normal * s.radius
  let b = p - normal * s.radius
  let c = a + outDir * s.radius
  let d = b + outDir * s.radius
  let ai = s.buffer.pushVertex(a.x, a.y)
  let bi = s.buffer.pushVertex(b.x, b.y)
  let ci = s.buffer.pushVertex(c.x, c.y)
  let di = s.buffer.pushVertex(d.x, d.y)
  s.buffer.pushTriangle(ai, bi, ci)
  s.buffer.pushTriangle(ci, bi, di)
  s.extend(a, b, c, d)

func squarePoint(s: var Stroker, p: Point) =
  let offsetX = Point(x: s.radius, y: 0.0'f32)
  let offsetY = Point(x: 0.0'f32, y: s.radius)
  let a = p + offsetX + offsetY
  let b = p - offsetX + offsetY
  let c = p - offsetX - offsetY
  let d = p + offsetX - offsetY
  let ai = s.buffer.pushVertex(a.x, a.y)
  let bi = s.buffer.pushVertex(b.x, b.y)
  let ci = s.buffer.pushVertex(c.x, c.y)
  let di = s.buffer.pushVertex(d.x, d.y)
  s.buffer.pushTriangle(ai, bi, ci)
  s.buffer.pushTriangle(ci, di, ai)
  s.extend(a, b, c, d)

func roundArc(s: var Stroker, prev, curr, center, apex: Point) =
  let turn = cross(center - prev, curr - prev)
  if turn == 0.0'f32: return
  s.leftTop.x = stdMin(s.leftTop.x, stdMin(center.x, stdMin(prev.x, curr.x)))
  s.leftTop.y = stdMin(s.leftTop.y, stdMin(center.y, stdMin(prev.y, curr.y)))
  s.rightBottom.x = stdMax(s.rightBottom.x, stdMax(center.x, stdMax(prev.x, curr.x)))
  s.rightBottom.y = stdMax(s.rightBottom.y, stdMax(center.y, stdMax(prev.y, curr.y)))

  let startAngle = atan(prev - center)
  var endAngle = atan(curr - center)
  if turn > 0.0'f32:
    if endAngle > startAngle: endAngle -= 2.0'f32 * MathPi
  elif endAngle < startAngle: endAngle += 2.0'f32 * MathPi

  let arcAngle = endAngle - startAngle
  let count = max(2'u32, gpuArcSegmentsCnt(arcAngle, s.radius * s.qualityScale))
  let c = s.buffer.pushVertex(apex.x, apex.y)
  var pi = s.buffer.pushVertex(prev.x, prev.y)
  let step = (endAngle - startAngle) / float32(count - 1)
  for i in 1'u32 ..< count:
    let angle = startAngle + step * float32(i)
    # keep the shared edge exact so adjacent arcs and segments do not overlap
    let outp = if i + 1 == count: curr
               else: Point(x: center.x + cos(angle) * s.radius, y: center.y + sin(angle) * s.radius)
    let oi = s.buffer.pushVertex(outp.x, outp.y)
    s.buffer.pushTriangle(c, pi, oi)
    pi = oi
    s.extend(outp)

func roundPoint(s: var Stroker, p: Point) =
  let count = gpuArcSegmentsCnt(2.0'f32 * MathPi, s.radius * s.qualityScale)
  let c = s.buffer.pushVertex(p.x, p.y)
  let step = 2.0'f32 * MathPi / float32(count - 1)
  for i in 1'u32 .. count:
    let angle = float32(i) * step
    let dir = Point(x: cos(angle), y: sin(angle))
    let outp = p + dir * s.radius
    let oi = s.buffer.pushVertex(outp.x, outp.y)
    if oi > 1: s.buffer.pushTriangle(c, oi, oi - 1)
  s.leftTop.x = stdMin(s.leftTop.x, p.x - s.radius)
  s.leftTop.y = stdMin(s.leftTop.y, p.y - s.radius)
  s.rightBottom.x = stdMax(s.rightBottom.x, p.x + s.radius)
  s.rightBottom.y = stdMax(s.rightBottom.y, p.y + s.radius)

func roundCap(s: var Stroker, p, outDir: Point) =
  let normal = Point(x: -outDir.y, y: outDir.x)
  let a = p + normal * s.radius
  let b = p - normal * s.radius
  let c = p + outDir * s.radius
  s.roundArc(a, c, p, p)
  s.roundArc(c, b, p, p)

func bevel(s: var Stroker, prev, curr, apex: Point) =
  let a = s.buffer.pushVertex(prev.x, prev.y)
  let b = s.buffer.pushVertex(curr.x, curr.y)
  let c = s.buffer.pushVertex(apex.x, apex.y)
  s.buffer.pushTriangle(a, b, c)

func miter(s: var Stroker, prev, curr, center, apex: Point) =
  let pp1 = prev - center
  let pp2 = curr - center
  let outd = pp1 + pp2
  let k = 2.0'f32 * s.radius * s.radius / (outd.x * outd.x + outd.y * outd.y)
  let pe = outd * k
  let limit = s.miterLimit * s.radius
  if dot(pe, pe) >= limit * limit:
    s.bevel(prev, curr, apex)
    return
  let join = center + pe
  let c = s.buffer.pushVertex(apex.x, apex.y)
  let cp1 = s.buffer.pushVertex(prev.x, prev.y)
  let cp2 = s.buffer.pushVertex(curr.x, curr.y)
  let e = s.buffer.pushVertex(join.x, join.y)
  s.buffer.pushTriangle(c, cp1, e)
  s.buffer.pushTriangle(e, cp2, c)
  s.extend(join)

func joinSegments(s: var Stroker, dir: Point, len: float32, index: uint32) =
  let turn = cross(s.state.prevPtDir, dir)
  if zero(turn):
    s.overlapFree = s.overlapFree and s.state.prevPtDir.x == dir.x and
      s.state.prevPtDir.y == dir.y
    if s.state.prevPtDir == dir: return          # same direction
    if s.join != StrokeJoin.Round: return        # opposite direction
    s.roundCap(s.state.prevPt, dir)
    return

  let normal = Point(x: -dir.y, y: dir.x)
  let prevNormal = Point(x: -s.state.prevPtDir.y, y: s.state.prevPtDir.x)
  let offset = if turn < 0.0'f32: s.radius else: -s.radius
  let prevJoin = s.state.prevPt + prevNormal * offset
  let currJoin = s.state.prevPt + normal * offset
  var apex = s.state.prevPt
  let cosine = dot(s.state.prevPtDir, dir)
  let denom = 1.0'f32 + cosine
  var trimmed = false

  if not s.thinFill and denom > FloatEpsilon:
    # choose the half-angle ratio that avoids cancellation near a reversal
    let setback = s.radius * (if cosine < 0.0'f32: (1.0'f32 - cosine) / abs(turn)
                              else: abs(turn) / denom)
    let scale = stdMax(stdMax(abs(apex.x), abs(apex.y)),
                       stdMax(s.radius, stdMax(s.state.prevLength, len)))
    # keep each cut within its half-segment so neighboring cuts and caps stay independent
    if 2.0'f32 * setback + FloatEpsilon * scale < stdMin(s.state.prevLength, len):
      let inner = apex - s.state.prevPtDir * setback - prevNormal * offset
      let side = if turn < 0.0'f32: 1'u32 else: 0'u32
      let prev = int((s.state.prevIndex + 2 + side) * 2)
      let curr = int((index + side) * 2)
      s.buffer.vertex[prev] = inner.x
      s.buffer.vertex[curr] = inner.x
      s.buffer.vertex[prev + 1] = inner.y
      s.buffer.vertex[curr + 1] = inner.y
      apex = inner
      trimmed = true
  s.overlapFree = s.overlapFree and trimmed

  if s.join == StrokeJoin.Miter: s.miter(prevJoin, currJoin, s.state.prevPt, apex)
  elif s.join == StrokeJoin.Bevel: s.bevel(prevJoin, currJoin, apex)
  else: s.roundArc(prevJoin, currJoin, s.state.prevPt, apex)

func lineTo(s: var Stroker, curr: Point) =
  var dir = curr - s.state.prevPt
  let len = length(dir)
  if zero(len) or not isFinite32(len): return
  dir *= 1.0'f32 / len
  if s.overlapFree:
    if s.state.firstLength == 0.0'f32: s.overlapFree = s.overlapFree and not s.probe.contourHasEdges
    # keep collecting after the convexity probe rejects a change of winding
    s.directions = s.directions or uint8(int(dir.x > 0.0'f32) or (int(dir.x < 0.0'f32) shl 1) or
      (int(dir.y > 0.0'f32) shl 2) or (int(dir.y < 0.0'f32) shl 3))
    s.probe.addEdge(dir)

  let normal = Point(x: -dir.y, y: dir.x)
  let a = s.state.prevPt + normal * s.radius
  let b = s.state.prevPt - normal * s.radius
  let c = curr + normal * s.radius
  let d = curr - normal * s.radius
  let ia = s.buffer.pushVertex(a.x, a.y)
  discard s.buffer.pushVertex(b.x, b.y)
  discard s.buffer.pushVertex(c.x, c.y)
  discard s.buffer.pushVertex(d.x, d.y)
  # a --------- c
  # b --------- d
  s.buffer.pushTriangle(ia, ia + 1, ia + 2)
  s.buffer.pushTriangle(ia + 1, ia + 3, ia + 2)

  if s.state.firstLength == 0.0'f32:
    s.state.firstPtDir = dir
    s.state.firstLength = len
    s.state.firstIndex = ia
  else: s.joinSegments(dir, len, ia)
  s.state.prevPtDir = dir
  s.state.prevPt = curr
  s.state.prevLength = len
  s.state.prevIndex = ia

  if ia == 0:
    s.leftTop = curr
    s.rightBottom = curr
  s.extend(a, b, c, d)

func cubicTo(s: var Stroker, cnt1, cnt2, finish: Point) =
  let curve = initBezier(s.state.prevPt, cnt1, cnt2, finish)
  let count = curve.segments(s.qualityScale)
  let step = 1.0'f32 / float32(count)
  for i in 1'u32 .. count: s.lineTo(curve.at(step * float32(i)))

func close(s: var Stroker) =
  if s.state.firstLength == 0.0'f32: return
  let delta = s.state.prevPt - s.state.firstPt
  if dot(delta, delta) > 0.015625'f32 * 0.015625'f32: s.lineTo(s.state.firstPt)

  # a skipped closing edge cannot share an inner corner
  let len = if s.state.prevPt.x == s.state.firstPt.x and s.state.prevPt.y == s.state.firstPt.y:
      s.state.firstLength else: 0.0'f32
  if len == 0.0'f32: s.overlapFree = false
  if s.overlapFree: s.probe.addEdge(s.state.firstPtDir)
  s.joinSegments(s.state.firstPtDir, len, s.state.firstIndex)
  s.overlapFree = s.overlapFree and s.probe.convex
  s.state.firstLength = 0.0'f32
  s.state.prevPt = s.state.firstPt

func addCap(s: var Stroker) =
  # open contours monotone in either axis may turn both ways: half-segment cuts keep joins
  # independent, and their forward boundaries separate the caps
  let monotone = (s.directions and 3) != 3 or (s.directions and 12) != 12
  s.overlapFree = s.overlapFree and s.state.firstLength > 0.0'f32 and
    (s.cap == StrokeCap.Butt or s.state.firstPt != s.state.prevPt) and
    (monotone or (s.probe.convex and s.probe.xDirChanges <= 1 and s.probe.yDirChanges <= 1 and
      float32(s.probe.winding) * cross(s.state.firstPtDir, s.state.prevPtDir) >= 0.0'f32))
  if s.cap == StrokeCap.Butt: return
  let first = s.state.firstPt
  let last = s.state.prevPt
  let firstOut = Point(x: -s.state.firstPtDir.x, y: -s.state.firstPtDir.y)
  if s.cap == StrokeCap.Square:
    if first == last: s.squarePoint(first)
    else:
      s.square(first, firstOut)
      s.square(last, s.state.prevPtDir)
  elif s.cap == StrokeCap.Round:
    if first == last: s.roundPoint(first)
    else:
      s.roundCap(first, firstOut)
      s.roundCap(last, s.state.prevPtDir)

func run*(s: var Stroker, path: RenderPath, thinFill = false) =
  ## Tessellates `path` into `s.buffer` (appending to what is already there).
  s.thinFill = thinFill
  s.overlapFree = not thinFill
  s.probe = GpuConvexProbe()
  s.directions = 0
  var validStrokeCap = false
  var pi = 0
  for cmd in path.cmds:
    case cmd
    of PathCommand.MoveTo:
      if validStrokeCap:   # skipped if the path only contains move instructions
        s.addCap()
      s.state.firstLength = 0.0'f32   # the first segment initializes the remaining edge state
      s.state.firstPt = path.pts[pi]
      s.state.prevPt = path.pts[pi]
      inc pi
      validStrokeCap = false
    of PathCommand.LineTo:
      validStrokeCap = true
      s.lineTo(path.pts[pi])
      inc pi
    of PathCommand.CubicTo:
      validStrokeCap = true
      s.cubicTo(path.pts[pi], path.pts[pi + 1], path.pts[pi + 2])
      pi += 3
    of PathCommand.Close:
      s.close()
      validStrokeCap = false
  if validStrokeCap: s.addCap()

{.pop.}
