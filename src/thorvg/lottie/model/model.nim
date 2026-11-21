## Lottie model (Phase 1+: transform eval + shape tree, no render).

import std/json
import ../../core/types
import common, property

type
  LottieObjectType* = enum
    otComposition = 0, otLayer, otGroup, otTransform, otSolidFill, otSolidStroke,
    otGradientFill, otGradientStroke, otRect, otEllipse, otPath, otPolystar,
    otImage, otTrimpath, otText, otRepeater, otRoundedCorner, otOffsetPath,
    otPuckerBloat, otZigZag, otMergePath, otTextRange, otAudio, otUnknown

  LottieLayerType* = enum
    ltPrecomp = 0, ltSolid = 1, ltImage = 2, ltNull = 3, ltShape = 4, ltText = 5, ltAudio = 6

  LottieObject* = ref object of RootObj
    objType*: LottieObjectType
    name*: string
    matchName*: string
    hidden*: bool
    ix*: int

  LottieTransform* = ref object of LottieObject
    position*: LottieGenericProperty[LottieVectorFrame[LottiePoint], LottiePoint]
    scale*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]
    anchor*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]
    rotation*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    opacity*: LottieGenericProperty[LottieScalarFrame[uint8], uint8]
    separate*: bool
    sepX*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    sepY*: LottieGenericProperty[LottieScalarFrame[float32], float32]

  LottieGroup* = ref object of LottieObject
    children*: seq[LottieObject]

  LottiePathObj* = ref object of LottieObject
    path*: LottieGenericProperty[LottieScalarFrame[LottiePath], LottiePath]

  LottieRectObj* = ref object of LottieObject
    position*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]
    size*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]
    radius*: LottieGenericProperty[LottieScalarFrame[float32], float32]

  LottieEllipseObj* = ref object of LottieObject
    position*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]
    size*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]

  LottieFillObj* = ref object of LottieObject
    color*: LottieGenericProperty[LottieScalarFrame[LottieColor], LottieColor]
    opacity*: LottieGenericProperty[LottieScalarFrame[uint8], uint8]
    fillRule*: int

  LottieStrokeObj* = ref object of LottieObject
    color*: LottieGenericProperty[LottieScalarFrame[LottieColor], LottieColor]
    opacity*: LottieGenericProperty[LottieScalarFrame[uint8], uint8]
    width*: LottieGenericProperty[LottieScalarFrame[float32], float32]

  LottieTrimpathObj* = ref object of LottieObject
    start*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    `end`*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    offset*: LottieGenericProperty[LottieScalarFrame[float32], float32]

  LottiePolystarObj* = ref object of LottieObject
    position*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]
    outerRadius*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    innerRadius*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    outerRoundness*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    innerRoundness*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    rotation*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    points*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    starType*: int # 1=star, 2=polygon

  LottieGradientStop* = object
    offset*: float32
    color*: LottieColor
    alpha*: float32 # 0..1, default 1

  LottieGradientFillObj* = ref object of LottieObject
    stops*: seq[LottieGradientStop]
    stopsSid*: uint32
    opacity*: LottieGenericProperty[LottieScalarFrame[uint8], uint8]
    start*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]
    `end`*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]
    height*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    angle*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    fillRule*: int
    gradType*: int # 1=linear, 2=radial

  LottieGradientStrokeObj* = ref object of LottieObject
    stops*: seq[LottieGradientStop]
    stopsSid*: uint32
    opacity*: LottieGenericProperty[LottieScalarFrame[uint8], uint8]
    start*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]
    `end`*: LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint]
    height*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    angle*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    width*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    gradType*: int # 1=linear, 2=radial

  LottieRoundedCornerObj* = ref object of LottieObject
    radius*: LottieGenericProperty[LottieScalarFrame[float32], float32]

  LottieZigZagObj* = ref object of LottieObject
    amplitude*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    frequency*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    pointType*: int

  LottieMergePathObj* = ref object of LottieObject
    mergeMode*: int

  LottieOffsetPathObj* = ref object of LottieObject
    offset*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    miterLimit*: float32
    join*: int

  LottieRepeaterObj* = ref object of LottieObject
    copies*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    offset*: LottieGenericProperty[LottieScalarFrame[float32], float32]

  LottiePuckerBloatObj* = ref object of LottieObject
    amount*: LottieGenericProperty[LottieScalarFrame[float32], float32]

  LottieAsset* = ref object of LottieObject
    id*: string
    layers*: seq[LottieLayer] # for precomp
    w*, h*: float32
    u*, p*: string
    embedded*: bool

  LottieMask* = ref object
    path*: LottieGenericProperty[LottieScalarFrame[LottiePath], LottiePath]
    opacity*: LottieGenericProperty[LottieScalarFrame[uint8], uint8]
    expand*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    mode*: MaskMethod
    inverse*: bool

  LottieLayer* = ref object of LottieObject
    id*: uint32
    layerType*: LottieLayerType
    transform*: LottieTransform
    children*: seq[LottieObject] # shapes/groups
    masks*: seq[LottieMask]
    inPoint*, outPoint*, startTime*, startFrame*: float32
    timeStretch*: float32
    timeRemap*: LottieGenericProperty[LottieScalarFrame[float32], float32]
    parentId*: int
    refId*: string
    w*, h*: float32 # for solid/precomp
    solidColor*: RGBA

  LottieSlot* = ref object
    sid*: uint32
    p*: JsonNode # override property node

  LottieSlotBinding* = ref object
    sid*: uint32
    apply*: proc(ov: JsonNode)

  LottieComposition* = ref object
    version*: string
    name*: string
    w*, h*: float32
    inPoint*, outPoint*, frameRate*: float32
    layers*: seq[LottieLayer]
    assets*: seq[LottieAsset]
    warnings*: seq[string]
    slots*: seq[LottieSlot] # raw slot defs; applied post-parse
    slotBindings*: seq[LottieSlotBinding]
    resourceDir*: string

proc newLottieTransform*(): LottieTransform =
  result = LottieTransform(
    objType: otTransform,
    position: newVectorProp(lp(0,0)),
    scale: newScalarProp(lp(100,100)),
    anchor: newScalarProp(lp(0,0)),
    rotation: newScalarProp(0.0'f32),
    opacity: newScalarProp(255'u8),
    separate: false,
    sepX: newScalarProp(0.0'f32),
    sepY: newScalarProp(0.0'f32),
  )

proc evalPosition*(t: LottieTransform; frameNo: float32): LottiePoint =
  if t.separate:
    lp(t.sepX.eval(frameNo), t.sepY.eval(frameNo))
  else:
    t.position.eval(frameNo)

proc evalScale*(t: LottieTransform; frameNo: float32): LottiePoint = t.scale.eval(frameNo)
proc evalRotation*(t: LottieTransform; frameNo: float32): float32 = t.rotation.eval(frameNo)
proc evalOpacity*(t: LottieTransform; frameNo: float32): uint8 = t.opacity.eval(frameNo)
