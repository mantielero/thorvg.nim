## Canvas: owns a root scene and drives update / draw / sync on a renderer.
##
## Ported from `src/renderer/tvgCanvas.h` / `tvgCanvas.cpp` (`Canvas::Impl`).
## The canvas never imports an engine: it works with the abstract `RenderMethod`.
## An engine front end (`SwCanvas::target` in C++) creates the canvas with its
## renderer, sets up its own target and then calls `retarget`.

import ../core/[types, geom]
import ./[render, paint, scene, loader]

type
  CanvasStatus* {.pure.} = enum
    Synced, Painting, Updating, Drawing, Damaged

  Canvas* = ref object
    scene*: Scene
    renderer*: RenderMethod
    vport*: Region
    status*: CanvasStatus
    clips: seq[RenderData]

proc newCanvas*(renderer: RenderMethod): Canvas =
  ## A canvas drawing through `renderer` (must not be nil).
  Canvas(scene: newScene(), renderer: renderer,
         vport: Region(xMin: 0, yMin: 0, xMax: high(int32), yMax: high(int32)))

proc paints*(c: Canvas): seq[Paint] = c.scene.paints

proc add*(c: Canvas, target: Paint, at: Paint = nil): Result =
  ## Appends `target` to the root scene, or inserts it before `at`.
  if target == nil: return Result.InvalidArguments
  if target.renderer != nil and target.renderer != c.renderer:
    return Result.InsufficientCondition  # owned by a different renderer
  if c.status == CanvasStatus.Drawing: return Result.InsufficientCondition
  c.status = CanvasStatus.Painting
  c.scene.add(target, at)

proc remove*(c: Canvas, paint: Paint): Result =
  ## Removes one paint, or every paint with nil. Not allowed while drawing.
  if c.status == CanvasStatus.Drawing: return Result.InsufficientCondition
  c.status = CanvasStatus.Painting
  if paint == nil: c.scene.clear() else: c.scene.remove(paint)

proc update*(c: Canvas): Result =
  ## Prepares all paints with the engine.
  if c.status == CanvasStatus.Updating: return Result.Success
  if c.status == CanvasStatus.Drawing: return Result.InsufficientCondition
  # TODO in C++: All is too harsh, can be optimized.
  let flags = if c.status == CanvasStatus.Damaged: AllUpdateFlags else: {}
  if not c.renderer.preUpdate(): return Result.InsufficientCondition
  c.clips.setLen(0)
  discard c.scene.update(c.renderer, identity(), c.clips, 255, flags)
  if not c.renderer.postUpdate(): return Result.InsufficientCondition
  c.status = CanvasStatus.Updating
  Result.Success

proc draw*(c: Canvas, clear = true): Result =
  ## Renders the scene (updating first when needed).
  if c.status == CanvasStatus.Drawing: return Result.InsufficientCondition
  if c.status in {CanvasStatus.Painting, CanvasStatus.Damaged}: discard c.update()
  if c.status != CanvasStatus.Updating: return Result.InsufficientCondition
  if clear and not c.renderer.clear(): return Result.InsufficientCondition
  if not c.renderer.preRender(): return Result.InsufficientCondition
  if not c.scene.render(c.renderer) or not c.renderer.postRender():
    return Result.InsufficientCondition
  c.status = CanvasStatus.Drawing
  Result.Success

proc sync*(c: Canvas): Result =
  ## Waits for the (possibly asynchronous) rendering to finish.
  if c.status == CanvasStatus.Synced: return Result.Success
  if c.renderer.sync():
    c.status = CanvasStatus.Synced
    return Result.Success
  Result.Unknown

proc viewport*(c: Canvas, x, y, w, h: int32): Result =
  ## Restricts drawing to a region; only allowed right after `sync`.
  if c.status != CanvasStatus.Synced and c.status != CanvasStatus.Damaged:
    return Result.InsufficientCondition
  var val = Region(xMin: x, yMin: y, xMax: x + w, yMax: y + h)
  let surface = c.renderer.mainSurface()
  if surface != nil and surface.w > 0 and surface.h > 0:
    val = intersect(val, Region(xMin: 0, yMin: 0, xMax: int32(surface.w),
                                yMax: int32(surface.h)))
  if c.vport == val: return Result.Success
  c.renderer.vport = val
  c.vport = val
  c.status = CanvasStatus.Damaged
  Result.Success

proc retarget*(c: Canvas, w, h: uint32, cs: ColorSpace): Result =
  ## Called by an engine front end after its target was set up successfully
  ## (the tail of `SwCanvas::target`): resets the viewport, marks every paint
  ## dirty and tells the bitmap loaders which color space to decode into.
  if c.status == CanvasStatus.Updating or c.status == CanvasStatus.Drawing:
    return Result.InsufficientCondition
  c.vport = Region(xMin: 0, yMin: 0, xMax: int32(w), yMax: int32(h))
  c.renderer.vport = c.vport
  c.status = CanvasStatus.Damaged  # paints must be updated again with this target
  setDesiredColorSpace(cs)
  Result.Success
