## Shared scene for CPU/GL/WG demos.
import thorvg/core/types
from thorvg/core/fill import linearGradient, radialGradient, Fill
import thorvg/renderer/[paint, shape, scene, canvas]

proc check*(r: Result) =
  if r != Result.Success: raise newException(ValueError, "thorvg call failed: " & $r)

proc buildDemoScene*(c: Canvas) =
  ## Same scene used by demo_cpu, demo_gl, demo_wg.
  let bg = newShape()
  check bg.appendRect(0, 0, 400, 300)
  var sky = linearGradient(0, 0, 0, 300)
  sky.stops = @[ColorStop(offset: 0.0, r: 18, g: 32, b: 90, a: 255),
                ColorStop(offset: 1.0, r: 120, g: 190, b: 255, a: 255)]
  check bg.fill(sky)
  check c.add(bg)

  let sun = newShape()
  check sun.appendCircle(320, 72, 38, 38)
  var glow = radialGradient(320, 72, 38, 320, 72, 0)
  glow.stops = @[ColorStop(offset: 0.0, r: 255, g: 160, b: 40, a: 255),
                 ColorStop(offset: 1.0, r: 255, g: 245, b: 190, a: 255)]
  check sun.fill(glow)
  check c.add(sun)

  let ground = newShape()
  check ground.moveTo(0, 300)
  check ground.lineTo(0, 215)
  check ground.cubicTo(90, 160, 170, 245, 265, 205)
  check ground.cubicTo(330, 175, 365, 195, 400, 188)
  check ground.lineTo(400, 300)
  check ground.close()
  check ground.fill(30, 105, 52, 255)
  check ground.strokeWidth(2)
  check ground.strokeFill(18, 65, 32, 255)
  check c.add(ground)

  let ring = newShape()
  check ring.appendCircle(200, 150, 58, 58)
  check ring.strokeWidth(9)
  var ringStroke = linearGradient(140, 90, 260, 210)
  ringStroke.stops = @[ColorStop(offset: 0.0, r: 255, g: 90, b: 90, a: 255),
                       ColorStop(offset: 1.0, r: 255, g: 220, b: 120, a: 255)]
  check ring.strokeFill(ringStroke)
  check ring.fill(255'u8, 255'u8, 255'u8, 28'u8)
  check c.add(ring)

  let badge = newScene()
  let card = newShape()
  check card.appendRect(22, 22, 170, 52, 10, 10)
  check card.fill(255, 255, 255, 225)
  check card.strokeWidth(3)
  check card.strokeFill(45, 90, 170, 255)
  check badge.add(card)
  let dot = newShape()
  check dot.appendCircle(46, 48, 8, 8)
  check dot.fill(60, 180, 110, 255)
  check badge.add(dot)
  check badge.opacity(235)
  check c.add(badge)
