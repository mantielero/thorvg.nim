## SVG scene builder, part 2: composition of a built paint - clip-path, mask, filter, blend.
##
## Ported from `modules/svg/tvgSvgBuilder.cpp` (`_applyClip`, `_clipperUnion`,
## `_applyMask`, `_applyComposition`, `_applyFilter`, `_applyBlend`).
##
## `applyFilter` wraps the paint in a scene with a gaussian blur effect per
## `feGaussianBlur` primitive and clips it to the filter region (DECISIONS.md D-L1-4).

import std/options
import ../../core/[types, geom]
import ../../renderer/[paint, shape, scene]
import ./[nodes, builder_geom]

proc applyClip*(ctx: BuildCtx, paint, content: Paint, node, clipNode: SvgNode, vBox: Box,
                res: var Paint): bool

proc compositionTransform(content: Paint, node, compNode: SvgNode,
                          kind: SvgNodeType): Matrix =
  result = identity()
  let isMask = kind == SvgNodeType.Mask
  let userSpace = if isMask: compNode.mask.maskContentUserSpace else: compNode.clipUserSpace
  # the initial mask transformation is ignored according to the SVG standard
  if node.kind == SvgNodeType.Use:
    if not isMask or not userSpace: result = useTransform(node)
  elif node.transform.isSome and not isMask:
    result = node.transform.get
  if compNode.transform.isSome: result = result * compNode.transform.get
  if not userSpace:
    var bbox: Box
    if node.kind == SvgNodeType.Use:
      var inv: Matrix
      let prev = content.transform()
      if inverse(useTransform(node), inv): discard content.transform(inv * prev)
      bbox = boxOf(content)
      discard content.transform(prev)
    else:
      bbox = boxOf(content)
    result = result * affine(bbox.w, 0, bbox.x, 0, bbox.h, bbox.y)

proc appendClipChild(ctx: BuildCtx, node: SvgNode, shape: Shape, vBox: Box,
                     clipped: var Paint): bool =
  var node = node
  var transform = none(Matrix)
  # the standard allows only `use` nodes that point directly to a basic shape
  if node.kind == SvgNodeType.Use:
    if node.child.len != 1:
      clipped = nil
      return false
    let child = node.child[0]
    var m = useTransform(node)
    if child.transform.isSome: m = m * child.transform.get
    if not m.isIdentity: transform = some(m)
    node = child
  if not appendClipShape(node, shape, transform):
    clipped = nil
    return false
  # clip chaining
  let clipNode = node.style.clipPath.node
  if clipNode != nil:
    if node.style.clipPath.applying: # circular dependency
      clipped = nil
      return false
    return applyClip(ctx, shape, shape, node, clipNode, vBox, clipped)
  clipped = shape
  true

proc clipperUnion(ctx: BuildCtx, content: Paint, node, clipNode: SvgNode, vBox: Box,
                  region: var Paint): bool =
  node.style.clipPath.applying = true
  var unionRegion: Paint = nil
  var scene: Scene = nil
  for p in clipNode.child:
    let child = newShape()
    var clipped: Paint = nil
    if not appendClipChild(ctx, p, child, vBox, clipped): continue
    discard child.fill(255, 255, 255, 255)
    if unionRegion == nil: unionRegion = clipped
    else:
      if scene == nil:
        scene = newScene()
        discard scene.add(unionRegion)
        unionRegion = scene
      discard scene.add(clipped)
  node.style.clipPath.applying = false
  if unionRegion == nil:
    region = nil
    return false
  discard unionRegion.transform(compositionTransform(content, node, clipNode, SvgNodeType.ClipPath))
  region = unionRegion
  true

proc applyClip*(ctx: BuildCtx, paint, content: Paint, node, clipNode: SvgNode, vBox: Box,
                res: var Paint): bool =
  var region: Paint = nil
  if not clipperUnion(ctx, content, node, clipNode, vBox, region):
    res = nil
    return false
  discard paint.mask(region, MaskMethod.Alpha)
  res = paint
  let inner = clipNode.style.clipPath.node
  if inner != nil and not inner.style.clipPath.applying:
    inner.style.clipPath.applying = true
    let scene = newScene()
    discard scene.add(paint)
    if not applyClip(ctx, scene, content, node, inner, vBox, res):
      discard scene.opacity(0)
      res = scene
    inner.style.clipPath.applying = false
  true

proc applyMask(ctx: BuildCtx, content: Paint, target: Scene, node, maskNode: SvgNode,
               vBox: Box, wrap: bool): Scene =
  node.style.mask.applying = true
  result = target
  let maskScene = ctx.sceneBuild(ctx, maskNode, vBox, true, 0)
  if maskScene != nil:
    let maskData = maskNode.mask
    let nodeTransform =
      if node.kind == SvgNodeType.Use: useTransform(node)
      elif node.transform.isSome: node.transform.get
      else: identity()
    if not maskData.maskContentUserSpace:
      discard maskScene.transform(compositionTransform(content, node, maskNode, SvgNodeType.Mask))
    elif not nodeTransform.isIdentity:
      discard maskScene.transform(nodeTransform)
    let bbox = boxOf(content)
    let clipper = newShape()
    if maskData.userSpace:
      discard clipper.appendRect(maskData.box.x, maskData.box.y, maskData.box.w, maskData.box.h)
      if not nodeTransform.isIdentity: discard clipper.transform(nodeTransform)
    else:
      let box = objectBoundingBox(maskData.box, bbox)
      discard clipper.appendRect(box.x, box.y, box.w, box.h)
    discard maskScene.clip(clipper)
    if wrap:
      let scene = newScene()
      discard scene.add(target)
      result = scene
    discard result.mask(maskScene, if maskData.kind == SvgMaskType.Luminance: MaskMethod.Luma
                              else: MaskMethod.Alpha)
  node.style.mask.applying = false

proc applyBlend*(paint: Paint, node: SvgNode): Paint =
  if paint != nil and SvgStyleFlag.BlendMode in node.style.flags:
    discard paint.blend(node.style.blendMode)
  paint

proc applyComposition*(ctx: BuildCtx, paint: Paint, node: SvgNode, vBox: Box): Paint =
  if node.style.clipPath.applying or node.style.mask.applying: # circular dependency
    return paint
  let clipNode = node.style.clipPath.node
  let maskNode = node.style.mask.node
  if clipNode == nil and maskNode == nil: return paint
  if (clipNode != nil and clipNode.child.len == 0) or
     (maskNode != nil and maskNode.child.len == 0):
    return nil
  var scene = newScene()
  discard scene.add(paint)
  if clipNode != nil:
    var clipped: Paint = nil
    if not applyClip(ctx, scene, paint, node, clipNode, vBox, clipped): return nil
    scene = Scene(clipped)
  if maskNode != nil: scene = applyMask(ctx, paint, scene, node, maskNode, vBox, clipNode != nil)
  scene

proc applyFilter*(ctx: BuildCtx, paint: Paint, node: SvgNode, vBox: Box): Paint =
  ## Wraps the paint in a scene with the gaussian blur effects of the filter, clipped
  ## to the filter region.
  let filterNode = node.style.filter.node
  if filterNode == nil or filterNode.child.len == 0: return paint
  let filter = filterNode.filter
  let scene = newScene()
  let bbox = boxOf(paint)
  var clipBox = if filter.filterUserSpace: filter.box else: objectBoundingBox(filter.box, bbox)
  let primitiveUserSpace = filter.primitiveUserSpace
  let sx = paint.transform().e11
  let sy = paint.transform().e22
  for child in filterNode.child:
    if child.kind != SvgNodeType.GaussianBlur: continue
    let gauss = child.gaussianBlur
    let direction =
      if gauss.stdDevX > 0.0'f32: (if gauss.stdDevY > 0.0'f32: 0 else: 1)
      else: (if gauss.stdDevY > 0.0'f32: 2 else: -1)
    if direction == -1: continue
    var stdDevX = gauss.stdDevX
    var stdDevY = gauss.stdDevY
    if gauss.hasBox:
      var gaussBox = gauss.box
      let isPercent = gauss.isPercentage
      if primitiveUserSpace:
        if isPercent[0]: gaussBox.x *= ctx.global.w
        if isPercent[1]: gaussBox.y *= ctx.global.h
        if isPercent[2]: gaussBox.w *= ctx.global.w
        if isPercent[3]: gaussBox.h *= ctx.global.h
      else:
        stdDevX *= bbox.w
        stdDevY *= bbox.h
        if isPercent[0]: gaussBox.x = bbox.x + gauss.box.x * bbox.w
        if isPercent[1]: gaussBox.y = bbox.y + gauss.box.y * bbox.h
        if isPercent[2]: gaussBox.w *= bbox.w
        if isPercent[3]: gaussBox.h *= bbox.h
      clipBox.intersect(gaussBox)
    elif not primitiveUserSpace:
      stdDevX *= bbox.w
      stdDevY *= bbox.h
    let sigma = 1.25'f32 * (if direction == 2: stdDevY * sy else: stdDevX * sx)
    discard scene.gaussianBlur(float64(sigma), direction, int(gauss.edgeModeWrap), 55)
  discard scene.add(paint)
  let clipShape = newShape()
  discard clipShape.appendRect(clipBox.x, clipBox.y, clipBox.w, clipBox.h)
  discard scene.clip(clipShape)
  scene