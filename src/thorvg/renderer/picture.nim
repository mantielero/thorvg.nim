## Picture paint: a vector (loader-provided paint tree) or a bitmap image.
##
## Ported from `src/renderer/tvgPicture.h` / `tvgPicture.cpp`. Accessor and
## animation-owned properties are out of scope. Deviations (DECISIONS.md): data is
## always copied (`load(data: string, ...)`), loaders are released with `unload`
## (there is no destructor), the asset resolver is a plain closure.

import ../core/[types, geom]
import ./[render, paint, loader]

type Picture* = ref object of Paint
  accessible*: bool           ## ask the loader for an id map; set before loading
  loader: ImageLoader
  vector: Paint               ## vector pictures use this
  bitmap: RenderSurface       ## bitmap pictures use this
  resolver: AssetResolver
  resolverFallback: bool
  origin: Point
  w, h: float32
  filter: FilterMethod
  resizing: bool

proc newPicture*(): Picture =
  result = Picture(filter: FilterMethod.Bilinear)
  initPaint(result)

# ---- loading ---------------------------------------------------------------------

proc load(pic: Picture): RenderUpdateFlags =
  ## Brings the loader's content in (first frame) or syncs the next frame.
  let l = pic.loader
  if l == nil: return {}
  if pic.vector != nil or pic.bitmap != nil:
    if l.sync() and pic.bitmap != nil: return {RenderUpdateFlag.Image}
  else:
    pic.vector = l.paint()
    if pic.vector != nil:
      pic.vector.parent = pic
      if pic.w != l.w or pic.h != l.h:
        if not pic.resizing:
          pic.w = l.w
          pic.h = l.h
        discard l.resize(pic.vector, pic.w, pic.h)
        pic.resizing = false
    else:
      pic.bitmap = l.bitmap()
      if pic.bitmap != nil: return {RenderUpdateFlag.Image}
  {}

proc adopt(pic: Picture, l: Loader): Result =
  if not (l of ImageLoader): return Result.NonSupport
  if Loader(pic.loader) == l:
    dec l.sharing  # keep the reference counting exact
    if pic.bitmap != nil: pic.mark RenderUpdateFlag.Image
    return Result.Success
  if pic.loader != nil: discard retrieve(pic.loader)
  pic.loader = ImageLoader(l)
  if not l.read(): return Result.Unknown
  pic.w = pic.loader.w
  pic.h = pic.loader.h
  pic.renderFlags = pic.renderFlags + AllUpdateFlags
  Result.Success

proc ops(pic: Picture, rpath = ""): LoaderOps =
  LoaderOps(rpath: rpath, resolver: pic.resolver, resolverFallback: pic.resolverFallback,
            accessible: pic.accessible)

proc load*(pic: Picture, path: string): Result =
  ## Loads a file (type by extension, then by probing).
  if path.len == 0: return Result.InvalidArguments
  if pic.vector != nil or pic.bitmap != nil: return Result.InsufficientCondition
  var ret = Result.InvalidArguments
  let l = acquireFile(path, pic.ops(), ret)
  if l != nil: pic.adopt(l) else: ret

proc load*(pic: Picture, data: string, mime: string, rpath: string = ""): Result =
  ## Loads memory data; `mime` may be empty (the loaders probe the data).
  if data.len == 0: return Result.InvalidArguments
  if pic.vector != nil or pic.bitmap != nil: return Result.InsufficientCondition
  var ret = Result.InvalidArguments
  let l = acquireData(data, mime, pic.ops(rpath), ret)
  if l != nil: pic.adopt(l) else: ret

proc loadRaw*(pic: Picture, pixels: seq[uint32], w, h: uint32, cs: ColorSpace): Result =
  ## Loads a raw pixel buffer (copied) of `w * h` pixels.
  if pixels.len == 0 or w == 0 or h == 0 or cs == ColorSpace.Unknown:
    return Result.InvalidArguments
  if pic.vector != nil: return Result.InsufficientCondition
  let l = acquireRaw(pixels, w, h, cs)
  if l != nil: pic.adopt(l) else: Result.NonSupport

proc unload*(pic: Picture) =
  ## Releases the loader use (the C++ destructor does this); empties the picture.
  if pic.loader != nil: discard retrieve(pic.loader)
  if pic.vector != nil: pic.vector.disposeRender()
  pic.loader = nil
  pic.vector = nil
  pic.bitmap = nil

proc resolver*(pic: Picture, resolver: AssetResolver, fallback = false): Result =
  ## Sets (or with nil removes) the external asset resolver; before loading only.
  if pic.loader != nil: return Result.InsufficientCondition
  pic.resolver = resolver
  pic.resolverFallback = resolver != nil and fallback
  Result.Success

# ---- properties ------------------------------------------------------------------

proc size*(pic: Picture, w, h: float32): Result =
  pic.w = w
  pic.h = h
  pic.resizing = true
  pic.mark RenderUpdateFlag.Transform
  Result.Success

proc size*(pic: Picture, w, h: var float32): Result =
  if pic.loader == nil: return Result.InsufficientCondition
  w = pic.w
  h = pic.h
  Result.Success

proc origin*(pic: Picture, x, y: float32): Result =
  pic.origin = pt(x, y)
  pic.mark RenderUpdateFlag.Transform
  Result.Success

proc origin*(pic: Picture, x, y: var float32): Result =
  x = pic.origin.x
  y = pic.origin.y
  Result.Success

proc filter*(pic: Picture, m: FilterMethod): Result =
  if m != pic.filter:
    pic.mark RenderUpdateFlag.Image
    pic.filter = m
  Result.Success

proc content*(pic: Picture): Paint = pic.vector
  ## The loaded vector paint tree (nil for bitmap or empty pictures).

proc isBitmap*(pic: Picture): bool = pic.bitmap != nil

proc loader*(pic: Picture): ImageLoader = pic.loader
  ## The loader that provides the content (nil before loading). Used by
  ## `Animation` and `Accessor`.

proc loadContent*(pic: Picture): Paint =
  ## Brings the loader's content in now (like the first update would) and returns
  ## the vector tree (nil for bitmaps). This is `PictureImpl::iterator`'s `load()`.
  pic.renderFlags = pic.renderFlags + pic.load()
  pic.vector

# ---- Paint behaviour -------------------------------------------------------------

method kind*(pic: Picture): PaintKind = PaintKind.Picture

method skipUpdate*(pic: Picture, flags: RenderUpdateFlags): bool =
  # The media have their own playback update
  pic.loader == nil or (flags == {} and pic.loader.kind != FileType.Media)

proc needComposition(pic: Picture, opacity: uint8) =
  pic.cmpFlags = {}  # must clear after the rendering
  # In this case, paint(scene) would try composition itself.
  if opacity < 255: return
  let target = pic.maskTarget
  if target == nil or target.opacity == 255 or target.opacity == 0: return
  pic.mark CompositionFlag.Opacity

method updateImpl*(pic: Picture, r: RenderMethod, tm: Matrix,
    clips: var seq[RenderData], opacity: uint8, flags: RenderUpdateFlags,
    clipper: bool): bool =
  let flag = flags + pic.load()
  if flag == {}: return true
  let pivot = pt(-pic.origin.x * pic.w, -pic.origin.y * pic.h)
  if pic.bitmap != nil:
    if pic.bitmap.cs == ColorSpace.Unknown: return false
    # Overriding transformation by the desired image size
    let sx = pic.w / pic.loader.w
    let sy = pic.h / pic.loader.h
    let scale = if sx < sy: sx else: sy
    let m = tm * Matrix(e11: scale, e12: 0, e13: pivot.x, e21: 0, e22: scale,
                        e23: pivot.y, e31: 0, e32: 0, e33: 1)
    pic.rd = r.prepareImage(pic.bitmap, pic.rd, m, clips, opacity, pic.filter, flag)
  elif pic.vector != nil:
    if pic.resizing:
      discard pic.loader.resize(pic.vector, pic.w, pic.h)
      pic.resizing = false
    pic.needComposition(opacity)
    discard pic.vector.blend(pic.blendMethod)  # propagate to the nested vector scene
    var m = tm
    translateR(m, pivot)
    discard pic.vector.update(r, m, clips, opacity, flag)
  true

method renderImpl*(pic: Picture, r: RenderMethod, flags: CompositionFlags): bool =
  if pic.bitmap != nil:
    discard r.blend(pic.blendMethod)
    return r.renderImage(pic.rd)
  result = true
  if pic.vector != nil:
    var cmp: RenderCompositor = nil
    if pic.cmpFlags != {}:
      cmp = r.target(pic.regionImpl(), r.colorSpace(), pic.cmpFlags)
      discard r.beginComposite(cmp, MaskMethod.None, 255)
    result = pic.vector.render(r)
    if cmp != nil: discard r.endComposite(cmp)

method regionImpl*(pic: Picture): Region =
  if pic.vector != nil: pic.vector.paintRegion()
  elif pic.renderer != nil: pic.renderer.region(pic.rd)
  else: Region()

method boundsImpl*(pic: Picture, pt4: var array[4, Point], m: Matrix,
    obb: bool): bool =
  let pivot = pt(-pic.origin.x * pic.w, -pic.origin.y * pic.h)
  pt4[0] = pivot * m
  pt4[1] = pt(pivot.x + pic.w, pivot.y) * m
  pt4[2] = pt(pivot.x + pic.w, pivot.y + pic.h) * m
  pt4[3] = pt(pivot.x, pivot.y + pic.h) * m
  true

method intersectsImpl*(pic: Picture, region: Region, visibleOnly: bool): bool =
  if pic.renderer == nil: return false
  pic.renderFlags = pic.renderFlags + pic.load()
  if pic.rd != nil: pic.renderer.intersectsImage(pic.rd, region)
  elif pic.vector != nil: pic.vector.intersects(region, visibleOnly)
  else: false

method duplicateImpl*(pic: Picture): Paint =
  pic.renderFlags = pic.renderFlags + pic.load()
  let dup = newPicture()
  if pic.vector != nil:
    dup.vector = pic.vector.duplicate()
    dup.vector.parent = dup
  if pic.loader != nil:
    dup.loader = pic.loader
    inc dup.loader.sharing
    dup.mark RenderUpdateFlag.Image
  dup.bitmap = pic.bitmap
  dup.resolver = pic.resolver
  dup.resolverFallback = pic.resolverFallback
  dup.origin = pic.origin
  dup.w = pic.w
  dup.h = pic.h
  dup.filter = pic.filter
  dup.resizing = pic.resizing
  dup

method releaseChildren*(pic: Picture) =
  if pic.vector != nil: pic.vector.disposeRender()
