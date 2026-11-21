## Vector shapes demo: gradients, strokes, caps/joins, dashes, transforms, opacity,
## clip, mask, blend and nested scenes (the `shapes` scene of the parity driver).
##
##   shapes [--size WxH] [--out file.bmp|.png|.ppm] [--no-window] [part]
##
## `part` is one of `shapes_scene.PartNames` (default: all). The design canvas is
## 400x300; other sizes show the same scene in the top-left corner like the driver.

import thorvg
import ./[common, shapes_scene]

proc main() =
  let opts = parseOptions(400, 300)
  let c = newSwCanvas(opts.width, opts.height)
  let part = if opts.args.len > 0: opts.args[0] else: ""
  if not buildShapes(c, part):
    quit("unknown part " & part, 2)
  c.render()
  opts.output("ThorVG shapes", swSurface(c))

main()
