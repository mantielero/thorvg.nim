## Per-paint work of the CPU engine: shape and image "tasks" run synchronously.
##
## Ported from `SwTask`, `SwShapeTask` and `SwImageTask` of
## `src/renderer/cpu_engine/tvgSwRenderer.cpp`. The C++ queues the tasks on a thread
## pool; here `runShapeTask` / `runImageTask` are called immediately by the renderer
## (DECISIONS D4), so there is no `done()`, no dependency list and no dirty-region
## bookkeeping (partial rendering is out of scope, D5). The task keeps its own copy of
## the `RenderShape` (C++ keeps a pointer to the paint's member).

import std/[options, math]
import ../../core/[types, geom]
import ../../renderer/render
import ./[common, rle_clip, shape, fill, raster, image]

type
  SwTask* = ref object of SwRenderData
    ## `SwRenderData` plus the scheduling state of the C++ `SwTask`.
    valid*: bool                ## something was rendered into `bbox`
    clipper*: bool              ## the shape is used as a clip path
    clipBox*: Region            ## clipping region (viewport and surface)
    pending*: RenderUpdateFlags ## flags kept while the task was skipped (C++ `flags[1]`)

proc newShapeTask*(): SwTask = SwTask(shape: SwShape(), isImage: false)

proc newImageTask*(source: RenderSurface): SwTask =
  SwTask(image: SwImage(surface: source), isImage: true)

proc ready*(t: SwTask, skip: bool): bool =
  ## True when the update is skipped (invisible); remembers the flags for later.
  if skip:
    if RenderUpdateFlag.Color in t.flags: t.valid = false
    t.pending = t.flags
    return true
  t.flags = t.flags + t.pending
  t.pending = {}
  false

proc clipWith*(t: SwTask, target: SwRle): bool =
  ## Intersects `target` with the area of this (clipper) task.
  if t.isImage: return true  # an image used as clip path is an error upstream, ignored
  if target == nil: return false
  if t.shape.strokeRle != nil: rleClip(target, t.shape.strokeRle)
  elif t.shape.fastTrack: rleClip(target, t.bbox)
  elif t.shape.rle != nil: rleClip(target, t.shape.rle)
  else: false

# ---- shapes ----------------------------------------------------------------

proc validStrokeWidth(t: SwTask): float32 =
  if t.rshape.stroke.isNone: return 0.0'f32
  let width = t.rshape.stroke.get.width
  if zero(width): return 0.0'f32
  if not t.clipper and t.rshape.stroke.get.fill.isNone and t.rshape.stroke.get.color.a == 0:
    return 0.0'f32
  if zero(t.rshape.stroke.get.trim.begin - t.rshape.stroke.get.trim.`end`): return 0.0'f32
  width * sqrt(t.transform.e11 * t.transform.e11 + t.transform.e12 * t.transform.e12)

proc antialiasing(t: SwTask, enabled: bool, strokeWidth: float32): bool =
  ## Thick strokes cover the outline beneath them, so only thin, dashed, trimmed,
  ## stroke-first or translucent strokes need the anti-aliased fill.
  if not enabled: return false
  if strokeWidth < 2.0'f32 or t.rshape.stroke.isNone: return true
  let st = t.rshape.stroke.get
  st.dash.pattern.len > 0 or st.first or t.rshape.trimpath or st.color.a < 255

proc buildShape(t: SwTask, clips: seq[RenderData], sfc: SwSurface, aa: bool): bool =
  ## Fill, stroke and clipping; false means "dismiss" (nothing visible).
  let flags = t.flags
  let strokeWidth = validStrokeWidth(t)
  let updateShape = flags * {RenderUpdateFlag.Path, RenderUpdateFlag.Transform,
                             RenderUpdateFlag.Clip} != {}
  var updateFill = flags * {RenderUpdateFlag.Color, RenderUpdateFlag.Gradient,
                            RenderUpdateFlag.Transform} != {}
  if updateShape:
    shapeReset(t.shape)
    if t.rshape.fill.isSome or t.rshape.color.a > 0 or t.clipper:
      if not shapeGenRle(t.shape, t.rshape, t.transform, t.clipBox, t.bbox, clips.len > 0,
                         antialiasing(t, aa, strokeWidth)):
        updateFill = false
        t.bbox = Region()
  if updateFill and t.rshape.fill.isSome:
    if not fillPrepare(t.shape.fill, t.rshape.fill.get, t.transform, sfc, t.opacity,
                       RenderUpdateFlag.Gradient in flags): return false
  if strokeWidth > 0.0'f32:
    let updateStroke = updateShape or RenderUpdateFlag.Stroke in flags
    if updateStroke and not shapeGenStrokeRle(t.shape, t.rshape, t.transform, t.clipBox,
                                              t.bbox, aa): return false
    let ctable = RenderUpdateFlag.GradientStroke in flags
    if (ctable or RenderUpdateFlag.Transform in flags) and t.shape.stroke != nil and
        t.rshape.stroke.get.fill.isSome:
      if not fillPrepare(t.shape.stroke.fill, t.rshape.stroke.get.fill.get, t.transform, sfc,
                         t.opacity, ctable): return false
  else:
    shapeDelStroke(t.shape)
  shapeDelOutline(t.shape)
  for c in clips:
    if c != nil:
      let clipTask = SwTask(c)
      let clipShape = clipTask.clipWith(t.shape.rle)
      let clipStroke = clipTask.clipWith(t.shape.strokeRle)
      if not clipShape and not clipStroke: return false
  true

proc runShapeTask*(t: SwTask, clips: seq[RenderData], sfc: SwSurface, aa: bool) =
  if buildShape(t, clips, sfc, aa): t.valid = true
  else:  # dismiss
    shapeReset(t.shape)
    rleReset(t.shape.strokeRle)
    t.valid = false

# ---- images ----------------------------------------------------------------

proc runImageTask*(t: SwTask, clips: seq[RenderData], sfc: SwSurface) =
  let img = t.image
  let source = img.surface
  # convert the color space if it is not aligned
  discard rasterConvertCS(source, sfc.cs)
  rasterPremultiplySurface(source)
  img.w = source.w
  img.h = source.h
  img.stride = source.stride
  img.channelSize = source.channelSize
  img.alphaIgnored = source.opaque

  let updateImage = t.flags * {RenderUpdateFlag.Image, RenderUpdateFlag.Clip,
                               RenderUpdateFlag.Transform} != {}
  let updateColor = RenderUpdateFlag.Color in t.flags
  var failed = false
  # an invisible image turned visible by alpha
  if (updateImage or updateColor) and t.opacity > 0:
    if updateImage: imageReset(img)
    if source.data.len == 0 or img.w == 0 or img.h == 0: failed = true
    elif not imagePrepare(img, t.transform, t.clipBox, t.bbox): failed = true
    else:
      t.valid = true
      if clips.len > 0:
        if not imageGenRle(img, t.bbox, false): failed = true
        else:
          for c in clips:
            if not failed and c != nil and not SwTask(c).clipWith(img.rle): failed = true
      else: img.rle = nil
  if failed:
    t.bbox = Region()
    imageReset(img)
