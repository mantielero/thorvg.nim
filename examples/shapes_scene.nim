## The `shapes` demo scene (design canvas 400x300), shared by `examples/shapes.nim`
## and the parity driver. It reproduces `tests/parity/cpp_driver.cpp` part by part,
## so the coordinates and the float32 arithmetic must not be "improved".

import std/math
import thorvg

const
  PartNames* = ["rect", "roundrect", "ellipse", "star_nonzero", "star_evenodd", "lingrad",
                "radgrad", "spread_reflect", "spread_repeat", "gradstroke", "caps", "joins",
                "dash", "transform", "opacity", "clip", "mask", "blend", "nested"]
  Pi32 = 3.14159265358979323846'f32

proc star(cx, cy, r: float32): Shape =
  ## Five-pointed star drawn as a pentagram path (self-intersecting).
  result = newShape()
  for i in 0 ..< 5:
    let a = -Pi32 / 2'f32 + float32(i * 4) * Pi32 / 5'f32
    let x = cx + r * cos(a)
    let y = cy + r * sin(a)
    if i == 0: check result.moveTo(x, y) else: check result.lineTo(x, y)
  check result.close()

proc rectPart(): seq[Paint] =
  let s = newShape()
  check s.appendRect(10, 10, 80, 80)
  check s.fill(220, 60, 40)
  @[Paint(s)]

proc roundRectPart(): seq[Paint] =
  let s = newShape()
  check s.appendRect(110, 10, 80, 80, 15, 25)
  check s.fill(40, 120, 220, 200)
  check s.strokeWidth(3)
  check s.strokeFill(10, 10, 10)
  @[Paint(s)]

proc ellipsePart(): seq[Paint] =
  let s = newShape()
  check s.appendCircle(240, 50, 40, 30)
  check s.fill(60, 180, 90)
  @[Paint(s)]

proc starNonZeroPart(): seq[Paint] =
  let s = star(345, 50, 40)
  check s.fill(250, 190, 20)
  check s.fillRule(FillRule.NonZero)
  @[Paint(s)]

proc starEvenOddPart(): seq[Paint] =
  let s = star(385, 80, 14)
  check s.fill(150, 40, 200)
  check s.fillRule(FillRule.EvenOdd)
  @[Paint(s)]

proc lingradPart(): seq[Paint] =
  let s = newShape()
  check s.appendRect(10, 110, 80, 80, 8, 8)
  let g = linearGradient(10, 110, 90, 190).withStops(
    colorStop(0.0, 255, 0, 0), colorStop(0.5, 255, 255, 0), colorStop(1.0, 0, 0, 255, 128))
  check s.fill(g)
  @[Paint(s)]

proc radgradPart(): seq[Paint] =
  let s = newShape()
  check s.appendCircle(150, 150, 40, 40)
  let g = radialGradient(150, 150, 40, 135, 140, 0).withStops(
    colorStop(0.0, 255, 255, 255), colorStop(1.0, 20, 40, 160))
  check s.fill(g)
  @[Paint(s)]

proc spreadPart(y: float32, spread: FillSpread): seq[Paint] =
  let s = newShape()
  check s.appendRect(210, y, 80, 36)
  var g = linearGradient(220, 0, 250, 0).withStops(
    colorStop(0.0, 255, 80, 0), colorStop(1.0, 0, 80, 255))
  g.spread = spread
  check s.fill(g)
  @[Paint(s)]

proc gradStrokePart(): seq[Paint] =
  let s = newShape()
  check s.appendCircle(345, 150, 30, 30)
  check s.strokeWidth(14)
  let g = radialGradient(345, 150, 44, 345, 150, 0).withStops(
    colorStop(0.6, 255, 0, 0), colorStop(1.0, 0, 0, 255))
  check s.strokeFill(g)
  @[Paint(s)]

proc capsPart(): seq[Paint] =
  const caps = [StrokeCap.Butt, StrokeCap.Round, StrokeCap.Square]
  for i in 0 ..< 3:
    let s = newShape()
    let y = float32(215 + i * 25)
    check s.moveTo(15, y)
    check s.lineTo(85, y)
    check s.strokeWidth(14)
    check s.strokeFill(30, 30, 30)
    check s.strokeCap(caps[i])
    result.add s

proc joinsPart(): seq[Paint] =
  const joins = [StrokeJoin.Miter, StrokeJoin.Round, StrokeJoin.Bevel]
  for i in 0 ..< 3:
    let s = newShape()
    let x = float32(110 + i * 30)
    check s.moveTo(x, 270)
    check s.lineTo(x + 12, 210)
    check s.lineTo(x + 24, 270)
    check s.strokeWidth(9)
    check s.strokeFill(120, 30, 30)
    check s.strokeJoin(joins[i])
    check s.strokeMiterlimit(4)
    result.add s

proc dashPart(): seq[Paint] =
  let s = newShape()
  check s.appendRect(205, 210, 80, 70, 10, 10)
  check s.strokeWidth(5)
  check s.strokeFill(0, 100, 100)
  check s.strokeDash([12'f32, 6'f32], 3)
  check s.strokeCap(StrokeCap.Round)
  @[Paint(s)]

proc transformPart(): seq[Paint] =
  let s = newShape()
  check s.appendRect(-25, -15, 50, 30, 4, 4)
  check s.fill(200, 100, 0)
  check s.strokeWidth(2)
  check s.strokeFill(0, 0, 0)
  check s.translate(335, 230)
  check s.rotate(30)
  check s.scale(1.3'f32)
  @[Paint(s)]

proc opacityPart(): seq[Paint] =
  let a = newShape()
  check a.appendRect(300, 255, 40, 40)
  check a.fill(255, 0, 0)
  let b = newShape()
  check b.appendRect(320, 265, 40, 30)
  check b.fill(0, 0, 255)
  check b.opacity(128)
  @[Paint(a), Paint(b)]

proc clipPart(): seq[Paint] =
  let s = newShape()
  check s.appendRect(10, 5, 100, 20)
  check s.fill(0, 160, 0)
  let c = newShape()
  check c.appendCircle(60, 15, 18, 18)
  check s.clip(c)
  @[Paint(s)]

proc maskPart(): seq[Paint] =
  let s = newShape()
  check s.appendRect(120, 195, 70, 10)
  check s.fill(200, 0, 200)
  let m = newShape()
  check m.appendCircle(155, 200, 12, 12)
  check m.fill(0, 0, 0, 255)
  check s.mask(m, MaskMethod.Alpha)
  @[Paint(s)]

proc blendPart(): seq[Paint] =
  let a = newShape()
  check a.appendRect(300, 5, 40, 20)
  check a.fill(250, 200, 100)
  let b = newShape()
  check b.appendRect(320, 10, 40, 20)
  check b.fill(100, 150, 250)
  check b.blend(BlendMethod.Multiply)
  @[Paint(a), Paint(b)]

proc nestedPart(): seq[Paint] =
  let sc = newScene()
  let a = newShape()
  check a.appendCircle(250, 245, 10, 10)
  check a.fill(255, 0, 0)
  let b = newShape()
  check b.appendCircle(258, 245, 10, 10)
  check b.fill(0, 255, 0)
  check sc.add(a)
  check sc.add(b)
  check sc.opacity(128)
  @[Paint(sc)]

proc buildPart(name: string): seq[Paint] =
  case name
  of "rect": rectPart()
  of "roundrect": roundRectPart()
  of "ellipse": ellipsePart()
  of "star_nonzero": starNonZeroPart()
  of "star_evenodd": starEvenOddPart()
  of "lingrad": lingradPart()
  of "radgrad": radgradPart()
  of "spread_reflect": spreadPart(110, FillSpread.Reflect)
  of "spread_repeat": spreadPart(154, FillSpread.Repeat)
  of "gradstroke": gradStrokePart()
  of "caps": capsPart()
  of "joins": joinsPart()
  of "dash": dashPart()
  of "transform": transformPart()
  of "opacity": opacityPart()
  of "clip": clipPart()
  of "mask": maskPart()
  of "blend": blendPart()
  of "nested": nestedPart()
  else: @[]

proc buildShapes*(c: Canvas, part = ""): bool =
  ## Adds the whole scene (`part == ""`) or one part to `c`; false for an unknown part.
  ## Painting order = `PartNames` order.
  for name in PartNames:
    if part.len == 0 or part == name:
      for p in buildPart(name):
        check c.add(p)
      result = true
