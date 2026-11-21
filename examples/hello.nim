## Renders a small scene with the software canvas and writes `examples/hello.bmp`.
import std/os
import thorvg/core/types
from thorvg/core/fill import linearGradient, Fill
import thorvg/renderer/[paint, shape, scene, canvas]
import thorvg/engine/cpu/renderer
import thorvg/display/imageio

proc check(r: Result) =
  if r != Result.Success: raise newException(ValueError, "thorvg call failed: " & $r)

proc main() =
  let c = newSwCanvas(256, 256)

  let bg = newShape()
  check bg.appendRect(0, 0, 256, 256)
  var sky = linearGradient(0, 0, 0, 256)
  sky.stops = @[ColorStop(offset: 0, r: 30, g: 60, b: 160, a: 255),
                ColorStop(offset: 1, r: 250, g: 190, b: 120, a: 255)]
  check bg.fill(sky)
  check c.add(bg)

  let sun = newShape()
  check sun.appendCircle(180, 90, 40, 40)
  var glow = linearGradient(140, 50, 220, 130)
  glow.stops = @[ColorStop(offset: 0, r: 255, g: 255, b: 200, a: 255),
                 ColorStop(offset: 1, r: 255, g: 140, b: 40, a: 255)]
  check sun.fill(glow)
  check c.add(sun)

  let hill = newShape()
  check hill.moveTo(0, 256)
  check hill.lineTo(0, 190)
  check hill.cubicTo(60, 130, 140, 230, 256, 170)
  check hill.lineTo(256, 256)
  check hill.close()
  check hill.fill(20, 80, 40, 255)
  check hill.strokeWidth(3)
  check hill.strokeFill(10, 40, 20, 255)
  check c.add(hill)

  let badge = newScene()
  let ring = newShape()
  check ring.appendRect(30, 30, 80, 50, 12, 12)
  check ring.fill(255, 255, 255, 255)
  check ring.strokeWidth(4)
  check ring.strokeFill(220, 40, 60, 255)
  check badge.add(ring)
  check badge.opacity(180)
  check c.add(badge)

  check c.update()
  check c.draw()
  check c.sync()
  writeBmp("examples" / "hello.bmp", swSurface(c))

main()
