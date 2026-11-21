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
    trimStart*: float32
    trimEnd*: float32
    trimOffset*: float32
    hasTrim*: bool
    roundCorner*: float32
    zigzagAmp*: float32
    zigzagFreq*: float32
    zigzagPoint*: int
    hasZigzag*: bool

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
    trimStart: 0.0'f32,
    trimEnd: 100.0'f32,
    trimOffset: 0.0'f32,
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

proc applyTransform(m: var Matrix; t: LottieTransform; frameNo: float32) =
  if t == nil: return
  let pos = evalPosition(t, frameNo)
  let anchor = t.anchor.eval(frameNo)
  let sc = evalScale(t, frameNo)
  let rot = evalRotation(t, frameNo)
  # Lottie: translate(pos) * rotate(rot) * scale(scale/100) * translate(-anchor)
  var mt = identity()
  translate(mt, pt(pos.x, pos.y))
  if rot != 0.0'f32: rotate(mt, rot)
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
  elif ctx.hasStroke and ctx.strokeWidth > 0.0'f32:
    discard s.strokeWidth(ctx.strokeWidth)
    discard s.strokeFill(ctx.strokeColor.r, ctx.strokeColor.g, ctx.strokeColor.b, ctx.strokeColor.a)
    discard s.strokeCap(ctx.strokeCap)
    discard s.strokeJoin(ctx.strokeJoin)
    discard s.strokeMiterlimit(ctx.strokeMiter)
  if ctx.hasTrim:
    let off = ctx.trimOffset / 360.0'f32 * 100.0'f32
    var b = normTrim(ctx.trimStart + off)
    var e = normTrim(ctx.trimEnd + off)
    # skip no-op trim
    if not (b == 0.0'f32 and e == 1.0'f32):
      discard s.trimpath(b, e, true)
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
    elif child of LottieTrimpathObj:
      let tm = LottieTrimpathObj(child)
      if not tm.hidden:
        local.trimStart = tm.start.eval(frameNo)
        local.trimEnd = tm.`end`.eval(frameNo)
        local.trimOffset = tm.offset.eval(frameNo)
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
  var acc = newShape()
  var accHas = false
  proc flushAcc() =
    if not accHas: return
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
      discard acc.appendCircle(pos.x, pos.y, sz.x/2.0'f32, sz.y/2.0'f32)
      accHas = true
    elif child of LottiePolystarObj:
      let ps = LottiePolystarObj(child)
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
  let tr = layer.timeRemap.eval(frameNo)
  if layer.timeRemap.frames.len > 0 or tr >= 0.0'f32:
    return frameAtTime(comp, tr)
  let stretch = if layer.timeStretch == 0.0'f32: 1.0'f32 else: layer.timeStretch
  (frameNo - layer.startFrame) / stretch

proc layerWorldTransform(layers: seq[LottieLayer]; layer: LottieLayer; frameNo: float32): Matrix =
  var m = identity()
  applyTransform(m, layer.transform, frameNo)
  var pid = layer.parentId
  var guard = 0
  while pid >= 0 and guard < 32:
    let p = findLayerById(layers, pid)
    if p == nil: break
    var pm = identity()
    applyTransform(pm, p.transform, frameNo)
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
    let asset = findAsset(comp, layer.refId)
    if asset != nil and asset.p.len > 0 and not asset.embedded:
      let path = if asset.u.len > 0: comp.resourceDir / asset.u / asset.p else: comp.resourceDir / asset.p
      let pic = newPicture()
      if pic.load(path) == Result.Success:
        if asset.w > 0.0'f32 and asset.h > 0.0'f32:
          discard pic.size(asset.w, asset.h)
        discard pic.transform(world)
        let layerScene = newScene()
        discard layerScene.opacity(op)
        discard layerScene.add(pic)
        return finalizeLayerScene(layerScene)
    return nil

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
