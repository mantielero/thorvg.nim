## Accessor: pre-order traversal of a paint tree with a callback.
##
## Ported from `src/renderer/tvgAccessor.h` / `tvgAccessor.cpp` (and the generic
## `Picture::paint(id)` fallback of tvgPicture.cpp).
##
## - `newAccessor()`, `set(a, paint, fn)`: calls `fn` for `paint` and then for every
##   descendant (scenes: their children; pictures: the loaded vector content; shapes
##   and text: none). `fn` returns false to stop. The C++ `void* data` is replaced by
##   the closure's captured variables.
## - `generateId(name)`: the hash (djb2) used for `Paint.id`.
## - `name(a, id)`: the original name of an id, available inside callbacks when the
##   traversed root is a Picture with `accessible = true` and its loader keeps an id
##   map; "" otherwise.
## - `paintById(pic, id)`: `Picture::paint(id)`, the first paint with that id.
## Deviation (DECISIONS.md D-L7-3): the iterator objects are replaced by `children`;
## the child list is snapshotted before visiting it.

import ../core/[types, compressor]
import ./[paint, scene, picture, loader]

export AccessorFunc, AccessorEntity

type Accessor* = ref object
  root: Paint
  accessible: bool        ## the root is an accessible Picture (loader id map)

proc newAccessor*(): Accessor = Accessor()

func generateId*(name: string): uint32 =
  ## Unique id (hash key) of a name; use it to set `Paint.id` (`Accessor::id`).
  djb2Encode(name)

proc children*(p: Paint): seq[Paint] =
  ## The paints nested in `p` (`AccessorIterator`); a picture is loaded first.
  if p of Scene:
    result = Scene(p).paints
  elif p of Picture:
    let content = Picture(p).loadContent()
    if content != nil: result = @[content]

proc access(p: Paint, fn: AccessorFunc): bool =
  ## Visits `p`'s descendants in pre-order; false when `fn` asked to stop.
  for child in p.children:
    if not fn(child): return false
    if not access(child, fn): return false
  true

proc set*(a: Accessor, p: Paint, fn: AccessorFunc): Result =
  ## Traverses `p` and its descendants calling `fn`.
  if p == nil or fn == nil: return Result.InvalidArguments
  a.root = p
  a.accessible = p of Picture and Picture(p).accessible
  if a.accessible:
    let l = Picture(p).loader
    if l != nil: l.access(fn)
  elif fn(p):
    discard access(p, fn)
  a.accessible = false
  a.root = nil
  Result.Success

proc name*(a: Accessor, id: uint32): string =
  ## The name of `id` (only during `set` on an accessible Picture), else "".
  var entity: AccessorEntity
  if a.accessible and Picture(a.root).loader.access(id, entity): entity.name else: ""

proc paintById*(pic: Picture, id: uint32): Paint =
  ## The first paint of the picture with that id, nil when none (`Picture::paint`).
  if pic.accessible and pic.loader != nil:
    var entity: AccessorEntity
    if pic.loader.access(id, entity): return entity.paint
    return nil
  var found: Paint = nil
  discard newAccessor().set(pic, proc (p: Paint): bool =
    if p.id == id:
      found = p
    found == nil)
  found
