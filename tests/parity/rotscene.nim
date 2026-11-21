## Scene `pngrot:<file>[@deg,scale,shear,opacity]` of the parity drivers (twin of `rotPicture`
## in `cpp_driver.cpp`): the picture at native size mapped about the canvas center by
## M = T(c) * R(deg) * Shear(x += shear*y) * S(scale) * T(-size/2), i.e. the texmap path.
## Defaults: angle 30, scale 1, shear 0, opacity 255. The matrix is computed in float64
## and rounded to float32 once, exactly like the C++ driver.

import std/[math, strutils]
import thorvg

proc rotPicture*(spec: string, w, h: int): Picture =
  var file = spec
  var par = [30.0, 1.0, 0.0, 255.0]  # deg, scale, shear, opacity
  let at = spec.rfind('@')
  if at >= 0:
    file = spec[0 ..< at]
    let parts = spec[at + 1 .. ^1].split(',')
    for i in 0 ..< min(parts.len, par.len): par[i] = parseFloat(parts[i])
  result = newPicture()
  let r = result.load(file)
  if r != Result.Success:
    raise newException(ThorvgError, "cannot load " & file & ": " & $r)
  var pw, ph = 0.0'f32
  check result.size(pw, ph), "picture size"
  if not (pw > 0.0'f32 and ph > 0.0'f32):
    raise newException(ThorvgError, "bad picture size " & $pw & "x" & $ph)
  let a = par[0] * 3.14159265358979323846 / 180.0
  let c = cos(a)
  let s = sin(a)
  let sc = par[1]
  let k = par[2]
  let e11 = sc * c
  let e12 = sc * (c * k - s)
  let e21 = sc * s
  let e22 = sc * (s * k + c)
  let hw = float64(pw) * 0.5
  let hh = float64(ph) * 0.5
  let m = Matrix(e11: float32(e11), e12: float32(e12),
                 e13: float32(float64(w) * 0.5 - (e11 * hw + e12 * hh)),
                 e21: float32(e21), e22: float32(e22),
                 e23: float32(float64(h) * 0.5 - (e21 * hw + e22 * hh)), e33: 1.0'f32)
  check result.transform(m), "transform"
  check result.opacity(uint8(par[3])), "opacity"
