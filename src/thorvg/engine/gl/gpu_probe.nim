## Convexity probe, edge-crossing test and point-in-mesh tests of the GPU engines.
##
## Ported from `src/renderer/gpu_engine/tvgGpuCommon.cpp/.h` (second part). Pure Nim,
## float32, same operation order as the original (bit-exact oracle in
## `tests/gl/gpucommon_*`).
##
## `GpuConvexProbe` is a conservative triangle-fan safety check: default-construct one
## per tessellation pass (`GpuConvexProbe()` or `initConvexProbe()`), call
## `nextContour` on MoveTo, stream each contour edge with `addEdge(curr - prev)`, finish
## with `addContourClose(first - prev)` on Close, and read `probe.convex`.
## For cubic segments callers may pre-reject looping control polygons with
## `gpuEdgesCross(start, ctrl1, ctrl2, end)`.
##
## Mesh tests: C++ passes `const void* vertices` + a raw index pointer. Here the
## vertices are either `openArray[float32]` (packed x/y pairs; `stride` = floats per
## vertex, 2 for the packed GL/WG layout) or `openArray[Point]`; `indices` is a
## triangle list and `count` the number of indices to use (`-1` = all).

import ../../core/[types, geom]

{.push floatChecks: false.}

const
  MaxAxisDirChanges = 3'u8
  MaxCollinearReversals = 2'u8

type GpuConvexProbe* = object
  convex*: bool = true
  winding*: int8
  firstEdge*: Point
  prevEdge*: Point
  prevXDir*, prevYDir*: int8
  xDirChanges*, yDirChanges*: uint8
  reversals*: uint8
  contourHasEdges*: bool

func initConvexProbe*(): GpuConvexProbe = GpuConvexProbe()

func resetContour(p: var GpuConvexProbe) =
  p.firstEdge = Point()
  p.prevEdge = Point()
  p.prevXDir = 0
  p.prevYDir = 0
  p.xDirChanges = 0
  p.yDirChanges = 0
  p.reversals = 0
  p.contourHasEdges = false

func updateDir(p: var GpuConvexProbe, value: float32, axisX: bool) =
  var dir = 0'i8
  if not zero(value): dir = (if value > 0.0'f32: 1'i8 else: -1'i8)
  if dir == 0 or not p.convex: return
  let prevDir = if axisX: p.prevXDir else: p.prevYDir
  if prevDir != 0 and prevDir != dir:
    if axisX:
      inc p.xDirChanges
      if p.xDirChanges > MaxAxisDirChanges:
        p.convex = false
        return
    else:
      inc p.yDirChanges
      if p.yDirChanges > MaxAxisDirChanges:
        p.convex = false
        return
  if axisX: p.prevXDir = dir
  else: p.prevYDir = dir

func addEdge*(p: var GpuConvexProbe, edge: Point) =
  if zero(edge): return
  p.contourHasEdges = true
  if not p.convex: return

  if zero(p.firstEdge): p.firstEdge = edge

  p.updateDir(edge.x, true)
  p.updateDir(edge.y, false)
  if not p.convex: return

  if zero(p.prevEdge):
    p.prevEdge = edge
    return

  let turn = cross(p.prevEdge, edge)
  if zero(turn):
    if dot(p.prevEdge, edge) < 0.0'f32:
      inc p.reversals
      if p.reversals > MaxCollinearReversals: p.convex = false
  else:
    let sign = (if turn > 0.0'f32: 1'i8 else: -1'i8)
    if p.winding == 0: p.winding = sign
    elif sign != p.winding: p.convex = false

  p.prevEdge = edge

func nextContour*(p: var GpuConvexProbe) =
  if p.contourHasEdges: p.convex = false
  p.resetContour()

func addContourClose*(p: var GpuConvexProbe, edge: Point) =
  p.addEdge(edge)
  if p.convex and not zero(p.firstEdge): p.addEdge(p.firstEdge)

func orientSign(a, b, c: Point): int8 =
  let value = cross(b - a, c - a)
  if zero(value): 0'i8
  elif value > 0.0'f32: 1'i8
  else: -1'i8

func straddlesLine(a, b, c, d: Point): bool =
  orientSign(a, b, c) * orientSign(a, b, d) < 0

func gpuEdgesCross*(p0, p1, p2, p3: Point): bool =
  straddlesLine(p0, p1, p2, p3) and straddlesLine(p2, p3, p0, p1)

# ---------------------------------------------------------------- point tests

func gpuPointInTriangle*(p, a, b, c: Point): bool =
  let d1 = cross(p - a, p - b)
  let d2 = cross(p - b, p - c)
  let d3 = cross(p - c, p - a)
  not (((d1 < 0.0'f32) or (d2 < 0.0'f32) or (d3 < 0.0'f32)) and
       ((d1 > 0.0'f32) or (d2 > 0.0'f32) or (d3 > 0.0'f32)))

func gpuPointInQuad*(p: Point, triangle: array[6, Point]): bool =
  gpuPointInTriangle(p, triangle[0], triangle[1], triangle[2]) or
    gpuPointInTriangle(p, triangle[3], triangle[4], triangle[5])

func vertexAt(v: openArray[float32], i, stride: int): Point =
  Point(x: v[i * stride], y: v[i * stride + 1])

func vertexAt(v: openArray[Point], i, stride: int): Point = v[i]

func gpuPointInAnyMesh*[V: float32 | Point](p: Point, vertices: openArray[V],
    indices: openArray[uint32], count = -1, stride = 2): bool =
  ## True if `p` lies in any triangle of the triangle list.
  let n = if count < 0: indices.len else: count
  var i = 0
  while i + 2 < n:
    let p0 = vertexAt(vertices, int(indices[i]), stride)
    let p1 = vertexAt(vertices, int(indices[i + 1]), stride)
    let p2 = vertexAt(vertices, int(indices[i + 2]), stride)
    if gpuPointInTriangle(p, p0, p1, p2): return true
    i += 3
  false

func crossEdge(winding: var int32, p, p1, p2: Point) =
  if (p1.y < p.y) == (p2.y < p.y): return
  let intersectionX = (p2.x - p1.x) * (p.y - p1.y) / (p2.y - p1.y) + p1.x
  if intersectionX > p.x: winding += (if p2.y > p1.y: 1'i32 else: -1'i32)

func gpuPointInFillMesh*[V: float32 | Point](p: Point, vertices: openArray[V],
    indices: openArray[uint32], rule: FillRule, count = -1, stride = 2): bool =
  ## The fill mesh is the stencil geometry: a triangle fan per contour. Summing the
  ## signed edge crossings of every triangle gives the winding (the fan's inner edges
  ## cancel out); its parity is the even-odd result.
  var winding = 0'i32
  let n = if count < 0: indices.len else: count
  var i = 0
  while i + 2 < n:
    let p0 = vertexAt(vertices, int(indices[i]), stride)
    let p1 = vertexAt(vertices, int(indices[i + 1]), stride)
    let p2 = vertexAt(vertices, int(indices[i + 2]), stride)
    crossEdge(winding, p, p0, p1)
    crossEdge(winding, p, p1, p2)
    crossEdge(winding, p, p2, p0)
    i += 3
  if rule == FillRule.EvenOdd: winding mod 2 != 0 else: winding != 0

{.pop.}
