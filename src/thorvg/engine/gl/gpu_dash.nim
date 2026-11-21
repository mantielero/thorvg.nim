## Dashed stroke generation for the GPU engines (`gpuStrokeDash`).
##
## Ported from `StrokeDashPath` / `gpuStrokeDash` in
## `src/renderer/gpu_engine/tvgGpuCommon.cpp`. NOT the same algorithm as
## `engine/cpu/dash.nim`: the GPU version emits closed dashes that wrap over the
## start point as one contour, and can output a dot for zero-length dashes.
## Pure Nim, float32, same operation order as C++ (bit-exact oracle in
## `tests/gl/gpucommon_*`).
##
## API: `gpuStrokeDash(rs, matrix, applyTransform, output): bool` appends the dashed
## path to `output` (like the C++ `RenderPath& out`) and returns false when the shape
## has no dash (or the trimmed path is empty). `applyTransform` + `matrix` replace the
## C++ `const Matrix* transform` (nullptr -> false); an identity matrix is not applied.
## The overload without `output` returns `(ok, path)`.
##
## C++ lambdas + template `segment<Segment>` became a generic proc over `Line` /
## `Bezier`. Float checks are off (H2).

import std/[math, options]
import ../../core/[types, geom, bezier, path]
import ../../renderer/[render, trim]

{.push floatChecks: false.}

const
  DashPatternThreshold* = 0.001'f32   ## `DASH_PATTERN_THRESHOLD`
  DashEndpointTolerance = DashPatternThreshold
  MinCurrLenThreshold = 0.1'f32

type
  Line = object
    pt1, pt2: Point

  PatternState = object
    idx: int
    offset: float32
    gap: bool

  SubpathState = object
    closed, closeEndsAtStart: bool

  PieceRange = object
    cmdBegin, cmdEnd, ptBegin, ptEnd: int

  StrokeDash = object
    dash: RenderDash
    curLen: float32
    curIdx: int
    curPos: Point
    opGap, move: bool
    matrix: Matrix
    applyTransform: bool

func patternState(dash: RenderDash): PatternState =
  result.offset = dash.offset
  if zero(dash.offset): return
  let count = dash.pattern.len
  let oddPattern = count and 1
  let total = if oddPattern != 0: dash.length * 2.0'f32 else: dash.length
  result.offset = result.offset mod total
  if result.offset < 0.0'f32: result.offset += total
  let patternCount = count * (oddPattern + 1)
  for i in 0 ..< patternCount:
    let curPattern = dash.pattern[result.idx]
    if result.offset < curPattern: break
    result.offset -= curPattern
    result.gap = not result.gap
    inc result.idx
    if result.idx == count: result.idx = 0

# ---------------------------------------------------------------- pieces

func appendDashedCommand(dst: var RenderPath, src: RenderPath, cmd: PathCommand,
                         ptIdx: var int, skipMoveTo: bool) =
  case cmd
  of PathCommand.MoveTo:
    let pt = src.pts[ptIdx]
    inc ptIdx
    if not skipMoveTo: dst.moveTo(pt)
  of PathCommand.LineTo:
    dst.lineTo(src.pts[ptIdx])
    inc ptIdx
  of PathCommand.CubicTo:
    dst.cubicTo(src.pts[ptIdx], src.pts[ptIdx + 1], src.pts[ptIdx + 2])
    ptIdx += 3
  of PathCommand.Close: discard

func appendDashedPiece(dst: var RenderPath, src: RenderPath, piece: PieceRange,
                       skipMoveTo: bool) =
  var ptIdx = piece.ptBegin
  for i in piece.cmdBegin ..< piece.cmdEnd:
    appendDashedCommand(dst, src, src.cmds[i], ptIdx, skipMoveTo and i == piece.cmdBegin)

func collectDashedPieces(subOut: RenderPath, pieces: var seq[PieceRange]) =
  var ptIdx = 0
  var pieceCmdBegin = -1  # UINT32_MAX in C++
  var piecePtBegin = 0
  var pieceHasDraw = false
  for i in 0 ..< subOut.cmds.len:
    if subOut.cmds[i] == PathCommand.MoveTo:
      if pieceCmdBegin != -1 and pieceHasDraw:
        pieces.add PieceRange(cmdBegin: pieceCmdBegin, cmdEnd: i, ptBegin: piecePtBegin,
                              ptEnd: ptIdx)
      pieceCmdBegin = i
      piecePtBegin = ptIdx
      pieceHasDraw = false
    else:
      pieceHasDraw = true
    if subOut.cmds[i] == PathCommand.CubicTo: ptIdx += 3
    elif subOut.cmds[i] != PathCommand.Close: ptIdx += 1
  if pieceCmdBegin != -1 and pieceHasDraw:
    pieces.add PieceRange(cmdBegin: pieceCmdBegin, cmdEnd: subOut.cmds.len,
                          ptBegin: piecePtBegin, ptEnd: ptIdx)

func resetDashedSubpath(subOut: var RenderPath, state: var SubpathState) =
  subOut.clear()
  state = SubpathState()

func appendDashedCommands(outp: var RenderPath, subOut: RenderPath) =
  outp.cmds.add subOut.cmds
  outp.pts.add subOut.pts

func prepareDashedPieces(subOut: var RenderPath, state: var SubpathState,
                         pieces: var seq[PieceRange]): bool =
  pieces.setLen(0)
  if subOut.cmds.len == 0:
    resetDashedSubpath(subOut, state)
    return false
  collectDashedPieces(subOut, pieces)
  if pieces.len > 0: return true
  resetDashedSubpath(subOut, state)
  false

func closedDashedContour(subOut: RenderPath, pieces: seq[PieceRange],
                         mappedStart: Point): bool =
  let firstStartsAtClose = closed(subOut.pts[pieces[0].ptBegin], mappedStart,
                                  DashEndpointTolerance)
  let lastEndsAtClose = closed(subOut.pts[pieces[^1].ptEnd - 1], mappedStart,
                               DashEndpointTolerance)
  firstStartsAtClose and lastEndsAtClose

func appendClosedDashedSubpath(outp: var RenderPath, subOut: RenderPath,
                               pieces: seq[PieceRange], mappedStart: Point,
                               state: SubpathState): bool =
  if not state.closed: return false
  if not closedDashedContour(subOut, pieces, mappedStart): return false
  if pieces.len == 1:
    appendDashedPiece(outp, subOut, pieces[0], false)
    outp.close()
    return true
  if not state.closeEndsAtStart: return false
  # Closed dash wraps across the original start point: emit it as one contour so the
  # stroker can join there.
  appendDashedPiece(outp, subOut, pieces[^1], false)
  appendDashedPiece(outp, subOut, pieces[0], true)
  for i in 1 ..< pieces.len - 1:
    appendDashedPiece(outp, subOut, pieces[i], false)
  true

func appendDashedSubpath(outp: var RenderPath, subOut: var RenderPath, mappedStart: Point,
                         state: var SubpathState, pieces: var seq[PieceRange]) =
  if not state.closed:
    appendDashedCommands(outp, subOut)
    resetDashedSubpath(subOut, state)
    return
  if not prepareDashedPieces(subOut, state, pieces): return
  if not appendClosedDashedSubpath(outp, subOut, pieces, mappedStart, state):
    appendDashedCommands(outp, subOut)
  resetDashedSubpath(subOut, state)

# ---------------------------------------------------------------- segments

func map(d: StrokeDash, pt: Point): Point =
  if d.applyTransform: pt * d.matrix else: pt

func startPt(l: Line): Point = l.pt1
func startPt(b: Bezier): Point = b.start

func splitSeg(l: Line, at: float32, left, right: var Line) =
  let dx0 = l.pt2.x - l.pt1.x
  let dy0 = l.pt2.y - l.pt1.y
  let len = sqrt(dx0 * dx0 + dy0 * dy0)
  let dx = ((l.pt2.x - l.pt1.x) / len) * at
  let dy = ((l.pt2.y - l.pt1.y) / len) * at
  left.pt1 = l.pt1
  left.pt2.x = left.pt1.x + dx
  left.pt2.y = left.pt1.y + dy
  right.pt1 = left.pt2
  right.pt2 = l.pt2

func splitSeg(b: Bezier, at: float32, left, right: var Bezier) = split(b, at, left, right)

func drawSeg(d: StrokeDash, outp: var RenderPath, l: Line) = outp.lineTo(d.map(l.pt2))

func drawSeg(d: StrokeDash, outp: var RenderPath, b: Bezier) =
  outp.cubicTo(d.map(b.ctrl1), d.map(b.ctrl2), d.map(b.`end`))

func nextDash(d: var StrokeDash) =
  inc d.curIdx
  if d.curIdx == d.dash.pattern.len: d.curIdx = 0
  d.curLen = d.dash.pattern[d.curIdx]
  d.opGap = not d.opGap

func point(d: var StrokeDash, outp: var RenderPath, p: Point) =
  if d.move or d.dash.pattern[d.curIdx] < FloatEpsilon:
    outp.moveTo(d.map(p))
    d.move = false
  outp.lineTo(d.map(p))

func segment[T: Line | Bezier](d: var StrokeDash, seg0: T, len0: float32,
                               outp: var RenderPath, allowDot: bool, endPos: Point) =
  var seg = seg0
  var len = len0
  if zero(len):
    d.curPos = endPos
    return

  if len <= d.curLen:
    d.curLen -= len
    if not d.opGap:
      if d.move:
        outp.moveTo(d.map(d.curPos))
        d.move = false
      d.drawSeg(outp, seg)
  else:
    var left, right: T
    while len - d.curLen > DashPatternThreshold:
      if d.curLen > 0.0'f32:
        let remaining = len - d.curLen
        if not (remaining < len): break  # "Dash data overflow!" in C++
        splitSeg(seg, d.curLen, left, right)
        len = remaining
        if not d.opGap:
          if d.move or d.dash.pattern[d.curIdx] - d.curLen < FloatEpsilon:
            outp.moveTo(d.map(startPt(left)))
            d.move = false
          d.drawSeg(outp, left)
      else:
        if allowDot and not d.opGap: d.point(outp, startPt(seg))
        right = seg
      d.nextDash()
      seg = right
      d.curPos = startPt(seg)
      d.move = true
    d.curLen -= len
    if not d.opGap:
      if d.move:
        outp.moveTo(d.map(startPt(seg)))
        d.move = false
      d.drawSeg(outp, seg)
    if d.curLen < MinCurrLenThreshold: 
      d.nextDash()
      d.move = true
  d.curPos = endPos

func lineTo(d: var StrokeDash, outp: var RenderPath, to: Point, allowDot: bool) =
  let line = Line(pt1: d.curPos, pt2: to)
  d.segment(line, length(to - d.curPos), outp, allowDot, to)

func cubicTo(d: var StrokeDash, outp: var RenderPath, c1, c2, finish: Point,
             allowDot: bool) =
  let curve = initBezier(d.curPos, c1, c2, finish)
  d.segment(curve, length(curve), outp, allowDot, finish)

func beginSubpath(d: var StrokeDash, start: Point, state: PatternState) =
  d.curIdx = state.idx
  d.curLen = d.dash.pattern[state.idx] - state.offset
  d.opGap = state.gap
  d.move = true
  d.curPos = start

func closeSubpath(d: var StrokeDash, subOut: var RenderPath, start: Point, allowDot: bool,
                  state: var SubpathState) =
  let prevPtCount = subOut.pts.len
  # a zero-length close emits nothing, yet the dash may already have reached start
  let zeroLength = zero(length(start - d.curPos))
  d.lineTo(subOut, start, allowDot)
  state.closed = true
  # Rejoin decisions use emitted piece endpoints; this only tracks whether Close reached start.
  state.closeEndsAtStart = zeroLength or (subOut.pts.len > prevPtCount and
    closed(subOut.pts[^1], d.map(start), DashEndpointTolerance))

# allowDot: zero length segment with non-butt cap still should be rendered as a point -
# only the caps are visible
func gen(d: var StrokeDash, input: RenderPath, outp: var RenderPath, allowDot: bool,
         matrix: Matrix, applyTransform: bool): bool =
  d.matrix = matrix
  d.applyTransform = applyTransform and not isIdentity(matrix)
  let initialState = patternState(d.dash)
  var pi = 0
  var start = Point()
  var subOut = RenderPath()
  var state = SubpathState()
  var pieces: seq[PieceRange]
  for cmd in input.cmds:
    case cmd
    of PathCommand.Close:
      d.closeSubpath(subOut, start, allowDot, state)
    of PathCommand.MoveTo:
      appendDashedSubpath(outp, subOut, d.map(start), state, pieces)
      start = input.pts[pi]
      inc pi
      d.beginSubpath(start, initialState)
    of PathCommand.LineTo:
      d.lineTo(subOut, input.pts[pi], allowDot)
      inc pi
    of PathCommand.CubicTo:
      d.cubicTo(subOut, input.pts[pi], input.pts[pi + 1], input.pts[pi + 2], allowDot)
      pi += 3
  appendDashedSubpath(outp, subOut, d.map(start), state, pieces)
  true

proc gpuStrokeDash*(rs: RenderShape, matrix: Matrix, applyTransform: bool,
                    output: var RenderPath): bool =
  ## Appends the dashed stroke path of `rs` to `output`; false if `rs` is not dashed.
  if rs.stroke.isNone: return false
  let stroke = rs.stroke.get
  if stroke.dash.pattern.len == 0 or stroke.dash.length < DashPatternThreshold:
    return false
  var d = StrokeDash(dash: stroke.dash)
  let allowDot = stroke.cap != StrokeCap.Butt
  if rs.trimpath:
    var tpath = RenderPath()
    if stroke.trim.trim(rs.path, tpath):
      return d.gen(tpath, output, allowDot, matrix, applyTransform)
    return false
  d.gen(rs.path, output, allowDot, matrix, applyTransform)

proc gpuStrokeDash*(rs: RenderShape, matrix: Matrix,
                    applyTransform: bool): tuple[ok: bool, path: RenderPath] =
  ## Same as the `output` overload, returning a fresh path.
  result.ok = gpuStrokeDash(rs, matrix, applyTransform, result.path)

{.pop.}
