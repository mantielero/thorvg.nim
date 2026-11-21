## GPU path helpers shared by the GL (and WebGPU) engines: path simplification,
## arc segment count, conic gradient transform and transformed bounds.
##
## Ported from `src/renderer/gpu_engine/tvgGpuCommon.cpp/.h` (first part). Pure Nim,
## no GL. Every `float` of the original is `float32` and the order of the
## operations is the original one (bit-exact oracle: `tests/gl/gpucommon_*`).
##
## Public API (used by the tessellator unit G2b):
##   `gpuOptimize(input, matrix, wantLocal = true): GpuOptimizeResult`
##     simplifies `input` in transformed space (`result.transformed`) and, when
##     `wantLocal`, mirrors the same decisions into a local-space path
##     (`result.local`, the C++ `result.local != nullptr`). `thin` / `skipFill`
##     are the C++ flags of the same name.
##   `gpuArcSegmentsCnt(arcAngle, pixelRadius): uint32`
##   `gpuConicTransform(center, angle): Matrix`
##   `gpuTransformBounds(bounds, matrix): Region`
##
## Float checks are off (DECISIONS H2): like C++, degenerate input may produce
## inf/NaN silently instead of raising in debug builds.

import std/math
import ../../core/[types, geom, path]

{.push floatChecks: false.}

const
  PathOptPxTolerance* = 0.25'f32
  AaCoverageQuantum = 1.0'f32 / 256.0'f32  # 1 / (1 shl SW_AA_COVERAGE_BITS)
  MaxPixelSpan = 1.41421356237'f32
  FltMin = 1.17549435e-38'f32              # FLT_MIN (smallest normal), as in C++

type
  GpuOptimizeResult* = object
    transformed*: RenderPath  ## simplified path in transformed space
    local*: RenderPath        ## same decisions in local space (only if `wantLocal`)
    thin*: bool               ## use the thin-fill fallback
    skipFill*: bool           ## too thin to be visible: stroke only

  ThinPathTracker = object
    preAxisPoints: seq[Point]
    axisStart, axisVec: Point
    axisLen, axisLenInv, axisLenSqInv: float32
    minT, maxT, minDist, maxDist: float32
    ready, candidate: bool

  OptCtx = object
    matrix: Matrix
    outp, localOut: RenderPath
    wantLocal: bool
    lastOutT, lastInT, subpathStartT: Point
    drawableSubpathCnt: uint32
    subpathOpen, subpathHasSegment: bool
    tracker: ThinPathTracker

func toU32(x: float32): uint32 =
  ## C `static_cast<uint32_t>(float)` as compiled by gcc on x86-64 (via int64).
  if x >= -9.2233720368547758e18'f32 and x < 9.2233720368547758e18'f32:
    uint32(uint64(int64(x)) and 0xFFFFFFFF'u64)
  else: 0'u32

func toI32(x: float32): int32 =
  ## C `int32_t(float)` as compiled by gcc on x86-64 (`cvttss2si`).
  if x >= -2147483648.0'f32 and x < 2147483648.0'f32: int32(x) else: low(int32)

func cmin(a, b: float32): float32 {.inline.} = (if b < a: b else: a)  # std::min
func cmax(a, b: float32): float32 {.inline.} = (if a < b: b else: a)  # std::max

func gpuConicTransform*(center: Point, angle: float32): Matrix =
  let radian = deg2rad(angle)
  let c = cos(radian)
  let s = sin(radian)
  Matrix(e11: c, e12: s, e13: -(c * center.x + s * center.y),
         e21: -s, e22: c, e23: s * center.x - c * center.y,
         e31: 0.0'f32, e32: 0.0'f32, e33: 1.0'f32)

func gpuArcSegmentsCnt*(arcAngle, pixelRadius: float32): uint32 =
  if pixelRadius < FloatEpsilon: return 2
  const PxTolerance = 0.25'f32
  # Sagitta-based approximation: 1 - cos(t/2) ~ (t/2)^2/2, so t ~ 2 * sqrt(2 * s/r)
  let segmentAngle = 2.0'f32 * sqrt(2.0'f32 * PxTolerance / pixelRadius)
  toU32(ceil(abs(arcAngle) / segmentAngle)) + 1'u32

func gpuTransformBounds*(bounds: Region, matrix: Matrix): Region =
  if bounds.invalid: return bounds
  let lt = Point(x: float32(bounds.xMin), y: float32(bounds.yMin)) * matrix
  let lb = Point(x: float32(bounds.xMin), y: float32(bounds.yMax)) * matrix
  let rt = Point(x: float32(bounds.xMax), y: float32(bounds.yMin)) * matrix
  let rb = Point(x: float32(bounds.xMax), y: float32(bounds.yMax)) * matrix
  let mn = Point(x: cmin(cmin(lt.x, lb.x), cmin(rt.x, rb.x)),
                 y: cmin(cmin(lt.y, lb.y), cmin(rt.y, rb.y)))
  let mx = Point(x: cmax(cmax(lt.x, lb.x), cmax(rt.x, rb.x)),
                 y: cmax(cmax(lt.y, lb.y), cmax(rt.y, rb.y)))
  Region(xMin: toI32(floor(mn.x)), yMin: toI32(floor(mn.y)),
         xMax: toI32(ceil(mx.x)), yMax: toI32(ceil(mx.y)))

# ---------------------------------------------------------------- ThinPathTracker

func initThinTracker(): ThinPathTracker = ThinPathTracker(candidate: true)

proc clearPreAxisPoints(t: var ThinPathTracker) = t.preAxisPoints.setLen(0)

proc disable(t: var ThinPathTracker) =
  t.candidate = false
  t.ready = false
  t.clearPreAxisPoints()

proc remember(t: var ThinPathTracker, pt: Point) =
  if not t.candidate or t.ready: return
  t.preAxisPoints.add pt

proc update(t: var ThinPathTracker, pt: Point) =
  let offset = pt - t.axisStart
  let signedDist = cross(t.axisVec, offset) * t.axisLenInv
  if abs(signedDist) > PathOptPxTolerance:
    t.disable()
    return
  let tt = dot(offset, t.axisVec) * t.axisLenSqInv
  if tt < t.minT: t.minT = tt
  if tt > t.maxT: t.maxT = tt
  if signedDist < t.minDist: t.minDist = signedDist
  if signedDist > t.maxDist: t.maxDist = signedDist

proc flushPreAxisPoints(t: var ThinPathTracker) =
  # `update` may disable the tracker, which clears the list and ends the loop
  var i = 0
  while i < t.preAxisPoints.len:
    t.update(t.preAxisPoints[i])
    if not t.candidate: break
    inc i
  t.clearPreAxisPoints()

proc initAxis(t: var ThinPathTracker, start, finish: Point) =
  let vec = finish - start
  let vecLenSq = dot(vec, vec)
  t.axisStart = start
  t.axisVec = vec
  t.axisLen = sqrt(vecLenSq)
  t.axisLenInv = 1.0'f32 / t.axisLen
  t.axisLenSqInv = 1.0'f32 / vecLenSq
  t.minT = 0.0'f32
  t.maxT = 1.0'f32
  t.minDist = 0.0'f32
  t.maxDist = 0.0'f32
  t.ready = true
  t.flushPreAxisPoints()

proc trackLine(t: var ThinPathTracker, start, finish: Point, closed: bool) =
  if not t.candidate: return
  if not t.ready:
    if closed: t.remember(start)
    else: t.initAxis(start, finish)
    return
  t.update(finish)

proc trackClosedCubic(t: var ThinPathTracker, start, ctrl1, ctrl2, finish: Point) =
  if not t.candidate: return
  if not t.ready:
    t.remember(start)
    t.remember(ctrl1)
    t.remember(ctrl2)
    return
  t.update(ctrl1)
  t.update(ctrl2)
  t.update(finish)

proc trackFlatCubic(t: var ThinPathTracker, start, ctrl1, ctrl2, finish: Point) =
  if not t.candidate: return
  if not t.ready: t.initAxis(start, finish)
  else: t.update(finish)
  t.update(ctrl1)
  t.update(ctrl2)

proc trackClose(t: var ThinPathTracker, start, finish: Point, closed: bool) =
  t.trackLine(start, finish, closed)  # identical body in the original

func tooThin(t: ThinPathTracker): bool =
  ## Even a thin candidate is skipped if its strongest local SW AA coverage
  ## stays sub-quantum.
  let thinSpan = (t.maxT - t.minT) * t.axisLen
  let thinThickness = t.maxDist - t.minDist
  let localVisibleArea = thinThickness * (if thinSpan < MaxPixelSpan: thinSpan else: MaxPixelSpan)
  localVisibleArea < AaCoverageQuantum

# ---------------------------------------------------------------- gpuOptimize

type CubicCheck = object
  maxDist, minT, maxT, vecLen: float32

func point2Line(point, start, vec: Point, vecLenInv, vecLenSqInv: float32,
                c: var CubicCheck) =
  let offset = point - start
  let dist = abs(cross(vec, offset)) * vecLenInv
  if dist > c.maxDist: c.maxDist = dist
  let t = dot(offset, vec) * vecLenSqInv
  if t < c.minT: c.minT = t
  if t > c.maxT: c.maxT = t

func validateCubic(start, ctrl1, ctrl2, finish: Point): CubicCheck =
  ## vecLen is non-zero for the callers: closed points are handled before.
  let vec = finish - start
  result.vecLen = sqrt(vec.x * vec.x + vec.y * vec.y)
  let vecLenInv = 1.0'f32 / result.vecLen
  let vecLenSqInv = vecLenInv * vecLenInv
  result.maxDist = 0.0'f32
  result.minT = FltMax
  result.maxT = FltMin
  point2Line(ctrl1, start, vec, vecLenInv, vecLenSqInv, result)
  point2Line(ctrl2, start, vec, vecLenInv, vecLenSqInv, result)

func isFlatInSpan(c: CubicCheck): bool =
  let flat = c.maxDist <= PathOptPxTolerance
  let tEps = PathOptPxTolerance / c.vecLen
  let inSpan = (c.minT >= -tEps) and (c.maxT <= 1.0'f32 + tEps)
  flat and inSpan

proc finalizeSubpath(c: var OptCtx) =
  if not c.subpathHasSegment: return
  inc c.drawableSubpathCnt
  if c.drawableSubpathCnt > 1: c.tracker.disable()
  c.subpathHasSegment = false

proc addLineCmd(c: var OptCtx, local, transformed: Point) =
  c.outp.lineTo(transformed)
  if c.wantLocal: c.localOut.lineTo(local)
  c.lastOutT = transformed

proc trackThinCubic(c: var OptCtx, startT, ctrl1T, ctrl2T, endT: Point) =
  if closed(startT, endT, PathOptPxTolerance):
    c.tracker.trackClosedCubic(startT, ctrl1T, ctrl2T, endT)
    return
  if isFlatInSpan(validateCubic(startT, ctrl1T, ctrl2T, endT)):
    c.tracker.trackFlatCubic(startT, ctrl1T, ctrl2T, endT)
  else:
    c.tracker.disable()

proc processCubicTo(c: var OptCtx, p: openArray[Point], startOutT, startInT: Point): Point =
  ## `p` holds the three control points; returns the transformed end point.
  let ctrl1T = p[0] * c.matrix
  let ctrl2T = p[1] * c.matrix
  let endT = p[2] * c.matrix
  result = endT
  if c.tracker.candidate: c.trackThinCubic(startInT, ctrl1T, ctrl2T, endT)
  if closed(startOutT, endT, PathOptPxTolerance): return
  if isFlatInSpan(validateCubic(startOutT, ctrl1T, ctrl2T, endT)):
    c.subpathHasSegment = true
    c.addLineCmd(p[2], endT)
  else:
    c.outp.cubicTo(ctrl1T, ctrl2T, endT)
    if c.wantLocal: c.localOut.cubicTo(p[0], p[1], p[2])
    c.lastOutT = endT
    c.subpathHasSegment = true
    c.tracker.disable()

proc gpuOptimize*(input: RenderPath, matrix: Matrix, wantLocal = true): GpuOptimizeResult =
  ## Simplifies `input` in transformed space; with `wantLocal` the same decisions
  ## are mirrored into `result.local` for stroke tessellation.
  if input.empty: return
  var c = OptCtx(matrix: matrix, wantLocal: wantLocal, tracker: initThinTracker())
  var pi = 0
  for cmd in input.cmds:
    case cmd
    of PathCommand.MoveTo:
      c.finalizeSubpath()
      let pt = input.pts[pi]
      let ptT = pt * matrix
      c.outp.moveTo(ptT)
      if wantLocal: c.localOut.moveTo(pt)
      c.lastOutT = ptT
      c.lastInT = ptT
      c.subpathStartT = ptT
      c.subpathOpen = true
      inc pi
    of PathCommand.LineTo:
      let startInT = c.lastInT
      let pt = input.pts[pi]
      let ptT = pt * matrix
      let closedIn = closed(startInT, ptT, PathOptPxTolerance)
      if not closedIn: c.subpathHasSegment = true
      c.tracker.trackLine(startInT, ptT, closedIn)
      c.lastInT = ptT
      if not closed(c.lastOutT, ptT, PathOptPxTolerance): c.addLineCmd(pt, ptT)
      inc pi
    of PathCommand.CubicTo:
      let endT = c.processCubicTo(input.pts.toOpenArray(pi, pi + 2), c.lastOutT, c.lastInT)
      c.lastInT = endT
      pi += 3
    of PathCommand.Close:
      if c.subpathOpen:
        let closedIn = closed(c.lastInT, c.subpathStartT, PathOptPxTolerance)
        if not closedIn: c.subpathHasSegment = true
        c.tracker.trackClose(c.lastInT, c.subpathStartT, closedIn)
      c.outp.cmds.add PathCommand.Close
      if wantLocal: c.localOut.cmds.add PathCommand.Close
      c.lastOutT = c.subpathStartT
      c.lastInT = c.subpathStartT
  c.finalizeSubpath()
  result.transformed = move c.outp
  result.local = move c.localOut
  # thin means "use thin fill fallback", not just "the geometry is narrow".
  result.thin = c.tracker.candidate and c.tracker.ready and c.drawableSubpathCnt == 1
  if result.thin and c.tracker.tooThin():
    # Too thin for fallback: keep the path for strokes, but skip the fill.
    result.thin = false
    result.skipFill = true

{.pop.}
