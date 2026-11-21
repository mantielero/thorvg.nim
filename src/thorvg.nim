## ThorVG for Nim: public facade.
##
## `import thorvg` gives the scene graph (Canvas, Shape, Scene, Picture), the shared
## core types (`Result`, `ColorStop`, `Matrix`, enums, ...), gradients, the software
## canvas (`newSwCanvas`, `swSurface`), the PNG loader and the image writers
## (`writeBmp`, `writePng`, `writePpm`). The window API stays in
## `thorvg/display/window` (it is only needed by interactive programs).
##
## Most calls return a `Result` like the C++ API; `check` turns a failure into a
## `ThorvgError`, so scripts can write `check shape.appendRect(0, 0, 10, 10)`.
##
##   let c = newSwCanvas(400, 300)
##   let s = newShape()
##   check s.appendRect(10, 10, 80, 80)
##   check s.fill(220, 60, 40)
##   check c.add(s)
##   c.render()
##   writePng("out.png", swSurface(c))
##
## Adding a loader or paint kind: import its module below. Loaders register
## themselves when the module is imported.

import ./thorvg/core/[types]
import ./thorvg/core/fill as gradient
import ./thorvg/renderer/[paint, shape, scene, picture, canvas]
import ./thorvg/display/imageio
from ./thorvg/renderer/render import RenderSurface
from ./thorvg/engine/cpu/renderer import newSwCanvas, swSurface
# Loaders (registration happens at import):
import ./thorvg/loaders/image/loader_png
import ./thorvg/loaders/image/loader_jpg
import ./thorvg/loaders/image/loader_gif
import ./thorvg/loaders/image/loader_webp
# Still to be wired in when they are ported (see migration/PLAN.md T17, T18, T19):
from ./thorvg/loaders/svg/loader import SvgLoader  # SVG pictures (T17)
from ./thorvg/loaders/font/loader import SfntLoader  # TTF fonts (T18)
import ./thorvg/renderer/text as textpaint          # Text paint (T19), loadFont/unloadFont
import ./thorvg/renderer/[animation, accessor, saver]  # Animation, Accessor, Saver (L7)
from ./thorvg/savers/png import PngSaver            # registers the "png" saver (addition)

export types, gradient, paint, shape, scene, picture, canvas, imageio
export loader_png, loader_jpg, loader_gif, loader_webp, RenderSurface, newSwCanvas, swSurface
export textpaint, SfntLoader, SvgLoader
export animation, accessor, saver, PngSaver

type ThorvgError* = object of CatchableError
  ## Raised by `check` and by the helpers that load files.

proc check*(r: Result, what = "thorvg call") =
  ## Raises `ThorvgError` unless `r` is `Result.Success`.
  if r != Result.Success:
    raise newException(ThorvgError, what & " failed: " & $r)

func colorStop*(offset: float32, r, g, b: uint8, a: uint8 = 255): ColorStop =
  ColorStop(offset: offset, r: r, g: g, b: b, a: a)

func withStops*(f: Fill, stops: varargs[ColorStop]): Fill =
  ## A copy of gradient `f` with the given color stops.
  result = f
  result.stops = @stops

proc fill*(s: Shape, r, g, b: uint8): Result =
  ## Solid fill with full opacity.
  s.fill(r, g, b, 255'u8)

proc strokeFill*(s: Shape, r, g, b: uint8): Result =
  ## Solid stroke color with full opacity.
  s.strokeFill(r, g, b, 255'u8)

proc render*(c: Canvas) =
  ## `update` + `draw` + `sync`; raises `ThorvgError` on failure.
  check c.update(), "update"
  check c.draw(true), "draw"
  check c.sync(), "sync"

proc fitPicture*(path: string, width, height: int): Picture =
  ## Loads `path` (type chosen by extension / header) and scales it to fit
  ## `width` x `height` keeping the aspect ratio, centered. Raises `ThorvgError`
  ## when the file cannot be loaded or has no size.
  result = newPicture()
  let r = result.load(path)
  if r != Result.Success:
    raise newException(ThorvgError, "cannot load " & path & ": " & $r)
  var w, h = 0.0'f32
  check result.size(w, h), "picture size"
  if not (w > 0.0'f32 and h > 0.0'f32):
    raise newException(ThorvgError, "bad picture size " & $w & "x" & $h)
  let fw = float32(width)
  let fh = float32(height)
  let scale = min(fw / w, fh / h)
  let nw = w * scale
  let nh = h * scale
  check result.size(nw, nh), "picture size"
  check result.translate((fw - nw) * 0.5'f32, (fh - nh) * 0.5'f32), "translate"

