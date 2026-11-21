## Text demo: TrueType text with sizes, colors, rotation, italic and a gradient
## (the `text` scene of the parity driver).
##
##   text [--size WxH] [--out file.bmp|.png|.ppm] [--no-window]
##        [--font file.ttf] [--text "headline"]
##
## Default font: platform-specific (e.g. Arial on Windows, DejaVu/Liberation/Noto on Linux),
## overridable with `--font`. Default canvas: 400x300.

import std/tables
import thorvg
import ./[common, text_scene]

proc main() =
  let opts = parseOptions(400, 300, ["font", "text"])
  let c = newSwCanvas(opts.width, opts.height)
  try:
    buildText(c, opts.extra.getOrDefault("font", DefaultFont),
      opts.extra.getOrDefault("text", ""))
    c.render()
  except ThorvgError as e:
    quit(e.msg, 2)
  opts.output("ThorVG text", swSurface(c))

main()
