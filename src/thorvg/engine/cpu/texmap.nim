## Scanline segments of the texture-mapped triangle rasterizer (rotated/sheared images).
##
## Ported from the `_raster*PolygonImageSegment*` functions of
## `src/renderer/cpu_engine/tvgSwRasterTexmap.h`. The four C++ variants (32-bit with an
## optional matte, blending, 8-bit mask, and the unsupported mask-composition one) share
## one row loop here; `SegMode` selects the per-pixel body. Triangle setup is in
## `texmappoly.nim`.
##
## Quirks kept on purpose: a texel outside the image skips the pixel WITHOUT advancing
## the destination or the UV (C++ `continue`), so the rest of the row is skipped; float to
## int conversions follow x86 (`toI32`); the masked-composition segment draws nothing.

import ../../core/types
import ../../renderer/render
import ./[hot, common, pixel, blend, rastercore, fill_gen]

type
  SegMode* = enum
    smPlain    ## premultiplied source over destination (32-bit)
    smMatte    ## same, modulated by the compositor alpha/luma
    smBlend    ## through the surface blender
    smGray     ## 8-bit mask surface, no filtering
    smNone     ## unsupported combination: draws nothing

  TexmapCtx* = object
    surface*: SwSurface
    image*: SwImage
    bbox*: Region
    opacity*: uint8
    dudx*, dvdx*: float32
    dxdya*, dxdyb*, dudya*, dvdya*: float32
    xa*, xb*, ua*, va*: float32

{.push floatChecks: off.}

func modf(v: float32): int =
  255 - (toI32(v * 256.0'f32) and 255)

func feathering(iru, irv, ar, ab, sw, sh: int): uint8 =
  ## Alpha of the edge texels so that the polygon border is anti-aliased.
  let car = uint8(ar)
  let cab = uint8(ab)
  if irv == 1:
    if iru == 1: uint8(255 - int(multiply(car, cab)))
    elif iru == sw: multiply(car, 255'u8 - cab)
    else: 255'u8 - cab
  elif irv == sh:
    if iru == 1: multiply(255'u8 - car, cab)
    elif iru == sw: multiply(car, cab)
    else: cab
  elif iru == 1: 255'u8 - car
  elif iru == sw: car
  else: 255'u8

proc texel(image: SwImage, uu, vv, ar, ab: int): uint32 =
  ## Source pixel at (uu, vv), bilinearly filtered with weights `ar` (x) and `ab` (y).
  let stride = int(image.stride)
  let sw = int(image.w)
  let sh = int(image.h)
  result = image.surface.data[vv * stride + uu]
  if image.filter == FilterMethod.Bilinear:
    let iru = uu + 1
    let irv = vv + 1
    if iru < sw:
      result = interpolate(result, image.surface.data[vv * stride + iru], uint8(ar))
    if irv < sh:
      var px2 = image.surface.data[irv * stride + uu]
      if iru < sw:
        px2 = interpolate(px2, image.surface.data[irv * stride + iru], uint8(ar))
      result = interpolate(result, px2, uint8(ab))

proc drawPlain(ctx: TexmapCtx, needAA: bool, u, v: float32, uu, vv: int,
               dst: int) {.noRaiseHot.} =
  ## One pixel of the plain 32-bit variant. It has no indirect call, so (unlike
  ## `drawPixel32`) it cannot raise and the caller does not poll the thread-local error
  ## flag per pixel (see `hot.nim`, H-perf-3).
  let sfc {.cursor.} = ctx.surface
  let ar = modf(u)
  let ab = modf(v)
  let px = texel(ctx.image, uu, vv, ar, ab)
  var src = if ctx.opacity == 255: px else: alphaBlend(px, uint32(ctx.opacity))
  if needAA:
    let feather = feathering(uu + 1, vv + 1, ar, ab, int(ctx.image.w), int(ctx.image.h))
    if feather < 255: src = alphaBlend(src, uint32(feather))
  sfc.data[dst] = src + alphaBlend(sfc.data[dst], uint32(ialpha(src)))

proc drawPixel32(ctx: TexmapCtx, mode: SegMode, needAA: bool, u, v: float32, uu, vv: int,
                 dst: int, cmpIdx: int, getAlpha: SwAlpha) =
  ## One pixel of the matte and blend 32-bit variants.
  let sfc {.cursor.} = ctx.surface
  let sw = int(ctx.image.w)
  let sh = int(ctx.image.h)
  let ar = modf(u)
  let ab = modf(v)
  let iru = uu + 1
  let irv = vv + 1
  var px = texel(ctx.image, uu, vv, ar, ab)
  let feather = if needAA: feathering(iru, irv, ar, ab, sw, sh) else: 255'u8
  if mode == smBlend:
    if feather < 255: px = alphaBlend(px, uint32(feather))
    let d = sfc.data[dst]
    sfc.data[dst] = interpolate(sfc.blender(sfc, unpremultiply(px), d), d,
                                multiply(ctx.opacity, alpha(px)))
  else:
    var src: uint32
    if mode == smMatte:
      let a = getAlpha(sfc.compositor.image.cmpAt(cmpIdx))
      src = if ctx.opacity == 255: alphaBlend(px, uint32(a))
            else: alphaBlend(px, uint32(multiply(ctx.opacity, a)))
    else:
      src = if ctx.opacity == 255: px else: alphaBlend(px, uint32(ctx.opacity))
    if feather < 255: src = alphaBlend(src, uint32(feather))
    sfc.data[dst] = src + alphaBlend(sfc.data[dst], uint32(ialpha(src)))

proc rasterSegment*(ctx: var TexmapCtx, yStart, yEnd: int, mode: SegMode, needAA: bool) =
  ## Fills the rows `yStart ..< yEnd` between the edges `xa`/`xb`, interpolating UV, and
  ## advances the edge state of `ctx` (C++ `_rasterPolygonImageSegment*`).
  if mode == smNone: return
  let bbox = ctx.bbox
  let sfc {.cursor.} = ctx.surface
  let stride = int(sfc.stride)
  let iw = int(ctx.image.w)
  let ih = int(ctx.image.h)
  let getAlpha = if mode == smMatte: surfaceAlpha(sfc, sfc.compositor.meth) else: nil
  let cimg {.cursor.} = if mode == smMatte: sfc.compositor.image else: nil
  var y = max(yStart, int(bbox.yMin))
  let yLast = min(yEnd, int(bbox.yMax))
  while y < yLast:
    let x1 = max(toI32(ctx.xa), int(bbox.xMin))
    let x2 = min(toI32(ctx.xb), int(bbox.xMax))
    if x2 - x1 >= 1 and x1 < int(bbox.xMax) and x2 > int(bbox.xMin):
      # subtexel pre-stepping on UV
      let dx = 1.0'f32 - (ctx.xa - float32(x1))
      var u = ctx.ua + dx * ctx.dudx
      var v = ctx.va + dx * ctx.dvdx
      var dst = y * stride + x1
      var cmpIdx = if mode == smMatte: y * int(cimg.stride) + x1 else: 0
      var x = x1
      while x < x2:
        inc x
        let uu = toI32(u)
        let vv = toI32(v)
        if uu >= 0 and vv >= 0 and uu < iw and vv < ih:
          if mode == smGray:
            sfc.buf8[dst] = multiply(alpha(ctx.image.surface.data[vv * int(ctx.image.stride) + uu]),
                                     ctx.opacity)
          elif mode == smPlain:
            drawPlain(ctx, needAA, u, v, uu, vv, dst)
          else:
            drawPixel32(ctx, mode, needAA, u, v, uu, vv, dst, cmpIdx, getAlpha)
            inc cmpIdx
          inc dst
          u += ctx.dudx
          v += ctx.dvdx
    ctx.xa += ctx.dxdya
    ctx.xb += ctx.dxdyb
    ctx.ua += ctx.dudya
    ctx.va += ctx.dvdya
    inc y

{.pop.}

func segMode*(sfc: SwSurface): SegMode =
  ## Which segment variant the C++ dispatch picks for this surface state.
  if compositing(sfc):
    if not matting(sfc): smNone
    elif sfc.channelSize == 1: smGray
    else: smMatte
  elif blending(sfc): (if sfc.channelSize == 1: smNone else: smBlend)
  elif sfc.channelSize == 1: smGray
  else: smPlain
