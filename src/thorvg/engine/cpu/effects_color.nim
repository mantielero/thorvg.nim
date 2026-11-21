## CPU engine scene effects, part 3: fill, tint and tritone.
##
## Ported from the color effects of `src/renderer/cpu_engine/tvgSwPostEffect.cpp`.
## With `direct` the result is composed straight into the surface under the
## composition (`recoverSfc`) and the composition is flagged as already done.

import ../../core/[types, geom]
import ../../renderer/[effect, render]
import ./[common, pixel]

proc fillUpdate*(p: FillEffect) = p.valid = true
proc tintUpdate*(p: TintEffect) = p.valid = p.intensity > 0
proc tritoneUpdate*(p: TritoneEffect) = p.valid = p.blender < 255

template eachPixel(cmp: SwCompositor, direct: bool, body: untyped) =
  ## Visits the pixels of the composition region. `px` is the source pixel (the
  ## composition image); `dst` is the destination buffer element: the surface below
  ## when `direct`, else the composition image itself.
  let bbox = cmp.bbox
  let w = int(bbox.sw)
  let h = int(bbox.sh)
  let sstride = int(cmp.image.stride)
  let sbase = int(bbox.yMin) * sstride + int(bbox.xMin)
  if direct:
    let rsfc = cmp.recoverSfc
    let dstride = int(rsfc.stride)
    let dbase = int(bbox.yMin) * dstride + int(bbox.xMin)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let px {.inject.} = cmp.image.surface.data[sbase + y * sstride + x]
        template dst(): untyped {.inject.} = rsfc.data[dbase + y * dstride + x]
        body
    cmp.valid = true  # no need for the subsequent composition
  else:
    for y in 0 ..< h:
      for x in 0 ..< w:
        let px {.inject.} = cmp.image.surface.data[sbase + y * sstride + x]
        template dst(): untyped {.inject.} = cmp.image.surface.data[sbase + y * sstride + x]
        body

proc effectFill*(cmp: SwCompositor, p: FillEffect, direct: bool): bool =
  let opacity = if direct: multiply(p.color[3], cmp.opacity) else: p.color[3]
  let color = cmp.recoverSfc.join(p.color[0], p.color[1], p.color[2], 255)
  eachPixel(cmp, direct):
    if direct:
      let a = multiply(opacity, alpha(px))
      dst = alphaBlend(color, uint32(a)) + alphaBlend(dst, uint32(255'u8 - a))
    else:
      dst = alphaBlend(color, uint32(multiply(opacity, alpha(px))))
  true

proc effectTint*(cmp: SwCompositor, p: TintEffect, direct: bool): bool =
  let rsfc = cmp.recoverSfc
  let black = rsfc.join(p.black[0], p.black[1], p.black[2], 255)
  let white = rsfc.join(p.white[0], p.white[1], p.white[2], 255)
  let opacity = cmp.opacity
  let luma = rsfc.alphas[2]
  eachPixel(cmp, direct):
    var val = interpolate(white, black, luma(px))
    if p.intensity < 255: val = interpolate(val, px, p.intensity)
    if direct: dst = interpolate(val, dst, multiply(opacity, alpha(px)))
    else: dst = alphaBlend(val, uint32(multiply(opacity, alpha(px))))
  true

func tritoneColor(s, m, h: uint32, l: int): uint32 =
  if l < 128:
    let a = uint32(min(l * 2, 255))
    alphaBlend(s, 255 - a) + alphaBlend(m, a)
  else:
    let a = uint32(2 * max(0, l - 128))
    alphaBlend(m, 255 - a) + alphaBlend(h, a)

proc effectTritone*(cmp: SwCompositor, p: TritoneEffect, direct: bool): bool =
  let rsfc = cmp.recoverSfc
  let shadow = rsfc.join(p.shadow[0], p.shadow[1], p.shadow[2], 255)
  let midtone = rsfc.join(p.midtone[0], p.midtone[1], p.midtone[2], 255)
  let highlight = rsfc.join(p.highlight[0], p.highlight[1], p.highlight[2], 255)
  let opacity = cmp.opacity
  let luma = rsfc.alphas[2]
  eachPixel(cmp, direct):
    var val = tritoneColor(shadow, midtone, highlight, int(luma(px)))
    if p.blender != 0: val = interpolate(px, val, p.blender)
    if direct: dst = interpolate(val, dst, multiply(opacity, alpha(px)))
    else: dst = alphaBlend(val, uint32(multiply(alpha(px), opacity)))
  true
