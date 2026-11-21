## Rasterizer facade of the CPU engine: surface setup and pixel-format utilities.
##
## Ported from the "External Interfaces" part of `src/renderer/cpu_engine/tvgSwRaster.cpp`
## and `rasterInit` of `tvgSwRasterCore.cpp`. The drawing procs live in sibling modules and
## are re-exported, so `import raster` gives the whole rasterizer API:
##
## - `rastercore`: `rasterClear`, translucent/solid pixel loops, predicates
## - `rastershape`: `rasterShape`, `rasterStroke`
## - `rastergrad`: `rasterGradientShape`, `rasterGradientStroke`
## - `rasterimage` / `rasterscale`: `rasterDirectImage`, `rasterDirectRleImage`,
##   `rasterScaledImage`, `rasterScaledRleImage`, and (via `texmappoly`) the full texture mapper
##   `rasterTexmapPolygon` for rotated/sheared images
##
## Differences from C++: `rasterInit` has nothing to do (no SIMD dispatch; the function
## pointer globals are gone); the compositor image shares its pixels with the compositor
## surface through `SwImage.surface` (T20 must set `cmp.compositor.image.surface = cmp`).

import ../../core/types
import ../../renderer/render
import ./[common, pixel, blend, rastercore, rastershape, rastergrad, rasterimage]

export rastercore, rastershape, rastergrad, rasterimage

proc rasterInit*() =
  ## Scalar build: nothing to select (C++ picks AVX/NEON kernels here).
  discard

proc rasterCompositor*(surface: SwSurface): Result =
  ## Installs the color join and the alpha/luma getters for the surface color space.
  surface.alphas[0] = maskAlpha
  surface.alphas[1] = maskInvAlpha
  if surface.cs == ColorSpace.ABGR8888 or surface.cs == ColorSpace.ABGR8888S:
    surface.join = abgrJoin
    surface.alphas[2] = abgrLuma
    surface.alphas[3] = abgrInvLuma
    Result.Success
  elif surface.cs == ColorSpace.ARGB8888 or surface.cs == ColorSpace.ARGB8888S:
    surface.join = argbJoin
    surface.alphas[2] = argbLuma
    surface.alphas[3] = argbInvLuma
    Result.Success
  else: Result.NonSupport

proc rasterUnpremultiplySurface*(surface: RenderSurface) =
  if surface.channelSize == 4:
    for y in 0 ..< int(surface.h):
      for x in 0 ..< int(surface.w):
        let i = y * int(surface.stride) + x
        surface.data[i] = unpremultiply(surface.data[i])
    surface.premultiplied = false

proc rasterPremultiplySurface*(surface: RenderSurface) =
  if not surface.premultiplied and surface.channelSize == 4:
    surface.premultiplied = true
    for y in 0 ..< int(surface.h):
      for x in 0 ..< int(surface.w):
        let i = y * int(surface.stride) + x
        let c = surface.data[i]
        if alpha(c) != 255: surface.data[i] = premultiply(c, alpha(c))

proc rasterConvertCS*(surface: RenderSurface, to: ColorSpace): bool =
  ## Swaps ABGR <-> ARGB in place; any other conversion is unsupported (false).
  let fromCs = surface.cs
  let isAbgr = fromCs == ColorSpace.ABGR8888 or fromCs == ColorSpace.ABGR8888S
  let isArgb = fromCs == ColorSpace.ARGB8888 or fromCs == ColorSpace.ARGB8888S
  let toAbgr = to == ColorSpace.ABGR8888 or to == ColorSpace.ABGR8888S
  let toArgb = to == ColorSpace.ARGB8888 or to == ColorSpace.ARGB8888S
  if fromCs == to: true
  elif (isAbgr and toArgb) or (isArgb and toAbgr):
    surface.cs = to
    rasterABGRtoARGB(surface)
  else: false
