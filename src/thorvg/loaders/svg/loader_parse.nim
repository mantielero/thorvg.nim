## SVG parsing entry point: turns SVG text into the resolved node tree (`SvgLoaderData`).
##
## Ported from the parsing half of `modules/svg/tvgSvgLoader.cpp` (`SvgLoader::header` and
## the parsing part of `SvgLoader::run`, with the xml callbacks and the post-processing
## passes). The scene builder (`svgSceneBuild`, `tvgSvgBuilder.cpp`) is not part of this
## module: it consumes `SvgLoaderData` (see T17b).
##
## API:
## * `parseSvg(data)` -> `SvgLoaderData`: `status` (`InvalidArguments` when there is no
##   `<svg>`), the document tree `doc` (and `defs`, `cssStyle`), the loose `gradients`, the
##   view box / size / alignment resolved by `header()` (`vbox`, `w`, `h`, `align`,
##   `meetOrSlice`, `viewFlag`), `fonts` and `empty` (view box of size 0: nothing to render).
## * After building the scene, call `finishLoad` (the "override viewbox & size" step of
##   the original `run`, which follows the builder).
##
## Like the original, the first pass (`header`) stops at the outermost `<svg>`; the second
## pass parses the whole text with the same state, so the real `<svg>` opens a nested `<g>`.

import ../../core/[types, geom, str]
import ./[nodes, util, xml, css, css_style, parser_style, parser_clone,
          parser_gradient, parser_attr, parser_node]

type SvgLoaderData* = object
  status*: Result
  doc*, defs*, cssStyle*: SvgNode
  gradients*: seq[SvgStyleGradient] ## gradients declared outside of `<defs>`
  vbox*: Box
  global*: Box ## the parser's percentage reference box (`ctx.parser->global`)
  w*, h*: float32
  align*: AspectRatioAlign
  meetOrSlice*: AspectRatioMeetOrSlice
  viewFlag*: SvgViewFlags
  fonts*: seq[FontFace]
  empty*: bool ## the view box has no area: rendering is disabled

const MaxTagName = 19 ## longest tag name handled (the original keeps 20 bytes with the NUL)

func tagNameEnd(content: string, attrsAt: int): int =
  var sz = attrsAt
  while sz > 0 and isCSpace(content[sz - 1]): dec sz
  sz

func closeTagName(content: string): string =
  ## `_svgLoaderParserXmlTagName`: the text up to `>`, trimmed and cut to 19 characters.
  let start = skipWhiteSpace(content, 0)
  var stop = start
  while stop < content.len and content[stop] != '>': inc stop
  var sz = stop - start
  while sz > 0 and isCSpace(content[start + sz - 1]): dec sz
  content[start ..< start + min(sz, MaxTagName)]

func startsTag(table: openArray[(string, SvgNodeType)], name: string): bool =
  ## `strncmp(tagName, tag, sz) == 0` for some tag: a tag that starts with `name`.
  for (tag, _) in table:
    if tag.len >= name.len and tag[0 ..< name.len] == name: return true
  false

proc cssNodeAttr(ctx: SvgParserContext, key, value: string): bool =
  ## `_attrParseCssStyleNode`: the declarations of a css rule go to `ctx.parser.node`.
  if key == "id":
    ctx.parser.node.id = value
    return true
  parseStyleAttr(ctx, key, value, true)

proc parseCssStyle(ctx: SvgParserContext, content: string) =
  ## `_svgLoaderParserXmlCssStyle`: the rules of a `<style>` element become css nodes.
  let cssAttr = proc(key, value: string): bool = cssNodeAttr(ctx, key, value)
  for rule in parseCss(content):
    var kind: SvgNodeType
    if rule.tag != "defs" and (findGroupKind(rule.tag, kind) or findGraphicsKind(rule.tag, kind)):
      var node = cssFindStyleNode(ctx.cssStyle, rule.name, kind)
      if node == nil:
        let global = ctx.parser.global
        node = createNodeOf(ctx, kind, ctx.cssStyle, "", xmlParseW3CAttribute)
        ctx.parser.global = global
        node.id = rule.name
      ctx.parser.node = node
      discard xmlParseW3CAttribute(rule.attrs, cssAttr)
    elif rule.tag == "all" and rule.name.len > 0:
      for id in selectorNames(rule):
        let cssNode = cssFindStyleNode(ctx.cssStyle, id)
        if cssNode != nil:
          let old = ctx.parser.node
          ctx.parser.node = cssNode
          discard xmlParseW3CAttribute(rule.attrs, cssAttr)
          ctx.parser.node = old
        else:
          let node = createNodeOf(ctx, SvgNodeType.CssStyle, ctx.cssStyle, rule.attrs,
                                  xmlParseW3CAttribute)
          node.id = id
    elif fontFaceRule(rule):
      ctx.fonts.add FontFace()
      discard xmlParseW3CAttribute(rule.attrs, proc(key, value: string): bool =
        parseFontFaceAttr(ctx, key, value))
    # gradients, stops and unknown selectors are not supported in style sheets
  ctx.openedTag = OpenedTagType.Other

proc parseText(ctx: SvgParserContext, content: string) =
  ## `_svgLoaderParserText`: character data of `<text>` / `<tspan>`.
  let node = ctx.parser.node
  if not isTextNode(node): return
  if hasTspanChild(node):
    let run = newNode(node, SvgNodeType.Tspan)
    run.text.x = high(float32)
    run.text.y = high(float32)
    run.text.text.add content
    return
  node.text.text.add content

proc parseStop(ctx: SvgParserContext, attrs: string) =
  ctx.parser.gradStop = ColorStop(offset: 0.0'f32, a: 255)
  ctx.parser.flags = {}
  discard xmlParseAttributes(attrs, proc(key, value: string): bool =
    parseStopAttr(ctx, key, value))
  ctx.gradientStack[^1].stops.add ctx.parser.gradStop

proc openGroup(ctx: SvgParserContext, kind: SvgNodeType, name, attrs: string, empty: bool) =
  var kind = kind
  if empty: return
  var node: SvgNode
  if ctx.doc == nil:
    if name != "svg": return # not a valid svg document
    node = createNodeOf(ctx, kind, nil, attrs, xmlParseAttributes)
    ctx.doc = node
  else:
    if name == "svg": kind = SvgNodeType.G # nested <svg> is not supported: a group
    let parent = if ctx.stack.len > 0: ctx.stack[^1] else: ctx.doc
    if name == "style":
      if ctx.cssStyle == nil:
        node = createNodeOf(ctx, kind, nil, attrs, xmlParseAttributes)
        ctx.cssStyle = node
        ctx.doc.doc.style = node
      else:
        node = ctx.cssStyle
      ctx.openedTag = OpenedTagType.Style
    else:
      node = createNodeOf(ctx, kind, parent, attrs, xmlParseAttributes)
  ctx.stack.add node

proc parseOpen(ctx: SvgParserContext, content: string, empty: bool) =
  ## `_svgLoaderParserXmlOpen`.
  let attrsAt = xmlFindAttributesTag(content)
  let sz = tagNameEnd(content, attrsAt)
  if sz > MaxTagName: return
  let name = content[0 ..< sz]
  let attrs = content[attrsAt .. ^1]
  if ctx.gradientStack.len > 0 and ctx.gradientStack[^1] == nil:
    if not empty: ctx.gradientStack.add nil # inside an ignored element
    return
  if name == "stop":
    if ctx.gradientStack.len > 0: parseStop(ctx, attrs)
    if not empty: ctx.gradientStack.add nil
    return
  if ctx.gradientStack.len > 0: # no elements but stops inside a gradient
    if not empty: ctx.gradientStack.add nil
    return
  var kind: SvgNodeType
  var gradientKind: SvgGradientType
  if findGroupKind(name, kind):
    openGroup(ctx, kind, name, attrs, empty)
  elif ctx.openedTag == OpenedTagType.Text and name == "tspan":
    let parent = ctx.parser.node
    discard createNodeOf(ctx, SvgNodeType.Tspan, parent, attrs, xmlParseAttributes)
    if empty: ctx.parser.node = parent
  elif findGraphicsKind(name, kind):
    if ctx.doc == nil: return # an element before the <svg>: ignored
    let parent = if ctx.stack.len > 0: ctx.stack[^1] else: ctx.doc
    let node = createNodeOf(ctx, kind, parent, attrs, xmlParseAttributes)
    if not empty:
      if name == "text": ctx.openedTag = OpenedTagType.Text
      ctx.stack.add createDefsNode(ctx)
      ctx.currentGraphicsNode = node
  elif findGradientKind(name, gradientKind):
    let gradient = createGradient(ctx, gradientKind, attrs, xmlParseAttributes)
    # gradients do not nest: only the outermost one is registered
    if ctx.gradientStack.len == 0:
      if ctx.def != nil and ctx.doc.doc.defs != nil: ctx.def.defs.gradients.add gradient
      else: ctx.gradients.add gradient
    if not empty: ctx.gradientStack.add gradient

proc popStack(ctx: SvgParserContext) =
  if ctx.stack.len > 0: ctx.stack.setLen(ctx.stack.len - 1)

proc parseClose(ctx: SvgParserContext, content: string) =
  ## `_svgLoaderParserXmlClose`: the tag names match by prefix, like the original.
  let name = closeTagName(content)
  if ctx.gradientStack.len > 0 and ctx.gradientStack[^1] == nil:
    ctx.gradientStack.setLen(ctx.gradientStack.len - 1)
    return
  if startsTag(GroupTags, name): ctx.popStack()
  for (tag, _) in GradientTags:
    if tag.len >= name.len and tag[0 ..< name.len] == name:
      if ctx.gradientStack.len > 0: ctx.gradientStack.setLen(ctx.gradientStack.len - 1)
      break
  if ctx.openedTag == OpenedTagType.Text and name == "tspan":
    spliceTspanClose(ctx)
    return
  if startsTag(GraphicsTags, name):
    ctx.currentGraphicsNode = nil
    if name.len >= 4 and name[0 ..< 4] == "text": ctx.openedTag = OpenedTagType.Other
    ctx.popStack()

proc svgCallback(ctx: SvgParserContext): XmlCb =
  ## `_svgLoaderParser`.
  result = proc(t: XmlType, content: string): bool =
    case t
    of XmlType.Open: parseOpen(ctx, content, false)
    of XmlType.OpenEmpty: parseOpen(ctx, content, true)
    of XmlType.Close: parseClose(ctx, content)
    of XmlType.Data, XmlType.CData:
      if ctx.openedTag == OpenedTagType.Style: parseCssStyle(ctx, content)
      elif ctx.openedTag == OpenedTagType.Text: parseText(ctx, content)
    else: discard
    true

proc headerCallback(ctx: SvgParserContext): XmlCb =
  ## `_svgLoaderParserForValidCheck`: parses up to the first `<svg>` and stops there.
  result = proc(t: XmlType, content: string): bool =
    if t notin {XmlType.Open, XmlType.OpenEmpty}: return true
    let attrsAt = xmlFindAttributesTag(content)
    let sz = tagNameEnd(content, attrsAt)
    if sz > MaxTagName: return false
    var kind: SvgNodeType
    if findGroupKind(content[0 ..< sz], kind) and ctx.doc == nil:
      if content[0 ..< sz] != "svg": return true # not a valid svg document
      ctx.doc = createNodeOf(ctx, kind, nil, content[attrsAt .. ^1], xmlParseAttributes)
      ctx.stack.add ctx.doc
      return false
    true

# --- post-processing passes ---

proc updateComposite(node, root: SvgNode) =
  ## Resolves the clip-path and mask references of the tree.
  if node.style.clipPath.url.len > 0 and node.style.clipPath.node == nil:
    node.style.clipPath.node = findNodeById(root, node.style.clipPath.url)
  if node.style.mask.url.len > 0 and node.style.mask.node == nil:
    node.style.mask.node = findNodeById(root, node.style.mask.url)
  for p in node.child: updateComposite(p, root)

proc updateFilter(node, root: SvgNode) =
  if node.style.filter.url.len > 0 and node.style.filter.node == nil:
    node.style.filter.node = findNodeById(root, node.style.filter.url)
  for p in node.child: updateFilter(p, root)

proc updateStyle(node, parent: SvgNode) =
  ## Inherits the style down the tree and resolves relative letter/word spacing.
  styleInherit(node.style, parent)
  if node.style.letterSpacingRelative:
    node.style.letterSpacing = node.style.letterSpacing * findEmBaseFontSize(node)
    node.style.letterSpacingRelative = false
  if node.style.wordSpacingRelative:
    node.style.wordSpacing = node.style.wordSpacing * findEmBaseFontSize(node)
    node.style.wordSpacingRelative = false
  for p in node.child: updateStyle(p, node)

proc updatePattern(node, root, defs: SvgNode) =
  ## Resolves the `fill="url(#pattern)"` references.
  template fill: untyped = node.style.fill.paint
  if fill.url.len > 0 and fill.gradient == nil and fill.pattern == nil:
    var p: SvgNode = nil
    if defs != nil: p = findNodeById(defs, fill.url)
    if p == nil: p = findNodeById(root, fill.url)
    if p != nil and p.kind == SvgNodeType.Pattern: fill.pattern = p
  for c in node.child: updatePattern(c, root, defs)

proc postProcess(ctx: SvgParserContext) =
  ## The passes of `SvgLoader::run` between the xml parse and the scene build.
  let defs = ctx.doc.doc.defs
  if ctx.nodesToStyle.len > 0: cssApplyStyleToPostponeds(ctx.nodesToStyle, ctx.cssStyle)
  if ctx.cssStyle != nil: cssUpdateStyle(ctx.doc, ctx.cssStyle)
  if ctx.cloneNodes.len > 0: clonePostponedNodes(ctx.cloneNodes, ctx.doc)
  updateComposite(ctx.doc, ctx.doc)
  if defs != nil:
    updateComposite(ctx.doc, defs)
    updateComposite(defs, defs)
  updateFilter(ctx.doc, ctx.doc)
  if defs != nil:
    updateFilter(ctx.doc, defs)
    updateFilter(defs, defs)
  updateStyle(ctx.doc, nil)
  if defs != nil: updateStyle(defs, nil)
  if ctx.gradients.len > 0: updateGradient(ctx, ctx.doc, ctx.gradients)
  if defs != nil:
    updateGradient(ctx, ctx.doc, defs.defs.gradients)
    if ctx.gradients.len > 0: updateGradient(ctx, defs, ctx.gradients)
    updateGradient(ctx, defs, defs.defs.gradients)
  updatePattern(ctx.doc, ctx.doc, defs)
  if defs != nil: updatePattern(defs, ctx.doc, defs)

# --- API ---

proc resolveHeader(doc: SvgDocNode, data: var SvgLoaderData) =
  ## The view box and size part of `SvgLoader::header`.
  data.viewFlag = doc.viewFlag
  data.align = doc.align
  data.meetOrSlice = doc.meetOrSlice
  if SvgViewFlag.Viewbox in data.viewFlag:
    data.vbox = doc.vbox
    if SvgViewFlag.Width in data.viewFlag: data.w = doc.w
    else:
      data.w = doc.vbox.w
      if SvgViewFlag.WidthInPercent in data.viewFlag:
        data.w = data.w * doc.w
        data.viewFlag.excl SvgViewFlag.WidthInPercent
      data.viewFlag.incl SvgViewFlag.Width
    if SvgViewFlag.Height in data.viewFlag: data.h = doc.h
    else:
      data.h = doc.vbox.h
      if SvgViewFlag.HeightInPercent in data.viewFlag:
        data.h = data.h * doc.h
        data.viewFlag.excl SvgViewFlag.HeightInPercent
      data.viewFlag.incl SvgViewFlag.Height
  else:
    # no view box and no size: defaults until the whole picture is known
    data.vbox.x = 0.0'f32
    data.vbox.y = 0.0'f32
    if SvgViewFlag.Width in data.viewFlag:
      data.w = doc.w
      data.vbox.w = doc.w
    else:
      data.vbox.w = 1.0'f32
      data.w = if SvgViewFlag.WidthInPercent in data.viewFlag: doc.w else: 1.0'f32
    if SvgViewFlag.Height in data.viewFlag:
      data.h = doc.h
      data.vbox.h = doc.h
    else:
      data.vbox.h = 1.0'f32
      data.h = if SvgViewFlag.HeightInPercent in data.viewFlag: doc.h else: 1.0'f32

proc parseSvg*(data: string): SvgLoaderData =
  ## Parses SVG text: the header pass, then the full parse with all the post-processing.
  let ctx = SvgParserContext()
  discard xmlParse(data, true, headerCallback(ctx))
  if ctx.doc == nil or ctx.doc.kind != SvgNodeType.Doc:
    result.status = Result.InvalidArguments
    return
  resolveHeader(ctx.doc.doc, result)
  result.doc = ctx.doc
  result.status = Result.Success
  # a zero-area view box disables rendering
  if SvgViewFlag.Viewbox in result.viewFlag and
      (abs(result.vbox.w) <= FloatEpsilon or abs(result.vbox.h) <= FloatEpsilon):
    result.empty = true
  elif xmlParse(data, true, svgCallback(ctx), proc(): bool = ctx.openedTag == OpenedTagType.Text):
    postProcess(ctx)
  else:
    result.status = Result.InsufficientCondition
  result.global = ctx.parser.global
  result.defs = ctx.doc.doc.defs
  result.cssStyle = ctx.cssStyle
  result.gradients = ctx.gradients
  result.fonts = ctx.fonts

proc finishLoad*(data: var SvgLoaderData) =
  ## "Override viewbox & size again after svg loading": without a view box the size comes
  ## from the document node, which the scene builder completes from the whole picture.
  if data.doc != nil and SvgViewFlag.Viewbox notin data.viewFlag:
    data.vbox = data.doc.doc.vbox
    data.w = data.doc.doc.w
    data.h = data.doc.doc.h

