## Font loading entry points (`Text::load` / `Text::unload` of tvgText.cpp and
## `TextImpl::load` of tvgText.h).
##
## Fonts live in the loader manager under their name: the file name without
## extension for `loadFont(path)`, the given name for `loadFont(name, data)`.
## A font loader module (`thorvg/loaders/font/loader`) must be imported by the
## application (or test) so that it registers itself for `FileType.Sfnt`;
## renderer/ cannot import loaders/.
##
## Deviations (DECISIONS.md D-T19-*): data is always copied, a font that is
## already loaded is not loaded twice (no `sharing` leak), and `unloadFont`
## really drops an unused font (upstream's lookup + retrieve pair never freed it).

import ../core/[types, str]
import ./loader

proc known(name: string): bool =
  ## True when a cached font with that name exists (the lookup is not counted).
  let l = font(name)
  if l != nil: dec l.sharing
  l != nil

proc loadFont*(path: string): Result =
  ## Loads a font file; later `Text.font(name)` finds it by its base name.
  if path.len == 0: return Result.InvalidArguments
  if known(strFilename(path)): return Result.Success
  var ret = Result.InvalidArguments
  let l = acquireFile(path, LoaderOps(), ret)
  if l == nil: return ret
  if not (l of FontLoader):
    discard retrieve(l)
    return Result.NonSupport
  Result.Success

proc loadFont*(name, data: string, mime: string = ""): Result =
  ## Loads a font from memory under `name` (the mime type is not needed:
  ## only sfnt fonts exist).
  if name.len == 0 or data.len == 0: return Result.InvalidArguments
  if known(name): return Result.Success
  if acquireFont(name, data, LoaderOps()) == nil: return Result.NonSupport
  Result.Success

proc unloadFont*(name: string): Result =
  ## Unloads a font by name (or by the path it was loaded from). A font that
  ## texts still use stays alive until they release it.
  if name.len == 0: return Result.InvalidArguments
  var l = font(name)
  if l == nil: l = font(strFilename(name))
  if l == nil: return Result.InsufficientCondition
  dec l.sharing                       # undo the lookup
  if l.sharing == 0: discard retrieve(l)
  Result.Success
