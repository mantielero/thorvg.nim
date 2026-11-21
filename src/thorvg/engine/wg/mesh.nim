## Geometry mesh buffers for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgMesh.h/.cpp.
## Holds vertex positions, optional texcoords (stored as Point pairs), indices and
## staging offsets used when uploading to GPU buffers.

import ../../core/[types, geom]

type
  WgMesh* = object
    vbuffer*: seq[Point]    ## vertex positions (and color/adjust are separate in pipelines)
    tbuffer*: seq[Point]    ## texcoords as (u,v) pairs; also reused for mask texcoords layouts
    ibuffer*: seq[uint32]
    voffset*: int
    toffset*: int
    ioffset*: int

proc clear*(m: var WgMesh) =
  m.vbuffer.setLen(0)
  m.tbuffer.setLen(0)
  m.ibuffer.setLen(0)
  m.voffset = 0
  m.toffset = 0
  m.ioffset = 0

proc invalid*(m: WgMesh): bool {.inline.} =
  m.vbuffer.len == 0

proc bbox*(m: var WgMesh, pmin, pmax: Point) =
  m.vbuffer = @[pt(pmin.x, pmin.y), pt(pmax.x, pmin.y), pt(pmax.x, pmax.y), pt(pmin.x, pmax.y)]
  m.tbuffer.setLen(0)
  m.ibuffer = @[0'u32, 1'u32, 2'u32, 0'u32, 2'u32, 3'u32]

proc imageBox*(m: var WgMesh, w, h: float32, transform: Matrix) =
  let p0 = pt(0.0'f32, 0.0'f32) * transform
  let p1 = pt(w,        0.0'f32) * transform
  let p2 = pt(w,        h)        * transform
  let p3 = pt(0.0'f32,  h)        * transform
  m.vbuffer = @[p0, p1, p2, p3]
  m.tbuffer = @[pt(0.0'f32, 0.0'f32), pt(1.0'f32, 0.0'f32), pt(1.0'f32, 1.0'f32), pt(0.0'f32, 1.0'f32)]
  m.ibuffer = @[0'u32, 1'u32, 2'u32, 0'u32, 2'u32, 3'u32]

proc blitBox*(m: var WgMesh) =
  m.vbuffer = @[pt(-1.0'f32, 1.0'f32), pt(1.0'f32, 1.0'f32), pt(1.0'f32, -1.0'f32), pt(-1.0'f32, -1.0'f32)]
  m.tbuffer = @[pt(0.0'f32, 0.0'f32), pt(1.0'f32, 0.0'f32), pt(1.0'f32, 1.0'f32), pt(0.0'f32, 1.0'f32)]
  m.ibuffer = @[0'u32, 1'u32, 2'u32, 0'u32, 2'u32, 3'u32]
