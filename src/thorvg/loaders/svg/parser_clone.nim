## Style inheritance and node cloning of the SVG loader: the machinery behind `<use>`.
##
## Ported from `_styleInherit`, `_styleCopy`, `_copyAttr`, `_cloneNode`,
## `_clonePostponedNodes` and the node lookup helpers of `modules/svg/tvgSvgLoader.cpp`.
## `cloneNodes` is the `Inlist` of the original with the front at index 0. Null strings
## are "": a node without id never matches a lookup.

import std/options
import ./nodes

const
  MaxCloneDepth = 8192 ## guard against recursive documents
  MaxPostponeDepth = 512

func isTextNode*(node: SvgNode): bool =
  node != nil and node.kind in {SvgNodeType.Text, SvgNodeType.Tspan}

func getDefsNode*(node: SvgNode): SvgNode =
  ## The `<defs>` of the document `node` belongs to (the root itself for a defs tree).
  if node == nil: return nil
  var n = node
  while n.parent != nil: n = n.parent
  if n.kind == SvgNodeType.Doc: return n.doc.defs
  if n.kind == SvgNodeType.Defs: return n
  nil

func findNodeById*(node: SvgNode, id: string): SvgNode =
  ## Depth-first search by id.
  if node == nil: return nil
  if node.id.len > 0 and node.id == id: return node
  for p in node.child:
    let found = findNodeById(p, id)
    if found != nil: return found
  nil

func findParentById*(node: SvgNode, id: string, doc: SvgNode): SvgNode =
  ## The ancestor of `node` (below `doc`) named `id`, if any.
  var parent = node.parent
  while parent != nil and parent != doc:
    if parent.id.len > 0 and parent.id == id: return parent
    parent = parent.parent
  nil

func checkPostponed*(node, cloneNode: SvgNode, depth: int): bool =
  ## True when `cloneNode` is `node` or one of its descendants.
  if node == cloneNode: return true
  if depth == MaxPostponeDepth: return false
  for p in node.child:
    if checkPostponed(p, cloneNode, depth + 1): return true
  false

func hasTspanChild*(node: SvgNode, exclude: SvgNode = nil): bool =
  for p in node.child:
    if p == exclude: continue
    if p.kind == SvgNodeType.Tspan and (p.text.text.len > 0 or p.child.len > 0): return true
  false

proc spliceTspanClose*(ctx: SvgParserContext) =
  ## Closing `</tspan>`: a plain tspan without any override folds its text into the parent.
  let cur = ctx.parser.node
  if cur == nil or cur.kind != SvgNodeType.Tspan: return
  let t = cur.text
  let unpositioned = t.x == high(float32) and t.y == high(float32) and t.dx == 0.0'f32 and
                     t.dy == 0.0'f32
  let noOverride = t.fontSize <= 0.0'f32 and t.fontFamily.len == 0 and
                   cur.xmlSpace == SvgXmlSpace.None and cur.style.flags == {} and
                   cur.style.fill.flags == {}
  if t.text.len > 0 and unpositioned and noOverride and isTextNode(cur.parent) and
      cur.child.len == 0 and not hasTspanChild(cur.parent, cur):
    cur.parent.text.text.add t.text
    cur.text.text = ""
  ctx.parser.node = cur.parent

func inheritWeight(child: var SvgStyleProperty, parentWeight: SvgFontWeight) =
  if SvgStyleFlag.FontWeight notin child.flags or child.fontWeight == SvgFontWeight.Inherit:
    child.fontWeight = parentWeight
  elif child.fontWeight == SvgFontWeight.Bolder:
    child.fontWeight =
      if parentWeight <= SvgFontWeight.Weight300: SvgFontWeight.Normal
      elif parentWeight <= SvgFontWeight.Weight500: SvgFontWeight.Bold
      else: SvgFontWeight.Weight900
  elif child.fontWeight == SvgFontWeight.Lighter:
    child.fontWeight =
      if parentWeight <= SvgFontWeight.Weight500: SvgFontWeight.Weight100
      elif parentWeight <= SvgFontWeight.Bold: SvgFontWeight.Normal
      else: SvgFontWeight.Bold

func inheritPaint(child: var SvgPaint, parent: SvgPaint) =
  child.color = parent.color
  child.none = parent.none
  child.curColor = parent.curColor
  if parent.url.len > 0: child.url = parent.url

func styleInherit*(child: var SvgStyleProperty, parent: SvgNode) =
  ## `_styleInherit`: takes from `parent` (may be nil) what `child` did not set itself.
  inheritWeight(child, if parent != nil: parent.style.fontWeight else: SvgFontWeight.Normal)
  if parent == nil: return
  template p: untyped = parent.style
  if not child.curColorSet:
    child.color = p.color
    child.curColorSet = p.curColorSet
  if SvgStyleFlag.PaintOrder notin child.flags: child.paintOrder = p.paintOrder
  if SvgFillFlag.Paint notin child.fill.flags: inheritPaint(child.fill.paint, p.fill.paint)
  if SvgFillFlag.Opacity notin child.fill.flags: child.fill.opacity = p.fill.opacity
  if SvgFillFlag.FillRule notin child.fill.flags: child.fill.fillRule = p.fill.fillRule
  if SvgStrokeFlag.Paint notin child.stroke.flags: inheritPaint(child.stroke.paint, p.stroke.paint)
  if SvgStrokeFlag.Opacity notin child.stroke.flags: child.stroke.opacity = p.stroke.opacity
  if SvgStrokeFlag.Width notin child.stroke.flags: child.stroke.width = p.stroke.width
  if SvgStrokeFlag.Dash notin child.stroke.flags and p.stroke.dash.array.len > 0:
    child.stroke.dash.array = p.stroke.dash.array
  if SvgStrokeFlag.DashOffset notin child.stroke.flags:
    child.stroke.dash.offset = p.stroke.dash.offset
  if SvgStrokeFlag.Cap notin child.stroke.flags: child.stroke.cap = p.stroke.cap
  if SvgStrokeFlag.Join notin child.stroke.flags: child.stroke.join = p.stroke.join
  if SvgStrokeFlag.Miterlimit notin child.stroke.flags:
    child.stroke.miterlimit = p.stroke.miterlimit
  if SvgStyleFlag.TextAnchor notin child.flags: child.textAnchor = p.textAnchor
  if SvgStyleFlag.DominantBaseline notin child.flags:
    child.dominantBaseline = p.dominantBaseline
  if SvgStyleFlag.LetterSpacing notin child.flags: child.letterSpacing = p.letterSpacing
  if SvgStyleFlag.WordSpacing notin child.flags: child.wordSpacing = p.wordSpacing
  if SvgStyleFlag.ImageRendering notin child.flags: child.imageRendering = p.imageRendering

func styleCopy(dst: var SvgStyleProperty, src: SvgStyleProperty) =
  ## `_styleCopy`: copies the properties `src` set explicitly.
  if src.curColorSet:
    dst.color = src.color
    dst.curColorSet = true
  if SvgStyleFlag.Opacity in src.flags: dst.opacity = src.opacity
  if SvgStyleFlag.PaintOrder in src.flags: dst.paintOrder = src.paintOrder
  if SvgStyleFlag.Display in src.flags: dst.display = src.display
  if SvgStyleFlag.BlendMode in src.flags: dst.blendMode = src.blendMode
  if SvgStyleFlag.ImageRendering in src.flags: dst.imageRendering = src.imageRendering
  if SvgStyleFlag.TextAnchor in src.flags: dst.textAnchor = src.textAnchor
  if SvgStyleFlag.AlignmentBaseline in src.flags:
    dst.alignmentBaseline = src.alignmentBaseline
  if SvgStyleFlag.DominantBaseline in src.flags: dst.dominantBaseline = src.dominantBaseline
  if SvgStyleFlag.FontWeight in src.flags: dst.fontWeight = src.fontWeight
  if SvgStyleFlag.LetterSpacing in src.flags:
    dst.letterSpacing = src.letterSpacing
    dst.letterSpacingRelative = src.letterSpacingRelative
  if SvgStyleFlag.WordSpacing in src.flags:
    dst.wordSpacing = src.wordSpacing
    dst.wordSpacingRelative = src.wordSpacingRelative
  dst.fill.flags = dst.fill.flags + src.fill.flags
  if SvgFillFlag.Paint in src.fill.flags: inheritPaint(dst.fill.paint, src.fill.paint)
  if SvgFillFlag.Opacity in src.fill.flags: dst.fill.opacity = src.fill.opacity
  if SvgFillFlag.FillRule in src.fill.flags: dst.fill.fillRule = src.fill.fillRule
  dst.stroke.flags = dst.stroke.flags + src.stroke.flags
  if SvgStrokeFlag.Paint in src.stroke.flags: inheritPaint(dst.stroke.paint, src.stroke.paint)
  if SvgStrokeFlag.Opacity in src.stroke.flags: dst.stroke.opacity = src.stroke.opacity
  if SvgStrokeFlag.Width in src.stroke.flags: dst.stroke.width = src.stroke.width
  if SvgStrokeFlag.Dash in src.stroke.flags and src.stroke.dash.array.len > 0:
    dst.stroke.dash.array = src.stroke.dash.array
  if SvgStrokeFlag.DashOffset in src.stroke.flags:
    dst.stroke.dash.offset = src.stroke.dash.offset
  if SvgStrokeFlag.Cap in src.stroke.flags: dst.stroke.cap = src.stroke.cap
  if SvgStrokeFlag.Join in src.stroke.flags: dst.stroke.join = src.stroke.join
  if SvgStrokeFlag.Miterlimit in src.stroke.flags:
    dst.stroke.miterlimit = src.stroke.miterlimit

proc copyAttr(dst, src: SvgNode) =
  ## `_copyAttr`: transform, style and the per-type attributes (not the children).
  if src.transform.isSome: dst.transform = src.transform
  styleCopy(dst.style, src.style)
  dst.style.flags = dst.style.flags + src.style.flags
  if src.style.clipPath.url.len > 0: dst.style.clipPath.url = src.style.clipPath.url
  if src.style.mask.url.len > 0: dst.style.mask.url = src.style.mask.url
  if src.style.filter.url.len > 0: dst.style.filter.url = src.style.filter.url
  case src.kind
  of SvgNodeType.Circle: dst.circle = src.circle
  of SvgNodeType.Ellipse: dst.ellipse = src.ellipse
  of SvgNodeType.Rect: dst.rect = src.rect
  of SvgNodeType.Line: dst.line = src.line
  of SvgNodeType.Path:
    if src.path.len > 0: dst.path = src.path
  of SvgNodeType.Polygon, SvgNodeType.Polyline:
    if src.polygon.pts.len > 0: dst.polygon.pts = src.polygon.pts
  of SvgNodeType.Image:
    dst.image.x = src.image.x
    dst.image.y = src.image.y
    dst.image.w = src.image.w
    dst.image.h = src.image.h
    if src.image.href.len > 0: dst.image.href = src.image.href
  of SvgNodeType.Use: dst.use = src.use
  of SvgNodeType.Pattern:
    dst.pattern = src.pattern
    dst.pattern.applying = false
  of SvgNodeType.Text, SvgNodeType.Tspan:
    dst.text.x = src.text.x
    dst.text.y = src.text.y
    dst.text.dx = src.text.dx
    dst.text.dy = src.text.dy
    dst.text.fontSize = src.text.fontSize
    if src.text.text.len > 0: dst.text.text = src.text.text
    if src.text.fontFamily.len > 0: dst.text.fontFamily = src.text.fontFamily
  else: discard

proc cloneNode*(src, parent: SvgNode, depth: int) =
  ## `_cloneNode`: appends a deep copy of `src` below `parent`.
  if depth == MaxCloneDepth: return # runaway recursion in a malformed document
  if src == nil or parent == nil or src == parent: return
  let node = newNode(parent, src.kind)
  styleInherit(node.style, parent)
  copyAttr(node, src)
  for p in src.child: cloneNode(p, node, depth + 1)

proc clonePostponedNodes*(cloneNodes: var seq[SvgNodeIdPair], doc: SvgNode) =
  ## `_clonePostponedNodes`: resolves the `use` references that could not be cloned while
  ## parsing; references that depend on each other in a cycle are discarded.
  var count = cloneNodes.len
  var postponeCount = 0
  while cloneNodes.len > 0:
    if postponeCount >= count:
      cloneNodes.setLen(0)
      break
    let pair = cloneNodes[0]
    if findParentById(pair.node, pair.id, doc) == nil:
      var postpone = false
      var nodeFrom = findNodeById(getDefsNode(pair.node), pair.id)
      if nodeFrom == nil: nodeFrom = findNodeById(doc, pair.id)
      if nodeFrom != nil:
        for other in cloneNodes:
          if checkPostponed(nodeFrom, other.node, 1):
            postpone = true
            cloneNodes.delete(0)
            cloneNodes.add pair
            break
      if not postpone:
        cloneNode(nodeFrom, pair.node, 0)
        if nodeFrom != nil and nodeFrom.kind == SvgNodeType.Symbol and
            pair.node.kind == SvgNodeType.Use:
          pair.node.use.symbol = nodeFrom
        cloneNodes.delete(0)
        postponeCount = 0
        dec count
      else:
        inc postponeCount
    else: # a reference to an ancestor is invalid
      cloneNodes.delete(0)
      postponeCount = 0
      dec count
