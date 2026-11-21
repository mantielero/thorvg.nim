## Cubic Bezier and polyline length helpers.
##
## Ported from `tvgMath.h` / `tvgMath.cpp` (struct `Bezier`, `tvg::length` for paths).

import std/math
import ./[types, geom]

const BezierEpsilon = 1e-2'f32

type Bezier* = object
  start*, ctrl1*, ctrl2*, `end`*: Point

func initBezier*(p0, p1, p2, p3: Point): Bezier =
  Bezier(start: p0, ctrl1: p1, ctrl2: p2, `end`: p3)

func initBezier*(st, ed: Point, radius: float32): Bezier =
  ## Approximates a quarter-circle arc between `st` and `ed` with a radius.
  let angle = atan(ed - st)
  let c = radius * PathKappa
  Bezier(start: st,
         ctrl1: Point(x: st.x + radius * cos(angle), y: st.y + radius * sin(angle)),
         ctrl2: Point(x: ed.x - c * cos(angle), y: ed.y - c * sin(angle)),
         `end`: ed)

func `*`*(b: Bezier, m: Matrix): Bezier =
  Bezier(start: b.start * m, ctrl1: b.ctrl1 * m, ctrl2: b.ctrl2 * m, `end`: b.`end` * m)

func tangent*(b: Bezier, t: float32): Point =
  let mt = 1.0'f32 - t
  let d = t * t
  let a = -mt * mt
  let bb = 1.0'f32 - 4.0'f32 * t + 3.0'f32 * d
  let c = 2.0'f32 * t - 3.0'f32 * d
  Point(x: a * b.start.x + bb * b.ctrl1.x + c * b.ctrl2.x + d * b.`end`.x,
        y: a * b.start.y + bb * b.ctrl1.y + c * b.ctrl2.y + d * b.`end`.y) * 3.0'f32

func angle*(b: Bezier, t: float32): float32 =
  if t < 0 or t > 1: return 0
  rad2deg(atan(tangent(b, t)))

func at*(b: Bezier, t: float32): Point =
  ## Point on the curve at parameter `t` (0..1).
  let it = 1.0'f32 - t
  var ax = b.start.x * it + b.ctrl1.x * t
  var bx = b.ctrl1.x * it + b.ctrl2.x * t
  let cx = b.ctrl2.x * it + b.`end`.x * t
  ax = ax * it + bx * t
  bx = bx * it + cx * t
  var ay = b.start.y * it + b.ctrl1.y * t
  var by = b.ctrl1.y * it + b.ctrl2.y * t
  let cy = b.ctrl2.y * it + b.`end`.y * t
  ay = ay * it + by * t
  by = by * it + cy * t
  Point(x: ax * it + bx * t, y: ay * it + by * t)

func split*(b: Bezier, left, right: var Bezier) =
  ## Splits at t = 0.5.
  var c = (b.ctrl1.x + b.ctrl2.x) * 0.5'f32
  left.ctrl1.x = (b.start.x + b.ctrl1.x) * 0.5'f32
  right.ctrl2.x = (b.ctrl2.x + b.`end`.x) * 0.5'f32
  left.start.x = b.start.x
  right.`end`.x = b.`end`.x
  left.ctrl2.x = (left.ctrl1.x + c) * 0.5'f32
  right.ctrl1.x = (right.ctrl2.x + c) * 0.5'f32
  left.`end`.x = (left.ctrl2.x + right.ctrl1.x) * 0.5'f32
  right.start.x = left.`end`.x

  c = (b.ctrl1.y + b.ctrl2.y) * 0.5'f32
  left.ctrl1.y = (b.start.y + b.ctrl1.y) * 0.5'f32
  right.ctrl2.y = (b.ctrl2.y + b.`end`.y) * 0.5'f32
  left.start.y = b.start.y
  right.`end`.y = b.`end`.y
  left.ctrl2.y = (left.ctrl1.y + c) * 0.5'f32
  right.ctrl1.y = (right.ctrl2.y + c) * 0.5'f32
  left.`end`.y = (left.ctrl2.y + right.ctrl1.y) * 0.5'f32
  right.start.y = left.`end`.y

func splitAt*(b: var Bezier, t: float32, left: var Bezier) =
  ## De Casteljau split at `t`: `left` receives [0,t], `b` is reduced to [t,1].
  left.start = b.start
  left.ctrl1 = b.start + t * (b.ctrl1 - b.start)
  left.ctrl2 = b.ctrl1 + t * (b.ctrl2 - b.ctrl1)  # temporary holding spot
  b.ctrl2 = b.ctrl2 + t * (b.`end` - b.ctrl2)
  b.ctrl1 = left.ctrl2 + t * (b.ctrl2 - left.ctrl2)
  left.ctrl2 = left.ctrl1 + t * (left.ctrl2 - left.ctrl1)
  left.`end` = left.ctrl2 + t * (b.ctrl1 - left.ctrl2)
  b.start = left.`end`

func exactDist(a, b: Point): float32 =
  let dx = b.x - a.x
  let dy = b.y - a.y
  sqrt(dx * dx + dy * dy)

func bezLengthExact(cur: Bezier): float32 =
  var l, r: Bezier
  let len = exactDist(cur.start, cur.ctrl1) + exactDist(cur.ctrl1, cur.ctrl2) +
            exactDist(cur.ctrl2, cur.`end`)
  if abs(len - exactDist(cur.start, cur.`end`)) > BezierEpsilon:
    split(cur, l, r)
    bezLengthExact(l) + bezLengthExact(r)
  else:
    len

func bezLengthApprox(cur: Bezier): float32 =
  var l, r: Bezier
  let len = length(cur.start, cur.ctrl1) + length(cur.ctrl1, cur.ctrl2) +
            length(cur.ctrl2, cur.`end`)
  if abs(len - length(cur.start, cur.`end`)) > BezierEpsilon:
    split(cur, l, r)
    bezLengthApprox(l) + bezLengthApprox(r)
  else:
    len

func length*(b: Bezier): float32 = bezLengthExact(b)
func lengthApprox*(b: Bezier): float32 = bezLengthApprox(b)

func bezAt(bz: Bezier, at, length: float32, approx: bool): float32 =
  var biggest = 1.0'f32
  var smallest = 0.0'f32
  var t = 0.5'f32
  if at <= 0: return 0.0'f32
  if at >= length: return 1.0'f32
  while true:
    var right = bz
    var left: Bezier
    splitAt(right, t, left)
    let len = if approx: bezLengthApprox(left) else: bezLengthExact(left)
    if abs(len - at) < BezierEpsilon or abs(smallest - biggest) < 1e-3'f32: break
    if len < at:
      smallest = t
      t = (t + biggest) * 0.5'f32
    else:
      biggest = t
      t = (smallest + t) * 0.5'f32
  t

func at*(b: Bezier, at, length: float32): float32 =
  ## Curve parameter t that corresponds to arc length `at` (of `length` total).
  bezAt(b, at, length, false)

func atApprox*(b: Bezier, at, length: float32): float32 =
  bezAt(b, at, length, true)

func split*(b: Bezier, at: float32, left, right: var Bezier) =
  ## Splits at arc length `at`.
  right = b
  let t = bezAt(b, at, length(b), false)
  splitAt(right, t, left)

func flatten*(b: Bezier, tolerance: float32): bool =
  ## True if the curve is flat enough for the given tolerance.
  var d1x = abs(b.ctrl1.x * 3.0'f32 - b.start.x * 2.0'f32 - b.`end`.x)
  var d1y = abs(b.ctrl1.y * 3.0'f32 - b.start.y * 2.0'f32 - b.`end`.y)
  let d2x = abs(b.ctrl2.x * 3.0'f32 - b.`end`.x * 2.0'f32 - b.start.x)
  let d2y = abs(b.ctrl2.y * 3.0'f32 - b.`end`.y * 2.0'f32 - b.start.y)
  if d1x < d2x: d1x = d2x
  if d1y < d2y: d1y = d2y
  d1x + d1y <= tolerance

func segments*(b: Bezier, scale: float32 = 1.0'f32): uint32 =
  ## Number of line segments needed to flatten the curve (capped at 2^10).
  const MaxSegments = 1'u32 shl 10
  var stack = @[b]
  let tolerance = 0.5'f32 / scale
  var count = 0'u32
  while stack.len > 0:
    let current = stack.pop()
    if current.flatten(tolerance):
      inc count
      continue
    if count + uint32(stack.len) + 2 >= MaxSegments:
      count = MaxSegments
      break
    var l, r: Bezier
    current.split(l, r)
    stack.add r
    stack.add l
  count

proc expandBounds(box: var BBox, st, c1, c2, en: Point) =
  if box.min.x > st.x: box.min.x = st.x
  if box.min.y > st.y: box.min.y = st.y
  if box.min.x > en.x: box.min.x = en.x
  if box.min.y > en.y: box.min.y = en.y
  if box.max.x < st.x: box.max.x = st.x
  if box.max.y < st.y: box.max.y = st.y
  if box.max.x < en.x: box.max.x = en.x
  if box.max.y < en.y: box.max.y = en.y

  proc extrema(s, c1, c2, e: float32, mn, mx: var float32) =
    let a = -1.0'f32 * s + 3.0'f32 * c1 - 3.0'f32 * c2 + e
    let b = s - 2.0'f32 * c1 + c2
    let c = -1.0'f32 * s + c1
    proc eval(t: float32): float32 =
      let u = 1.0'f32 - t
      u * u * u * s + 3.0'f32 * u * u * t * c1 + 3.0'f32 * u * t * t * c2 + t * t * t * e
    if zero(a):
      if zero(b): return
      let t = -c / (2.0'f32 * b)
      if t > 0.0'f32 and t < 1.0'f32:
        let q = eval(t)
        if q < mn: mn = q
        if q > mx: mx = q
      return
    var h = b * b - a * c
    if h <= 0.0'f32: return
    h = sqrt(h)
    for t in [(-b - h) / a, (-b + h) / a]:
      if t <= 0.0'f32 or t >= 1.0'f32: continue
      let q = eval(t)
      if q < mn: mn = q
      if q > mx: mx = q

  extrema(st.x, c1.x, c2.x, en.x, box.min.x, box.max.x)
  extrema(st.y, c1.y, c2.y, en.y, box.min.y, box.max.y)

proc bounds*(box: var BBox, start, ctrl1, ctrl2, `end`: Point) =
  ## Extends `box` with the exact extrema of the cubic curve.
  expandBounds(box, start, ctrl1, ctrl2, `end`)

func pathLength*(cmds: openArray[PathCommand], pts: openArray[Point]): float32 =
  ## Total length of a path (sum of segment lengths).
  if pts.len < 2: return 0.0'f32
  var start = 0
  var p = 0
  for c in cmds:
    case c
    of PathCommand.Close:
      result += length(pts[p - 1], pts[start])
    of PathCommand.MoveTo:
      start = p
      inc p
    of PathCommand.LineTo:
      result += length(pts[p - 1], pts[p])
      inc p
    of PathCommand.CubicTo:
      result += length(initBezier(pts[p - 1], pts[p], pts[p + 1], pts[p + 2]))
      p += 3
