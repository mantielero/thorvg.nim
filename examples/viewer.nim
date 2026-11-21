## Image viewer: shows a picture scaled to fit the window and centered.
##
##   viewer <file.png> [--size WxH] [--out file.bmp|.png|.ppm] [--no-window]
##
## The file type is chosen by `Picture.load` (extension, then header probing), so SVG
## files work as soon as the SVG loader is imported by `thorvg.nim`. Default size 800x600.

import thorvg
import ./common

proc main() =
  let opts = parseOptions(800, 600)
  if opts.args.len != 1:
    quit("usage: viewer <file> [--size WxH] [--out file] [--no-window]", 2)
  let c = newSwCanvas(opts.width, opts.height)
  try:
    check c.add(fitPicture(opts.args[0], opts.width, opts.height))
  except ThorvgError as e:
    quit(e.msg, 2)
  c.render()
  opts.output("ThorVG viewer - " & opts.args[0], swSurface(c))

main()
