## Common Lottie model value types.

import std/math

type
  LottiePoint* = object
    x*, y*: float32

  LottiePoint3* = object
    x*, y*, z*: float32

  LottieColor* = object
    r*, g*, b*: float32  # 0..1

  LottiePath* = object
    pts*: seq[LottiePoint]
    inTangents*: seq[LottiePoint]
    outTangents*: seq[LottiePoint]
    closed*: bool

proc lp*(x, y: float32): LottiePoint {.inline.} = LottiePoint(x: x, y: y)
proc lp3*(x, y, z: float32): LottiePoint3 {.inline.} = LottiePoint3(x: x, y: y, z: z)

proc `+`*(a, b: LottiePoint): LottiePoint {.inline.} = lp(a.x+b.x, a.y+b.y)
proc `-`*(a, b: LottiePoint): LottiePoint {.inline.} = lp(a.x-b.x, a.y-b.y)
proc `*`*(a: LottiePoint; s: float32): LottiePoint {.inline.} = lp(a.x*s, a.y*s)

proc lerp*(a, b: float32; t: float32): float32 {.inline.} = a + (b - a) * t
proc lerp*(a, b: LottiePoint; t: float32): LottiePoint {.inline.} =
  lp(lerp(a.x,b.x,t), lerp(a.y,b.y,t))
proc lerp*(a, b: LottiePoint3; t: float32): LottiePoint3 {.inline.} =
  lp3(lerp(a.x,b.x,t), lerp(a.y,b.y,t), lerp(a.z,b.z,t))

proc lerp*(a, b: LottieColor; t: float32): LottieColor {.inline.} =
  # C++ 1.1.1: parser uses remap255 (nearbyint, ties-to-even) to get RGB32 keyframes,
  # then LottieScalarFrame::interpolate lerps RGB32 with truncation: int32(s+(e-s)*t).
  proc remap255i(v: float32): int32 {.inline.} =
    let x = v * 255.0'f32
    let fl = floor(x)
    let diff = x - fl
    let r = if diff < 0.5'f32: fl
            elif diff > 0.5'f32: fl + 1.0'f32
            elif int(fl) mod 2 == 0: fl
            else: fl + 1.0'f32
    clamp(int32(r), 0'i32, 255'i32)
  template ch(sa, sb: float32): float32 =
    let ia = remap255i(sa)
    let ib = remap255i(sb)
    float32(clamp(int32(float32(ia) + float32(ib - ia) * t), 0'i32, 255'i32)) / 255.0'f32
  LottieColor(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b))

proc lerp*(a, b: LottiePath; t: float32): LottiePath =
  if a.pts.len != b.pts.len or a.inTangents.len != b.inTangents.len or a.outTangents.len != b.outTangents.len:
    return a
  result.closed = a.closed
  result.pts = newSeq[LottiePoint](a.pts.len)
  result.inTangents = newSeq[LottiePoint](a.inTangents.len)
  result.outTangents = newSeq[LottiePoint](a.outTangents.len)
  for i in 0 ..< a.pts.len:
    result.pts[i] = lerp(a.pts[i], b.pts[i], t)
  for i in 0 ..< a.inTangents.len:
    result.inTangents[i] = lerp(a.inTangents[i], b.inTangents[i], t)
  for i in 0 ..< a.outTangents.len:
    result.outTangents[i] = lerp(a.outTangents[i], b.outTangents[i], t)
