## Lottie builder (Phase 2 MVP): lower Lottie model to ThorVG scene.
## No expressions, no masks/mattes/precomps/repeaters/trimpath/gradients yet.

import std/[math, os]
import ../../core/[types, geom, fill, path]
import ../../renderer/[paint, shape, scene, picture]
import ../model/[common, model, property]

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
    hasTrim*: bool
    roundCorner*: float32
    zigzagAmp*: float32
    zigzagFreq*: float32
    zigzagPoint*: int
    hasZigzag*: bool
    puckerBloat*: float32

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
  # c.r/g/b are 0..1
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
    # if tangents are zero, lineTo
    let z1 = abs(c1.x-p0.x) < 0.0001'f32 and abs(c1.y-p0.y) < 0.0001'f32
    let z2 = abs(c2.x-p1.x) < 0.0001'f32 and abs(c2.y-p1.y) < 0.0001'f32
    if z1 and z2:
      discard s.lineTo(p1.x, p1.y)
    else:
      discard s.cubicTo(c1.x, c1.y, c2.x, c2.y, p1.x, p1.y)
  if p.closed:
    discard s.close()

proc buildPolystar(s: Shape; pos: LottiePoint; outerR, innerR, outerRound, innerRound, rotDeg, ptsF: float32; starType: int) =
  let n = max(3, int(round(ptsF)))
  let rot = deg2rad(rotDeg - 90.0'f32)
  let step = MathPi / float32(n)
  var angle = rot
  var first = true
  let isStar = starType == 1
  let count = if isStar: n * 2 else: n
  for i in 0 ..< count:
    let useOuter = (not isStar) or (i mod 2 == 0)
    let r = if useOuter: outerR else: innerR
    let x = pos.x + r * cos(angle)
    let y = pos.y + r * sin(angle)
    if first:
      discard s.moveTo(x, y)
      first = false
    else:
      discard s.lineTo(x, y)
    angle += step
  discard s.close()

proc toColorStops(stops: seq[LottieGradientStop]; opacity: uint8): seq[ColorStop] =
  result = @[]
  for st in stops:
    let oa = clamp(st.alpha, 0.0'f32, 1.0'f32)
    let a = uint8(clamp(int(float32(opacity) * oa + 0.5'f32), 0, 255))
    result.add(ColorStop(
      offset: clamp(st.offset, 0.0'f32, 1.0'f32),
      r: uint8(clamp(int(st.color.r * 255.0'f32 + 0.5'f32), 0, 255)),
      g: uint8(clamp(int(st.color.g * 255.0'f32 + 0.5'f32), 0, 255)),
      b: uint8(clamp(int(st.color.b * 255.0'f32 + 0.5'f32), 0, 255)),
      a: a))

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
  f.stops = toColorStops(gf.stops, op)
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
  f.stops = toColorStops(gs.stops, op)
  f

proc normTrim(v: float32): float32 =
  ## normalize trim value (percent+offset already applied) to 0..1 range with wrapping
  var x = v / 100.0'f32
  if x >= 0.0'f32 and x <= 1.0'f32: return x
  x = x - floor(x)
  if x < 0.0'f32: x += 1.0'f32
  if x == 0.0'f32: x = 1.0'f32
  x

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
  if ctx.hasTrim:
    let off = ctx.trimOffset / 360.0'f32 * 100.0'f32
    var b = normTrim(ctx.trimStart + off)
    var e = normTrim(ctx.trimEnd + off)
    # skip no-op trim
    if not (b == 0.0'f32 and e == 1.0'f32):
      discard s.trimpath(b, e, ctx.trimSimultaneous)
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
  discard sh.appendRect(pos.x - sz.x/2.0'f32, pos.y - sz.y/2.0'f32, sz.x, sz.y, r, r)
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

proc roundPath(inPath: RenderPath; r: float32): RenderPath =
  if r <= 0.0'f32 or inPath.cmds.len == 0: return inPath
  result = RenderPath(cmds: @[], pts: @[])
  result.cmds.setLen(0)
  result.pts.setLen(0)
  var startIndex = 0
  var rounded = false
  var roundTo = Point(x:0, y:0)
  var iCmds = 0
  var iPts = 0
  while iCmds < inPath.cmds.len:
    let cmd = inPath.cmds[iCmds]
    case cmd
    of PathCommand.MoveTo:
      startIndex = result.pts.len
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
          elif nextCmd == PathCommand.Close and startIndex + 2 < inPath.pts.len:
            roundTo = roundLineCorner(result, prev, curr, inPath.pts[startIndex + 2], r)
            if startIndex + 1 < result.pts.len and zero(result.pts[startIndex] - result.pts[startIndex + 1]):
              result.pts[startIndex + 1] = result.pts[^1]
            result.pts[startIndex] = result.pts[^1]
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
  var local = ctx
  # collect group transform and style (fills/strokes/tr). Lottie order varies; MVP collects all.
  for child in g.children:
    if child == nil: continue
    if child of LottieTransform:
      let t = LottieTransform(child)
      var m = local.transform
      applyTransform(m, t, frameNo)
      local.transform = m
      let op = layerOpacity(t, frameNo)
      local.opacity = uint8((int(local.opacity) * int(op)) div 255)
    elif child of LottieFillObj:
      let f = LottieFillObj(child)
      if not f.hidden:
        let c = f.color.eval(frameNo)
        let o = f.opacity.eval(frameNo)
        local.fillColor = toRgba(c, o)
        local.hasFill = true
        local.fillRule = if f.fillRule == 2: FillRule.EvenOdd else: FillRule.NonZero
    elif child of LottieStrokeObj:
      let st = LottieStrokeObj(child)
      if not st.hidden:
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
    elif child of LottieGradientFillObj:
      let gf = LottieGradientFillObj(child)
      if not gf.hidden:
        local.fillGrad = makeGradient(gf, frameNo)
        local.hasFillGrad = true
        local.hasFill = false
        local.fillRule = if gf.fillRule == 2: FillRule.EvenOdd else: FillRule.NonZero
    elif child of LottieGradientStrokeObj:
      let gs = LottieGradientStrokeObj(child)
      if not gs.hidden:
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
    elif child of LottieTrimpathObj:
      let tm = LottieTrimpathObj(child)
      if not tm.hidden:
        let off = tm.offset.eval(frameNo) / 360.0'f32 * 100.0'f32
        var nb = normTrim(tm.start.eval(frameNo) + off)
        var ne = normTrim(tm.`end`.eval(frameNo) + off)
        if local.hasTrim:
          # compose into existing trim range (C++ LottieBuilder::updateTrimpath)
          let curOff = local.trimOffset / 360.0'f32 * 100.0'f32
          let cb = normTrim(local.trimStart + curOff)
          let ce = normTrim(local.trimEnd + curOff)
          let len = abs(cb - ce)
          local.trimStart = (len * nb + cb) * 100.0'f32
          local.trimEnd = (len * ne + cb) * 100.0'f32
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
        local.roundCorner = rd.radius.eval(frameNo)
    elif child of LottieZigZagObj:
      let zz = LottieZigZagObj(child)
      if not zz.hidden:
        local.hasZigzag = true
        local.zigzagAmp = zz.amplitude.eval(frameNo)
        local.zigzagFreq = zz.frequency.eval(frameNo)
        local.zigzagPoint = zz.pointType
    elif child of LottiePuckerBloatObj:
      let pb = LottiePuckerBloatObj(child)
      if not pb.hidden:
        local.puckerBloat = pb.amount.eval(frameNo)
  var acc = newShape()
  var accHas = false
  proc flushAcc() =
    if not accHas: return
    if local.puckerBloat != 0.0'f32:
      acc.rs.path = puckerBloatPath(acc.rs.path, local.puckerBloat)
    if local.hasZigzag and local.zigzagAmp != 0.0'f32 and local.zigzagFreq > 0.0'f32:
      acc.rs.path = applyZigZag(acc.rs.path, local.zigzagAmp, local.zigzagFreq, local.zigzagPoint)
    applyStyle(acc, local)
    discard acc.transform(local.transform)
    discard parentScene.add(acc)
    acc = newShape()
    accHas = false
  for child in g.children:
    if child == nil or child.hidden: continue
    if child of LottieGroup:
      flushAcc()
      buildGroup(LottieGroup(child), frameNo, parentScene, local)
    elif child of LottiePathObj:
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
      let r = LottieRectObj(child)
      let rr = max(r.radius.eval(frameNo), local.roundCorner)
      let pos = r.position.eval(frameNo)
      let sz = r.size.eval(frameNo)
      discard acc.appendRect(pos.x - sz.x/2.0'f32, pos.y - sz.y/2.0'f32, sz.x, sz.y, rr, rr)
      accHas = true
    elif child of LottieEllipseObj:
      let e = LottieEllipseObj(child)
      let pos = e.position.eval(frameNo)
      let sz = e.size.eval(frameNo)
      if local.roundCorner > 0.0'f32:
        let tmp = newShape()
        discard tmp.appendCircle(pos.x, pos.y, sz.x/2.0'f32, sz.y/2.0'f32)
        tmp.rs.path = roundPath(tmp.rs.path, local.roundCorner)
        acc.rs.path.cmds.add(tmp.rs.path.cmds)
        acc.rs.path.pts.add(tmp.rs.path.pts)
      else:
        discard acc.appendCircle(pos.x, pos.y, sz.x/2.0'f32, sz.y/2.0'f32)
      accHas = true
    elif child of LottiePolystarObj:
      let ps = LottiePolystarObj(child)
      if local.roundCorner > 0.0'f32:
        let tmp = newShape()
        buildPolystar(tmp, ps.position.eval(frameNo), ps.outerRadius.eval(frameNo),
          ps.innerRadius.eval(frameNo), ps.outerRoundness.eval(frameNo), ps.innerRoundness.eval(frameNo),
          ps.rotation.eval(frameNo), ps.points.eval(frameNo), ps.starType)
        tmp.rs.path = roundPath(tmp.rs.path, local.roundCorner)
        acc.rs.path.cmds.add(tmp.rs.path.cmds)
        acc.rs.path.pts.add(tmp.rs.path.pts)
      else:
        buildPolystar(acc, ps.position.eval(frameNo), ps.outerRadius.eval(frameNo),
          ps.innerRadius.eval(frameNo), ps.outerRoundness.eval(frameNo), ps.innerRoundness.eval(frameNo),
          ps.rotation.eval(frameNo), ps.points.eval(frameNo), ps.starType)
      accHas = true
  flushAcc()

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
    op = (op * int(layerOpacity(p.transform, frameNo))) div 255
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

proc applyEffects(layerScene: Scene; layer: LottieLayer; frameNo: float32) =
  const BLUR_TO_SIGMA = 0.3'f32
  for e in layer.effects:
    if e == nil or not e.enable: continue
    case e.effectType
    of etTint:
      let fx = LottieFxTint(e)
      let black = fx.black.eval(frameNo)
      let white = fx.white.eval(frameNo)
      let intensity = fx.intensity.eval(frameNo)
      discard layerScene.tint(int(black.r * 255.0'f32 + 0.5'f32), int(black.g * 255.0'f32 + 0.5'f32), int(black.b * 255.0'f32 + 0.5'f32),
                              int(white.r * 255.0'f32 + 0.5'f32), int(white.g * 255.0'f32 + 0.5'f32), int(white.b * 255.0'f32 + 0.5'f32),
                              float(intensity))
    of etFill:
      let fx = LottieFxFill(e)
      let c = fx.color.eval(frameNo)
      var op = fx.opacity.eval(frameNo)
      if op > 1.0'f32: op = op / 100.0'f32
      let a = clamp(int(op * 255.0'f32 + 0.5'f32), 0, 255)
      discard layerScene.fill(int(c.r * 255.0'f32 + 0.5'f32), int(c.g * 255.0'f32 + 0.5'f32), int(c.b * 255.0'f32 + 0.5'f32), a)
    of etTritone:
      let fx = LottieFxTritone(e)
      let bright = fx.bright.eval(frameNo)
      let midtone = fx.midtone.eval(frameNo)
      let dark = fx.dark.eval(frameNo)
      let blend = clamp(int(fx.blend.eval(frameNo)), 0, 255)
      discard layerScene.tritone([int(dark.r*255+0.5'f32), int(dark.g*255+0.5'f32), int(dark.b*255+0.5'f32)],
                                 [int(midtone.r*255+0.5'f32), int(midtone.g*255+0.5'f32), int(midtone.b*255+0.5'f32)],
                                 [int(bright.r*255+0.5'f32), int(bright.g*255+0.5'f32), int(bright.b*255+0.5'f32)],
                                 blend)
    of etGaussianBlur:
      let fx = LottieFxGaussianBlur(e)
      let sigma = fx.blurness.eval(frameNo) * BLUR_TO_SIGMA
      discard layerScene.gaussianBlur(sigma, fx.direction - 1, fx.wrap, 100)
    of etDropShadow:
      let fx = LottieFxDropShadow(e)
      let c = fx.color.eval(frameNo)
      let op = clamp(int(fx.opacity.eval(frameNo)), 0, 255)
      let sigma = fx.blurness.eval(frameNo) * BLUR_TO_SIGMA
      discard layerScene.dropShadow(int(c.r*255+0.5'f32), int(c.g*255+0.5'f32), int(c.b*255+0.5'f32), op,
                                    fx.angle.eval(frameNo), fx.distance.eval(frameNo), sigma, 100)
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
    # TODO: mask.expand (offset path)
    if pShape == nil:
      pShape = newShape()
      let compMethod = if maskMode == MaskMethod.Subtract or maskMode == MaskMethod.InvAlpha: MaskMethod.InvAlpha else: MaskMethod.Alpha
      discard layerScene.mask(pShape, compMethod)
    elif pMethod != maskMode or pOpacity != opacity or (maskMode != MaskMethod.Subtract and maskMode != MaskMethod.Difference):
      let shape = newShape()
      discard pShape.mask(shape, maskMode)
      pShape = shape
    let path = mask.path.eval(frameNo)
    buildPath(pShape, path)
    discard pShape.fill(255'u8, 255'u8, 255'u8, opacity)
    discard pShape.transform(world)
    pOpacity = opacity
    pMethod = maskMode

proc buildLayer*(comp: LottieComposition; layers: seq[LottieLayer]; layer: LottieLayer; frameNo: float32; root: Scene; parentWorld: Matrix = identity(); depth: int = 0; addToRoot: bool = true): Scene

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
      applyEffects(outScene, layer, frameNo)
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

  if layer.layerType != ltShape: return nil # TODO: image/text
  # Avoid double-applying layer transform opacity: scene gets parent-only opacity,
  # buildGroup applies the layer's own transform opacity via its transform child.
  var parentOp = 255
  var pid = layer.parentId
  var guard = 0
  while pid >= 0 and guard < 32:
    let p = findLayerById(layers, pid)
    if p == nil: break
    parentOp = (parentOp * int(layerOpacity(p.transform, frameNo))) div 255
    pid = p.parentId
    inc guard
  let layerScene = newScene()
  var ctx = identityCtx()
  ctx.transform = world
  discard layerScene.opacity(uint8(clamp(parentOp, 0, 255)))
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
