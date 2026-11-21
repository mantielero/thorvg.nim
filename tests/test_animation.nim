## Animation API tests (tvgAnimation.cpp) with a fake AnimLoader defined here.
import std/unittest
import thorvg/core/types
import thorvg/renderer/[render, paint, shape, scene, picture, canvas, loader, animation]
import thorvg/engine/cpu/renderer

type FakeAnim = ref object of AnimLoader
  cur: float32
  total: float32
  dirty: bool
  syncs: int
  root: Scene
  box: Shape

proc makeAnim(): Loader =
  let l = FakeAnim(total: 10.0'f32)
  l.initAnimLoader(FileType.Lot)
  l

method openData(l: FakeAnim, data: string, ops: LoaderOps): Result =
  if data != "<anim>": return Result.InvalidArguments
  l.w = 20.0'f32
  l.h = 10.0'f32
  l.segmentBegin = 0.0'f32
  l.segmentEnd = l.total
  Result.Success

proc recolor(l: FakeAnim) =
  if l.box != nil:
    if l.cur < 5.0'f32: discard l.box.fill(255, 0, 0, 255)
    else: discard l.box.fill(0, 0, 255, 255)

method paint(l: FakeAnim): Paint =
  l.root = newScene()
  l.box = newShape()
  discard l.box.appendRect(0, 0, 20, 10)
  l.recolor()
  discard l.root.add(l.box)
  l.root

method frame(l: FakeAnim, no: float32): bool =
  if no < l.segmentBegin or no >= l.segmentEnd: return false
  if no == l.cur: return false
  l.cur = no
  l.dirty = true
  true

method sync(l: FakeAnim): bool =
  inc l.syncs
  result = l.dirty
  if l.dirty:
    l.recolor()
    l.dirty = false

method curFrame(l: FakeAnim): float32 = l.cur
method duration(l: FakeAnim): float32 = 2.0'f32

method segment(l: FakeAnim, b, e: float32): Result =
  if b < 0.0'f32 or e > l.total or b >= e: return Result.InvalidArguments
  l.segmentBegin = b
  l.segmentEnd = e
  if l.cur < b or l.cur >= e: l.cur = b
  Result.Success

registerLoader(FileType.Lot, makeAnim)

proc px(c: Canvas, x, y: int): uint32 =
  let s = swSurface(c)
  s.data[y * int(s.stride) + x]

proc loaded(): Animation =
  result = newAnimation()
  check result.picture.load("<anim>", "lot") == Result.Success

suite "animation without a loader":
  test "everything reports the missing loader":
    let a = newAnimation()
    check a.picture != nil
    check a.frame(1.0'f32) == Result.InsufficientCondition
    check a.totalFrame() == 0.0'f32
    check a.curFrame() == 0.0'f32
    check a.duration() == 0.0'f32
    check a.segment(0.0'f32, 1.0'f32) == Result.InsufficientCondition
    var b, e = 0.0'f32
    check a.segment(b, e) == Result.InsufficientCondition

suite "animation with a playable loader":
  test "queries are forwarded":
    let a = loaded()
    check a.totalFrame() == 10.0'f32
    check a.duration() == 2.0'f32
    check a.curFrame() == 0.0'f32
    var w, h = 0.0'f32
    check a.picture.size(w, h) == Result.Success
    check (w, h) == (20.0'f32, 10.0'f32)

  test "frame succeeds, marks the picture, and fails out of range":
    let a = loaded()
    check a.frame(3.0'f32) == Result.Success
    check a.curFrame() == 3.0'f32
    check a.picture.marked(RenderUpdateFlag.Children)
    check a.frame(3.0'f32) == Result.InsufficientCondition   # unchanged
    check a.frame(10.0'f32) == Result.InsufficientCondition  # beyond the end
    check a.curFrame() == 3.0'f32

  test "segment get / set":
    let a = loaded()
    check a.segment(2.0'f32, 6.0'f32) == Result.Success
    check a.totalFrame() == 4.0'f32
    var b, e = 0.0'f32
    check a.segment(b, e) == Result.Success
    check (b, e) == (2.0'f32, 6.0'f32)
    check a.curFrame() == 2.0'f32
    check a.frame(6.0'f32) == Result.InsufficientCondition
    check a.frame(5.0'f32) == Result.Success
    check a.segment(7.0'f32, 7.0'f32) == Result.InvalidArguments

  test "the picture draws the frame content through the canvas":
    let a = loaded()
    let c = newSwCanvas(20, 10)
    check c.add(a.picture) == Result.Success
    check c.update() == Result.Success
    check c.draw(true) == Result.Success
    check c.sync() == Result.Success
    check c.px(5, 5) == 0xFFFF0000'u32
    check a.frame(7.0'f32) == Result.Success
    check c.update() == Result.Success
    check c.draw(true) == Result.Success
    check c.sync() == Result.Success
    check c.px(5, 5) == 0xFF0000FF'u32
    check FakeAnim(a.picture.loader).syncs >= 1
    a.unload()

suite "animation with a non playable loader":
  test "a bitmap picture is NonSupport":
    let a = newAnimation()
    check a.picture.loadRaw(@[0xFFFFFFFF'u32, 0xFFFFFFFF'u32], 2, 1,
      ColorSpace.ARGB8888) == Result.Success
    check a.frame(1.0'f32) == Result.NonSupport
    check a.segment(0.0'f32, 1.0'f32) == Result.NonSupport
    var b, e = 0.0'f32
    check a.segment(b, e) == Result.NonSupport
    check a.totalFrame() == 0.0'f32
    check a.curFrame() == 0.0'f32
    check a.duration() == 0.0'f32
