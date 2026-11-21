## Texture-mapped triangle setup and the image entry point of the CPU engine.
##
## Ported from `_rasterPolygonImage` and `rasterTexmapPolygon` of
## `src/renderer/cpu_engine/tvgSwRasterTexmap.h` (scan conversion after Mikael Kalms).
## The image rectangle is split into two triangles that are mapped with the paint
## transform; `texmap.nim` draws the scanline segments. All math is `float32` like C++.
##
## 2 triangles make one mesh (vertex indices):
##
##     0 -- 1
##     |  / |
##     | /  |
##     3 -- 2

import ../../core/[types, geom]
import ./[common, fill_gen, texmap]

type Vertex = object
  pt, uv: Point

{.push floatChecks: off.}

proc polygonImage(ctx: var TexmapCtx, vs: array[3, Vertex], needAA: bool) =
  var x = [vs[0].pt.x, vs[1].pt.x, vs[2].pt.x]
  var y = [vs[0].pt.y, vs[1].pt.y, vs[2].pt.y]
  var u = [vs[0].uv.x, vs[1].uv.x, vs[2].uv.x]
  var v = [vs[0].uv.y, vs[1].uv.y, vs[2].uv.y]
  var dxdy = [0.0'f32, 0.0'f32, 0.0'f32]
  var upper = false

  proc swapVert(i, j: int) =
    swap(x[i], x[j])
    swap(y[i], y[j])
    swap(u[i], u[j])
    swap(v[i], v[j])

  # sort the vertices in ascending Y order
  if y[0] > y[1]: swapVert(0, 1)
  if y[0] > y[2]: swapVert(0, 2)
  if y[1] > y[2]: swapVert(1, 2)

  let yi = [toI32(y[0]), toI32(y[1]), toI32(y[2])]

  # too thin to cover any pixel
  if (yi[0] == yi[1] and yi[0] == yi[2]) or
      (toI32(x[0]) == toI32(x[1]) and toI32(x[0]) == toI32(x[2])): return

  # horizontal and vertical increments of the UV axes
  var denom = (x[2] - x[0]) * (y[1] - y[0]) - (x[1] - x[0]) * (y[2] - y[0])
  if zero(denom): return  # infinitely thin line
  denom = 1.0'f32 / denom
  ctx.dudx = ((u[2] - u[0]) * (y[1] - y[0]) - (u[1] - u[0]) * (y[2] - y[0])) * denom
  ctx.dvdx = ((v[2] - v[0]) * (y[1] - y[0]) - (v[1] - v[0]) * (y[2] - y[0])) * denom
  let dudy = ((u[1] - u[0]) * (x[2] - x[0]) - (u[2] - u[0]) * (x[1] - x[0])) * denom
  let dvdy = ((v[1] - v[0]) * (x[2] - x[0]) - (v[2] - v[0]) * (x[1] - x[0])) * denom

  # X-slopes along the edges
  if y[1] > y[0]: dxdy[0] = (x[1] - x[0]) / (y[1] - y[0])
  if y[2] > y[0]: dxdy[1] = (x[2] - x[0]) / (y[2] - y[0])
  if y[2] > y[1]: dxdy[2] = (x[2] - x[1]) / (y[2] - y[1])

  # which side of the polygon the longer edge is on
  var side = dxdy[1] > dxdy[0]
  if equal(y[0], y[1]): side = x[0] > x[1]
  if equal(y[1], y[2]): side = x[2] > x[1]

  let mode = segMode(ctx.surface)
  let ymin = float32(ctx.bbox.yMin)
  let fy = [float32(yi[0]), float32(yi[1]), float32(yi[2])]

  if not side:
    # longer edge on the left: slopes along the left edge
    ctx.dxdya = dxdy[1]
    ctx.dudya = ctx.dxdya * ctx.dudx + dudy
    ctx.dvdya = ctx.dxdya * ctx.dvdx + dvdy
    # subpixel pre-stepping along the left edge
    let dy = 1.0'f32 - (y[0] - fy[0])
    ctx.xa = x[0] + dy * ctx.dxdya
    ctx.ua = u[0] + dy * ctx.dudya
    ctx.va = v[0] + dy * ctx.dvdya
    if yi[0] < yi[1]:  # upper segment
      let offY = if y[0] < ymin: ymin - y[0] else: 0.0'f32
      ctx.xa += offY * ctx.dxdya
      ctx.ua += offY * ctx.dudya
      ctx.va += offY * ctx.dvdya
      ctx.dxdyb = dxdy[0]
      ctx.xb = x[0] + dy * ctx.dxdyb + (offY * ctx.dxdyb)
      rasterSegment(ctx, yi[0], yi[1], mode, needAA)
      upper = true
    if yi[1] < yi[2]:  # lower segment
      let offY = if y[1] < ymin: ymin - y[1] else: 0.0'f32
      if not upper:
        ctx.xa += offY * ctx.dxdya
        ctx.ua += offY * ctx.dudya
        ctx.va += offY * ctx.dvdya
      ctx.dxdyb = dxdy[2]
      ctx.xb = x[1] + (1.0'f32 - (y[1] - fy[1])) * ctx.dxdyb + (offY * ctx.dxdyb)
      rasterSegment(ctx, yi[1], yi[2], mode, needAA)
  else:
    # longer edge on the right
    ctx.dxdyb = dxdy[1]
    var dy = 1.0'f32 - (y[0] - fy[0])
    ctx.xb = x[0] + dy * ctx.dxdyb
    if yi[0] < yi[1]:  # upper segment
      let offY = if y[0] < ymin: ymin - y[0] else: 0.0'f32
      ctx.xb += offY * ctx.dxdyb
      ctx.dxdya = dxdy[0]
      ctx.dudya = ctx.dxdya * ctx.dudx + dudy
      ctx.dvdya = ctx.dxdya * ctx.dvdx + dvdy
      ctx.xa = x[0] + dy * ctx.dxdya + (offY * ctx.dxdya)
      ctx.ua = u[0] + dy * ctx.dudya + (offY * ctx.dudya)
      ctx.va = v[0] + dy * ctx.dvdya + (offY * ctx.dvdya)
      rasterSegment(ctx, yi[0], yi[1], mode, needAA)
      upper = true
    if yi[1] < yi[2]:  # lower segment
      let offY = if y[1] < ymin: ymin - y[1] else: 0.0'f32
      if not upper: ctx.xb += offY * ctx.dxdyb
      ctx.dxdya = dxdy[2]
      ctx.dudya = ctx.dxdya * ctx.dudx + dudy
      ctx.dvdya = ctx.dxdya * ctx.dvdx + dvdy
      dy = 1.0'f32 - (y[1] - fy[1])
      ctx.xa = x[1] + dy * ctx.dxdya + (offY * ctx.dxdya)
      ctx.ua = u[1] + dy * ctx.dudya + (offY * ctx.dudya)
      ctx.va = v[1] + dy * ctx.dvdya + (offY * ctx.dvdya)
      rasterSegment(ctx, yi[1], yi[2], mode, needAA)

{.pop.}

proc rasterTexmapPolygon*(surface: SwSurface, image: SwImage, transform: Matrix,
                          bbox: Region, opacity: uint8): bool =
  ## Draws `image` mapped by `transform` (rotation, shear, any affine) inside `bbox`.
  var ctx = TexmapCtx(surface: surface, image: image, bbox: bbox, opacity: opacity)
  let w = float32(image.w)
  let h = float32(image.h)
  var vs = [Vertex(pt: pt(0.0'f32, 0.0'f32), uv: pt(0.0'f32, 0.0'f32)),
            Vertex(pt: pt(w, 0.0'f32), uv: pt(w, 0.0'f32)),
            Vertex(pt: pt(w, h), uv: pt(w, h)),
            Vertex(pt: pt(0.0'f32, h), uv: pt(0.0'f32, h))]
  for i in 0 ..< 4: vs[i].pt = vs[i].pt * transform
  let needAA = not rightAngle(transform)
  polygonImage(ctx, [vs[0], vs[1], vs[3]], needAA)  # first triangle
  polygonImage(ctx, [vs[1], vs[2], vs[3]], needAA)  # second triangle
  true
