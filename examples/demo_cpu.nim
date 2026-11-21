## CPU demo: renders the shared demo scene with the software (CPU) backend.
##
##   demo_cpu [--size WxH] [--out file.bmp|.png|.ppm] [--no-window]
##
## Windowed mode shows FPS in the title. --no-window renders one frame.

import std/[os, times]
import thorvg/core/types
from thorvg/core/fill import linearGradient, radialGradient, Fill
import thorvg/renderer/[paint, shape, scene, canvas]
import thorvg/engine/cpu/renderer
import thorvg/display/imageio
import thorvg/display/window
import ./[common, demo_scene]

proc main() =
  let opts = parseOptions(400, 300)
  let c = newSwCanvas(opts.width, opts.height)
  buildDemoScene(c)
  check c.update()
  check c.draw()
  check c.sync()

  if opts.outFile.len > 0:
    saveImage(opts.outFile, swSurface(c))
    echo "saved: ", opts.outFile

  if opts.noWindow:
    return

  let win = openWindow("ThorVG CPU demo - FPS: ...", opts.width, opts.height)
  var frames = 0
  var last = epochTime()
  var fps = 0.0
  while win.pollEvents():
    if win.keyPressed(KeyEscape):
      win.close()
      break
    check c.update()
    check c.draw()
    check c.sync()
    win.present(swSurface(c))
    inc frames
    let now = epochTime()
    if now - last >= 1.0:
      fps = frames.float / (now - last)
      frames = 0
      last = now
      win.setTitle("ThorVG CPU demo - FPS: " & $int(fps))
    sleep(1)

main()
