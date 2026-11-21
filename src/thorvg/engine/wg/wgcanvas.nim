## WebGPU canvas facade (`WgCanvas` of tvgCanvas.cpp, W7).
##
## Separate import (`import thorvg/engine/wg/wgcanvas`), like `engine/gl/glcanvas`:
## the default `import thorvg` stays free of WG. The canvas renders with the WG
## (wgpu-native) engine to a `WGPUSurface` (`type = 0`) or `WGPUTexture`
## (`type = 1`) provided by the application.
##
## Runtime/build/link/parity require wgpu-native headers/libs (R-WG-1); WG FFI
## values/layouts are scaffolding pending verification vs target `webgpu.h`
## (R-WG-2). This facade wires the renderer/canvas API; actual rendering depends
## on a correct wgpu-native binding at build time.

import ../../core/types
import ../../renderer/canvas
import ./[wg_types, renderer]

export canvas
export wg_types
export termWgRenderer

proc wgTerm*(): bool =
  ## Global WG engine termination hook (`WgRenderer::term`).
  termWgRenderer()

proc target*(c: Canvas; ctx: WgCanvasContext; target: pointer; w, h: uint32;
             cs: ColorSpace; typ: int = 0): Result =
  ## `WgCanvas::target(const Context&, target, w, h, cs, type)` on an existing WG canvas.
  ## Binds (or rebinds) the canvas to a WGPU surface/texture target.
  if c == nil: return Result.InvalidArguments
  if c.status == CanvasStatus.Updating or c.status == CanvasStatus.Drawing:
    return Result.InsufficientCondition
  let r = asWgRenderer(c.renderer)
  if r == nil: return Result.InsufficientCondition
  result = r.target(ctx, target, w, h, cs, typ)
  if result == Result.Success:
    result = c.retarget(w, h, r.mainSurface().cs)

proc target*(c: Canvas; device, instance, target: pointer; w, h: uint32;
             cs: ColorSpace; typ: int = 0): Result =
  ## Convenience overload matching `WgCanvas::target(device, instance, target, w,h,cs,type)`.
  ## Builds a context with `adapter = nil`.
  var ctx = WgCanvasContext(instance: instance, adapter: nil, device: device)
  c.target(ctx, target, w, h, cs, typ)

proc retarget*(c: Canvas; ctx: WgCanvasContext; target: pointer; w, h: uint32;
               cs: ColorSpace; typ: int = 0): Result =
  ## Same as `target` (retarget an existing WG canvas).
  c.target(ctx, target, w, h, cs, typ)

proc newWgCanvas*(op: EngineOption = EngineOption.Default): Canvas =
  ## Creates a WG canvas backed by `WgRenderer` (C++ `WgCanvas::gen` shape).
  ## Call `target(...)` before drawing. `op` is accepted for API parity (WG ignores options).
  discard op
  newCanvas(newWgRenderer())

proc destroy*(c: Canvas) =
  ## Releases paints and WG renderer resources, clears the renderer target, and
  ## decrements/terms WG renderer state (best-effort C++ dtor semantics).
  let r = asWgRenderer(c.renderer)
  if r != nil:
    discard c.remove(nil)
    # Clear/retire the GPU target before releasing renderer resources.
    discard r.target(WgCanvasContext(), nil, 0'u32, 0'u32, ColorSpace.Unknown, 0)
    r.destroy()
    discard termWgRenderer()
