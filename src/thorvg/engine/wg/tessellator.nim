## Tessellation and stroking for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgTessellator.h/.cpp.
## Provides WgBWTessellator (fill triangulation) and WgStroker (stroke expansion).

import std/math
import ../../core/[types, geom, path, bezier]
import ../gl/gpu_probe
import ../gl/gpu_path
import ./mesh

const
  MIN_WG_STROKE_WIDTH* = 1.0'f32
  MIN_WG_STROKE_ALPHA* = 0.25'f32

type
  StrokeState = object
    firstPt, firstPtDir, prevPt, prevPtDir: Point
    firstLength, prevLength: float32
    firstIndex, prevIndex: uint32

  WgStroker* = object
    buffer: ptr WgMesh
    width: float32
    miterLimit: float32
    qualityScale: float32
    cap: StrokeCap
    join: StrokeJoin
    thinFill: bool
    directions: uint8  ## +x, -x, +y, -y of the tessellated edges
    probe: GpuConvexProbe
    state: StrokeState
    leftTop: Point
    rightBottom: Point
    overlapFree*: bool

  WgBWTessellator* = object
    buffer: ptr WgMesh
    bbox: BBox
    convex*: bool

func initWgStroker*(buffer: ptr WgMesh; width: float32; cap: StrokeCap;
                    join: StrokeJoin = StrokeJoin.Bevel; miterLimit = 4.0'f32;
                    qualityScale = 1.0'f32): WgStroker =
  WgStroker(buffer: buffer, width: width, miterLimit: miterLimit,
            qualityScale: qualityScale, cap: cap, join: join)

func radius(s: WgStroker): float32 {.inline.} = s.width * 0.5'f32

proc pushVertex(t: var WgBWTessellator; x, y: float32): uint32 =
  result = uint32(t.buffer.vbuffer.len)
  t.buffer.vbuffer.add(Point(x: x, y: y))
  if result == 0'u32:
    t.bbox.min = Point(x: x, y: y)
    t.bbox.max = Point(x: x, y: y)
  else:
    if x < t.bbox.min.x: t.bbox.min.x = x
    if y < t.bbox.min.y: t.bbox.min.y = y
    if x > t.bbox.max.x: t.bbox.max.x = x
    if y > t.bbox.max.y: t.bbox.max.y = y

proc pushTriangle(t: var WgBWTessellator; a, b, c: uint32) =
  t.buffer.ibuffer.add(a)
  t.buffer.ibuffer.add(b)
  t.buffer.ibuffer.add(c)

func getBBox*(t: WgBWTessellator): BBox = t.bbox

func bounds*(t: WgBWTessellator): Region =
  Region(xMin: int32(floor(t.bbox.min.x)), yMin: int32(floor(t.bbox.min.y)),
         xMax: int32(ceil(t.bbox.max.x)), yMax: int32(ceil(t.bbox.max.y)))

proc tessellate*(t: var WgBWTessellator; path: RenderPath) =
  if path.pts.len <= 2: return
  let cmds = path.cmds
  var pts = 0
  var firstIndex = 0'u32
  var prevIndex = 0'u32
  var firstPt = Point()
  var prevPt = Point()
  var probe = initConvexProbe()
  var contourClosed = false


  proc finishContour() =
    if prevIndex == 0'u32 or contourClosed: return
    probe.addContourClose(firstPt - prevPt)
    contourClosed = true

  for cmd in cmds:
    case cmd
    of PathCommand.MoveTo:
      finishContour()
      probe.nextContour()
      firstIndex = t.pushVertex(path.pts[pts].x, path.pts[pts].y)
      firstPt = path.pts[pts]
      prevPt = path.pts[pts]
      prevIndex = 0'u32
      contourClosed = false
      inc pts
    of PathCommand.LineTo:
      let edge = path.pts[pts] - prevPt
      if prevIndex == 0'u32:
        prevIndex = t.pushVertex(path.pts[pts].x, path.pts[pts].y)
        probe.addEdge(edge)
        prevPt = path.pts[pts]; inc pts
      else:
        probe.addEdge(edge)
        let currIndex = t.pushVertex(path.pts[pts].x, path.pts[pts].y)
        t.pushTriangle(firstIndex, prevIndex, currIndex)
        prevIndex = currIndex
        prevPt = path.pts[pts]; inc pts
    of PathCommand.CubicTo:
      var curve = initBezier(path.pts[pts - 1], path.pts[pts], path.pts[pts + 1], path.pts[pts + 2])
      if probe.convex and gpuEdgesCross(curve.start, curve.ctrl1, curve.ctrl2, curve.`end`):
        probe.convex = false
      var stepCount = int(curve.segments())
      if stepCount <= 1: stepCount = 2
      let step = 1.0'f32 / float32(stepCount)
      var curvePrevPt = prevPt
      for s in 1 .. stepCount:
        let pt = curve.at(step * float32(s))
        probe.addEdge(pt - curvePrevPt)
        let currIndex = t.pushVertex(pt.x, pt.y)
        curvePrevPt = pt
        if prevIndex == 0'u32:
          prevIndex = currIndex
          continue
        t.pushTriangle(firstIndex, prevIndex, currIndex)
        prevIndex = currIndex
      prevPt = curve.`end`
      pts += 3
    of PathCommand.Close:
      finishContour()
  finishContour()
  t.convex = probe.convex

func initWgBWTessellator*(buffer: ptr WgMesh): WgBWTessellator =
  WgBWTessellator(buffer: buffer, bbox: initBBox(), convex: true)

#************************************************************************
# WgStroker
#************************************************************************

func getBBox*(s: WgStroker): BBox =
  BBox(min: s.leftTop, max: s.rightBottom)

func bounds*(s: WgStroker): Region =
  Region(xMin: int32(floor(s.leftTop.x)), yMin: int32(floor(s.leftTop.y)),
         xMax: int32(ceil(s.rightBottom.x)), yMax: int32(ceil(s.rightBottom.y)))

proc expandBounds(s: var WgStroker; x, y: float32) =
  if x < s.leftTop.x: s.leftTop.x = x
  if y < s.leftTop.y: s.leftTop.y = y
  if x > s.rightBottom.x: s.rightBottom.x = x
  if y > s.rightBottom.y: s.rightBottom.y = y

proc pushV(s: var WgStroker; p: Point): uint32 {.inline.} =
  result = uint32(s.buffer.vbuffer.len)
  s.buffer.vbuffer.add(p)

proc pushTri(s: var WgStroker; a, b, c: uint32) {.inline.} =
  s.buffer.ibuffer.add(a); s.buffer.ibuffer.add(b); s.buffer.ibuffer.add(c)

proc join(s: var WgStroker; dir: Point; len: float32; index: uint32)
proc cap(s: var WgStroker)
proc lineTo(s: var WgStroker; curr: Point)
proc cubicTo(s: var WgStroker; cnt1, cnt2, `end`: Point)
proc closePath(s: var WgStroker)

proc roundJoin(s: var WgStroker; prev, curr, center, apex: Point) =
  let turn = cross(center - prev, curr - prev)
  if turn == 0.0'f32: return
  s.expandBounds(center.x, center.y)
  s.expandBounds(prev.x, prev.y)
  s.expandBounds(curr.x, curr.y)

  var startAngle = arctan2((prev - center).y, (prev - center).x)
  var endAngle = arctan2((curr - center).y, (curr - center).x)
  if turn > 0.0'f32:
    if endAngle > startAngle: endAngle -= 2.0'f32 * PI
  else:
    if endAngle < startAngle: endAngle += 2.0'f32 * PI

  let arcAngle = endAngle - startAngle
  let count = max(2'u32, gpuArcSegmentsCnt(arcAngle, s.radius() * s.qualityScale))
  let c = s.pushV(apex)
  var pi = s.pushV(prev)
  let step = (endAngle - startAngle) / float32(int(count) - 1)
  for i in 1 ..< int(count):
    let angle = startAngle + step * float32(i)
    let outp = if i + 1 == int(count): curr
               else: Point(x: center.x + cos(angle) * s.radius(), y: center.y + sin(angle) * s.radius())
    let oi = s.pushV(outp)
    s.pushTri(c, pi, oi)
    pi = oi
    s.expandBounds(outp.x, outp.y)

proc roundPoint(s: var WgStroker; p: Point) =
  let count = gpuArcSegmentsCnt(2.0'f32 * PI, s.radius() * s.qualityScale)
  let c = s.pushV(p)
  let step = 2.0'f32 * PI / float32(int(count) - 1)
  for i in 1 .. int(count):
    let angle = float32(i) * step
    let dir = Point(x: cos(angle), y: sin(angle))
    let outp = p + dir * s.radius()
    let oi = s.pushV(outp)
    if oi > 1'u32:
      s.pushTri(c, oi, oi - 1'u32)
  s.expandBounds(p.x - s.radius(), p.y - s.radius())
  s.expandBounds(p.x + s.radius(), p.y + s.radius())

proc bevel(s: var WgStroker; prev, curr, apex: Point) =
  let a = s.pushV(prev)
  let b = s.pushV(curr)
  let c = s.pushV(apex)
  s.pushTri(a, b, c)

proc miterJoin(s: var WgStroker; prev, curr, center, apex: Point) =
  let pp1 = prev - center
  let pp2 = curr - center
  let outv = pp1 + pp2
  let k = 2.0'f32 * s.radius() * s.radius() / (outv.x * outv.x + outv.y * outv.y)
  let pe = outv * k
  if length(pe) >= s.miterLimit * s.radius():
    s.bevel(prev, curr, apex)
    return
  let joinPt = center + pe
  let c = s.pushV(apex)
  let cp1 = s.pushV(prev)
  let cp2 = s.pushV(curr)
  let e = s.pushV(joinPt)
  s.pushTri(c, cp1, e)
  s.pushTri(e, cp2, c)
  s.expandBounds(joinPt.x, joinPt.y)

proc squareCap(s: var WgStroker; p, outDir: Point) =
  let normal = Point(x: -outDir.y, y: outDir.x)
  let a = p + normal * s.radius()
  let b = p - normal * s.radius()
  let c = a + outDir * s.radius()
  let d = b + outDir * s.radius()
  let ai = s.pushV(a); let bi = s.pushV(b); let ci = s.pushV(c); let di = s.pushV(d)
  s.pushTri(ai, bi, ci)
  s.pushTri(ci, bi, di)
  for pt in [a,b,c,d]: s.expandBounds(pt.x, pt.y)

proc squarePoint(s: var WgStroker; p: Point) =
  let offsetX = Point(x: s.radius(), y: 0.0'f32)
  let offsetY = Point(x: 0.0'f32, y: s.radius())
  let a = p + offsetX + offsetY
  let b = p - offsetX + offsetY
  let c = p - offsetX - offsetY
  let d = p + offsetX - offsetY
  let ai = s.pushV(a); let bi = s.pushV(b); let ci = s.pushV(c); let di = s.pushV(d)
  s.pushTri(ai, bi, ci)
  s.pushTri(ci, di, ai)
  for pt in [a,b,c,d]: s.expandBounds(pt.x, pt.y)

proc roundCapDir(s: var WgStroker; p, outDir: Point) =
  let normal = Point(x: -outDir.y, y: outDir.x)
  let a = p + normal * s.radius()
  let b = p - normal * s.radius()
  let c = p + outDir * s.radius()
  s.roundJoin(a, c, p, p)
  s.roundJoin(c, b, p, p)

proc join(s: var WgStroker; dir: Point; len: float32; index: uint32) =
  let turn = cross(s.state.prevPtDir, dir)
  if zero(turn):
    s.overlapFree = s.overlapFree and (s.state.prevPtDir.x == dir.x and s.state.prevPtDir.y == dir.y)
    if s.state.prevPtDir == dir: return
    if s.join != StrokeJoin.Round: return
    s.roundJoin(s.state.prevPt + Point(x: -s.state.prevPtDir.y, y: s.state.prevPtDir.x) * s.radius(),
                s.state.prevPt + Point(x: -dir.y, y: dir.x) * s.radius(), s.state.prevPt, s.state.prevPt)
  else:
    let normal = Point(x: -dir.y, y: dir.x)
    let prevNormal = Point(x: -s.state.prevPtDir.y, y: s.state.prevPtDir.x)
    let offset = if turn < 0.0'f32: s.radius() else: -s.radius()
    let prevJoin = s.state.prevPt + prevNormal * offset
    let currJoin = s.state.prevPt + normal * offset
    var apex = s.state.prevPt
    let denom = 1.0'f32 + dot(s.state.prevPtDir, dir)
    # Inner-join trimming can collapse quads into slivers, leaving gaps in
    # stroked curves (e.g. demo horizon). Skip trimming; overlap is harmless for
    # opaque direct strokes and overlapFree is already conservative.
    s.overlapFree = false
    case s.join
    of StrokeJoin.Miter: s.miterJoin(prevJoin, currJoin, s.state.prevPt, apex)
    of StrokeJoin.Bevel: s.bevel(prevJoin, currJoin, apex)
    of StrokeJoin.Round: s.roundJoin(prevJoin, currJoin, s.state.prevPt, apex)

proc lineTo(s: var WgStroker; curr: Point) =
  var dir = curr - s.state.prevPt
  let len = length(dir)
  if zero(len): return
  dir = dir * (1.0'f32 / len)
  if s.overlapFree:
    if s.state.firstLength == 0.0'f32:
      s.overlapFree = s.overlapFree and (not s.probe.contourHasEdges)
    var d: uint8 = 0
    if dir.x > 0.0'f32: d = d or 1'u8
    if dir.x < 0.0'f32: d = d or 2'u8
    if dir.y > 0.0'f32: d = d or 4'u8
    if dir.y < 0.0'f32: d = d or 8'u8
    s.directions = s.directions or d
    s.probe.addEdge(dir)

  let normal = Point(x: -dir.y, y: dir.x)
  let a = s.state.prevPt + normal * s.radius()
  let b = s.state.prevPt - normal * s.radius()
  let c = curr + normal * s.radius()
  let dpt = curr - normal * s.radius()
  let ia = s.pushV(a); let ib = s.pushV(b); let ic = s.pushV(c); let id = s.pushV(dpt)
  s.pushTri(ia, ib, ic)
  s.pushTri(ib, id, ic)

  if s.state.firstLength == 0.0'f32:
    s.state.firstPtDir = dir
    s.state.firstLength = len
    s.state.firstIndex = ia
  else:
    s.join(dir, len, ia)
  s.state.prevPtDir = dir
  s.state.prevPt = curr
  s.state.prevLength = len
  s.state.prevIndex = ia

  if ia == 0'u32:
    s.leftTop = curr; s.rightBottom = curr
  for pt in [a,b,c,dpt]: s.expandBounds(pt.x, pt.y)

proc cubicTo(s: var WgStroker; cnt1, cnt2, `end`: Point) =
  var curve = initBezier(s.state.prevPt, cnt1, cnt2, `end`)
  let count = curve.segments(s.qualityScale)
  let step = 1.0'f32 / float32(count)
  var i = 1'u32
  while i <= count:
    s.lineTo(curve.at(step * float32(i)))
    inc i

proc closePath(s: var WgStroker) =
  if s.state.firstLength == 0.0'f32: return
  if length(s.state.prevPt - s.state.firstPt) > 0.015625'f32:
    s.lineTo(s.state.firstPt)
  let len = if s.state.prevPt.x == s.state.firstPt.x and s.state.prevPt.y == s.state.firstPt.y: s.state.firstLength else: 0.0'f32
  if len == 0.0'f32: s.overlapFree = false
  if s.overlapFree: s.probe.addEdge(s.state.firstPtDir)
  s.join(s.state.firstPtDir, len, s.state.firstIndex)
  s.overlapFree = s.overlapFree and s.probe.convex
  s.state.firstLength = 0.0'f32
  s.state.prevPt = s.state.firstPt

proc cap(s: var WgStroker) =
  let monotone = (s.directions and 3'u8) != 3'u8 or (s.directions and 12'u8) != 12'u8
  s.overlapFree = s.overlapFree and s.state.firstLength > 0.0'f32 and
    (s.cap == StrokeCap.Butt or s.state.firstPt != s.state.prevPt) and
    (monotone or (s.probe.convex and s.probe.xDirChanges <= 1'u8 and s.probe.yDirChanges <= 1'u8 and
      float32(s.probe.winding) * cross(s.state.firstPtDir, s.state.prevPtDir) >= 0.0'f32))
  if s.cap == StrokeCap.Butt: return
  if s.cap == StrokeCap.Square:
    if s.state.firstPt == s.state.prevPt: s.squarePoint(s.state.firstPt)
    else:
      s.squareCap(s.state.firstPt, Point(x: -s.state.firstPtDir.x, y: -s.state.firstPtDir.y))
      s.squareCap(s.state.prevPt, s.state.prevPtDir)
  elif s.cap == StrokeCap.Round:
    if s.state.firstPt == s.state.prevPt: s.roundPoint(s.state.firstPt)
    else:
      s.roundCapDir(s.state.firstPt, Point(x: -s.state.firstPtDir.x, y: -s.state.firstPtDir.y))
      s.roundCapDir(s.state.prevPt, s.state.prevPtDir)

proc run*(s: var WgStroker; path: RenderPath; thinFill = false) =
  s.thinFill = thinFill
  s.overlapFree = not thinFill
  s.probe = initConvexProbe()
  s.directions = 0
  s.state = StrokeState()
  s.leftTop = Point()
  s.rightBottom = Point()

  var validStrokeCap = false
  var pts = 0
  for cmd in path.cmds:
    case cmd
    of PathCommand.MoveTo:
      if validStrokeCap:
        s.cap()
        validStrokeCap = false
      s.state = StrokeState()
      s.state.firstPt = path.pts[pts]
      s.state.prevPt = path.pts[pts]
      inc pts
      validStrokeCap = false
    of PathCommand.LineTo:
      validStrokeCap = true
      s.lineTo(path.pts[pts]); inc pts
    of PathCommand.CubicTo:
      validStrokeCap = true
      s.cubicTo(path.pts[pts], path.pts[pts+1], path.pts[pts+2])
      pts += 3
    of PathCommand.Close:
      s.closePath()
      validStrokeCap = false
  if validStrokeCap: s.cap()
