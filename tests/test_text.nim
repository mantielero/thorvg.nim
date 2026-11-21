## Text paint tests (ported behaviour of tvgText.h/.cpp) with the recording fake
## renderer: font loading, layout bounds, alignment, wrapping, appearance, duplicate.
import std/[unittest, math, os, strutils, options, sequtils]
import thorvg/core/[types, path]
from thorvg/core/fill import linearGradient, Fill
import thorvg/renderer/[render, paint, shape, scene, canvas, loader, text]
import thorvg/loaders/font/loader as fontloader

include scenegraph_fakes

const
  Root = currentSourcePath().parentDir.parentDir
  PublicSans = Root / "upstream" / "thorvg" / "test" / "res" / "PublicSans-Regular.ttf"
  Arial = "C:\\Windows\\Fonts\\arial.ttf"

  Upm = 2000.0'f32                       # PublicSans units per em
  FontScale = Upm / (20.0'f32 * FontDpi)   # font units per pixel at 20 pt

type Box = tuple[x, y, w, h: float32]

proc box(p: Paint): Box =
  check p.bounds(result.x, result.y, result.w, result.h) == Result.Success

proc newSans(size: float32 = 20.0'f32, s: string = "Hello"): Text =
  result = newText()
  check result.font("PublicSans-Regular", size) == Result.Success
  check result.text(s) == Result.Success

suite "font loading errors":
  test "no font is loaded yet":
    let t = newText()
    check t.font("nope") == Result.InsufficientCondition
    check t.font() == Result.InsufficientCondition
    var tm: TextMetrics
    check t.metrics(tm) == Result.InsufficientCondition
    check t.length == 0 and t.lines == 0
    check t.text("abc") == Result.Success
    check t.text == "abc"
    var x, y, w, h: float32
    check t.bounds(x, y, w, h) == Result.Success    # nothing laid out: empty box
    check w == 0.0'f32 and h == 0.0'f32

  test "bad arguments and bad fonts":
    check loadFont("") == Result.InvalidArguments
    check loadFont("name", "") == Result.InvalidArguments
    check loadFont("", "data") == Result.InvalidArguments
    check loadFont("C:\\does\\not\\exist.ttf") != Result.Success
    check loadFont("garbage", "this is not a font") != Result.Success
    check loadFont("tiny", "abc") != Result.Success
    check unloadFont("") == Result.InvalidArguments
    check unloadFont("never-loaded") == Result.InsufficientCondition
    let t = newText()
    check t.size(0.0'f32) == Result.InvalidArguments
    check t.size(-3.0'f32) == Result.InvalidArguments
    check t.spacing(-1.0'f32, 1.0'f32) == Result.InvalidArguments
    check t.spacing(1.0'f32, -1.0'f32) == Result.InvalidArguments
    check t.spacing(1.5'f32, 2.0'f32) == Result.Success

  test "the sfnt loader registers itself on import":
    check newLoader(FileType.Sfnt) of fontloader.SfntLoader

  test "loading files and memory":
    check loadFont(PublicSans) == Result.Success
    let count = activeLoaderCount()
    check loadFont(PublicSans) == Result.Success   # already loaded
    check activeLoaderCount() == count
    check loadFont("mem-sans", readFile(PublicSans), "ttf") == Result.Success
    check loadFont("mem-sans", readFile(PublicSans)) == Result.Success
    check activeLoaderCount() == count + 1
    let t = newText()
    check t.font("mem-sans", 12.0'f32) == Result.Success
    check t.font("missing") == Result.InsufficientCondition
    t.unload()
    check unloadFont("mem-sans") == Result.Success
    check t.font("mem-sans") == Result.InsufficientCondition
    check activeLoaderCount() == count
    check t.font() == Result.Success     # any loaded font
    t.unload()

suite "layout":
  test "width grows with the text, height follows the font size":
    let t = newSans(20.0'f32, "H")
    let one = t.box
    check t.length == 1 and t.lines == 1
    discard t.text("HHHH")
    let four = t.box
    check four.w > 2.0'f32 * one.w
    check abs(four.h - one.h) < 0.01'f32
    check t.length == 4
    # cap height of PublicSans is ~0.7 em; 20 pt = 26.7 px
    check one.h > 0.5'f32 * 26.0'f32 and one.h < 26.7'f32

  test "size scales the box linearly":
    let t = newSans(10.0'f32, "Hello World")
    let small = t.box
    check t.size(20.0'f32) == Result.Success
    let big = t.box
    check abs(big.w - 2.0'f32 * small.w) < 0.05'f32
    check abs(big.h - 2.0'f32 * small.h) < 0.05'f32

  test "empty text has no geometry, then text again":
    let t = newSans(20.0'f32, "Hello")
    check t.length == 5
    discard t.text("")
    var x, y, w, h: float32
    check t.bounds(x, y, w, h) == Result.InsufficientCondition
    check t.length == 0
    discard t.text("Hi")
    check t.length == 2

  test "letter spacing widens, line count and metrics":
    let t = newSans(20.0'f32, "Hello")
    let a = t.box.w
    check t.spacing(2.0'f32, 1.0'f32) == Result.Success
    check t.box.w > a
    var tm: TextMetrics
    check t.metrics(tm) == Result.Success
    check tm.ascent > 0.0'f32 and tm.descent != 0.0'f32 and tm.advance > 0.0'f32

  test "italic shears and is clamped":
    let t = newSans(20.0'f32, "Hello")
    let plain = t.box
    check t.italic(0.3'f32) == Result.Success
    check t.box.w > plain.w
    let at3 = t.box.w
    check t.italic(5.0'f32) == Result.Success    # clamped to 0.5
    let clamped = t.box.w
    check clamped > at3
    check t.italic(0.5'f32) == Result.Success
    check abs(t.box.w - clamped) < 0.001'f32
    check t.italic(-1.0'f32) == Result.Success   # clamped to 0
    check abs(t.box.w - plain.w) < 0.001'f32

  test "alignment shifts inside the layout box":
    let t = newSans(20.0'f32, "Hello World")
    check t.layout(200.0'f32, 0.0'f32) == Result.Success
    check t.align(0.0'f32, 0.0'f32) == Result.Success
    let left = t.box
    check t.align(0.5'f32, 0.0'f32) == Result.Success
    let center = t.box
    check t.align(1.0'f32, 0.0'f32) == Result.Success
    let right = t.box
    check abs(left.w - right.w) < 0.01'f32
    check center.x > left.x and right.x > center.x
    check abs((center.x - left.x) * 2.0'f32 - (right.x - left.x)) < 0.1'f32
    check right.x + right.w < 200.0'f32 and right.x + right.w > 190.0'f32
    check left.x < 5.0'f32

  test "wrap modes break lines inside the box":
    let t = newSans(20.0'f32, "Hello World")
    check t.layout(60.0'f32, 0.0'f32) == Result.Success
    check t.wrap(TextWrap.None) == Result.Success
    check t.lines == 1 and t.length == 11
    let single = t.box
    check t.wrap(TextWrap.Character) == Result.Success
    check t.lines == 3 and t.length == 11
    check t.box.w < 60.0'f32 and t.box.h > 2.0'f32 * single.h
    check t.wrap(TextWrap.Word) == Result.Success
    check t.lines == 2
    check t.box.w < 80.0'f32
    check t.wrap(TextWrap.Smart) == Result.Success
    check t.lines >= 2
    check t.wrap(TextWrap.Ellipsis) == Result.Success
    check t.lines == 1 and t.length < 11
    check t.box.w < 60.0'f32
    check t.wrap(TextWrap.None) == Result.Success
    check t.lines == 1 and abs(t.box.w - single.w) < 0.001'f32

  test "metrics of single glyphs":
    let t = newSans(20.0'f32, "A")
    var gm: GlyphMetrics
    var next = 0
    check t.metrics("A\xC3\xA9", 0, gm, next) == Result.Success
    check next == 1 and gm.advance > 0.0'f32 and gm.max.x > gm.min.x
    check t.metrics("A\xC3\xA9", 1, gm, next) == Result.Success
    check next == 3
    check t.metrics("A", 1, gm, next) == Result.InvalidArguments
    let noFont = newText()
    check noFont.metrics("A", 0, gm, next) == Result.InsufficientCondition

suite "text as a paint":
  test "update prepares the glyph shape and draw renders it":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let t = newSans(20.0'f32, "Hello")
    check t.fill(10, 200, 30) == Result.Success
    check c.add(t) == Result.Success
    check c.update() == Result.Success
    check r.log.count("prepareShape:1") == 1
    let g = t.glyphShape
    check g.fillColor == RGBA(r: 10, g: 200, b: 30, a: 255)
    check g.fd.tm.e11 > 0.0'f32 and abs(g.fd.tm.e11 - g.transform().e11) < 1e-6'f32
    check abs(g.fd.tm.e11 - 20.0'f32 * FontDpi / Upm) < 1e-5'f32
    check g.fd.box.xMax > g.fd.box.xMin
    check c.draw() == Result.Success
    check r.log.count("renderShape:1") == 1
    check t.paintRegion() == g.fd.box

  test "transform and opacity reach the glyph shape":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let t = newSans(20.0'f32, "Hi")
    let before = t.box
    check t.translate(30.0'f32, 40.0'f32) == Result.Success
    check t.opacity(100) == Result.Success
    check c.add(t) == Result.Success
    check c.update() == Result.Success
    let moved = t.box
    check abs(moved.x - (before.x + 30.0'f32)) < 0.001'f32
    check abs(moved.y - (before.y + 40.0'f32)) < 0.001'f32
    check t.glyphShape.fd.opacity == 100
    check abs(t.glyphShape.fd.tm.e13 - (30.0'f32 + t.glyphShape.transform().e13)) < 0.001'f32

  test "no font, nothing is prepared or rendered":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let t = newText()
    discard t.text("x")
    check c.add(t) == Result.Success
    check c.update() == Result.Success
    check c.draw() == Result.Success
    check r.log.filterIt(it.startsWith("prepareShape")).len == 0 and
      r.log.filterIt(it.startsWith("renderShape")).len == 0

  test "changing the text after a draw lays it out again":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let t = newSans(20.0'f32, "Hi")
    check c.add(t) == Result.Success
    check c.update() == Result.Success
    let narrow = t.glyphShape.fd.box
    c.status = CanvasStatus.Synced
    check t.text("Hi there, wide") == Result.Success
    check c.update() == Result.Success
    check t.glyphShape.fd.prepared == 2
    check t.glyphShape.fd.box.xMax > narrow.xMax

  test "outline width follows the font scale":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let t = newSans(20.0'f32, "Hi")
    check t.outline(2.0'f32, 255, 0, 0) == Result.Success
    check c.add(t) == Result.Success
    check c.update() == Result.Success
    let g = t.glyphShape
    check abs(g.strokeWidth - 2.0'f32 * FontScale) < 0.01'f32
    check g.strokeJoin == StrokeJoin.Round
    var col: RGBA
    check g.strokeFillColor(col) == Result.Success
    check col == RGBA(r: 255, g: 0, b: 0, a: 255)

  test "gradient coordinates are scaled to font units":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let t = newSans(20.0'f32, "Hi")
    check t.fill(linearGradient(0.0'f32, 0.0'f32, 40.0'f32, 10.0'f32)) == Result.Success
    check c.add(t) == Result.Success
    check c.update() == Result.Success
    let f = t.glyphShape.fill.get
    check abs(f.p2.x - 40.0'f32 * FontScale) < 0.01'f32
    check abs(f.p2.y - 10.0'f32 * FontScale) < 0.01'f32

  test "removing the text releases the engine data":
    let r = newRenderer()
    let c = newTestCanvas(r)
    let t = newSans(20.0'f32, "Hi")
    check c.add(t) == Result.Success
    check c.update() == Result.Success
    let id = t.glyphShape.fd.id
    check c.remove(t) == Result.Success
    check id in r.disposed

  test "text is not a valid clipper":
    let t = newSans(20.0'f32, "Hi")
    check t.kind == PaintKind.Text
    let s = rectShape(0, 0, 10, 10)
    check s.clip(t) == Result.InsufficientCondition

  test "duplicate copies text, font, style and is independent":
    let t = newSans(20.0'f32, "Hello")
    check t.fill(1, 2, 3) == Result.Success
    check t.italic(0.2'f32) == Result.Success
    check t.outline(1.5'f32, 9, 8, 7) == Result.Success
    check t.translate(5.0'f32, 6.0'f32) == Result.Success
    let orig = t.box
    let d = Text(t.duplicate())
    check d.text == "Hello"
    check d.glyphShape != t.glyphShape
    check d.glyphShape.fillColor == RGBA(r: 1, g: 2, b: 3, a: 255)
    let copy = d.box
    check abs(copy.x - orig.x) < 0.001'f32 and abs(copy.w - orig.w) < 0.001'f32
    check abs(copy.h - orig.h) < 0.001'f32
    check d.length == 5
    check d.text("Hello World") == Result.Success
    check d.box.w > orig.w
    check abs(t.box.w - orig.w) < 0.001'f32
    check t.text == "Hello"
    t.unload()
    check d.length == 11                # the copy keeps its own use of the font
    d.unload()

  test "duplicate without a font keeps the text":
    let t = newText()
    discard t.text("abc")
    let d = Text(t.duplicate())
    check d.text == "abc"
    check d.length == 0

suite "other fonts":
  test "Arial layout":
    if fileExists(Arial):
      check loadFont(Arial) == Result.Success
      let t = newText()
      check t.font("arial", 24.0'f32) == Result.Success
      check t.text("The quick brown fox") == Result.Success
      let a = t.box
      check t.text("The quick brown fox jumps") == Result.Success
      check t.box.w > a.w
      check a.h > 10.0'f32 and a.h < 40.0'f32
      check t.length == 25
      t.unload()
      check unloadFont(Arial) == Result.Success
    else:
      skip()
