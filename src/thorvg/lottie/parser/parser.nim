## Minimal Lottie JSON parser for Phase 1 (transform/property evaluation).

import std/[json, math, tables, strutils, os]
import jsony
import ../model/[common, model, property]
import ../../core/types
import ../animation/interpolator

type
  LottieParseError* = object of ValueError

var gSlotBindings: seq[LottieSlotBinding] = @[]

proc djb2Encode(s: string): uint32 =
  var h: uint32 = 5381'u32
  for c in s:
    h = ((h shl 5) + h) + uint32(uint8(c))
  h

proc getNode(j: JsonNode; k: string): JsonNode =
  if j.kind == JObject and j.hasKey(k): j[k] else: newJNull()

proc asFloat(j: JsonNode; def = 0.0'f32): float32 =
  case j.kind
  of JInt: float32(j.getBiggestInt())
  of JFloat: float32(j.getFloat())
  of JArray:
    if j.len > 0: asFloat(j[0], def) else: def
  of JBool: (if j.getBool(): 1.0'f32 else: 0.0'f32)
  else: def

proc asInt(j: JsonNode; def = 0): int =
  case j.kind
  of JInt: int(j.getBiggestInt())
  of JFloat: int(j.getFloat())
  of JBool: (if j.getBool(): 1 else: 0)
  of JArray:
    if j.len > 0: asInt(j[0], def) else: def
  else: def

proc asPoint(j: JsonNode; def = lp(0,0)): LottiePoint =
  if j.kind == JArray and j.len >= 2:
    lp(asFloat(j[0]), asFloat(j[1]))
  elif j.kind == JObject:
    lp(asFloat(j.getNode("x")), asFloat(j.getNode("y")))
  else: def

proc getInterpolatorPoint(j: JsonNode): LottiePoint =
  if j.kind == JObject:
    lp(asFloat(j.getNode("x")), asFloat(j.getNode("y")))
  else: lp(0,0)

proc hasExpr(j: JsonNode): bool =
  j.kind == JObject and j.hasKey("x") and j["x"].kind == JString

proc asColor(j: JsonNode; def = LottieColor(r:0,g:0,b:0)): LottieColor =
  if j.kind == JArray and j.len >= 3:
    LottieColor(r: asFloat(j[0]), g: asFloat(j[1]), b: asFloat(j[2]))
  elif j.kind == JObject:
    LottieColor(r: asFloat(j.getNode("r")), g: asFloat(j.getNode("g")), b: asFloat(j.getNode("b")))
  else: def

proc asPath(j: JsonNode): LottiePath =
  result = LottiePath(closed: false)
  if j.kind != JObject: return
  if j.hasKey("c"):
    let c = j["c"]
    result.closed = (c.kind == JBool and c.getBool()) or (c.kind == JInt and c.getBiggestInt() != 0)
  if j.hasKey("v") and j["v"].kind == JArray:
    for p in j["v"]:
      result.pts.add(asPoint(p))
  if j.hasKey("i") and j["i"].kind == JArray:
    for p in j["i"]:
      result.inTangents.add(asPoint(p))
  if j.hasKey("o") and j["o"].kind == JArray:
    for p in j["o"]:
      result.outTangents.add(asPoint(p))

proc makeInterpolator(inT, outT: LottiePoint): LottieInterpolator =
  result = LottieInterpolator()
  let key = $inT.x & "_" & $inT.y & "_" & $outT.x & "_" & $outT.y
  result.set(key, inT, outT)

proc isArrayEasing(j: JsonNode): bool =
  if j.kind != JObject: return false
  let x = j.getNode("x")
  let y = j.getNode("y")
  (x.kind == JArray and x.len > 1) or (y.kind == JArray and y.len > 1)

proc getDimEasing(inJ, outJ: JsonNode; dim: int): tuple[inT, outT: LottiePoint] =
  proc getAt(j: JsonNode; key: string; dim: int): float32 =
    let n = j.getNode(key)
    if n.kind == JArray and dim < n.len: asFloat(n[dim])
    elif n.kind == JArray and n.len > 0: asFloat(n[0])
    else: asFloat(n)
  result.inT = lp(getAt(inJ, "x", dim), getAt(inJ, "y", dim))
  result.outT = lp(getAt(outJ, "x", dim), getAt(outJ, "y", dim))

proc makeDimInterpolators(inJ, outJ: JsonNode; dims: int): seq[LottieInterpolator] =
  result = @[]
  for d in 0 ..< dims:
    let e = getDimEasing(inJ, outJ, d)
    result.add(makeInterpolator(e.inT, e.outT))

proc parseScalarFloatFrames(k: JsonNode; def: float32): LottieGenericProperty[LottieScalarFrame[float32], float32] =
  result = newScalarProp(def)
  if k.kind != JArray: return
  result.hasFrames = true
  result.frames = @[]
  var pendingE: float32 = 0.0'f32
  var hasPendingE = false
  for item in k:
    if item.kind != JObject: continue
    var f: LottieScalarFrame[float32]
    f.no = asFloat(item.getNode("t"))
    if item.hasKey("s"):
      f.value = asFloat(item["s"])
    elif hasPendingE:
      f.value = pendingE
      hasPendingE = false
    else:
      f.value = def
    f.hold = asInt(item.getNode("h"), 0) != 0
    var inTan = lp(0,0); var outTan = lp(1,1); var hasInterp = false
    if item.hasKey("i"): inTan = getInterpolatorPoint(item["i"]); hasInterp = true
    if item.hasKey("o"): outTan = getInterpolatorPoint(item["o"]); hasInterp = true
    if hasInterp: f.interpolator = makeInterpolator(inTan, outTan)
    if item.hasKey("e"):
      pendingE = asFloat(item["e"])
      hasPendingE = true
    result.frames.add(f)
  if result.frames.len > 0: result.value = result.frames[0].value

proc parseScalarProp(j: JsonNode; def = 0.0'f32): LottieGenericProperty[LottieScalarFrame[float32], float32] =
  var sid: uint32 = 0
  if j.kind == JObject and j.hasKey("sid") and j["sid"].kind == JString: sid = djb2Encode(j["sid"].getStr())
  if j.kind != JObject:
    result = newScalarProp(asFloat(j, def)); result.sid = sid; return
  let a = asInt(j.getNode("a"), 0)
  let k = j.getNode("k")
  if a == 0 or k.kind != JArray:
    result = newScalarProp(asFloat(k, def))
  else:
    result = parseScalarFloatFrames(k, def)
  result.sid = sid

proc parseOpacityFrames(k: JsonNode; def: uint8): LottieGenericProperty[LottieScalarFrame[uint8], uint8] =
  result = newScalarProp(def)
  if k.kind != JArray: return
  result.hasFrames = true
  result.frames = @[]
  var pendingE: uint8 = def
  var hasPendingE = false
  for item in k:
    if item.kind != JObject: continue
    var f: LottieScalarFrame[uint8]
    f.no = asFloat(item.getNode("t"))
    if item.hasKey("s"):
      f.value = uint8(clamp(int(asFloat(item["s"]) * 2.55'f32), 0, 255))
    elif hasPendingE:
      f.value = pendingE; hasPendingE = false
    else:
      f.value = def
    f.hold = asInt(item.getNode("h"), 0) != 0
    var inTan = lp(0,0); var outTan = lp(1,1); var hasInterp = false
    if item.hasKey("i"): inTan = getInterpolatorPoint(item["i"]); hasInterp = true
    if item.hasKey("o"): outTan = getInterpolatorPoint(item["o"]); hasInterp = true
    if hasInterp: f.interpolator = makeInterpolator(inTan, outTan)
    if item.hasKey("e"):
      pendingE = uint8(clamp(int(asFloat(item["e"]) * 2.55'f32), 0, 255))
      hasPendingE = true
    result.frames.add(f)
  if result.frames.len > 0: result.value = result.frames[0].value

proc parseOpacityProp(j: JsonNode; defPct: float32 = 100.0'f32): LottieGenericProperty[LottieScalarFrame[uint8], uint8] =
  let defVal = uint8(clamp(int(defPct * 2.55'f32), 0, 255))
  var sid: uint32 = 0
  if j.kind == JObject and j.hasKey("sid") and j["sid"].kind == JString: sid = djb2Encode(j["sid"].getStr())
  if j.kind != JObject:
    result = newScalarProp(uint8(clamp(int(asFloat(j, defPct) * 2.55'f32), 0, 255))); result.sid = sid; return
  let a = asInt(j.getNode("a"), 0)
  let k = j.getNode("k")
  if a == 0 or k.kind != JArray:
    result = newScalarProp(uint8(clamp(int(asFloat(k, defPct) * 2.55'f32), 0, 255)))
  else:
    result = parseOpacityFrames(k, defVal)
  result.sid = sid

proc parseScalarColorFrames(k: JsonNode; def: LottieColor): LottieGenericProperty[LottieScalarFrame[LottieColor], LottieColor] =
  result = newColorProp(def)
  if k.kind != JArray: return
  result.hasFrames = true
  result.frames = @[]
  var pendingE = def
  var hasPendingE = false
  for item in k:
    if item.kind != JObject: continue
    var f: LottieScalarFrame[LottieColor]
    f.no = asFloat(item.getNode("t"))
    if item.hasKey("s"):
      f.value = asColor(item["s"], def)
    elif hasPendingE:
      f.value = pendingE; hasPendingE = false
    else:
      f.value = def
    f.hold = asInt(item.getNode("h"), 0) != 0
    let iJ = item.getNode("i")
    let oJ = item.getNode("o")
    if item.hasKey("i") or item.hasKey("o"):
      let inTan = getInterpolatorPoint(iJ)
      let outTan = getInterpolatorPoint(oJ)
      f.interpolator = makeInterpolator(inTan, outTan)
      if isArrayEasing(iJ) or isArrayEasing(oJ):
        f.interpolatorsD = makeDimInterpolators(iJ, oJ, 3)
    if item.hasKey("e"):
      pendingE = asColor(item["e"], def)
      hasPendingE = true
    result.frames.add(f)
  if result.frames.len > 0: result.value = result.frames[0].value

proc parseColorProp(j: JsonNode; def = LottieColor(r:0,g:0,b:0)): LottieGenericProperty[LottieScalarFrame[LottieColor], LottieColor] =
  var sid: uint32 = 0
  if j.kind == JObject and j.hasKey("sid") and j["sid"].kind == JString: sid = djb2Encode(j["sid"].getStr())
  if j.kind != JObject:
    result = newColorProp(asColor(j, def)); result.sid = sid; return
  let a = asInt(j.getNode("a"), 0)
  let k = j.getNode("k")
  if a == 0 or k.kind != JArray:
    result = newColorProp(asColor(k, def))
  else:
    result = parseScalarColorFrames(k, def)
  result.sid = sid

proc parseScalarPointFrames(k: JsonNode; def: LottiePoint): LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint] =
  result = newScalarProp(def)
  if k.kind != JArray: return
  result.hasFrames = true
  result.frames = @[]
  var pendingE = def
  var hasPendingE = false
  for item in k:
    if item.kind != JObject: continue
    var f: LottieScalarFrame[LottiePoint]
    f.no = asFloat(item.getNode("t"))
    if item.hasKey("s"):
      f.value = asPoint(item["s"], def)
    elif hasPendingE:
      f.value = pendingE; hasPendingE = false
    else:
      f.value = def
    f.hold = asInt(item.getNode("h"), 0) != 0
    var hasInterp = false
    let iJ = item.getNode("i")
    let oJ = item.getNode("o")
    if item.hasKey("i") or item.hasKey("o"):
      hasInterp = true
      let inTan = getInterpolatorPoint(iJ)
      let outTan = getInterpolatorPoint(oJ)
      f.interpolator = makeInterpolator(inTan, outTan)
      if isArrayEasing(iJ) or isArrayEasing(oJ):
        f.interpolatorsD = makeDimInterpolators(iJ, oJ, 2)
    if item.hasKey("e"):
      pendingE = asPoint(item["e"], def)
      hasPendingE = true
    result.frames.add(f)
  if result.frames.len > 0: result.value = result.frames[0].value

proc parseVectorPointFrames(k: JsonNode; def: LottiePoint): LottieGenericProperty[LottieVectorFrame[LottiePoint], LottiePoint] =
  result = newVectorProp(def)
  if k.kind != JArray: return
  result.hasFrames = true
  result.frames = @[]
  var pendingE = def
  var hasPendingE = false
  for item in k:
    if item.kind != JObject: continue
    var f: LottieVectorFrame[LottiePoint]
    f.no = asFloat(item.getNode("t"))
    if item.hasKey("s"):
      f.value = asPoint(item["s"], def)
    elif hasPendingE:
      f.value = pendingE; hasPendingE = false
    else:
      f.value = def
    f.hold = asInt(item.getNode("h"), 0) != 0
    let iJ = item.getNode("i")
    let oJ = item.getNode("o")
    if item.hasKey("i") or item.hasKey("o"):
      let inTan = getInterpolatorPoint(iJ)
      let outTan = getInterpolatorPoint(oJ)
      f.interpolator = makeInterpolator(inTan, outTan)
      if isArrayEasing(iJ) or isArrayEasing(oJ):
        f.interpolatorsD = makeDimInterpolators(iJ, oJ, 2)
    # spatial tangents
    if item.hasKey("ti"):
      f.inTangent = asPoint(item["ti"]); f.hasTangent = true
    if item.hasKey("to"):
      f.outTangent = asPoint(item["to"]); f.hasTangent = true
    if item.hasKey("e"):
      pendingE = asPoint(item["e"], def)
      hasPendingE = true
    result.frames.add(f)
  # prepare lengths
  for i in 0 ..< max(0, result.frames.len - 1):
    var fr = result.frames[i]
    fr.prepareVector(result.frames[i+1])
    result.frames[i] = fr
  if result.frames.len > 0: result.value = result.frames[0].value

proc parsePositionProp(j: JsonNode; def = lp(0,0)): LottieGenericProperty[LottieVectorFrame[LottiePoint], LottiePoint] =
  if j.kind != JObject: return newVectorProp(asPoint(j, def))
  let a = asInt(j.getNode("a"), 0)
  let k = j.getNode("k")
  if a == 0 or k.kind != JArray:
    return newVectorProp(asPoint(k, def))
  parseVectorPointFrames(k, def)

proc parseScalarPointProp(j: JsonNode; def = lp(0,0)): LottieGenericProperty[LottieScalarFrame[LottiePoint], LottiePoint] =
  var sid: uint32 = 0
  if j.kind == JObject and j.hasKey("sid") and j["sid"].kind == JString: sid = djb2Encode(j["sid"].getStr())
  if j.kind != JObject:
    result = newScalarProp(asPoint(j, def)); result.sid = sid; return
  let a = asInt(j.getNode("a"), 0)
  let k = j.getNode("k")
  if a == 0 or k.kind != JArray:
    result = newScalarProp(asPoint(k, def))
  else:
    result = parseScalarPointFrames(k, def)
  result.sid = sid

proc pathFromK(k: JsonNode): LottiePath =
  if k.kind == JArray and k.len > 0 and k[0].kind == JObject and k[0].hasKey("v"):
    asPath(k[0])
  elif k.kind == JObject and k.hasKey("v"):
    asPath(k)
  else:
    LottiePath(closed: false)

proc parsePathFrames(k: JsonNode; def: LottiePath): LottieGenericProperty[LottieScalarFrame[LottiePath], LottiePath] =
  result = newPathProp(def)
  if k.kind != JArray: return
  result.hasFrames = true
  result.frames = @[]
  var pendingE = def
  var hasPendingE = false
  for item in k:
    if item.kind != JObject: continue
    var f: LottieScalarFrame[LottiePath]
    f.no = asFloat(item.getNode("t"))
    if item.hasKey("s"):
      f.value = pathFromK(item["s"])
    elif hasPendingE:
      f.value = pendingE; hasPendingE = false
    else:
      f.value = def
    f.hold = asInt(item.getNode("h"), 0) != 0
    if item.hasKey("e"):
      pendingE = pathFromK(item["e"])
      hasPendingE = true
    result.frames.add(f)
  if result.frames.len > 0: result.value = result.frames[0].value

proc parsePathProp*(j: JsonNode; def = LottiePath(closed:false)): LottieGenericProperty[LottieScalarFrame[LottiePath], LottiePath] =
  var sid: uint32 = 0
  if j.kind == JObject and j.hasKey("sid") and j["sid"].kind == JString: sid = djb2Encode(j["sid"].getStr())
  if j.kind != JObject:
    result = newPathProp(pathFromK(j)); result.sid = sid; return
  let a = asInt(j.getNode("a"), 0)
  let k = j.getNode("k")
  if a == 0 or k.kind != JArray:
    result = newPathProp(pathFromK(k))
  else:
    result = parsePathFrames(k, def)
  result.sid = sid

proc parseTransform(j: JsonNode; warnings: var seq[string]; layerName: string): LottieTransform =
  result = newLottieTransform()
  if j.kind != JObject: return
  let t = result
  if j.hasKey("o"):
    if hasExpr(j["o"]): warnings.add("layer '" & layerName & "': opacity has expression, skipped")
    t.opacity = parseOpacityProp(j["o"], 100.0'f32)
    if t.opacity.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.opacity.sid, apply: proc(ov: JsonNode) = t.opacity = parseOpacityProp(ov, 100.0'f32)))
  if j.hasKey("r"):
    if hasExpr(j["r"]): warnings.add("layer '" & layerName & "': rotation has expression, skipped")
    t.rotation = parseScalarProp(j["r"], 0.0'f32)
    if t.rotation.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.rotation.sid, apply: proc(ov: JsonNode) = t.rotation = parseScalarProp(ov, 0.0'f32)))
  if j.hasKey("p"):
    let p = j["p"]
    if hasExpr(p): warnings.add("layer '" & layerName & "': position has expression, skipped")
    let sep = p.kind == JObject and p.hasKey("s") and asInt(p.getNode("s"), 0) == 1
    if sep:
      t.separate = true
      if p.hasKey("x"):
        if hasExpr(p["x"]): warnings.add("layer '" & layerName & "': position.x has expression, skipped")
        t.sepX = parseScalarProp(p["x"], 0.0'f32)
        if t.sepX.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.sepX.sid, apply: proc(ov: JsonNode) = t.sepX = parseScalarProp(ov, 0.0'f32)))
      if p.hasKey("y"):
        if hasExpr(p["y"]): warnings.add("layer '" & layerName & "': position.y has expression, skipped")
        t.sepY = parseScalarProp(p["y"], 0.0'f32)
        if t.sepY.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.sepY.sid, apply: proc(ov: JsonNode) = t.sepY = parseScalarProp(ov, 0.0'f32)))
    else:
      t.position = parsePositionProp(p, lp(0,0))
      if t.position.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.position.sid, apply: proc(ov: JsonNode) = t.position = parsePositionProp(ov, lp(0,0))))
  if j.hasKey("a"):
    if hasExpr(j["a"]): warnings.add("layer '" & layerName & "': anchor has expression, skipped")
    t.anchor = parseScalarPointProp(j["a"], lp(0,0))
    if t.anchor.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.anchor.sid, apply: proc(ov: JsonNode) = t.anchor = parseScalarPointProp(ov, lp(0,0))))
  if j.hasKey("s"):
    if hasExpr(j["s"]): warnings.add("layer '" & layerName & "': scale has expression, skipped")
    t.scale = parseScalarPointProp(j["s"], lp(100,100))
    if t.scale.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.scale.sid, apply: proc(ov: JsonNode) = t.scale = parseScalarPointProp(ov, lp(100,100))))
  if j.hasKey("sk"):
    if hasExpr(j["sk"]): warnings.add("layer '" & layerName & "': skew has expression, skipped")
    t.skewAngle = parseScalarProp(j["sk"], 0.0'f32)
    if t.skewAngle.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.skewAngle.sid, apply: proc(ov: JsonNode) = t.skewAngle = parseScalarProp(ov, 0.0'f32)))
  if j.hasKey("sa"):
    if hasExpr(j["sa"]): warnings.add("layer '" & layerName & "': skew axis has expression, skipped")
    t.skewAxis = parseScalarProp(j["sa"], 0.0'f32)
    if t.skewAxis.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.skewAxis.sid, apply: proc(ov: JsonNode) = t.skewAxis = parseScalarProp(ov, 0.0'f32)))
  let has3D = j.hasKey("rx") or j.hasKey("ry") or j.hasKey("rz") or j.hasKey("or")
  if has3D:
    t.has3D = true
    if j.hasKey("rx"):
      if hasExpr(j["rx"]): warnings.add("layer '" & layerName & "': rx has expression, skipped")
      t.rx = parseScalarProp(j["rx"], 0.0'f32)
      if t.rx.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.rx.sid, apply: proc(ov: JsonNode) = t.rx = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("ry"):
      if hasExpr(j["ry"]): warnings.add("layer '" & layerName & "': ry has expression, skipped")
      t.ry = parseScalarProp(j["ry"], 0.0'f32)
      if t.ry.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.ry.sid, apply: proc(ov: JsonNode) = t.ry = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("rz"):
      if hasExpr(j["rz"]): warnings.add("layer '" & layerName & "': rz has expression, skipped")
      t.rotation = parseScalarProp(j["rz"], 0.0'f32)
      if t.rotation.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.rotation.sid, apply: proc(ov: JsonNode) = t.rotation = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("or"):
      if hasExpr(j["or"]): warnings.add("layer '" & layerName & "': orientation has expression, skipped")
      t.orient = parseScalarPointProp(j["or"], lp(0,0))
      if t.orient.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: t.orient.sid, apply: proc(ov: JsonNode) = t.orient = parseScalarPointProp(ov, lp(0,0))))
      # orient z: parse third component
      block parseOrientZ:
        let oj = j["or"]
        if oj.kind == JObject:
          let oa = asInt(oj.getNode("a"), 0)
          let ok = oj.getNode("k")
          if oa == 0 or ok.kind != JArray:
            let zv = if ok.kind == JArray and ok.len >= 3: asFloat(ok[2]) else: 0.0'f32
            t.orientZ = newScalarProp(zv)
          else:
            var zp = newScalarProp(0.0'f32)
            zp.hasFrames = true
            zp.frames = @[]
            var pendingZ = 0.0'f32
            var hasPendingZ = false
            for item in ok:
              if item.kind != JObject: continue
              var f: LottieScalarFrame[float32]
              f.no = asFloat(item.getNode("t"))
              f.hold = asInt(item.getNode("h"), 0) == 1
              if item.hasKey("s") and item["s"].kind == JArray and item["s"].len >= 3:
                f.value = asFloat(item["s"][2])
              elif hasPendingZ:
                f.value = pendingZ
                hasPendingZ = false
              else:
                f.value = 0.0'f32
              if item.hasKey("e") and item["e"].kind == JArray and item["e"].len >= 3:
                pendingZ = asFloat(item["e"][2]); hasPendingZ = true
              if item.hasKey("i") or item.hasKey("o"):
                let inTan = getInterpolatorPoint(item.getNode("i"))
                let outTan = getInterpolatorPoint(item.getNode("o"))
                f.interpolator = makeInterpolator(inTan, outTan)
              zp.frames.add(f)
            t.orientZ = zp
        elif oj.kind == JArray and oj.len >= 3:
          t.orientZ = newScalarProp(asFloat(oj[2]))

proc parseShape(j: JsonNode; warnings: var seq[string]; ctx: string): LottieObject

proc parseShapes(j: JsonNode; warnings: var seq[string]; ctx: string): seq[LottieObject] =
  result = @[]
  if j.kind != JArray: return
  var i = 0
  for item in j:
    let child = parseShape(item, warnings, ctx & "[" & $i & "]")
    if child != nil: result.add(child)
    inc i

proc parseGradientStops(j: JsonNode; sid: var uint32): seq[LottieGradientStop] =
  result = @[]
  # j is the "g" object: {p: count, k: [...] } or {p: count, k: {a:0,k:[...]}}
  if j.kind != JObject or not j.hasKey("k"): return
  if j.hasKey("sid") and j["sid"].kind == JString: sid = djb2Encode(j["sid"].getStr())
  var k = j["k"]
  if k.kind == JObject:
    if k.hasKey("sid") and k["sid"].kind == JString: sid = djb2Encode(k["sid"].getStr())
    if k.hasKey("k"): k = k["k"] # static or animated wrapper
  if k.kind == JObject and k.hasKey("k"): k = k["k"]
  if k.kind != JArray: return
  # p = number of color stops (each 4 values: offset,r,g,b). Remaining may be alpha stops.
  let p = if j.hasKey("p"): asInt(j["p"], 0) else: k.len div 4
  var i = 0
  while i + 3 < k.len and result.len < max(p, 0):
    let off = asFloat(k[i], 0.0'f32)
    let r = asFloat(k[i+1], 0.0'f32)
    let g = asFloat(k[i+2], 0.0'f32)
    let b = asFloat(k[i+3], 0.0'f32)
    result.add(LottieGradientStop(offset: off, color: LottieColor(r:r, g:g, b:b), alpha: 1.0'f32))
    i += 4
  # alpha stops: pairs (offset, alpha)
  var alphaStops: seq[(float32, float32)] = @[]
  while i + 1 < k.len:
    alphaStops.add((asFloat(k[i], 0.0'f32), asFloat(k[i+1], 1.0'f32)))
    i += 2
  # merge alpha stops by index if counts match, else by nearest offset
  if alphaStops.len > 0 and result.len > 0:
    if alphaStops.len == result.len:
      for j in 0 ..< result.len:
        result[j].alpha = alphaStops[j][1]
    else:
      for j in 0 ..< result.len:
        var best = 0
        var bestD = abs(result[j].offset - alphaStops[0][0])
        for a in 1 ..< alphaStops.len:
          let d = abs(result[j].offset - alphaStops[a][0])
          if d < bestD: bestD = d; best = a
        result[j].alpha = alphaStops[best][1]
  # if p was 0 or parsing failed, try to read all 4-tuples
  if result.len == 0:
    i = 0
    while i + 3 < k.len:
      let off = asFloat(k[i], 0.0'f32)
      let r = asFloat(k[i+1], 0.0'f32)
      let g = asFloat(k[i+2], 0.0'f32)
      let b = asFloat(k[i+3], 0.0'f32)
      result.add(LottieGradientStop(offset: off, color: LottieColor(r:r, g:g, b:b), alpha: 1.0'f32))
      i += 4

proc parseShape(j: JsonNode; warnings: var seq[string]; ctx: string): LottieObject =
  if j.kind != JObject: return nil
  let ty = if j.hasKey("ty"): j["ty"].getStr("") else: ""
  let nm = if j.hasKey("nm"): j["nm"].getStr("") else: ""
  let hd = j.hasKey("hd") and asInt(j["hd"], 0) != 0
  case ty
  of "gr":
    let g = LottieGroup(objType: otGroup, name: nm, hidden: hd)
    if j.hasKey("it"): g.children = parseShapes(j["it"], warnings, ctx & ".it")
    # group transform 'tr'
    if j.hasKey("tr"):
      g.children.add(parseTransform(j["tr"], warnings, ctx & ".tr(" & nm & ")"))
    return g
  of "sh":
    let p = LottiePathObj(objType: otPath, name: nm, hidden: hd)
    if j.hasKey("ks"):
      p.path = parsePathProp(j["ks"])
      if p.path.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: p.path.sid, apply: proc(ov: JsonNode) = p.path = parsePathProp(ov)))
    else: p.path = newPathProp(LottiePath(closed:false))
    return p
  of "rc":
    let r = LottieRectObj(objType: otRect, name: nm, hidden: hd,
      position: newScalarProp(lp(0,0)), size: newScalarProp(lp(0,0)), radius: newScalarProp(0.0'f32))
    if j.hasKey("p"):
      r.position = parseScalarPointProp(j["p"], lp(0,0))
      if r.position.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: r.position.sid, apply: proc(ov: JsonNode) = r.position = parseScalarPointProp(ov, lp(0,0))))
    if j.hasKey("s"):
      r.size = parseScalarPointProp(j["s"], lp(0,0))
      if r.size.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: r.size.sid, apply: proc(ov: JsonNode) = r.size = parseScalarPointProp(ov, lp(0,0))))
    if j.hasKey("r"):
      r.radius = parseScalarProp(j["r"], 0.0'f32)
      if r.radius.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: r.radius.sid, apply: proc(ov: JsonNode) = r.radius = parseScalarProp(ov, 0.0'f32)))
    return r
  of "el":
    let e = LottieEllipseObj(objType: otEllipse, name: nm, hidden: hd,
      position: newScalarProp(lp(0,0)), size: newScalarProp(lp(0,0)))
    if j.hasKey("p"):
      e.position = parseScalarPointProp(j["p"], lp(0,0))
      if e.position.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: e.position.sid, apply: proc(ov: JsonNode) = e.position = parseScalarPointProp(ov, lp(0,0))))
    if j.hasKey("s"):
      e.size = parseScalarPointProp(j["s"], lp(0,0))
      if e.size.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: e.size.sid, apply: proc(ov: JsonNode) = e.size = parseScalarPointProp(ov, lp(0,0))))
    return e
  of "fl":
    let f = LottieFillObj(objType: otSolidFill, name: nm, hidden: hd,
      color: newColorProp(LottieColor(r:0,g:0,b:0)), opacity: newScalarProp(255'u8), fillRule: 1)
    if j.hasKey("c"):
      if hasExpr(j["c"]): warnings.add(ctx & ".c: fill color has expression, skipped")
      f.color = parseColorProp(j["c"])
      if f.color.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: f.color.sid, apply: proc(ov: JsonNode) = f.color = parseColorProp(ov)))
    if j.hasKey("o"):
      if hasExpr(j["o"]): warnings.add(ctx & ".o: fill opacity has expression, skipped")
      f.opacity = parseOpacityProp(j["o"], 100.0'f32)
      if f.opacity.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: f.opacity.sid, apply: proc(ov: JsonNode) = f.opacity = parseOpacityProp(ov, 100.0'f32)))
    if j.hasKey("r"): f.fillRule = asInt(j["r"], 1)
    return f
  of "st":
    let st = LottieStrokeObj(objType: otSolidStroke, name: nm, hidden: hd,
      color: newColorProp(LottieColor(r:0,g:0,b:0)), opacity: newScalarProp(255'u8), width: newScalarProp(0.0'f32),
      cap: StrokeCap.Round, join: StrokeJoin.Round, miterLimit: 4.0'f32)
    if j.hasKey("c"):
      if hasExpr(j["c"]): warnings.add(ctx & ".c: stroke color has expression, skipped")
      st.color = parseColorProp(j["c"])
      if st.color.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: st.color.sid, apply: proc(ov: JsonNode) = st.color = parseColorProp(ov)))
    if j.hasKey("o"):
      if hasExpr(j["o"]): warnings.add(ctx & ".o: stroke opacity has expression, skipped")
      st.opacity = parseOpacityProp(j["o"], 100.0'f32)
      if st.opacity.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: st.opacity.sid, apply: proc(ov: JsonNode) = st.opacity = parseOpacityProp(ov, 100.0'f32)))
    if j.hasKey("w"):
      if hasExpr(j["w"]): warnings.add(ctx & ".w: stroke width has expression, skipped")
      st.width = parseScalarProp(j["w"], 0.0'f32)
      if st.width.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: st.width.sid, apply: proc(ov: JsonNode) = st.width = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("lc"): st.cap = StrokeCap(clamp(asInt(j["lc"], 2) - 1, 0, 2))
    if j.hasKey("lj"): st.join = StrokeJoin(clamp(asInt(j["lj"], 2) - 1, 0, 2))
    if j.hasKey("ml"): st.miterLimit = asFloat(j["ml"], 0.0'f32)
    if j.hasKey("d") and j["d"].kind == JArray:
      st.dashOffset = newScalarProp(0.0'f32)
      for di in j["d"]:
        if di.kind != JObject or not di.hasKey("v"): continue
        let dn = if di.hasKey("n"): di["n"].getStr("") else: ""
        let dv = parseScalarProp(di["v"], 0.0'f32)
        if dn == "o":
          st.dashOffset = dv
        else:
          st.dashes.add(dv)
    return st
  of "sr":
    let ps = LottiePolystarObj(objType: otPolystar, name: nm, hidden: hd,
      position: newScalarProp(lp(0,0)), outerRadius: newScalarProp(0.0'f32),
      innerRadius: newScalarProp(0.0'f32), outerRoundness: newScalarProp(0.0'f32),
      innerRoundness: newScalarProp(0.0'f32), rotation: newScalarProp(0.0'f32),
      points: newScalarProp(0.0'f32), starType: 1)
    if j.hasKey("p"):
      ps.position = parseScalarPointProp(j["p"], lp(0,0))
      if ps.position.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: ps.position.sid, apply: proc(ov: JsonNode) = ps.position = parseScalarPointProp(ov, lp(0,0))))
    if j.hasKey("or"):
      ps.outerRadius = parseScalarProp(j["or"], 0.0'f32)
      if ps.outerRadius.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: ps.outerRadius.sid, apply: proc(ov: JsonNode) = ps.outerRadius = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("ir"):
      ps.innerRadius = parseScalarProp(j["ir"], 0.0'f32)
      if ps.innerRadius.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: ps.innerRadius.sid, apply: proc(ov: JsonNode) = ps.innerRadius = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("os"):
      ps.outerRoundness = parseScalarProp(j["os"], 0.0'f32)
      if ps.outerRoundness.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: ps.outerRoundness.sid, apply: proc(ov: JsonNode) = ps.outerRoundness = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("is"):
      ps.innerRoundness = parseScalarProp(j["is"], 0.0'f32)
      if ps.innerRoundness.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: ps.innerRoundness.sid, apply: proc(ov: JsonNode) = ps.innerRoundness = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("r"):
      ps.rotation = parseScalarProp(j["r"], 0.0'f32)
      if ps.rotation.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: ps.rotation.sid, apply: proc(ov: JsonNode) = ps.rotation = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("pt"):
      ps.points = parseScalarProp(j["pt"], 0.0'f32)
      if ps.points.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: ps.points.sid, apply: proc(ov: JsonNode) = ps.points = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("sy"): ps.starType = asInt(j["sy"], 1)
    return ps
  of "gf":
    let gf = LottieGradientFillObj(objType: otGradientFill, name: nm, hidden: hd,
      opacity: newScalarProp(255'u8), start: newScalarProp(lp(0,0)), `end`: newScalarProp(lp(0,0)),
      height: newScalarProp(0.0'f32), angle: newScalarProp(0.0'f32),
      fillRule: 1, gradType: 1)
    if j.hasKey("o"):
      gf.opacity = parseOpacityProp(j["o"], 100.0'f32)
      if gf.opacity.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gf.opacity.sid, apply: proc(ov: JsonNode) = gf.opacity = parseOpacityProp(ov, 100.0'f32)))
    if j.hasKey("s"):
      gf.start = parseScalarPointProp(j["s"], lp(0,0))
      if gf.start.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gf.start.sid, apply: proc(ov: JsonNode) = gf.start = parseScalarPointProp(ov, lp(0,0))))
    if j.hasKey("e"):
      gf.`end` = parseScalarPointProp(j["e"], lp(0,0))
      if gf.`end`.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gf.`end`.sid, apply: proc(ov: JsonNode) = gf.`end` = parseScalarPointProp(ov, lp(0,0))))
    if j.hasKey("h"):
      gf.height = parseScalarProp(j["h"], 0.0'f32)
      if gf.height.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gf.height.sid, apply: proc(ov: JsonNode) = gf.height = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("a"):
      gf.angle = parseScalarProp(j["a"], 0.0'f32)
      if gf.angle.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gf.angle.sid, apply: proc(ov: JsonNode) = gf.angle = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("r"): gf.fillRule = asInt(j["r"], 1)
    if j.hasKey("t"): gf.gradType = asInt(j["t"], 1)
    if j.hasKey("g"):
      var gsid: uint32 = 0
      gf.stops = parseGradientStops(j["g"], gsid)
      gf.stopsSid = gsid
      if gsid != 0:
        let gg = gf
        gSlotBindings.add(LottieSlotBinding(sid: gsid, apply: proc(ov: JsonNode) =
          var s2: uint32 = 0
          gg.stops = parseGradientStops(ov, s2)))
    return gf
  of "gs":
    let gs = LottieGradientStrokeObj(objType: otGradientStroke, name: nm, hidden: hd,
      opacity: newScalarProp(255'u8), start: newScalarProp(lp(0,0)), `end`: newScalarProp(lp(0,0)),
      height: newScalarProp(0.0'f32), angle: newScalarProp(0.0'f32),
      width: newScalarProp(0.0'f32), gradType: 1,
      cap: StrokeCap.Round, join: StrokeJoin.Round, miterLimit: 0.0'f32)
    if j.hasKey("o"):
      gs.opacity = parseOpacityProp(j["o"], 100.0'f32)
      if gs.opacity.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gs.opacity.sid, apply: proc(ov: JsonNode) = gs.opacity = parseOpacityProp(ov, 100.0'f32)))
    if j.hasKey("s"):
      gs.start = parseScalarPointProp(j["s"], lp(0,0))
      if gs.start.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gs.start.sid, apply: proc(ov: JsonNode) = gs.start = parseScalarPointProp(ov, lp(0,0))))
    if j.hasKey("e"):
      gs.`end` = parseScalarPointProp(j["e"], lp(0,0))
      if gs.`end`.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gs.`end`.sid, apply: proc(ov: JsonNode) = gs.`end` = parseScalarPointProp(ov, lp(0,0))))
    if j.hasKey("w"):
      gs.width = parseScalarProp(j["w"], 0.0'f32)
      if gs.width.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gs.width.sid, apply: proc(ov: JsonNode) = gs.width = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("h"):
      gs.height = parseScalarProp(j["h"], 0.0'f32)
      if gs.height.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gs.height.sid, apply: proc(ov: JsonNode) = gs.height = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("a"):
      gs.angle = parseScalarProp(j["a"], 0.0'f32)
      if gs.angle.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: gs.angle.sid, apply: proc(ov: JsonNode) = gs.angle = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("t"): gs.gradType = asInt(j["t"], 1)
    if j.hasKey("lc"): gs.cap = StrokeCap(clamp(asInt(j["lc"], 2) - 1, 0, 2))
    if j.hasKey("lj"): gs.join = StrokeJoin(clamp(asInt(j["lj"], 2) - 1, 0, 2))
    if j.hasKey("ml"): gs.miterLimit = asFloat(j["ml"], 0.0'f32)
    if j.hasKey("g"):
      var gsid: uint32 = 0
      gs.stops = parseGradientStops(j["g"], gsid)
      gs.stopsSid = gsid
      if gsid != 0:
        let gg2 = gs
        gSlotBindings.add(LottieSlotBinding(sid: gsid, apply: proc(ov: JsonNode) =
          var s2: uint32 = 0
          gg2.stops = parseGradientStops(ov, s2)))
    if j.hasKey("d") and j["d"].kind == JArray:
      gs.dashOffset = newScalarProp(0.0'f32)
      for di in j["d"]:
        if di.kind != JObject or not di.hasKey("v"): continue
        let dn = if di.hasKey("n"): di["n"].getStr("") else: ""
        let dv = parseScalarProp(di["v"], 0.0'f32)
        if dn == "o":
          gs.dashOffset = dv
        else:
          gs.dashes.add(dv)
    return gs
  of "tm":
    let tm = LottieTrimpathObj(objType: otTrimpath, name: nm, hidden: hd,
      start: newScalarProp(0.0'f32), `end`: newScalarProp(100.0'f32), offset: newScalarProp(0.0'f32), mode: 1)
    if j.hasKey("s"):
      tm.start = parseScalarProp(j["s"], 0.0'f32)
      if tm.start.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: tm.start.sid, apply: proc(ov: JsonNode) = tm.start = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("e"):
      tm.`end` = parseScalarProp(j["e"], 100.0'f32)
      if tm.`end`.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: tm.`end`.sid, apply: proc(ov: JsonNode) = tm.`end` = parseScalarProp(ov, 100.0'f32)))
    if j.hasKey("o"):
      tm.offset = parseScalarProp(j["o"], 0.0'f32)
      if tm.offset.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: tm.offset.sid, apply: proc(ov: JsonNode) = tm.offset = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("m"):
      tm.mode = asInt(j["m"], 1)
    return tm
  of "rd":
    let rd = LottieRoundedCornerObj(objType: otRoundedCorner, name: nm, hidden: hd,
      radius: newScalarProp(0.0'f32))
    if j.hasKey("r"):
      rd.radius = parseScalarProp(j["r"], 0.0'f32)
      if rd.radius.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: rd.radius.sid, apply: proc(ov: JsonNode) = rd.radius = parseScalarProp(ov, 0.0'f32)))
    return rd
  of "zz":
    let zz = LottieZigZagObj(objType: otZigZag, name: nm, hidden: hd,
      amplitude: newScalarProp(0.0'f32), frequency: newScalarProp(0.0'f32), pointType: 1)
    if j.hasKey("s"):
      zz.amplitude = parseScalarProp(j["s"], 0.0'f32)
      if zz.amplitude.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: zz.amplitude.sid, apply: proc(ov: JsonNode) = zz.amplitude = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("pt"): zz.pointType = asInt(j["pt"], 1)
    if j.hasKey("r"):
      zz.frequency = parseScalarProp(j["r"], 0.0'f32)
      if zz.frequency.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: zz.frequency.sid, apply: proc(ov: JsonNode) = zz.frequency = parseScalarProp(ov, 0.0'f32)))
    return zz
  of "mm":
    let mm = LottieMergePathObj(objType: otMergePath, name: nm, hidden: hd, mergeMode: 1)
    if j.hasKey("mm"): mm.mergeMode = asInt(j["mm"], 1)
    return mm
  of "op":
    let op = LottieOffsetPathObj(objType: otOffsetPath, name: nm, hidden: hd,
      offset: newScalarProp(0.0'f32), miterLimit: 4.0'f32, join: 0)
    if j.hasKey("a"):
      op.offset = parseScalarProp(j["a"], 0.0'f32)
      if op.offset.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: op.offset.sid, apply: proc(ov: JsonNode) = op.offset = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("ml"): op.miterLimit = asFloat(j["ml"], 4.0'f32)
    if j.hasKey("lj"): op.join = asInt(j["lj"], 0)
    return op
  of "rp":
    let rp = LottieRepeaterObj(objType: otRepeater, name: nm, hidden: hd,
      copies: newScalarProp(0.0'f32), offset: newScalarProp(0.0'f32),
      position: newScalarProp(lp(0,0)), anchor: newScalarProp(lp(0,0)),
      scale: newScalarProp(lp(100,100)), rotation: newScalarProp(0.0'f32),
      startOpacity: newScalarProp(100.0'f32), endOpacity: newScalarProp(100.0'f32),
      inorder: true)
    if j.hasKey("c"):
      rp.copies = parseScalarProp(j["c"], 0.0'f32)
      if rp.copies.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: rp.copies.sid, apply: proc(ov: JsonNode) = rp.copies = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("o"):
      rp.offset = parseScalarProp(j["o"], 0.0'f32)
      if rp.offset.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: rp.offset.sid, apply: proc(ov: JsonNode) = rp.offset = parseScalarProp(ov, 0.0'f32)))
    if j.hasKey("m"):
      rp.inorder = asInt(j["m"], 1) == 2
    if j.hasKey("tr") and j["tr"].kind == JObject:
      let tr = j["tr"]
      if tr.hasKey("a"): rp.anchor = parseScalarPointProp(tr["a"], lp(0,0))
      if tr.hasKey("p"): rp.position = parseScalarPointProp(tr["p"], lp(0,0))
      if tr.hasKey("r"): rp.rotation = parseScalarProp(tr["r"], 0.0'f32)
      if tr.hasKey("s"): rp.scale = parseScalarPointProp(tr["s"], lp(100,100))
      if tr.hasKey("so"): rp.startOpacity = parseScalarProp(tr["so"], 100.0'f32)
      if tr.hasKey("eo"): rp.endOpacity = parseScalarProp(tr["eo"], 100.0'f32)
    return rp
  of "pb":
    let pb = LottiePuckerBloatObj(objType: otPuckerBloat, name: nm, hidden: hd,
      amount: newScalarProp(0.0'f32))
    if j.hasKey("a"):
      pb.amount = parseScalarProp(j["a"], 0.0'f32)
      if pb.amount.sid != 0: gSlotBindings.add(LottieSlotBinding(sid: pb.amount.sid, apply: proc(ov: JsonNode) = pb.amount = parseScalarProp(ov, 0.0'f32)))
    return pb
  of "tr":
    return parseTransform(j, warnings, ctx & ".tr")
  of "":
    warnings.add(ctx & ": shape missing 'ty'")
    return nil
  else:
    let o = LottieObject(objType: otUnknown, name: nm, hidden: hd)
    warnings.add(ctx & ": unsupported shape type '" & ty & "' name='" & nm & "'")
    return o

proc getMaskMethod(mode: string; inversed: bool): MaskMethod =
  if mode.len == 0: return MaskMethod.None
  case mode[0]
  of 'a':
    if inversed: MaskMethod.InvAlpha else: MaskMethod.Add
  of 's':
    if inversed: MaskMethod.Intersect else: MaskMethod.Subtract
  of 'i':
    if inversed: MaskMethod.Difference else: MaskMethod.Intersect
  of 'f':
    if inversed: MaskMethod.Intersect else: MaskMethod.Difference
  of 'l': MaskMethod.Lighten
  of 'd': MaskMethod.Darken
  else: MaskMethod.None

proc parseMask(j: JsonNode): LottieMask =
  result = LottieMask(
    path: newPathProp(LottiePath()),
    opacity: newScalarProp(255'u8),
    expand: newScalarProp(0.0'f32),
    mode: MaskMethod.None,
    inverse: false
  )
  if j.kind != JObject: return
  var modeStr = ""
  for k, v in j:
    case k
    of "inv": result.inverse = asInt(v, 0) != 0 or (v.kind == JBool and v.getBool(false))
    of "mode": modeStr = v.getStr("")
    of "pt": result.path = parsePathProp(v)
    of "o": result.opacity = parseOpacityProp(v, 100.0'f32)
    of "x": result.expand = parseScalarProp(v, 0.0'f32)
    else: discard
  result.mode = getMaskMethod(modeStr, result.inverse)

proc parseEffectPropScalar(v: JsonNode; def: float32 = 0.0'f32): LottieGenericProperty[LottieScalarFrame[float32], float32] =
  if v.kind == JObject and v.hasKey("v"):
    parseScalarProp(v["v"], def)
  else:
    parseScalarProp(v, def)

proc parseEffectPropColor(v: JsonNode): LottieGenericProperty[LottieScalarFrame[LottieColor], LottieColor] =
  if v.kind == JObject and v.hasKey("v"):
    parseColorProp(v["v"])
  else:
    parseColorProp(v)

proc parseEffectPropOpacity(v: JsonNode; defPct: float32 = 100.0'f32): LottieGenericProperty[LottieScalarFrame[float32], float32] =
  # effect opacity is usually 0..1 or 0..255 depending on effect; keep as scalar
  parseEffectPropScalar(v, defPct)

proc parseIntScalarProp(v: JsonNode; def: int = 0): LottieGenericProperty[LottieScalarFrame[int], int] =
  let fp = parseEffectPropScalar(v, float32(def))
  result = LottieGenericProperty[LottieScalarFrame[int], int](value: int(fp.value), hasFrames: fp.hasFrames)
  for f in fp.frames:
    result.frames.add(LottieScalarFrame[int](no: f.no, value: int(f.value), hold: f.hold))

proc parseEffects(j: JsonNode): seq[LottieEffect] =
  result = @[]
  if j.kind != JArray: return
  for ej in j:
    if ej.kind != JObject: continue
    let ty = asInt(ej.getNode("ty"), -1)
    let en = if ej.hasKey("en"): asInt(ej["en"], 1) != 0 else: true
    let props = if ej.hasKey("ef") and ej["ef"].kind == JArray: ej["ef"] else: newJArray()
    case ty
    of 20: # Tint
      let fx = LottieFxTint(effectType: etTint, enable: en,
        black: newColorProp(LottieColor(r:0,g:0,b:0)),
        white: newColorProp(LottieColor(r:1,g:1,b:1)),
        intensity: newScalarProp(100.0'f32))
      for i in 0 ..< props.len:
        let p = props[i]
        case i
        of 0: fx.black = parseEffectPropColor(p)
        of 1: fx.white = parseEffectPropColor(p)
        of 2: fx.intensity = parseEffectPropScalar(p, 100.0'f32)
        else: discard
      result.add(fx)
    of 21: # Fill
      let fx = LottieFxFill(effectType: etFill, enable: en,
        color: newColorProp(LottieColor(r:0,g:0,b:0)),
        opacity: newScalarProp(1.0'f32))
      for i in 0 ..< props.len:
        let p = props[i]
        case i
        of 2: fx.color = parseEffectPropColor(p)
        of 6: fx.opacity = parseEffectPropScalar(p, 1.0'f32)
        else: discard
      result.add(fx)
    of 23: # Tritone
      let fx = LottieFxTritone(effectType: etTritone, enable: en,
        bright: newColorProp(LottieColor(r:1,g:1,b:1)),
        midtone: newColorProp(LottieColor(r:0.5,g:0.5,b:0.5)),
        dark: newColorProp(LottieColor(r:0,g:0,b:0)),
        blend: newScalarProp(uint8(0)))
      for i in 0 ..< props.len:
        let p = props[i]
        let pv = if p.kind == JObject and p.hasKey("v"): p["v"] else: p
        case i
        of 0: fx.bright = parseEffectPropColor(p)
        of 1: fx.midtone = parseEffectPropColor(p)
        of 2: fx.dark = parseEffectPropColor(p)
        of 3: fx.blend = parseOpacityProp(pv, 0.0'f32)
        else: discard
      result.add(fx)
    of 25: # DropShadow
      let fx = LottieFxDropShadow(effectType: etDropShadow, enable: en,
        color: newColorProp(LottieColor(r:0,g:0,b:0)),
        opacity: newScalarProp(0.0'f32),
        angle: newScalarProp(0.0'f32),
        distance: newScalarProp(0.0'f32),
        blurness: newScalarProp(0.0'f32))
      for i in 0 ..< props.len:
        let p = props[i]
        case i
        of 0: fx.color = parseEffectPropColor(p)
        of 1: fx.opacity = parseEffectPropScalar(p, 0.0'f32)
        of 2: fx.angle = parseEffectPropScalar(p, 0.0'f32)
        of 3: fx.distance = parseEffectPropScalar(p, 0.0'f32)
        of 4: fx.blurness = parseEffectPropScalar(p, 0.0'f32)
        else: discard
      result.add(fx)
    of 22: # Stroke
      let fx = LottieFxStroke(effectType: etStroke, enable: en,
        mask: newScalarProp(0), allMask: newScalarProp(0),
        color: newColorProp(LottieColor(r:1,g:1,b:1)),
        size: newScalarProp(0.0'f32),
        opacity: newScalarProp(1.0'f32),
        begin: newScalarProp(0.0'f32),
        `end`: newScalarProp(100.0'f32))
      var usedMn = false
      for i in 0 ..< props.len:
        let p = props[i]
        let mn = if p.kind == JObject and p.hasKey("mn"): p["mn"].getStr("") else: ""
        if mn.len > 0:
          usedMn = true
          if mn.endsWith("-0008"): fx.mask = parseIntScalarProp(p, 0)
          elif mn.endsWith("-0009"): fx.allMask = parseIntScalarProp(p, 0)
          elif mn.endsWith("-0001"): fx.color = parseEffectPropColor(p)
          elif mn.endsWith("-0002"): fx.size = parseEffectPropScalar(p, 0.0'f32)
          elif mn.endsWith("-0004"): fx.opacity = parseEffectPropScalar(p, 1.0'f32)
          elif mn.endsWith("-0005"): fx.begin = parseEffectPropScalar(p, 0.0'f32)
          elif mn.endsWith("-0006"): fx.`end` = parseEffectPropScalar(p, 100.0'f32)
          elif mn.endsWith("-0010"): discard # sequential
          elif mn.endsWith("-0003"): discard # hardness
        elif not usedMn:
          case i
          of 0: fx.mask = parseIntScalarProp(p, 0)
          of 1: fx.allMask = parseIntScalarProp(p, 0)
          of 3: fx.color = parseEffectPropColor(p)
          of 4: fx.size = parseEffectPropScalar(p, 0.0'f32)
          of 6: fx.opacity = parseEffectPropScalar(p, 1.0'f32)
          of 7: fx.begin = parseEffectPropScalar(p, 0.0'f32)
          of 8: fx.`end` = parseEffectPropScalar(p, 100.0'f32)
          else: discard
      result.add(fx)
    of 29: # GaussianBlur
      let fx = LottieFxGaussianBlur(effectType: etGaussianBlur, enable: en,
        blurness: newScalarProp(0.0'f32), direction: 0, wrap: 0)
      for i in 0 ..< props.len:
        let p = props[i]
        case i
        of 0: fx.blurness = parseEffectPropScalar(p, 0.0'f32)
        of 1:
          let v = if p.kind == JObject and p.hasKey("v"): p["v"] else: p
          fx.direction = if v.kind == JObject and v.hasKey("k"): asInt(v["k"], 0) else: asInt(v, 0)
        of 2:
          let v = if p.kind == JObject and p.hasKey("v"): p["v"] else: p
          fx.wrap = if v.kind == JObject and v.hasKey("k"): asInt(v["k"], 0) else: asInt(v, 0)
        else: discard
      result.add(fx)
    else:
      discard

proc parseLayer(j: JsonNode; warnings: var seq[string]; idx: int): LottieLayer =
  let lname = (if j.kind == JObject and j.hasKey("nm"): j["nm"].getStr("") else: "")
  let ctx = "layers[" & $idx & "]('" & lname & "')"
  result = LottieLayer(
    objType: otLayer,
    name: lname,
    id: 0'u32,
    layerType: ltShape,
    hidden: false,
    matteType: MaskMethod.None,
    matteTarget: nil,
    matteSrc: false,
    mix: -1,
    blendMode: BlendMethod.Normal,
    inPoint: 0.0'f32, outPoint: 0.0'f32, startTime: 0.0'f32, startFrame: 0.0'f32,
    timeStretch: 1.0'f32,
    timeRemap: newScalarProp(-1.0'f32),
    parentId: -1,
    children: @[],
    masks: @[]
  )
  if j.kind != JObject: return
  if j.hasKey("ind"): result.id = uint32(asInt(j["ind"], 0))
  if j.hasKey("ty"): result.layerType = LottieLayerType(clamp(asInt(j["ty"], 4), 0, 6))
  if j.hasKey("parent"): result.parentId = asInt(j["parent"], -1)
  if result.layerType == ltAudio:
    warnings.add(ctx & ": audio layer not supported")
  if j.hasKey("hd"): result.hidden = asInt(j["hd"], 0) != 0
  if j.hasKey("tt"):
    let tt = clamp(asInt(j["tt"], 0), 0, 4)
    result.matteType = MaskMethod(tt)
  if j.hasKey("tp"): result.mix = asInt(j["tp"], -1)
  if j.hasKey("td"): result.matteSrc = asInt(j["td"], 0) != 0
  if j.hasKey("bm"):
    let bm = asInt(j["bm"], 0)
    if bm >= 0 and bm <= 16:
      result.blendMode = BlendMethod(bm)
  if j.hasKey("ip"): result.inPoint = asFloat(j["ip"])
  if j.hasKey("op"): result.outPoint = asFloat(j["op"])
  if j.hasKey("st"):
    result.startTime = asFloat(j["st"])
    result.startFrame = result.startTime
  if j.hasKey("sr"): result.timeStretch = asFloat(j["sr"], 1.0'f32)
  if j.hasKey("tm"):
    result.timeRemap = parseScalarProp(j["tm"], -1.0'f32)
  if j.hasKey("refId"): result.refId = j["refId"].getStr("")
  if j.hasKey("sw"): result.w = asFloat(j["sw"])
  if j.hasKey("sh"): result.h = asFloat(j["sh"])
  if j.hasKey("w"): result.w = asFloat(j["w"])
  if j.hasKey("h"): result.h = asFloat(j["h"])
  if j.hasKey("ao"): result.autoOrient = asInt(j["ao"], 0) != 0
  if j.hasKey("sc"):
    let sc = j["sc"].getStr("#000000")
    if sc.len == 7 and sc[0] == '#':
      try:
        let r = uint8(parseHexInt(sc[1..2]))
        let g = uint8(parseHexInt(sc[3..4]))
        let b = uint8(parseHexInt(sc[5..6]))
        result.solidColor = RGBA(r:r, g:g, b:b, a:255)
      except: discard
  if j.hasKey("ks"):
    result.transform = parseTransform(j["ks"], warnings, lname)
  else:
    result.transform = newLottieTransform()
  if j.hasKey("shapes") and j["shapes"].kind == JArray:
    result.children = parseShapes(j["shapes"], warnings, ctx & ".shapes")
  if j.hasKey("masksProperties") and j["masksProperties"].kind == JArray:
    for mj in j["masksProperties"]:
      if mj.kind == JObject:
        let m = parseMask(mj)
        if m.mode != MaskMethod.None:
          result.masks.add(m)
  if j.hasKey("ef") and j["ef"].kind == JArray:
    result.effects = parseEffects(j["ef"])

proc applySlots(comp: LottieComposition) =
  if comp.slots.len == 0 or comp.slotBindings.len == 0: return
  for s in comp.slots:
    for b in comp.slotBindings:
      if b.sid == s.sid and b.apply != nil:
        b.apply(s.p)

proc parseComposition*(j: JsonNode): LottieComposition =
  gSlotBindings.setLen(0)
  result = LottieComposition(
    version: (if j.kind == JObject and j.hasKey("v"): j["v"].getStr("") else: ""),
    name: (if j.kind == JObject and j.hasKey("nm"): j["nm"].getStr("") else: ""),
    w: asFloat(j.getNode("w")), h: asFloat(j.getNode("h")),
    inPoint: asFloat(j.getNode("ip")), outPoint: asFloat(j.getNode("op")),
    frameRate: asFloat(j.getNode("fr"), 60.0'f32),
    layers: @[],
    assets: @[],
    warnings: @[],
    slots: @[],
    slotBindings: @[]
  )
  var warnings: seq[string] = @[]
  if j.kind == JObject and j.hasKey("assets") and j["assets"].kind == JArray:
    for aj in j["assets"]:
      if aj.kind != JObject: continue
      let a = LottieAsset(objType: otComposition, id: (if aj.hasKey("id"): aj["id"].getStr("") else: ""))
      a.w = asFloat(aj.getNode("w"))
      a.h = asFloat(aj.getNode("h"))
      if aj.hasKey("u"): a.u = aj["u"].getStr("")
      if aj.hasKey("p"): a.p = aj["p"].getStr("")
      a.embedded = (aj.hasKey("e") and aj["e"].asInt(0) == 1) or (a.p.len >= 5 and a.p[0..4] == "data:")
      if aj.hasKey("layers") and aj["layers"].kind == JArray:
        var li = 0
        for lj in aj["layers"]:
          a.layers.add(parseLayer(lj, warnings, li))
          inc li
      result.assets.add(a)
  if j.kind == JObject and j.hasKey("layers") and j["layers"].kind == JArray:
    var li = 0
    for lj in j["layers"]:
      result.layers.add(parseLayer(lj, warnings, li))
      inc li
  # parse slots
  if j.kind == JObject and j.hasKey("slots") and j["slots"].kind == JObject:
    for k, v in j["slots"]:
      if v.kind == JObject and v.hasKey("p"):
        let slot = LottieSlot(sid: djb2Encode(k), p: v["p"])
        result.slots.add(slot)
  result.warnings = warnings
  result.slotBindings = gSlotBindings
  gSlotBindings = @[]
  applySlots(result)

proc parseLottieFile*(content: string): LottieComposition =
  let j = jsony.fromJson(content)
  parseComposition(j)

proc parseLottieFileFromPath*(path: string): LottieComposition =
  let content = readFile(path)
  result = parseLottieFile(content)
  result.resourceDir = parentDir(path)
