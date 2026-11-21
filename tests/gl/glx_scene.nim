## GL-only scenes `glx:<name>` (design canvas 200x150), the Nim twin of `buildGlx` in
## `cpp_gl_driver.cpp`: keep both in lock-step (same coordinates, same float32 arithmetic).
## They cover what the CPU suite lacks: the 16 blend modes on shapes and scenes, the 10 mask methods,
## scene effects, 16-stop / conic / focal gradients, thin strokes, trim paths, nested clips and nested
## opacity scenes. Names: blend:<m> sblend:<m> mask:<m> fx:<e> grad:<g> thin trim clip nest nest:mask.

import std/strutils
import thorvg

const
  Blends = [("multiply", BlendMethod.Multiply), ("screen", BlendMethod.Screen),
    ("overlay", BlendMethod.Overlay), ("darken", BlendMethod.Darken),
    ("lighten", BlendMethod.Lighten), ("colordodge", BlendMethod.ColorDodge),
    ("colorburn", BlendMethod.ColorBurn), ("hardlight", BlendMethod.HardLight),
    ("softlight", BlendMethod.SoftLight), ("difference", BlendMethod.Difference),
    ("exclusion", BlendMethod.Exclusion), ("hue", BlendMethod.Hue),
    ("saturation", BlendMethod.Saturation), ("color", BlendMethod.Color),
    ("luminosity", BlendMethod.Luminosity), ("add", BlendMethod.Add)]
  Masks = [("alpha", MaskMethod.Alpha), ("invalpha", MaskMethod.InvAlpha),
    ("luma", MaskMethod.Luma), ("invluma", MaskMethod.InvLuma), ("add", MaskMethod.Add),
    ("subtract", MaskMethod.Subtract), ("intersect", MaskMethod.Intersect),
    ("difference", MaskMethod.Difference), ("lighten", MaskMethod.Lighten),
    ("darken", MaskMethod.Darken)]

proc glxBase(): Shape =
  result = newShape()
  check result.appendRect(10, 10, 180, 130)
  let g = linearGradient(10, 10, 190, 140).withStops(
    colorStop(0.0, 230, 60, 60), colorStop(0.5, 60, 200, 90), colorStop(1.0, 60, 80, 230))
  check result.fill(g)

proc glxTop(dx: float32): Shape =
  result = newShape()
  check result.appendRect(70 + dx, 40, 100, 70, 12, 12)
  let g = linearGradient(70 + dx, 40, 170 + dx, 110).withStops(
    colorStop(0.0, 255, 220, 120), colorStop(1.0, 40, 30, 120, 200))
  check result.fill(g)

proc glxContent(): Scene =
  result = newScene()
  let a = newShape()
  check a.appendCircle(70, 70, 35, 35)
  check a.fill(220, 40, 40)
  let b = newShape()
  check b.appendRect(90, 50, 70, 60)
  check b.fill(40, 60, 220, 230)
  let c = newShape()
  check c.moveTo(30, 120)
  check c.lineTo(170, 30)
  check c.strokeWidth(6)
  check c.strokeFill(250, 250, 250)
  check result.add(a)
  check result.add(b)
  check result.add(c)

func stops16(): seq[ColorStop] =
  for i in 0 ..< 16:
    result.add colorStop(float32(i) / 15'f32, uint8((i * 53) and 255),
      uint8((i * 97 + 40) and 255), uint8((i * 29 + 120) and 255), uint8(255 - (i mod 4) * 20))

proc with16(g: Fill): Fill =
  result = g
  result.stops = stops16()

proc gradScene(c: Canvas, arg: string): bool =
  let s = newShape()
  var g: Fill
  case arg
  of "linear16":
    check s.appendRect(10, 10, 180, 130)
    check s.fill(linearGradient(10, 0, 190, 0).with16())
  of "reflect16":
    check s.appendRect(10, 10, 180, 130)
    g = linearGradient(20, 20, 70, 50).with16()
    g.spread = FillSpread.Reflect
    check s.fill(g)
  of "radial16":
    check s.appendCircle(100, 75, 65, 65)
    check s.fill(radialGradient(100, 75, 60, 90, 70, 10).with16())
  of "radial_repeat":
    check s.appendRect(10, 10, 180, 130)
    g = radialGradient(100, 75, 30, 100, 75, 0).with16()
    g.spread = FillSpread.Repeat
    check s.fill(g)
  of "radial_focal":
    check s.appendRect(10, 10, 180, 130)
    check s.fill(radialGradient(100, 75, 30, 160, 75, 10).withStops(
      colorStop(0.0, 255, 0, 0), colorStop(0.5, 0, 255, 0), colorStop(1.0, 0, 0, 255)))
  of "conic":
    check s.appendRect(10, 10, 180, 130)
    check s.fill(conicGradient(100, 75, 30).withStops(
      colorStop(0.0, 255, 0, 0), colorStop(0.25, 255, 255, 0), colorStop(0.5, 0, 255, 0),
      colorStop(0.75, 0, 0, 255), colorStop(1.0, 255, 0, 0)))
  of "conic_stroke":
    check s.appendCircle(100, 75, 50, 50)
    check s.strokeWidth(20)
    check s.strokeFill(conicGradient(100, 75, 0).withStops(
      colorStop(0.0, 255, 0, 0), colorStop(0.5, 0, 0, 255, 128), colorStop(1.0, 0, 255, 0)))
  else:
    return false
  check c.add(s)
  true

proc thinScene(c: Canvas) =
  const Widths = [0.1'f32, 0.25, 0.5, 0.75, 0.99, 1.0, 1.5, 2.0]
  for i in 0 ..< 8:
    let s = newShape()
    check s.moveTo(10, 10.5'f32 + float32(i * 8))
    check s.lineTo(90, 10.5'f32 + float32(i * 8))
    check s.strokeWidth(Widths[i])
    check s.strokeFill(20, 20, 20)
    check c.add(s)
    let t = newShape()
    check t.moveTo(110, 10.5'f32 + float32(i * 8))
    check t.lineTo(190, 14.0'f32 + float32(i * 8))
    check t.strokeWidth(Widths[i])
    check t.strokeFill(200, 30, 30, 200)
    check c.add(t)
  let ci = newShape()
  check ci.appendCircle(50, 105, 30, 25)
  check ci.strokeWidth(0.5'f32)
  check ci.strokeFill(0, 0, 0)
  check c.add(ci)
  let r = newShape()
  check r.appendRect(110, 85, 70, 45, 6, 6)
  check r.fill(250, 220, 120)
  check r.strokeWidth(0.8'f32)
  check r.strokeFill(0, 0, 160)
  check c.add(r)

proc trimScene(c: Canvas) =
  let a = newShape()
  check a.appendCircle(55, 75, 40, 40)
  check a.strokeWidth(8)
  check a.strokeFill(200, 40, 40)
  check a.strokeCap(StrokeCap.Round)
  check a.trimpath(0.1'f32, 0.6'f32, true)
  check c.add(a)
  let b = newShape()
  check b.appendRect(110, 30, 70, 90, 8, 8)
  check b.strokeWidth(5)
  check b.strokeFill(20, 100, 200)
  check b.strokeDash([10'f32, 5'f32], 0)
  check b.trimpath(0.8'f32, 0.3'f32, true)
  check c.add(b)

proc clipScene(c: Canvas) =
  let s = newShape()
  check s.appendRect(10, 10, 180, 130)
  check s.fill(linearGradient(10, 10, 190, 140).withStops(
    colorStop(0.0, 255, 80, 0), colorStop(1.0, 0, 80, 255)))
  let cl = newShape()
  check cl.appendCircle(70, 70, 40, 40)
  check cl.appendRect(90, 50, 60, 60)
  check cl.rotate(20)
  check s.clip(cl)
  check c.add(s)
  let sc = newScene()
  let a = newShape()
  check a.appendRect(120, 90, 70, 50)
  check a.fill(30, 160, 60)
  let inner = newShape()
  check inner.appendCircle(150, 115, 30, 30)
  check inner.fill(250, 250, 40, 200)
  let ic = newShape()
  check ic.appendRect(140, 100, 50, 50)
  check inner.clip(ic)
  check sc.add(a)
  check sc.add(inner)
  check sc.opacity(200)
  let oc = newShape()
  check oc.appendCircle(155, 105, 35, 30)
  check sc.clip(oc)
  check c.add(sc)

proc nestScene(c: Canvas, masked: bool) =
  let outer = newScene()
  let inner = newScene()
  let a = newShape()
  check a.appendCircle(80, 75, 40, 40)
  check a.fill(255, 0, 0)
  let b = newShape()
  check b.appendCircle(110, 75, 40, 40)
  check b.fill(0, 0, 255)
  check inner.add(a)
  check inner.add(b)
  check inner.opacity(128)
  let d = newShape()
  check d.appendRect(60, 90, 90, 30)
  check d.fill(0, 200, 0)
  check outer.add(inner)
  check outer.add(d)
  check outer.opacity(200)
  if masked:
    let m = newShape()
    check m.appendCircle(95, 75, 55, 40)
    check m.fill(0, 0, 0, 255)
    check outer.mask(m, MaskMethod.Alpha)
  check c.add(glxBase())
  check c.add(outer)

proc effectScene(c: Canvas, arg: string): bool =
  let sc = glxContent()
  case arg
  of "blur": check sc.gaussianBlur(6.0, 0, 0, 100)
  of "blur_h": check sc.gaussianBlur(4.0, 1, 0, 100)
  of "blur_v": check sc.gaussianBlur(4.0, 2, 0, 100)
  of "blur_q50": check sc.gaussianBlur(10.0, 0, 0, 50)
  of "shadow": check sc.dropShadow(0, 0, 0, 160, 45.0, 10.0, 4.0, 100)
  of "motion": check sc.motionBlur(20.0, 30.0, 100)
  of "fill": check sc.fill(30, 200, 120, 200)
  of "tint": check sc.tint(0, 0, 60, 255, 230, 180, 80.0)
  of "tritone": check sc.tritone([0, 0, 80], [200, 60, 60], [255, 255, 200], 128)
  of "chain":
    check sc.gaussianBlur(3.0, 0, 0, 100)
    check sc.tint(0, 0, 60, 255, 230, 180, 80.0)
  else: return false
  check c.add(sc)
  true

proc buildGlx*(c: Canvas, name: string): bool =
  ## Adds the paints of `glx:<name>` to `c`; false for an unknown name.
  let colon = name.find(':')
  let kind = if colon < 0: name else: name.substr(0, colon - 1)
  let arg = if colon < 0: "" else: name.substr(colon + 1)
  result = true
  case kind
  of "blend":
    for (n, m) in Blends:
      if arg == n:
        let top = glxTop(0)
        check top.blend(m)
        check c.add(glxBase())
        check c.add(top)
        return
    result = false
  of "sblend":
    for (n, m) in Blends:
      if arg == n:
        let sc = newScene()
        check sc.add(glxTop(-30))
        let ci = newShape()
        check ci.appendCircle(120, 90, 40, 40)
        check ci.fill(30, 200, 220, 200)
        check sc.add(ci)
        check sc.blend(m)
        check c.add(glxBase())
        check c.add(sc)
        return
    result = false
  of "mask":
    for (n, k) in Masks:
      if arg == n:
        let bg = newShape()
        check bg.appendRect(0, 0, 200, 150)
        check bg.fill(40, 40, 40)
        let s = newShape()
        check s.appendRect(30, 30, 140, 90)
        check s.fill(linearGradient(30, 30, 170, 120).withStops(
          colorStop(0.0, 255, 200, 40), colorStop(1.0, 40, 120, 255)))
        let m = newShape()
        check m.appendCircle(100, 75, 45, 45)
        check m.fill(radialGradient(100, 75, 45, 100, 75, 0).withStops(
          colorStop(0.0, 255, 255, 255), colorStop(1.0, 60, 30, 90, 90)))
        check s.mask(m, k)
        check c.add(bg)
        check c.add(s)
        return
    result = false
  of "fx": result = effectScene(c, arg)
  of "grad": result = gradScene(c, arg)
  of "thin": thinScene(c)
  of "trim": trimScene(c)
  of "clip": clipScene(c)
  of "nest": nestScene(c, arg == "mask")
  else: result = false
