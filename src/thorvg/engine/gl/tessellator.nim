## Fill tessellator of the GL engine (`BWTessellator` of `tvgGlTessellator.cpp`).
##
## API:
##   `var t = initBWTessellator()`
##   `t.tessellate(path)`   one triangle fan per contour (stencil geometry) into `t.buffer`
##   `t.bounds(): Region`   integer bounds of the vertices
##   `t.convex`             the probe found a single convex contour (no stencil pass needed)
##
## The tessellator owns its buffer (the C++ keeps a pointer): `g.fill = move t.buffer`.
## The stroke tessellator `Stroker` lives in `tess_stroke` and is re-exported from here.
## float32 everywhere, original operation order (bit-exact oracle: `tests/gl/geometry_compare.ps1`).

import std/math
import ../../core/[types, geom, path, bezier]
import ./[gl_common, gpu_probe]
import ./tess_stroke
export tess_stroke

{.push floatChecks: false.}

type BWTessellator* = object
  buffer*: GlGeometryBuffer
  convex*: bool
  bbox: BBox

func initBWTessellator*(): BWTessellator = BWTessellator(convex: true)

func pushVertex*(t: var BWTessellator, x, y: float32): uint32 =
  result = uint32(t.buffer.vertex.len div 2)
  t.buffer.vertex.add x
  t.buffer.vertex.add y
  if result == 0:
    t.bbox.min = Point(x: x, y: y)
    t.bbox.max = t.bbox.min
  else:
    t.bbox = BBox(min: Point(x: stdMin(t.bbox.min.x, x), y: stdMin(t.bbox.min.y, y)),
                  max: Point(x: stdMax(t.bbox.max.x, x), y: stdMax(t.bbox.max.y, y)))

func pushTriangle*(t: var BWTessellator, a, b, c: uint32) =
  t.buffer.index.add a
  t.buffer.index.add b
  t.buffer.index.add c

func bounds*(t: BWTessellator): Region =
  Region(xMin: toI32(floor(t.bbox.min.x)), yMin: toI32(floor(t.bbox.min.y)),
         xMax: toI32(ceil(t.bbox.max.x)), yMax: toI32(ceil(t.bbox.max.y)))

func tessellate*(t: var BWTessellator, path: RenderPath) =
  if path.pts.len <= 2: return

  var firstIndex, prevIndex = 0'u32
  var firstPt, prevPt = Point()
  var probe = GpuConvexProbe()
  var contourClosed = false
  var pi = 0

  func finishContour(probe: var GpuConvexProbe, closed: var bool, prevIndex: uint32,
                     firstPt, prevPt: Point) =
    if prevIndex == 0 or closed: return
    probe.addContourClose(firstPt - prevPt)
    closed = true

  for cmd in path.cmds:
    case cmd
    of PathCommand.MoveTo:
      finishContour(probe, contourClosed, prevIndex, firstPt, prevPt)
      probe.nextContour()
      let p = path.pts[pi]
      firstIndex = t.pushVertex(p.x, p.y)
      firstPt = p
      prevPt = p
      prevIndex = 0
      contourClosed = false
      inc pi
    of PathCommand.LineTo:
      let p = path.pts[pi]
      let edge = p - prevPt
      if prevIndex == 0:
        prevIndex = t.pushVertex(p.x, p.y)
        probe.addEdge(edge)
      else:
        probe.addEdge(edge)
        let currIndex = t.pushVertex(p.x, p.y)
        t.pushTriangle(firstIndex, prevIndex, currIndex)
        prevIndex = currIndex
      prevPt = p
      inc pi
    of PathCommand.CubicTo:
      let curve = initBezier(path.pts[pi - 1], path.pts[pi], path.pts[pi + 1], path.pts[pi + 2])
      if probe.convex and gpuEdgesCross(curve.start, curve.ctrl1, curve.ctrl2, curve.`end`):
        probe.convex = false

      var stepCount = curve.segments()
      if stepCount <= 1: stepCount = 2
      let step = 1.0'f32 / float32(stepCount)
      var curvePrevPt = prevPt
      for s in 1'u32 .. stepCount:
        let p = curve.at(step * float32(s))
        probe.addEdge(p - curvePrevPt)
        let currIndex = t.pushVertex(p.x, p.y)
        curvePrevPt = p
        if prevIndex == 0: prevIndex = currIndex
        else:
          t.pushTriangle(firstIndex, prevIndex, currIndex)
          prevIndex = currIndex
      prevPt = curve.`end`
      pi += 3
    of PathCommand.Close:
      finishContour(probe, contourClosed, prevIndex, firstPt, prevPt)

  finishContour(probe, contourClosed, prevIndex, firstPt, prevPt)
  t.convex = probe.convex

{.pop.}
