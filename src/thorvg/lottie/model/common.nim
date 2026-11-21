## Common Lottie model value types.

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
  LottieColor(r: lerp(a.r,b.r,t), g: lerp(a.g,b.g,t), b: lerp(a.b,b.b,t))

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
