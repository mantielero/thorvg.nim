import std/[unittest, os]
import thorvg/core/[types, geom, path]
import thorvg/renderer/[loader, paint, shape]
import thorvg/loaders/font/loader as fl

const
  Root = currentSourcePath().parentDir.parentDir
  PublicSans = Root / "upstream" / "thorvg" / "test" / "res" / "PublicSans-Regular.ttf"
  Arial = "C:\\Windows\\Fonts\\arial.ttf"

proc cell(l: SfntLoader, s: string): GlyphCell =
  var p = 0
  l.src.request(codepoint(s, p, s.len))

proc contours(c: GlyphCell): int =
  for cmd in c.path.cmds:
    if cmd == PathCommand.Close: inc result

proc load(file: string): SfntLoader =
  result = newSfntLoader()
  doAssert result.openFile(file, LoaderOps()) == Result.Success

proc checkFont(file: string, upm: int, advA, advSpace: float32) =
  let l = load(file)
  check l.name.len > 0
  check l.src.reader.sfnt.unitsPerEm == upm

  let a = l.cell("A")
  let g = l.cell("g")
  check a != nil and g != nil
  check a.glyph.idx != g.glyph.idx
  check a.glyph.idx > 0 and g.glyph.idx > 0
  check a.path.pts.len > 0 and a.path.cmds[0] == PathCommand.MoveTo
  check a.contours >= 2          # "A" has an outer contour and a counter
  check g.path.pts.len > a.path.pts.len div 2

  # metrics: bbox from the file is y-up, the path is y-down
  for c in [a, g]:
    check c.glyph.bbox.w > 0 and c.glyph.bbox.h > 0
    check c.glyph.bbox.max.x < float32(upm) * 2
    var box: BBox
    check c.path.bounds(box)
    check box.min.x >= c.glyph.bbox.min.x - 1.5'f32
    check box.max.x <= c.glyph.bbox.max.x + 1.5'f32
    check box.min.y >= -c.glyph.bbox.max.y - 1.5'f32
    check box.max.y <= -c.glyph.bbox.min.y + 1.5'f32
  check a.glyph.bbox.max.y > 0 and a.glyph.bbox.min.y >= 0   # cap height, on the baseline
  check g.glyph.bbox.min.y < 0                               # descender

  check a.glyph.advance == advA
  check l.cell(" ").glyph.advance == advSpace
  check l.cell(" ").path.pts.len == 0
  check a.glyph.advance > 0 and abs(a.glyph.lsb) < a.glyph.advance

  # the glyph cache returns the same object
  check l.cell("A") == a

  # composite glyph: e acute = e + accent, taller than "e" and with more contours
  let e = l.cell("e")
  let ea = l.cell("\xC3\xA9")
  check ea != nil
  check ea.path.pts.len > e.path.pts.len
  check ea.contours > e.contours or ea.path.pts.len > e.path.pts.len
  check ea.glyph.bbox.max.y > e.glyph.bbox.max.y
  check ea.glyph.advance == e.glyph.advance

  # missing glyph: the .notdef outline (index 0) and code 0 -> nil
  let emoji = l.cell("\xF0\x9F\x98\x80")
  check emoji != nil and emoji.glyph.idx == 0
  check l.src.request(0) == nil

proc hello(file: string) =
  let l = load(file)
  var fm = initFontMetrics()
  fm.fontSize = 24
  var outp: RenderPath
  check l.get(fm, "Hello World", 11, outp)
  check fm.length == 11 and fm.lines == 1
  check outp.pts.len > 100
  check abs(fm.scale - float32(l.src.reader.sfnt.unitsPerEm) / (24.0'f32 * FontDpi)) < 1e-4'f32
  var sum = 0.0'f32
  for ch in "Hello World": sum += l.cell($ch).glyph.advance
  check fm.size.x >= sum - 400 and fm.size.x <= sum + 100   # kerning only shrinks a bit
  var box: BBox
  check outp.bounds(box)
  check box.min.y >= -float32(l.src.reader.sfnt.unitsPerEm) * 2

  # two lines, text with a missing codepoint is still laid out
  check l.get(fm, "Hi\nHi", 5, outp)
  check fm.lines == 2 and fm.length == 4
  check fm.size.y == (l.src.reader.sfnt.hhea.advance * 2 - l.src.reader.sfnt.hhea.linegap)
  fm.fontSize = 0
  check not l.get(fm, "x", 1, outp)

  # metrics
  fm.fontSize = 30
  var tm: TextMetrics
  l.metrics(fm, tm)
  let k = (30.0'f32 * FontDpi) / float32(l.src.reader.sfnt.unitsPerEm)
  check tm.ascent == l.src.reader.sfnt.hhea.ascent * k
  check tm.descent < 0 and tm.advance > tm.ascent
  var gm: GlyphMetrics
  var nxt = 0
  check l.glyphMetrics(fm, "Ag", 0, gm, nxt)
  check nxt == 1
  check gm.advance == l.cell("A").glyph.advance * k
  check gm.max.x > gm.min.x and gm.max.y > gm.min.y
  check l.glyphMetrics(fm, "Ag", nxt, gm, nxt) and nxt == 2
  check not l.glyphMetrics(fm, "Ag", 2, gm, nxt)
  check l.glyphMetrics(fm, "\xC3\xA9x", 0, gm, nxt) and nxt == 2

  # italic transform
  let s = newShape()
  check l.get(fm, "Ag", 2, outp)
  l.transform(s, fm, 0.2'f32)
  let m = s.transform()
  check abs(m.e11 - 1.0'f32 / fm.scale) < 1e-6'f32
  check m.e12 < 0 and m.e13 > 0
  check m.e23 == l.src.reader.sfnt.hhea.ascent / fm.scale
  # copy/release of the engine metrics
  var other = initFontMetrics()
  l.copy(fm, other)
  check other.engine != nil and other.engine != fm.engine
  l.release(other)
  check other.engine == nil

suite "ttf PublicSans":
  test "glyphs":
    checkFont(PublicSans, 2000, 1420, 486)
  test "layout and metrics":
    hello(PublicSans)
  test "no kern table":
    let l = load(PublicSans)
    var kp = Point()
    check not l.src.reader.positioning(1, 2, kp)

suite "ttf Arial":
  test "glyphs":
    if fileExists(Arial): checkFont(Arial, 2048, 1366, 569)
  test "layout and metrics":
    if fileExists(Arial): hello(Arial)
  test "kerning":
    if fileExists(Arial):
      let l = load(Arial)
      let a = l.src.reader.sfnt.glyphIndex(uint32('A'))
      let v = l.src.reader.sfnt.glyphIndex(uint32('V'))
      var kp = Point()
      check l.src.reader.positioning(a, v, kp)
      check kp.x < 0 and kp.y == 0
      var none = Point()
      check l.src.reader.positioning(a, a, none)
      check none.x == 0
      # kerning narrows "AV"
      var fm = initFontMetrics()
      fm.fontSize = 10
      var outp: RenderPath
      check l.get(fm, "AV", 2, outp)
      check fm.size.x == l.cell("A").glyph.advance + kp.x + l.cell("V").glyph.advance

suite "font loader registration":
  test "file and data":
    var ret = Result.InvalidArguments
    let ld = acquireFile(PublicSans, LoaderOps(), ret)
    check ret == Result.Success and ld != nil and ld.kind == FileType.Sfnt
    check FontLoader(ld).name == "PublicSans-Regular"
    check font("PublicSans-Regular") == ld
    check retrieve(ld)
    let data = readFile(PublicSans)
    let byData = acquireFont("mem", data, LoaderOps())
    check byData != nil and font("mem") == byData
    termLoaders()
    check font("mem") == nil
    let sniffed = acquireData(data, "", LoaderOps(), ret)
    check sniffed != nil and ret == Result.Success
    let byMime = acquireData(data, "ttf", LoaderOps(), ret)
    check byMime != nil

  test "invalid data":
    var ret = Result.Success
    check acquireData("not a font at all", "ttf", LoaderOps(), ret) == nil
    check ret == Result.InvalidArguments
    let l = newSfntLoader()
    check l.openData("OTTO0000", LoaderOps()) == Result.NonSupport
    check l.openData("abc", LoaderOps()) == Result.InvalidArguments
    check l.openData("\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", LoaderOps()) ==
      Result.InvalidArguments
    check l.openFile("no-such-font.ttf", LoaderOps()) == Result.InvalidArguments
    # truncated files never crash
    let data = readFile(PublicSans)
    for n in [64, 300, 5000, 40000, data.len - 1]:
      let t = newSfntLoader()
      if t.openData(data[0 ..< n], LoaderOps()) == Result.Success:
        var fm = initFontMetrics()
        fm.fontSize = 12
        var outp: RenderPath
        discard t.get(fm, "Hello", 5, outp)

  test "utf8 decoding":
    var p = 0
    check codepoint("A", p, 1) == 65 and p == 1
    p = 0
    check codepoint("\xC3\xA9", p, 2) == 0xE9 and p == 2
    p = 0
    check codepoint("\xE2\x82\xAC", p, 3) == 0x20AC and p == 3
    p = 0
    check codepoint("\xF0\x9F\x98\x80", p, 4) == 0x1F600 and p == 4
    p = 0
    check codepoint("\xC3", p, 1) == 0 and p == 1   # truncated sequence
    p = 0
    check codepoint("\x80", p, 1) == 0 and p == 1   # stray continuation byte
