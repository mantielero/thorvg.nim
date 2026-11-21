## SVG scene builder, part 4: `<text>` and `<tspan>`.
##
## Ported from the text half of `modules/svg/tvgSvgBuilder.cpp` (`_buildText`,
## `_applyTextFill`, `_applySpacing`, `_buildTspanScene`, `_textBuildHelper`...).
## A text without font loaded (see `loadFont` and `@font-face`) has no glyphs and renders
## nothing, like the original. A text node with an empty string is a node without text
## (null and "" are the same here).

import std/options
import ../../core/[types, geom]
import ../../renderer/[paint, text]
import ./[nodes, builder_geom, builder_comp]

const MaxDepth = 2192

func isSpaceChar(c: char): bool = c in {' ', '\t', '\n', '\v', '\f', '\r'}

func processText(text: string, space: SvgXmlSpace): string =
  ## `_processText`: `preserve` turns line breaks and tabs into spaces; the default mode
  ## also trims and collapses runs of white space.
  if space == SvgXmlSpace.Preserve:
    for c in text: result.add(if c in {'\n', '\t', '\r'}: ' ' else: c)
    return
  var first = 0
  while first < text.len and isSpaceChar(text[first]): inc first
  var spaceFound = false
  for i in first ..< text.len:
    if isSpaceChar(text[i]):
      if not spaceFound:
        result.add ' '
        spaceFound = true
    else:
      result.add text[i]
      spaceFound = false
  if result.len > 0 and result[^1] == ' ': result.setLen(result.len - 1)

func effectiveBaseline(style: SvgStyleProperty): SvgBaseline =
  if style.alignmentBaseline != SvgBaseline.Auto: style.alignmentBaseline
  else: style.dominantBaseline

proc applyTextFill(style: SvgStyleProperty, text: Text, fontSize: float32, vBox, viewport: Box) =
  let paint = style.fill.paint
  if paint.none: return
  if paint.gradient != nil:
    let g = paint.gradient
    let box = if g.userSpace: vBox else: boxOf(text)
    let f = applyGradient(g, box, viewport, style.fill.opacity)
    if f.isSome: discard text.fill(f.get)
    return
  if paint.url.len > 0: return # the fill's url is not supported
  let color = if paint.curColor: style.color else: paint.color
  discard text.fill(color.r, color.g, color.b)
  if style.fontWeight >= SvgFontWeight.Weight600:
    discard text.outline(fontSize * 0.03'f32, color.r, color.g, color.b)
  discard text.opacity(lowByte(style.fill.opacity))

proc applyBaseline(text: Text, baseline: SvgBaseline, transform: var Matrix) =
  if baseline == SvgBaseline.Auto or baseline == SvgBaseline.Alphabetic: return
  var tm: TextMetrics
  if text.metrics(tm) != Result.Success: return # ascent > 0, descent < 0
  var shift = 0.0'f32
  case baseline
  of SvgBaseline.BeforeEdge: shift = tm.ascent
  of SvgBaseline.AfterEdge: shift = tm.descent
  of SvgBaseline.Central: shift = 0.5'f32 * (tm.ascent + tm.descent)
  of SvgBaseline.Middle: # half the x-height
    var gm: GlyphMetrics
    var next = 0
    if text.metrics("x", 0, gm, next) == Result.Success and gm.max.y > 0.0'f32:
      shift = 0.5'f32 * gm.max.y
    else: shift = 0.27'f32 * tm.ascent
  of SvgBaseline.Hanging: shift = 0.8'f32 * tm.ascent
  of SvgBaseline.Mathematical: shift = 0.5'f32 * tm.ascent
  else: return
  translateR(transform, pt(0.0'f32, shift))
  discard text.transform(transform)

proc buildText(node: SvgTextNode, space: SvgXmlSpace, transform: Option[Matrix],
               baseline: SvgBaseline): Text =
  if node.text.len == 0: return nil
  let tx = newText()
  let fontPts = node.fontSize * 0.75'f32 # 1 pt = 1/72 in, 1 in = 96 px
  if tx.font(node.fontFamily) != Result.Success: discard tx.font() # any loaded font
  discard tx.size(fontPts)
  discard tx.text(processText(node.text, space))
  var tm: TextMetrics
  discard tx.metrics(tm)
  var textTransform = if transform.isSome: transform.get else: identity()
  translateR(textTransform, pt(node.x + node.dx, node.y + node.dy - tm.ascent))
  discard tx.transform(textTransform)
  applyBaseline(tx, baseline, textTransform)
  tx

proc applySpacing(tx: Text, letterSpacing, wordSpacing: float32): float32 =
  if letterSpacing == 0.0'f32 and wordSpacing == 0.0'f32: return 1.0'f32
  let utf8 = tx.text()
  var advance = 0.0'f32
  var gaps, spaces = 0'u32
  var gm: GlyphMetrics
  var pos = 0
  while pos < utf8.len:
    let isSpace = utf8[pos] == ' '
    var next = pos
    if tx.metrics(utf8, pos, gm, next) != Result.Success: return 1.0'f32
    if next <= pos: break
    pos = next
    if pos < utf8.len:
      advance += gm.advance
      inc gaps
      if isSpace: inc spaces
  if advance <= 0.0'f32: return 1.0'f32
  # tx.spacing() scales advances, so match the total offset using the measured gaps
  var scale = 1.0'f32 + (letterSpacing * float32(gaps) + wordSpacing * float32(spaces)) / advance
  if scale < 0.0'f32: scale = 0.0'f32
  discard tx.spacing(scale, 1.0'f32)
  scale

proc updatePos(tx: Text, node: SvgTextNode, anchor, spacingScale: float32, pos: var Point) =
  var advance = 0.0'f32
  let utf8 = tx.text()
  var gm: GlyphMetrics
  var p = 0
  while p < utf8.len:
    var next = p
    if tx.metrics(utf8, p, gm, next) != Result.Success: break
    advance += gm.advance
    if next <= p: break
    p = next
  pos.x = node.x + node.dx + (1.0'f32 - anchor) * advance * spacingScale
  pos.y = node.y + node.dy

proc hasPositionedTspan(node: SvgNode, depth: int): bool =
  if depth > MaxDepth: return true
  for p in node.child:
    if p.kind != SvgNodeType.Tspan: continue
    if p.text.text.len > 0 or hasPositionedTspan(p, depth + 1): return true
  false

proc finishText(ctx: BuildCtx, built: Paint, node: SvgNode, vBox: Box): Paint =
  ## Filter, composition and blend of a built text (the common tail of the builders).
  var p = applyFilter(ctx, built, node, vBox)
  p = applyComposition(ctx, p, node, vBox)
  applyBlend(p, node)

proc buildTspanScene(ctx: BuildCtx, node: SvgNode, scene: Scene, vBox: Box, depth: int,
                     pos: var Point) =
  if depth > MaxDepth: return
  for child in node.child:
    if child.kind != SvgNodeType.Tspan: continue
    var textNode = child.text
    if textNode.text.len > 0:
      var space = child.xmlSpace
      var n = child.parent
      while n != nil:
        if n.kind in {SvgNodeType.Text, SvgNodeType.Tspan}:
          if textNode.fontSize <= 0.0'f32: textNode.fontSize = n.text.fontSize
          if textNode.fontFamily.len == 0: textNode.fontFamily = n.text.fontFamily
        if space == SvgXmlSpace.None: space = n.xmlSpace
        if n.kind == SvgNodeType.Text: break
        n = n.parent
      if space == SvgXmlSpace.None: space = SvgXmlSpace.Default
      if textNode.x == high(float32): textNode.x = pos.x
      if textNode.y == high(float32): textNode.y = pos.y
      let text = buildText(textNode, space, none(Matrix), effectiveBaseline(child.style))
      if text != nil:
        discard text.align(child.style.textAnchor, 0.0'f32)
        let scale = applySpacing(text, child.style.letterSpacing, child.style.wordSpacing)
        updatePos(text, textNode, child.style.textAnchor, scale, pos)
        applyTextFill(child.style, text, textNode.fontSize, vBox, ctx.global)
        let paint = finishText(ctx, text, child, vBox)
        if paint != nil: discard scene.add(paint)
    buildTspanScene(ctx, child, scene, vBox, depth + 1, pos)

proc textBuild*(ctx: BuildCtx, node: SvgNode, vBox: Box): Paint =
  let textNode = node.text
  var space = node.xmlSpace
  var n = node.parent
  while space == SvgXmlSpace.None and n != nil:
    space = n.xmlSpace
    n = n.parent
  if space == SvgXmlSpace.None: space = SvgXmlSpace.Default
  let style = node.style
  if not hasPositionedTspan(node, 0):
    let text = buildText(textNode, space, node.transform, effectiveBaseline(style))
    if text == nil: return nil
    discard text.align(style.textAnchor, 0.0'f32)
    discard applySpacing(text, style.letterSpacing, style.wordSpacing)
    applyTextFill(style, text, textNode.fontSize, vBox, ctx.global)
    return finishText(ctx, text, node, vBox)
  let scene = newScene()
  if node.transform.isSome: discard scene.transform(node.transform.get)
  var pos = pt(textNode.x, textNode.y)
  let text = buildText(textNode, space, none(Matrix), effectiveBaseline(style))
  if text != nil:
    discard text.align(style.textAnchor, 0.0'f32)
    let scale = applySpacing(text, style.letterSpacing, style.wordSpacing)
    updatePos(text, textNode, style.textAnchor, scale, pos)
    applyTextFill(style, text, textNode.fontSize, vBox, ctx.global)
    discard scene.add(text)
  buildTspanScene(ctx, node, scene, vBox, 0, pos)
  finishText(ctx, scene, node, vBox)
