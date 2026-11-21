## Scene effects: the engine independent description of post-processing effects.
##
## Ported from the `RenderEffect*` structs of `src/renderer/tvgRender.h` and the
## `SceneEffect` enum of `thorvg.h`. The `gen*` procs clamp their arguments like the C++
## `gen(va_list&)` functions; the `update*` procs compute the transformed offsets that
## depend on the paint transform. `RenderEffect.rd` is the engine's private cache
## (C++ `void* rd`), subclassed by the engine from `EffectData`.

import std/math
import ../core/[types, geom]

type
  SceneEffect* {.pure.} = enum
    Clear, GaussianBlur, DropShadow, Fill, Tint, Tritone, MotionBlur

  EffectData* = ref object of RootObj
    ## Engine-owned cache of one effect (kernels, offsets, ...).

  RenderEffect* = ref object of RootObj
    rd*: EffectData
    extend*: Region          ## how much the effect enlarges the scene region
    kind*: SceneEffect
    valid*: bool

  GaussianBlurEffect* = ref object of RenderEffect
    sigma*: float32
    direction*: uint8        ## 0: both, 1: horizontal, 2: vertical
    border*: uint8           ## 0: duplicate, 1: wrap
    quality*: uint8          ## 0 ~ 100

  MotionBlurEffect* = ref object of RenderEffect
    distance*, angle*: float32
    quality*: uint8

  DropShadowEffect* = ref object of RenderEffect
    color*: array[4, uint8]  ## rgba
    angle*, distance*, sigma*: float32
    quality*: uint8

  FillEffect* = ref object of RenderEffect
    color*: array[4, uint8]  ## rgba

  TintEffect* = ref object of RenderEffect
    black*, white*: array[3, uint8]
    intensity*: uint8        ## 0 ~ 255

  TritoneEffect* = ref object of RenderEffect
    shadow*, midtone*, highlight*: array[3, uint8]
    blender*: uint8          ## 0 ~ 255

func u8(v: int): uint8 = uint8(v and 0xff)  # C++ `int` -> `uint8_t` truncation

func genGaussianBlur*(sigma: float, direction, border, quality: int): GaussianBlurEffect =
  GaussianBlurEffect(kind: SceneEffect.GaussianBlur,
    sigma: max(float32(sigma), 0.0'f32), direction: u8(clamp(direction, 0, 2)),
    border: u8(min(border, 1)), quality: u8(min(quality, 100)))

func genMotionBlur*(distance, angle: float, quality: int): MotionBlurEffect =
  MotionBlurEffect(kind: SceneEffect.MotionBlur,
    distance: max(0.0'f32, float32(distance)), angle: float32(angle) mod 180.0'f32,
    quality: u8(min(quality, 100)))

func genDropShadow*(r, g, b, a: int, angle, distance, sigma: float,
    quality: int): DropShadowEffect =
  DropShadowEffect(kind: SceneEffect.DropShadow, color: [u8(r), u8(g), u8(b), u8(a)],
    angle: float32(angle), distance: float32(distance),
    sigma: max(float32(sigma), 0.0'f32), quality: u8(min(quality, 100)))

func genFill*(r, g, b, a: int): FillEffect =
  FillEffect(kind: SceneEffect.Fill, color: [u8(r), u8(g), u8(b), u8(a)])

func genTint*(blackR, blackG, blackB, whiteR, whiteG, whiteB: int,
    intensity: float): TintEffect =
  TintEffect(kind: SceneEffect.Tint, black: [u8(blackR), u8(blackG), u8(blackB)],
    white: [u8(whiteR), u8(whiteG), u8(whiteB)],
    intensity: u8(int(float32(intensity) * 2.55'f32)))

func genTritone*(shadow, midtone, highlight: array[3, int], blender: int): TritoneEffect =
  result = TritoneEffect(kind: SceneEffect.Tritone, blender: u8(blender))
  for i in 0 ..< 3:
    result.shadow[i] = u8(shadow[i])
    result.midtone[i] = u8(midtone[i])
    result.highlight[i] = u8(highlight[i])

proc update*(e: MotionBlurEffect, tm: Matrix, offset: var Point, samples: var int): bool =
  ## The transformed blur vector and its sample count; false when nothing is blurred.
  e.valid = false
  let radian = deg2rad(e.angle)
  let vx = e.distance * cos(radian)
  let vy = e.distance * sin(radian)
  offset = pt(tm.e11 * vx + tm.e12 * vy, tm.e21 * vx + tm.e22 * vy)
  # avoid spurious one-pixel expansion at exact cardinal angles
  if abs(offset.x) < 0.001'f32: offset.x = 0.0'f32
  if abs(offset.y) < 0.001'f32: offset.y = 0.0'f32
  let length = max(abs(offset.x), abs(offset.y))
  if zero(length): return false
  let density = 0.25'f32 + float32(e.quality) * 0.0075'f32
  samples = 2 * int(min(128.0'f32, ceil(length * density * 0.5'f32))) + 1
  e.valid = true
  true

proc update*(e: DropShadowEffect, tm: Matrix, offset: var Point): bool =
  ## The transformed shadow offset (a direction, without translation).
  e.valid = e.color[3] != 0
  if not e.valid: return false
  let radian = deg2rad(90.0'f32 - e.angle)
  let x = e.distance * cos(radian)
  let y = -e.distance * sin(radian)
  offset = pt(tm.e11 * x + tm.e12 * y, tm.e21 * x + tm.e22 * y)
  true

proc duplicate*(e: RenderEffect): RenderEffect =
  ## A copy without engine data (it is prepared again by the new owner).
  case e.kind
  of SceneEffect.GaussianBlur:
    let o = GaussianBlurEffect(e)
    result = GaussianBlurEffect(sigma: o.sigma, direction: o.direction, border: o.border,
                                quality: o.quality)
  of SceneEffect.MotionBlur:
    let o = MotionBlurEffect(e)
    result = MotionBlurEffect(distance: o.distance, angle: o.angle, quality: o.quality)
  of SceneEffect.DropShadow:
    let o = DropShadowEffect(e)
    result = DropShadowEffect(color: o.color, angle: o.angle, distance: o.distance,
                              sigma: o.sigma, quality: o.quality)
  of SceneEffect.Fill:
    result = FillEffect(color: FillEffect(e).color)
  of SceneEffect.Tint:
    let o = TintEffect(e)
    result = TintEffect(black: o.black, white: o.white, intensity: o.intensity)
  of SceneEffect.Tritone:
    let o = TritoneEffect(e)
    result = TritoneEffect(shadow: o.shadow, midtone: o.midtone, highlight: o.highlight,
                           blender: o.blender)
  of SceneEffect.Clear: return nil
  result.kind = e.kind
  result.extend = e.extend
