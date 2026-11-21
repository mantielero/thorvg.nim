## Gradient rasterizers (rectangles and RLE spans) of the CPU engine.
##
## Ported from the "Rect Gradient" / "Rle Gradient" sections of
## `src/renderer/cpu_engine/tvgSwRaster.cpp` plus `rasterGradientShape` and
## `rasterGradientStroke`. The per-span work is done by the `fillRaster*` procs of
## `fill_raster.nim`; this module only chooses the variant (mask, matte, blending,
## translucent, solid) and walks rows or spans. A gradient that is really one solid
## color (`fillFetchSolid`) is drawn through `rasterShape` / `rasterStroke`.

import ../../core/[types, geom, fill]
import ../../renderer/render
import ./[common, pixel, blend, fill as swfill, rastercore, rastershape]

proc matteSpan(fill: SwFill, surface: SwSurface, cimg: SwImage, getAlpha: SwAlpha,
               dOff, y, x, n, cOff: int, opacity: uint8) =
  if cimg.channelSize == 1:
    fillRasterMatte(fill, surface.data, dOff, y, x, n, cimg.surface.buf8, cOff, getAlpha, opacity)
  else:
    fillRasterMatte(fill, surface.data, dOff, y, x, n, cimg.surface.data, cOff, getAlpha, opacity)

# ---- rect ----

proc gradientRect(surface: SwSurface, bbox: Region, fill: SwFill): bool =
  let w = max(int(bbox.sw), 0)
  let h = max(int(bbox.sh), 0)
  let x0 = int(bbox.xMin)
  let stride = int(surface.stride)
  if compositing(surface):
    let cmp = surface.compositor
    let cimg = cmp.image
    if matting(surface):
      if surface.channelSize == 1: return false
      let getAlpha = surfaceAlpha(surface, cmp.meth)
      for y in 0 ..< h:
        let py = int(bbox.yMin) + y
        matteSpan(fill, surface, cimg, getAlpha, py * stride + x0, py, x0, w,
                  py * int(cimg.stride) + x0, 255)
      true
    else:
      let maskOp = getMaskOp(cmp.meth)
      for y in 0 ..< h:
        let py = int(bbox.yMin) + y
        if maskDirect(cmp.meth):
          fillRasterMaskDirect(fill, surface.buf8, py * stride + x0, py, x0, w,
                               cimg.surface.buf8, py * int(cimg.stride) + x0, maskOp, 255)
        else:
          fillRasterMask(fill, cimg.surface.buf8, py * int(cimg.stride) + x0, py, x0, w,
                         maskOp, 255)
      if maskDirect(cmp.meth): true else: compositeMaskImage(surface, cimg, cmp.bbox)
  elif surface.channelSize == 1:
    for y in 0 ..< h:
      let py = int(bbox.yMin) + y
      fillRasterMask(fill, surface.buf8, py * stride + x0, py, x0, w, opMaskAdd, 255)
    true
  else:
    let op: SwBlenderA = if fill.translucent: opBlendPreNormal else: opBlendSrcOver
    for y in 0 ..< h:
      let py = int(bbox.yMin) + y
      if blending(surface):
        fillRasterBlendEx(surface, fill, surface.data, py * stride + x0, py, x0, w, op,
                          surface.blender, 255)
      else: fillRasterBlend(fill, surface.data, py * stride + x0, py, x0, w, op, 255)
    true

# ---- rle ----

proc gradientRle(surface: SwSurface, rle: SwRle, fill: SwFill): bool =
  let stride = int(surface.stride)
  if compositing(surface):
    let cmp = surface.compositor
    let cimg = cmp.image
    if matting(surface):
      if surface.channelSize == 1: return false
      let getAlpha = surfaceAlpha(surface, cmp.meth)
      for span in rle.spans:
        let py = int(span.y)
        let px = int(span.x)
        matteSpan(fill, surface, cimg, getAlpha, py * stride + px, py, px, int(span.len),
                  py * int(cimg.stride) + px, span.coverage)
      true
    else:
      let maskOp = getMaskOp(cmp.meth)
      let direct = maskDirect(cmp.meth)
      for span in rle.spans:
        let py = int(span.y)
        let px = int(span.x)
        if direct:
          fillRasterMaskDirect(fill, surface.buf8, py * stride + px, py, px, int(span.len),
                               cimg.surface.buf8, py * int(cimg.stride) + px, maskOp,
                               span.coverage)
        else:
          fillRasterMask(fill, cimg.surface.buf8, py * int(cimg.stride) + px, py, px,
                         int(span.len), maskOp, span.coverage)
      if direct: true else: compositeMaskImage(surface, cimg, cmp.bbox)
  elif surface.channelSize == 1:
    for span in rle.spans:
      fillRasterMask(fill, surface.buf8, int(span.y) * stride + int(span.x), int(span.y),
                     int(span.x), int(span.len), opMaskAdd, span.coverage)
    true
  else:
    for span in rle.spans:
      let py = int(span.y)
      let px = int(span.x)
      let n = int(span.len)
      let off = py * stride + px
      if blending(surface):
        fillRasterBlendEx(surface, fill, surface.data, off, py, px, n, opBlendPreNormal,
                          surface.blender, span.coverage)
      elif fill.translucent:
        if span.coverage == 255:
          fillRasterBlend(fill, surface.data, off, py, px, n, opBlendPreNormal, 255)
        else: fillRasterBlend(fill, surface.data, off, py, px, n, opBlendNormal, span.coverage)
      elif span.coverage == 255:
        fillRasterBlend(fill, surface.data, off, py, px, n, opBlendSrcOver, 255)
      else: fillRasterBlend(fill, surface.data, off, py, px, n, opBlendInterp, span.coverage)
    true

# ---- external interface ----

proc rasterGradientShape*(surface: SwSurface, shape: SwShape, bbox: Region, fdata: Fill,
                          opacity: uint8): bool =
  ## Fills the shape with its gradient `shape.fill` (prepared from `fdata`).
  if shape.fill == nil: return false
  var stop: ColorStop
  if fillFetchSolid(shape.fill, fdata, stop):
    let a = multiply(stop.a, opacity)
    var c = RGBA(r: stop.r, g: stop.g, b: stop.b, a: a)
    if a > 0: rasterShape(surface, shape, bbox, c) else: true
  elif shape.fastTrack: gradientRect(surface, bbox, shape.fill)
  elif shape.rle.valid: gradientRle(surface, shape.rle, shape.fill)
  else: false

proc rasterGradientStroke*(surface: SwSurface, shape: SwShape, bbox: Region, fdata: Fill,
                           opacity: uint8): bool =
  if shape.stroke == nil or shape.stroke.fill == nil or shape.strokeRle.invalid: return false
  var stop: ColorStop
  if fillFetchSolid(shape.stroke.fill, fdata, stop):
    var c = RGBA(r: stop.r, g: stop.g, b: stop.b, a: multiply(stop.a, opacity))
    if c.a > 0: rasterStroke(surface, shape, bbox, c) else: true
  else: gradientRle(surface, shape.strokeRle, shape.stroke.fill)
