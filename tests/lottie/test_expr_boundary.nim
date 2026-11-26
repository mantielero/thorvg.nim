import std/[json, os, strformat, strutils, math, options]
import ../../src/thorvg/lottie/expr/[val, boundary]

var failures = 0
var passes = 0

template check(name: string; cond: bool) =
  if cond:
    inc passes
  else:
    inc failures
    echo "FAIL ", name

proc nearlyEqual(a, b: float64; epsAbs = 1e-9; epsRel = 4e-7'f64): bool =
  if a != a and b != b: return true # NaN
  if a != a or b != b: return false
  if a == b: return true
  let diff = abs(a - b)
  diff <= epsAbs + epsRel * abs(b)

proc valFromSpec(j: JsonNode): Val =
  let k = j["k"].getStr
  case k
  of "undef": vUndef()
  of "null": vNull()
  of "nan": vNum(NaN)
  of "inf": vNum(Inf)
  of "ninf": vNum(-Inf)
  of "bool": vBool(j["v"].getBool)
  of "num":
    let v = j["v"]
    if v.kind == JInt: vNum(float64(v.getBiggestInt()))
    else: vNum(v.getFloat)
  of "str": vStr(j["v"].getStr)
  of "arr":
    var items: seq[Val] = @[]
    for it in j["v"]:
      items.add valFromSpec(it)
    vArray(items)
  else:
    vUndef()

proc checkScalar(name: string; got: Option[float64]; exp: JsonNode) =
  let ek = exp["k"].getStr
  case ek
  of "static":
    check(name & " static", got.isNone)
  of "num":
    let ev = exp["v"]
    let e = if ev.kind == JInt: float64(ev.getBiggestInt()) else: ev.getFloat
    check(name & " some", got.isSome)
    if got.isSome:
      check(name & " value", nearlyEqual(got.get(), e))
  of "nan":
    check(name & " nan", got.isSome and got.get() != got.get())
  of "inf":
    check(name & " inf", got.isSome and got.get() == Inf)
  of "ninf":
    check(name & " ninf", got.isSome and got.get() == -Inf)
  else:
    check(name & " unknown expected " & ek, false)

proc checkVec(name: string; got: Option[seq[float64]]; exp: JsonNode) =
  let ek = exp["k"].getStr
  case ek
  of "static":
    check(name & " static", got.isNone)
  of "vec":
    check(name & " some", got.isSome)
    if got.isSome:
      let gv = got.get()
      let ev = exp["v"]
      check(name & " len", gv.len == ev.len)
      for i in 0 ..< min(gv.len, ev.len):
        let ej = ev[i]
        if ej.kind == JString and ej.getStr == "nan":
          check(name & "[" & $i & "] nan", gv[i] != gv[i])
        elif ej.kind == JString and ej.getStr == "inf":
          check(name & "[" & $i & "] inf", gv[i] == Inf)
        elif ej.kind == JString and ej.getStr == "ninf":
          check(name & "[" & $i & "] ninf", gv[i] == -Inf)
        else:
          let e = if ej.kind == JInt: float64(ej.getBiggestInt()) else: ej.getFloat
          check(name & "[" & $i & "]", nearlyEqual(gv[i], e))
  else:
    check(name & " unknown expected " & ek, false)

proc checkOpacity(name: string; got: Option[uint8]; exp: JsonNode) =
  let ek = exp["k"].getStr
  case ek
  of "static":
    check(name & " static", got.isNone)
  of "u8":
    check(name & " some", got.isSome)
    if got.isSome:
      check(name & " value", got.get() == uint8(exp["v"].getInt))
  else:
    check(name & " unknown expected " & ek, false)

proc main() =
  let data = parseFile("tests/lottie/expr_boundary_cases.json")
  var pending = 0
  for sec in ["scalar", "vec2", "opacity"]:
    for c in data[sec]:
      let status = c["status"].getStr
      let id = c["id"].getStr
      if status == "pending-oracle":
        inc pending
        echo "PENDING ", id
        continue
      if c.hasKey("kind") and c["kind"].getStr == "sweep":
        # opacity sweep: verify formula exactness using nimExpected/expected not present as per-value; use golden file
        let goldenPath = c["golden"].getStr
        if not fileExists(goldenPath):
          check(id & " sweep golden exists", false)
          continue
        var ok = true
        var n = 0
        for line in lines(goldenPath):
          if line.len == 0: continue
          let j = parseJson(line)
          let frame = j["frame"].getFloat
          let gotU8 = uint8(int(j["value"][0].getFloat))
          # sweep is time*10 = frame in our generated case
          let pct = float32(frame)
          let expU8 = staticOpacityU8(pct)
          if gotU8 != expU8:
            ok = false
            echo "FAIL ", id, " frame=", frame, " got=", gotU8, " exp=", expU8
          inc n
        check(id & " sweep count 1001", n == 1001)
        check(id & " sweep exact", ok)
        continue
      let exp = c["expected"]
      if exp.kind == JNull:
        check(id & " has expected", false)
        continue
      # build input val
      if not c.hasKey("input"):
        # program/boundary-mixed; skip in 3a boundary-only
        continue
      let v = valFromSpec(c["input"])
      if sec == "scalar":
        checkScalar(id, toPropScalar(v), exp)
      elif sec == "vec2":
        checkVec(id, toPropVec(v, 2), exp)
      elif sec == "opacity":
        checkOpacity(id, toPropOpacityU8(v), exp)

  # program cases: boundary/diagnostic only - no eval here
  for c in data["program"]:
    let status = c["status"].getStr
    if status == "pending-oracle":
      inc pending
      echo "PENDING ", c["id"].getStr

  check("no pending-oracle at Paso 3a", pending == 0)
  echo fmt"pass={passes} fail={failures} pending={pending}"
  if failures > 0 or pending > 0: quit(1)

when isMainModule:
  main()
