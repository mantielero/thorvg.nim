## Hand-built TrueType fonts: cmap formats 4/6/12, quadratic -> cubic conversion,
## composite offsets, kerning, wrap modes and alignment (exact expectations).
import std/[unittest, strutils]
import thorvg/core/[types, geom, path]
import thorvg/renderer/loader
import thorvg/loaders/font/loader as fl

proc be16(v: int): string = $char((v shr 8) and 0xff) & $char(v and 0xff)
proc be32(v: int): string = be16((v shr 16) and 0xffff) & be16(v and 0xffff)

proc pad4(s: string): string = s & repeat('\0', (4 - s.len mod 4) mod 4)

proc simple(pts: seq[(int, int, bool)]): string =
  ## One-contour simple glyph with 16-bit deltas.
  var flags, xs, ys: string
  var px, py = 0
  for (x, y, on) in pts:
    flags.add char(if on: 1 else: 0)
    xs.add be16((x - px) and 0xffff)
    ys.add be16((y - py) and 0xffff)
    px = x
    py = y
  pad4(be16(1) & be16(0) & be16(0) & be16(100) & be16(100) & be16(pts.len - 1) &
       be16(0) & flags & xs & ys)

proc composite(): string =
  # glyph 1 at (10, 20) with word args + more, glyph 2 at (5, -7) with byte args
  pad4(be16(0xffff) & be16(0) & be16(0) & be16(100) & be16(100) &
       be16(0x23) & be16(1) & be16(10) & be16(20) &
       be16(0x02) & be16(2) & "\x05\xF9")

proc kernTable(): string =
  let sub = be16(0) & be16(6 + 8 + 12) & be16(0x0001) & be16(2) & be16(0) & be16(0) &
            be16(0) & be16(1) & be16(2) & be16(-50 and 0xffff) &
            be16(2) & be16(1) & be16(30)
  pad4(be16(0) & be16(1) & sub)

proc buildFont(cmapSub: string, platEnc: int, withKern = true): string =
  let glyphs = @["", simple(@[(0, 0, true), (100, 0, true), (100, 100, true), (0, 100, true)]),
                 simple(@[(0, 0, true), (50, 100, false), (100, 0, true)]), composite()]
  var glyf, loca: string
  for g in glyphs:
    loca.add be32(glyf.len)
    glyf.add g
  loca.add be32(glyf.len)
  let head = be32(0x10000) & repeat('\0', 14) & be16(1000) & repeat('\0', 30) & be16(1) &
             be16(0)
  let hhea = be32(0x10000) & be16(800) & be16(-200 and 0xffff) & be16(100) &
             repeat('\0', 24) & be16(4)
  var hmtx: string
  for adv in [500, 600, 700, 800]: hmtx.add be16(adv) & be16(0)
  let maxp = be32(0x10000) & be16(4) & repeat('\0', 24) & be16(4)
  let cmap = be16(0) & be16(1) & be16(platEnc shr 8) & be16(platEnc and 0xff) & be32(12) &
             cmapSub
  var tables = @[("cmap", cmap), ("glyf", glyf), ("head", head), ("hhea", hhea),
                 ("hmtx", hmtx)]
  if withKern: tables.add ("kern", kernTable())
  tables.add [("loca", loca), ("maxp", maxp)]
  var dir = be32(0x10000) & be16(tables.len) & repeat('\0', 6)
  var body: string
  var off = 12 + 16 * tables.len
  for (tag, t) in tables:
    dir.add tag & be32(0) & be32(off + body.len) & be32(t.len)
    body.add pad4(t)
  dir & body

const
  Cmap12 = be16(12) & be16(0) & be32(16 + 12 * 3) & be32(0) & be32(3) &
    be32(46) & be32(46) & be32(1) & be32(65) & be32(67) & be32(1) & be32(32) & be32(32) &
    be32(0)
  Cmap6 = be16(6) & be16(0) & be16(0) & be16(65) & be16(4) & be16(1) & be16(2) & be16(3) &
    be16(0)
  Cmap4 = be16(4) & be16(0) & be16(0) & be16(4) & be16(0) & be16(0) & be16(0) &
    be16(67) & be16(0xffff) & be16(0) & be16(65) & be16(0xffff) & be16(-64 and 0xffff) &
    be16(1) & be16(0) & be16(0)

proc open(font: string): SfntLoader =
  result = newSfntLoader()
  doAssert result.openData(font, LoaderOps()) == Result.Success

proc layoutFont(): SfntLoader = open(buildFont(Cmap12, 0x0300 + 10))

proc metrics(size = 750.0'f32): FontMetrics =
  result = initFontMetrics()
  result.fontSize = size   # scale == 1 font unit per path unit (up to float error)

proc glyph(l: SfntLoader, c: char): GlyphCell = l.src.request(uint32(c))

suite "cmap":
  test "format 12":
    let l = layoutFont()
    check l.src.reader.sfnt.glyphIndex(65) == 1
    check l.src.reader.sfnt.glyphIndex(67) == 3
    check l.src.reader.sfnt.glyphIndex(46) == 1
    check l.src.reader.sfnt.glyphIndex(64) == 0
    check l.src.reader.sfnt.glyphIndex(0x1F600) == 0
  test "format 6":
    let l = open(buildFont(Cmap6, 0x0301))
    check l.src.reader.sfnt.glyphIndex(65) == 1
    check l.src.reader.sfnt.glyphIndex(66) == 2
    check l.src.reader.sfnt.glyphIndex(68) == 0
    check l.src.reader.sfnt.glyphIndex(64) == 0
    check l.src.reader.sfnt.glyphIndex(0x10000) == 0
  test "format 4":
    let l = open(buildFont(Cmap4, 0x0301))
    check l.src.reader.sfnt.glyphIndex(65) == 1
    check l.src.reader.sfnt.glyphIndex(67) == 3
    check l.src.reader.sfnt.glyphIndex(68) == 0
    check l.src.reader.sfnt.glyphIndex(0x10000) == 0
  test "unsupported subtable":
    let l = open(buildFont(be16(2) & be16(6) & be16(0), 0x0301))
    check l.src.reader.sfnt.glyphIndex(65) == InvalidGlyph
    check l.glyph('A') == nil

suite "outlines":
  test "square":
    let c = layoutFont().glyph('A')
    check c.path.cmds == @[PathCommand.MoveTo, PathCommand.LineTo, PathCommand.LineTo,
                           PathCommand.LineTo, PathCommand.Close]
    check c.path.pts == @[pt(0, 0), pt(100, 0), pt(100, -100), pt(0, -100)]
    check c.glyph.advance == 600 and c.glyph.bbox.max == pt(100, 100)
  test "quadratic becomes cubic":
    let c = layoutFont().glyph('B')
    check c.path.cmds == @[PathCommand.MoveTo, PathCommand.CubicTo, PathCommand.Close]
    check c.path.pts.len == 4
    check abs(c.path.pts[1].x - 100.0'f32 / 3.0'f32) < 1e-3'f32
    check abs(c.path.pts[1].y + 200.0'f32 / 3.0'f32) < 1e-3'f32
    check abs(c.path.pts[2].x - 200.0'f32 / 3.0'f32) < 1e-3'f32
    check abs(c.path.pts[2].y + 200.0'f32 / 3.0'f32) < 1e-3'f32
    check c.path.pts[3] == pt(100, 0)
  test "composite with offsets":
    let c = layoutFont().glyph('C')
    check c.path.pts.len == 8
    check c.path.pts[0] == pt(10, -20)
    check c.path.pts[2] == pt(110, -120)
    check c.path.pts[4] == pt(5, 7)
    check c.path.pts[7] == pt(105, 7)
    check c.path.cmds.len == 5 + 3
  test "notdef and failures":
    let l = layoutFont()
    let sp = l.glyph(' ')
    check sp != nil and sp.path.pts.len == 0 and sp.glyph.advance == 500
    check l.glyph('Z').glyph.idx == 0      # not in cmap -> .notdef
    check l.src.request(0) == nil

suite "layout":
  test "kerning and size":
    let l = layoutFont()
    var fm = metrics()
    var o: RenderPath
    check l.get(fm, "AB", 2, o)
    check abs(fm.scale - 1.0'f32) < 1e-6'f32
    check abs(fm.size.x - 1250.0'f32) < 0.01'f32      # 600 + (700 - 50)
    check abs(fm.size.y - 1000.0'f32) < 0.01'f32      # (1100 - 100)
    check fm.length == 2 and fm.lines == 1
    check o.pts[4] == pt(550, 0)                      # B is shifted by the kern value
    var kp = Point()
    check l.src.reader.positioning(2, 1, kp) and kp.x == 30
  test "line feed and length limit":
    let l = layoutFont()
    var fm = metrics()
    var o: RenderPath
    check l.get(fm, "A\nB", 3, o)
    check fm.lines == 2 and fm.length == 2
    check abs(fm.size.y - 2100.0'f32) < 0.01'f32
    check abs(o.pts[4].y - 1100.0'f32) < 0.01'f32
    check l.get(fm, "AB", 1, o)
    check fm.length == 1
    check l.get(fm, "", 0, o) and o.pts.len == 0
  test "wrap character":
    let l = layoutFont()
    var fm = metrics()
    fm.box = pt(1300, 0)
    fm.wrap = TextWrap.Character
    var o: RenderPath
    check l.get(fm, "ABAB", 4, o)
    check fm.lines == 2 and fm.length == 4
    check abs(fm.size.x - 1280.0'f32) < 0.01'f32
  test "wrap word":
    let l = layoutFont()
    var fm = metrics()
    fm.box = pt(1700, 0)
    fm.wrap = TextWrap.Word
    var o: RenderPath
    check l.get(fm, "AB AB", 5, o)
    check fm.lines == 2 and fm.length == 5
    check abs(o.pts[^1].y - 1100.0'f32) < 0.01'f32 or abs(o.pts[^1].y - 1000.0'f32) < 0.01'f32
    fm.wrap = TextWrap.Smart
    check l.get(fm, "AB AB", 5, o)
    check fm.lines >= 2
  test "ellipsis":
    let l = layoutFont()
    var fm = metrics()
    fm.box = pt(2000, 0)
    fm.wrap = TextWrap.Ellipsis
    var o: RenderPath
    check l.get(fm, "ABABAB", 6, o)
    check fm.length == 5                  # A B + "..."
    check o.pts.len == 4 + 4 + 3 * 4
    check abs(fm.size.x - 3050.0'f32) < 0.01'f32
  test "alignment":
    let l = layoutFont()
    var fm = metrics()
    fm.box = pt(2000, 0)
    fm.align = pt(1, 0)
    var o: RenderPath
    check l.get(fm, "A", 1, o)
    check abs(o.pts[0].x - 1400.0'f32) < 0.01'f32
    fm.align = pt(0.5'f32, 0)
    check l.get(fm, "A", 1, o)
    check abs(o.pts[0].x - 700.0'f32) < 0.01'f32

suite "robustness":
  test "corrupted fonts never crash":
    let good = buildFont(Cmap12, 0x0300 + 10)
    var seed = 12345'u32
    for round in 0 ..< 400:
      var font = good
      for k in 0 ..< 3:
        seed = seed * 1664525'u32 + 1013904223'u32
        font[int(seed shr 8) mod font.len] = char(seed and 0xff)
      let l = newSfntLoader()
      if l.openData(font, LoaderOps()) == Result.Success:
        var fm = metrics()
        var o: RenderPath
        discard l.get(fm, "AB ZC.", 6, o)
        var gm: GlyphMetrics
        var nxt = 0
        discard l.glyphMetrics(fm, "ABC", 0, gm, nxt)
  test "header validation":
    let good = buildFont(Cmap12, 0x0300 + 10)
    check newSfntLoader().openData(good[0 ..< 40], LoaderOps()) == Result.InvalidArguments
    check newSfntLoader().openData(good, LoaderOps()) == Result.Success
    var kp = Point()
    check not open(buildFont(Cmap12, 0x0300 + 10, false)).src.reader.positioning(1, 2, kp)
