## Expression runtime value (AOT). No JS engine. Elements of arrays are Val.
type
  ValKind* = enum
    vkUndef, vkNull, vkNum, vkBool, vkStr, vkArray

  Val* = object
    case kind*: ValKind
    of vkUndef, vkNull: discard
    of vkNum: num*: float64
    of vkBool: b*: bool
    of vkStr: s*: string
    of vkArray: items*: seq[Val]

proc vUndef*(): Val = Val(kind: vkUndef)
proc vNull*(): Val = Val(kind: vkNull)
proc vNum*(x: float64): Val = Val(kind: vkNum, num: x)
proc vBool*(x: bool): Val = Val(kind: vkBool, b: x)
proc vStr*(x: string): Val = Val(kind: vkStr, s: x)
proc vArray*(xs: seq[Val]): Val = Val(kind: vkArray, items: xs)

proc isNaN*(v: Val): bool = v.kind == vkNum and v.num != v.num
