## Recording fake renderer, fake loaders and helpers shared by test_scenegraph.
## (included, not imported, so it shares the test module's imports).

type
  FakeData = ref object of RenderData
    id: int
    tm: Matrix
    opacity: uint8
    flags: RenderUpdateFlags
    nclips: int
    vport: Region
    box: Region
    prepared: int

  FakeRenderer = ref object of RenderMethod
    log: seq[string]
    nextId: int
    disposed: seq[int]
    cmps: seq[tuple[cs: ColorSpace, flags: CompositionFlags]]
    surface: RenderSurface

proc fd(p: Paint): FakeData = FakeData(p.rd)

method preUpdate(r: FakeRenderer): bool = r.log.add "preUpdate"; true
method postUpdate(r: FakeRenderer): bool = r.log.add "postUpdate"; true
method preRender(r: FakeRenderer): bool = r.log.add "preRender"; true
method postRender(r: FakeRenderer): bool = r.log.add "postRender"; true
method clear(r: FakeRenderer): bool = r.log.add "clear"; true
method sync(r: FakeRenderer): bool = r.log.add "sync"; true
method colorSpace(r: FakeRenderer): ColorSpace = ColorSpace.ARGB8888
method mainSurface(r: FakeRenderer): RenderSurface = r.surface
method blend(r: FakeRenderer, m: BlendMethod): bool = true

proc touch(r: FakeRenderer, data: RenderData, tm: Matrix, clips: seq[RenderData],
    opacity: uint8, flags: RenderUpdateFlags): FakeData =
  result = if data == nil: FakeData() else: FakeData(data)
  if data == nil:
    inc r.nextId
    result.id = r.nextId
  result.tm = tm
  result.opacity = opacity
  result.flags = flags
  result.nclips = clips.len
  result.vport = r.vport
  inc result.prepared

method prepareShape(r: FakeRenderer, rshape: RenderShape, data: RenderData,
    transform: Matrix, clips: seq[RenderData], opacity: uint8,
    flags: RenderUpdateFlags, clipper: bool): RenderData =
  let d = r.touch(data, transform, clips, opacity, flags)
  var box: BBox
  if rshape.path.bounds(box, transform):
    d.box = Region(xMin: int32(floor(box.min.x)), yMin: int32(floor(box.min.y)),
                   xMax: int32(ceil(box.max.x)), yMax: int32(ceil(box.max.y)))
  r.log.add "prepareShape:" & $d.id
  d

method prepareImage(r: FakeRenderer, surface: RenderSurface, data: RenderData,
    transform: Matrix, clips: seq[RenderData], opacity: uint8,
    filter: FilterMethod, flags: RenderUpdateFlags): RenderData =
  let d = r.touch(data, transform, clips, opacity, flags)
  d.box = Region(xMin: 0, yMin: 0, xMax: int32(float32(surface.w) * transform.e11),
                 yMax: int32(float32(surface.h) * transform.e22))
  r.log.add "prepareImage:" & $d.id
  d

method renderShape(r: FakeRenderer, data: RenderData): bool =
  r.log.add "renderShape:" & $FakeData(data).id
  true

method renderImage(r: FakeRenderer, data: RenderData): bool =
  r.log.add "renderImage:" & $FakeData(data).id
  true

method dispose(r: FakeRenderer, data: RenderData) = r.disposed.add FakeData(data).id
method region(r: FakeRenderer, data: RenderData): Region = FakeData(data).box

method target(r: FakeRenderer, region: Region, cs: ColorSpace,
    flags: CompositionFlags): RenderCompositor =
  r.cmps.add (cs, flags)
  r.log.add "target"
  RenderCompositor()

method beginComposite(r: FakeRenderer, cmp: RenderCompositor, m: MaskMethod,
    opacity: uint8): bool =
  r.log.add "begin:" & $m & ":" & $opacity
  true

method endComposite(r: FakeRenderer, cmp: RenderCompositor): bool =
  r.log.add "end"
  true

# ---- fake loaders ------------------------------------------------------------------

type FakeVec = ref object of ImageLoader
  resized: int
  lastW: float32

method openData(l: FakeVec, data: string, ops: LoaderOps): Result =
  if not data.startsWith("<fake"): return Result.InvalidArguments
  l.w = 100.0'f32
  l.h = 50.0'f32
  Result.Success

method paint(l: FakeVec): Paint =
  let s = newScene()
  let sh = newShape()
  discard sh.appendRect(0, 0, l.w, l.h)
  discard sh.fill(1, 2, 3, 255)
  discard s.add(sh)
  s

method resize(l: FakeVec, p: Paint, w, h: float32): bool =
  inc l.resized
  l.lastW = w
  true

proc makeVec(): Loader = FakeVec(kind: FileType.Svg)
proc sniffVec(data: string): bool = data.startsWith("<fake")

proc newRenderer(): FakeRenderer = FakeRenderer()

proc newTestCanvas(r: FakeRenderer): Canvas =
  result = newCanvas(r)
  check result.retarget(100, 100, ColorSpace.ARGB8888) == Result.Success

proc rectShape(x, y, w, h: float32, color: uint8 = 255): Shape =
  result = newShape()
  discard result.appendRect(x, y, w, h)
  discard result.fill(10, 20, 30, color)

