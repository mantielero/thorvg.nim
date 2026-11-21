## SVG scene builder: turns the parsed node tree (`SvgLoaderData`) into a Scene.
##
## Ported from `modules/svg/tvgSvgBuilder.cpp` (`svgSceneBuild` and the property / shape /
## group builders). The helpers live in `builder_geom` (shapes, gradients, matrices),
## `builder_comp` (clip, mask, filter, blend), `builder_image`, `builder_text` and
## `builder_pattern`.
##
## API: `svgSceneBuild(data, svgPath)` returns the root scene, clipped to the view box, and
## stores the final view box and size in `data.doc` (read them back with `finishLoad`).
##
## Deviations (DECISIONS.md D-T17b-*): no accessor ids bookkeeping and no image buffer
## ownership (`ctx.images`); `paint.id` is still set from the node id; `_applyProperty`
## has no `clip` flag (the original always passes false).

import std/options
import ../../core/[types, geom, compressor]
import ../../renderer/[paint, shape, scene, fonts]
from ../../renderer/render import multiply
import ./[nodes, loader_parse, builder_geom, builder_comp, builder_image, builder_text,
          builder_pattern]

const MaxDepth = 2192

func opaqueBy(opacity: int, alpha: uint8): uint8 =
  ## `MULTIPLY(opacity, alpha)`.
  multiply(lowByte(opacity), alpha)

proc applyStroke(style: SvgStyleProperty, vg: Shape, vBox, viewport: Box) =
  let stroke = style.stroke
  discard vg.strokeWidth(stroke.width)
  discard vg.strokeCap(stroke.cap)
  discard vg.strokeJoin(stroke.join)
  discard vg.strokeMiterlimit(stroke.miterlimit)
  discard vg.strokeDash(stroke.dash.array, stroke.dash.offset)
  if stroke.paint.none:
    discard vg.strokeWidth(0.0'f32)
  elif stroke.paint.gradient != nil:
    let g = stroke.paint.gradient
    let box = if g.userSpace: vBox else: boxOf(vg)
    let f = applyGradient(g, box, viewport, stroke.opacity)
    if f.isSome: discard vg.strokeFill(f.get)
    else: discard vg.strokeWidth(0.0'f32)
  elif stroke.paint.url.len > 0:
    discard # the stroke's url is not supported
  elif stroke.paint.curColor:
    discard vg.strokeFill(style.color.r, style.color.g, style.color.b,
                          opaqueBy(stroke.opacity, style.color.a))
  else:
    let c = stroke.paint.color
    discard vg.strokeFill(c.r, c.g, c.b, opaqueBy(stroke.opacity, c.a))

proc applyProperty(ctx: BuildCtx, node: SvgNode, vg: Shape, vBox: Box): Paint =
  let style = node.style
  if node.kind == SvgNodeType.Doc or not style.display: return vg
  let fill = style.fill
  if fill.paint.none:
    discard
  elif fill.paint.gradient != nil:
    let g = fill.paint.gradient
    let f = applyGradient(g, (if g.userSpace: vBox else: boxOf(vg)), ctx.global, fill.opacity)
    if f.isSome: discard vg.fill(f.get)
  elif fill.paint.pattern != nil:
    let patternPaint = applyPatternProperty(ctx, vg, node, fill.paint.pattern, vBox)
    if patternPaint != nil:
      discard vg.fillRule(fill.fillRule)
      discard vg.order(not style.paintOrder)
      applyStroke(style, vg, vBox, ctx.global)
      let patternScene = newScene()
      discard patternScene.add(patternPaint)
      discard patternScene.add(vg)
      discard patternScene.opacity(lowByte(style.opacity))
      if node.transform.isSome: discard patternScene.transform(node.transform.get)
      var p = applyFilter(ctx, patternScene, node, vBox)
      p = applyComposition(ctx, p, node, vBox)
      return applyBlend(p, node)
  elif fill.paint.url.len > 0:
    discard # the fill's url is not supported
  elif fill.paint.curColor:
    discard vg.fill(style.color.r, style.color.g, style.color.b,
                    opaqueBy(fill.opacity, style.color.a))
  else:
    let c = fill.paint.color
    discard vg.fill(c.r, c.g, c.b, opaqueBy(fill.opacity, c.a))
  discard vg.fillRule(fill.fillRule)
  discard vg.order(not style.paintOrder)
  discard vg.opacity(lowByte(style.opacity))
  if node.kind in {SvgNodeType.G, SvgNodeType.Use}:
    if SvgStyleFlag.BlendMode in style.flags: discard vg.blend(style.blendMode)
    return vg
  applyStroke(style, vg, vBox, ctx.global)
  # the transform is applied after the local bounds were used for the gradients
  if node.transform.isSome: discard vg.transform(node.transform.get)
  var p = applyFilter(ctx, vg, node, vBox)
  p = applyComposition(ctx, p, node, vBox)
  applyBlend(p, node)

proc shapeBuild(ctx: BuildCtx, node: SvgNode, vBox: Box): Paint =
  let shape = newShape()
  if not recognizeShape(node, shape): return nil
  applyProperty(ctx, node, shape, vBox)

proc useBuild(ctx: BuildCtx, node: SvgNode, vBox: Box, depth: int): Scene =
  let scene = ctx.sceneBuild(ctx, node, vBox, false, depth + 1)
  if node.use.symbol == nil or node.use.symbol.symbol.overflowVisible: return scene
  let (width, height) = symbolSize(node, vBox)
  let viewBoxClip = newShape()
  discard viewBoxClip.appendRect(0, 0, width, height)
  var clipTransform = useTransform(node)
  if node.use.symbol.transform.isSome:
    clipTransform = clipTransform * node.use.symbol.transform.get
  discard viewBoxClip.transform(clipTransform)
  let clippingLayer = newScene()
  discard clippingLayer.clip(viewBoxClip)
  discard clippingLayer.add(scene)
  clippingLayer

proc buildChild(ctx: BuildCtx, child: SvgNode, vBox: Box, depth: int): Paint =
  ## The child dispatch shared by scenes (`depth` + 1) and pattern tiles (`depth` 0).
  if child.kind in {SvgNodeType.ClipPath, SvgNodeType.Filter, SvgNodeType.Pattern,
                    SvgNodeType.Mask}:
    return nil
  case child.kind
  of SvgNodeType.Use: result = useBuild(ctx, child, vBox, depth)
  of SvgNodeType.Symbol: result = nil
  of SvgNodeType.Doc, SvgNodeType.G: result = ctx.sceneBuild(ctx, child, vBox, false, depth)
  of SvgNodeType.Image: result = imageBuild(ctx, child, vBox)
  of SvgNodeType.Text: result = textBuild(ctx, child, vBox)
  else: result = shapeBuild(ctx, child, vBox)

proc buildScene(ctx: BuildCtx, node: SvgNode, vBox: Box, mask: bool, depth: int): Scene =
  if depth > MaxDepth: return nil # invalid svg: recursion without end
  if not isGroupType(node.kind) and not mask: return nil
  let scene = newScene()
  # a symbol gets its view box transform from the `use` (see symbolTransform)
  if not mask and node.kind != SvgNodeType.Symbol:
    if node.kind == SvgNodeType.Use:
      discard scene.transform(if node.use.symbol != nil: symbolTransform(node, vBox)
                              else: useTransform(node))
    elif node.transform.isSome: discard scene.transform(node.transform.get)
  if not node.style.display or node.style.opacity == 0: return scene
  for child in node.child:
    var paint: Paint = nil
    if child.kind in {SvgNodeType.ClipPath, SvgNodeType.Filter, SvgNodeType.Pattern}: continue
    if child.kind == SvgNodeType.Symbol:
      if node.kind == SvgNodeType.Use: paint = ctx.sceneBuild(ctx, child, vBox, false, depth + 1)
    elif isGroupType(child.kind) and child.kind != SvgNodeType.Use:
      paint = ctx.sceneBuild(ctx, child, vBox, false, depth + 1)
    else: paint = buildChild(ctx, child, vBox, depth + 1)
    if paint != nil:
      if child.id.len > 0: paint.id = djb2Encode(child.id)
      discard scene.add(paint)
  discard scene.opacity(lowByte(node.style.opacity))
  Scene(applyBlend(applyComposition(ctx, applyFilter(ctx, scene, node, vBox), node, vBox), node))

proc buildPatternChild(ctx: BuildCtx, child: SvgNode, vBox: Box): Paint =
  ## `_buildPatternChild`: the children of a pattern start a fresh depth count.
  buildChild(ctx, child, vBox, 0)

# ---- document ---------------------------------------------------------------------

proc loadFonts(fonts: seq[FontFace]) =
  ## `_loadFonts`: embedded `@font-face` sources ("...ttf;base64,<data>").
  const MaxScan = 40
  const Key = 10 # "ttf;base64" / "otf;base64"
  for f in fonts:
    if f.name.len == 0: continue
    let limit = min(f.src.len, MaxScan)
    var i = 0
    while i + Key <= limit:
      let tag = f.src[i ..< i + Key]
      if tag == "ttf;base64" or tag == "otf;base64":
        discard loadFont(f.name, b64Decode(f.src[i + Key + 1 .. ^1]), tag[0 ..< 3])
        break
      inc i

func hasUserSpaceGradients(data: SvgLoaderData): bool =
  for g in data.gradients:
    if g.userSpace: return true
  if data.defs != nil:
    for g in data.defs.defs.gradients:
      if g.userSpace: return true
  false

proc updateInvalidViewSize(scene: Scene, vBox: var Box, w, h: var float32,
                           viewFlag: SvgViewFlags) =
  let useW = SvgViewFlag.Width in viewFlag
  let useH = SvgViewFlag.Height in viewFlag
  let bbox = boxOf(scene)
  if not useW and not useH: vBox = bbox
  else:
    vBox.w = if useW: w else: bbox.w
    vBox.h = if useH: h else: bbox.h
  # the size would have 1x1 or percentage values
  if not useW: w *= vBox.w
  if not useH: h *= vBox.h

proc svgSceneBuild*(data: SvgLoaderData, svgPath: string): Scene =
  ## The root scene of a parsed document (nil without a document node). `svgPath` is the
  ## directory of the file, for the relative image paths.
  if data.doc == nil or data.doc.kind != SvgNodeType.Doc: return nil
  let ctx = BuildCtx(global: data.global, svgPath: svgPath, sceneBuild: buildScene,
                     patternChild: buildPatternChild)
  var vBox = data.vbox
  var w = data.w
  var h = data.h
  loadFonts(data.fonts)
  var docNode = buildScene(ctx, data.doc, vBox, false, 0)
  if SvgViewFlag.Viewbox notin data.viewFlag:
    let prevW = vBox.w
    let prevH = vBox.h
    updateInvalidViewSize(docNode, vBox, w, h, data.viewFlag)
    if (not equal(vBox.w, prevW) or not equal(vBox.h, prevH)) and hasUserSpaceGradients(data):
      docNode = buildScene(ctx, data.doc, vBox, false, 0)
  if not equal(w, vBox.w) or not equal(h, vBox.h):
    discard docNode.transform(aspectRatioMatrix(data.align, data.meetOrSlice, w, h, vBox))
  elif not zero(vBox.x) or not zero(vBox.y):
    discard docNode.translate(-vBox.x, -vBox.y)
  let viewBoxClip = newShape()
  discard viewBoxClip.appendRect(0, 0, w, h)
  let clippingLayer = newScene()
  discard clippingLayer.clip(viewBoxClip)
  discard clippingLayer.add(docNode)
  data.doc.doc.vbox = vBox
  data.doc.doc.w = w
  data.doc.doc.h = h
  result = newScene()
  discard result.add(clippingLayer)
