## Port of tvgLottieInterpolator (cubic Bezier easing for keyframes).

import std/math
import ../model/common

const
  SplineTableSize* = 11
  SampleStepSize = 1.0'f32 / float32(SplineTableSize - 1)
  NewtonMinSlope = 0.02'f32
  NewtonIterations = 4
  SubdivisionPrecision = 0.0000001'f32
  SubdivisionMaxIterations = 10

type
  LottieInterpolator* = ref object
    key*: string
    outTangent*, inTangent*: LottiePoint
    samples*: array[SplineTableSize, float32]

proc constA(aA1, aA2: float32): float32 {.inline.} = 1.0'f32 - 3.0'f32 * aA2 + 3.0'f32 * aA1
proc constB(aA1, aA2: float32): float32 {.inline.} = 3.0'f32 * aA2 - 6.0'f32 * aA1
proc constC(aA1: float32): float32 {.inline.} = 3.0'f32 * aA1

proc getSlope(t, aA1, aA2: float32): float32 {.inline.} =
  3.0'f32 * constA(aA1, aA2) * t * t + 2.0'f32 * constB(aA1, aA2) * t + constC(aA1)

proc calcBezier(t, aA1, aA2: float32): float32 {.inline.} =
  ((constA(aA1, aA2) * t + constB(aA1, aA2)) * t + constC(aA1)) * t

proc newtonRaphsonIterate(it: LottieInterpolator; aX, aGuessT: float32): float32 =
  var guess = aGuessT
  for i in 0 ..< NewtonIterations:
    let currentX = calcBezier(guess, it.outTangent.x, it.inTangent.x) - aX
    let currentSlope = getSlope(guess, it.outTangent.x, it.inTangent.x)
    if currentSlope == 0.0'f32: return guess
    guess -= currentX / currentSlope
  guess

proc binarySubdivide(it: LottieInterpolator; aX, aA, aB: float32): float32 =
  var
    aA = aA
    aB = aB
    t = 0.0'f32
    x = 0.0'f32
    i = 0
  while true:
    t = aA + (aB - aA) / 2.0'f32
    x = calcBezier(t, it.outTangent.x, it.inTangent.x) - aX
    if x > 0.0'f32: aB = t
    else: aA = t
    inc i
    if not (abs(x) > SubdivisionPrecision and i < SubdivisionMaxIterations):
      break
  t

proc getTForX(it: LottieInterpolator; aX: float32): float32 =
  var intervalStart = 0.0'f32
  var currentSample = 1
  let lastSample = SplineTableSize - 1
  while currentSample != lastSample and it.samples[currentSample] <= aX:
    intervalStart += SampleStepSize
    inc currentSample
  dec currentSample
  let dist = (aX - it.samples[currentSample]) / (it.samples[currentSample + 1] - it.samples[currentSample])
  let guessForT = intervalStart + dist * SampleStepSize
  let initialSlope = getSlope(guessForT, it.outTangent.x, it.inTangent.x)
  if initialSlope >= NewtonMinSlope: return it.newtonRaphsonIterate(aX, guessForT)
  elif initialSlope == 0.0'f32: return guessForT
  else: return it.binarySubdivide(aX, intervalStart, intervalStart + SampleStepSize)

proc progress*(it: LottieInterpolator; t: float32): float32 =
  if it.outTangent.x == it.outTangent.y and it.inTangent.x == it.inTangent.y:
    return t
  calcBezier(it.getTForX(t), it.outTangent.y, it.inTangent.y)

proc set*(it: LottieInterpolator; key: string; inTangent, outTangent: LottiePoint) =
  it.key = key
  it.inTangent = inTangent
  it.outTangent = outTangent
  if outTangent.x == outTangent.y and inTangent.x == inTangent.y:
    return
  for i in 0 ..< SplineTableSize:
    it.samples[i] = calcBezier(float32(i) * SampleStepSize, outTangent.x, inTangent.x)

proc newLottieInterpolator*(key: string = ""; inTangent = LottiePoint(x:0,y:0); outTangent = LottiePoint(x:1,y:1)): LottieInterpolator =
  result = LottieInterpolator()
  result.set(key, inTangent, outTangent)
