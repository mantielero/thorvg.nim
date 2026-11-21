## Gradient preparation of the CPU engine: color table, transforms, solid detection.
##
## Ported from `src/renderer/cpu_engine/tvgSwFill.cpp` (SIMD not ported, D3). The span
## rasterizers (`fillRaster*`) live in `fill_raster.nim` and the per-pixel generator in
## `fill_gen.nim`; this module re-exports them so `import thorvg/engine/cpu/fill` is enough.
##
## Public API (the rasterizer T12b depends on it):
## - `fillPrepare(fill: var SwFill, fdata: Fill, transform: Matrix, surface: SwSurface,
##   opacity: uint8, ctable: bool): bool` creates `fill` when nil (and builds the color
##   table), otherwise rebuilds it only if `ctable`. C++ returns true when `fdata` is
##   null: the caller must simply not call it for an absent fill.
## - `fillFetchSolid(fill, fdata, stop: var ColorStop): bool` last stop of a solid fill.
## - `fillReset(fill)` clears `translucent`/`solid`.
## - `fillRasterMask`, `fillRasterMaskDirect`, `fillRasterBlend`, `fillRasterBlendEx`,
##   `fillRasterMatte`: exact signatures in the header of `fill_raster.nim`.
## - `colorAt(fill, pos)`, `spreadIndex(fill, pos)` (from `fill_gen`): sample the table.
##
## `surface.join` must be set (see `abgrJoin`/`argbJoin` in `blend.nim`).

import std/math
import ../../core/[types, geom, fill]
import ../../renderer/render
import ./[common, pixel, fill_gen, fill_raster]

export fill_raster
export fill_gen.colorAt, fill_gen.spreadIndex

const MarginMax = 40  ## max color table entries of the anti-aliasing margin at each end

{.push floatChecks: off.}

func adjustAAMargin(margin: var int, count: int) =
  let threshold = toI32(float32(count) * 0.1'f32)
  if margin > threshold: margin = threshold
  if margin > MarginMax: margin = MarginMax

func unblend(c: uint32): uint32 =
  let a = c shr 24
  if a == 255 or a == 0: return c
  let invA = 255.0'f32 / float32(a)
  let c0 = uint32(toI32(float32((c shr 16) and 0xff) * invA) and 0xff)
  let c1 = uint32(toI32(float32((c shr 8) and 0xff) * invA) and 0xff)
  let c2 = uint32(toI32(float32(c and 0xff) * invA) and 0xff)
  (a shl 24) or (c0 shl 16) or (c1 shl 8) or c2

func applyRepeatAA(f: SwFill, colors: seq[ColorStop]) =
  let cnt = colors.len
  if cnt == 1: return
  # count that satisfies (i + 0.5) / SwColorTable < offset
  let tableSize = float32(SwColorTable)
  let countBegin = toI32(max(0.0'f32, floor(colors[1].offset * tableSize - 0.5'f32) + 1.0'f32))
  let countEnd = toI32(max(0.0'f32,
    floor((1.0'f32 - colors[cnt - 2].offset) * tableSize - 0.5'f32) + 1.0'f32))
  # estimate the AA margin
  var begin = if zero(f.extent): 0 else: toI32(800.0'f32 / f.extent)
  adjustAAMargin(begin, countBegin)
  var finish = begin
  adjustAAMargin(finish, countEnd)
  if begin == 0 or finish == 0: return
  var i = SwColorTable - finish
  let rgbaEnd = unblend(f.ctable[i])
  let rgbaBegin = unblend(f.ctable[begin])
  let dt = 1.0'f32 / (float32(begin) + float32(finish) + 1.0'f32)
  var t = dt
  while i != begin:
    let dist = 255 - toI32(255.0'f32 * t)
    let color = interpolate(rgbaEnd, rgbaBegin, uint8(dist and 0xff))
    f.ctable[i] = alphaBlend(color or 0xff000000'u32, color shr 24)
    inc i
    if i == SwColorTable: i = 0
    t += dt

proc genColorTable(f: SwFill, colors: seq[ColorStop], surface: SwSurface, opacity: uint8,
                   begin, finish: int) =
  ## Generates the color table entries over [begin, finish).
  var a = multiply(colors[0].a, opacity)
  if a < 255: f.translucent = true
  var rgba = surface.join(colors[0].r, colors[0].g, colors[0].b, a)
  let step = 1.0'f32 / float32(SwColorTable)
  var pos = (float32(begin) + 0.5'f32) * step
  var i = begin
  let padColor = alphaBlend(rgba or 0xff000000'u32, uint32(a))
  while i < finish and (i == 0 or pos <= colors[0].offset):
    f.ctable[i] = padColor
    inc i
    pos += step
  for j in 0 ..< colors.len - 1:
    let curr = colors[j]
    let next = colors[j + 1]
    let div0 = next.offset - curr.offset
    let delta = if div0 != 0.0'f32: 1.0'f32 / div0 else: 0.0'f32
    let a2 = multiply(next.a, opacity)
    if not f.translucent and a2 < 255: f.translucent = true
    let rgba2 = surface.join(next.r, next.g, next.b, a2)
    while i < finish and pos < next.offset:
      let t = (pos - curr.offset) * delta
      let dist2 = 255 - toI32(255.0'f32 * t)
      let color = interpolate(rgba, rgba2, uint8(dist2 and 0xff))
      f.ctable[i] = alphaBlend(color or 0xff000000'u32, color shr 24)
      inc i
      pos += step
    rgba = rgba2
    a = a2
  rgba = alphaBlend(rgba or 0xff000000'u32, uint32(a))
  while i < finish:
    f.ctable[i] = rgba
    inc i
  if finish == SwColorTable: f.ctable[SwColorTable - 1] = rgba

proc updateColorTable(f: SwFill, fdata: Fill, surface: SwSurface, opacity: uint8): bool =
  if f.solid: return true
  if fdata.stops.len == 0: return false
  genColorTable(f, fdata.stops, surface, opacity, 0, SwColorTable)
  if f.spread == FillSpread.Repeat and fdata.kind != FillKind.Conic:
    applyRepeatAA(f, fdata.stops)
  true

proc updateAAMargin(f: SwFill, fdata: Fill, surface: SwSurface, opacity: uint8): bool =
  ## Updates only the table margins after the extent changed.
  if fdata.stops.len == 0: return false
  genColorTable(f, fdata.stops, surface, opacity, 0, MarginMax)
  genColorTable(f, fdata.stops, surface, opacity, SwColorTable - MarginMax, SwColorTable)
  applyRepeatAA(f, fdata.stops)
  true

func setInverse(f: SwFill, m: Matrix) =
  f.a11 = m.e11
  f.a12 = m.e12
  f.a13 = m.e13
  f.a21 = m.e21
  f.a22 = m.e22
  f.a23 = m.e23

func prepareRadial(f: SwFill, fdata: Fill, pTransform: Matrix, extentChanged: var bool): bool =
  var fx, fy, fr: float32
  f.solid = not correct(fdata, fx, fy, fr)
  if f.solid: return true
  f.rdr = fdata.r - fr
  f.rdx = fdata.center.x - fx
  f.rdy = fdata.center.y - fy
  f.fr = fr
  f.fx = fx
  f.fy = fy
  f.aa = f.rdr * f.rdr - f.rdx * f.rdx - f.rdy * f.rdy
  # relative epsilon
  let precision = max(1e-5'f32, max(f.rdr * f.rdr, 1.0'f32) * 1e-4'f32)
  if f.aa < precision: f.aa = precision
  f.invA = 1.0'f32 / f.aa
  let transform = pTransform * fdata.transform
  var itransform: Matrix
  if not inverse(transform, itransform): return false
  setInverse(f, itransform)
  # The transform maps the gradient circle to an ellipse: take its semi-minor axis
  # (the smaller singular value), where the table packs tightest and needs most margin.
  let sx = transform.e11 * transform.e11 + transform.e21 * transform.e21
  let sy = transform.e12 * transform.e12 + transform.e22 * transform.e22
  let sxy = transform.e11 * transform.e12 + transform.e21 * transform.e22
  let d = sqrt((sx - sy) * (sx - sy) + 4.0'f32 * sxy * sxy)
  let ext = fdata.r * sqrt(0.5'f32 * max(0.0'f32, sx + sy - d))
  if not equal(ext, f.extent):
    extentChanged = true
    f.extent = ext
  true

func prepareConic(f: SwFill, fdata: Fill, pTransform: Matrix): bool =
  f.cx = fdata.center.x
  f.cy = fdata.center.y
  f.offset = -fdata.angle / 360.0'f32
  let transform = pTransform * fdata.transform
  var itransform: Matrix
  if not inverse(transform, itransform): return false
  setInverse(f, itransform)
  # conic anti-aliasing variables
  let radian = fdata.angle * (MathPi / 180.0'f32)
  let seam = pt(cos(radian), sin(radian))
  f.normal = pt(-seam.y, seam.x)
  let xStep = pt(f.a11, f.a21)
  let yStep = pt(f.a12, f.a22)
  let dFdx = dot(f.normal, xStep)
  let dFdy = dot(f.normal, yStep)
  let fwidth = abs(dFdx) + abs(dFdy)
  f.invFwidth = if zero(dFdx) or zero(dFdy): 0.0'f32 else: 1.0'f32 / fwidth
  f.distanceDx = dFdx * f.invFwidth
  f.seamProjectionDx = dot(seam, xStep)
  true

func prepareLinear(f: SwFill, fdata: Fill, pTransform: Matrix, extentChanged: var bool): bool =
  let x1 = fdata.p1.x
  let y1 = fdata.p1.y
  f.dx = fdata.p2.x - x1
  f.dy = fdata.p2.y - y1
  let len = f.dx * f.dx + f.dy * f.dy
  if len < FloatEpsilon:
    if zero(f.dx) and zero(f.dy): f.solid = true
    return true
  f.dx /= len
  f.dy /= len
  f.offset = -f.dx * x1 - f.dy * y1
  let transform = pTransform * fdata.transform
  var itransform: Matrix
  if not inverse(transform, itransform): return false
  f.offset += f.dx * itransform.e13 + f.dy * itransform.e23
  let dx = f.dx
  f.dx = dx * itransform.e11 + f.dy * itransform.e21
  f.dy = dx * itransform.e12 + f.dy * itransform.e22
  # dx/dy is the change in screen space; the reciprocal of its magnitude is the pixel
  # span of one full color table cycle.
  let ext = 1.0'f32 / sqrt(f.dx * f.dx + f.dy * f.dy)
  if not equal(ext, f.extent):
    extentChanged = true
    f.extent = ext
  true

func fillReset*(fill: SwFill) =
  fill.translucent = false
  fill.solid = false

proc fillPrepare*(fill: var SwFill, fdata: Fill, transform: Matrix, surface: SwSurface,
                  opacity: uint8, ctable: bool): bool =
  var ctable = ctable
  if fill == nil:
    fill = SwFill()
    ctable = true
  elif ctable:
    fillReset(fill)
  # a single color stop is treated as solid
  if fdata.stops.len == 1:
    fill.solid = true
    return true
  var extentChanged = false
  fill.spread = fdata.spread
  fill.kind = fdata.kind
  case fdata.kind
  of FillKind.Linear:
    if not prepareLinear(fill, fdata, transform, extentChanged): return false
  of FillKind.Radial:
    if not prepareRadial(fill, fdata, transform, extentChanged): return false
  of FillKind.Conic:
    if not prepareConic(fill, fdata, transform): return false
  if ctable: updateColorTable(fill, fdata, surface, opacity)
  elif extentChanged and fill.spread == FillSpread.Repeat:
    updateAAMargin(fill, fdata, surface, opacity)
  else: true

func fillFetchSolid*(fill: SwFill, fdata: Fill, stop: var ColorStop): bool =
  ## True and the last color stop when the fill is solid.
  if not fill.solid or fdata.stops.len == 0: return false
  stop = fdata.stops[^1]
  true

{.pop.}
