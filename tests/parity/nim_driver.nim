## Nim twin of `cpp_driver.cpp` (same CLI, same stdout line, same dump files).
##
##   nim_driver <scene> <w> <h> [--dump <prefix>] [--repeat N]
##   scene = see `driver_common.nim` (shapes, svg:, png:, jpg:, webp:, pngrot:, gif:, text)
##
## Exit code 0 ok, 2 usage / load / render error. The scenes are shared with the GL driver
## (`tests/gl/nim_gl_driver.nim`) through `driver_common.nim`.

import std/os
import thorvg
import ./driver_common

proc render(scene: string, w, h: int): RenderSurface =
  let c = newSwCanvas(w, h)
  buildScene(c, scene, w, h)
  c.render()
  swSurface(c)

proc main(): int =
  var a: DriverArgs
  let rc = parseDriverArgs("nim_driver", commandLineParams(), a)
  if rc != 0: return rc
  var surface: RenderSurface
  try:
    for _ in 0 ..< a.repeat: surface = render(a.scene, a.w, a.h)
  except CatchableError as e:
    stderr.writeLine e.msg
    return 2
  printSummary(a.scene, a.w, a.h, surface.data)
  if a.dump.len > 0: writeDump(a.dump, surface.data, int(surface.w), int(surface.h))
  0

quit(main())
