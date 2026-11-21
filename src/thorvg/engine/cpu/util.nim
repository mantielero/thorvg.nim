## Outline export (float -> 26.6 fixed point) and render-box helpers.
##
## Ported from `src/renderer/cpu_engine/tvgSwUtil.cpp`. The C++ outline points at a
## `RenderPath`; here `SwOutline` owns `cmds` + `fpts` (float path points) and
## `utilExport` fills `pts` (fixed point, the only points `rle.nim` reads).

import std/math
import ../../core/[types, geom]
import ./common

func toInt32(f: float32): int32 =
  ## C float -> int32 conversion (truncation); out of range or NaN gives
  ## `int32.low` like the x86 `cvttss2si` instruction.
  if f >= -2147483648.0'f32 and f < 2147483648.0'f32: int32(f) else: int32.low

proc utilExport*(outline: SwOutline, transform: Matrix, bbox: var BBox) =
  ## Transforms `outline.fpts` into `outline.pts` (x64 fixed point) and
  ## returns the bounds of the transformed float points in `bbox`.
  bbox = initBBox()
  outline.pts.setLen(0)
  outline.pts.setLen(outline.fpts.len)
  for i, pt in outline.fpts:
    let t = pt * transform
    if bbox.min.x > t.x: bbox.min.x = t.x
    if bbox.max.x < t.x: bbox.max.x = t.x
    if bbox.min.y > t.y: bbox.min.y = t.y
    if bbox.max.y < t.y: bbox.max.y = t.y
    outline.pts[i] = SwPoint(x: toInt32(t.x * 64.0'f32), y: toInt32(t.y * 64.0'f32))

proc utilBBox*(bbox: BBox, clipBox: Region, renderBox: var Region, fastTrack: bool): bool =
  ## Integer render box of `bbox` (rounded for fast-track rectangles, otherwise the
  ## enclosing box) clipped to `clipBox`; true if something is left.
  if fastTrack:
    renderBox.xMin = toInt32(round(bbox.min.x))
    renderBox.yMin = toInt32(round(bbox.min.y))
    renderBox.xMax = toInt32(round(bbox.max.x))
    renderBox.yMax = toInt32(round(bbox.max.y))
  else:
    renderBox.xMin = toInt32(floor(bbox.min.x))
    renderBox.yMin = toInt32(floor(bbox.min.y))
    renderBox.xMax = toInt32(ceil(bbox.max.x))
    renderBox.yMax = toInt32(ceil(bbox.max.y))
  renderBox = intersect(renderBox, clipBox)
  renderBox.valid
