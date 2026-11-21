## Image preparation for the CPU engine (outline, render box, RLE of an image).
##
## Ported from `src/renderer/cpu_engine/tvgSwImage.cpp`. An image is drawn as the
## rectangle `(0,0)-(w,h)` transformed by the paint matrix; shifted-only images are
## `direct`, uniformly scaled ones `scaled`, the rest need the texmap path (simplified,
## see `rasterimage.nim`). Needs `utilExport`/`utilBBox` of `util.nim` (T10b).
## The memory pool is gone: the outline is a fresh object owned by the image.

import ../../core/[types, geom]
import ./[common, rle, rle_clip, util]

proc genOutline(image: SwImage): SwOutline =
  let w = float32(image.w)
  let h = float32(image.h)
  SwOutline(
    cmds: @[PathCommand.MoveTo, PathCommand.LineTo, PathCommand.LineTo, PathCommand.LineTo,
            PathCommand.Close],
    fpts: @[pt(0.0'f32, 0.0'f32), pt(w, 0.0'f32), pt(w, h), pt(0.0'f32, h)],
    fillRule: FillRule.NonZero)

proc imagePrepare*(image: SwImage, transform: Matrix, clipBox: Region,
                   renderBox: var Region): bool =
  ## Classifies the transform (direct/scaled), builds the outline and computes `renderBox`
  ## clipped to `clipBox`; false if the image is entirely outside.
  image.direct = equal(transform.e11, 1.0'f32) and equal(transform.e22, 1.0'f32) and
    zero(transform.e12) and zero(transform.e21)
  if image.direct:
    image.ox = -int32(nearbyint(transform.e13))
    image.oy = -int32(nearbyint(transform.e23))
  else:
    image.scale = scaling(transform)
    image.scaled = zero(transform.e12) and zero(transform.e21)
  image.outline = genOutline(image)
  var bbox: BBox
  utilExport(image.outline, transform, bbox)
  utilBBox(bbox, clipBox, renderBox, image.direct)

proc imageGenRle*(image: SwImage, renderBox: Region, antiAlias: bool): bool =
  ## Scan-converts the image outline into `image.rle` (reused when present).
  image.rle = rleRender(image.rle, image.outline, renderBox, antiAlias)
  image.rle != nil

proc imageReset*(image: SwImage) =
  rleReset(image.rle)
