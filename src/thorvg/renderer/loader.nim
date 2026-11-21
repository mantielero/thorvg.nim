## Loader base classes and the loader registry / manager.
##
## Ported from `src/renderer/tvgLoader.h`, `tvgLoaderMgr.h` and `tvgLoaderMgr.cpp`.
##
## Stable API used by the loader modules (png, svg, fonts...):
## - Subclass `ImageLoader` / `BitmapLoader` / `AnimLoader` / `FontLoader`
##   (`ref object of ...`) and set `kind` (and `w`, `h` for images).
## - Override the base `method`s: `openData(l, data: string, ops)` (data is a byte
##   string; use `toOpenArrayByte(data, 0, data.high)` for a byte view), optionally
##   `openFile(l, path, ops)` (the default reads the file and calls `openData`),
##   `read`, `close`, `resize`, `sync`, and for images `paint()` / `bitmap()`.
##   Call `baseRead(l)` / `baseClose(l)` from overrides (`Loader::read/close`).
## - Register a constructor once from the loader module:
##   `registerLoader(FileType.Png, proc (): Loader = PngLoader(kind: FileType.Png))`.
## - The manager picks a loader by extension, mime type or (for unknown input) by
##   probing every registered loader in `FileType` order, skipping the ones whose
##   optional `sniff(data)` header test fails.
## Deviations (DECISIONS.md): data buffers are always copied strings (no Borrow /
## Transfer ownership, so no pointer-keyed cache for memory data; only file loaders
## are cached by path); the raw pixel loader is built in (`RawLoader`).

import std/strutils
import ../core/[types, path]
import ./[render, paint]

type
  FileType* {.pure.} = enum
    Svg, Lot, Sfnt, Png, Jpg, Webp, Media, Raw, Gif, Unknown

  AssetResolver* = proc (paint: Paint, src: string): bool

  AccessorFunc* = proc (paint: Paint): bool
    ## Accessor callback: return false to stop the traversal.

  AccessorEntity* = object
    ## An id-addressable paint of a loaded vector asset (`AccessorEntity`).
    id*: uint32                      ## equal to `paint.id`
    paint*: Paint
    name*: string

  LoaderOps* = object
    ## Per-request options (`PictureOps` in C++).
    rpath*: string                   ## base directory for relative resources
    resolver*: AssetResolver
    resolverFallback*: bool
    accessible*: bool                ## the loader should keep an id map (Accessor)

  Loader* = ref object of RootObj
    kind*: FileType
    hashKey*: string                 ## cache key (file path)
    sharing*: int                    ## extra users of this loader
    readied*, cached*: bool

  ImageLoader* = ref object of Loader
    w*, h*: float32
    playable*: bool

  BitmapLoader* = ref object of ImageLoader
    surface*: RenderSurface

  RawLoader* = ref object of BitmapLoader

  AnimLoader* = ref object of ImageLoader
    segmentBegin*, segmentEnd*: float32

  FontMetrics* = object
    size*: Point
    scale*: float32
    align*, box*: Point
    spacing*: Point
    fontSize*: float32
    lines*: uint32
    length*: uint32
    wrap*: TextWrap
    engine*: RootRef                 ## engine extension (void* in C++)

  FontLoader* = ref object of Loader
    name*: string

  LoaderCtor* = proc (): Loader {.nimcall.}
  SniffProc* = proc (data: string): bool {.nimcall.}

  LoaderEntry = object
    ctor: LoaderCtor
    sniff: SniffProc

const FontDpi* = 96.0'f32 / 72.0'f32

var
  entries: array[FileType, LoaderEntry]
  active: seq[Loader]
  bitmapCs = ColorSpace.ARGB8888

func initFontMetrics*(): FontMetrics =
  FontMetrics(spacing: Point(x: 1.0'f32, y: 1.0'f32), lines: 1, wrap: TextWrap.None)

proc desiredColorSpace*(): ColorSpace = bitmapCs
  ## Color space the bitmap loaders should decode into (`BitmapLoader::cs`).

proc setDesiredColorSpace*(cs: ColorSpace) = bitmapCs = cs

# ---- Loader: overridable behavior ------------------------------------------

proc baseRead*(l: Loader): bool =
  ## `Loader::read`: true only on the first call.
  if l.readied: return false
  l.readied = true
  true

proc baseClose*(l: Loader): bool =
  ## `Loader::close`: true when nobody else shares the loader.
  if l.sharing == 0: return true
  dec l.sharing
  false

method openData*(l: Loader, data: string, ops: LoaderOps): Result {.base.} =
  Result.NonSupport

method openFile*(l: Loader, path: string, ops: LoaderOps): Result {.base.} =
  ## Default: read the whole file and hand it to `openData`.
  var content = ""
  try:
    content = readFile(path)
  except IOError:
    return Result.InvalidArguments
  if content.len == 0: return Result.InvalidArguments
  l.openData(content, ops)

method resize*(l: Loader, p: Paint, w, h: float32): bool {.base.} = false
method sync*(l: Loader): bool {.base.} = false
method cacheable*(l: Loader): bool {.base.} = true
method read*(l: Loader): bool {.base.} =
  ## True when the content is ready (also for an already-read shared loader).
  discard baseRead(l)
  true
method close*(l: Loader): bool {.base.} = baseClose(l)

method paint*(l: ImageLoader): Paint {.base.} = nil
  ## A vector loader returns a Paint the caller owns exclusively (it may be a
  ## duplicate of the loader's own tree when already handed out).

method bitmap*(l: ImageLoader): RenderSurface {.base.} = nil

method access*(l: ImageLoader, id: uint32, entity: var AccessorEntity): bool {.base.} =
  ## Looks an id up in the loader's id map (only loaders that keep one, with
  ## `LoaderOps.accessible`; default: none).
  false

method access*(l: ImageLoader, cb: AccessorFunc) {.base.} = discard
  ## Calls `cb` for every paint of the loader's id map (default: none).

method bitmap*(l: BitmapLoader): RenderSurface =
  if l.surface != nil and (l.surface.data.len > 0 or l.surface.buf8.len > 0): l.surface
  else: nil

proc initAnimLoader*(l: AnimLoader, kind: FileType) =
  ## `AnimLoader::AnimLoader`: a playable image loader. Call it in the constructor
  ## of every animation loader (`playable` is what `Animation` checks).
  l.kind = kind
  l.playable = true

# AnimLoader interface (see renderer/animation.nim): override these in a concrete
# animation loader; the defaults are the "nothing to play" answers.
method frame*(l: AnimLoader, no: float32): bool {.base.} = false
  ## Sets the current frame; true when the content changed (the picture is then
  ## re-synced through `sync` on its next update).

method totalFrame*(l: AnimLoader): float32 {.base.} = l.segmentEnd - l.segmentBegin
  ## Number of frames of the current segment.

method curFrame*(l: AnimLoader): float32 {.base.} = 0.0'f32
  ## The current frame number.

method duration*(l: AnimLoader): float32 {.base.} = 0.0'f32
  ## Duration in seconds.

method segment*(l: AnimLoader, b, e: float32): Result {.base.} = Result.NonSupport
  ## Restricts playback to the frames `b ..< e`.

proc segment*(l: AnimLoader, b, e: var float32) =
  ## The current segment (`AnimLoader::segment(float*, float*)`).
  b = l.segmentBegin
  e = l.segmentEnd

method get*(l: FontLoader, fm: var FontMetrics, text: string, len: uint32,
    output: var RenderPath): bool {.base.} = false

method transform*(l: FontLoader, p: Paint, fm: var FontMetrics,
    italicShear: float32) {.base.} = discard

method release*(l: FontLoader, fm: var FontMetrics) {.base.} = discard
method metrics*(l: FontLoader, fm: FontMetrics, output: var TextMetrics) {.base.} = discard

method glyphMetrics*(l: FontLoader, fm: FontMetrics, text: string, pos: int,
    output: var GlyphMetrics, next: var int): bool {.base.} = false

method copy*(l: FontLoader, src: FontMetrics, dst: var FontMetrics) {.base.} = dst = src

proc cache*(l: Loader, key: string): bool =
  ## Marks the loader as shareable under `key`.
  if not l.cacheable(): return false
  l.hashKey = key
  l.cached = true
  true

# ---- raw pixel loader --------------------------------------------------------

proc newRawLoader*(): RawLoader = RawLoader(kind: FileType.Raw)

proc openRaw*(l: RawLoader, pixels: seq[uint32], w, h: uint32, cs: ColorSpace): bool =
  ## `RawLoader::open`: wraps (a copy of) premultiplied/straight pixels.
  if not l.baseRead(): return true
  if w == 0 or h == 0 or pixels.len < int(w) * int(h): return false
  l.w = float32(w)
  l.h = float32(h)
  l.surface = newSurface(w, h, cs)
  l.surface.data = pixels
  true

method read*(l: RawLoader): bool =
  discard l.baseRead()
  true

# ---- mapping tables ------------------------------------------------------------

func fileExt*(path: string): string =
  ## Text after the last '.', or the whole path without a dot (`fileext`).
  let dot = path.rfind('.')
  if dot < 0: path else: path[dot + 1 .. ^1]

func fileTypeOfExt*(ext: string): FileType =
  case ext
  of "svg": FileType.Svg
  of "lot", "json": FileType.Lot
  of "ttf", "ttc", "otf", "otc": FileType.Sfnt
  of "png": FileType.Png
  of "jpg": FileType.Jpg
  of "webp": FileType.Webp
  of "mp4": FileType.Media
  of "gif": FileType.Gif
  else: FileType.Unknown

func fileTypeOfMime*(mime: string): FileType =
  case mime
  of "svg", "svg+xml": FileType.Svg
  of "lot", "lottie+json": FileType.Lot
  of "ttf", "otf": FileType.Sfnt
  of "png": FileType.Png
  of "jpg", "jpeg": FileType.Jpg
  of "webp": FileType.Webp
  of "mp4": FileType.Media
  of "gif": FileType.Gif
  of "raw": FileType.Raw
  else: FileType.Unknown

# ---- registry and manager -----------------------------------------------------

proc registerLoader*(kind: FileType, ctor: LoaderCtor, sniff: SniffProc = nil) =
  ## Registers (or replaces) the constructor of a file type.
  entries[kind] = LoaderEntry(ctor: ctor, sniff: sniff)

proc newLoader*(kind: FileType): Loader =
  ## A fresh loader of a type, nil when none is registered.
  if entries[kind].ctor != nil: entries[kind].ctor()
  elif kind == FileType.Raw: newRawLoader()
  else: nil

proc dirOf(path: string): string =
  let i = max(path.rfind('/'), path.rfind('\\'))
  if i < 0: "" else: path[0 .. i]

proc remember(l: Loader) = active.add l

proc findCached(key: string): Loader =
  for l in active:
    if l.cached and l.hashKey == key and l.kind != FileType.Sfnt:
      inc l.sharing
      return l
  nil

proc acquireFile*(path: string, ops: LoaderOps, ret: var Result): Loader =
  ## Loader for a file: cache, then by extension, then probing every type.
  if path.len == 0: return nil
  let cached = findCached(path)
  if cached != nil: return cached
  var ops = ops
  if ops.rpath.len == 0: ops.rpath = dirOf(path)
  ret = Result.InvalidArguments
  let kind = fileTypeOfExt(fileExt(path))
  if kind != FileType.Unknown:
    ret = Result.NonSupport
    let l = newLoader(kind)
    if l != nil:
      ret = l.openFile(path, ops)
      if ret == Result.Success:
        if l.cache(path): remember(l)
        return l
  if ret == Result.NonSupport: return nil
  for k in FileType.Svg ..< FileType.Unknown:
    let l = newLoader(k)
    if l != nil and l.openFile(path, ops) == Result.Success:
      ret = Result.Success
      if l.cache(path): remember(l)
      return l
  return nil

proc acquireData*(data: string, mime: string, ops: LoaderOps, ret: var Result): Loader =
  ## Loader for memory data: by mime type, then probing (header sniffing).
  ret = Result.InvalidArguments
  if mime.len > 0:
    let kind = fileTypeOfMime(mime)
    if kind != FileType.Unknown: ret = Result.NonSupport
    let l = newLoader(kind)
    if l != nil:
      ret = l.openData(data, ops)
      if ret == Result.Success: return l
  if ret == Result.NonSupport: return nil
  for k in FileType.Svg ..< FileType.Unknown:
    let sniff = entries[k].sniff
    if sniff == nil or sniff(data):
      let l = newLoader(k)
      if l != nil and l.openData(data, ops) == Result.Success:
        ret = Result.Success
        return l
  return nil

proc acquireRaw*(pixels: seq[uint32], w, h: uint32, cs: ColorSpace): Loader =
  ## Loader for a raw pixel buffer (always built in; nil when invalid).
  let l = newRawLoader()
  if l.openRaw(pixels, w, h, cs): l else: nil

proc font*(name: string): Loader =
  ## A cached font loader with that name (its `sharing` is incremented).
  for l in active:
    if l.kind == FileType.Sfnt and l.cached and FontLoader(l).name == name:
      inc l.sharing
      return l
  nil

proc anyFont*(): Loader =
  for l in active:
    if l.cached and l.kind == FileType.Sfnt:
      inc l.sharing
      return l
  nil

proc acquireFont*(name: string, data: string, ops: LoaderOps): Loader =
  ## Loads a font from memory; the loader is always cached under `name`.
  let known = font(name)
  if known != nil: return known
  let l = newLoader(FileType.Sfnt)
  if l != nil and l.openData(data, ops) == Result.Success:
    FontLoader(l).name = name
    l.cached = true
    remember(l)
    return l
  nil

proc retrieve*(l: Loader): bool =
  ## Releases one use of a loader; unregisters it when the last user is gone.
  if l == nil: return false
  if l.close() and l.cached:
    let i = active.find(l)
    if i >= 0: active.delete(i)
  true

proc retrieve*(path: string): bool = retrieve(findCached(path))

proc termLoaders*() =
  ## Drops the globally shared font loaders (`LoaderMgr::term`).
  var i = 0
  while i < active.len:
    if active[i].kind == FileType.Sfnt: active.delete(i) else: inc i

proc activeLoaderCount*(): int = active.len
