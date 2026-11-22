## Lottie property model and keyframe evaluation (port of tvgLottieProperty).

import std/math
import common
import ../animation/interpolator

type
  LottieScalarFrame*[T] = object
    value*: T
    no*: float32
    interpolator*: LottieInterpolator
    interpolatorsD*: seq[LottieInterpolator] # per-dimension easing
    hold*: bool

  LottieVectorFrame*[T] = object
    value*: T
    no*: float32
    interpolator*: LottieInterpolator
    interpolatorsD*: seq[LottieInterpolator] # per-dimension easing
    outTangent*, inTangent*: T
    length*: float32
    hasTangent*: bool
    hold*: bool

  LottieGenericProperty*[F, V] = ref object
    frames*: seq[F]
    value*: V
    hasFrames*: bool
    ix*: uint8
    sid*: uint32

proc lerpValue(a, b: float32; t: float32): float32 {.inline.} = lerp(a,b,t)
proc lerpValue(a, b: LottiePoint; t: float32): LottiePoint {.inline.} = lerp(a,b,t)
proc lerpValue(a, b: LottiePoint3; t: float32): LottiePoint3 {.inline.} = lerp(a,b,t)
proc lerpValue(a, b: LottieColor; t: float32): LottieColor {.inline.} = lerp(a,b,t)
proc lerpValue(a, b: LottiePath; t: float32): LottiePath {.inline.} = lerp(a,b,t)
proc lerpValue(a, b: uint8; t: float32): uint8 {.inline.} =
  uint8(clamp(int(lerp(float32(a), float32(b), t)), 0, 255))

proc interpScalar*[T](f, n: LottieScalarFrame[T]; frameNo: float32): T =
  var t = (frameNo - f.no) / (n.no - f.no)
  if f.interpolator != nil: t = f.interpolator.progress(t)
  if f.hold:
    if t < 1.0'f32: return f.value
    else: return n.value
  # NOTE: i.x/i.y/o.x/o.y may be arrays (per-dimension easing). ThorVG C++ getValue()
  # collapses to first element; we store interpolatorsD in the model but evaluate
  # using the collapsed interpolator for C++ parity. Per-dim eval is a future gap.
  lerpValue(f.value, n.value, t)

# Bezier for spatial vector interpolation (ported from tvgMath.cpp)

const BezierEpsilon = 1e-2'f32

type Bezier* = object
  start*, ctrl1*, ctrl2*, `end`*: LottiePoint

proc bezierAt*(b: Bezier; t: float32): LottiePoint =
  let it = 1.0'f32 - t
  let it2 = it * it
  let t2 = t * t
  b.start * (it2 * it) + b.ctrl1 * (3.0'f32 * it2 * t) + b.ctrl2 * (3.0'f32 * it * t2) + b.`end` * (t2 * t)

proc tangent*(b: Bezier; t: float32): LottiePoint =
  let mt = 1.0'f32 - t
  let d = t * t
  let a = -mt * mt
  let bb = 1.0'f32 - 4.0'f32 * t + 3.0'f32 * d
  let c = 2.0'f32 * t - 3.0'f32 * d
  let pt = LottiePoint(x: a * b.start.x + bb * b.ctrl1.x + c * b.ctrl2.x + d * b.`end`.x,
                       y: a * b.start.y + bb * b.ctrl1.y + c * b.ctrl2.y + d * b.`end`.y)
  LottiePoint(x: pt.x * 3.0'f32, y: pt.y * 3.0'f32)

proc angle*(b: Bezier; t: float32): float32 =
  let pt = b.tangent(t)
  radToDeg(arctan2(pt.y, pt.x))

proc split(b: Bezier; t: float32; left: var Bezier): Bezier =
  left.start = b.start
  left.ctrl1 = b.start + (b.ctrl1 - b.start) * t
  left.ctrl2 = b.ctrl1 + (b.ctrl2 - b.ctrl1) * t
  var right: Bezier
  right.ctrl2 = b.ctrl2 + (b.`end` - b.ctrl2) * t
  right.ctrl1 = left.ctrl2 + (right.ctrl2 - left.ctrl2) * t
  left.ctrl2 = left.ctrl1 + (left.ctrl2 - left.ctrl1) * t
  left.`end` = left.ctrl2 + (right.ctrl1 - left.ctrl2) * t
  right.start = left.`end`
  right.`end` = b.`end`
  right

proc lengthFast(a, b: LottiePoint): float32 {.inline.} =
  var x = b.x - a.x; var y = b.y - a.y
  if x < 0: x = -x
  if y < 0: y = -y
  if x > y: x + 0.375'f32 * y else: y + 0.375'f32 * x

proc lengthEuclid(a, b: LottiePoint): float32 {.inline.} =
  let dx = b.x - a.x; let dy = b.y - a.y
  sqrt(dx*dx + dy*dy)

proc bezLengthApproxFn(b: Bezier): float32 =
  let len = lengthFast(b.start, b.ctrl1) + lengthFast(b.ctrl1, b.ctrl2) + lengthFast(b.ctrl2, b.`end`)
  let chord = lengthFast(b.start, b.`end`)
  if abs(len - chord) > BezierEpsilon:
    var left: Bezier
    let right = split(b, 0.5'f32, left)
    return bezLengthApproxFn(left) + bezLengthApproxFn(right)
  len

proc bezLengthFn(b: Bezier): float32 =
  let len = lengthEuclid(b.start, b.ctrl1) + lengthEuclid(b.ctrl1, b.ctrl2) + lengthEuclid(b.ctrl2, b.`end`)
  let chord = lengthEuclid(b.start, b.`end`)
  if abs(len - chord) > BezierEpsilon:
    var left: Bezier
    let right = split(b, 0.5'f32, left)
    return bezLengthFn(left) + bezLengthFn(right)
  len

proc bezAtApproxFn(bz: Bezier; at, length: float32): float32 =
  var biggest = 1.0'f32
  var smallest = 0.0'f32
  var t = 0.5'f32
  if at <= 0.0'f32: return 0.0'f32
  if at >= length: return 1.0'f32
  while true:
    var left: Bezier
    discard split(bz, t, left)
    let len = bezLengthApproxFn(left)
    if abs(len - at) < BezierEpsilon or abs(smallest - biggest) < 1e-3'f32:
      break
    if len < at:
      smallest = t
      t = (t + biggest) * 0.5'f32
    else:
      biggest = t
      t = (smallest + t) * 0.5'f32
  t

proc bezAtFn(bz: Bezier; at, length: float32): float32 =
  var biggest = 1.0'f32
  var smallest = 0.0'f32
  var t = 0.5'f32
  if at <= 0.0'f32: return 0.0'f32
  if at >= length: return 1.0'f32
  while true:
    var left: Bezier
    discard split(bz, t, left)
    let len = bezLengthFn(left)
    if abs(len - at) < BezierEpsilon or abs(smallest - biggest) < 1e-3'f32:
      break
    if len < at:
      smallest = t
      t = (t + biggest) * 0.5'f32
    else:
      biggest = t
      t = (smallest + t) * 0.5'f32
  t

proc bezierLengthApprox*(p0, p1, p2, p3: LottiePoint): float32 =
  bezLengthApproxFn(Bezier(start:p0, ctrl1:p1, ctrl2:p2, `end`:p3))

proc bezierAtApprox*(p0,p1,p2,p3: LottiePoint; tLen, totalLen: float32): float32 =
  bezAtApproxFn(Bezier(start:p0, ctrl1:p1, ctrl2:p2, `end`:p3), tLen, totalLen)

proc bezierAngle(p0,p1,p2,p3: LottiePoint; t: float32): float32 =
  let b = Bezier(start:p0, ctrl1:p1, ctrl2:p2, `end`:p3)
  let pt = bezierAt(b, t)
  # derivative approximation
  let e = 0.0001'f32
  let t2 = min(1.0'f32, t + e)
  let pt2 = bezierAt(b, t2)
  radToDeg(arctan2(pt2.y - pt.y, pt2.x - pt.x))

proc interpVector*(f, n: LottieVectorFrame[LottiePoint]; frameNo: float32): LottiePoint =
  var t = (frameNo - f.no) / (n.no - f.no)
  if f.interpolator != nil: t = f.interpolator.progress(t)
  if f.hold:
    if t < 1.0'f32: return f.value
    else: return n.value
  if f.hasTangent:
    let p0 = f.value
    let p1 = f.value + f.outTangent
    let p2 = n.value + f.inTangent
    let p3 = n.value
    let len = if f.length > 0.0'f32: f.length else: bezierLengthApprox(p0,p1,p2,p3)
    let bt = bezierAtApprox(p0,p1,p2,p3, t * len, len)
    let b = Bezier(start:p0, ctrl1:p1, ctrl2:p2, `end`:p3)
    return bezierAt(b, bt)
  else:
    return lerp(f.value, n.value, t)

proc angleVector*(f, n: LottieVectorFrame[LottiePoint]; frameNo: float32): float32 =
  if not f.hasTangent:
    let dp = n.value - f.value
    return radToDeg(arctan2(dp.y, dp.x))
  var t = (frameNo - f.no) / (n.no - f.no)
  if f.interpolator != nil: t = f.interpolator.progress(t)
  let p0 = f.value
  let p1 = f.value + f.outTangent
  let p2 = n.value + f.inTangent
  let p3 = n.value
  let len = if f.length > 0.0'f32: f.length else: bezierLengthApprox(p0,p1,p2,p3)
  let b = Bezier(start:p0, ctrl1:p1, ctrl2:p2, `end`:p3)
  var bt = bezAtApproxFn(b, t * len, len)
  if bt >= 1.0'f32: bt = 0.99'f32
  elif bt <= 0.0'f32: bt = 0.01'f32
  b.angle(bt)

proc prepareVector*(f: var LottieVectorFrame[LottiePoint]; next: LottieVectorFrame[LottiePoint]) =
  if f.hasTangent:
    let p0 = f.value
    let p1 = f.value + f.outTangent
    let p2 = next.value + f.inTangent
    let p3 = next.value
    f.length = bezierLengthApprox(p0,p1,p2,p3)

# Generic property eval
proc eval*[F,V](p: LottieGenericProperty[F,V]; frameNo: float32): V =
  if not p.hasFrames or p.frames.len == 0:
    return p.value
  if p.frames.len == 1 or frameNo <= p.frames[0].no:
    return p.frames[0].value
  let last = p.frames.len - 1
  if frameNo >= p.frames[last].no:
    return p.frames[last].value
  # binary search
  var lo = 0
  var hi = last
  while lo <= hi:
    let mid = (lo + hi) div 2
    if p.frames[mid].no < frameNo: lo = mid + 1
    else: hi = mid - 1
  let key = max(0, hi)
  let f = p.frames[key]
  if abs(f.no - frameNo) < 0.00001'f32:
    return f.value
  let n = p.frames[key+1]
  when F is LottieScalarFrame[float32]:
    return interpScalar(f, n, frameNo)
  elif F is LottieScalarFrame[uint8]:
    return interpScalar(f, n, frameNo)
  elif F is LottieVectorFrame[LottiePoint]:
    return interpVector(f, n, frameNo)
  elif F is LottieScalarFrame[LottiePoint]:
    return interpScalar(f, n, frameNo)
  elif F is LottieScalarFrame[LottiePoint3]:
    return interpScalar(f, n, frameNo)
  elif F is LottieScalarFrame[LottieColor]:
    return interpScalar(f, n, frameNo)
  elif F is LottieScalarFrame[LottiePath]:
    return interpScalar(f, n, frameNo)
  else:
    return f.value

proc angle*(p: LottieGenericProperty[LottieVectorFrame[LottiePoint], LottiePoint]; frameNo: float32): float32 =
  if not p.hasFrames or p.frames.len <= 1:
    return 0.0'f32
  if frameNo <= p.frames[0].no:
    return angleVector(p.frames[0], p.frames[1], p.frames[0].no)
  let last = p.frames.len - 1
  if frameNo >= p.frames[last].no:
    return angleVector(p.frames[last - 1], p.frames[last], p.frames[last].no)
  var lo = 0
  var hi = last
  while lo <= hi:
    let mid = (lo + hi) div 2
    if p.frames[mid].no < frameNo: lo = mid + 1
    else: hi = mid - 1
  let key = max(0, hi)
  angleVector(p.frames[key], p.frames[key + 1], frameNo)

proc newScalarProp*[T](v: T): LottieGenericProperty[LottieScalarFrame[T], T] =
  result = LottieGenericProperty[LottieScalarFrame[T], T](value: v, hasFrames: false)

proc newVectorProp*(v: LottiePoint): LottieGenericProperty[LottieVectorFrame[LottiePoint], LottiePoint] =
  result = LottieGenericProperty[LottieVectorFrame[LottiePoint], LottiePoint](value: v, hasFrames: false)

proc newPoint3Prop*(v: LottiePoint3): LottieGenericProperty[LottieScalarFrame[LottiePoint3], LottiePoint3] =
  result = LottieGenericProperty[LottieScalarFrame[LottiePoint3], LottiePoint3](value: v, hasFrames: false)

proc newColorProp*(v: LottieColor): LottieGenericProperty[LottieScalarFrame[LottieColor], LottieColor] =
  result = LottieGenericProperty[LottieScalarFrame[LottieColor], LottieColor](value: v, hasFrames: false)

proc newPathProp*(v: LottiePath): LottieGenericProperty[LottieScalarFrame[LottiePath], LottiePath] =
  result = LottieGenericProperty[LottieScalarFrame[LottiePath], LottiePath](value: v, hasFrames: false)
