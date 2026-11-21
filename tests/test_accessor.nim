## Accessor tests (tvgAccessor.cpp): pre-order traversal, callback edits, stable ids.
import std/[unittest, strutils]
import thorvg/core/types
import thorvg/renderer/[paint, shape, scene, picture, loader, accessor]

type
  FakeVec = ref object of ImageLoader
    entities: seq[AccessorEntity]
    root: Scene

proc makeVec(): Loader = FakeVec(kind: FileType.Svg)

proc named(name: string): Shape =
  result = newShape()
  discard result.appendRect(0, 0, 4, 4)
  result.id = generateId(name)

method openData(l: FakeVec, data: string, ops: LoaderOps): Result =
  if not data.startsWith("<vec"): return Result.InvalidArguments
  l.w = 8.0'f32
  l.h = 8.0'f32
  l.root = newScene()
  l.root.id = generateId("vec-root")
  for n in ["vec-a", "vec-b"]:
    let sh = named(n)
    discard l.root.add(sh)
    # like Lottie: the id map is built while loading, only when requested
    if ops.accessible: l.entities.add AccessorEntity(id: sh.id, paint: sh, name: n)
  Result.Success

method paint(l: FakeVec): Paint = l.root

method access(l: FakeVec, id: uint32, entity: var AccessorEntity): bool =
  for e in l.entities:
    if e.id == id:
      entity = e
      return true
  false

method access(l: FakeVec, cb: AccessorFunc) =
  for e in l.entities:
    if not cb(e.paint): return

registerLoader(FileType.Svg, makeVec)

proc tree(): tuple[root, inner: Scene, a, b, c: Shape] =
  result.root = newScene()
  result.inner = newScene()
  result.a = named("a")
  result.b = named("b")
  result.c = named("c")
  result.root.id = generateId("root")
  result.inner.id = generateId("inner")
  discard result.root.add(result.a)
  discard result.root.add(result.inner)
  discard result.inner.add(result.b)
  discard result.root.add(result.c)

suite "ids":
  test "generateId is the djb2 hash and is stable":
    check generateId("a") == generateId("a")
    check generateId("a") != generateId("b")
    check generateId("") == 5381'u32
    check generateId("a") == 5381'u32 * 33'u32 + uint32('a')

suite "traversal":
  test "pre-order, root first, children in order":
    let t = tree()
    var seen: seq[uint32]
    let r = newAccessor().set(t.root, proc (p: Paint): bool =
      seen.add p.id
      true)
    check r == Result.Success
    check seen == @[t.root.id, t.a.id, t.inner.id, t.b.id, t.c.id]

  test "returning false stops the traversal":
    let t = tree()
    var count = 0
    discard newAccessor().set(t.root, proc (p: Paint): bool =
      inc count
      p.id != t.b.id)
    check count == 4

  test "a callback can change the colors of the shapes":
    let t = tree()
    discard newAccessor().set(t.root, proc (p: Paint): bool =
      if p of Shape: discard Shape(p).fill(10, 20, 30, 255)
      true)
    for s in [t.a, t.b, t.c]:
      check s.fillColor == RGBA(r: 10, g: 20, b: 30, a: 255)
    check t.root.id == generateId("root")   # ids are untouched
    check t.b.id == generateId("b")

  test "a single shape visits only itself":
    let s = named("solo")
    var count = 0
    check newAccessor().set(s, proc (p: Paint): bool =
      inc count
      true) == Result.Success
    check count == 1

  test "invalid arguments":
    check newAccessor().set(nil, proc (p: Paint): bool = true) ==
      Result.InvalidArguments
    check newAccessor().set(newScene(), nil) == Result.InvalidArguments

suite "pictures":
  test "the loaded vector tree is traversed":
    let pic = newPicture()
    check pic.load("<vec>", "svg") == Result.Success
    var ids: seq[uint32]
    check newAccessor().set(pic, proc (p: Paint): bool =
      ids.add p.id
      true) == Result.Success
    check ids == @[pic.id, generateId("vec-root"), generateId("vec-a"),
                   generateId("vec-b")]
    check pic.paintById(generateId("vec-b")) != nil
    check pic.paintById(generateId("vec-b")).id == generateId("vec-b")
    check pic.paintById(generateId("nothing")) == nil
    pic.unload()

  test "accessible pictures use the loader id map and know the names":
    let pic = newPicture()
    pic.accessible = true
    check pic.load("<vec>", "svg") == Result.Success
    let acc = newAccessor()
    var names: seq[string]
    check acc.set(pic, proc (p: Paint): bool =
      names.add acc.name(p.id)
      true) == Result.Success
    check names == @["vec-a", "vec-b"]
    check acc.name(generateId("vec-a")) == ""    # only valid inside callbacks
    check pic.paintById(generateId("vec-a")).id == generateId("vec-a")
    check pic.paintById(generateId("vec-root")) == nil
    pic.unload()

  test "a picture inside a scene is descended into":
    let pic = newPicture()
    check pic.load("<vec>", "svg") == Result.Success
    let root = newScene()
    check root.add(pic) == Result.Success
    var count = 0
    discard newAccessor().set(root, proc (p: Paint): bool =
      inc count
      true)
    check count == 5   # root, picture, vec-root, vec-a, vec-b
    pic.unload()

  test "an empty picture only reports itself":
    var count = 0
    discard newAccessor().set(newPicture(), proc (p: Paint): bool =
      inc count
      true)
    check count == 1
