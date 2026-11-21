## TrueType (glyf) outlines and kerning on top of the sfnt reader.
##
## Ported from `src/modules/sfnt/tvgTtfReader.{h,cpp}`. Quadratic contours are
## converted to cubic curves exactly like upstream; composite glyphs only apply
## the component offset (the upstream scale / 2x2 transforms are TODO there too).
## Glyph y coordinates are flipped (y grows downward) as in the path output.

import ../../core/[types, geom, path]
import ./reader

export reader

type TtfReader* = object
  sfnt*: SfntReader
  loca, glyf, kern, kernEnd: int

const
  OnCurve = 0x01
  XShort = 0x02
  YShort = 0x04
  RepeatFlag = 0x08
  XSameOrPositive = 0x10
  YSameOrPositive = 0x20
  ArgsAreWords = 0x0001
  ArgsAreXy = 0x0002
  HaveScale = 0x0008
  MoreComponents = 0x0020
  HaveXyScale = 0x0040
  HaveTwoByTwo = 0x0080
  TwoThirds = 2.0'f32 / 3.0'f32

func readHeader*(t: var TtfReader): Result =
  ## `TtfReader::header`: sfnt header plus kern, loca and glyf tables.
  if t.sfnt.readHeader() != Result.Success: return Result.InvalidArguments
  t.kern = t.sfnt.table("kern")
  if t.kern != 0:
    let rec = t.sfnt.tableRecord("kern")
    let length = if rec < 0: 0 else: t.sfnt.u32(rec + 12)
    if length < 4 or not t.sfnt.validate(t.kern, length): return Result.InvalidArguments
    t.kernEnd = t.kern + length
    if t.sfnt.u16(t.kern) != 0 and (length < 8 or t.sfnt.u32(t.kern) != 0x00010000):
      return Result.InvalidArguments
  t.loca = t.sfnt.table("loca")
  t.glyf = t.sfnt.table("glyf")
  if t.loca == 0 or t.glyf == 0: return Result.InvalidArguments
  Result.Success

func outlineOffset(t: TtfReader, glyph: int): int =
  ## Offset of the glyph outline in the font, 0 for an empty glyph.
  var cur, next: int
  if t.sfnt.locaFormat == 0:
    let base = t.loca + 2 * glyph
    if not t.sfnt.validate(base, 4): return 0
    cur = 2 * t.sfnt.u16(base)
    next = 2 * t.sfnt.u16(base + 2)
  else:
    let base = t.loca + 4 * glyph
    if not t.sfnt.validate(base, 8): return 0
    cur = t.sfnt.u32(base)
    next = t.sfnt.u32(base + 4)
  if cur == next: 0 else: t.glyf + cur

func glyphMetrics(t: TtfReader, glyph: var SfntGlyph): int =
  ## hmtx metrics and bbox of a glyph; returns its outline offset (0 = none).
  if not t.sfnt.horizontalMetrics(glyph): return 0
  let glyphOffset = t.outlineOffset(int(glyph.idx))
  if glyphOffset == 0:
    glyph.bbox = BBox()
    return 0
  if not t.sfnt.validate(glyphOffset, 10): return 0
  glyph.bbox.min.x = float32(t.sfnt.i16(glyphOffset + 2))
  glyph.bbox.min.y = float32(t.sfnt.i16(glyphOffset + 4))
  glyph.bbox.max.x = float32(t.sfnt.i16(glyphOffset + 6))
  glyph.bbox.max.y = float32(t.sfnt.i16(glyphOffset + 8))
  glyphOffset

func readFlags(t: TtfReader, outline: var int, count: int, flags: var seq[int]): bool =
  var offset = outline
  var value = 0
  var repeat = 0
  flags.setLen(count)
  for i in 0 ..< count:
    if repeat > 0:
      dec repeat
    else:
      if not t.sfnt.validate(offset, 1): return false
      value = t.sfnt.u8(offset)
      inc offset
      if (value and RepeatFlag) != 0:
        if not t.sfnt.validate(offset, 1): return false
        repeat = t.sfnt.u8(offset)
        inc offset
    flags[i] = value
  outline = offset
  true

func readPoints(t: TtfReader, outline: int, flags: seq[int], offset: Point,
    pts: var seq[Point]): bool =
  var pos = outline
  var accum = 0
  pts.setLen(flags.len)
  for i, fl in flags:
    if (fl and XShort) != 0:
      if not t.sfnt.validate(pos, 1): return false
      let value = t.sfnt.u8(pos)
      inc pos
      if (fl and XSameOrPositive) != 0: accum += value else: accum -= value
    elif (fl and XSameOrPositive) == 0:
      if not t.sfnt.validate(pos, 2): return false
      accum += t.sfnt.i16(pos)
      pos += 2
    pts[i].x = offset.x + float32(accum)
  accum = 0
  for i, fl in flags:
    if (fl and YShort) != 0:
      if not t.sfnt.validate(pos, 1): return false
      let value = t.sfnt.u8(pos)
      inc pos
      if (fl and YSameOrPositive) != 0: accum += value else: accum -= value
    elif (fl and YSameOrPositive) == 0:
      if not t.sfnt.validate(pos, 2): return false
      accum += t.sfnt.i16(pos)
      pos += 2
    pts[i].y = offset.y - float32(accum)
  true

func convert(t: TtfReader, path: var RenderPath, glyphOffset: int, offset: Point,
    depth: int): bool

func composite(t: TtfReader, path: var RenderPath, glyphOffset: int, offset: Point,
    depth: int): bool =
  var cursor = glyphOffset + 10
  var flags = 0
  while true:
    if not t.sfnt.validate(cursor, 4): return false
    flags = t.sfnt.u16(cursor)
    var comp = SfntGlyph(idx: uint32(t.sfnt.u16(cursor + 2)))
    cursor += 4
    var compOffset = Point()
    if (flags and ArgsAreWords) != 0:
      if not t.sfnt.validate(cursor, 4): return false
      if (flags and ArgsAreXy) != 0:
        compOffset = pt(float32(t.sfnt.i16(cursor)), -float32(t.sfnt.i16(cursor + 2)))
      cursor += 4
    else:
      if not t.sfnt.validate(cursor, 2): return false
      if (flags and ArgsAreXy) != 0:
        compOffset = pt(float32(t.sfnt.i8(cursor)), -float32(t.sfnt.i8(cursor + 1)))
      cursor += 2
    var skip = 0
    if (flags and HaveScale) != 0: skip = 2
    elif (flags and HaveXyScale) != 0: skip = 4
    elif (flags and HaveTwoByTwo) != 0: skip = 8
    if skip > 0:
      if not t.sfnt.validate(cursor, skip): return false
      cursor += skip
    let compGlyphOffset = t.glyphMetrics(comp)
    if not t.convert(path, compGlyphOffset, offset + compOffset, depth): return false
    if (flags and MoreComponents) == 0: break
  true

func convert(t: TtfReader, path: var RenderPath, glyphOffset: int, offset: Point,
    depth: int): bool =
  if glyphOffset == 0: return true
  let outlineCnt = t.sfnt.i16(glyphOffset)
  if outlineCnt == 0: return false
  if outlineCnt < 0:
    var maxDepth = 16
    if t.sfnt.validate(t.sfnt.maxp, 32) and t.sfnt.u32(t.sfnt.maxp) >= 0x00010000:
      maxDepth = t.sfnt.u16(t.sfnt.maxp + 30)
    if depth > maxDepth: return false
    return t.composite(path, glyphOffset, offset, depth + 1)

  var outline = glyphOffset + 10
  if not t.sfnt.validate(outline, outlineCnt * 2 + 2): return false
  let ptsCnt = t.sfnt.u16(outline + (outlineCnt - 1) * 2) + 1
  var endPts = newSeq[int](outlineCnt)
  for i in 0 ..< outlineCnt:
    endPts[i] = t.sfnt.u16(outline)
    if i > 0 and endPts[i] <= endPts[i - 1]: return false
    outline += 2
  outline += 2 + t.sfnt.u16(outline)

  var flags: seq[int]
  var pts: seq[Point]
  if not t.readFlags(outline, ptsCnt, flags): return false
  if not t.readPoints(outline, flags, offset, pts): return false

  var begin = 0
  for i in 0 ..< outlineCnt:
    var offCurve = (flags[begin] and OnCurve) == 0
    let ptsBegin = if offCurve: (pts[begin] + pts[endPts[i]]) * 0.5'f32 else: pts[begin]
    path.moveTo(ptsBegin)
    let cnt = endPts[i] - begin + 1
    for x in 1 ..< cnt:
      let cur = pts[begin + x]
      let prev = pts[begin + x - 1]
      if (flags[begin + x] and OnCurve) != 0:
        if offCurve:
          let last = path.pts[^1]
          path.cubicTo(last + TwoThirds * (prev - last), cur + TwoThirds * (prev - cur), cur)
          offCurve = false
        else:
          path.lineTo(cur)
      elif offCurve:
        let last = path.pts[^1]
        let e = (cur + prev) * 0.5'f32
        path.cubicTo(last + TwoThirds * (prev - last), e + TwoThirds * (prev - e), e)
      else:
        offCurve = true
    if offCurve:
      let last = path.pts[^1]
      let prev = pts[begin + cnt - 1]
      path.cubicTo(last + TwoThirds * (prev - last), ptsBegin + TwoThirds * (prev - ptsBegin),
                   ptsBegin)
    path.close()
    begin = endPts[i] + 1
  true

func convertGlyph*(t: TtfReader, glyph: var SfntGlyph, codepoint: uint32,
    path: var RenderPath): bool =
  ## Looks up `codepoint`, fills the glyph metrics and appends its outline to `path`.
  glyph.idx = t.sfnt.glyphIndex(codepoint)
  if glyph.idx == InvalidGlyph: return false
  let glyphOffset = t.glyphMetrics(glyph)
  t.convert(path, glyphOffset, Point(), 1)

func positioning*(t: TtfReader, lglyph, rglyph: uint32, output: var Point): bool =
  ## Kerning adjustment between two glyphs, added to `output` (`TtfReader::positioning`).
  let r {.cursor.} = t.sfnt  # a plain `let` would deep-copy the whole font file
  if t.kern == 0: return false
  var kern = t.kern
  let apple = r.u16(kern) != 0
  var tableCnt = if apple: r.u32(kern + 4) else: r.u16(kern + 2)
  kern += (if apple: 8 else: 4)
  let headerSize = if apple: 8 else: 6
  let key = ((int(lglyph) and 0xffff) shl 16) or (int(rglyph) and 0xffff)
  while tableCnt > 0:
    dec tableCnt
    if t.kernEnd - kern < headerSize: return false
    let length = if apple: r.u32(kern) else: r.u16(kern + 2)
    if length < headerSize or length > t.kernEnd - kern: return false
    let next = kern + length
    let coverage = r.u16(kern + 4)
    let format = if apple: coverage and 0xff else: coverage shr 8
    let horizontal = if apple: (coverage and 0x8000) == 0 else: (coverage and 0x01) != 0
    let unsupported = if apple: (coverage and 0x2000) != 0 else: (coverage and 0x02) != 0
    let crossStream = if apple: (coverage and 0x4000) != 0 else: (coverage and 0x04) != 0
    kern += headerSize
    if format == 0 and horizontal and not unsupported:
      if next - kern < 8: return false
      let pairCnt = r.u16(kern)
      kern += 8
      if pairCnt > (next - kern) div 6: return false
      var lo = 0
      var hi = pairCnt - 1
      while lo <= hi:
        let mid = lo + (hi - lo) div 2
        let rec = kern + mid * 6
        let k = r.u32(rec)
        if k == key:
          let value = float32(r.i16(rec + 4))
          var adj = if crossStream: output.y else: output.x
          if crossStream and value == -32768.0'f32: adj = 0.0'f32
          elif not apple and (coverage and 0x08) != 0: adj = value
          else: adj += value
          if crossStream: output.y = adj else: output.x = adj
          break
        if k < key: lo = mid + 1 else: hi = mid - 1
    kern = next
  true
