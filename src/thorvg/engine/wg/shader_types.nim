## GPU shader-side types and uniform/param packing for the WG (WebGPU) engine.
##
## Port of upstream/src/renderer/gpu_engine/wg/tvgWgShaderTypes.h/.cpp.
## Layouts and update logic must match the WGSL shaders in `shader_src.nim`.
## Pure Nim migration (no FFI); uses core/fill/geom/types and renderer/effect types.

import std/math
import ../../core/[types, geom]
import ../../core/fill
import ../../renderer/effect
import ../gl/gpu_path

const
  WG_TEXTURE_GRADIENT_SIZE* = 512
  WG_GAUSSIAN_KERNEL_SIZE_MAX* = 128.0'f32 ## gaussian params: sigma, scale, extend (upstream)

type
  WgShaderTypeMat4x4f* = object ## WGSL mat4x4f
    mat*: array[16, float32]

  WgShaderTypeMat4x4fBlock* = object ## aligned view-matrix uniform block (256 bytes)
    matrix*: WgShaderTypeMat4x4f
    padding*: array[256 - sizeof(WgShaderTypeMat4x4f), uint8]

  WgShaderTypeVec4f* = object ## WGSL vec4f
    vec*: array[4, float32]

  WgShaderTypeGradSettings* = object
    ## WGSL: struct GradSettings { transform: mat4x4f, coords: vec4f, focal: vec4f };
    transform*: WgShaderTypeMat4x4f
    coords*: WgShaderTypeVec4f ## linear: x1,y1,x2,y2; radial: cx,cy,cr,_
    focal*: WgShaderTypeVec4f  ## radial: fx,fy,fr,_ 

  WgShaderTypePaintSettings* = object
    ## WGSL: struct PaintSettings { options: vec4f, gradient: GradSettings };
    ## options: [0]=color space, [3]=opacity. Aligned to 256 bytes (minUniformBufferOffsetAlignment).
    options*: WgShaderTypeVec4f
    gradient*: WgShaderTypeGradSettings
    padding*: array[256 - sizeof(WgShaderTypeVec4f) - sizeof(WgShaderTypeGradSettings), uint8]

  WgShaderTypeGradientData* = object
    data*: array[WG_TEXTURE_GRADIENT_SIZE * 4, uint8]

  WgShaderTypeEffectParams* = object
    ## gaussian blur: [0]=sigma,[1]=scale,[2]=kernel size
    ## drop shadow: [0]=sigma,[1]=scale,[2]=kernel,[4..7]=premultiplied RGBA,[8,9]=offset
    ## fill: [0..3]=normalized RGBA
    ## tint: [0..2]=black RGB,[4..6]=white RGB,[8]=intensity
    ## tritone: [0..2]=shadow,[4..6]=midtone,[8..10]=highlight,[11]=blender
    ## motion blur: [0,1]=offset,[2]=sample count,[4..7]=clip region (set elsewhere)
    params*: array[12, float32] ## settings: array<vec4f, 3>
    extend*: uint32
    offset*: Point

#************************************************************************
# WgShaderTypeMat4x4f
#************************************************************************

proc identity*(m: var WgShaderTypeMat4x4f) =
  m.mat[0] = 1.0'f32;  m.mat[1] = 0.0'f32;  m.mat[2] = 0.0'f32;  m.mat[3] = 0.0'f32
  m.mat[4] = 0.0'f32;  m.mat[5] = 1.0'f32;  m.mat[6] = 0.0'f32;  m.mat[7] = 0.0'f32
  m.mat[8] = 0.0'f32;  m.mat[9] = 0.0'f32;  m.mat[10] = 1.0'f32; m.mat[11] = 0.0'f32
  m.mat[12] = 0.0'f32; m.mat[13] = 0.0'f32; m.mat[14] = 0.0'f32; m.mat[15] = 1.0'f32

proc initWgShaderTypeMat4x4f*(): WgShaderTypeMat4x4f =
  result.identity()

proc update*(m: var WgShaderTypeMat4x4f, transform: Matrix) =
  m.mat[0]  = transform.e11
  m.mat[1]  = transform.e21
  m.mat[2]  = 0.0'f32
  m.mat[3]  = transform.e31
  m.mat[4]  = transform.e12
  m.mat[5]  = transform.e22
  m.mat[6]  = 0.0'f32
  m.mat[7]  = transform.e32
  m.mat[8]  = 0.0'f32
  m.mat[9]  = 0.0'f32
  m.mat[10] = 1.0'f32
  m.mat[11] = 0.0'f32
  m.mat[12] = transform.e13
  m.mat[13] = transform.e23
  m.mat[14] = 0.0'f32
  m.mat[15] = transform.e33

proc initWgShaderTypeMat4x4f*(transform: Matrix): WgShaderTypeMat4x4f =
  result.update(transform)

proc update*(m: var WgShaderTypeMat4x4f, w, h: int) =
  let wf = float32(w)
  let hf = float32(h)
  m.mat[0]  =  2.0'f32 / wf; m.mat[1]  =  0.0'f32;       m.mat[2]  =  0.0'f32; m.mat[3]  = 0.0'f32
  m.mat[4]  =  0.0'f32;       m.mat[5]  = -2.0'f32 / hf; m.mat[6]  =  0.0'f32; m.mat[7]  = 0.0'f32
  m.mat[8]  =  0.0'f32;       m.mat[9]  =  0.0'f32;       m.mat[10] = -1.0'f32; m.mat[11] = 0.0'f32
  m.mat[12] = -1.0'f32;       m.mat[13] =  1.0'f32;       m.mat[14] =  0.0'f32; m.mat[15] = 1.0'f32

proc initWgShaderTypeMat4x4f*(w, h: int): WgShaderTypeMat4x4f =
  result.update(w, h)

#************************************************************************
# WgShaderTypeVec4f
#************************************************************************

proc update*(v: var WgShaderTypeVec4f, colorSpace: ColorSpace, o: uint8) =
  v.vec[0] = float32(uint32(ord(colorSpace)))
  v.vec[3] = float32(o) / 255.0'f32

proc initWgShaderTypeVec4f*(colorSpace: ColorSpace, o: uint8): WgShaderTypeVec4f =
  result.update(colorSpace, o)

proc update*(v: var WgShaderTypeVec4f, r: Region) =
  v.vec[0] = float32(r.xMin)
  v.vec[1] = float32(r.yMin)
  v.vec[2] = float32(r.xMax - 1)
  v.vec[3] = float32(r.yMax - 1)

#************************************************************************
# WgShaderTypeGradSettings
#************************************************************************

proc update*(s: var WgShaderTypeGradSettings, fill: Fill, transform: ptr Matrix) =
  var resultM: Matrix
  if inverse(fill.transform, resultM):
    if transform != nil:
      var itransform: Matrix
      if inverse(transform[], itransform):
        resultM = resultM * itransform
    if fill.kind == FillKind.Conic:
      resultM = gpuConicTransform(fill.center, fill.angle) * resultM
    s.transform.update(resultM)
  else:
    s.transform.identity()

  case fill.kind
  of FillKind.Linear:
    s.coords.vec[0] = fill.p1.x
    s.coords.vec[1] = fill.p1.y
    s.coords.vec[2] = fill.p2.x
    s.coords.vec[3] = fill.p2.y
  of FillKind.Radial:
    s.coords.vec[0] = fill.center.x
    s.coords.vec[1] = fill.center.y
    s.coords.vec[2] = fill.r
    var fx = 0.0'f32
    var fy = 0.0'f32
    var fr = 0.0'f32
    if not fill.correct(fx, fy, fr):
      s.coords.vec[2] = 0.0'f32
    s.focal.vec[0] = fx
    s.focal.vec[1] = fy
    s.focal.vec[2] = fr
  of FillKind.Conic:
    discard

#************************************************************************
# WgShaderTypeGradientData
#************************************************************************

proc assignColor(dst: var openArray[uint8], idx: int, c: ColorStop) {.inline.} =
  dst[idx + 0] = c.r
  dst[idx + 1] = c.g
  dst[idx + 2] = c.b
  dst[idx + 3] = c.a

proc update*(g: var WgShaderTypeGradientData, fill: Fill): bool =
  let stopCnt = fill.stops.len
  if stopCnt == 0:
    for i in 0 ..< g.data.len: g.data[i] = 0
    return false

  var sstops: seq[ColorStop] = @[]
  sstops.add(fill.stops[0])
  var opaque = fill.stops[0].a == 255

  # filter by increasing offset
  for i in 1 ..< stopCnt:
    opaque = opaque and (fill.stops[i].a == 255)
    if sstops[sstops.high].offset < fill.stops[i].offset:
      sstops.add(fill.stops[i])
    elif sstops[sstops.high].offset == fill.stops[i].offset:
      sstops[sstops.high] = fill.stops[i]

  let texN = WG_TEXTURE_GRADIENT_SIZE - 1

  # head
  var rangeS = 0'u32
  var rangeE = uint32(sstops[0].offset * float32(texN))
  var ti = rangeS
  while ti < rangeE and ti < uint32(WG_TEXTURE_GRADIENT_SIZE):
    assignColor(g.data, int(ti) * 4, sstops[0])
    inc ti

  # body
  if sstops.len > 1:
    for di in 1 ..< sstops.len:
      rangeS = uint32(sstops[di - 1].offset * float32(texN))
      rangeE = uint32(sstops[di].offset * float32(texN))
      if rangeE <= rangeS:
        continue
      let delta = 1.0'f32 / float32(rangeE - rangeS)
      ti = rangeS
      while ti < rangeE and ti < uint32(WG_TEXTURE_GRADIENT_SIZE):
        let c = lerp(sstops[di - 1], sstops[di], float32(ti - rangeS) * delta)
        assignColor(g.data, int(ti) * 4, c)
        inc ti

  # tail
  let colorStopLast = sstops[sstops.high]
  rangeS = uint32(colorStopLast.offset * float32(texN))
  rangeE = uint32(WG_TEXTURE_GRADIENT_SIZE)
  ti = rangeS
  while ti < rangeE:
    assignColor(g.data, int(ti) * 4, colorStopLast)
    inc ti
  opaque

#************************************************************************
# WgShaderTypeEffectParams
#************************************************************************

proc update*(p: var WgShaderTypeEffectParams, motion: MotionBlurEffect, transform: Matrix): bool =
  var samples = 0
  if not motion.update(transform, p.offset, samples): return false
  p.params[0] = p.offset.x
  p.params[1] = p.offset.y
  p.params[2] = float32(samples)
  true

proc update*(p: var WgShaderTypeEffectParams, gaussian: GaussianBlurEffect, transform: Matrix): bool =
  p.params[0] = gaussian.sigma
  p.params[1] = sqrt(transform.e11 * transform.e11 + transform.e12 * transform.e12)
  p.params[2] = 2.0'f32 * gaussian.sigma * p.params[1]
  p.extend = uint32(p.params[2] * 2.0'f32) # kernel
  gaussian.valid = p.extend != 0'u32
  gaussian.valid

proc update*(p: var WgShaderTypeEffectParams, dropShadow: DropShadowEffect, transform: Matrix): bool =
  if not dropShadow.update(transform, p.offset): return false
  let scale = sqrt(transform.e11 * transform.e11 + transform.e12 * transform.e12)
  let ex = dropShadow.sigma * scale + abs(p.offset.x)
  let ey = dropShadow.sigma * scale + abs(p.offset.y)
  p.extend = uint32(2.0'f32 * max(ex, ey))
  p.params[0] = dropShadow.sigma
  p.params[1] = scale
  p.params[2] = 2.0'f32 * dropShadow.sigma * scale
  p.params[3] = 0.0'f32
  p.params[7] = float32(dropShadow.color[3]) / 255.0'f32 # alpha
  # Color is premultiplied to avoid multiplication in the fragment shader:
  p.params[4] = float32(dropShadow.color[0]) / 255.0'f32 * p.params[7] # red
  p.params[5] = float32(dropShadow.color[1]) / 255.0'f32 * p.params[7] # green
  p.params[6] = float32(dropShadow.color[2]) / 255.0'f32 * p.params[7] # blue
  p.params[8] = p.offset.x
  p.params[9] = p.offset.y
  true

proc update*(p: var WgShaderTypeEffectParams, fill: FillEffect): bool =
  p.params[0] = float32(fill.color[0]) / 255.0'f32
  p.params[1] = float32(fill.color[1]) / 255.0'f32
  p.params[2] = float32(fill.color[2]) / 255.0'f32
  p.params[3] = float32(fill.color[3]) / 255.0'f32
  fill.valid = true
  true

proc update*(p: var WgShaderTypeEffectParams, tint: TintEffect): bool =
  p.params[0] = float32(tint.black[0]) / 255.0'f32
  p.params[1] = float32(tint.black[1]) / 255.0'f32
  p.params[2] = float32(tint.black[2]) / 255.0'f32
  p.params[3] = 0.0'f32
  p.params[4] = float32(tint.white[0]) / 255.0'f32
  p.params[5] = float32(tint.white[1]) / 255.0'f32
  p.params[6] = float32(tint.white[2]) / 255.0'f32
  p.params[7] = 0.0'f32
  p.params[8] = float32(tint.intensity) / 255.0'f32
  tint.valid = tint.intensity > 0
  tint.valid

proc update*(p: var WgShaderTypeEffectParams, tritone: TritoneEffect): bool =
  p.params[0] = float32(tritone.shadow[0]) / 255.0'f32
  p.params[1] = float32(tritone.shadow[1]) / 255.0'f32
  p.params[2] = float32(tritone.shadow[2]) / 255.0'f32
  p.params[3] = 0.0'f32
  p.params[4] = float32(tritone.midtone[0]) / 255.0'f32
  p.params[5] = float32(tritone.midtone[1]) / 255.0'f32
  p.params[6] = float32(tritone.midtone[2]) / 255.0'f32
  p.params[7] = 0.0'f32
  p.params[8] = float32(tritone.highlight[0]) / 255.0'f32
  p.params[9] = float32(tritone.highlight[1]) / 255.0'f32
  p.params[10] = float32(tritone.highlight[2]) / 255.0'f32
  p.params[11] = float32(tritone.blender) / 255.0'f32
  tritone.valid = tritone.blender < 255
  true
