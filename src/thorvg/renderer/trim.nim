## Trim path: keeps only the `begin..end` portion of a `RenderPath`.
##
## Ported from `RenderTrimPath::trim` in `src/renderer/tvgRender.cpp`.
## The C++ code walks raw `PathCommand*`/`Point*` cursors; here the cursors are
## absolute indices into the whole `cmds`/`pts` arrays (a sub-path may read the
## point before its first one, exactly like the original `pts - 1`).
## Divisions are guarded explicitly (DECISIONS.md H2, D-trim1).

import std/math
import ../core/[types, geom, bezier, path]
import ./render

const Epsilon = 1e-4'f32

type
  Line = object
    pt1, pt2: Point

  Walker = object
    ## Cursor over the source path (the C++ `cmds`/`pts` pointers).
    ci, pi: int
    moveTo, moveToTrimmed: Point

func exactLength(l: Line): float32 =
  let dx = l.pt2.x - l.pt1.x
  let dy = l.pt2.y - l.pt1.y
  sqrt(dx * dx + dy * dy)

func split(l: Line, at: float32, left, right: var Line) =
  ## Splits the segment at the distance `at` from `pt1`.
  let len = l.exactLength()
  # A zero-length segment never reaches this point (trimming skips it); C++ would
  # produce NaN here, the port keeps `pt1` instead (D-trim1).
  let dx = if len == 0.0'f32: 0.0'f32 else: ((l.pt2.x - l.pt1.x) / len) * at
  let dy = if len == 0.0'f32: 0.0'f32 else: ((l.pt2.y - l.pt1.y) / len) * at
  left.pt1 = l.pt1
  left.pt2.x = left.pt1.x + dx
  left.pt2.y = left.pt1.y + dy
  right.pt1 = left.pt2
  right.pt2 = l.pt2

func segLength(cmd: PathCommand, pts: openArray[Point], pi: int, moveTo: Point): float32 =
  case cmd
  of PathCommand.MoveTo: 0.0'f32
  of PathCommand.LineTo: length(pts[pi - 1], pts[pi])
  of PathCommand.CubicTo:
    length(initBezier(pts[pi - 1], pts[pi], pts[pi + 1], pts[pi + 2]))
  of PathCommand.Close: length(pts[pi - 1], moveTo)

func totalLength(cmds: openArray[PathCommand], pts: openArray[Point], ci0, cnt, pi0,
                 ptsCnt: int): float32 =
  ## `tvg::length(cmds, cmdsCnt, pts, ptsCnt)` over a sub-range.
  if ptsCnt < 2: return 0.0'f32
  var start = pts[pi0]
  var pi = pi0
  for ci in ci0 ..< ci0 + cnt:
    case cmds[ci]
    of PathCommand.Close:
      result += length(pts[pi - 1], start)
    of PathCommand.MoveTo:
      start = pts[pi]
      inc pi
    of PathCommand.LineTo:
      result += length(pts[pi - 1], pts[pi])
      inc pi
    of PathCommand.CubicTo:
      result += length(initBezier(pts[pi - 1], pts[pi], pts[pi + 1], pts[pi + 2]))
      pi += 3

proc pushMoveTo(output: var RenderPath, p: Point) =
  output.pts.add p
  output.cmds.add PathCommand.MoveTo

proc trimAt(cmd: PathCommand, pts: openArray[Point], pi: int, moveTo: var Point,
            at1, at2: float32, start: bool, output: var RenderPath) =
  ## Emits the part of the current segment between `at1` and `at1 + at2`.
  case cmd
  of PathCommand.LineTo, PathCommand.Close:
    var tmp, left, right: Line
    let target = if cmd == PathCommand.Close: moveTo else: pts[pi]
    Line(pt1: pts[pi - 1], pt2: target).split(at1, left, tmp)
    tmp.split(at2, left, right)
    if start:
      output.pushMoveTo(left.pt1)
      moveTo = left.pt1
    output.lineTo(left.pt2)
  of PathCommand.CubicTo:
    var tmp, left, right: Bezier
    initBezier(pts[pi - 1], pts[pi], pts[pi + 1], pts[pi + 2]).split(at1, left, tmp)
    tmp.split(at2, left, right)
    if start:
      moveTo = left.start
      output.pushMoveTo(left.start)
    output.cubicTo(left.ctrl1, left.ctrl2, left.`end`)
  of PathCommand.MoveTo: discard

proc addWhole(cmd: PathCommand, pts: openArray[Point], pi: int, moveTo: Point,
              start: var bool, output: var RenderPath) =
  ## Copies the current segment unchanged.
  case cmd
  of PathCommand.MoveTo:
    output.pushMoveTo(pts[pi])
    start = false
  of PathCommand.LineTo:
    if start: output.pushMoveTo(pts[pi - 1])
    output.lineTo(pts[pi])
    start = false
  of PathCommand.CubicTo:
    if start: output.pushMoveTo(pts[pi - 1])
    output.cubicTo(pts[pi], pts[pi + 1], pts[pi + 2])
    start = false
  of PathCommand.Close:
    if start: output.pushMoveTo(pts[pi - 1])
    output.lineTo(moveTo)
    start = true

proc shift(w: var Walker, cmd: PathCommand, pts: openArray[Point]) =
  case cmd
  of PathCommand.MoveTo:
    w.moveTo = pts[w.pi]
    w.moveToTrimmed = pts[w.pi]
    inc w.pi
  of PathCommand.LineTo: inc w.pi
  of PathCommand.CubicTo: w.pi += 3
  of PathCommand.Close: discard
  inc w.ci

proc trimPath(cmds: openArray[PathCommand], pts: openArray[Point], ci0, cnt, pi0: int,
              trimStart, trimEnd: float32, output: var RenderPath, connect = false) =
  # A lone `Close` after the last point has no point to read (UB in C++): use the origin.
  let first = if pi0 < pts.len: pts[pi0] else: Point()
  var w = Walker(ci: ci0, pi: pi0, moveTo: first, moveToTrimmed: first)
  var len = 0.0'f32
  var start = not connect

  for _ in 0 ..< cnt:
    let cmd = cmds[w.ci]
    let dLen = segLength(cmd, pts, w.pi, w.moveTo)

    # Very short segments are skipped: Bezier subdivision and length calculation
    # (1e-2) are finite-precision, so trimming could yield zero-length pieces.
    if len <= trimStart:
      if len + dLen > trimEnd:
        # cut the segment at the beginning and at the end
        trimAt(cmd, pts, w.pi, w.moveToTrimmed, trimStart - len, trimEnd - trimStart,
               start, output)
        start = false
      elif len + dLen > trimStart + Epsilon:
        # cut the segment at the beginning
        trimAt(cmd, pts, w.pi, w.moveToTrimmed, trimStart - len, len + dLen - trimStart,
               start, output)
        start = false
    elif len <= trimEnd - Epsilon:
      if len + dLen > trimEnd:
        # cut the segment at the end
        trimAt(cmd, pts, w.pi, w.moveTo, 0.0'f32, trimEnd - len, start, output)
        start = true
      elif len + dLen > trimStart + Epsilon:
        addWhole(cmd, pts, w.pi, w.moveTo, start, output)

    len += dLen
    w.shift(cmd, pts)

proc trimRange(cmds: openArray[PathCommand], pts: openArray[Point], ci0, cnt, pi0, ptsCnt: int,
               begin, `end`: float32, connect: bool, output: var RenderPath) =
  let total = totalLength(cmds, pts, ci0, cnt, pi0, ptsCnt)
  let trimStart = begin * total
  let trimEnd = `end` * total

  if begin >= `end`:
    let before = output.cmds.len
    trimPath(cmds, pts, ci0, cnt, pi0, trimStart, total, output)
    # nothing to connect to when the first part is empty
    trimPath(cmds, pts, ci0, cnt, pi0, 0.0'f32, trimEnd, output,
             connect and output.cmds.len > before)
  else:
    trimPath(cmds, pts, ci0, cnt, pi0, trimStart, trimEnd, output)

func normalizeRange(begin, `end`: var float32) =
  ## Wraps the range into 0..1 and orders it (loop when it crosses the origin).
  var loop = true
  if begin > 1.0'f32 and `end` > 1.0'f32: loop = false
  if begin < 0.0'f32 and `end` < 0.0'f32: loop = false
  if begin >= 0.0'f32 and begin <= 1.0'f32 and `end` >= 0.0'f32 and `end` <= 1.0'f32:
    loop = false

  if begin > 1.0'f32: begin -= 1.0'f32
  if begin < 0.0'f32: begin += 1.0'f32
  if `end` > 1.0'f32: `end` -= 1.0'f32
  if `end` < 0.0'f32: `end` += 1.0'f32

  if (loop and begin < `end`) or (not loop and begin > `end`): swap(begin, `end`)

proc trim*(t: RenderTrimPath, input: RenderPath, output: var RenderPath): bool =
  ## Appends the trimmed `input` to `output`; false when nothing was produced.
  if input.pts.len < 2 or zero(t.begin - t.`end`): return false

  var begin = t.begin
  var en = t.`end`
  normalizeRange(begin, en)

  if t.simultaneous:
    var startCi, startPi, ci, pi = 0
    # Trims the sub-path collected since the last flush.
    template flush() =
      if startCi != ci:
        trimRange(input.cmds, input.pts, startCi, ci - startCi, startPi, pi - startPi,
                  begin, en, input.cmds[ci - 1] == PathCommand.Close, output)
    while ci < input.cmds.len:
      case input.cmds[ci]
      of PathCommand.MoveTo:
        flush()
        startPi = pi
        startCi = ci
        inc pi
        inc ci
      of PathCommand.LineTo:
        inc pi
        inc ci
      of PathCommand.CubicTo:
        pi += 3
        inc ci
      of PathCommand.Close:
        inc ci
        flush()
        startPi = pi
        startCi = ci
    flush()
  else:
    trimRange(input.cmds, input.pts, 0, input.cmds.len, 0, input.pts.len, begin, en, false,
              output)

  output.pts.len >= 2
