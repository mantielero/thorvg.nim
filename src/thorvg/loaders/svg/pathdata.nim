## SVG path data (`d` attribute) to `RenderPath`.
##
## Ported from `modules/svg/tvgSvgPath.cpp`. Supports M m L l H h V v C c S s Q q T t A a Z z,
## implicit command repetition, compact number forms (`10-5.5.5`, `1e-3`), arc flags written
## without separators, and converts quadratics and elliptical arcs into cubic beziers.

import std/math
import ../../core/[types, geom, path, str]
import ./util

type PathState = object
  ## Current point, last control point and sub-path start of the walk.
  cur, curCtl, start: Point
  quadratic, closed: bool

{.push floatChecks: off.}

proc pathAppendArcTo*(outPath: var RenderPath, cur, curCtl: var Point, next: Point,
                      radius: Point, angle: float32, largeArc, sweep: bool) =
  ## Appends the arc from `cur` to `next` as cubic beziers (SVG implementation notes F.6).
  ## `cur` and `curCtl` are updated to the arc end and its last control point.
  var radius = radius
  var start = cur
  let cosPhi = cos(angle)
  let sinPhi = sin(angle)
  let d2 = (start - next) * 0.5'f32
  let x1p = cosPhi * d2.x + sinPhi * d2.y
  let y1p = cosPhi * d2.y - sinPhi * d2.x
  let x1p2 = x1p * x1p
  let y1p2 = y1p * y1p
  var radius2 = pt(radius.x * radius.x, radius.y * radius.y)
  let lambda = (x1p2 / radius2.x) + (y1p2 / radius2.y)

  # Correction of out-of-range radii (F6.6.2 step 4, F6.6.3)
  if lambda > 1.0'f32:
    radius *= sqrt(lambda)
    radius2 = pt(radius.x * radius.x, radius.y * radius.y)

  var cp, center: Point
  var c = (radius2.x * radius2.y) - (radius2.x * y1p2) - (radius2.y * x1p2)

  if c < 0.0'f32:
    # No solution: scale uniformly until there is a single one (F6.2)
    radius *= sqrt(1.0'f32 - c / (radius2.x * radius2.y))
    radius2 = pt(radius.x * radius.x, radius.y * radius.y)
    cp = pt(0.0'f32, 0.0'f32)
    center = pt(0.0'f32, 0.0'f32)
  else:
    c = sqrt(c / ((radius2.x * y1p2) + (radius2.y * x1p2)))
    if largeArc == sweep: c = -c
    cp = c * pt(radius.x * y1p / radius.y, -radius.y * x1p / radius.x)
    center = pt(cosPhi * cp.x - sinPhi * cp.y, sinPhi * cp.x + cosPhi * cp.y)

  center += (start + next) * 0.5'f32

  # F6.5.4: no arccos, see http://www.euclideanspace.com/maths/algebra/vectors/angleBetween
  let at = fastAtan2((y1p - cp.y) / radius.y, (x1p - cp.x) / radius.x)
  var theta1 = if at < 0.0'f32: 2.0'f32 * MathPi + at else: at
  let nat = fastAtan2((-y1p - cp.y) / radius.y, (-x1p - cp.x) / radius.x)
  var deltaTheta = if nat < at: 2.0'f32 * MathPi - at + nat else: nat - at

  if sweep:
    if deltaTheta < 0.0'f32: deltaTheta += 2.0'f32 * MathPi
  else:
    if deltaTheta > 0.0'f32: deltaTheta -= 2.0'f32 * MathPi

  # Split into cubic beziers smaller than 90 degrees (one extra segment on purpose).
  let segments = int(abs(deltaTheta / (MathPi * 0.5'f32)) + 1.0'f32)
  let delta = deltaTheta / float32(segments)

  # http://www.stillhq.com/ctpfaq/2001/comp.text.pdf-faq-2001-04.txt (section 2.13)
  let bcp = 4.0'f32 / 3.0'f32 * (1.0'f32 - cos(delta / 2.0'f32)) / sin(delta / 2.0'f32)
  let cosPhiR = pt(cosPhi * radius.x, cosPhi * radius.y)
  let sinPhiR = pt(sinPhi * radius.x, sinPhi * radius.y)
  var cosTheta1 = cos(theta1)
  var sinTheta1 = sin(theta1)

  for _ in 0 ..< segments:
    let theta2 = theta1 + delta
    let cosTheta2 = cos(theta2)
    let sinTheta2 = sin(theta2)
    let c1 = start + pt(-bcp * (cosPhiR.x * sinTheta1 + sinPhiR.y * cosTheta1),
                        bcp * (cosPhiR.y * cosTheta1 - sinPhiR.x * sinTheta1))
    let e = center + pt(cosPhiR.x * cosTheta2 - sinPhiR.y * sinTheta2,
                        sinPhiR.x * cosTheta2 + cosPhiR.y * sinTheta2)
    curCtl = e + pt(bcp * (cosPhiR.x * sinTheta2 + sinPhiR.y * cosTheta2),
                    bcp * (sinPhiR.x * sinTheta2 - cosPhiR.y * cosTheta2))
    cur = e
    outPath.cubicTo(c1, curCtl, cur)
    start = e
    theta1 = theta2
    cosTheta1 = cosTheta2
    sinTheta1 = sinTheta2

{.pop.}

func numberCount(cmd: char): int =
  case cmd
  of 'M', 'm', 'L', 'l', 'T', 't': 2
  of 'C', 'c', 'E', 'e': 6
  of 'H', 'h', 'V', 'v': 1
  of 'S', 's', 'Q', 'q': 4
  of 'A', 'a': 7
  else: 0

proc processCommand(outPath: var RenderPath, cmd: char, arr: var array[7, float32],
                    count: int, st: var PathState): bool =
  case cmd
  of 'm', 'l', 'c', 's', 'q', 't':
    for i in countup(0, count - 2, 2):
      arr[i] += st.cur.x
      arr[i + 1] += st.cur.y
  of 'h': arr[0] += st.cur.x
  of 'v': arr[0] += st.cur.y
  of 'a':
    arr[5] += st.cur.x
    arr[6] += st.cur.y
  else: discard

  case cmd
  of 'm', 'M':
    st.cur = pt(arr[0], arr[1])
    st.start = st.cur
    outPath.moveTo(st.cur)
  of 'l', 'L':
    st.cur = pt(arr[0], arr[1])
    outPath.lineTo(st.cur)
  of 'c', 'C':
    st.curCtl = pt(arr[2], arr[3])
    st.cur = pt(arr[4], arr[5])
    outPath.cubicTo(pt(arr[0], arr[1]), st.curCtl, st.cur)
    st.quadratic = false
  of 's', 'S':
    let ctrl =
      if outPath.cmds.len > 1 and outPath.cmds[^1] == PathCommand.CubicTo and
          not st.quadratic: 2.0'f32 * st.cur - st.curCtl
      else: st.cur
    st.curCtl = pt(arr[0], arr[1])
    st.cur = pt(arr[2], arr[3])
    outPath.cubicTo(ctrl, st.curCtl, st.cur)
    st.quadratic = false
  of 'q', 'Q':
    let q = pt(arr[0], arr[1])
    let ctrl1 = (st.cur + 2.0'f32 * q) * (1.0'f32 / 3.0'f32)
    let ctrl2 = (pt(arr[2], arr[3]) + 2.0'f32 * q) * (1.0'f32 / 3.0'f32)
    st.curCtl = q
    st.cur = pt(arr[2], arr[3])
    outPath.cubicTo(ctrl1, ctrl2, st.cur)
    st.quadratic = true
  of 't', 'T':
    let ctrl =
      if outPath.cmds.len > 1 and outPath.cmds[^1] == PathCommand.CubicTo and
          st.quadratic: 2.0'f32 * st.cur - st.curCtl
      else: st.cur
    let ctrl1 = (st.cur + 2.0'f32 * ctrl) * (1.0'f32 / 3.0'f32)
    let ctrl2 = (pt(arr[0], arr[1]) + 2.0'f32 * ctrl) * (1.0'f32 / 3.0'f32)
    st.curCtl = ctrl
    st.cur = pt(arr[0], arr[1])
    outPath.cubicTo(ctrl1, ctrl2, st.cur)
    st.quadratic = true
  of 'h', 'H':
    outPath.lineTo(pt(arr[0], st.cur.y))
    st.cur.x = arr[0]
  of 'v', 'V':
    outPath.lineTo(pt(st.cur.x, arr[0]))
    st.cur.y = arr[0]
  of 'z', 'Z':
    outPath.close()
    st.cur = st.start
    st.closed = true
  of 'a', 'A':
    if zero(arr[0]) or zero(arr[1]):
      st.cur = pt(arr[5], arr[6])
      outPath.lineTo(st.cur)
    elif not equal(st.cur.x, arr[5]) or not equal(st.cur.y, arr[6]):
      pathAppendArcTo(outPath, st.cur, st.curCtl, pt(arr[5], arr[6]),
                      pt(abs(arr[0]), abs(arr[1])), deg2rad(arr[2]), arr[3] != 0.0'f32,
                      arr[4] != 0.0'f32)
      st.cur = pt(arr[5], arr[6])
      st.curCtl = st.cur
      st.quadratic = false
  else: return false
  true

proc parseFlag(d: string, pos: var int, flag: var int): bool =
  ## Arc flags are a single `0`/`1` character, so `a1 1 0 00.5.5` is legal.
  if d.charAt(pos) notin {'0', '1'}: return false
  flag = ord(d[pos]) - ord('0')
  inc pos
  pos = skipWhiteSpaceAndComma(d, pos)
  true

proc nextCommand(d: string, pos: var int, cmd: var char, arr: var array[7, float32],
                 count: var int, closed: bool): bool =
  ## Reads the next command letter (or repeats the previous one) and its numbers.
  var ignored = 0
  pos = skipWhiteSpaceAndComma(d, pos)
  if d.charAt(pos) in {'a'..'z', 'A'..'Z'}:
    cmd = d[pos]
    inc pos
    count = numberCount(cmd)
  elif cmd == 'm': cmd = 'l'
  elif cmd == 'M': cmd = 'L'
  elif closed: return false
  if count == 7:
    var large, sweep = 0
    if parseNumber(d, pos, ignored, arr[0]) and parseNumber(d, pos, ignored, arr[1]) and
        parseNumber(d, pos, ignored, arr[2]) and parseFlag(d, pos, large) and
        parseFlag(d, pos, sweep) and parseNumber(d, pos, ignored, arr[5]) and
        parseNumber(d, pos, ignored, arr[6]):
      arr[3] = float32(large)
      arr[4] = float32(sweep)
      return true
    count = 0
    return false
  for i in 0 ..< count:
    if not parseNumber(d, pos, ignored, arr[i]):
      count = 0
      return false
    pos = skipWhiteSpaceAndComma(d, pos)
  true

proc parsePath*(d: string, outPath: var RenderPath): bool =
  ## Appends the path `d` to `outPath`. Parsing stops quietly at the first error, keeping
  ## what was read; returns false only when the appended data does not start with a MoveTo.
  var arr: array[7, float32]
  var count = 0
  var cmd = '\0'
  var pos = 0
  var st = PathState()
  let lastCmds = outPath.cmds.len
  while d.charAt(pos) != '\0':
    if not nextCommand(d, pos, cmd, arr, count, st.closed): break
    st.closed = false
    if not processCommand(outPath, cmd, arr, count, st): break
  not (outPath.cmds.len > lastCmds and outPath.cmds[lastCmds] != PathCommand.MoveTo)
