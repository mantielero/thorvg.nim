## Gradient fill description (linear, radial, conic) as a plain value type.
##
## Ported from `src/renderer/tvgFill.h` (`Fill::Impl`, `LinearGradientImpl`,
## `RadialGradientImpl`, `ConicGradientImpl`). The C++ class hierarchy became a
## single object with a `kind` tag: copying a `Fill` copies its stops, so there is
## no `duplicate()`.

import ./[types, geom]

type
  FillKind* {.pure.} = enum
    Linear
    Radial
    Conic

  Fill* = object
    kind*: FillKind
    stops*: seq[ColorStop]
    transform*: Matrix
    spread*: FillSpread
    p1*, p2*: Point        ## Linear: start and end points
    center*: Point         ## Radial, Conic: center
    focal*: Point          ## Radial: focal point
    r*, fr*: float32       ## Radial: end radius, focal radius
    angle*: float32        ## Conic: start angle in degrees

func linearGradient*(x1, y1, x2, y2: float32): Fill =
  Fill(kind: FillKind.Linear, transform: identity(), p1: pt(x1, y1), p2: pt(x2, y2))

func radialGradient*(cx, cy, r, fx, fy, fr: float32): Fill =
  Fill(kind: FillKind.Radial, transform: identity(), center: pt(cx, cy), r: r,
       focal: pt(fx, fy), fr: fr)

func radialGradient*(cx, cy, r: float32): Fill =
  ## Radial gradient whose focal point is the center.
  radialGradient(cx, cy, r, cx, cy, 0)

func conicGradient*(cx, cy, angle: float32): Fill =
  Fill(kind: FillKind.Conic, transform: identity(), center: pt(cx, cy), angle: angle)

func correct*(f: Fill, fx, fy, fr: var float32): bool =
  ## Clamps the focal point inside the end circle and shrinks the focal radius
  ## when needed. False means "too small, treat as a solid fill".
  const precision = 0.02'f32
  if f.r < precision: return false
  var dist = length(f.center - f.focal)
  if f.r - dist < precision:
    var diff = f.center - f.focal
    if dist < precision:
      diff.x = precision
      dist = precision
    let scale = f.r * (1.0'f32 - precision) / dist
    diff *= scale
    dist *= scale
    fx = f.center.x - diff.x
    fy = f.center.y - diff.y
  else:
    fx = f.focal.x
    fy = f.focal.y
  let maxFr = (f.r - dist) * (1.0'f32 - precision)
  fr = if f.fr > maxFr: max(0.0'f32, maxFr) else: f.fr
  true
