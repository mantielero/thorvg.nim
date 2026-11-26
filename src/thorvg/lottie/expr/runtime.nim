## AOT expression runtime. Pure Nim, no JS engine, no global mutable state.
import std/[math, options]
import val

type
  ExprCtx* = object
    time*: float64
    frame*: float64

proc evUndef*(): Val = vUndef()
proc evNull*(): Val = vNull()
proc evNum*(x: float64): Val = vNum(x)
proc evBool*(x: bool): Val = vBool(x)
proc evStr*(x: string): Val = vStr(x)
proc evArray*(xs: seq[Val]): Val = vArray(xs)

proc isNum(v: Val): bool = v.kind == vkNum
proc asNum*(v: Val): float64 =
  ## ThorVG scalar _number(obj): number or index 0 of array, else JS-ish coercion.
  case v.kind
  of vkNum: v.num
  of vkBool: (if v.b: 1.0'f64 else: 0.0'f64)
  of vkNull: 0.0'f64
  of vkUndef: NaN
  of vkStr: NaN # simplified; avoid in corpus
  of vkArray:
    if v.items.len == 0: 0.0'f64
    else: asNum(v.items[0])

proc toF32(x: float64): float32 = float32(x)

# 1d/2d classification like ThorVG _number(obj, Point& out): true if 1d
proc as1d2d(v: Val; outp: var array[2, float64]): bool =
  ## returns true if 1d, false if 2d (or more, takes first 2)
  case v.kind
  of vkNum:
    outp[0] = v.num; outp[1] = 0.0; return true
  of vkArray:
    if v.items.len == 0:
      outp[0] = 0.0; outp[1] = 0.0; return true
    outp[0] = asNum(v.items[0])
    if v.items.len < 2:
      outp[1] = 0.0; return true
    # index 1 exists => 2d
    outp[1] = asNum(v.items[1])
    return false
  else:
    outp[0] = asNum(v); outp[1] = 0.0; return true

proc vec2(x, y: float64): Val = vArray(@[vNum(x), vNum(y)])

proc bmSum*(a, b: Val): Val =
  # ThorVG _addsub: string concat, 1d+1d, 2d+2d, 2d+1d scalar-to-x-only
  if a.kind == vkStr or b.kind == vkStr:
    # simple string concat
    proc toS(v: Val): string =
      case v.kind
      of vkStr: v.s
      of vkNum: $v.num
      of vkBool: $v.b
      of vkNull: "null"
      of vkUndef: "undefined"
      of vkArray: "" # simplified
    return vStr(toS(a) & toS(b))
  var v1, v2: array[2, float64]
  let n1 = as1d2d(a, v1)
  let n2 = as1d2d(b, v2)
  if n1 and n2: return vNum(v1[0] + v2[0])
  if not n1 and not n2: return vec2(v1[0] + v2[0], v1[1] + v2[1])
  if n1:
    # 1d + 2d => scalar added to x of 2d
    return vec2(v1[0] + v2[0], v2[1])
  else:
    # 2d + 1d => scalar added to x of 2d
    return vec2(v1[0] + v2[0], v1[1])

proc bmSub*(a, b: Val): Val =
  if a.kind == vkStr or b.kind == vkStr:
    return vNum(NaN) # JS would coerce weirdly; avoid
  var v1, v2: array[2, float64]
  let n1 = as1d2d(a, v1)
  let n2 = as1d2d(b, v2)
  if n1 and n2: return vNum(v1[0] - v2[0])
  if not n1 and not n2: return vec2(v1[0] - v2[0], v1[1] - v2[1])
  if n1:
    return vec2(v1[0] - v2[0], v2[1]) # 1d - 2d: v2.x = v1.x - v2.x
  else:
    return vec2(v1[0] - v2[0], v1[1]) # 2d - 1d: v1.x - v2.x, y unchanged

proc bmMul*(a, b: Val): Val =
  # ThorVG muldiv: second arg scalar via _number (index 0)
  var v1: array[2, float64]
  let n1 = as1d2d(a, v1)
  let s2 = asNum(b) # scalar from second arg
  if n1: return vNum(v1[0] * s2)
  return vec2(v1[0] * s2, v1[1] * s2)

proc bmDiv*(a, b: Val): Val =
  # ThorVG: 1.0f / _number(args[1]) then muldiv; div by zero -> Inf/NaN per float rules
  var v1: array[2, float64]
  let n1 = as1d2d(a, v1)
  let s2 = asNum(b)
  let inv = 1.0 / s2
  if n1: return vNum(v1[0] * inv)
  return vec2(v1[0] * inv, v1[1] * inv)

proc bmMod*(a, b: Val): Val =
  # ThorVG: fmod(_number(a), _number(b)) scalar only
  let x = asNum(a)
  let y = asNum(b)
  return vNum(x - y * trunc(x / y))

# Emitter-facing helpers
proc evAdd*(a, b: Val): Val = bmSum(a, b)
proc evSub*(a, b: Val): Val = bmSub(a, b)
proc evMul*(a, b: Val): Val = bmMul(a, b)
proc evDiv*(a, b: Val): Val = bmDiv(a, b)
proc evMod*(a, b: Val): Val = bmMod(a, b)

proc evTruthy*(v: Val): bool =
  case v.kind
  of vkUndef, vkNull: false
  of vkBool: v.b
  of vkNum: v.num != 0.0 and v.num == v.num # NaN is falsy
  of vkStr: v.s.len > 0
  of vkArray: true

proc evNeg*(a: Val): Val = vNum(-asNum(a))
proc evPos*(a: Val): Val = vNum(asNum(a))
proc evNot*(a: Val): Val = vBool(not evTruthy(a))

proc evLt*(a,b: Val): Val = vBool(asNum(a) < asNum(b))
proc evLtEq*(a,b: Val): Val = vBool(asNum(a) <= asNum(b))
proc evGt*(a,b: Val): Val = vBool(asNum(a) > asNum(b))
proc evGtEq*(a,b: Val): Val = vBool(asNum(a) >= asNum(b))
proc evEq*(a,b: Val): Val = vBool(asNum(a) == asNum(b)) # simplified
proc evNeq*(a,b: Val): Val = vBool(asNum(a) != asNum(b))
proc evAnd*(a,b: Val): Val =
  if evTruthy(a): b else: a

proc evOr*(a,b: Val): Val =
  if evTruthy(a): a else: b

proc evMathSin*(a: Val): Val = vNum(sin(asNum(a)))
proc evMathCos*(a: Val): Val = vNum(cos(asNum(a)))
proc evMathExp*(a: Val): Val = vNum(exp(asNum(a)))
proc evMathAbs*(a: Val): Val = vNum(abs(asNum(a)))
proc evMathSqrt*(a: Val): Val = vNum(sqrt(asNum(a)))
proc evMathFloor*(a: Val): Val = vNum(floor(asNum(a)))
proc evMathCeil*(a: Val): Val = vNum(ceil(asNum(a)))
proc evMathRound*(a: Val): Val = vNum(round(asNum(a)))

proc evMember*(obj: Val; prop: string): Val =
  if obj.kind == vkArray and prop == "length": return vNum(float64(obj.items.len))
  vUndef()

proc evIndex*(obj: Val; idx: Val): Val =
  if obj.kind == vkArray:
    let i = int(asNum(idx))
    if i >= 0 and i < obj.items.len: return obj.items[i]
  vUndef()
