import std/[unittest, options, os]
import thorvg/core/types
import thorvg/loaders/svg/[nodes, loader_parse]

const DataDir = currentSourcePath().parentDir / "data"

proc load(name: string): SvgLoaderData =
  parseSvg(readFile(DataDir / (name & ".svg")))

proc body(d: SvgLoaderData): SvgNode =
  ## The element tree under the real `<svg>` (the doc node holds it as a nested group).
  d.doc.child[0]

proc rgb(r, g, b: uint8, a: uint8 = 255): RGBA =
  RGBA(r: r, g: g, b: b, a: a)

proc near(a, b: float32, eps = 1e-4'f32): bool =
  abs(a - b) <= eps

proc kinds(n: SvgNode): seq[SvgNodeType] =
  for c in n.child: result.add c.kind

suite "document and header":
  test "doc node wraps the real svg as a group":
    let d = load("shapes_basic")
    check d.status == Result.Success
    check d.doc.kind == SvgNodeType.Doc
    check d.doc.child.len == 1
    check d.body.kind == SvgNodeType.G
    check d.defs == nil
    check load("style_use").defs.kind == SvgNodeType.Defs

  test "size, view box and alignment":
    let d = load("style_use")
    check d.viewFlag == {SvgViewFlag.Width, SvgViewFlag.Height, SvgViewFlag.Viewbox}
    check d.w == 200.0'f32
    check d.h == 120.0'f32
    check d.vbox == Box(x: 0, y: 0, w: 400, h: 240)
    check d.align == AspectRatioAlign.XMidYMid
    check d.meetOrSlice == AspectRatioMeetOrSlice.Meet
    check not d.empty

  test "units and percentages in width/height":
    let d = parseSvg("<svg width='50%' height='10cm'><circle r='1'/></svg>")
    check d.viewFlag == {SvgViewFlag.Height, SvgViewFlag.WidthInPercent}
    check d.w == 0.5'f32
    check near(d.h, 377.95282'f32)

  test "preserveAspectRatio slice":
    let d = parseSvg("<svg viewBox='0 0 10 20' preserveAspectRatio='xMinYMax slice'/>")
    check d.align == AspectRatioAlign.XMinYMax
    check d.meetOrSlice == AspectRatioMeetOrSlice.Slice
    check d.vbox == Box(x: 0, y: 0, w: 10, h: 20)

  test "view box of size 0 means nothing to render":
    let d = parseSvg("<svg viewBox='0 0 0 10'><rect width='1' height='1'/></svg>")
    check d.empty

  test "text without svg is rejected":
    check parseSvg("<g/>").status == Result.InvalidArguments
    check parseSvg("").status == Result.InvalidArguments

  test "graphics before the svg element hang from the doc node, as in the original":
    let d = parseSvg("<rect width='1' height='1'/><svg><circle r='2'/></svg>")
    check d.status == Result.Success
    check d.doc.kinds == @[SvgNodeType.Rect, SvgNodeType.G]
    check d.doc.child[1].kinds == @[SvgNodeType.Circle]

  test "no view box: size comes from the header, then finishLoad takes the doc values":
    var d = parseSvg("<svg width='30' height='40'><rect width='1' height='1'/></svg>")
    check SvgViewFlag.Viewbox notin d.viewFlag
    check d.w == 30.0'f32 and d.h == 40.0'f32
    check d.vbox == Box(x: 0, y: 0, w: 30, h: 40)
    d.doc.doc.vbox = Box(x: 1, y: 2, w: 3, h: 4) # what the scene builder computes
    d.doc.doc.w = 3.0'f32
    d.doc.doc.h = 4.0'f32
    finishLoad(d)
    check d.vbox == Box(x: 1, y: 2, w: 3, h: 4)
    check d.w == 3.0'f32 and d.h == 4.0'f32

  test "finishLoad leaves an explicit view box alone":
    var d = load("style_use")
    finishLoad(d)
    check d.vbox == Box(x: 0, y: 0, w: 400, h: 240)
    check d.w == 200.0'f32

suite "shapes":
  test "basic shapes tree":
    let d = load("shapes_basic")
    check d.body.kinds == @[SvgNodeType.Rect, SvgNodeType.Rect, SvgNodeType.Circle,
        SvgNodeType.Ellipse, SvgNodeType.Line, SvgNodeType.Polyline, SvgNodeType.Polygon,
        SvgNodeType.Polygon]

  test "rect attributes and rx/ry":
    let r = load("shapes_basic").body.child
    check r[0].rect.x == 10.0'f32
    check r[0].rect.w == 50.0'f32
    check r[0].rect.h == 40.0'f32
    check not r[0].rect.hasRx
    check r[0].style.fill.paint.color == rgb(224, 64, 42)
    check r[1].rect.rx == 10.0'f32
    check r[1].rect.ry == 6.0'f32
    check r[1].rect.hasRx and r[1].rect.hasRy
    check r[1].style.fill.paint.color == rgb(40, 120, 220)
    check r[1].style.stroke.width == 2.0'f32
    check not r[1].style.stroke.paint.none
    check r[1].style.stroke.paint.color == rgb(0, 0, 0)

  test "circle, fill-opacity and ellipse":
    let r = load("shapes_basic").body.child
    check r[2].circle == SvgCircleNode(cx: 155, cy: 30, r: 22)
    check r[2].style.fill.opacity == 153
    check SvgFillFlag.Opacity in r[2].style.fill.flags
    check r[2].style.fill.paint.color == rgb(0, 128, 0)
    check r[3].ellipse == SvgEllipseNode(cx: 35, cy: 85, rx: 25, ry: 14)
    check r[3].style.fill.paint.color == rgb(255, 170, 0)

  test "line, polyline, polygon":
    let r = load("shapes_basic").body.child
    check r[4].line == SvgLineNode(x1: 70, y1: 70, x2: 120, y2: 100)
    check r[4].style.stroke.cap == StrokeCap.Round
    check r[5].polygon.pts == @[130'f32, 70, 150, 100, 170, 70, 190, 100]
    check r[5].style.fill.paint.none
    check r[5].style.stroke.join == StrokeJoin.Round
    check r[6].polygon.pts.len == 10
    check r[6].style.fill.fillRule == FillRule.EvenOdd
    check r[7].style.opacity == 128

  test "path data is kept verbatim":
    let d = load("path_arcs")
    check d.body.child.len > 0
    for c in d.body.child:
      if c.kind == SvgNodeType.Path: check c.path.len > 0

suite "transform and dash":
  test "transform lists":
    let g = load("transform").body.child
    check g.len == 6
    let m0 = g[0].transform.get()
    check m0.e11 == 1.0'f32 and m0.e13 == 20.0'f32 and m0.e23 == 20.0'f32
    let m1 = g[1].transform.get()
    check m1.e11 == 1.0'f32 and near(m1.e12, -0.2'f32) and near(m1.e21, 0.3'f32)
    check m1.e13 == 20.0'f32 and m1.e23 == 70.0'f32
    check near(g[2].transform.get().e12, 0.4663077'f32)
    check near(g[3].transform.get().e21, -0.2679492'f32)
    check near(g[4].transform.get().e11, 1.41421'f32, 1e-3'f32)
    check g[5].style.opacity == 153

  test "nested group transforms stay separate":
    let g = load("transform").body.child[0]
    check g.kinds == @[SvgNodeType.Rect, SvgNodeType.G, SvgNodeType.G]
    check g.child[1].transform.isSome
    check g.child[1].parent == g

  test "dash arrays, offset, caps and joins":
    let l = load("dash").body.child
    check l.len == 7
    check l[0].style.stroke.dash.array == @[10'f32, 5]
    check SvgStrokeFlag.Dash in l[0].style.stroke.flags
    check l[1].style.stroke.dash.offset == 7.0'f32
    check l[2].style.stroke.cap == StrokeCap.Round
    check l[2].style.stroke.paint.color == rgb(204, 0, 0)
    check l[3].style.stroke.dash.array == @[12'f32, 6, 3, 6]
    check l[3].style.stroke.cap == StrokeCap.Square
    check l[4].style.stroke.dash.array == @[8'f32, 4]
    check l[4].style.fill.paint.none
    check l[6].style.stroke.miterlimit == 2.0'f32
    check SvgStrokeFlag.Miterlimit in l[6].style.stroke.flags

suite "css":
  test "class rules, tag.class rules and the css node":
    let d = load("style_use")
    check d.cssStyle != nil
    let c = d.body.child
    check c[0].style.fill.paint.color == rgb(238, 51, 51)
    check c[0].style.stroke.paint.color == rgb(51, 0, 0)
    check c[0].style.stroke.width == 4.0'f32
    check c[2].style.fill.paint.color == rgb(250, 160, 0, 204)

  test "hsl in a css rule stays black like the original":
    let c = load("style_use").body.child[1]
    check c.id == "c"
    check c.style.fill.paint.color == rgb(0, 0, 0)

  test "tag selectors and attribute precedence":
    let d = parseSvg("<svg><style>rect { fill: red } circle { fill: blue }</style>" &
        "<rect width='1' height='1'/><circle r='1' fill='green'/></svg>")
    let c = d.body.child
    check c[0].style.fill.paint.color == rgb(255, 0, 0)
    check c[1].style.fill.paint.color == rgb(0, 0, 255)

  test "inline style attribute":
    let d = parseSvg("<svg><rect width='1' height='1' style='fill:#00f;opacity:0.5'/></svg>")
    let r = d.body.child[0]
    check r.style.fill.paint.color == rgb(0, 0, 255)
    check r.style.opacity == 128

  test "important css overrides the style attribute":
    let d = parseSvg("<svg><style>.k { fill: #f00 !important }</style>" &
        "<rect class='k' width='1' height='1' style='fill:#00f'/></svg>")
    check d.body.child[0].style.fill.paint.color == rgb(255, 0, 0)

suite "use and defs":
  test "defs content and use clones":
    let d = load("style_use")
    check d.defs.kinds == @[SvgNodeType.Path, SvgNodeType.G]
    check d.defs.child[0].id == "tri"
    let u = d.body.child[3 .. 6]
    check u.len == 4
    for n in u:
      check n.kind == SvgNodeType.Use
      check n.child.len == 1
    check u[0].use.x == 40.0'f32 and u[0].use.y == 200.0'f32
    check u[0].child[0].kind == SvgNodeType.Path
    check u[0].child[0].path == "M 0 0 L 50 0 L 25 -45 Z"
    check u[2].child[0].kind == SvgNodeType.G
    check u[2].child[0].kinds == @[SvgNodeType.Circle, SvgNodeType.Circle]

  test "style is inherited by the cloned content":
    let u = load("style_use").body.child
    check u[3].style.fill.paint.color == rgb(238, 51, 51)
    check u[3].child[0].style.fill.paint.color == rgb(238, 51, 51)
    check u[4].style.fill.paint.color == rgb(128, 0, 128)
    check u[4].child[0].style.fill.paint.color == rgb(128, 0, 128)
    check u[4].transform.isSome
    check u[3].transform.isNone

  test "cloned group keeps its own styled children":
    let g = load("style_use").body.child[5].child[0]
    check g.child[0].style.opacity == 178
    check g.child[0].style.fill.paint.color == rgb(51, 170, 51)
    check g.child[1].style.fill.opacity == 128
    check g.child[1].style.fill.paint.color == rgb(51, 51, 238)

  test "the clone is a copy, not the defs node":
    let d = load("style_use")
    check d.body.child[3].child[0] != d.defs.child[0]
    check d.body.child[5].child[0] != d.defs.child[1]

  test "use before the defs it refers to is resolved at the end":
    let d = parseSvg("<svg><use href='#r' x='3'/><defs><rect id='r' width='4' height='5'/>" &
        "</defs></svg>")
    let u = d.body.child[0]
    check u.kind == SvgNodeType.Use
    check u.use.x == 3.0'f32
    check u.child.len == 1
    check u.child[0].kind == SvgNodeType.Rect
    check u.child[0].rect.w == 4.0'f32

  test "use of an unknown id has no content":
    let d = parseSvg("<svg><use href='#nothing'/></svg>")
    check d.body.child.len == 0 or d.body.child[0].child.len == 0

  test "symbol referenced by use":
    let d = parseSvg("<svg><defs><symbol id='s' viewBox='0 0 10 10'>" &
        "<rect width='10' height='10'/></symbol></defs><use href='#s' width='20' height='20'/></svg>")
    check d.defs.child[0].kind == SvgNodeType.Symbol
    check d.defs.child[0].symbol.hasViewBox
    check d.defs.child[0].symbol.vw == 10.0'f32
    let u = d.body.child[0]
    check u.kind == SvgNodeType.Use
    check u.use.isWidthSet and u.use.isHeightSet
    check u.use.w == 20.0'f32
    check u.use.symbol != nil
    check u.use.symbol.kind == SvgNodeType.Symbol

suite "gradients":
  test "gradients live in defs":
    let d = load("gradient")
    check d.defs.defs.gradients.len == 5
    check d.gradients.len == 0
    check d.defs.defs.gradients[0].id == "lg1"

  test "linear gradient with stops":
    let g = load("gradient").body.child[0].style.fill.paint.gradient
    check g != nil
    check g.kind == SvgGradientType.Linear
    check g.coord[0 .. 3] == @[0'f32, 0, 1, 1]
    check not g.userSpace
    check g.spread == FillSpread.Pad
    check g.stops.len == 3
    check g.stops[0] == ColorStop(offset: 0, r: 255, g: 0, b: 0, a: 255)
    check g.stops[1] == ColorStop(offset: 0.5, r: 255, g: 255, b: 0, a: 255)
    check g.stops[2] == ColorStop(offset: 1, r: 0, g: 0, b: 255, a: 128)

  test "user space gradient is normalised against the view box":
    let g = load("gradient").body.child[1].style.fill.paint.gradient
    check g.userSpace
    check g.spread == FillSpread.Reflect
    check near(g.coord[0], 130.0'f32 / 240.0'f32)
    check near(g.coord[2], 160.0'f32 / 240.0'f32)
    check g.stops[0] == ColorStop(offset: 0, r: 255, g: 165, b: 0, a: 255)
    check g.stops[1] == ColorStop(offset: 1, r: 0, g: 0, b: 255, a: 255)

  test "href inherits stops and keeps its own transform":
    let r = load("gradient").body.child[2]
    let g = r.style.fill.paint.gradient
    check g.id == "lg3"
    check g.stops.len == 3
    check g.coord[0 .. 3] == @[0'f32, 0, 1, 1]
    check g.transform.isSome
    check near(g.transform.get().e12, -1.0'f32)
    check near(g.transform.get().e21, 1.0'f32)
    check r.style.stroke.paint.gradient.id == "lg1"
    check r.style.stroke.width == 6.0'f32

  test "radial gradients":
    let c = load("gradient").body.child
    let g = c[3].style.fill.paint.gradient
    check g.kind == SvgGradientType.Radial
    check g.coord[int(RadialCoord.Cx)] == 0.5'f32
    check g.coord[int(RadialCoord.Fx)] == 0.35'f32
    check g.coord[int(RadialCoord.R)] == 0.5'f32
    check g.stops.len == 2
    check g.stops[1] == ColorStop(offset: 1, r: 20, g: 40, b: 160, a: 255)
    let u = c[4].style.fill.paint.gradient
    check u.userSpace
    check u.spread == FillSpread.Repeat
    check u.stops.len == 3
    check u.stops[2].a == 76

  test "gradient outside of defs is kept in the loose list":
    let d = parseSvg("<svg viewBox='0 0 10 10'><linearGradient id='g'>" &
        "<stop offset='0' stop-color='red'/></linearGradient>" &
        "<rect width='1' height='1' fill='url(#g)'/></svg>")
    check d.gradients.len == 1
    check d.body.child.len == 1
    check d.body.child[0].style.fill.paint.gradient != nil

  test "stop offset in percent (no clamping in the parser)":
    let d = parseSvg("<svg><defs><linearGradient id='g'><stop offset='25%' stop-color='#fff'/>" &
        "<stop offset='2' stop-color='#000'/></linearGradient></defs>" &
        "<rect width='1' height='1' fill='url(#g)'/></svg>")
    let g = d.body.child[0].style.fill.paint.gradient
    check g.stops.len == 2
    check g.stops[0].offset == 0.25'f32
    check g.stops[1].offset == 2.0'f32

suite "clip, mask":
  test "clip paths and masks are in defs":
    let d = load("clippath")
    check d.defs.kinds == @[SvgNodeType.ClipPath, SvgNodeType.ClipPath, SvgNodeType.ClipPath,
        SvgNodeType.Mask]
    check d.defs.child[0].id == "c1"
    check d.defs.child[0].kinds == @[SvgNodeType.Circle]
    check d.defs.child[2].kinds == @[SvgNodeType.Rect, SvgNodeType.Rect]
    check d.defs.child[2].child[1].transform.isSome

  test "clipPathUnits":
    let d = load("clippath")
    check d.defs.child[0].clipUserSpace
    check not d.defs.child[1].clipUserSpace

  test "references are resolved to nodes":
    let d = load("clippath")
    let c = d.body.child
    check c[0].style.clipPath.node == d.defs.child[0]
    check c[1].style.clipPath.node == d.defs.child[1]
    check c[2].style.clipPath.node == d.defs.child[2]
    check c[3].style.mask.node == d.defs.child[3]
    check c[4].style.clipPath.node == d.defs.child[0]
    check c[4].kind == SvgNodeType.G
    check c[4].transform.isSome

  test "mask content uses a gradient":
    let m = load("clippath").defs.child[3]
    check m.child[0].style.fill.paint.gradient != nil
    check m.mask.kind == SvgMaskType.Luminance

suite "text":
  test "text content and font size":
    let d = parseSvg("<svg><text x='1' y='2' font-size='20'>Hi</text></svg>")
    let t = d.body.child[0]
    check t.kind == SvgNodeType.Text
    check t.text.text == "Hi"
    check t.text.x == 1.0'f32
    check t.text.y == 2.0'f32
    check t.text.fontSize == 20.0'f32

  test "tspan becomes a child":
    let d = parseSvg("<svg><text>A<tspan x='5'>B</tspan></text></svg>")
    let t = d.body.child[0]
    check t.kind == SvgNodeType.Text
    check SvgNodeType.Tspan in t.kinds
    for c in t.child:
      if c.kind == SvgNodeType.Tspan:
        check c.text.text == "B"
        check c.text.x == 5.0'f32

suite "robustness":
  test "unknown elements are skipped":
    let d = parseSvg("<svg><foo><rect width='1' height='1'/></foo><circle r='1'/></svg>")
    check SvgNodeType.Circle in d.body.kinds

  test "malformed body keeps the header information":
    let d = parseSvg("<svg width='10' height='20'><rect")
    check d.w == 10.0'f32
    check d.h == 20.0'f32



