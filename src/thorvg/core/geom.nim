## Scalar helpers, Point, Matrix, BBox and Region operations.
##
## Ported from `src/common/tvgMath.h` and `tvgMath.cpp` (everything except
## Bezier, which lives in `bezier.nim`).
## Behaviour notes: all values are `float32` like the original. `==` on
## `Point` and `Matrix` compares with `FloatEpsilon` tolerance, as in C++.

import std/math
import ./types

const
  MathPi* = 3.14159265358979323846'f32
  MathPi2* = MathPi * 0.5'f32
  Math2Pi* = MathPi * 2.0'f32
  FloatEpsilon* = 1.0e-06'f32
  PathKappa* = 0.552284'f32
  FltMax* = 3.4028234663852886e+38'f32
  IdentityMatrix* = Matrix(e11: 1, e12: 0, e13: 0, e21: 0, e22: 1, e23: 0,
                           e31: 0, e32: 0, e33: 1)

# ---------------------------------------------------------------- scalars

func deg2rad*(degree: float32): float32 = degree * (MathPi / 180.0'f32)
func rad2deg*(radian: float32): float32 = radian * (180.0'f32 / MathPi)

func zero*(a: float32): bool = abs(a) <= FloatEpsilon
func equal*(a, b: float32): bool = zero(a - b)

func nearbyint*(x: float32): float32 =
  ## Round to nearest, ties to even (C `nearbyintf` in the default mode).
  let fl = floor(x)
  let diff = x - fl
  if diff < 0.5'f32: fl
  elif diff > 0.5'f32: fl + 1.0'f32
  elif fl mod 2.0'f32 == 0.0'f32: fl
  else: fl + 1.0'f32

func remap255*(val: float32): uint8 =
  ## Maps 0..1 to 0..255 (rounded), like `tvg::remap255<uint8_t>`.
  uint8(nearbyint(val * 255.0'f32))

func fastAtan2*(y, x: float32): float32 =
  ## Remez-polynomial approximation of atan2 (same coefficients as ThorVG).
  if y == 0.0'f32 and x == 0.0'f32: return 0.0'f32
  let ax = abs(x)
  let ay = abs(y)
  let a = min(ax, ay) / max(ax, ay)
  let s = a * a
  var r = ((-0.0464964749'f32 * s + 0.15931422'f32) * s - 0.327622764'f32) * s * a + a
  if ay > ax: r = 1.57079637'f32 - r
  if x < 0: r = 3.14159274'f32 - r
  if y < 0: -r else: r

func lerp*(a, b, t: float32): float32 = a + (b - a) * t

func lerp*(a, b: uint8, t: float32): uint8 =
  ## Interpolation clamped to 0..255 (truncating, as the original).
  uint8(clamp(int(float32(a) + (float32(b) - float32(a)) * t), 0, 255))

func lerp*(a, b: ColorStop, t: float32): ColorStop =
  ColorStop(offset: lerp(a.offset, b.offset, t),
            r: lerp(a.r, b.r, t), g: lerp(a.g, b.g, t),
            b: lerp(a.b, b.b, t), a: lerp(a.a, b.a, t))

# ---------------------------------------------------------------- Point

func pt*(x, y: float32): Point = Point(x: x, y: y)

func `+`*(a, b: Point): Point = Point(x: a.x + b.x, y: a.y + b.y)
func `-`*(a, b: Point): Point = Point(x: a.x - b.x, y: a.y - b.y)
func `-`*(a: Point): Point = Point(x: -a.x, y: -a.y)
func `+`*(a: Point, s: float32): Point = Point(x: a.x + s, y: a.y + s)
func `-`*(a: Point, s: float32): Point = Point(x: a.x - s, y: a.y - s)
func `*`*(a, b: Point): Point = Point(x: a.x * b.x, y: a.y * b.y)
func `*`*(a: Point, s: float32): Point = Point(x: a.x * s, y: a.y * s)
func `*`*(s: float32, a: Point): Point = Point(x: s * a.x, y: s * a.y)
func `/`*(a, b: Point): Point = Point(x: a.x / b.x, y: a.y / b.y)
func `/`*(a: Point, s: float32): Point = Point(x: a.x / s, y: a.y / s)
func `+=`*(a: var Point, b: Point) =
  a.x += b.x
  a.y += b.y
func `*=`*(a: var Point, s: float32) =
  a.x *= s
  a.y *= s

func zero*(p: Point): bool = zero(p.x) and zero(p.y)

func `==`*(a, b: Point): bool = equal(a.x, b.x) and equal(a.y, b.y)

func min*(a, b: Point): Point = Point(x: min(a.x, b.x), y: min(a.y, b.y))
func max*(a, b: Point): Point = Point(x: max(a.x, b.x), y: max(a.y, b.y))
func dot*(a, b: Point): float32 = a.x * b.x + a.y * b.y
func cross*(a, b: Point): float32 = a.x * b.y - b.x * a.y
func length2*(a: Point): float32 = a.x * a.x + a.y * a.y
func length*(a: Point): float32 = sqrt(a.x * a.x + a.y * a.y)

func length*(a, b: Point): float32 =
  ## Approximate distance (alpha max + beta min, error < 7%), as in ThorVG.
  let x = abs(b.x - a.x)
  let y = abs(b.y - a.y)
  if x > y: x + 0.375'f32 * y else: y + 0.375'f32 * x

func atan*(p: Point): float32 = fastAtan2(p.y, p.x)

func normalize*(p: var Point) =
  if zero(p): return
  let ilength = 1.0'f32 / sqrt(p.x * p.x + p.y * p.y)
  p.x *= ilength
  p.y *= ilength

func normal*(p1, p2: Point): Point =
  ## Unit normal (left-hand) of the segment p1 -> p2; zero if degenerate.
  let dir = p2 - p1
  let len = length(dir)
  if zero(len): return Point()
  let u = dir / len
  Point(x: -u.y, y: u.x)

func closed*(a, b: Point, tolerance: float32): bool =
  let dx = a.x - b.x
  let dy = a.y - b.y
  (dx * dx + dy * dy) < (tolerance * tolerance)

type Orientation* {.pure.} = enum
  Linear, Clockwise, CounterClockwise

func orientation*(p1, p2, p3: Point): Orientation =
  let val = cross(p2 - p1, p3 - p1)
  if zero(val): Orientation.Linear
  elif val > 0: Orientation.Clockwise
  else: Orientation.CounterClockwise

# ---------------------------------------------------------------- Matrix

func identity*(): Matrix = IdentityMatrix

func isIdentity*(m: Matrix): bool =
  m.e11 == 1.0'f32 and m.e12 == 0.0'f32 and m.e13 == 0.0'f32 and
    m.e21 == 0.0'f32 and m.e22 == 1.0'f32 and m.e23 == 0.0'f32 and
    m.e31 == 0.0'f32 and m.e32 == 0.0'f32 and m.e33 == 1.0'f32

func `*`*(l, r: Matrix): Matrix =
  Matrix(
    e11: l.e11 * r.e11 + l.e12 * r.e21 + l.e13 * r.e31,
    e12: l.e11 * r.e12 + l.e12 * r.e22 + l.e13 * r.e32,
    e13: l.e11 * r.e13 + l.e12 * r.e23 + l.e13 * r.e33,
    e21: l.e21 * r.e11 + l.e22 * r.e21 + l.e23 * r.e31,
    e22: l.e21 * r.e12 + l.e22 * r.e22 + l.e23 * r.e32,
    e23: l.e21 * r.e13 + l.e22 * r.e23 + l.e23 * r.e33,
    e31: l.e31 * r.e11 + l.e32 * r.e21 + l.e33 * r.e31,
    e32: l.e31 * r.e12 + l.e32 * r.e22 + l.e33 * r.e32,
    e33: l.e31 * r.e13 + l.e32 * r.e23 + l.e33 * r.e33)

func `==`*(l, r: Matrix): bool =
  equal(l.e11, r.e11) and equal(l.e12, r.e12) and equal(l.e13, r.e13) and
    equal(l.e21, r.e21) and equal(l.e22, r.e22) and equal(l.e23, r.e23) and
    equal(l.e31, r.e31) and equal(l.e32, r.e32) and equal(l.e33, r.e33)

func `*`*(p: Point, m: Matrix): Point =
  ## Transforms a point by a matrix.
  Point(x: p.x * m.e11 + p.y * m.e12 + m.e13,
        y: p.x * m.e21 + p.y * m.e22 + m.e23)

func `*=`*(p: var Point, m: Matrix) =
  p = p * m

func inverse*(m: Matrix, outM: var Matrix): bool =
  ## Computes the inverse; false if the matrix is singular.
  let det = m.e11 * (m.e22 * m.e33 - m.e32 * m.e23) -
            m.e12 * (m.e21 * m.e33 - m.e23 * m.e31) +
            m.e13 * (m.e21 * m.e32 - m.e22 * m.e31)
  if det == 0.0'f32: return false  # C++ tests isinf(1/det); debug builds trap float div by zero
  let invDet = 1.0'f32 / det
  if classify(invDet) == fcInf or classify(invDet) == fcNegInf: return false
  outM = Matrix(
    e11: (m.e22 * m.e33 - m.e32 * m.e23) * invDet,
    e12: (m.e13 * m.e32 - m.e12 * m.e33) * invDet,
    e13: (m.e12 * m.e23 - m.e13 * m.e22) * invDet,
    e21: (m.e23 * m.e31 - m.e21 * m.e33) * invDet,
    e22: (m.e11 * m.e33 - m.e13 * m.e31) * invDet,
    e23: (m.e21 * m.e13 - m.e11 * m.e23) * invDet,
    e31: (m.e21 * m.e32 - m.e31 * m.e22) * invDet,
    e32: (m.e31 * m.e12 - m.e11 * m.e32) * invDet,
    e33: (m.e11 * m.e22 - m.e21 * m.e12) * invDet)
  true

func rotate*(m: var Matrix, degree: float32) =
  ## Sets the rotation part of `m` (the original multiplies into e11..e22).
  if degree == 0.0'f32: return
  let radian = degree / 180.0'f32 * MathPi
  let cosVal = cos(radian)
  let sinVal = sin(radian)
  m.e12 = m.e11 * -sinVal
  m.e11 *= cosVal
  m.e21 = m.e22 * sinVal
  m.e22 *= cosVal

func scale*(m: var Matrix, p: Point) =
  m.e11 *= p.x
  m.e22 *= p.y

func scaleR*(m: var Matrix, p: Point) =
  if p.x != 1.0'f32:
    m.e11 *= p.x
    m.e21 *= p.x
  if p.y != 1.0'f32:
    m.e22 *= p.y
    m.e12 *= p.y

func translate*(m: var Matrix, p: Point) =
  m.e13 += p.x
  m.e23 += p.y

func translateR*(m: var Matrix, p: Point) =
  if p.x == 0.0'f32 and p.y == 0.0'f32: return
  m.e13 += p.x * m.e11 + p.y * m.e12
  m.e23 += p.x * m.e21 + p.y * m.e22

func radian*(m: Matrix): float32 = abs(fastAtan2(m.e21, m.e11))

func rightAngle*(m: Matrix): bool =
  let r = radian(m)
  zero(r) or zero(r - MathPi2) or zero(r - MathPi)

func skewed*(m: Matrix): bool = not zero(m.e21 + m.e12)

func scaling*(m: Matrix): float32 =
  let sx = m.e11 * m.e11 + m.e21 * m.e21
  let sy = m.e12 * m.e12 + m.e22 * m.e22
  sqrt(if sx > sy: sx else: sy)

# ---------------------------------------------------------------- BBox

func initBBox*(): BBox =
  ## An "empty" box that any point extends (min = +FLT_MAX, max = -FLT_MAX).
  BBox(min: Point(x: FltMax, y: FltMax), max: Point(x: -FltMax, y: -FltMax))

func inside*(b: BBox, p: Point): bool =
  p.x >= b.min.x and p.x <= b.max.x and p.y >= b.min.y and p.y <= b.max.y

func w*(b: BBox): float32 = b.max.x - b.min.x
func h*(b: BBox): float32 = b.max.y - b.min.y

# ---------------------------------------------------------------- Region

func initRegion*(xMin, yMin, xMax, yMax: int32): Region =
  Region(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)

func intersect*(l, r: Region): Region =
  ## Intersection; a disjoint result collapses to a zero-area region.
  result = Region(xMin: max(l.xMin, r.xMin), yMin: max(l.yMin, r.yMin),
                  xMax: min(l.xMax, r.xMax), yMax: min(l.yMax, r.yMax))
  if result.xMin > result.xMax: result.xMax = result.xMin
  if result.yMin > result.yMax: result.yMax = result.yMin

func add*(l, r: Region): Region =
  ## Union (bounding region) of two regions.
  Region(xMin: min(l.xMin, r.xMin), yMin: min(l.yMin, r.yMin),
         xMax: max(l.xMax, r.xMax), yMax: max(l.yMax, r.yMax))

func valid*(r: Region): bool = r.xMax > r.xMin and r.yMax > r.yMin
func invalid*(r: Region): bool = not valid(r)
func sw*(r: Region): int32 = r.xMax - r.xMin
func sh*(r: Region): int32 = r.yMax - r.yMin

func inside*(r: Region, p: Point): bool =
  p.x >= float32(r.xMin) and p.x < float32(r.xMax) and
    p.y >= float32(r.yMin) and p.y < float32(r.yMax)

func contained*(r, other: Region): bool =
  ## True if `r` fully contains `other`.
  r.xMin <= other.xMin and r.xMax >= other.xMax and
    r.yMin <= other.yMin and r.yMax >= other.yMax

func intersected*(r, other: Region): bool =
  other.xMin < r.xMax and other.xMax > r.xMin and
    other.yMin < r.yMax and other.yMax > r.yMin
