## Saver: exports a paint or an animation to a file through a SaveModule.
##
## Ported from `src/renderer/tvgSaver.cpp` / `tvgSaveModule.h`.
##
## The saver itself only knows the file-extension registry: concrete formats are
## `SaveModule` subclasses that register themselves with `registerSaver("gif", ctor)`
## when their module is imported (upstream GIF/Lottie savers are not ported; a
## minimal PNG saver lives in `savers/png.nim`, an addition without C++ equivalent).
##
## A module implements `save(paint, ...)` and/or `save(animation, ...)` (return true
## when the job was started) and `close()` (finish; called by `sync`).
## Results as upstream: `save` -> InvalidArguments (nil), InsufficientCondition
## (already saving / animation without frames), NonSupport (unknown extension),
## Unknown (the module failed); `sync` -> InsufficientCondition when nothing is
## being saved. There is no reference counting: a failed save leaves the paint alone.

import std/tables
import ../core/[types, geom]
import ./[paint, loader, animation]

type
  SaveModule* = ref object of RootObj
    ## Base of the concrete savers.

  SaveModuleCtor* = proc (): SaveModule {.nimcall.}

  Saver* = ref object
    module: SaveModule         ## the running job
    bg: Paint                  ## background drawn behind the content

var registry: Table[string, SaveModuleCtor]

method save*(m: SaveModule, paint: Paint, bg: Paint, filename: string,
    quality: uint32): bool {.base.} = false

method save*(m: SaveModule, anim: Animation, bg: Paint, filename: string,
    quality: uint32, fps: uint32): bool {.base.} = false

method close*(m: SaveModule): bool {.base.} = true

proc registerSaver*(ext: string, ctor: SaveModuleCtor) =
  ## Registers (or replaces) the saver of a file extension (without the dot,
  ## case-sensitive like upstream).
  registry[ext] = ctor

proc findModule(filename: string): SaveModule =
  ## `_find(filename)`: a new module for the extension, nil when unsupported.
  let ext = fileExt(filename)
  if ext in registry: registry[ext]() else: nil

proc newSaver*(): Saver = Saver()

proc background*(s: Saver, p: Paint): Result =
  ## Sets the paint drawn behind the saved content.
  if p == nil: return Result.InvalidArguments
  s.bg = p
  Result.Success

proc save*(s: Saver, p: Paint, filename: string, quality: uint32 = 100): Result =
  ## Starts exporting `p` to `filename` (the format follows the extension).
  if p == nil: return Result.InvalidArguments
  if s.module != nil: return Result.InsufficientCondition
  let m = findModule(filename)
  if m == nil: return Result.NonSupport
  if not m.save(p, s.bg, filename, quality): return Result.Unknown
  s.module = m
  Result.Success

proc save*(s: Saver, a: Animation, filename: string, quality: uint32 = 100,
    fps: uint32 = 0): Result =
  ## Starts exporting the animation; `fps` 0 keeps the original frame data.
  if a == nil: return Result.InvalidArguments
  if zero(a.totalFrame()): return Result.InsufficientCondition
  if s.module != nil: return Result.InsufficientCondition
  let m = findModule(filename)
  if m == nil: return Result.NonSupport
  if not m.save(a, s.bg, filename, quality, fps): return Result.Unknown
  s.module = m
  Result.Success

proc sync*(s: Saver): Result =
  ## Guarantees the running job is finished and releases it.
  if s.module == nil: return Result.InsufficientCondition
  discard s.module.close()
  s.module = nil
  Result.Success
