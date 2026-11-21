## Animation: a Picture whose content is driven by a playable loader.
##
## Ported from `src/renderer/tvgAnimation.h` / `tvgAnimation.cpp`.
##
## Public API (stable; concrete animation loaders such as GIF or Lottie are written
## against `AnimLoader` in `renderer/loader.nim`):
## - `newAnimation()`, `picture(a)`: the picture to add to a canvas; load content
##   into it with `picture.load(...)`.
## - `frame(a, no)`: `Success`; `InsufficientCondition` without a loader or when the
##   loader refuses the frame; `NonSupport` when the loader is not playable.
## - `totalFrame(a)`, `curFrame(a)`, `duration(a)`: 0 without a playable loader.
## - `segment(a, begin, end)` / `segment(a, begin, end: var float32)`: set / read the
##   playback range; `InsufficientCondition` without a loader, `NonSupport` when
##   not playable.
## - `unload(a)`: releases the loader (the C++ destructor does this).
##
## How a loader implements it: subclass `AnimLoader`, call `initAnimLoader(l, kind)`
## in the constructor (sets `playable`), override the `frame`, `curFrame`, `duration`,
## `totalFrame`, `segment` methods and `sync` (called by the picture on the next
## update after `frame` marked it dirty) and `paint()` for the vector content.
## `frame` returns true when the content changed; `Animation.frame` then marks the
## picture's children as modified, so the next canvas `update` re-syncs it.

import ../core/types
import ./[render, paint, picture, loader]

type Animation* = ref object
  pic: Picture

proc newAnimation*(): Animation =
  Animation(pic: newPicture())

proc picture*(a: Animation): Picture = a.pic
  ## The picture that shows the animation (owned by the animation).

proc unload*(a: Animation) = a.pic.unload()
  ## Releases the loader of the picture; call it when the animation is discarded.

proc animLoader(a: Animation): AnimLoader =
  ## The playable loader of the picture, nil when there is none (or not playable).
  let l = a.pic.loader
  if l != nil and l.playable and l of AnimLoader: AnimLoader(l) else: nil

proc frame*(a: Animation, no: float32): Result =
  ## Shows frame `no`; the picture is marked for update when it changed.
  let l = a.pic.loader
  if l == nil: return Result.InsufficientCondition
  if not l.playable: return Result.NonSupport
  let al = a.animLoader()
  if al == nil: return Result.NonSupport
  if al.frame(no):
    a.pic.mark RenderUpdateFlag.Children
    return Result.Success
  Result.InsufficientCondition

proc curFrame*(a: Animation): float32 =
  let al = a.animLoader()
  if al == nil: 0.0'f32 else: al.curFrame()

proc totalFrame*(a: Animation): float32 =
  let al = a.animLoader()
  if al == nil: 0.0'f32 else: al.totalFrame()

proc duration*(a: Animation): float32 =
  let al = a.animLoader()
  if al == nil: 0.0'f32 else: al.duration()

proc segment*(a: Animation, b, e: float32): Result =
  ## Restricts playback to `b ..< e` (frame numbers).
  let l = a.pic.loader
  if l == nil: return Result.InsufficientCondition
  let al = a.animLoader()
  if al == nil: return Result.NonSupport
  al.segment(b, e)

proc segment*(a: Animation, b, e: var float32): Result =
  ## Reads the current playback range.
  let l = a.pic.loader
  if l == nil: return Result.InsufficientCondition
  let al = a.animLoader()
  if al == nil: return Result.NonSupport
  al.segment(b, e)
  Result.Success
