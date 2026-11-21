## SVG scene builder, part 5: `fill="url(#pattern)"`.
##
## Ported from `_applyPatternProperty` and its helpers in `modules/svg/tvgSvgBuilder.cpp`.
## The pattern tile is built once from the pattern's children (through
## `ctx.patternChild`), duplicated for every grid cell that covers the shape's bounds, and
## clipped to the shape.

import std/[math, options]
import ../../core/[types, geom]
import ../../renderer/[paint, shape]
import ./[nodes, builder_geom]

proc buildBaseTile(ctx: BuildCtx, patternNode: SvgNode, vBox: Box): Paint =
  var tile: Paint = nil
  var tileScene: Scene = nil
  for p in patternNode.child:
    let child = ctx.patternChild(ctx, p, vBox)
    if child == nil: continue
    if tile == nil and tileScene == nil:
      tile = child
      continue
    if tileScene == nil:
      tileScene = newScene()
      discard tileScene.add(tile)
      tile = nil
    discard tileScene.add(child)
  if tileScene != nil: Paint(tileScene) else: tile

func cellRect(pat: SvgPatternNode, bbox: Box, cell: var Box): bool =
  if pat.patternUserSpace: cell = pat.box
  else:
    cell = Box(x: bbox.x + pat.box.x * bbox.w, y: bbox.y + pat.box.y * bbox.h,
               w: pat.box.w * bbox.w, h: pat.box.h * bbox.h)
  validBox(cell)

func contentTransform(pat: SvgPatternNode, bbox, cell: Box): Matrix =
  if pat.hasViewBox:
    let sx = cell.w / pat.vbox.w
    let sy = cell.h / pat.vbox.h
    return affine(sx, 0, -pat.vbox.x * sx, 0, sy, -pat.vbox.y * sy)
  if not pat.contentUserSpace: return affine(bbox.w, 0, 0, 0, bbox.h, 0)
  identity()

func transformBounds(bounds: Box, m: Matrix): Box =
  let lt = pt(bounds.x, bounds.y) * m
  let lb = pt(bounds.x, bounds.y + bounds.h) * m
  let rt = pt(bounds.x + bounds.w, bounds.y) * m
  let rb = pt(bounds.x + bounds.w, bounds.y + bounds.h) * m
  let lo = min(min(lt, lb), min(rt, rb))
  let hi = max(max(lt, lb), max(rt, rb))
  Box(x: lo.x, y: lo.y, w: hi.x - lo.x, h: hi.y - lo.y)

proc applyPatternProperty*(ctx: BuildCtx, vg: Shape, node, patternNode: SvgNode,
                           vBox: Box): Paint =
  ## The tiles scene of the pattern painted on `vg` (nil when it cannot be built).
  if patternNode == nil or patternNode.child.len == 0: return nil
  let pat = patternNode.pattern
  if pat.applying: return nil # circular pattern reference
  let bbox = boxOf(vg)
  if not validBox(bbox): return nil
  var cell: Box
  if not cellRect(pat, bbox, cell): return nil

  var box = bbox
  var inv: Matrix
  if pat.transform.isSome and inverse(pat.transform.get, inv): box = transformBounds(bbox, inv)
  let startX = cell.x + floor((box.x - cell.x) / cell.w) * cell.w
  let startY = cell.y + floor((box.y - cell.y) / cell.h) * cell.h
  let cols = int(ceil((box.x + box.w - startX) / cell.w))
  let rows = int(ceil((box.y + box.h - startY) / cell.h))
  let content = contentTransform(pat, bbox, cell)

  patternNode.pattern.applying = true
  let base = buildBaseTile(ctx, patternNode, vBox)
  let tiles = newScene()
  if base != nil:
    for r in 0 ..< rows:
      for c in 0 ..< cols:
        let copy = base.duplicate()
        if copy == nil: continue
        var tileTransform = affine(1, 0, startX + float32(c) * cell.w,
                                   0, 1, startY + float32(r) * cell.h) * content
        if pat.transform.isSome: tileTransform = pat.transform.get * tileTransform
        discard copy.transform(tileTransform * copy.transform())
        discard tiles.add(copy)
  let clipper = newShape()
  if not recognizeShape(node, clipper):
    patternNode.pattern.applying = false
    return nil
  discard tiles.clip(clipper)
  patternNode.pattern.applying = false
  tiles
