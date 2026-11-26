## Property boundary: single source of truth for expr->property conversion.
## Rules from ThorVG 1.2.0 oracle + declared divergences (D1-exc2, D1-exc3).
import std/[math, options]
import val

type
  PropScalar* = Option[float64]          ## none => use static
  PropVec* = Option[seq[float64]]         ## none => use static

proc isNumNaN(x: float64): bool = x != x

proc toScalarNumber*(v: Val): Option[float64] =
  ## Convert Val to scalar number per boundary rule.
  ## undefined -> none (static fallback)
  ## number -> itself (NaN preserved)
  ## bool/string -> 0 (ThorVG rule, not JS)
  ## array -> first element rule: first exists => toScalarNumber(first) else 0
  ##   but D1-exc3: non-numeric/nested element -> 0 (NaN preserved only if number NaN)
  case v.kind
  of vkUndef:
    return none(float64)
  of vkNum:
    return some(v.num)
  of vkBool, vkStr, vkNull:
    return some(0.0'f64)
  of vkArray:
    if v.items.len == 0:
      return some(0.0'f64)
    let first = v.items[0]
    case first.kind
    of vkNum:
      return some(first.num) # NaN preserved
    of vkBool, vkStr, vkUndef, vkNull, vkArray:
      # D1-exc3: non-numeric/nested -> 0
      return some(0.0'f64)

proc toPropScalar*(v: Val): PropScalar =
  ## undefined -> none (static); null/bool/string/num/array per toScalarNumber
  if v.kind == vkUndef: return none(float64)
  return toScalarNumber(v)

proc toPropVec*(v: Val; dim: int): PropVec =
  ## dim=2 for position/scale/anchor. undefined -> none (static).
  ## array -> take first dim elements, pad with 0, truncate; element rule: num->self(NaN preserved), else 0 (D1-exc3)
  ## non-array scalar/bool/string/null-like non-undef -> [0,0,...]
  if v.kind == vkUndef: return none(seq[float64])
  if v.kind == vkArray:
    var outp: seq[float64] = @[]
    for i in 0 ..< dim:
      if i < v.items.len:
        let e = v.items[i]
        case e.kind
        of vkNum: outp.add(e.num)
        of vkBool, vkStr, vkUndef, vkNull, vkArray: outp.add(0.0'f64) # D1-exc3
      else:
        outp.add(0.0'f64)
    return some(outp)
  # scalar/bool/string on vec2 -> [0,0]
  var zeros: seq[float64] = @[]
  for _ in 0 ..< dim: zeros.add(0.0'f64)
  return some(zeros)

proc toPropOpacityU8*(v: Val; staticPct: float32 = 100.0'f32): Option[uint8] =
  ## Returns none => use static opacity. D1-exc2 clamp for OOB/UB.
  ## Formula: p = float32(percent) * 2.55f32; NaN->0; p<=0->0; p>=255->255; else uint8(trunc(p))
  if v.kind == vkUndef: return none(uint8)
  let scalar = toScalarNumber(v)
  if scalar.isNone: return none(uint8)
  let pct = float32(scalar.get())
  if pct != pct: # NaN
    return some(0'u8)
  let p = pct * 2.55'f32
  if p != p: return some(0'u8)
  if p <= 0.0'f32: return some(0'u8)
  if p >= 255.0'f32: return some(255'u8)
  return some(uint8(int(p)))

proc staticOpacityU8*(pct: float32): uint8 =
  ## Same boundary as expression opacity (D1-exc2). Reuse in parser/static path.
  let p = pct * 2.55'f32
  if p != p: return 0'u8
  if p <= 0.0'f32: return 0'u8
  if p >= 255.0'f32: return 255'u8
  return uint8(int(p))
