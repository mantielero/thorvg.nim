## Per-pixel gradient color generator of the CPU engine.
##
## Ported from the `_fillLinear`/`_fillRadial`/`_fillConic` loops of `tvgSwFill.cpp`.
## The C++ repeats each loop for every raster flavour (mask, blend, matte...); here a
## `PixelGen` yields the gradient color of the next pixel of a span and the flavours
## (in `fill_raster.nim`) only combine it with the destination. The arithmetic (fixed
## point linear path, radial Taylor stepping, conic AA band) is the same as upstream.
##
## Float to int conversions use `toI32`, which mimics x86 `cvttss2si` (NaN/overflow give
## `int32.low`) as the C++ code relies on it; float checks are off like in C++.

import std/math
import ../../core/[types, geom, fill]
import ./[common, pixel]

const
  FixptBits = 8
  FixptSize = 1 shl FixptBits
  RadialAThreshold = 0.0005'f32

type
  GenMode = enum
    gmConst, gmFixed, gmFloat, gmRadialEdge, gmRadial, gmConic

  ConicAARange = object
    first, last, distance: float32

  PixelGen* = object
    fill {.cursor.}: SwFill  # borrowed: the caller keeps the fill alive for the span
    mode: GenMode
    quirk: bool
    color: uint32
    t, inc: float32
    t2, inc2: int
    rx, ry, b, deltaB, det, deltaDet, deltaDeltaDet: float32
    idx: int
    range: ConicAARange

{.push floatChecks: off.}

func toI32*(f: float32): int {.inline.} =
  ## C `static_cast<int32_t>(float)` on x86.
  if f >= -2147483648.0'f32 and f < 2147483648.0'f32: int(int32(f))
  else: int(low(int32))  # NaN fails both compares

func spreadIndex*(fill: SwFill, pos: int): int =
  ## `_clamp`: maps a color table position to 0..SwColorTable-1 by the spread method.
  result = pos
  case fill.spread
  of FillSpread.Pad:
    result = clamp(pos, 0, SwColorTable - 1)
  of FillSpread.Repeat:
    result = pos mod SwColorTable
    if result < 0: result = SwColorTable + result
  of FillSpread.Reflect:
    const limit = SwColorTable * 2
    result = pos mod limit
    if result < 0: result = limit + result
    if result >= SwColorTable: result = limit - result - 1

func colorAt*(fill: SwFill, pos: float32): uint32 =
  ## `_pixel`: color of the gradient position `pos` (0..1 is one cycle).
  fill.ctable[spreadIndex(fill, toI32(pos * float32(SwColorTable - 1) + 0.5'f32))]

func fixedPixel(fill: SwFill, pos: int): uint32 =
  fill.ctable[spreadIndex(fill, (pos + FixptSize div 2) shr FixptBits)]

func conicAARange(fill: SwFill, rx, ry: float32, len: int): ConicAARange =
  if fill.invFwidth <= 0.0'f32 or len == 0: return
  let offset = pt(rx, ry)
  let distance = dot(fill.normal, offset) * fill.invFwidth
  let distanceDx = fill.distanceDx
  var range = ConicAARange(first: 0.0'f32, last: float32(len))
  if zero(distanceDx):
    if distance <= -0.5'f32 or distance >= 0.5'f32: return
  else:
    var first = (-0.5'f32 - distance) / distanceDx
    var last = (0.5'f32 - distance) / distanceDx
    if first > last: swap(first, last)
    range.first = max(range.first, floor(first) + 1.0'f32)
    range.last = min(range.last, ceil(last))
  let seam = pt(fill.normal.y, -fill.normal.x)
  let seamProjection = dot(offset, seam)
  let seamDx = fill.seamProjectionDx
  if zero(seamDx):
    if seamProjection < 0.0'f32: return
  elif seamDx > 0.0'f32:
    range.first = max(range.first, ceil(-seamProjection / seamDx))
  else:
    range.last = min(range.last, floor(-seamProjection / seamDx) + 1.0'f32)
  if range.first >= range.last: return
  range.distance = distance + range.first * distanceDx
  range

func conicPixel(g: PixelGen): uint32 =
  let fill {.cursor.} = g.fill
  let i = float32(g.idx)
  if i < g.range.first or i >= g.range.last:
    # atan2 starts at 3 o'clock; offset rotates to the configured start angle
    var t = arctan2(g.ry, g.rx) * (0.5'f32 / MathPi) + fill.offset
    t = t - floor(t)
    colorAt(fill, t)
  else:
    let distance = g.range.distance + (i - g.range.first) * fill.distanceDx
    interpolate(fill.ctable[0], fill.ctable[SwColorTable - 1],
                uint8(toI32(255.0'f32 * (distance + 0.5'f32)) and 0xff))

func radialStart(g: var PixelGen, x, y: int) =
  ## `_calculateCoefficients` (and the start of the edge case): the quadratic of the
  ## radial gradient and its derivatives along x.
  let f {.cursor.} = g.fill
  let fx = float32(x) + 0.5'f32
  let fy = float32(y) + 0.5'f32
  g.rx = fx * f.a11 + fy * f.a12 + f.a13 - f.fx
  g.ry = fx * f.a21 + fy * f.a22 + f.a23 - f.fy
  if f.aa < RadialAThreshold:
    g.mode = gmRadialEdge
  else:
    g.mode = gmRadial
    g.b = (f.rdr * f.fr + g.rx * f.rdx + g.ry * f.rdy) * f.invA
    g.deltaB = (f.a11 * f.rdx + f.a21 * f.rdy) * f.invA
    let rr = g.rx * g.rx + g.ry * g.ry
    let deltaRr = 2.0'f32 * (g.rx * f.a11 + g.ry * f.a21) * f.invA
    let deltaDeltaRr = 2.0'f32 * (f.a11 * f.a11 + f.a21 * f.a21) * f.invA
    g.det = g.b * g.b + (rr - f.fr * f.fr) * f.invA
    g.deltaDet = 2.0'f32 * g.b * g.deltaB + g.deltaB * g.deltaB + deltaRr + deltaDeltaRr * 0.5'f32
    g.deltaDeltaDet = 2.0'f32 * g.deltaB * g.deltaB + deltaDeltaRr

func linearStart(g: var PixelGen, x, y, len: int) =
  let f {.cursor.} = g.fill
  let rx = float32(x) + 0.5'f32
  let ry = float32(y) + 0.5'f32
  g.t = (f.dx * rx + f.dy * ry + f.offset) * float32(SwColorTable - 1)
  g.inc = f.dx * float32(SwColorTable - 1)
  if zero(g.inc):
    g.mode = gmConst
    g.color = fixedPixel(f, toI32(g.t * float32(FixptSize)))
  else:
    const vMax = float32((high(int32) shr (FixptBits + 1)))
    let v = g.t + g.inc * float32(len)
    if v < vMax and v > -vMax:
      g.mode = gmFixed
      g.t2 = toI32(g.t * float32(FixptSize))
      g.inc2 = toI32(g.inc * float32(FixptSize))
    else:
      g.mode = gmFloat

func initGen*(fill: SwFill, y, x, len: int, quirk = false): PixelGen =
  ## Starts the span (y, x, len). `quirk` reproduces the upstream radial code of the
  ## direct masking raster, which forgets `- b` in the regular (non edge) case.
  result = PixelGen(fill: fill, quirk: quirk)
  case fill.kind
  of FillKind.Linear:
    linearStart(result, x, y, len)
  of FillKind.Radial:
    radialStart(result, x, y)
  of FillKind.Conic:
    result.mode = gmConic
    result.rx = (float32(x) + 0.5'f32) * fill.a11 + (float32(y) + 0.5'f32) * fill.a12 +
      fill.a13 - fill.cx
    result.ry = (float32(x) + 0.5'f32) * fill.a21 + (float32(y) + 0.5'f32) * fill.a22 +
      fill.a23 - fill.cy
    result.range = conicAARange(fill, result.rx, result.ry, len)

func next*(g: var PixelGen): uint32 =
  ## Color of the current pixel; moves to the next one.
  let f {.cursor.} = g.fill
  case g.mode
  of gmConst:
    result = g.color
  of gmFixed:
    result = fixedPixel(f, g.t2)
    g.t2 += g.inc2
  of gmFloat:
    result = colorAt(f, g.t / float32(SwColorTable))
    g.t += g.inc
  of gmRadialEdge:
    let x0 = 0.5'f32 * (g.rx * g.rx + g.ry * g.ry - f.fr * f.fr) /
      (f.rdr * f.fr + g.rx * f.rdx + g.ry * f.rdy)
    result = colorAt(f, x0)
    g.rx += f.a11
    g.ry += f.a21
  of gmRadial:
    result = colorAt(f, if g.quirk: sqrt(g.det) else: sqrt(g.det) - g.b)
    g.det += g.deltaDet
    g.deltaDet += g.deltaDeltaDet
    g.b += g.deltaB
  of gmConic:
    result = conicPixel(g)
    g.rx += f.a11
    g.ry += f.a21
  inc g.idx

{.pop.}
