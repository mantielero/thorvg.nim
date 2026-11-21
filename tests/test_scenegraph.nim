## Scene graph tests (ported behaviour of tvgPaint/Scene/Shape/Picture/Canvas/LoaderMgr)
## using a recording fake renderer.
import std/[unittest, math, os, strutils]
import thorvg/core/[types, geom, path]
import thorvg/renderer/[render, paint, shape, scene, picture, canvas, loader]

include scenegraph_fakes

suite "update flag propagation":
  test "first update prepares, a clean second update skips":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let s = rectShape(10, 10, 20, 20)
    check c.add(s) == Result.Success
    check c.update() == Result.Success
    check s.fd.prepared == 1
    check RenderUpdateFlag.Path in s.fd.flags
    check RenderUpdateFlag.Transform in s.fd.flags
    check s.renderFlags == {}
    c.status = CanvasStatus.Synced
    check c.update() == Result.Success
    check s.fd.prepared == 1
    c.status = CanvasStatus.Synced
    check s.opacity(100) == Result.Success
    check c.update() == Result.Success
    check s.fd.prepared == 2
    check s.fd.flags == {RenderUpdateFlag.Color}

  test "a scene transform reaches the children as a Transform flag":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let sc = newScene()
    let s = rectShape(0, 0, 5, 5)
    check sc.add(s) == Result.Success
    check c.add(sc) == Result.Success
    check c.update() == Result.Success
    c.status = CanvasStatus.Synced
    check sc.translate(5, 5) == Result.Success
    check c.update() == Result.Success
    check s.fd.prepared == 2
    check RenderUpdateFlag.Transform in s.fd.flags

  test "a damaged canvas updates everything again":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let s = rectShape(0, 0, 5, 5)
    check c.add(s) == Result.Success
    check c.update() == Result.Success
    check c.sync() == Result.Success
    check c.viewport(0, 0, 50, 50) == Result.Success
    check c.status == CanvasStatus.Damaged
    check c.update() == Result.Success
    check s.fd.prepared == 2
    check s.fd.flags == AllUpdateFlags

suite "transform and opacity composition":
  test "matrices and opacities multiply down the tree":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let sc = newScene()
    let s = rectShape(0, 0, 10, 10)
    check sc.add(s) == Result.Success
    check c.add(sc) == Result.Success
    check sc.translate(10, 20) == Result.Success
    check sc.scale(2.0'f32) == Result.Success
    check sc.opacity(128) == Result.Success
    check s.translate(1, 1) == Result.Success
    check s.opacity(128) == Result.Success
    check c.update() == Result.Success
    let tm = s.fd.tm
    check (tm.e11, tm.e22, tm.e13, tm.e23) == (2.0'f32, 2.0'f32, 12.0'f32, 22.0'f32)
    check s.fd.opacity == multiply(multiply(255, 128), 128)
    check s.fd.opacity == 64

  test "explicit transform blocks rotate/scale/translate":
    let s = newShape()
    var m = identity()
    m.e13 = 3.0'f32
    check s.transform(m) == Result.Success
    check s.rotate(10) == Result.InsufficientCondition
    check s.scale(2) == Result.InsufficientCondition
    check s.translate(1, 1) == Result.InsufficientCondition
    check s.transform().e13 == 3.0'f32

  test "a translucent multi-child scene composites with its opacity":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let sc = newScene()
    let a = rectShape(0, 0, 10, 10)
    let b = rectShape(5, 5, 10, 10)
    check sc.add(a) == Result.Success
    check sc.add(b) == Result.Success
    check sc.opacity(128) == Result.Success
    check c.add(sc) == Result.Success
    check c.draw() == Result.Success
    check a.fd.opacity == 255
    check r.cmps.len == 1
    check r.cmps[0].flags == {CompositionFlag.Opacity}
    check "begin:None:128" in r.log

suite "bounds":
  test "shape bounds follow the parent transform":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let sc = newScene()
    let s = rectShape(10, 10, 20, 20)
    check sc.add(s) == Result.Success
    check c.add(sc) == Result.Success
    check sc.translate(5, 5) == Result.Success
    var x, y, w, h: float32
    check s.bounds(x, y, w, h) == Result.Success
    check (x, y, w, h) == (15.0'f32, 15.0'f32, 20.0'f32, 20.0'f32)

  test "scene bounds are the union, empty scene fails":
    let sc = newScene()
    var x, y, w, h: float32
    check sc.bounds(x, y, w, h) == Result.InsufficientCondition
    check sc.add(rectShape(0, 0, 10, 10)) == Result.Success
    check sc.add(rectShape(20, 30, 10, 10)) == Result.Success
    check sc.bounds(x, y, w, h) == Result.Success
    check (x, y, w, h) == (0.0'f32, 0.0'f32, 30.0'f32, 40.0'f32)

  test "oriented bounds of a rotated shape":
    let s = rectShape(0, 0, 10, 20)
    check s.rotate(90) == Result.Success
    var pts: array[4, Point]
    check s.bounds(pts) == Result.Success
    check abs(pts[1].x - 0.0'f32) < 0.01'f32
    check abs(pts[1].y - 10.0'f32) < 0.01'f32
    var x, y, w, h: float32
    check s.bounds(x, y, w, h) == Result.Success
    check abs(w - 20.0'f32) < 0.01'f32
    check abs(h - 10.0'f32) < 0.01'f32

  test "intersects uses the engine region":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let s = rectShape(10, 10, 20, 20)
    check not s.intersects(0, 0, 100, 100)  # no renderer yet
    check c.add(s) == Result.Success
    check c.update() == Result.Success
    check s.paintRegion() == Region(xMin: 10, yMin: 10, xMax: 30, yMax: 30)

suite "add insert remove":
  test "order, insertion and errors":
    let sc = newScene()
    let a = newShape()
    let b = newShape()
    let d = newShape()
    check sc.add(a) == Result.Success
    check sc.add(d) == Result.Success
    check sc.add(b, d) == Result.Success
    check sc.paints == @[Paint(a), Paint(b), Paint(d)]
    check sc.add(a) == Result.InsufficientCondition  # already has a parent
    check sc.add(nil) == Result.InvalidArguments
    check sc.add(newShape(), newShape()) == Result.InvalidArguments
    check sc.remove(newShape()) == Result.InsufficientCondition
    check sc.remove(b) == Result.Success
    check b.parent == nil
    check sc.paints.len == 2
    check sc.clear() == Result.Success
    check sc.paints.len == 0

  test "removal releases engine data and the paint can be re-added":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let s = rectShape(0, 0, 5, 5)
    check c.add(s) == Result.Success
    check c.update() == Result.Success
    let id = s.fd.id
    check c.remove(s) == Result.Success
    check id in r.disposed
    check s.rd == nil
    check c.add(s) == Result.Success
    check c.update() == Result.Success
    check s.fd.prepared == 1  # fresh engine data
    check c.remove(nil) == Result.Success
    check c.paints.len == 0

  test "canvas guards":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let s = rectShape(0, 0, 5, 5)
    check c.add(nil) == Result.InvalidArguments
    check c.add(s) == Result.Success
    check c.draw() == Result.Success
    check c.draw() == Result.InsufficientCondition
    check c.add(newShape()) == Result.InsufficientCondition
    check c.remove(s) == Result.InsufficientCondition
    check c.retarget(10, 10, ColorSpace.ARGB8888) == Result.InsufficientCondition
    check c.viewport(0, 0, 10, 10) == Result.InsufficientCondition
    check c.sync() == Result.Success
    check c.status == CanvasStatus.Synced
    let other = newTestCanvas(newRenderer())
    check other.add(s) == Result.InsufficientCondition  # owned by another renderer

  test "draw updates first and renders in order":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let a = rectShape(0, 0, 5, 5)
    let b = rectShape(0, 0, 5, 5)
    let hidden = rectShape(0, 0, 5, 5)
    check hidden.visible(false) == Result.Success
    check c.add(a) == Result.Success
    check c.add(hidden) == Result.Success
    check c.add(b) == Result.Success
    check c.draw() == Result.Success
    check r.log == @["preUpdate", "prepareShape:1", "prepareShape:2", "prepareShape:3",
      "postUpdate", "clear", "preRender", "renderShape:1", "renderShape:3", "postRender"]

suite "clipper and mask decisions":
  test "an axis-aligned rectangle clipper becomes a viewport restriction":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let s = rectShape(0, 0, 80, 80)
    let clp = rectShape(0, 0, 50, 50)
    check c.add(s) == Result.Success
    check s.clip(clp) == Result.Success
    check c.update() == Result.Success
    check clp.fastTrack
    check clp.rd == nil
    check s.fd.nclips == 0
    check s.fd.vport == Region(xMin: 0, yMin: 0, xMax: 50, yMax: 50)
    check r.vport == Region(xMin: 0, yMin: 0, xMax: 100, yMax: 100)

  test "a rotated or round clipper is rendered as a clip":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let s = rectShape(0, 0, 80, 80)
    let clp = rectShape(10, 10, 20, 20)
    check clp.rotate(45) == Result.Success
    check c.add(s) == Result.Success
    check s.clip(clp) == Result.Success
    check c.update() == Result.Success
    check not clp.fastTrack
    check clp.rd != nil
    check s.fd.nclips == 1
    check RenderUpdateFlag.Clip in s.fd.flags

    let round = newShape()
    discard round.appendCircle(20, 20, 10, 10)
    let s2 = rectShape(0, 0, 80, 80)
    check c.add(s2) == Result.Success
    check s2.clip(round) == Result.Success
    check c.update() == Result.Success
    check s2.fd.nclips == 1

  test "clip rejects non shapes and attached paints":
    let s = newShape()
    check s.clip(newScene()) == Result.InsufficientCondition
    let owner = newScene()
    let attached = newShape()
    check owner.add(attached) == Result.Success
    check s.clip(attached) == Result.InsufficientCondition
    check s.clip(nil) == Result.Success

  test "an opaque rectangle alpha mask is a fast track":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let s = rectShape(0, 0, 80, 80)
    let m = rectShape(0, 0, 40, 40)
    check c.add(s) == Result.Success
    check s.mask(m, MaskMethod.Alpha) == Result.Success
    check c.draw() == Result.Success
    check m.fastTrack
    check m.rd == nil
    check s.fd.vport == Region(xMin: 0, yMin: 0, xMax: 40, yMax: 40)
    check r.cmps.len == 0

  test "a round mask composites through a grayscale target":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let s = rectShape(0, 0, 80, 80)
    let m = newShape()
    discard m.appendCircle(20, 20, 10, 10)
    discard m.fill(0, 0, 0, 255)
    check c.add(s) == Result.Success
    check s.mask(m, MaskMethod.Alpha) == Result.Success
    check c.draw() == Result.Success
    check not m.fastTrack
    check m.rd != nil
    check r.cmps.len == 1
    check r.cmps[0].cs == ColorSpace.Grayscale8
    check r.cmps[0].flags == {CompositionFlag.Masking}
    check "begin:None:255" in r.log
    check "begin:Alpha:255" in r.log
    var target: Paint
    check s.mask(target) == MaskMethod.Alpha
    check target == Paint(m)

  test "mask argument validation":
    let s = newShape()
    check s.mask(newShape(), MaskMethod.None) == Result.InvalidArguments
    check s.mask(nil, MaskMethod.Alpha) == Result.InvalidArguments
    check s.mask(nil, MaskMethod.None) == Result.Success

suite "duplicate":
  test "shape copy is independent":
    let s = rectShape(0, 0, 10, 10)
    check s.opacity(100) == Result.Success
    check s.translate(4, 5) == Result.Success
    check s.clip(rectShape(0, 0, 3, 3)) == Result.Success
    let d = Shape(s.duplicate())
    check d.opacity == 100
    check d.clipper != nil and d.clipper != s.clipper
    check d.transform().e13 == 4.0'f32
    check d.parent == nil
    check d.fillColor() == s.fillColor()
    check d.strokeWidth(3) == Result.Success
    check s.strokeWidth() == 0.0'f32
    check d.renderFlags == AllUpdateFlags

  test "scene copy is deep":
    let sc = newScene()
    check sc.add(rectShape(0, 0, 10, 10)) == Result.Success
    check sc.add(rectShape(1, 1, 2, 2)) == Result.Success
    let d = Scene(sc.duplicate())
    check d.paints.len == 2
    check d.paints[0] != sc.paints[0]
    check d.paints[0].parent == Paint(d)
    check sc.remove(sc.paints[0]) == Result.Success
    check d.paints.len == 2

suite "loaders and pictures":
  setup:
    registerLoader(FileType.Svg, makeVec, sniffVec)

  test "extension and mime mapping":
    check fileTypeOfExt(fileExt("a/b/c.PNG".toLowerAscii)) == FileType.Png
    check fileTypeOfExt("json") == FileType.Lot
    check fileTypeOfExt("xyz") == FileType.Unknown
    check fileTypeOfMime("svg+xml") == FileType.Svg
    check fileTypeOfMime("jpeg") == FileType.Jpg
    check fileTypeOfMime("") == FileType.Unknown

  test "vector picture loaded from data":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let pic = newPicture()
    check pic.load("", "svg") == Result.InvalidArguments
    check pic.load("<fake/>", "png") == Result.NonSupport
    check pic.load("<fake/>", "") == Result.Success  # probed by sniffing
    var w, h: float32
    check pic.size(w, h) == Result.Success
    check (w, h) == (100.0'f32, 50.0'f32)
    check c.add(pic) == Result.Success
    check c.update() == Result.Success
    check pic.content() != nil
    check pic.load("<fake/>", "svg") == Result.InsufficientCondition
    check pic.content().parent == Paint(pic)
    check pic.paintRegion() == Region(xMin: 0, yMin: 0, xMax: 100, yMax: 50)
    check c.draw() == Result.Success
    check r.log[^2] == "renderShape:1"
    pic.unload()

  test "picture size, origin and bounds":
    let pic = newPicture()
    check pic.load("<fake/>", "svg") == Result.Success
    check pic.size(200, 100) == Result.Success
    check pic.origin(0.5'f32, 0.5'f32) == Result.Success
    var x, y, w, h: float32
    check pic.bounds(x, y, w, h) == Result.Success
    check (x, y, w, h) == (-100.0'f32, -50.0'f32, 200.0'f32, 100.0'f32)
    let r = newRenderer()
    let c = newTestCanvas(r)
    check c.add(pic) == Result.Success
    check c.update() == Result.Success
    check Scene(pic.content()).paints[0].fd.tm.e13 == -100.0'f32
    pic.unload()

  test "raw bitmap picture scales to the requested size":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let pic = newPicture()
    check pic.loadRaw(@[], 4, 2, ColorSpace.ARGB8888) == Result.InvalidArguments
    check pic.loadRaw(newSeq[uint32](8), 4, 2, ColorSpace.Unknown) == Result.InvalidArguments
    check pic.loadRaw(newSeq[uint32](8), 4, 2, ColorSpace.ARGB8888) == Result.Success
    check pic.isBitmap == false  # content is fetched on the first update
    check pic.size(8, 2) == Result.Success
    check c.add(pic) == Result.Success
    check c.update() == Result.Success
    check pic.isBitmap
    check pic.fd.tm.e11 == 1.0'f32  # min(8/4, 2/2)
    check RenderUpdateFlag.Image in pic.fd.flags
    check c.draw() == Result.Success
    check "renderImage:1" in r.log
    let dup = Picture(pic.duplicate())
    var w, h: float32
    check dup.size(w, h) == Result.Success
    check (w, h) == (8.0'f32, 2.0'f32)
    check dup.isBitmap

  test "file loaders are cached and released":
    let path = getTempDir() / "tvg_scenegraph_fake.svg"
    writeFile(path, "<fake/>")
    let before = activeLoaderCount()
    let a = newPicture()
    let b = newPicture()
    check a.load(path) == Result.Success
    check b.load(path) == Result.Success
    check activeLoaderCount() == before + 1
    a.unload()
    check activeLoaderCount() == before + 1
    b.unload()
    check activeLoaderCount() == before
    check newPicture().load(path & ".missing.svg") == Result.InvalidArguments
    removeFile(path)

  test "a filter change marks the image":
    let pic = newPicture()
    check pic.filter(FilterMethod.Nearest) == Result.Success
    check RenderUpdateFlag.Image in pic.renderFlags
