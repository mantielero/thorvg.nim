## Vector path container (`RenderPath`): command list + point list.
##
## Ported from `RenderPath` in `src/renderer/tvgRender.h` / `tvgRender.cpp`.
## `Array<T>` became `seq[T]`. Trim-path lives in `trim.nim`.

import ./[types, geom, bezier]

type RenderPath* = object
  cmds*: seq[PathCommand]
  pts*: seq[Point]

func empty*(p: RenderPath): bool = p.pts.len == 0

func clear*(p: var RenderPath) =
  p.pts.setLen(0)
  p.cmds.setLen(0)

func close*(p: var RenderPath) =
  ## Closes the sub-path (never twice in a row).
  if p.cmds.len > 0 and p.cmds[^1] == PathCommand.Close: return
  p.cmds.add PathCommand.Close

func moveTo*(p: var RenderPath, pt: Point) =
  p.pts.add pt
  p.cmds.add PathCommand.MoveTo

func lineTo*(p: var RenderPath, pt: Point) =
  p.pts.add pt
  p.cmds.add PathCommand.LineTo

func cubicTo*(p: var RenderPath, c1, c2, e: Point) =
  p.pts.add c1
  p.pts.add c2
  p.pts.add e
  p.cmds.add PathCommand.CubicTo

func point*(p: RenderPath, progress: float32): Point =
  ## Point at a relative position (0..1) along the path length.
  if progress <= 0.0'f32: return p.pts[0]
  if progress >= 1.0'f32: return p.pts[^1]
  let pleng = pathLength(p.cmds, p.pts) * progress
  var cleng = 0.0'f32
  var pi = 0
  var curr, start: Point
  for c in p.cmds:
    case c
    of PathCommand.MoveTo:
      curr = p.pts[pi]
      start = curr
      inc pi
    of PathCommand.LineTo:
      let nxt = p.pts[pi]
      let segLen = length(curr, nxt)
      if cleng + segLen >= pleng:
        return curr + (nxt - curr) * ((pleng - cleng) / segLen)
      cleng += segLen
      curr = p.pts[pi]
      inc pi
    of PathCommand.CubicTo:
      let bz = initBezier(curr, p.pts[pi], p.pts[pi + 1], p.pts[pi + 2])
      let segLen = length(bz)
      if cleng + segLen >= pleng:
        return bz.at((pleng - cleng) / segLen)
      cleng += segLen
      curr = p.pts[pi + 2]
      pi += 3
    of PathCommand.Close:
      let segLen = length(curr, start)
      if cleng + segLen >= pleng:
        return curr + (start - curr) * ((pleng - cleng) / segLen)
      cleng += segLen
      curr = start
  curr

proc addCircle*(p: var RenderPath, cx, cy, rx, ry: float32, cw: bool) =
  ## Appends an ellipse made of four cubic curves (starts at the top).
  let rxK = rx * PathKappa
  let ryK = ry * PathKappa
  p.cmds.add [PathCommand.MoveTo, PathCommand.CubicTo, PathCommand.CubicTo,
              PathCommand.CubicTo, PathCommand.CubicTo, PathCommand.Close]
  const fwd = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
  const rev = [0, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 12]
  let idx = if cw: fwd else: rev
  var q: array[13, Point]
  q[idx[0]] = pt(cx, cy - ry)
  q[idx[1]] = pt(cx + rxK, cy - ry)
  q[idx[2]] = pt(cx + rx, cy - ryK)
  q[idx[3]] = pt(cx + rx, cy)
  q[idx[4]] = pt(cx + rx, cy + ryK)
  q[idx[5]] = pt(cx + rxK, cy + ry)
  q[idx[6]] = pt(cx, cy + ry)
  q[idx[7]] = pt(cx - rxK, cy + ry)
  q[idx[8]] = pt(cx - rx, cy + ryK)
  q[idx[9]] = pt(cx - rx, cy)
  q[idx[10]] = pt(cx - rx, cy - ryK)
  q[idx[11]] = pt(cx - rxK, cy - ry)
  q[idx[12]] = pt(cx, cy - ry)
  p.pts.add q

proc addRect*(p: var RenderPath, x, y, w, h: float32, rx, ry: float32, cw: bool) =
  ## Appends a rectangle, sharp when rx and ry are ~0, rounded otherwise.
  if zero(rx) and zero(ry):
    p.cmds.add [PathCommand.MoveTo, PathCommand.LineTo, PathCommand.LineTo,
                PathCommand.LineTo, PathCommand.Close]
    var q: array[4, Point]
    q[0] = pt(x + w, y)
    q[2] = pt(x, y + h)
    if cw:
      q[1] = pt(x + w, y + h)
      q[3] = pt(x, y)
    else:
      q[1] = pt(x, y)
      q[3] = pt(x + w, y + h)
    p.pts.add q
    return

  let rx = min(rx, w * 0.5'f32)
  let ry = min(ry, h * 0.5'f32)
  let hr = pt(rx * PathKappa, ry * PathKappa)
  let line = if cw: PathCommand.LineTo else: PathCommand.CubicTo
  let cubic = if cw: PathCommand.CubicTo else: PathCommand.LineTo
  p.cmds.add [PathCommand.MoveTo, line, cubic, line, cubic, line, cubic,
              line, cubic, PathCommand.Close]
  # Counter-clockwise reverses the point order, keeping the endpoints fixed.
  const reversed = [0, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
  const natural = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  let idx = if cw: natural else: reversed
  var q: array[17, Point]
  q[0] = pt(x + w, y + ry)
  q[idx[1]] = pt(x + w, y + h - ry)
  q[idx[2]] = pt(x + w, y + h - ry + hr.y)
  q[idx[3]] = pt(x + w - rx + hr.x, y + h)
  q[idx[4]] = pt(x + w - rx, y + h)
  q[idx[5]] = pt(x + rx, y + h)
  q[idx[6]] = pt(x + rx - hr.x, y + h)
  q[idx[7]] = pt(x, y + h - ry + hr.y)
  q[idx[8]] = pt(x, y + h - ry)
  q[idx[9]] = pt(x, y + ry)
  q[idx[10]] = pt(x, y + ry - hr.y)
  q[idx[11]] = pt(x + rx - hr.x, y)
  q[idx[12]] = pt(x + rx, y)
  q[idx[13]] = pt(x + w - rx, y)
  q[idx[14]] = pt(x + w - rx + hr.x, y)
  q[idx[15]] = pt(x + w, y + ry - hr.y)
  q[16] = pt(x + w, y + ry)
  p.pts.add q

func bounds*(p: RenderPath, box: var BBox, m: Matrix): bool =
  ## Bounding box of the transformed path; false for an empty/invalid path.
  if p.cmds.len == 0 or p.cmds[0] == PathCommand.CubicTo: return false
  box = initBBox()
  proc assign(q: Point, box: var BBox) =
    if q.x < box.min.x: box.min.x = q.x
    if q.y < box.min.y: box.min.y = q.y
    if q.x > box.max.x: box.max.x = q.x
    if q.y > box.max.y: box.max.y = q.y
  var pi = 0
  for ci, c in p.cmds:
    case c
    of PathCommand.MoveTo:
      if ci + 1 < p.cmds.len:
        let nxt = p.cmds[ci + 1]
        if nxt == PathCommand.LineTo or nxt == PathCommand.CubicTo:
          assign(p.pts[pi] * m, box)
      inc pi
    of PathCommand.LineTo:
      assign(p.pts[pi] * m, box)
      inc pi
    of PathCommand.CubicTo:
      bezier.bounds(box, p.pts[pi - 1] * m, p.pts[pi] * m, p.pts[pi + 1] * m,
                    p.pts[pi + 2] * m)
      pi += 3
    of PathCommand.Close: discard
  true

func bounds*(p: RenderPath, box: var BBox): bool =
  ## Same as `bounds(p, box, m)` with the identity matrix.
  bounds(p, box, identity())
