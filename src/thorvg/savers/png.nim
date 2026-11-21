## Minimal PNG saver (ADDITION: the C++ code base has no PNG saver, see D-L7-5).
##
## Importing this module registers the "png" extension with `renderer/saver`. A paint
## (or the current frame of an animation) is rendered with the software engine on a
## transparent canvas that covers `0 .. ceil(x + w)` x `0 .. ceil(y + h)` of its
## bounds, behind the optional background paint, and written with
## `display/imageio.writePng`. The work is done in `save`; `close` is a no-op.
## `quality` and `fps` are ignored.

import std/math
import ../core/types
import ../renderer/[paint, canvas, saver, animation]
import ../engine/cpu/renderer as swengine
import ../display/imageio

const MaxPixels = 1 shl 26

type PngSaver* = ref object of SaveModule
  ## Import it (`from thorvg/savers/png import PngSaver`) to register "png".

proc renderPng(p, bg: Paint, filename: string): bool =
  ## Renders `p` over `bg` and writes the PNG; false when nothing could be saved.
  var x, y, w, h = 0.0'f32
  if p.bounds(x, y, w, h) != Result.Success: return false
  let width = int(ceil(x + w))
  let height = int(ceil(y + h))
  if width <= 0 or height <= 0 or width * height > MaxPixels: return false
  let c = newSwCanvas(width, height)
  let hasBg = bg != nil and bg.parent == nil
  if hasBg and c.add(bg) != Result.Success: return false
  result = c.add(p) == Result.Success and c.update() == Result.Success and
    c.draw(true) == Result.Success and c.sync() == Result.Success
  if result:
    try:
      writePng(filename, swSurface(c))
    except IOError:
      result = false
  # give the paints back (they can be saved or drawn again)
  discard c.remove(p)
  if hasBg: discard c.remove(bg)

method save(m: PngSaver, p: Paint, bg: Paint, filename: string,
    quality: uint32): bool =
  renderPng(p, bg, filename)

method save(m: PngSaver, a: Animation, bg: Paint, filename: string,
    quality: uint32, fps: uint32): bool =
  renderPng(a.picture, bg, filename)

registerSaver("png", proc (): SaveModule {.nimcall.} = PngSaver())
