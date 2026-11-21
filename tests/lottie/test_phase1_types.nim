import std/math
import thorvg/lottie/model/[common, property]

proc approx(a,b: float32; tol=1e-4'f32): bool = abs(a-b) <= tol

var p3 = newPoint3Prop(lp3(0,0,0))
doAssert approx(p3.value.x, 0)
var cp = newColorProp(LottieColor(r:0,g:0,b:0))
doAssert approx(cp.value.r, 0)

var a: LottiePath
a.pts = @[lp(0,0), lp(10,0)]
a.inTangents = @[lp(0,0), lp(0,0)]
a.outTangents = @[lp(0,0), lp(0,0)]
a.closed = true
var b: LottiePath
b.pts = @[lp(0,10), lp(10,10)]
b.inTangents = @[lp(0,0), lp(0,0)]
b.outTangents = @[lp(0,0), lp(0,0)]
b.closed = true
let m = lerp(a,b,0.5'f32)
doAssert approx(m.pts[0].y, 5.0'f32)
doAssert approx(m.pts[1].y, 5.0'f32)
doAssert m.closed == true
var c: LottiePath
c.pts = @[lp(1,1)]
c.inTangents = @[lp(0,0)]
c.outTangents = @[lp(0,0)]
c.closed = false
let m2 = lerp(a,c,0.5'f32)
doAssert m2.pts.len == 2
echo "ok"
