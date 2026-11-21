## Saver tests (tvgSaver.cpp) with a recording SaveModule, plus the PNG saver addition.
import std/[unittest, os]
import thorvg/core/types
import thorvg/renderer/[paint, shape, picture, loader, animation, saver]
from thorvg/savers/png import PngSaver

type
  FakeSaver = ref object of SaveModule
    paints, anims, closed: int
    fail: bool
    lastName: string
    lastBg: Paint
    lastQuality, lastFps: uint32

var last: FakeSaver

proc makeFake(): SaveModule =
  last = FakeSaver()
  last

proc makeBad(): SaveModule =
  last = FakeSaver(fail: true)
  last

method save(m: FakeSaver, p: Paint, bg: Paint, filename: string,
    quality: uint32): bool =
  inc m.paints
  m.lastName = filename
  m.lastBg = bg
  m.lastQuality = quality
  not m.fail

method save(m: FakeSaver, a: Animation, bg: Paint, filename: string,
    quality: uint32, fps: uint32): bool =
  inc m.anims
  m.lastName = filename
  m.lastQuality = quality
  m.lastFps = fps
  true

method close(m: FakeSaver): bool =
  inc m.closed
  true

type FakeAnim = ref object of AnimLoader

method openData(l: FakeAnim, data: string, ops: LoaderOps): Result =
  l.w = 4.0'f32
  l.h = 4.0'f32
  l.segmentEnd = 3.0'f32
  Result.Success

method paint(l: FakeAnim): Paint = nil

method frame(l: FakeAnim, no: float32): bool = true

proc makeAnim(): Loader =
  let l = FakeAnim()
  l.initAnimLoader(FileType.Lot)
  l

registerLoader(FileType.Lot, makeAnim)
registerSaver("fake", makeFake)

proc rect(): Shape =
  result = newShape()
  discard result.appendRect(0, 0, 8, 6)
  discard result.fill(0, 255, 0, 255)

suite "saver contract":
  test "invalid and unsupported requests":
    let s = newSaver()
    check s.save(Paint(nil), "x.fake") == Result.InvalidArguments
    check s.save(Animation(nil), "x.fake") == Result.InvalidArguments
    check s.background(nil) == Result.InvalidArguments
    check s.save(rect(), "x.unknown") == Result.NonSupport
    check s.save(rect(), "noextension") == Result.NonSupport
    check s.sync() == Result.InsufficientCondition

  test "save, busy, sync":
    let s = newSaver()
    let bg = rect()
    check s.background(bg) == Result.Success
    check s.save(rect(), "a.fake", 80) == Result.Success
    check last.paints == 1
    check last.lastName == "a.fake"
    check last.lastBg == Paint(bg)
    check last.lastQuality == 80
    check s.save(rect(), "b.fake") == Result.InsufficientCondition
    check last.paints == 1
    let job = last
    check s.sync() == Result.Success
    check job.closed == 1
    check s.sync() == Result.InsufficientCondition
    check s.save(rect(), "c.fake") == Result.Success   # free again
    check s.sync() == Result.Success

  test "a failing module gives Unknown and leaves the saver free":
    let s = newSaver()
    registerSaver("bad", makeBad)
    check s.save(rect(), "x.bad") == Result.Unknown
    check s.sync() == Result.InsufficientCondition
    check s.save(rect(), "x.fake") == Result.Success
    check s.sync() == Result.Success

  test "animations: needs frames, forwards quality and fps":
    let s = newSaver()
    let empty = newAnimation()
    check s.save(empty, "x.fake") == Result.InsufficientCondition
    let a = newAnimation()
    check a.picture.load("<a>", "lot") == Result.Success
    check s.save(a, "x.nothing") == Result.NonSupport
    check s.save(a, "x.fake", 50, 24) == Result.Success
    check last.anims == 1
    check last.lastQuality == 50
    check last.lastFps == 24
    check s.save(a, "y.fake") == Result.InsufficientCondition
    check s.sync() == Result.Success

suite "png saver (addition)":
  test "a paint is rendered and written":
    check PngSaver() of SaveModule   # the import registers the "png" extension
    let path = getTempDir() / "thorvg_saver_test.png"
    removeFile(path)
    let s = newSaver()
    check s.save(rect(), path) == Result.Success
    check s.sync() == Result.Success
    check fileExists(path)
    let data = readFile(path)
    check data.len > 8
    check data[1 .. 3] == "PNG"
    removeFile(path)

  test "an empty shape cannot be saved":
    let path = getTempDir() / "thorvg_saver_empty.png"
    let s = newSaver()
    check s.save(newShape(), path) == Result.Unknown
    check not fileExists(path)
