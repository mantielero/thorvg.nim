## SVG loader: the `ImageLoader` for `.svg` files and `svg` / `svg+xml` memory data.
##
## Ported from the `SvgLoader` class of `modules/svg/tvgSvgLoader.cpp` (`header`, `run`,
## `open`, `read`, `resize`, `paint`, `close`). Importing this module registers the loader
## (`FileType.Svg`). The parse (`loader_parse`) happens in `openData`; the scene build
## (`builder`) happens in `openData` when the file has neither view box nor size (the
## original forces it in `header` so the size is known) and in `read` otherwise.
##
## Deviations (DECISIONS.md D-T17b-*): the build is synchronous (no task scheduler, D4);
## the first `paint()` gives the loader's own scene and later ones a duplicate (the
## original tests the reference count); the base directory of the file (`ops.rpath`) is
## used for relative image paths (the original never sets it); the accessor API is not
## ported.

import std/strutils
import ../../core/types
import ../../renderer/[paint, scene, fonts, loader]
import ./[nodes, loader_parse, builder]

type SvgLoader* = ref object of ImageLoader
  content: string
  data: SvgLoaderData
  svgPath: string
  root: Scene
  built, handedOut: bool

proc newSvgLoader*(): SvgLoader = SvgLoader(kind: FileType.Svg)

proc build(l: SvgLoader) =
  ## `SvgLoader::run`: builds the scene once; then `w` / `h` take the final size.
  if l.built: return
  l.built = true
  if l.data.empty: l.root = newScene()
  elif l.data.status == Result.Success:
    l.root = svgSceneBuild(l.data, l.svgPath)
    finishLoad(l.data)
  l.w = l.data.w
  l.h = l.data.h

method openData*(l: SvgLoader, data: string, ops: LoaderOps): Result =
  l.content = data
  l.svgPath = ops.rpath
  l.data = parseSvg(data)
  if l.data.status == Result.InvalidArguments: return Result.InvalidArguments
  l.w = l.data.w
  l.h = l.data.h
  # without view box and size the size comes from the whole picture: build right now
  if SvgViewFlag.Viewbox notin l.data.viewFlag: l.build()
  Result.Success

method read*(l: SvgLoader): bool =
  if l.content.len == 0: return false
  if not l.baseRead() or l.root != nil: return true
  l.build()
  true

method resize*(l: SvgLoader, p: Paint, w, h: float32): bool =
  if p == nil: return false
  let m = Matrix(e11: w / l.w, e22: h / l.h, e33: 1.0'f32)
  discard p.transform(m)
  true

method close*(l: SvgLoader): bool =
  if not l.baseClose(): return false
  for f in l.data.fonts:
    if f.name.len > 0: discard unloadFont(f.name)
  true

method paint*(l: SvgLoader): Paint =
  if l.root == nil: return nil
  if not l.handedOut:
    l.handedOut = true
    return l.root
  l.root.duplicate()

proc sniffSvg(data: string): bool = "<svg" in data

registerLoader(FileType.Svg, proc (): Loader = newSvgLoader(), sniffSvg)
