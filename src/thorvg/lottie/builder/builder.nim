## Lottie builder (Phase 2 MVP): lower Lottie model to ThorVG scene.
## No expressions, no masks/mattes/precomps/repeaters/trimpath/gradients yet.

import std/[math, os]
import ../../core/[types, geom, fill, path, bezier]
import ../../renderer/[paint, shape, scene, picture]
import ../model/[common, model, property]
import ../animation/interpolator

type
  LottieBuildCtx* = object
    transform*: Matrix
    opacity*: uint8
    fillColor*: RGBA
    hasFill*: bool
    fillGrad*: Fill
    hasFillGrad*: bool
    fillRule*: FillRule
    strokeColor*: RGBA
    hasStroke*: bool
    strokeGrad*: Fill
    hasStrokeGrad*: bool
    strokeWidth*: float32
    strokeCap*: StrokeCap
    strokeJoin*: StrokeJoin
    strokeMiter*: float32
    strokeDashes*: seq[float32]
    strokeDashOffset*: float32
    hasStrokeDash*: bool
    trimStart*: float32
    trimEnd*: float32
    trimOffset*: float32
    trimSimultaneous*: bool
    trimComposed*: bool
    hasTrim*: bool
    roundCorner*: float32
    zigzagAmp*: float32
    zigzagFreq*: float32
    zigzagPoint*: int
    hasZigzag*: bool
    puckerBloat*: float32
    offsetPathVal*: float32
    offsetPathMiter*: float32
    offsetPathJoin*: StrokeJoin
    hasOffsetPath*: bool
    strokeFirst*: bool

  LottieBuilder* = ref object
    comp*: LottieComposition
    root*: Scene

proc identityCtx(): LottieBuildCtx =
  LottieBuildCtx(
    transform: identity(),
    opacity: 255'u8,
    fillColor: RGBA(r:0,g:0,b:0,a:0),
    hasFill: false,
    hasFillGrad: false,
    fillRule: FillRule.NonZero,
    strokeColor: RGBA(r:0,g:0,b:0,a:0),
    hasStroke: false,
    hasStrokeGrad: false,
    strokeWidth: 0.0'f32,
    strokeCap: StrokeCap.Round,
    strokeJoin: StrokeJoin.Round,
    strokeMiter: 4.0'f32,
    strokeDashes: @[],
    strokeDashOffset: 0.0'f32,
    hasStrokeDash: false,
    trimStart: 0.0'f32,
    trimEnd: 100.0'f32,
    trimOffset: 0.0'f32,
    trimSimultaneous: true,
    hasTrim: false,
  )

proc newLottieBuilder*(comp: LottieComposition): LottieBuilder =
  result = LottieBuilder(comp: comp, root: newScene())

proc rootScene*(b: LottieBuilder): Scene = b.root

proc toRgba(c: LottieColor; opacity: uint8): RGBA =
  let a = uint8(clamp(int(float32(opacity) * 1.0'f32), 0, 255))
  # c.r/g/b are 0..1. Keep round-half-up for solid fill/stroke to avoid regressions;
  # C++ RGB32 lerps in int space so 1-unit diffs can remain on interpolated colors.
  RGBA(r: uint8(clamp(int(c.r * 255.0'f32 + 0.5'f32), 0, 255)),
       g: uint8(clamp(int(c.g * 255.0'f32 + 0.5'f32), 0, 255)),
       b: uint8(clamp(int(c.b * 255.0'f32 + 0.5'f32), 0, 255)),
       a: a)

proc skewR(m: var Matrix; angleDeg, axisDegIn: float32) =
  let angle = -degToRad(angleDeg)
  let tanVal = tan(angle)
  var axisDeg = axisDegIn mod 180.0'f32
  if abs(axisDeg) < 0.01'f32 or abs(axisDeg - 180.0'f32) < 0.01'f32 or abs(axisDeg + 180.0'f32) < 0.01'f32:
    let cosVal = cos(degToRad(axisDeg))
    let b = cosVal * cosVal * tanVal
    m.e12 += b * m.e11
    m.e22 += b * m.e21
    return
  elif abs(axisDeg - 90.0'f32) < 0.01'f32 or abs(axisDeg + 90.0'f32) < 0.01'f32:
    let sinVal = -sin(degToRad(axisDeg))
    let c = sinVal * sinVal * tanVal
    m.e11 -= c * m.e12
    m.e21 -= c * m.e22
    return
  let axis = -degToRad(axisDeg)
  let cosVal = cos(axis)
  let sinVal = sin(axis)
  let a = sinVal * cosVal * tanVal
  let b = cosVal * cosVal * tanVal
  let c = sinVal * sinVal * tanVal
  let e11 = m.e11
  let e21 = m.e21
  m.e11 = (1.0'f32 - a) * e11 - c * m.e12
  m.e12 = b * e11 + (1.0'f32 + a) * m.e12
  m.e21 = (1.0'f32 - a) * e21 - c * m.e22
  m.e22 = b * e21 + (1.0'f32 + a) * m.e22

proc applyTransform(m: var Matrix; t: LottieTransform; frameNo: float32; autoOrient = false) =
  if t == nil: return
  let pos = evalPosition(t, frameNo)
  let anchor = t.anchor.eval(frameNo)
  let sc = evalScale(t, frameNo)
  var rot = evalRotation(t, frameNo)
  if autoOrient and not t.separate:
    rot += t.position.angle(frameNo)
  # Lottie: translate(pos) * rotate(autoOrient+rot) * skew * scale(scale/100) * translate(-anchor)
  var mt = identity()
  translate(mt, pt(pos.x, pos.y))
  if t.has3D:
    let rxv = degToRad(t.rx.eval(frameNo))
    let ryv = degToRad(t.ry.eval(frameNo))
    let rzv = degToRad(rot) # rotation already holds rz when 3D
    let sinx = sin(rxv); let siny = sin(ryv); let sinz = sin(rzv)
    let cosx = cos(rxv); let cosy = cos(ryv); let cosz = cos(rzv)
    let ri00 = cosy * cosz
    let ri01 = -cosy * sinz
    let ri10 = sinx * siny * cosz + cosx * sinz
    let ri11 = -sinx * siny * sinz + cosx * cosz
    let o = t.orient.eval(frameNo)
    let ozVal = t.orientZ.eval(frameNo)
    if o.x == 0.0'f32 and o.y == 0.0'f32 and ozVal == 0.0'f32:
      mt.e11 = ri00; mt.e12 = ri01; mt.e21 = ri10; mt.e22 = ri11
    else:
      let ri02 = siny
      let ri12 = -sinx * cosy
      let ox = degToRad(o.x); let oy = degToRad(o.y); let oz = degToRad(ozVal)
      let sox = sin(ox); let soy = sin(oy); let soz = sin(oz)
      let cox = cos(ox); let coy = cos(oy); let coz = cos(oz)
      let ro00 = coy * coz
      let ro01 = -coy * soz
      let ro10 = sox * soy * coz + cox * soz
      let ro11 = -sox * soy * soz + cox * coz
      let ro20 = -cox * soy * coz + sox * soz
      let ro21 = cox * soy * soz + sox * coz
      mt.e11 = ri00 * ro00 + ri01 * ro10 + ri02 * ro20
      mt.e12 = ri00 * ro01 + ri01 * ro11 + ri02 * ro21
      mt.e21 = ri10 * ro00 + ri11 * ro10 + ri12 * ro20
      mt.e22 = ri10 * ro01 + ri11 * ro11 + ri12 * ro21
  elif rot != 0.0'f32:
    rotate(mt, rot)
  let skewAngle = t.skewAngle.eval(frameNo)
  if skewAngle != 0.0'f32:
    var sa = skewAngle mod 180.0'f32
    if abs(sa - 90.0'f32) < 0.01'f32 or abs(sa + 90.0'f32) < 0.01'f32:
      mt = identity()
      scaleR(mt, pt(0.0'f32, 0.0'f32))
      m = m * mt
      return
    skewR(mt, sa, t.skewAxis.eval(frameNo))
  let sx = sc.x / 100.0'f32
  let sy = sc.y / 100.0'f32
  scaleR(mt, pt(sx, sy))
  translateR(mt, pt(-anchor.x, -anchor.y))
  m = m * mt

proc layerOpacity(t: LottieTransform; frameNo: float32): uint8 =
  if t == nil: return 255'u8
  evalOpacity(t, frameNo)

proc buildPath(s: Shape; p: LottiePath) =
  let n = p.pts.len
  if n == 0: return
  discard s.moveTo(p.pts[0].x, p.pts[0].y)
  for i in 0 ..< n:
    let j = (i + 1) mod n
    if i + 1 >= n and not p.closed: break
    let p0 = p.pts[i]
    let p1 = p.pts[j]
    let c1 = p0 + (if i < p.outTangents.len: p.outTangents[i] else: lp(0,0))
    let c2 = p1 + (if j < p.inTangents.len: p.inTangents[j] else: lp(0,0))
    # C++ PathSet always emits cubicTo, even for straight segments (zero tangents).
    discard s.cubicTo(c1.x, c1.y, c2.x, c2.y, p1.x, p1.y)
  if p.closed:
    discard s.close()

proc lottiePathToRenderPath(p: LottiePath): RenderPath =
  result = RenderPath(cmds: @[], pts: @[])
  let n = p.pts.len
  if n == 0: return
  result.moveTo(pt(p.pts[0].x, p.pts[0].y))
  for i in 0 ..< n:
    let j = (i + 1) mod n
    if i + 1 >= n and not p.closed: break
    let p0 = p.pts[i]
    let p1 = p.pts[j]
    let c1 = p0 + (if i < p.outTangents.len: p.outTangents[i] else: lp(0,0))
    let c2 = p1 + (if j < p.inTangents.len: p.inTangents[j] else: lp(0,0))
    # C++ PathSet always emits cubicTo, even for straight segments.
    result.cubicTo(pt(c1.x, c1.y), pt(c2.x, c2.y), pt(p1.x, p1.y))
  if p.closed:
    result.close()

proc applyRenderPathToShape(s: Shape; rp: RenderPath) =
  var iPt = 0
  for cmd in rp.cmds:
    case cmd
    of PathCommand.MoveTo:
      if iPt < rp.pts.len: discard s.moveTo(rp.pts[iPt].x, rp.pts[iPt].y); inc iPt
    of PathCommand.LineTo:
      if iPt < rp.pts.len: discard s.lineTo(rp.pts[iPt].x, rp.pts[iPt].y); inc iPt
    of PathCommand.CubicTo:
      if iPt + 2 < rp.pts.len:
        discard s.cubicTo(rp.pts[iPt].x, rp.pts[iPt].y, rp.pts[iPt+1].x, rp.pts[iPt+1].y, rp.pts[iPt+2].x, rp.pts[iPt+2].y)
        iPt += 3
    of PathCommand.Close:
      discard s.close()

proc buildPolystar(s: Shape; pos: LottiePoint; outerR, innerR, outerRound, innerRound, rotDeg, ptsF: float32; starType: int) =
  ## C++-faithful polystar/polygon. Fractional points and roundness supported.
  ## C++ applies transform (pos+rot) as matrix; here we apply pos/rot inline (no scale/skew).
  const POLYSTAR_MAGIC = 0.47829'f32 / 0.28'f32
  const POLYGON_MAGIC = 0.25'f32
  let isStar = starType == 1
  let direction = 1.0'f32 # clockwise default; Nim model lacks clockwise field
  let baseAngle = deg2rad(rotDeg - 90.0'f32)

  if not isStar:
    # Polygon: C++ uses int(floor(ptsCnt))
    let ptsCnt = int(floor(ptsF))
    if ptsCnt < 1: return
    let outerRoundness = outerRound * 0.01'f32
    let anglePerPoint = 2.0'f32 * PI / float32(ptsCnt)
    let hasRoundness = abs(outerRoundness) > 0.00001'f32
    var angle = baseAngle
    var x = outerR * cos(angle)
    var y = outerR * sin(angle)
    angle += anglePerPoint * direction
    let startPt = Point(x: pos.x + x, y: pos.y + y)
    discard s.moveTo(startPt.x, startPt.y)
    let coeff = anglePerPoint * outerR * outerRoundness * POLYGON_MAGIC
    for i in 0 ..< ptsCnt:
      let prevX = x; let prevY = y
      x = outerR * cos(angle)
      y = outerR * sin(angle)
      if hasRoundness:
        let cp1Theta = arctan2(prevY, prevX) - PI * 0.5'f32 * direction
        let cp1x = coeff * cos(cp1Theta)
        let cp1y = coeff * sin(cp1Theta)
        let cp2Theta = arctan2(y, x) - PI * 0.5'f32 * direction
        let cp2x = coeff * cos(cp2Theta)
        let cp2y = coeff * sin(cp2Theta)
        discard s.cubicTo(pos.x + prevX - cp1x, pos.y + prevY - cp1y,
                          pos.x + x + cp2x, pos.y + y + cp2y,
                          pos.x + x, pos.y + y)
      else:
        discard s.cubicTo(pos.x + prevX, pos.y + prevY, pos.x + x, pos.y + y, pos.x + x, pos.y + y)
      angle += anglePerPoint * direction
    # C++ _close: ensure last point == start (float precision)
    if s.rs.path.pts.len >= 1:
      let li = s.rs.path.pts.len - 1
      if s.rs.path.pts.len >= 2 and zero(s.rs.path.pts[li] - s.rs.path.pts[li-1]):
        s.rs.path.pts[li-1] = startPt
      s.rs.path.pts[li] = startPt
    discard s.close()
  else:
    # Star
    let ptsCntF = ptsF
    if ptsCntF < 1.0'f32: return
    let innerRoundness = innerRound * 0.01'f32
    let outerRoundness = outerRound * 0.01'f32
    var angle = baseAngle
    let anglePerPoint = 2.0'f32 * PI / ptsCntF
    let halfAnglePerPoint = anglePerPoint * 0.5'f32
    let partialPointAmount = ptsCntF - floor(ptsCntF)
    var longSegment = false
    let numPoints = int(ceil(ptsCntF)) * 2
    let hasRoundness = abs(innerRoundness) > 0.00001'f32 or abs(outerRoundness) > 0.00001'f32
    var partialPointRadius = 0.0'f32
    var x, y: float32
    if abs(partialPointAmount) > 0.00001'f32:
      angle += halfAnglePerPoint * (1.0'f32 - partialPointAmount) * direction
    if abs(partialPointAmount) > 0.00001'f32:
      partialPointRadius = innerR + partialPointAmount * (outerR - innerR)
      x = partialPointRadius * cos(angle)
      y = partialPointRadius * sin(angle)
      angle += anglePerPoint * partialPointAmount * 0.5'f32 * direction
    else:
      x = outerR * cos(angle)
      y = outerR * sin(angle)
      angle += halfAnglePerPoint * direction
    let startPt = Point(x: pos.x + x, y: pos.y + y)
    discard s.moveTo(startPt.x, startPt.y)
    for i in 0 ..< numPoints:
      var radius = if longSegment: outerR else: innerR
      var dTheta = halfAnglePerPoint
      if abs(partialPointRadius) > 0.00001'f32 and i == numPoints - 2:
        dTheta = anglePerPoint * partialPointAmount * 0.5'f32
      if abs(partialPointRadius) > 0.00001'f32 and i == numPoints - 1:
        radius = partialPointRadius
      let prevX = x; let prevY = y
      x = radius * cos(angle)
      y = radius * sin(angle)
      if hasRoundness:
        let cp1Theta = arctan2(prevY, prevX) - PI * 0.5'f32 * direction
        let cp1Dx = cos(cp1Theta); let cp1Dy = sin(cp1Theta)
        let cp2Theta = arctan2(y, x) - PI * 0.5'f32 * direction
        let cp2Dx = cos(cp2Theta); let cp2Dy = sin(cp2Theta)
        let cp1Roundness = if longSegment: innerRoundness else: outerRoundness
        let cp2Roundness = if longSegment: outerRoundness else: innerRoundness
        let cp1Radius = if longSegment: innerR else: outerR
        let cp2Radius = if longSegment: outerR else: innerR
        var cp1x = cp1Radius * cp1Roundness * POLYSTAR_MAGIC * cp1Dx / ptsCntF
        var cp1y = cp1Radius * cp1Roundness * POLYSTAR_MAGIC * cp1Dy / ptsCntF
        var cp2x = cp2Radius * cp2Roundness * POLYSTAR_MAGIC * cp2Dx / ptsCntF
        var cp2y = cp2Radius * cp2Roundness * POLYSTAR_MAGIC * cp2Dy / ptsCntF
        if abs(partialPointAmount) > 0.00001'f32 and (i == 0 or i == numPoints - 1):
          cp1x *= partialPointAmount; cp1y *= partialPointAmount
          cp2x *= partialPointAmount; cp2y *= partialPointAmount
        discard s.cubicTo(pos.x + prevX - cp1x, pos.y + prevY - cp1y,
                          pos.x + x + cp2x, pos.y + y + cp2y,
                          pos.x + x, pos.y + y)
      else:
        discard s.cubicTo(pos.x + prevX, pos.y + prevY, pos.x + x, pos.y + y, pos.x + x, pos.y + y)
      angle += dTheta * direction
      longSegment = not longSegment
    # C++ _close: ensure last point == start (float precision)
    if s.rs.path.pts.len >= 1:
      let li = s.rs.path.pts.len - 1
      if s.rs.path.pts.len >= 2 and zero(s.rs.path.pts[li] - s.rs.path.pts[li-1]):
        s.rs.path.pts[li-1] = startPt
      s.rs.path.pts[li] = startPt
    discard s.close()

proc lerpU8(a, b: uint8; t: float32): uint8 {.inline.} =
  uint8(clamp(int(float32(a) + (float32(b) - float32(a)) * t), 0, 255))

proc lerpStop(a, b: ColorStop; t: float32): ColorStop {.inline.} =
  ColorStop(offset: a.offset + (b.offset - a.offset) * t,
            r: lerpU8(a.r,b.r,t), g: lerpU8(a.g,b.g,t), b: lerpU8(a.b,b.b,t), a: lerpU8(a.a,b.a,t))

proc populateColorStops(input: seq[float32]; colorCount: int): seq[ColorStop] =
  ## C++ 1.2.0 LottieGradient::populate: merge color stops (4 floats) and alpha stops (2 floats).
  result = @[]
  if input.len == 0 or colorCount <= 0: return
  let clast = colorCount * 4
  if input.len < clast: return
  let inputLast = clast + ((input.len - clast) div 2) * 2 # ignore incomplete trailing alpha
  var cidx = 0
  var aidx = clast
  var cs: ColorStop
  while cidx < clast and aidx < inputLast:
    if input[cidx] == input[aidx]:
      cs.offset = input[cidx]
      cs.r = remap255(input[cidx+1]); cs.g = remap255(input[cidx+2]); cs.b = remap255(input[cidx+3])
      cs.a = remap255(input[aidx+1])
      cidx += 4; aidx += 2
    elif input[cidx] < input[aidx]:
      cs.offset = input[cidx]
      cs.r = remap255(input[cidx+1]); cs.g = remap255(input[cidx+2]); cs.b = remap255(input[cidx+3])
      if result.len > 0:
        let p = (input[cidx] - result[^1].offset) / (input[aidx] - result[^1].offset)
        cs.a = lerpU8(result[^1].a, remap255(input[aidx+1]), p)
      else:
        cs.a = remap255(input[aidx+1])
      cidx += 4
    else:
      cs.offset = input[aidx]
      cs.a = remap255(input[aidx+1])
      if result.len > 0:
        let p = (input[aidx] - result[^1].offset) / (input[cidx] - result[^1].offset)
        cs.r = lerpU8(result[^1].r, remap255(input[cidx+1]), p)
        cs.g = lerpU8(result[^1].g, remap255(input[cidx+2]), p)
        cs.b = lerpU8(result[^1].b, remap255(input[cidx+3]), p)
      else:
        cs.r = remap255(input[cidx+1]); cs.g = remap255(input[cidx+2]); cs.b = remap255(input[cidx+3])
      aidx += 2
    result.add(cs)
  while cidx + 3 < clast:
    cs.offset = input[cidx]
    cs.r = remap255(input[cidx+1]); cs.g = remap255(input[cidx+2]); cs.b = remap255(input[cidx+3])
    cs.a = if result.len > 0: result[^1].a else: 255'u8
    result.add(cs); cidx += 4
  while aidx + 1 < inputLast:
    cs.offset = input[aidx]
    cs.a = remap255(input[aidx+1])
    if result.len > 0:
      cs.r = result[^1].r; cs.g = result[^1].g; cs.b = result[^1].b
    else:
      cs.r = 255; cs.g = 255; cs.b = 255
    result.add(cs); aidx += 2

proc evalColorStops(cs: LottieColorStops; frameNo: float32): seq[ColorStop] =
  ## Evaluate animated/static color stops, populate-merge, return Fill::ColorStop-like seq.
  if cs == nil: return @[]
  if cs.frames.len == 0:
    if not cs.populated:
      cs.populatedData = populateColorStops(cs.value, cs.colorCount)
      cs.populatedCount = cs.populatedData.len
      cs.populated = true
    return cs.populatedData
  # animated: populate frames on demand
  if not cs.populated:
    cs.populatedFrames.setLen(cs.frames.len)
    var minCount = int.high
    for i, f in cs.frames:
      cs.populatedFrames[i] = populateColorStops(f.input, cs.colorCount)
      minCount = min(minCount, cs.populatedFrames[i].len)
    cs.populatedCount = if minCount == int.high: 0 else: minCount
    cs.populated = true
  if cs.populatedCount <= 0: return @[]
  let first = cs.frames[0].no
  let last = cs.frames[^1].no
  if cs.frames.len == 1 or frameNo <= first:
    return cs.populatedFrames[0][0 ..< min(cs.populatedCount, cs.populatedFrames[0].len)]
  if frameNo >= last:
    let li = cs.populatedFrames.len - 1
    return cs.populatedFrames[li][0 ..< min(cs.populatedCount, cs.populatedFrames[li].len)]
  # find keyframe
  var key = 0
  for i in 0 ..< cs.frames.len - 1:
    if frameNo < cs.frames[i+1].no: key = i; break
    key = i
  let f = cs.frames[key]
  let n = cs.frames[key+1]
  var t = (frameNo - f.no) / (n.no - f.no)
  if f.interpolator != nil: t = f.interpolator.progress(t)
  if f.hold:
    if t < 1.0'f32: return cs.populatedFrames[key][0 ..< min(cs.populatedCount, cs.populatedFrames[key].len)]
    return cs.populatedFrames[key+1][0 ..< min(cs.populatedCount, cs.populatedFrames[key+1].len)]
  let s = cs.populatedFrames[key]
  let e = cs.populatedFrames[key+1]
  result = newSeq[ColorStop](cs.populatedCount)
  for i in 0 ..< cs.populatedCount:
    result[i] = lerpStop(s[i], e[i], t)

proc toColorStops(stops: LottieColorStops; opacity: uint8; frameNo: float32): seq[ColorStop] =
  ## opacity is 0-100 (Lottie). TODO: C++ uses 0-1->0-255; Nim engine gradient stroke
  ## rendering is wrong when using full alpha, so keep 0-100 scaling for now.
  result = evalColorStops(stops, frameNo)
  for i in 0 ..< result.len:
    let oa = clamp(float32(result[i].a) / 255.0'f32, 0.0'f32, 1.0'f32)
    result[i].a = uint8(clamp(int(float32(opacity) * oa + 0.5'f32), 0, 255))

proc makeGradient(gf: LottieGradientFillObj; frameNo: float32): Fill =
  let op = gf.opacity.eval(frameNo)
  let spt = gf.start.eval(frameNo)
  let ept = gf.`end`.eval(frameNo)
  var f: Fill
  if gf.gradType == 2:
    let w = abs(ept.x - spt.x)
    let h = abs(ept.y - spt.y)
    let r = if w > h: w + 0.375'f32 * h else: h + 0.375'f32 * w
    let progress = gf.height.eval(frameNo) * 0.01'f32
    if abs(progress) < 0.00001'f32:
      f = radialGradient(spt.x, spt.y, r, spt.x, spt.y, 0.0'f32)
    else:
      let startAngle = radToDeg(arctan2(ept.y - spt.y, ept.x - spt.x))
      let ang = degToRad(startAngle + gf.angle.eval(frameNo))
      let fx = spt.x + cos(ang) * progress * r
      let fy = spt.y + sin(ang) * progress * r
      f = radialGradient(spt.x, spt.y, r, fx, fy, 0.0'f32)
  else:
    f = linearGradient(spt.x, spt.y, ept.x, ept.y)
  f.stops = toColorStops(gf.colorStops, op, frameNo)
  f

proc makeStrokeGradient(gs: LottieGradientStrokeObj; frameNo: float32): Fill =
  let op = gs.opacity.eval(frameNo)
  let spt = gs.start.eval(frameNo)
  let ept = gs.`end`.eval(frameNo)
  var f: Fill
  if gs.gradType == 2:
    let w = abs(ept.x - spt.x)
    let h = abs(ept.y - spt.y)
    let r = if w > h: w + 0.375'f32 * h else: h + 0.375'f32 * w
    let progress = gs.height.eval(frameNo) * 0.01'f32
    if abs(progress) < 0.00001'f32:
      f = radialGradient(spt.x, spt.y, r, spt.x, spt.y, 0.0'f32)
    else:
      let startAngle = radToDeg(arctan2(ept.y - spt.y, ept.x - spt.x))
      let ang = degToRad(startAngle + gs.angle.eval(frameNo))
      let fx = spt.x + cos(ang) * progress * r
      let fy = spt.y + sin(ang) * progress * r
      f = radialGradient(spt.x, spt.y, r, fx, fy, 0.0'f32)
  else:
    f = linearGradient(spt.x, spt.y, ept.x, ept.y)
  f.stops = toColorStops(gs.colorStops, op, frameNo)
  f

proc normTrim(v: float32): float32 =
  ## normalize trim value (percent+offset already applied) to 0..1 range with wrapping
  var x = v / 100.0'f32
  if x >= 0.0'f32 and x <= 1.0'f32: return x
  x = x - floor(x)
  if x < 0.0'f32: x += 1.0'f32
  if x == 0.0'f32: x = 1.0'f32
  x

proc trimSegment(startPct, endPct, offsetDeg: float32): tuple[begin, `end`: float32] =
  ## C++ LottieTrimpath::segment: returns 0..1+offset range (may exceed 1).
  var s = clamp(startPct * 0.01'f32, 0.0'f32, 1.0'f32)
  var e = clamp(endPct * 0.01'f32, 0.0'f32, 1.0'f32)
  let diff = abs(s - e)
  if diff <= 0.000001'f32:
    return (0.0'f32, 0.0'f32)
  var o = offsetDeg mod 360.0'f32
  if o < 0.0'f32: o += 360.0'f32
  o = o / 360.0'f32
  if abs(o) <= 0.000001'f32 and diff >= 1.0'f32:
    return (0.0'f32, 1.0'f32)
  if s > e: swap(s, e)
  (s + o, e + o)

proc applyStyle(s: Shape; ctx: LottieBuildCtx) =
  if ctx.hasFillGrad:
    discard s.fill(ctx.fillGrad)
    discard s.fillRule(ctx.fillRule)
  elif ctx.hasFill:
    discard s.fill(ctx.fillColor.r, ctx.fillColor.g, ctx.fillColor.b, ctx.fillColor.a)
    discard s.fillRule(ctx.fillRule)
  else:
    discard s.fill(0'u8, 0'u8, 0'u8, 0'u8)
  if ctx.hasStrokeGrad and ctx.strokeWidth > 0.0'f32:
    discard s.strokeWidth(ctx.strokeWidth)
    discard s.strokeFill(ctx.strokeGrad)
    discard s.strokeCap(ctx.strokeCap)
    discard s.strokeJoin(ctx.strokeJoin)
    discard s.strokeMiterlimit(ctx.strokeMiter)
    if ctx.hasStrokeDash:
      discard s.strokeDash(ctx.strokeDashes, ctx.strokeDashOffset)
  elif ctx.hasStroke and ctx.strokeWidth > 0.0'f32:
    discard s.strokeWidth(ctx.strokeWidth)
    discard s.strokeFill(ctx.strokeColor.r, ctx.strokeColor.g, ctx.strokeColor.b, ctx.strokeColor.a)
    discard s.strokeCap(ctx.strokeCap)
    discard s.strokeJoin(ctx.strokeJoin)
    discard s.strokeMiterlimit(ctx.strokeMiter)
    if ctx.hasStrokeDash:
      discard s.strokeDash(ctx.strokeDashes, ctx.strokeDashOffset)
  if ctx.strokeFirst and (ctx.hasStroke or ctx.hasStrokeGrad) and ctx.strokeWidth > 0.0'f32:
    discard s.order(true)
  if ctx.hasTrim:
    let seg = if ctx.trimComposed: (begin: ctx.trimStart, `end`: ctx.trimEnd)
              else: trimSegment(ctx.trimStart, ctx.trimEnd, ctx.trimOffset)
    # skip no-op trim
    if not (seg.begin == 0.0'f32 and seg.`end` == 1.0'f32):
      discard s.trimpath(seg.begin, seg.`end`, ctx.trimSimultaneous)
  if ctx.opacity < 255'u8:
    discard s.opacity(ctx.opacity)


proc drawStyledPath(parentScene: Scene; path: LottiePath; ctx: LottieBuildCtx) =
  let sh = newShape()
  buildPath(sh, path)
  applyStyle(sh, ctx)
  discard sh.transform(ctx.transform)
  discard parentScene.add(sh)

proc drawStyledRect(parentScene: Scene; pos, sz: LottiePoint; rr: float32; ctx: LottieBuildCtx) =
  let sh = newShape()
  let r = max(rr, ctx.roundCorner)
  let cr = min(abs(r), min(abs(sz.x), abs(sz.y)) * 0.5'f32)
  discard sh.appendRect(pos.x - sz.x/2.0'f32, pos.y - sz.y/2.0'f32, sz.x, sz.y, cr, cr)
  applyStyle(sh, ctx)
  discard sh.transform(ctx.transform)
  discard parentScene.add(sh)

proc drawStyledEllipse(parentScene: Scene; pos, sz: LottiePoint; ctx: LottieBuildCtx) =
  let sh = newShape()
  discard sh.appendCircle(pos.x, pos.y, sz.x/2.0'f32, sz.y/2.0'f32)
  applyStyle(sh, ctx)
  discard sh.transform(ctx.transform)
  discard parentScene.add(sh)

proc drawStyledPolystar(parentScene: Scene; pos: LottiePoint; outerR, innerR, outerRound, innerRound, rotDeg, ptsF: float32; starType: int; ctx: LottieBuildCtx) =
  let sh = newShape()
  buildPolystar(sh, pos, outerR, innerR, outerRound, innerRound, rotDeg, ptsF, starType)
  applyStyle(sh, ctx)
  discard sh.transform(ctx.transform)
  discard parentScene.add(sh)

proc buildObject(obj: LottieObject; frameNo: float32; parentScene: Scene; ctx: LottieBuildCtx)


type ZigZagVertex = object
  v, i, o: Point

proc zzRidge(at, dir: Point; sign, amp, inAmp, outAmp: float32): ZigZagVertex =
  let len = length(dir)
  if len < 1e-6'f32: return ZigZagVertex(v: at, i: at, o: at)
  let n = normal(Point(x:0,y:0), dir)
  let pos = at + n * (sign * amp)
  let unit = dir / len
  ZigZagVertex(v: pos, i: pos - unit * inAmp, o: pos + unit * outAmp)

proc zzCorner(cur: int; sign: float32; verts: seq[Point]; amp: float32; smooth: bool; freq: int; ridges: var seq[ZigZagVertex]) =
  let n = verts.len
  if n == 0: return
  let curIdx = ((cur mod n) + n) mod n
  let prevIdx = if curIdx == 0: n - 1 else: curIdx - 1
  let nextIdx = (curIdx + 1) mod n
  let dir = verts[nextIdx] - verts[prevIdx]
  var outAmp = 0.0'f32
  var inAmp = 0.0'f32
  if smooth:
    outAmp = length(verts[nextIdx] - verts[curIdx]) / (float32(freq + 1) * 2.0'f32)
    inAmp = length(verts[prevIdx] - verts[curIdx]) / (float32(freq + 1) * 2.0'f32)
  ridges.add(zzRidge(verts[curIdx], dir, sign, amp, inAmp, outAmp))

proc zzBezierAt(p0,p1,p2,p3: Point; t: float32): Point =
  let u = 1.0'f32 - t
  u*u*u*p0 + 3.0'f32*u*u*t*p1 + 3.0'f32*u*t*t*p2 + t*t*t*p3

proc zzBezierTan(p0,p1,p2,p3: Point; t: float32): Point =
  let u = 1.0'f32 - t
  3.0'f32*u*u*(p1-p0) + 6.0'f32*u*t*(p2-p1) + 3.0'f32*t*t*(p3-p2)

proc zzSegment(idx: int; sign: var float32; verts,ins,outs: seq[Point]; amp: float32; smooth: bool; freq: int; ridges: var seq[ZigZagVertex]) =
  if freq == 0: return
  let n = verts.len
  let i0 = idx
  let i1 = (idx + 1) mod n
  let p0 = verts[i0]; let p1 = outs[i0]; let p2 = ins[i1]; let p3 = verts[i1]
  let sAmp = if smooth: length(p3 - p0) / (float32(freq + 1) * 2.0'f32) else: 0.0'f32
  for k in 0 ..< freq:
    let t = float32(k + 1) / float32(freq + 1)
    ridges.add(zzRidge(zzBezierAt(p0,p1,p2,p3,t), zzBezierTan(p0,p1,p2,p3,t), sign, amp, sAmp, sAmp))
    sign = -sign

proc applyZigZag*(inPath: RenderPath; amp, freqF: float32; pointType: int): RenderPath =
  var outPath = RenderPath()
  let freq = max(0, int(freqF))
  let smooth = pointType == 2
  var verts: seq[Point] = @[]
  var ins: seq[Point] = @[]
  var outs: seq[Point] = @[]
  var ridges: seq[ZigZagVertex] = @[]
  var closed = false
  var iPt = 0

  proc flushSub() =
    if verts.len == 0: return
    if closed and verts.len > 1 and length(verts[^1] - verts[0]) < 1e-4'f32:
      ins[0] = ins[^1]
      discard verts.pop(); discard ins.pop(); discard outs.pop()
    if verts.len < 2: return
    let segCount = if closed: verts.len else: verts.len - 1
    ridges.setLen(0)
    var sign = 1.0'f32
    zzCorner(0, sign, verts, amp, smooth, freq, ridges)
    for i in 0 ..< segCount:
      var s = -sign
      zzSegment(i, s, verts, ins, outs, amp, smooth, freq, ridges)
      sign = s
      zzCorner(i + 1, sign, verts, amp, smooth, freq, ridges)
    if ridges.len == 0: return
    outPath.moveTo(ridges[0].v)
    for i in 1 ..< ridges.len:
      outPath.cubicTo(ridges[i-1].o, ridges[i].i, ridges[i].v)
    if closed: outPath.close()

  for cmd in inPath.cmds:
    case cmd
    of PathCommand.MoveTo:
      flushSub()
      verts.setLen(0); ins.setLen(0); outs.setLen(0); closed = false
      let p = inPath.pts[iPt]; inc iPt
      verts.add(p); ins.add(p); outs.add(p)
    of PathCommand.LineTo:
      let p = inPath.pts[iPt]; inc iPt
      if verts.len > 0: outs[outs.len-1] = verts[verts.len-1]
      ins.add(p); verts.add(p); outs.add(p)
    of PathCommand.CubicTo:
      let c1 = inPath.pts[iPt]; let c2 = inPath.pts[iPt+1]; let e = inPath.pts[iPt+2]; iPt += 3
      if verts.len > 0: outs[outs.len-1] = c1
      ins.add(c2); verts.add(e); outs.add(e)
    of PathCommand.Close:
      closed = true
      flushSub()
      verts.setLen(0); ins.setLen(0); outs.setLen(0); closed = false
  flushSub()
  result = outPath
proc colinear(p: seq[Point]; i: int): bool =
  i + 3 < p.len and zero(p[i] - p[i+1]) and zero(p[i+2] - p[i+3])

proc sharpCorner(p: seq[Point]; i: int): bool =
  i + 2 < p.len and zero(p[i] - p[i+1]) and zero(p[i+1] - p[i+2])

proc roundLineTo(outPath: var RenderPath; to: Point) =
  if outPath.pts.len == 0: return
  let last = outPath.pts[^1]
  outPath.cubicTo(last, to, to)

proc roundLineCorner(outPath: var RenderPath; prev, curr, next: Point; r: float32): Point =
  let lenPrev = length(prev - curr)
  let rPrev = if lenPrev > 0.0'f32: 0.5'f32 * min(lenPrev * 0.5'f32, r) / lenPrev else: 0.0'f32
  let lenNext = length(next - curr)
  let rNext = if lenNext > 0.0'f32: 0.5'f32 * min(lenNext * 0.5'f32, r) / lenNext else: 0.0'f32
  let dPrev = (curr - prev) * rPrev
  let dNext = (curr - next) * rNext
  roundLineTo(outPath, curr - dPrev * 2.0'f32)
  let ret = curr - dNext * 2.0'f32
  outPath.cubicTo(curr - dPrev, curr - dNext, ret)
  ret

proc roundCurveCorner(outPath: var RenderPath; prev, ctrl1, curr, next: Point; rounded: bool; roundTo: Point; r: float32): Point =
  let lenPrev = length(prev - curr)
  let tPrev = if lenPrev > 0.0'f32: min(lenPrev * 0.5'f32, r) / lenPrev else: 0.0'f32
  let arcStart = curr + (prev - curr) * tPrev
  outPath.cubicTo(if rounded: roundTo else: ctrl1, arcStart, arcStart)
  let lenNext = length(next - curr)
  let tNext = if lenNext > 0.0'f32: min(lenNext * 0.5'f32, r) / lenNext else: 0.0'f32
  let arcEnd = curr + (next - curr) * tNext
  outPath.cubicTo(arcStart + (curr - arcStart) * 0.5'f32, arcEnd + (curr - arcEnd) * 0.5'f32, arcEnd)
  arcEnd

proc roundPolystar(inPath: RenderPath; r: float32; outerRoundness: float32; hasRoundness: bool): RenderPath =
  ## C++ LottieRoundnessModifier::polystar (ThorVG 1.1.1)
  const ROUNDED_POLYSTAR_MAGIC_NUMBER = 0.47829'f32
  result = RenderPath(cmds: @[], pts: @[])
  if inPath.pts.len < 3 or inPath.cmds.len == 0:
    return inPath
  let ln = length(inPath.pts[1] - inPath.pts[2])
  let rr = if ln > 0.0'f32: ROUNDED_POLYSTAR_MAGIC_NUMBER * min(ln * 0.5'f32, r) / ln else: 0.0'f32
  if hasRoundness:
    let start = if abs(outerRoundness) <= 0.00001'f32: 3 else: 0
    result.moveTo(inPath.pts[start])
    var i = 1 + start
    while i + 2 < inPath.pts.len:
      let prev = inPath.pts[i]
      let curr = inPath.pts[i + 2]
      let next = if i < inPath.pts.len - start: inPath.pts[i + 4] else: inPath.pts[2]
      let nextCtrl = if i < inPath.pts.len - start: inPath.pts[i + 5] else: inPath.pts[3]
      let dNext = (curr - next) * rr
      let dPrev = (curr - prev) * rr
      let p0 = curr - dPrev * 2.0'f32
      let p1 = curr - dPrev
      let p2 = curr - dNext
      let p3 = curr - dNext * 2.0'f32
      result.cubicTo(prev, p0, p0)
      result.cubicTo(p1, p2, p3)
      result.cubicTo(p3, next, nextCtrl)
      i += 6
  else:
    # Build a simple vertex list (MoveTo + LineTo vertices). Nim may encode straight
    # segments as CubicTo; extract endpoints in that case.
    var verts: seq[Point] = @[]
    var ip = 0
    for cmd in inPath.cmds:
      case cmd
      of PathCommand.MoveTo:
        if ip < inPath.pts.len: verts.add(inPath.pts[ip]); inc ip
      of PathCommand.LineTo:
        if ip < inPath.pts.len: verts.add(inPath.pts[ip]); inc ip
      of PathCommand.CubicTo:
        if ip + 2 < inPath.pts.len: verts.add(inPath.pts[ip + 2]); ip += 3
      of PathCommand.Close:
        discard
    if verts.len < 2: return inPath
    let dPrev0 = (verts[1] - verts[0]) * rr
    var dPrev = dPrev0
    let pStart = verts[0] + dPrev * 2.0'f32
    result.moveTo(pStart)
    for idx in 1 ..< verts.len:
      let curr = verts[idx]
      let next = if idx == verts.len - 1: verts[1] else: verts[idx + 1]
      let dNext = (curr - next) * rr
      let p0 = curr - dPrev * 2.0'f32
      let p1 = curr - dPrev
      let p2 = curr - dNext
      let p3 = curr - dNext * 2.0'f32
      result.lineTo(p0)
      result.cubicTo(p1, p2, p3)
      dPrev = dNext * -1.0'f32
  result.close()

proc roundPath(inPath: RenderPath; r: float32): RenderPath =
  if r <= 0.0'f32 or inPath.cmds.len == 0: return inPath
  result = RenderPath(cmds: @[], pts: @[])
  result.cmds.setLen(0)
  result.pts.setLen(0)
  var startIndex = 0
  var inputStartPt = 0
  var rounded = false
  var roundTo = Point(x:0, y:0)
  var iCmds = 0
  var iPts = 0
  while iCmds < inPath.cmds.len:
    let cmd = inPath.cmds[iCmds]
    case cmd
    of PathCommand.MoveTo:
      startIndex = result.pts.len
      inputStartPt = iPts
      result.moveTo(inPath.pts[iPts])
      inc iPts
    of PathCommand.CubicTo:
      let hasNext = iCmds < inPath.cmds.len - 1
      let nextCmd = if hasNext: inPath.cmds[iCmds + 1] else: PathCommand.MoveTo
      var didRound = false
      if hasNext and iPts - 1 >= 0 and iPts + 2 < inPath.pts.len:
        if colinear(inPath.pts, iPts - 1):
          let prev = inPath.pts[iPts - 1]
          let curr = inPath.pts[iPts + 2]
          if nextCmd == PathCommand.CubicTo and iPts + 5 < inPath.pts.len and zero(inPath.pts[iPts + 2] - inPath.pts[iPts + 3]):
            roundTo = roundLineCorner(result, prev, curr, inPath.pts[iPts + 5], r)
            iPts += 3
            rounded = true
            didRound = true
          elif nextCmd == PathCommand.Close and inputStartPt + 2 < inPath.pts.len:
            roundTo = roundLineCorner(result, prev, curr, inPath.pts[inputStartPt + 2], r)
            let oldStart = result.pts[startIndex]
            result.pts[startIndex] = result.pts[^1]
            # All-cubic Nim paths: first cubic ctrl1 may be stale copy of old moveTo.
            if startIndex + 1 < result.pts.len and zero(result.pts[startIndex + 1] - oldStart):
              result.pts[startIndex + 1] = result.pts[startIndex]
            iPts += 3
            rounded = true
            didRound = true
        elif nextCmd == PathCommand.CubicTo and iPts + 5 < inPath.pts.len and sharpCorner(inPath.pts, iPts + 1):
          roundTo = roundCurveCorner(result, inPath.pts[iPts - 1], inPath.pts[iPts], inPath.pts[iPts + 2], inPath.pts[iPts + 5], rounded, roundTo, r)
          iPts += 3
          rounded = true
          didRound = true
      if not didRound:
        result.cubicTo(if rounded: roundTo else: inPath.pts[iPts], inPath.pts[iPts + 1], inPath.pts[iPts + 2])
        iPts += 3
        rounded = false
      inc iCmds
      continue
    of PathCommand.Close:
      result.close()
    of PathCommand.LineTo:
      result.lineTo(inPath.pts[iPts])
      inc iPts
    rounded = false
    inc iCmds

type
  OffsetLine = object
    pt1, pt2: Point
  OffsetState = object
    line: OffsetLine
    firstLine: OffsetLine
    movetoOutIndex: int
    movetoInIndex: int
    moveto: bool

proc offsetNormal(p1, p2: Point): Point =
  normal(p1, p2)

proc offsetShift(p1, p2: Point, offset: float32): OffsetLine =
  let scaled = offsetNormal(p1, p2) * offset
  OffsetLine(pt1: p1 + scaled, pt2: p2 + scaled)

proc offsetIntersected(line1, line2: OffsetLine; intersection: var Point; inside: var bool): bool =
  if zero(line1.pt2 - line2.pt1):
    intersection = line1.pt2
    inside = true
    return true
  const epsilon = 1e-3'f32
  let denom = (line1.pt2.x - line1.pt1.x) * (line2.pt2.y - line2.pt1.y) - (line1.pt2.y - line1.pt1.y) * (line2.pt2.x - line2.pt1.x)
  if abs(denom) < epsilon: return false
  let t = ((line2.pt1.x - line1.pt1.x) * (line2.pt2.y - line2.pt1.y) - (line2.pt1.y - line1.pt1.y) * (line2.pt2.x - line2.pt1.x)) / denom
  let u = ((line2.pt1.x - line1.pt1.x) * (line1.pt2.y - line1.pt1.y) - (line2.pt1.y - line1.pt1.y) * (line1.pt2.x - line1.pt1.x)) / denom
  intersection.x = line1.pt1.x + t * (line1.pt2.x - line1.pt1.x)
  intersection.y = line1.pt1.y + t * (line1.pt2.y - line1.pt1.y)
  inside = t >= -epsilon and t <= 1.0'f32 + epsilon and u >= -epsilon and u <= 1.0'f32 + epsilon
  true

proc offsetLineTo(outPath: var RenderPath; to: Point) =
  if outPath.pts.len == 0: return
  outPath.cubicTo(outPath.pts[^1], to, to)

proc offsetCorner(outPath: var RenderPath; line, nextLine: OffsetLine; movetoOutIndex: int; nextClose: bool; join: StrokeJoin; miterLimit: float32) =
  var inside = false
  var intersect = Point(x:0, y:0)
  if offsetIntersected(line, nextLine, intersect, inside):
    if inside:
      if nextClose:
        if outPath.pts.len > movetoOutIndex + 1 and zero(outPath.pts[movetoOutIndex] - outPath.pts[movetoOutIndex + 1]):
          outPath.pts[movetoOutIndex + 1] = intersect
        if outPath.pts.len > movetoOutIndex:
          outPath.pts[movetoOutIndex] = intersect
      offsetLineTo(outPath, intersect)
    else:
      offsetLineTo(outPath, line.pt2)
      if join == StrokeJoin.Round:
        outPath.cubicTo((line.pt2 + intersect) * 0.5'f32, (nextLine.pt1 + intersect) * 0.5'f32, nextLine.pt1)
      elif join == StrokeJoin.Miter:
        let norm = offsetNormal(line.pt1, line.pt2)
        let nextNorm = offsetNormal(nextLine.pt1, nextLine.pt2)
        let miterDir = norm + nextNorm
        let miterLen = sqrt(miterDir.x*miterDir.x + miterDir.y*miterDir.y)
        if miterLen > 1e-6'f32:
          let md = miterDir / miterLen
          if 1.0'f32 <= miterLimit * abs(md.x * norm.x + md.y * norm.y):
            offsetLineTo(outPath, intersect)
        offsetLineTo(outPath, nextLine.pt1)
      else:
        offsetLineTo(outPath, nextLine.pt1)
  else:
    offsetLineTo(outPath, line.pt2)

proc colinearOffset(p: seq[Point]; i: int): bool =
  if i + 3 >= p.len: return false
  zero(p[i] - p[i+1]) and zero(p[i+2] - p[i+3])

proc offsetLine(outPath: var RenderPath; inCmds: seq[PathCommand]; inPts: seq[Point]; curPt: var int; curCmd: int; state: var OffsetState; offset: float32; degenerated: bool; join: StrokeJoin; miterLimit: float32) =
  if curPt - 1 >= 0 and curPt < inPts.len and zero(inPts[curPt - 1] - inPts[curPt]):
    inc curPt
    return
  if curCmd - 1 >= 0 and inCmds[curCmd - 1] != PathCommand.LineTo:
    state.line = offsetShift(inPts[curPt - 1], inPts[curPt], offset)
  if state.moveto:
    state.movetoOutIndex = outPath.pts.len
    outPath.moveTo(state.line.pt1)
    state.firstLine = state.line
    state.moveto = false

  let nonDegeneratedCubic = proc(cmdIdx, ptIdx: int): bool =
    if cmdIdx < 0 or cmdIdx >= inCmds.len: return false
    if inCmds[cmdIdx] != PathCommand.CubicTo: return false
    if ptIdx < 0 or ptIdx + 3 >= inPts.len: return false
    not zero(inPts[ptIdx] - inPts[ptIdx + 1]) and not zero(inPts[ptIdx + 2] - inPts[ptIdx + 3])

  let degAdj = if degenerated: 1 else: 0
  if curCmd + 1 >= inCmds.len or inCmds[curCmd + 1] == PathCommand.MoveTo or nonDegeneratedCubic(curCmd + 1, curPt + degAdj):
    offsetLineTo(outPath, state.line.pt2)
    inc curPt
    return

  var nextLine = state.firstLine
  if curCmd + 1 < inCmds.len:
    if inCmds[curCmd + 1] == PathCommand.LineTo and curPt + 1 + degAdj < inPts.len:
      nextLine = offsetShift(inPts[curPt + degAdj], inPts[curPt + 1 + degAdj], offset)
    elif inCmds[curCmd + 1] == PathCommand.CubicTo and curPt + 2 + degAdj < inPts.len:
      nextLine = offsetShift(inPts[curPt + 1 + degAdj], inPts[curPt + 2 + degAdj], offset)
    elif inCmds[curCmd + 1] == PathCommand.Close and curPt + degAdj < inPts.len and state.movetoInIndex + degAdj < inPts.len and not zero(inPts[curPt + degAdj] - inPts[state.movetoInIndex + degAdj]):
      nextLine = offsetShift(inPts[curPt + degAdj], inPts[state.movetoInIndex + degAdj], offset)

  offsetCorner(outPath, state.line, nextLine, state.movetoOutIndex, curCmd + 1 < inCmds.len and inCmds[curCmd + 1] == PathCommand.Close, join, miterLimit)
  state.line = nextLine
  inc curPt

proc offsetCubic(outPath: var RenderPath; pts: seq[Point]; ptStart: int; state: var OffsetState; offset: float32; threshold: float32; pending: var int) =
  var intersect = Point(x:0, y:0)
  var stack: seq[bezier.Bezier] = @[]
  if ptStart < 0 or ptStart + 3 >= pts.len: return
  stack.add(bezier.Bezier(start: pts[ptStart], ctrl1: pts[ptStart+1], ctrl2: pts[ptStart+2], `end`: pts[ptStart+3]))

  while stack.len > 0:
    var bz = stack.pop()
    let blen = length(bz.start, bz.ctrl1) + length(bz.ctrl1, bz.ctrl2) + length(bz.ctrl2, bz.`end`)
    let blenArc = bezier.length(bz)
    if blen > threshold * blenArc and blen > 1.0'f32:
      var leftBz: bezier.Bezier
      bezier.splitAt(bz, 0.5'f32, leftBz) # leftBz=[0,0.5], bz=[0.5,1]
      stack.add(bz)
      stack.add(leftBz)
      continue

    let deg1 = zero(bz.start - bz.ctrl1)
    let line1 = if deg1: state.line else: offsetShift(bz.start, bz.ctrl1, offset)
    let line2 = offsetShift(bz.ctrl1, bz.ctrl2, offset)

    if pending == outPath.pts.len and not state.moveto:
      var inside = false
      if not offsetIntersected((if deg1: line2 else: line1), state.line, intersect, inside):
        intersect = state.line.pt2
      if outPath.pts.len >= 2:
        outPath.pts[outPath.pts.len - 2] = intersect
        outPath.pts[outPath.pts.len - 1] = intersect

    let deg3 = zero(bz.ctrl2 - bz.`end`)
    state.line = if deg3: line2 else: offsetShift(bz.ctrl2, bz.`end`, offset)

    if state.moveto:
      state.movetoOutIndex = outPath.pts.len
      outPath.moveTo(line1.pt1)
      state.firstLine = line1
      state.moveto = false

    var inside2 = false
    if deg1:
      if outPath.pts.len > 0: outPath.pts.add(outPath.pts[^1])
      else: outPath.pts.add(line1.pt1)
    else:
      discard offsetIntersected(line1, line2, intersect, inside2)
      outPath.pts.add(intersect)

    if deg3:
      intersect = state.line.pt2
      pending = outPath.pts.len + 2
    else:
      var inside3 = false
      discard offsetIntersected(line2, state.line, intersect, inside3)
    outPath.pts.add(intersect)
    outPath.pts.add(state.line.pt2)
    outPath.cmds.add(PathCommand.CubicTo)

proc offsetPath(inPath: RenderPath; offset: float32; join: StrokeJoin = StrokeJoin.Round; miterLimit: float32 = 4.0'f32): RenderPath =
  ## C++ LottieOffsetModifier-like path offset. Bounded implementation.
  if offset == 0.0'f32 or inPath.cmds.len == 0: return inPath
  result = RenderPath(cmds: @[], pts: @[])
  if inPath.pts.len == 0: return result

  # Determine winding (clockwise) from path points
  var area = 0.0'f32
  for i in 0 ..< max(0, inPath.pts.len - 1):
    area += cross(inPath.pts[i], inPath.pts[i+1])
  if inPath.pts.len > 0:
    area += cross(inPath.pts[^1], inPath.pts[0])
  let off = if area < 0.0'f32: offset else: -offset
  let threshold = 1.0'f32 / abs(off) + 1.0'f32

  var state = OffsetState(movetoOutIndex: 0, movetoInIndex: 0, moveto: false)
  var pending = -1
  var iPt = 0
  for iCmd in 0 ..< inPath.cmds.len:
    case inPath.cmds[iCmd]
    of PathCommand.MoveTo:
      state.moveto = true
      state.movetoInIndex = iPt
      inc iPt
    of PathCommand.LineTo:
      offsetLine(result, inPath.cmds, inPath.pts, iPt, iCmd, state, off, false, join, miterLimit)
    of PathCommand.CubicTo:
      if iPt - 1 >= 0 and iPt + 2 < inPath.pts.len and colinearOffset(inPath.pts, iPt - 1):
        inc iPt
        offsetLine(result, inPath.cmds, inPath.pts, iPt, iCmd, state, off, true, join, miterLimit)
        inc iPt
      else:
        offsetCubic(result, inPath.pts, iPt - 1, state, off, threshold, pending)
        iPt += 3
    of PathCommand.Close:
      if iPt - 1 >= 0 and state.movetoInIndex < inPath.pts.len and not zero(inPath.pts[iPt - 1] - inPath.pts[state.movetoInIndex]):
        offsetCorner(result, state.line, state.firstLine, state.movetoOutIndex, true, join, miterLimit)
      result.cmds.add(PathCommand.Close)

proc puckerBloatCenter(cmds: seq[PathCommand]; pts: seq[Point]): Point =
  var center = Point(x:0, y:0)
  var count = 0
  var p = 0
  var start = 0
  for ci in 0 ..< cmds.len:
    case cmds[ci]
    of PathCommand.MoveTo:
      start = p
      inc p
    of PathCommand.CubicTo:
      if p - 1 >= 0 and p + 2 < pts.len:
        center = center + pts[p-1] + pts[p] + pts[p+1] + pts[p+2]
        count += 4
      p += 3
    of PathCommand.LineTo:
      if p - 1 >= 0 and p < pts.len:
        center = center + pts[p-1] + pts[p]
        count += 2
      inc p
    of PathCommand.Close:
      if p - 1 >= 0 and start < pts.len and not zero(pts[p-1] - pts[start]):
        center = center + pts[p-1] + pts[start]
        count += 2
  if count > 0: center / float32(count) else: Point(x:0, y:0)

proc puckerBloatPath(inPath: RenderPath; amount: float32): RenderPath =
  if amount == 0.0'f32 or inPath.cmds.len == 0: return inPath
  result = RenderPath(cmds: @[], pts: @[])
  let center = puckerBloatCenter(inPath.cmds, inPath.pts)
  let a = amount * 0.01'f32
  var p = 0
  var start = 0
  for ci in 0 ..< inPath.cmds.len:
    case inPath.cmds[ci]
    of PathCommand.MoveTo:
      start = p
      result.cmds.add(PathCommand.MoveTo)
      result.pts.add(inPath.pts[p] + (center - inPath.pts[p]) * a)
      inc p
    of PathCommand.CubicTo:
      result.cmds.add(PathCommand.CubicTo)
      result.pts.add(inPath.pts[p] - (center - inPath.pts[p]) * a)
      result.pts.add(inPath.pts[p+1] - (center - inPath.pts[p+1]) * a)
      result.pts.add(inPath.pts[p+2] + (center - inPath.pts[p+2]) * a)
      p += 3
    of PathCommand.LineTo:
      result.cmds.add(PathCommand.CubicTo)
      let prev = inPath.pts[p-1]
      let curr = inPath.pts[p]
      result.pts.add(prev - (center - prev) * a)
      result.pts.add(curr - (center - curr) * a)
      result.pts.add(curr + (center - curr) * a)
      inc p
    of PathCommand.Close:
      if p - 1 >= 0 and start < inPath.pts.len and not zero(inPath.pts[p-1] - inPath.pts[start]):
        let prev = inPath.pts[p-1]
        let st = inPath.pts[start]
        result.cmds.add(PathCommand.CubicTo)
        result.pts.add(prev - (center - prev) * a)
        result.pts.add(st - (center - st) * a)
        result.pts.add(st + (center - st) * a)
      result.cmds.add(PathCommand.Close)

proc buildGroup(g: LottieGroup; frameNo: float32; parentScene: Scene; ctx: LottieBuildCtx) =
  ## Paso 1: reverse child traversal to match C++ LottieBuilder temporal semantics.
  ## Style/transform/modifier updates mutate local propagator state at visit time.
  ## Geometry/groups are collected as draw acts and emitted in forward order
  ## (equivalent to C++ reverse iteration + add-at-processing-time).
  var local = ctx
  type DrawActKind = enum akShape, akGroup
  type DrawAct = object
    case kind: DrawActKind
    of akShape: shp: Shape
    of akGroup: grp: LottieGroup
  type RepeaterInfo = object
    cnt: int
    offset: float32
    position: LottiePoint
    anchor: LottiePoint
    scale: LottiePoint
    rotation: float32
    startOpacity: uint8
    endOpacity: uint8
    inorder: bool
    baseTransform: Matrix
  var repeaters: seq[RepeaterInfo] = @[] # active repeaters (reverse-pass order)
  var acts: seq[DrawAct] = @[]
  var acc = newShape()
  var accHas = false
  type SavedFill = tuple[hasFill: bool, hasFillGrad: bool, fillColor: RGBA, fillGrad: Fill, fillRule: FillRule]
  type SavedStroke = tuple[hasStroke: bool, hasStrokeGrad: bool, strokeColor: RGBA, strokeGrad: Fill,
    strokeWidth: float32, strokeCap: StrokeCap, strokeJoin: StrokeJoin, strokeMiter: float32,
    strokeDashes: seq[float32], strokeDashOffset: float32, hasStrokeDash: bool]
  var extraFills: seq[SavedFill] = @[]
  var extraStrokes: seq[SavedStroke] = @[]
  # C++ LottieModel.cpp: reqFragment when multiple fills/strokes or non-mergeable group with painters.
  var reqFragment = false
  block computeReqFragment:
    var fillCnt = 0
    var strokeCnt = 0
    for ch in g.children:
      if ch == nil: continue
      if reqFragment: break
      if ch of LottieGroup and not LottieGroup(ch).hidden:
        if fillCnt > 0 or strokeCnt > 0: reqFragment = true
      elif ch of LottieFillObj or ch of LottieGradientFillObj:
        if not ch.hidden:
          if fillCnt > 0: reqFragment = true
          else: inc fillCnt
      elif ch of LottieStrokeObj or ch of LottieGradientStrokeObj:
        if not ch.hidden:
          if strokeCnt > 0: reqFragment = true
          else: inc strokeCnt

  proc applyRepeaters(shp: Shape): seq[Shape] =
    if repeaters.len == 0:
      return @[shp]
    var propagators: seq[Shape] = @[shp]
    for ri in countdown(repeaters.len - 1, 0):
      let r = repeaters[ri]
      let last = (ri == 0)
      if r.cnt <= 0:
        propagators.setLen(0)
        break
      var invBase: Matrix
      discard inverse(r.baseTransform, invBase)
      var shapes: seq[Shape] = @[]
      for i in 0 ..< r.cnt:
        let multiplier = r.offset + float32(i)
        let tval = if r.cnt <= 1: 1.0'f32 else: float32(i + 1) / float32(r.cnt)
        let sop = int(r.startOpacity)
        let eop = int(r.endOpacity)
        let opacity = uint8(clamp(sop + int(float32(eop - sop) * tval + 0.5'f32), 0, 255))
        var m = identity()
        translate(m, Point(x: r.position.x * multiplier + r.anchor.x, y: r.position.y * multiplier + r.anchor.y))
        scale(m, Point(x: pow(r.scale.x * 0.01'f32, multiplier), y: pow(r.scale.y * 0.01'f32, multiplier)))
        rotate(m, r.rotation * multiplier)
        translateR(m, Point(x: -r.anchor.x, y: -r.anchor.y))
        let trM = r.baseTransform * m
        for p in propagators:
          let ns = Shape(p.duplicate())
          ns.opacity = uint8((uint32(p.opacity) * uint32(opacity) + 0xff'u32) shr 8)
          let curT = p.transform()
          discard ns.transform(trM * (invBase * curT))
          shapes.add(ns)
      propagators = @[]
      if not last:
        propagators = shapes
      else:
        var outShapes: seq[Shape] = @[]
        if r.inorder:
          for s in shapes: outShapes.add(s)
        else:
          for i2 in countdown(shapes.len - 1, 0): outShapes.add(shapes[i2])
        return outShapes
    return propagators

  proc emitStyledAcc(baseShape: Shape; styleCtx: LottieBuildCtx) =
    let sh = Shape(baseShape.duplicate())
    applyStyle(sh, styleCtx)
    discard sh.transform(styleCtx.transform)
    let expanded = applyRepeaters(sh)
    for s in expanded:
      acts.add(DrawAct(kind: akShape, shp: s))

  proc flushAcc() =
    if not accHas: return
    if local.puckerBloat != 0.0'f32:
      acc.rs.path = puckerBloatPath(acc.rs.path, local.puckerBloat)
    if local.hasZigzag and local.zigzagAmp != 0.0'f32 and local.zigzagFreq > 0.0'f32:
      acc.rs.path = applyZigZag(acc.rs.path, local.zigzagAmp, local.zigzagFreq, local.zigzagPoint)
    if local.hasOffsetPath and local.offsetPathVal != 0.0'f32:
      acc.rs.path = offsetPath(acc.rs.path, local.offsetPathVal, local.offsetPathJoin, local.offsetPathMiter)
    # C++ reqFragment: painter-only fragments, fills before strokes in context order.
    let hasFillP = local.hasFill or local.hasFillGrad
    let hasStrokeP = local.hasStroke or local.hasStrokeGrad
    # Extra fills (saved earlier fills), then current fill
    for ef in extraFills:
      var fc = local
      fc.hasFill = ef.hasFill
      fc.hasFillGrad = ef.hasFillGrad
      fc.fillColor = ef.fillColor
      fc.fillGrad = ef.fillGrad
      fc.fillRule = ef.fillRule
      fc.hasStroke = false
      fc.hasStrokeGrad = false
      emitStyledAcc(acc, fc)
    if hasFillP:
      var fc = local
      fc.hasStroke = false
      fc.hasStrokeGrad = false
      if reqFragment or not hasStrokeP:
        emitStyledAcc(acc, fc)
      # if not reqFragment and hasStrokeP, fill will be emitted with stroke below
    # Extra strokes, then current stroke
    if hasStrokeP:
      if not reqFragment and hasFillP:
        # non-reqFragment: keep combined fill+stroke as one shape
        emitStyledAcc(acc, local)
      else:
        for i in countdown(extraStrokes.high, 0):
          let es = extraStrokes[i]
          var sc = local
          sc.hasFill = false
          sc.hasFillGrad = false
          sc.hasStroke = es.hasStroke
          sc.hasStrokeGrad = es.hasStrokeGrad
          sc.strokeColor = es.strokeColor
          sc.strokeGrad = es.strokeGrad
          sc.strokeWidth = es.strokeWidth
          sc.strokeCap = es.strokeCap
          sc.strokeJoin = es.strokeJoin
          sc.strokeMiter = es.strokeMiter
          sc.strokeDashes = es.strokeDashes
          sc.strokeDashOffset = es.strokeDashOffset
          sc.hasStrokeDash = es.hasStrokeDash
          emitStyledAcc(acc, sc)
        var sc = local
        sc.hasFill = false
        sc.hasFillGrad = false
        emitStyledAcc(acc, sc)
    elif not hasFillP:
      emitStyledAcc(acc, local)
    extraFills.setLen(0)
    extraStrokes.setLen(0)
    acc = newShape()
    accHas = false

  proc breakMerge() =
    # C++ clears ctx->merging on style/transform/modifier changes.
    if accHas: flushAcc()

  for i in countdown(g.children.high, 0):
    let child = g.children[i]
    if child == nil: continue

    if child of LottieTransform:
      if child.hidden: continue
      breakMerge()
      let t = LottieTransform(child)
      var m = local.transform
      applyTransform(m, t, frameNo)
      local.transform = m
      let op = layerOpacity(t, frameNo)
      local.opacity = uint8((uint32(local.opacity) * uint32(op) + 0xff'u32) shr 8)

    elif child of LottieFillObj:
      let f = LottieFillObj(child)
      if not f.hidden:
        breakMerge()
        if reqFragment and (local.hasFill or local.hasFillGrad):
          extraFills.add((local.hasFill, local.hasFillGrad, local.fillColor, local.fillGrad, local.fillRule))
        let c = f.color.eval(frameNo)
        let o = f.opacity.eval(frameNo)
        local.fillColor = toRgba(c, o)
        local.hasFill = true
        local.hasFillGrad = false
        local.fillRule = if f.fillRule == 2: FillRule.EvenOdd else: FillRule.NonZero
        # C++: if (ctx->propagator->strokeWidth() > 0) ctx->propagator->order(true);
        if local.strokeWidth > 0.0'f32:
          local.strokeFirst = true

    elif child of LottieStrokeObj:
      let st = LottieStrokeObj(child)
      if not st.hidden:
        breakMerge()
        if reqFragment and (local.hasStroke or local.hasStrokeGrad):
          extraStrokes.add((local.hasStroke, local.hasStrokeGrad, local.strokeColor, local.strokeGrad,
            local.strokeWidth, local.strokeCap, local.strokeJoin, local.strokeMiter,
            local.strokeDashes, local.strokeDashOffset, local.hasStrokeDash))
        let c = st.color.eval(frameNo)
        let o = st.opacity.eval(frameNo)
        local.strokeColor = toRgba(c, o)
        local.hasStroke = true
        local.hasStrokeGrad = false
        local.strokeWidth = st.width.eval(frameNo)
        local.strokeCap = st.cap
        local.strokeJoin = st.join
        local.strokeMiter = st.miterLimit
        if st.dashes.len > 0:
          local.strokeDashes.setLen(0)
          for d in st.dashes:
            local.strokeDashes.add(max(0.0'f32, d.eval(frameNo)))
          local.strokeDashOffset = st.dashOffset.eval(frameNo)
          local.hasStrokeDash = true
        else:
          local.hasStrokeDash = false
          local.strokeDashes.setLen(0)
          local.strokeDashOffset = 0.0'f32

    elif child of LottieGradientFillObj:
      let gf = LottieGradientFillObj(child)
      if not gf.hidden:
        breakMerge()
        if reqFragment and (local.hasFill or local.hasFillGrad):
          extraFills.add((local.hasFill, local.hasFillGrad, local.fillColor, local.fillGrad, local.fillRule))
        local.fillGrad = makeGradient(gf, frameNo)
        local.hasFillGrad = true
        local.hasFill = false
        local.fillRule = if gf.fillRule == 2: FillRule.EvenOdd else: FillRule.NonZero
        if local.strokeWidth > 0.0'f32:
          local.strokeFirst = true

    elif child of LottieGradientStrokeObj:
      let gs = LottieGradientStrokeObj(child)
      if not gs.hidden:
        breakMerge()
        if reqFragment and (local.hasStroke or local.hasStrokeGrad):
          extraStrokes.add((local.hasStroke, local.hasStrokeGrad, local.strokeColor, local.strokeGrad,
            local.strokeWidth, local.strokeCap, local.strokeJoin, local.strokeMiter,
            local.strokeDashes, local.strokeDashOffset, local.hasStrokeDash))
        local.strokeGrad = makeStrokeGradient(gs, frameNo)
        local.hasStrokeGrad = true
        local.hasStroke = true
        local.strokeWidth = gs.width.eval(frameNo)
        local.strokeCap = gs.cap
        local.strokeJoin = gs.join
        local.strokeMiter = gs.miterLimit
        if gs.dashes.len > 0:
          local.strokeDashes.setLen(0)
          for d in gs.dashes:
            local.strokeDashes.add(max(0.0'f32, d.eval(frameNo)))
          local.strokeDashOffset = gs.dashOffset.eval(frameNo)
          local.hasStrokeDash = true
        else:
          local.hasStrokeDash = false
          local.strokeDashes.setLen(0)
          local.strokeDashOffset = 0.0'f32

    elif child of LottieTrimpathObj:
      let tm = LottieTrimpathObj(child)
      if not tm.hidden:
        breakMerge()
        let off = tm.offset.eval(frameNo) / 360.0'f32 * 100.0'f32
        var nb = normTrim(tm.start.eval(frameNo) + off)
        var ne = normTrim(tm.`end`.eval(frameNo) + off)
        if local.hasTrim:
          # Reverse pass visits later-array trim first; compose existing(later) into new(earlier)
          # to preserve legacy/C++-observed composition order that matches goldens.
          let curOff = local.trimOffset / 360.0'f32 * 100.0'f32
          let cb = normTrim(local.trimStart + curOff)
          let ce = normTrim(local.trimEnd + curOff)
          let len = abs(nb - ne)
          local.trimStart = (len * cb + nb) * 100.0'f32
          local.trimEnd = (len * ce + nb) * 100.0'f32
          local.trimOffset = 0.0'f32
        else:
          local.trimStart = tm.start.eval(frameNo)
          local.trimEnd = tm.`end`.eval(frameNo)
          local.trimOffset = tm.offset.eval(frameNo)
        local.trimSimultaneous = (tm.mode != 2)
        local.hasTrim = true

    elif child of LottieRoundedCornerObj:
      let rd = LottieRoundedCornerObj(child)
      if not rd.hidden:
        breakMerge()
        local.roundCorner = rd.radius.eval(frameNo)

    elif child of LottieZigZagObj:
      let zz = LottieZigZagObj(child)
      if not zz.hidden:
        breakMerge()
        local.hasZigzag = true
        local.zigzagAmp = zz.amplitude.eval(frameNo)
        local.zigzagFreq = zz.frequency.eval(frameNo)
        local.zigzagPoint = zz.pointType

    elif child of LottiePuckerBloatObj:
      let pb = LottiePuckerBloatObj(child)
      if not pb.hidden:
        breakMerge()
        local.puckerBloat = pb.amount.eval(frameNo)

    elif child of LottieOffsetPathObj:
      let op = LottieOffsetPathObj(child)
      if not op.hidden:
        breakMerge()
        local.offsetPathVal = op.offset.eval(frameNo)
        local.offsetPathMiter = op.miterLimit
        local.offsetPathJoin = if op.join == 1: StrokeJoin.Miter elif op.join == 2: StrokeJoin.Round else: StrokeJoin.Bevel
        local.hasOffsetPath = local.offsetPathVal != 0.0'f32

    elif child of LottieRepeaterObj:
      let rp = LottieRepeaterObj(child)
      if not rp.hidden:
        breakMerge()
        let cnt = max(0, int(round(rp.copies.eval(frameNo))))
        let so = uint8(clamp(int(rp.startOpacity.eval(frameNo) * 2.55'f32 + 0.5'f32), 0, 255))
        let eo = uint8(clamp(int(rp.endOpacity.eval(frameNo) * 2.55'f32 + 0.5'f32), 0, 255))
        repeaters.add(RepeaterInfo(
          cnt: cnt,
          offset: rp.offset.eval(frameNo),
          position: rp.position.eval(frameNo),
          anchor: rp.anchor.eval(frameNo),
          scale: rp.scale.eval(frameNo),
          rotation: rp.rotation.eval(frameNo),
          startOpacity: so,
          endOpacity: eo,
          inorder: rp.inorder,
          baseTransform: local.transform
        ))

    elif child of LottieGroup:
      if child.hidden: continue
      flushAcc()
      acts.add(DrawAct(kind: akGroup, grp: LottieGroup(child)))

    elif child of LottiePathObj:
      if child.hidden: continue
      let p = LottiePathObj(child)
      if local.roundCorner > 0.0'f32:
        let tmp = newShape()
        buildPath(tmp, p.path.eval(frameNo))
        tmp.rs.path = roundPath(tmp.rs.path, local.roundCorner)
        acc.rs.path.cmds.add(tmp.rs.path.cmds)
        acc.rs.path.pts.add(tmp.rs.path.pts)
      else:
        buildPath(acc, p.path.eval(frameNo))
      accHas = true

    elif child of LottieRectObj:
      if child.hidden: continue
      let r = LottieRectObj(child)
      let pos = r.position.eval(frameNo)
      let sz = r.size.eval(frameNo)
      let baseR = r.radius.eval(frameNo)
      # C++ 1.1.1 RoundnessModifier::rect: if rect.r == 0, use min(modifier.r, max(w,h)*0.5); else keep rect.r
      let effectiveR = if baseR == 0.0'f32 and local.roundCorner > 0.0'f32:
                         min(local.roundCorner, max(sz.x, sz.y) * 0.5'f32)
                       else:
                         min(abs(baseR), min(abs(sz.x), abs(sz.y)) * 0.5'f32)
      let useRoundPath = baseR == 0.0'f32 and local.roundCorner > 0.0'f32 and (local.hasTrim or local.hasZigzag or local.puckerBloat != 0.0'f32 or local.hasOffsetPath)
      if useRoundPath:
        let tmp = newShape()
        discard tmp.appendRect(pos.x - sz.x/2.0'f32, pos.y - sz.y/2.0'f32, sz.x, sz.y, 0.0'f32, 0.0'f32)
        tmp.rs.path = roundPath(tmp.rs.path, effectiveR)
        acc.rs.path.cmds.add(tmp.rs.path.cmds)
        acc.rs.path.pts.add(tmp.rs.path.pts)
      else:
        discard acc.appendRect(pos.x - sz.x/2.0'f32, pos.y - sz.y/2.0'f32, sz.x, sz.y, effectiveR, effectiveR)
      accHas = true

    elif child of LottieEllipseObj:
      if child.hidden: continue
      let e = LottieEllipseObj(child)
      let pos = e.position.eval(frameNo)
      let sz = e.size.eval(frameNo)
      # C++ 1.1.1: RoundnessModifier::ellipse bypasses. OffsetModifier::ellipse expands radius.
      if local.hasOffsetPath and local.offsetPathVal != 0.0'f32 and local.puckerBloat == 0.0'f32 and not local.hasZigzag:
        flushAcc()
        let rx = max(0.0'f32, sz.x/2.0'f32 + local.offsetPathVal)
        let ry = max(0.0'f32, sz.y/2.0'f32 + local.offsetPathVal)
        let sh = newShape()
        discard sh.appendCircle(pos.x, pos.y, rx, ry)
        applyStyle(sh, local)
        discard sh.transform(local.transform)
        let expanded = applyRepeaters(sh)
        for s in expanded:
          acts.add(DrawAct(kind: akShape, shp: s))
      else:
        discard acc.appendCircle(pos.x, pos.y, sz.x/2.0'f32, sz.y/2.0'f32)
        accHas = true

    elif child of LottiePolystarObj:
      if child.hidden: continue
      let ps = LottiePolystarObj(child)
      if local.roundCorner > 0.0'f32:
        let tmp = newShape()
        let outerR = ps.outerRadius.eval(frameNo)
        let innerR = ps.innerRadius.eval(frameNo)
        let outerRound = ps.outerRoundness.eval(frameNo)
        let innerRound = ps.innerRoundness.eval(frameNo)
        buildPolystar(tmp, ps.position.eval(frameNo), outerR, innerR, outerRound, innerRound,
          ps.rotation.eval(frameNo), ps.points.eval(frameNo), ps.starType)
        let outerRoundness01 = outerRound * 0.01'f32
        let innerRoundness01 = innerRound * 0.01'f32
        let hasRoundness = (ps.starType == 1) and (abs(outerRoundness01) > 0.00001'f32 or abs(innerRoundness01) > 0.00001'f32)
        let polyOuter = if ps.starType == 1: outerRoundness01 else: 0.0'f32
        tmp.rs.path = roundPolystar(tmp.rs.path, local.roundCorner, polyOuter, hasRoundness)
        acc.rs.path.cmds.add(tmp.rs.path.cmds)
        acc.rs.path.pts.add(tmp.rs.path.pts)
      else:
        buildPolystar(acc, ps.position.eval(frameNo), ps.outerRadius.eval(frameNo),
          ps.innerRadius.eval(frameNo), ps.outerRoundness.eval(frameNo), ps.innerRoundness.eval(frameNo),
          ps.rotation.eval(frameNo), ps.points.eval(frameNo), ps.starType)
      accHas = true

  flushAcc()
  # Acts collected in reverse child order; emit forward to match C++ add-at-processing-time.
  for i in 0 ..< acts.len:
    case acts[i].kind
    of akShape:
      discard parentScene.add(acts[i].shp)
    of akGroup:
      buildGroup(acts[i].grp, frameNo, parentScene, local)

proc buildObject(obj: LottieObject; frameNo: float32; parentScene: Scene; ctx: LottieBuildCtx) =
  if obj == nil or obj.hidden: return
  if obj of LottieGroup:
    buildGroup(LottieGroup(obj), frameNo, parentScene, ctx)
  elif obj of LottiePathObj:
    let p = LottiePathObj(obj)
    drawStyledPath(parentScene, p.path.eval(frameNo), ctx)
  elif obj of LottieRectObj:
    let r = LottieRectObj(obj)
    drawStyledRect(parentScene, r.position.eval(frameNo), r.size.eval(frameNo), r.radius.eval(frameNo), ctx)
  elif obj of LottieEllipseObj:
    let e = LottieEllipseObj(obj)
    drawStyledEllipse(parentScene, e.position.eval(frameNo), e.size.eval(frameNo), ctx)
  elif obj of LottiePolystarObj:
    let ps = LottiePolystarObj(obj)
    drawStyledPolystar(parentScene, ps.position.eval(frameNo), ps.outerRadius.eval(frameNo),
      ps.innerRadius.eval(frameNo), ps.outerRoundness.eval(frameNo), ps.innerRoundness.eval(frameNo),
      ps.rotation.eval(frameNo), ps.points.eval(frameNo), ps.starType, ctx)

proc findLayerById(layers: seq[LottieLayer]; id: int): LottieLayer =
  for l in layers:
    if l != nil and int(l.id) == id: return l
  nil

proc findAsset(comp: LottieComposition; refId: string): LottieAsset =
  for a in comp.assets:
    if a != nil and a.id == refId: return a
  nil

proc frameAtTime(comp: LottieComposition; timeInSec: float32): float32 =
  let dur = (comp.outPoint - comp.inPoint) / (if comp.frameRate > 0.0'f32: comp.frameRate else: 60.0'f32)
  if dur <= 0.0'f32: return 0.0'f32
  var p = timeInSec / dur
  if p < 0.0'f32: p = 0.0'f32
  p * (comp.outPoint - comp.inPoint)

proc remapFrame(comp: LottieComposition; layer: LottieLayer; frameNo: float32): float32 =
  # C++ LottieRootLayer::remap: if timeRemap enabled, frameAtTime(timeRemap(frameNo)); else (frameNo-startFrame)/timeStretch
  if layer.timeRemap.frames.len > 0 or layer.timeRemap.value >= 0.0'f32:
    return frameAtTime(comp, layer.timeRemap.eval(frameNo))
  let stretch = if layer.timeStretch == 0.0'f32: 1.0'f32 else: layer.timeStretch
  (frameNo - layer.startFrame) / stretch

proc layerWorldTransform(layers: seq[LottieLayer]; layer: LottieLayer; frameNo: float32): Matrix =
  var m = identity()
  applyTransform(m, layer.transform, frameNo, layer.autoOrient)
  var pid = layer.parentId
  var guard = 0
  while pid >= 0 and guard < 32:
    let p = findLayerById(layers, pid)
    if p == nil: break
    var pm = identity()
    applyTransform(pm, p.transform, frameNo, p.autoOrient)
    m = pm * m
    pid = p.parentId
    inc guard
  m

proc layerWorldOpacity(layers: seq[LottieLayer]; layer: LottieLayer; frameNo: float32): uint8 =
  var op = int(layerOpacity(layer.transform, frameNo))
  var pid = layer.parentId
  var guard = 0
  while pid >= 0 and guard < 32:
    let p = findLayerById(layers, pid)
    if p == nil: break
    # Null layers are transform-only parents; their opacity must not affect children.
    if p.layerType != ltNull:
      op = int((uint32(op) * uint32(layerOpacity(p.transform, frameNo)) + 0xff'u32) shr 8)
    pid = p.parentId
    inc guard
  uint8(clamp(op, 0, 255))

proc resolveMatteTargets*(layers: seq[LottieLayer]) =
  for i, layer in layers:
    layer.matteTarget = nil
    if layer == nil or layer.matteType == MaskMethod.None: continue
    if layer.mix >= 0:
      layer.matteTarget = findLayerById(layers, layer.mix)
    elif i > 0:
      # Lottie matte target is usually the previous layer in the stack.
      layer.matteTarget = layers[i - 1]

proc applyEffects(layerScene: Scene; layer: LottieLayer; frameNo: float32; world: Matrix) =
  const BLUR_TO_SIGMA = 0.3'f32
  for e in layer.effects:
    if e == nil or not e.enable: continue
    case e.effectType
    of etTint:
      let fx = LottieFxTint(e)
      let black = fx.black.eval(frameNo)
      let white = fx.white.eval(frameNo)
      let intensity = fx.intensity.eval(frameNo)
      discard layerScene.tint(int(black.r * 255.0'f32), int(black.g * 255.0'f32), int(black.b * 255.0'f32),
                              int(white.r * 255.0'f32), int(white.g * 255.0'f32), int(white.b * 255.0'f32),
                              float(intensity))
    of etFill:
      let fx = LottieFxFill(e)
      let c = fx.color.eval(frameNo)
      let op = fx.opacity.eval(frameNo)
      let a = int(255.0'f32 * op) and 0xFF
      discard layerScene.fill(int(c.r * 255.0'f32), int(c.g * 255.0'f32), int(c.b * 255.0'f32), a)
    of etTritone:
      let fx = LottieFxTritone(e)
      let bright = fx.bright.eval(frameNo)
      let midtone = fx.midtone.eval(frameNo)
      let dark = fx.dark.eval(frameNo)
      let blend = clamp(int(fx.blend.eval(frameNo)), 0, 255)
      discard layerScene.tritone([int(dark.r * 255.0'f32), int(dark.g * 255.0'f32), int(dark.b * 255.0'f32)],
                                 [int(midtone.r * 255.0'f32), int(midtone.g * 255.0'f32), int(midtone.b * 255.0'f32)],
                                 [int(bright.r * 255.0'f32), int(bright.g * 255.0'f32), int(bright.b * 255.0'f32)],
                                 blend)
    of etGaussianBlur:
      let fx = LottieFxGaussianBlur(e)
      let sigma = fx.blurness.eval(frameNo) * BLUR_TO_SIGMA
      discard layerScene.gaussianBlur(sigma, fx.direction - 1, fx.wrap, 50)
    of etDropShadow:
      let fx = LottieFxDropShadow(e)
      let c = fx.color.eval(frameNo)
      let op = clamp(int(fx.opacity.eval(frameNo)), 0, 255)
      let sigma = fx.blurness.eval(frameNo) * BLUR_TO_SIGMA
      discard layerScene.dropShadow(int(c.r * 255.0'f32), int(c.g * 255.0'f32), int(c.b * 255.0'f32), op,
                                    fx.angle.eval(frameNo), fx.distance.eval(frameNo), sigma, 50)
    of etStroke:
      if layer.masks.len == 0: continue
      let fx = LottieFxStroke(e)
      let shape = newShape()
      let allMask = fx.allMask.eval(frameNo) != 0
      if allMask:
        for m in layer.masks:
          if m == nil or m.mode == MaskMethod.None: continue
          let path = m.path.eval(frameNo)
          buildPath(shape, path)
      else:
        let idx = fx.mask.eval(frameNo) - 1
        if idx >= 0 and idx < layer.masks.len:
          let m = layer.masks[idx]
          if m != nil and m.mode != MaskMethod.None:
            let path = m.path.eval(frameNo)
            buildPath(shape, path)
      discard shape.transform(world)
      let begin = fx.begin.eval(frameNo) * 0.01'f32
      let endv = fx.`end`.eval(frameNo) * 0.01'f32
      discard shape.trimpath(begin, endv)
      let sop = fx.opacity.eval(frameNo)
      let sa = int(255.0'f32 * sop) and 0xFF
      discard shape.strokeFill(255'u8, 255'u8, 255'u8, uint8(sa))
      discard shape.strokeJoin(StrokeJoin.Round)
      discard shape.strokeCap(StrokeCap.Round)
      let strokeSize = fx.size.eval(frameNo) * 2.0'f32
      discard shape.strokeWidth(strokeSize)
      let col = fx.color.eval(frameNo)
      let cr = uint8(clamp(int(col.r * 255.0'f32), 0, 255))
      let cg = uint8(clamp(int(col.g * 255.0'f32), 0, 255))
      let cb = uint8(clamp(int(col.b * 255.0'f32), 0, 255))
      if cr != 255'u8 or cg != 255'u8 or cb != 255'u8:
        let isShapeLayer = layer.layerType == ltShape
        proc fillShapes(p: Paint) =
          if p == nil: return
          if p of Shape:
            let s = Shape(p)
            if isShapeLayer:
              discard s.strokeWidth(strokeSize)
              discard s.strokeFill(cr, cg, cb, 255'u8)
            discard s.fill(cr, cg, cb, 255'u8)
          elif p of Scene:
            let sc = Scene(p)
            for child in sc.paints:
              fillShapes(child)
        fillShapes(layerScene)
      discard layerScene.mask(shape, MaskMethod.Alpha)
    else:
      discard

proc applyMasks(layerScene: Scene; layer: LottieLayer; frameNo: float32; world: Matrix) =
  if layer.masks.len == 0: return
  var pShape: Shape = nil
  var pMethod: MaskMethod = MaskMethod.None
  var pOpacity: uint8 = 0
  for mask in layer.masks:
    if mask == nil or mask.mode == MaskMethod.None: continue
    let maskMode = mask.mode
    let opacity = mask.opacity.eval(frameNo)
    let expand = mask.expand.eval(frameNo)
    if pShape == nil:
      pShape = newShape()
      let compMethod = if maskMode == MaskMethod.Subtract or maskMode == MaskMethod.InvAlpha: MaskMethod.InvAlpha else: MaskMethod.Alpha
      discard layerScene.mask(pShape, compMethod)
    elif pMethod != maskMode or pOpacity != opacity or (maskMode != MaskMethod.Subtract and maskMode != MaskMethod.Difference):
      let shape = newShape()
      discard pShape.mask(shape, maskMode)
      pShape = shape
    let path = mask.path.eval(frameNo)
    if expand != 0.0'f32:
      let rp = lottiePathToRenderPath(path)
      let orp = offsetPath(rp, expand)
      applyRenderPathToShape(pShape, orp)
    else:
      buildPath(pShape, path)
    discard pShape.fill(255'u8, 255'u8, 255'u8, opacity)
    discard pShape.transform(world)
    pOpacity = opacity
    pMethod = maskMode

proc buildLayer*(comp: LottieComposition; layers: seq[LottieLayer]; layer: LottieLayer; frameNo: float32; root: Scene; parentWorld: Matrix = identity(); depth: int = 0; addToRoot: bool = true): Scene

proc findTextFont(comp: LottieComposition; name: string): LottieFont =
  for f in comp.fonts:
    if f != nil and f.name == name:
      return f
  nil

proc searchGlyph(font: LottieFont; p: string; pos: int; caps: uint8; capScale: var float32): LottieGlyph =
  capScale = 1.0'f32
  if pos >= p.len: return nil
  var ch = p[pos .. pos]
  if caps != 0 and pos < p.len:
    let c = p[pos]
    if c >= 'a' and c <= 'z':
      ch = $(char(ord(c) - ord('a') + ord('A')))
      if caps == 2: capScale = 0.7'f32
  for g in font.chars:
    if g == nil: continue
    let gl = max(1, int(g.len))
    if pos + gl <= p.len:
      let seg = p[pos ..< pos + gl]
      if g.code == seg or g.code == ch:
        return g
    if g.code == ch:
      return g
  nil

proc appendGlyphPath(shape: Shape; glyph: LottieGlyph; frameNo: float32) =
  for child in glyph.shapes:
    if child == nil: continue
    if child.objType == otGroup:
      let grp = LottieGroup(child)
      for gc in grp.children:
        if gc != nil and gc.objType == otPath:
          let po = LottiePathObj(gc)
          let path = po.path.eval(frameNo)
          buildPath(shape, path)
    elif child.objType == otPath:
      let po = LottiePathObj(child)
      let path = po.path.eval(frameNo)
      buildPath(shape, path)

type
  FollowPathState = object
    cmds: seq[PathCommand]
    pts: seq[Point]
    idxCmd: int
    idxPt: int
    startPt: int
    totalLen: float32
    currentLen: float32

proc fpRewind(fp: var FollowPathState) =
  fp.idxCmd = 0
  fp.idxPt = 0
  fp.startPt = 0
  fp.currentLen = 0.0'f32

proc fpShift(fp: var FollowPathState) =
  if fp.idxCmd >= fp.cmds.len: return
  case fp.cmds[fp.idxCmd]
  of PathCommand.MoveTo:
    fp.startPt = fp.idxPt
    inc fp.idxPt
  of PathCommand.LineTo:
    inc fp.idxPt
  of PathCommand.CubicTo:
    fp.idxPt += 3
  of PathCommand.Close:
    discard
  inc fp.idxCmd

proc fpLength(fp: FollowPathState): float32 =
  if fp.idxCmd >= fp.cmds.len: return 0.0'f32
  case fp.cmds[fp.idxCmd]
  of PathCommand.MoveTo: 0.0'f32
  of PathCommand.LineTo:
    if fp.idxPt <= 0 or fp.idxPt >= fp.pts.len: 0.0'f32 else: length(fp.pts[fp.idxPt - 1], fp.pts[fp.idxPt])
  of PathCommand.CubicTo:
    if fp.idxPt <= 0 or fp.idxPt + 2 >= fp.pts.len: 0.0'f32
    else: length(initBezier(fp.pts[fp.idxPt - 1], fp.pts[fp.idxPt], fp.pts[fp.idxPt + 1], fp.pts[fp.idxPt + 2]))
  of PathCommand.Close:
    if fp.idxPt <= 0 or fp.startPt >= fp.pts.len: 0.0'f32 else: length(fp.pts[fp.idxPt - 1], fp.pts[fp.startPt])

proc fpSplit(fp: FollowPathState; dLen, lenSearched: float32; angle: var float32): Point =
  if fp.idxCmd >= fp.cmds.len: return pt(0,0)
  case fp.cmds[fp.idxCmd]
  of PathCommand.MoveTo:
    angle = 0.0'f32
    return pt(0,0)
  of PathCommand.LineTo:
    if fp.idxPt <= 0 or fp.idxPt >= fp.pts.len: return pt(0,0)
    let dp = fp.pts[fp.idxPt] - fp.pts[fp.idxPt - 1]
    angle = arctan2(dp.y, dp.x)
    return pt(0,0)
  of PathCommand.CubicTo:
    if fp.idxPt <= 0 or fp.idxPt + 2 >= fp.pts.len: return pt(0,0)
    let bz = initBezier(fp.pts[fp.idxPt - 1], fp.pts[fp.idxPt], fp.pts[fp.idxPt + 1], fp.pts[fp.idxPt + 2])
    let t = bz.at(lenSearched - fp.currentLen, dLen)
    angle = degToRad(bz.angle(t))
    return bz.at(t)
  of PathCommand.Close:
    if fp.idxPt <= 0 or fp.startPt >= fp.pts.len: return pt(0,0)
    let dp = fp.pts[fp.startPt] - fp.pts[fp.idxPt - 1]
    angle = arctan2(dp.y, dp.x)
    return pt(0,0)

proc fpPrepare(fp: var FollowPathState; layer: LottieLayer; frameNo, textScale: float32): float32 =
  ## Prepare follow path from mask; returns firstMargin in scaled space.
  fp.cmds = @[]
  fp.pts = @[]
  fp.totalLen = 0.0'f32
  fpRewind(fp)
  if layer == nil: return 0.0'f32
  if layer.children.len == 0: return 0.0'f32
  let obj = layer.children[0]
  if obj == nil or obj.objType != otText: return 0.0'f32
  let text = LottieTextObj(obj)
  if text.followPath == nil: return 0.0'f32
  let f = text.followPath
  let maskIdx = f.mask
  if maskIdx < 0 or maskIdx >= layer.masks.len: return 0.0'f32
  let mask = layer.masks[maskIdx]
  if mask == nil: return 0.0'f32
  let lp = mask.path.eval(frameNo)
  var rp = lottiePathToRenderPath(lp)
  if textScale != 0.0'f32 and textScale != 1.0'f32:
    var sm = identity()
    scale(sm, pt(1.0'f32 / textScale, 1.0'f32 / textScale))
    for i in 0 ..< rp.pts.len:
      rp.pts[i] = rp.pts[i] * sm
  fp.cmds = rp.cmds
  fp.pts = rp.pts
  fp.totalLen = pathLength(fp.cmds, fp.pts)
  fpRewind(fp)
  f.firstMargin.eval(frameNo) / (if textScale != 0.0'f32: textScale else: 1.0'f32)

proc fpPosition(fp: var FollowPathState; lenSearched: float32; angle: var float32): Point =
  if fp.cmds.len == 0 or fp.pts.len == 0:
    angle = 0.0'f32
    return pt(0,0)
  let closed = fp.cmds.len > 0 and fp.cmds[fp.cmds.len - 1] == PathCommand.Close
  var lenS = lenSearched
  # before start
  if lenS <= 0.0'f32:
    if closed:
      if fp.totalLen > 0.0'f32:
        while lenS < 0.0'f32: lenS += fp.totalLen
    else:
      if fp.idxCmd >= fp.cmds.len - 1:
        return if fp.startPt < fp.pts.len: fp.pts[fp.startPt] else: pt(0,0)
      let nextCmd = fp.cmds[fp.idxCmd + 1]
      case nextCmd
      of PathCommand.LineTo:
        if fp.idxPt + 1 < fp.pts.len:
          let dp = fp.pts[fp.idxPt + 1] - fp.pts[fp.idxPt]
          angle = arctan2(dp.y, dp.x)
          return pt(fp.pts[fp.idxPt].x + lenS * cos(angle), fp.pts[fp.idxPt].y + lenS * sin(angle))
      of PathCommand.CubicTo:
        if fp.idxPt + 3 < fp.pts.len:
          let bz = initBezier(fp.pts[fp.idxPt], fp.pts[fp.idxPt + 1], fp.pts[fp.idxPt + 2], fp.pts[fp.idxPt + 3])
          angle = degToRad(bz.angle(0.0001'f32))
          return pt(fp.pts[fp.idxPt].x + lenS * cos(angle), fp.pts[fp.idxPt].y + lenS * sin(angle))
      else:
        angle = 0.0'f32
        return if fp.startPt < fp.pts.len: fp.pts[fp.startPt] else: pt(0,0)
  # beyond end
  if lenS >= fp.totalLen and fp.totalLen > 0.0'f32:
    if closed:
      while lenS > fp.totalLen: lenS -= fp.totalLen
    else:
      while fp.idxCmd < fp.cmds.len - 1: fpShift(fp)
      let lenOver = lenS - fp.totalLen
      if fp.idxCmd < fp.cmds.len:
        case fp.cmds[fp.idxCmd]
        of PathCommand.MoveTo:
          angle = 0.0'f32
          return if fp.idxPt < fp.pts.len: fp.pts[fp.idxPt] else: pt(0,0)
        of PathCommand.LineTo:
          if fp.idxPt > 0 and fp.idxPt < fp.pts.len:
            let dp = fp.pts[fp.idxPt] - fp.pts[fp.idxPt - 1]
            angle = arctan2(dp.y, dp.x)
            return pt(fp.pts[fp.idxPt].x + lenOver * cos(angle), fp.pts[fp.idxPt].y + lenOver * sin(angle))
        of PathCommand.CubicTo:
          if fp.idxPt > 0 and fp.idxPt + 2 < fp.pts.len:
            let bz = initBezier(fp.pts[fp.idxPt - 1], fp.pts[fp.idxPt], fp.pts[fp.idxPt + 1], fp.pts[fp.idxPt + 2])
            angle = degToRad(bz.angle(0.999'f32))
            return pt(fp.pts[fp.idxPt + 2].x + lenOver * cos(angle), fp.pts[fp.idxPt + 2].y + lenOver * sin(angle))
        of PathCommand.Close:
          if fp.idxPt > 0 and fp.startPt < fp.pts.len:
            let dp = fp.pts[fp.startPt] - fp.pts[fp.idxPt - 1]
            angle = arctan2(dp.y, dp.x)
            return pt(fp.pts[fp.idxPt - 1].x + lenOver * cos(angle), fp.pts[fp.idxPt - 1].y + lenOver * sin(angle))
      return pt(0,0)

  if lenS < fp.currentLen:
    fpRewind(fp)
  while fp.idxCmd < fp.cmds.len:
    let dLen = fpLength(fp)
    if fp.currentLen + dLen < lenS:
      fpShift(fp)
      fp.currentLen += dLen
      continue
    let p = fpSplit(fp, dLen, lenS, angle)
    # for LineTo/Close/MoveTo split returns pt(0,0), compute by interpolation
    if fp.cmds[fp.idxCmd] == PathCommand.LineTo and fp.idxPt > 0 and fp.idxPt < fp.pts.len:
      let p0 = fp.pts[fp.idxPt - 1]; let p1 = fp.pts[fp.idxPt]
      let t = if dLen > 0.0'f32: (lenS - fp.currentLen) / dLen else: 0.0'f32
      return pt(p0.x + (p1.x-p0.x)*t, p0.y + (p1.y-p0.y)*t)
    if fp.cmds[fp.idxCmd] == PathCommand.Close and fp.idxPt > 0 and fp.startPt < fp.pts.len:
      let p0 = fp.pts[fp.idxPt - 1]; let p1 = fp.pts[fp.startPt]
      let t = if dLen > 0.0'f32: (lenS - fp.currentLen) / dLen else: 0.0'f32
      return pt(p0.x + (p1.x-p0.x)*t, p0.y + (p1.y-p0.y)*t)
    if fp.cmds[fp.idxCmd] == PathCommand.MoveTo:
      return if fp.startPt < fp.pts.len: fp.pts[fp.startPt] else: pt(0,0)
    return p
  pt(0,0)

proc buildTextLayer(comp: LottieComposition; layers: seq[LottieLayer]; layer: LottieLayer; frameNo: float32; world: Matrix; op: uint8): Scene =
  result = newScene()
  discard result.opacity(op)
  if layer.children.len == 0: return
  let obj = layer.children[0]
  if obj == nil or obj.objType != otText: return
  let text = LottieTextObj(obj)
  if text.doc == nil: return
  let doc = text.doc.eval(frameNo)
  if doc.text.len == 0: return
  let font = findTextFont(comp, doc.name)
  if font == nil:
    comp.warnings.add("text layer '" & layer.name & "': missing font '" & doc.name & "'")
    return
  if font.origin != 0 or font.chars.len == 0:
    comp.warnings.add("text layer '" & layer.name & "': unsupported font origin/chars for '" & doc.name & "'")
    return

  let textScale = doc.size / 100.0'f32
  if textScale <= 0.0'f32: return
  var cursorX = 0.0'f32
  let baseY = -font.ascent + doc.shift / textScale
  # follow path
  var fp: FollowPathState
  var hasFollow = false
  var firstMargin = 0.0'f32
  var perpendicular = false
  if text.followPath != nil and text.followPath.mask >= 0 and text.followPath.mask < layer.masks.len:
    hasFollow = true
    perpendicular = text.followPath.perpendicular
    firstMargin = fpPrepare(fp, layer, frameNo, textScale)
  var pos = 0
  while pos < doc.text.len:
    let c = doc.text[pos]
    if c == '\r' or c == '\n' or ord(c) == 3:
      inc pos
      continue
    var capScale = 1.0'f32
    let glyph = searchGlyph(font, doc.text, pos, doc.caps, capScale)
    if glyph == nil:
      inc pos
      continue
    let adv = (glyph.width + doc.tracking) * capScale
    let shape = newShape()
    discard shape.reset()
    appendGlyphPath(shape, glyph, frameNo)
    let cr = uint8(clamp(int(doc.color.r * 255.0'f32 + 0.5'f32), 0, 255))
    let cg = uint8(clamp(int(doc.color.g * 255.0'f32 + 0.5'f32), 0, 255))
    let cb = uint8(clamp(int(doc.color.b * 255.0'f32 + 0.5'f32), 0, 255))
    discard shape.fill(cr, cg, cb, 255'u8)
    if doc.strokeWidth > 0.0'f32:
      let sr = uint8(clamp(int(doc.strokeColor.r * 255.0'f32 + 0.5'f32), 0, 255))
      let sg = uint8(clamp(int(doc.strokeColor.g * 255.0'f32 + 0.5'f32), 0, 255))
      let sb = uint8(clamp(int(doc.strokeColor.b * 255.0'f32 + 0.5'f32), 0, 255))
      discard shape.strokeWidth(doc.strokeWidth / textScale)
      discard shape.strokeFill(sr, sg, sb, 255'u8)
      discard shape.strokeJoin(StrokeJoin.Round)
      if doc.strokeBelow:
        discard shape.order(false)
      else:
        discard shape.order(true)
    var m = identity()
    if hasFollow:
      var angle = 0.0'f32
      let widthHalf = glyph.width * 0.5'f32
      let pth = fpPosition(fp, cursorX + widthHalf + firstMargin, angle)
      let sc2 = textScale * capScale
      m.e11 = sc2; m.e22 = sc2
      if perpendicular:
        let ca = cos(angle); let sa = sin(angle)
        m.e11 = sc2 * ca; m.e12 = -sc2 * sa
        m.e21 = sc2 * sa; m.e22 = sc2 * ca
        m.e13 = pth.x * textScale - widthHalf * m.e11
        m.e23 = pth.y * textScale - widthHalf * m.e21
      else:
        m.e13 = (pth.x - widthHalf) * textScale
        m.e23 = pth.y * textScale
      let finalM = world * m
      discard shape.transform(finalM)
    else:
      translate(m, pt(cursorX, baseY))
      scale(m, pt(textScale * capScale, textScale * capScale))
      let finalM = world * m
      discard shape.transform(finalM)
    discard result.add(shape)
    cursorX += adv
    let step = max(1, int(glyph.len))
    pos += step

proc buildLayer*(comp: LottieComposition; layers: seq[LottieLayer]; layer: LottieLayer; frameNo: float32; root: Scene; parentWorld: Matrix = identity(); depth: int = 0; addToRoot: bool = true): Scene =
  if layer == nil or layer.hidden: return nil
  if addToRoot and layer.matteSrc: return nil
  if frameNo < layer.inPoint or frameNo >= layer.outPoint: return nil
  if layer.layerType == ltNull or layer.layerType == ltAudio: return nil
  if depth > 32: return nil

  let world = parentWorld * layerWorldTransform(layers, layer, frameNo)
  let op = layerWorldOpacity(layers, layer, frameNo)

  proc finalizeLayerScene(layerScene: Scene): Scene =
    if layerScene == nil: return nil
    # Matte first (C++ updateMatte before updateMasks), then masks with wrap if needed.
    if layer.matteType != MaskMethod.None and layer.matteTarget != nil:
      let matteScene = buildLayer(comp, layers, layer.matteTarget, frameNo, root, parentWorld, depth + 1, addToRoot = false)
      if matteScene != nil:
        discard layerScene.mask(matteScene, layer.matteType)
      elif layer.matteType == MaskMethod.Alpha or layer.matteType == MaskMethod.Luma:
        return nil
    var outScene = layerScene
    if layer.masks.len > 0:
      if layer.matteTarget != nil or layer.layerType == ltPrecomp:
        let wrap = newScene()
        discard wrap.add(layerScene)
        outScene = wrap
      applyMasks(outScene, layer, frameNo, world)
    if layer.blendMode != BlendMethod.Normal:
      discard outScene.blend(layer.blendMode)
    if layer.effects.len > 0:
      applyEffects(outScene, layer, frameNo, world)
    if addToRoot:
      discard root.add(outScene)
    outScene

  if layer.layerType == ltPrecomp:
    let asset = findAsset(comp, layer.refId)
    if asset == nil: return nil
    let precompScene = newScene()
    discard precompScene.opacity(op)
    let remapped = remapFrame(comp, layer, frameNo)
    resolveMatteTargets(asset.layers)
    for i in countdown(asset.layers.len - 1, 0):
      discard buildLayer(comp, asset.layers, asset.layers[i], remapped, precompScene, world, depth + 1)
    return finalizeLayerScene(precompScene)

  if layer.layerType == ltSolid:
    let layerScene = newScene()
    discard layerScene.opacity(op)
    let sh = newShape()
    discard sh.appendRect(0, 0, layer.w, layer.h)
    let c = layer.solidColor
    discard sh.fill(c.r, c.g, c.b, c.a)
    discard sh.transform(world)
    discard layerScene.add(sh)
    return finalizeLayerScene(layerScene)

  if layer.layerType == ltImage:
    let layerScene = newScene()
    discard layerScene.opacity(op)
    let asset = findAsset(comp, layer.refId)
    if asset != nil and asset.p.len > 0 and not asset.embedded:
      let path = if asset.u.len > 0: comp.resourceDir / asset.u / asset.p else: comp.resourceDir / asset.p
      let pic = newPicture()
      if pic.load(path) == Result.Success:
        if asset.w > 0.0'f32 and asset.h > 0.0'f32:
          discard pic.size(asset.w, asset.h)
        discard pic.transform(world)
        discard layerScene.add(pic)
    return finalizeLayerScene(layerScene)

  if layer.layerType == ltText:
    let textScene = buildTextLayer(comp, layers, layer, frameNo, world, op)
    return finalizeLayerScene(textScene)

  if layer.layerType != ltShape: return nil
  let layerScene = newScene()
  discard layerScene.opacity(op)
  var ctx = identityCtx()
  ctx.transform = world
  ctx.opacity = 255
  let g = LottieGroup(objType: otGroup, children: layer.children)
  buildGroup(g, frameNo, layerScene, ctx)
  return finalizeLayerScene(layerScene)

proc update*(b: LottieBuilder; frameNo: float32; targetW = 0.0'f32; targetH = 0.0'f32): bool =
  ## Rebuilds the root scene for the given frame. MVP: full rebuild.
  ## If targetW/H are provided, scales composition (comp.w/h) to fit target.
  b.root = newScene()
  let tw = if targetW > 0.0'f32: targetW else: b.comp.w
  let th = if targetH > 0.0'f32: targetH else: b.comp.h
  let clip = newShape()
  discard clip.appendRect(0, 0, tw, th)
  discard b.root.clip(clip)
  resolveMatteTargets(b.comp.layers)
  for i in countdown(b.comp.layers.len - 1, 0):
    discard buildLayer(b.comp, b.comp.layers, b.comp.layers[i], frameNo, b.root)
  if tw != b.comp.w or th != b.comp.h:
    let sx = tw / b.comp.w
    let sy = th / b.comp.h
    var m = identity()
    scale(m, pt(sx, sy))
    discard b.root.transform(m)
  true

proc updateTime*(b: LottieBuilder; t: float32; targetW = 0.0'f32; targetH = 0.0'f32): bool =
  let frameNo = t * b.comp.frameRate
  b.update(frameNo, targetW, targetH)
