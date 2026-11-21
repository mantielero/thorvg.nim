## Glyph cache and text layout (wrap modes) of the sfnt font loader.
##
## Ported from the layout half of `src/modules/sfnt/tvgSfntLoader.cpp`
## (`request`, `_codepoints`, `wrapNone/Char/Word/Ellipsis`). Text is a UTF-8
## byte string; the output is a `RenderPath` whose points are already
## scaled in font units (the loader's `transform` applies the final scale).

import std/tables
import ../../core/[types, geom, path]
from ../../renderer/loader import FontMetrics
import ./ttf

const
  LineFeedCode = 10'u32
  SpaceCode = 32'u32
  DotCode = 46'u32

type
  GlyphCell* = ref object
    code*: uint32
    glyph*: SfntGlyph
    path*: RenderPath

  SfntMetrics* = ref object of RootObj
    ## Engine extension of `FontMetrics` (`SfntMetrics` in C++).
    baseCode*: uint32       ## first glyph of the text (reference for italic), 0 = none

  GlyphSource* = object
    reader*: TtfReader
    glyphs*: Table[uint32, GlyphCell]   ## glyph cache, key: codepoint

func cont(s: string, i: int): uint32 = uint32(uint8(s[i])) and 0x3f'u32

func codepoint*(s: string, pos: var int, endPos: int): uint32 =
  ## Decodes one UTF-8 character at `pos` (upstream quirks kept: a malformed
  ## or truncated sequence advances one byte and yields 0).
  let p = uint32(uint8(s[pos]))
  if (p and 0x80'u32) == 0:
    inc pos
    return p
  if (p and 0xe0'u32) == 0xc0'u32 and pos + 1 < endPos:
    result = ((p and 0x1f'u32) shl 6) + cont(s, pos + 1)
    pos += 2
  elif (p and 0xf0'u32) == 0xe0'u32 and pos + 2 < endPos:
    result = ((p and 0x0f'u32) shl 12) + (cont(s, pos + 1) shl 6) + cont(s, pos + 2)
    pos += 3
  elif (p and 0xf8'u32) == 0xf0'u32 and pos + 3 < endPos:
    result = ((p and 0x07'u32) shl 18) + (cont(s, pos + 1) shl 12) +
             (cont(s, pos + 2) shl 6) + cont(s, pos + 3)
    pos += 4
  else:
    inc pos
    result = 0

proc request*(src: var GlyphSource, code: uint32): GlyphCell =
  ## Cached glyph of a codepoint; nil for code 0 or when it cannot be built.
  if code == 0: return nil
  if code in src.glyphs: return src.glyphs[code]
  let cell = GlyphCell(code: code)
  if src.reader.convertGlyph(cell.glyph, code, cell.path):
    src.glyphs[code] = cell
    return cell
  nil

func height(src: GlyphSource, loc: uint32, spacing: float32): float32 =
  let hhea = src.reader.sfnt.hhea
  (hhea.advance * float32(loc) - hhea.linegap) * spacing

func buildGlyph(glyph: RenderPath, cursor, offset: Point, output: var RenderPath) =
  output.cmds.add glyph.cmds
  for p in glyph.pts: output.pts.add p + cursor + offset

func alignBoth(align, box, cursor: Point, first, last: int, output: var RenderPath) =
  if align.x > 0.0'f32 or align.y > 0.0'f32:
    let shift = (box - cursor) * align
    for i in first ..< last: output.pts[i] += shift

func alignX(align, box, x: float32, first, last: int, output: var RenderPath) =
  if align > 0.0'f32:
    let shift = (box - x) * align
    for i in first ..< last: output.pts[i].x += shift

func alignY(align, box, y: float32, first, last: int, output: var RenderPath) =
  if align > 0.0'f32:
    let shift = (box - y) * align
    for i in first ..< last: output.pts[i].y += shift

func feedLine(src: GlyphSource, fm: var FontMetrics, box, x: float32, first, last: int,
    cursor: var Point, output: var RenderPath): int =
  alignX(fm.align.x, box, x, first, last, output)  # align the given line
  cursor.x = 0.0'f32
  cursor.y += src.reader.sfnt.hhea.advance * fm.spacing.y
  inc fm.lines
  output.pts.len

func finish(src: GlyphSource, fm: var FontMetrics, box: Point, line: int, cursorX: float32,
    output: var RenderPath) =
  fm.size.y = src.height(fm.lines, fm.spacing.y)
  alignY(fm.align.y, box.y, fm.size.y, 0, line, output)  # before the last line
  alignBoth(fm.align, box, pt(cursorX, fm.size.y), line, output.pts.len, output)

proc kerning(src: GlyphSource, left, right: GlyphCell): Point =
  if left != nil: discard src.reader.positioning(left.glyph.idx, right.glyph.idx, result)

proc wrapNone*(src: var GlyphSource, fm: var FontMetrics, eng: SfntMetrics, box: Point,
    text: string, endPos: int, output: var RenderPath) =
  var ltgm: GlyphCell
  var cursor = Point()
  var line = 0
  var pos = 0
  while pos < endPos:
    let code = codepoint(text, pos, endPos)
    if code == LineFeedCode:
      line = src.feedLine(fm, box.x, cursor.x, line, output.pts.len, cursor, output)
    else:
      let rtgm = src.request(code)
      if rtgm != nil:
        inc fm.length
        let offset = src.kerning(ltgm, rtgm)
        buildGlyph(rtgm.path, cursor, offset, output)
        cursor.x += (rtgm.glyph.advance + offset.x) * fm.spacing.x
        if cursor.x > fm.size.x: fm.size.x = cursor.x
        if ltgm == nil: eng.baseCode = rtgm.code
        ltgm = rtgm
  src.finish(fm, box, line, cursor.x, output)

proc wrapChar*(src: var GlyphSource, fm: var FontMetrics, eng: SfntMetrics, box: Point,
    text: string, endPos: int, output: var RenderPath) =
  var ltgm: GlyphCell
  var cursor = Point()
  var line = 0
  var pos = 0
  while pos < endPos:
    let code = codepoint(text, pos, endPos)
    if code == LineFeedCode:
      line = src.feedLine(fm, box.x, cursor.x, line, output.pts.len, cursor, output)
    else:
      let rtgm = src.request(code)
      if rtgm != nil:
        inc fm.length
        let offset = src.kerning(ltgm, rtgm)
        let xadv = (rtgm.glyph.advance + offset.x) * fm.spacing.x
        if xadv < box.x:
          if cursor.x + xadv > box.x:
            line = src.feedLine(fm, box.x, cursor.x, line, output.pts.len, cursor, output)
          buildGlyph(rtgm.path, cursor, offset, output)
          cursor.x += xadv
        else:  # not enough layout space, force pushing
          buildGlyph(rtgm.path, cursor, offset, output)
          line = src.feedLine(fm, box.x, cursor.x, line, output.pts.len, cursor, output)
        if cursor.x > fm.size.x: fm.size.x = cursor.x
        if ltgm == nil: eng.baseCode = rtgm.code
        ltgm = rtgm
  src.finish(fm, box, line, cursor.x, output)

proc wrapWord*(src: var GlyphSource, fm: var FontMetrics, eng: SfntMetrics, box: Point,
    text: string, endPos: int, output: var RenderPath, smart: bool) =
  var ltgm: GlyphCell
  var line = 0   # begin of the last line among the points
  var word = 0   # begin of the last word among the points
  var wadv = 0.0'f32   # word advance size
  let hadv = src.reader.sfnt.hhea.advance * fm.spacing.y
  var cursor = Point()
  var pos = 0
  while pos < endPos:
    let code = codepoint(text, pos, endPos)
    if code == LineFeedCode:
      line = src.feedLine(fm, box.x, cursor.x, line, output.pts.len, cursor, output)
    else:
      let rtgm = src.request(code)
      if rtgm != nil:
        inc fm.length
        let offset = src.kerning(ltgm, rtgm)
        let xadv = (rtgm.glyph.advance + offset.x) * fm.spacing.x
        if cursor.x + xadv > box.x:
          if (cursor.x - wadv) + xadv < box.x:  # enough space for the current word
            alignX(fm.align.x, box.x, wadv, line, word, output)
            for i in word ..< output.pts.len:   # shift the wrapping word down
              output.pts[i].x -= wadv
              output.pts[i].y += hadv
            cursor.x -= wadv
            cursor.y += hadv
            line = word
            wadv = 0.0'f32
            inc fm.lines
          elif smart:   # not enough space, wrap by character
            line = src.feedLine(fm, box.x, cursor.x, line, output.pts.len, cursor, output)
        buildGlyph(rtgm.path, cursor, offset, output)
        cursor.x += xadv
        if code == SpaceCode:
          word = output.pts.len
          wadv = cursor.x
        if cursor.x > fm.size.x: fm.size.x = cursor.x
        if ltgm == nil: eng.baseCode = rtgm.code
        ltgm = rtgm
  src.finish(fm, box, line, cursor.x, output)

proc wrapEllipsis*(src: var GlyphSource, fm: var FontMetrics, eng: SfntMetrics, box: Point,
    text: string, endPos: int, output: var RenderPath) =
  var ltgm: GlyphCell
  var line = 0
  var cursor = Point()
  # the last glyph, to revert it when the "..." does not fit
  var capPts, capCmds = 0
  var capAdv = 0.0'f32
  var capLength = 0'u32
  var stop = false
  var pos = 0
  while pos < endPos and not stop:
    let code = codepoint(text, pos, endPos)
    if code == LineFeedCode:
      line = src.feedLine(fm, box.x, cursor.x, line, output.pts.len, cursor, output)
    else:
      var rtgm = src.request(code)
      if rtgm != nil:
        var offset = src.kerning(ltgm, rtgm)
        let xadv = (rtgm.glyph.advance + offset.x) * fm.spacing.x
        if cursor.x + xadv < box.x:
          capPts = output.pts.len
          capCmds = output.cmds.len
          capAdv = xadv
          capLength = fm.length
          inc fm.length
          buildGlyph(rtgm.path, cursor, offset, output)
          cursor.x += xadv
        else:
          rtgm = src.request(DotCode)
          if rtgm == nil: return   # no glyph data for "..."
          offset = Point()
          discard src.reader.positioning(rtgm.glyph.idx, rtgm.glyph.idx, offset)
          if cursor.x + (rtgm.glyph.advance + offset.x) * 3.0'f32 > box.x:
            output.pts.setLen(capPts)
            output.cmds.setLen(capCmds)
            cursor.x -= capAdv
            fm.length = capLength
          fm.length += 3
          let tmp = (rtgm.glyph.advance + offset.x) * fm.spacing.x
          for i in 0 ..< 3:
            buildGlyph(rtgm.path, cursor, offset, output)
            cursor.x += tmp
          stop = true
        if cursor.x > fm.size.x: fm.size.x = cursor.x
        if ltgm == nil: eng.baseCode = rtgm.code
        ltgm = rtgm
  src.finish(fm, box, line, cursor.x, output)
