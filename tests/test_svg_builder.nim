## SVG builder + loader: scene structure and rendered pixels (through `Picture.load`).

import std/[unittest, base64]
import thorvg
import thorvg/renderer/scene

const
  Red = 0xffff0000'u32
  Green = 0xff008000'u32

proc svg(w, h: int, body: string): string =
  "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' " &
  "width='" & $w & "' height='" & $h & "' viewBox='0 0 " & $w & " " & $h & "'>" &
  body & "</svg>"

proc load(data: string): Picture =
  result = newPicture()
  check result.load(data, "svg") == Result.Success

proc attached(data: string): Picture =
  ## Loads and renders once: the picture takes the loader's scene on its first update.
  result = load(data)
  let c = newSwCanvas(8, 8)
  check c.add(result) == Result.Success
  c.render()

proc renderPic(data: string, w, h: int): seq[uint32] =
  let c = newSwCanvas(w, h)
  check c.add(load(data)) == Result.Success
  c.render()
  swSurface(c).data

proc px(d: seq[uint32], w, x, y: int): uint32 = d[y * w + x]

proc alphaOf(p: uint32): uint32 = p shr 24

proc redOf(p: uint32): uint32 = (p shr 16) and 0xff

proc countShapes(s: Scene): int =
  for p in s.paints:
    if p of Scene: result += countShapes(Scene(p))
    elif p of Shape: inc result

proc countScenes(s: Scene): int =
  result = 1
  for p in s.paints:
    if p of Scene: result += countScenes(Scene(p))

suite "svg builder: structure":
  test "size comes from the svg header":
    let pic = load(svg(30, 20, "<rect width='5' height='5'/>"))
    var w, h: float32
    check pic.size(w, h) == Result.Success
    check w == 30.0'f32
    check h == 20.0'f32

  test "group yields a scene with its children":
    let pic = attached(svg(20, 20, "<g><rect width='5' height='5'/><circle cx='10' cy='10' r='3'/></g>"))
    let root = Scene(pic.content)
    check root != nil
    check countShapes(root) == 2
    check countScenes(root) >= 2

  test "display none and zero opacity draw nothing":
    let d = renderPic(svg(20, 20, "<rect width='5' height='5' display='none'/>" &
                                  "<g opacity='0'><rect width='5' height='5'/></g>"), 20, 20)
    for p in d: check p == 0
  test "zero-area viewbox gives an empty scene":
    let pic = newPicture()
    discard pic.load("<svg viewBox='0 0 0 0'><rect width='5' height='5'/></svg>", "svg")
    let c = newSwCanvas(10, 10)
    discard c.add(pic)
    c.render()
    for p in swSurface(c).data: check p == 0

  test "second load of the same data builds an independent scene":
    let d = svg(10, 10, "<rect width='10' height='10' fill='red'/>")
    let a = renderPic(d, 10, 10)
    let b = renderPic(d, 10, 10)
    check a == b

suite "svg builder: pixels":
  test "filled rect":
    let d = renderPic(svg(20, 20, "<rect x='5' y='5' width='10' height='10' fill='red'/>"), 20, 20)
    check px(d, 20, 10, 10) == Red
    check px(d, 20, 2, 2) == 0
    check px(d, 20, 17, 17) == 0

  test "default fill is black":
    let d = renderPic(svg(10, 10, "<rect width='10' height='10'/>"), 10, 10)
    check px(d, 10, 5, 5) == 0xff000000'u32

  test "fill-opacity and opacity":
    let d = renderPic(svg(10, 10, "<rect width='10' height='10' fill='red' fill-opacity='0.5'/>"), 10, 10)
    check alphaOf(px(d, 10, 5, 5)) in 127'u32 .. 128'u32
    let e = renderPic(svg(10, 10, "<rect width='10' height='10' fill='red' opacity='0.5'/>"), 10, 10)
    check alphaOf(px(e, 10, 5, 5)) in 127'u32 .. 128'u32

  test "odd opacity values do not crash":
    let body = "<rect width='10' height='10' fill='red' style='fill-opacity:1e12'/>" &
               "<rect width='10' height='10' fill='red' style='fill-opacity:inf;stroke-opacity:nan'/>"
    let d = renderPic(svg(10, 10, body), 10, 10)
    check d.len == 100

  test "stroke":
    let d = renderPic(svg(20, 20, "<rect x='5' y='5' width='10' height='10' fill='none' " &
                                  "stroke='green' stroke-width='4'/>"), 20, 20)
    check px(d, 20, 5, 10) == Green
    check px(d, 20, 10, 10) == 0

  test "transform":
    let d = renderPic(svg(20, 20, "<rect width='5' height='5' fill='red' transform='translate(10 10)'/>"), 20, 20)
    check px(d, 20, 12, 12) == Red
    check px(d, 20, 2, 2) == 0

  test "linear gradient varies along x":
    let body = "<defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='0'>" &
               "<stop offset='0' stop-color='black'/><stop offset='1' stop-color='red'/>" &
               "</linearGradient></defs><rect width='40' height='10' fill='url(#g)'/>"
    let d = renderPic(svg(40, 10, body), 40, 10)
    check redOf(px(d, 40, 2, 5)) < redOf(px(d, 40, 20, 5))
    check redOf(px(d, 40, 20, 5)) < redOf(px(d, 40, 37, 5))

  test "radial gradient is brighter at the center":
    let body = "<defs><radialGradient id='g' cx='0.5' cy='0.5' r='0.5'>" &
               "<stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/>" &
               "</radialGradient></defs><rect width='40' height='40' fill='url(#g)'/>"
    let d = renderPic(svg(40, 40, body), 40, 40)
    check redOf(px(d, 40, 20, 20)) > redOf(px(d, 40, 2, 20))

  test "clip path":
    let body = "<defs><clipPath id='c'><rect x='0' y='0' width='10' height='20'/></clipPath></defs>" &
               "<rect width='20' height='20' fill='red' clip-path='url(#c)'/>"
    let d = renderPic(svg(20, 20, body), 20, 20)
    check px(d, 20, 5, 10) == Red
    check px(d, 20, 15, 10) == 0

  test "mask hides where the mask is black":
    let body = "<defs><mask id='m'><rect width='10' height='20' fill='white'/></mask></defs>" &
               "<rect width='20' height='20' fill='red' mask='url(#m)'/>"
    let d = renderPic(svg(20, 20, body), 20, 20)
    # a white luma mask is 254/255 opaque in the original too
    check alphaOf(px(d, 20, 5, 10)) >= 253'u32
    check redOf(px(d, 20, 5, 10)) >= 253'u32
    check px(d, 20, 15, 10) == 0

  test "use instantiates a definition at an offset":
    let body = "<defs><rect id='r' width='5' height='5' fill='red'/></defs>" &
               "<use href='#r' x='10' y='10'/>"
    let d = renderPic(svg(20, 20, body), 20, 20)
    check px(d, 20, 12, 12) == Red
    check px(d, 20, 2, 2) == 0

  test "use with xlink:href and symbol":
    let body = "<defs><symbol id='s' viewBox='0 0 5 5'><rect width='5' height='5' fill='red'/></symbol></defs>" &
               "<use xlink:href='#s' x='10' y='10' width='5' height='5'/>"
    let d = renderPic(svg(20, 20, body), 20, 20)
    check px(d, 20, 12, 12) == Red
    check px(d, 20, 2, 2) == 0

  test "nested svg with embedded image data":
    let inner = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 10 10'>" &
                "<rect width='10' height='10' fill='red'/></svg>"
    let body = "<image x='5' y='5' width='10' height='10' href='data:image/svg+xml;base64," &
               encode(inner) & "'/>"
    let d = renderPic(svg(20, 20, body), 20, 20)
    check px(d, 20, 10, 10) == Red
    check px(d, 20, 2, 2) == 0

  test "pattern fill tiles the content":
    let body = "<defs><pattern id='p' width='10' height='10' patternUnits='userSpaceOnUse'>" &
               "<rect width='5' height='10' fill='red'/></pattern></defs>" &
               "<rect width='20' height='10' fill='url(#p)'/>"
    let d = renderPic(svg(20, 10, body), 20, 10)
    check px(d, 20, 2, 5) == Red
    check px(d, 20, 7, 5) == 0
    check px(d, 20, 12, 5) == Red

  test "css style rule applies to elements":
    let body = "<style>.a { fill: red }</style><rect class='a' width='10' height='10'/>"
    let d = renderPic(svg(10, 10, body), 10, 10)
    check px(d, 10, 5, 5) == Red

  test "feGaussianBlur blurs the element and keeps it inside the filter region":
    let body = "<defs><filter id='f' x='-50%' y='-50%' width='200%' height='200%'>" &
               "<feGaussianBlur stdDeviation='3'/></filter></defs>" &
               "<rect x='15' y='15' width='20' height='20' fill='red' filter='url(#f)'/>"
    let d = renderPic(svg(50, 50, body), 50, 50)
    check px(d, 50, 25, 25) == Red             # the core stays opaque
    check alphaOf(px(d, 50, 15, 25)) in 1'u32 .. 254'u32  # the edge is soft
    check alphaOf(px(d, 50, 12, 25)) > 0       # the blur spreads outside the rect
    check px(d, 50, 1, 1) == 0                 # far away stays empty
  test "malformed input fails to load":
    let pic = newPicture()
    check pic.load("not an svg at all", "svg") != Result.Success
