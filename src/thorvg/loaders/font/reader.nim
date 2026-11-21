## Big-endian sfnt container reader: table directory, cmap, hhea and hmtx.
##
## Ported from `src/modules/sfnt/tvgSfntReader.{h,cpp}`. The font bytes are an
## immutable `string`; offsets are `int`. Every primitive read is bounds
## checked and yields 0 outside the data (the C++ reads raw memory, but the
## `validate` calls make a well-formed read never go out of range).

import ../../core/types

const InvalidGlyph* = high(uint32)  ## C++ `INVALID_GLYPH` ((uint32_t)-1)

type
  SfntGlyph* = object
    idx*: uint32          ## glyph index
    advance*: float32     ## advance width
    lsb*: float32         ## left side bearing
    bbox*: BBox           ## bounding box in font units (y up), as in the file

  SfntReader* = object
    data*: string
    hhea*: TextMetrics    ## ascent / descent / linegap / advance in font units
    unitsPerEm*: int
    numHmtx*: int         ## number of long horizontal metrics
    locaFormat*: int      ## 0 for short offsets, 1 for long
    cmap*, hmtx*, maxp*: int

func u8*(r: SfntReader, offset: int): int =
  if offset < 0 or offset >= r.data.len: 0 else: int(uint8(r.data[offset]))

func u16*(r: SfntReader, offset: int): int =
  (u8(r, offset) shl 8) or u8(r, offset + 1)

func u32*(r: SfntReader, offset: int): int =
  (u16(r, offset) shl 16) or u16(r, offset + 2)

func i8*(r: SfntReader, offset: int): int =
  let v = u8(r, offset)
  if v >= 0x80: v - 0x100 else: v

func i16*(r: SfntReader, offset: int): int =
  let v = u16(r, offset)
  if v >= 0x8000: v - 0x10000 else: v

func validate*(r: SfntReader, offset, margin: int): bool =
  ## `SfntReader::validate`: `margin` bytes are readable at `offset`.
  offset >= 0 and margin >= 0 and offset <= r.data.len and r.data.len - offset >= margin

func tableRecord*(r: SfntReader, tag: string): int =
  ## Offset of the 16-byte directory record of `tag` (binary search like
  ## `bsearch`), or -1.
  let tableCnt = u16(r, 4)
  if not r.validate(12, tableCnt * 16): return -1
  var lo = 0
  var hi = tableCnt - 1
  while lo <= hi:
    let mid = lo + (hi - lo) div 2
    let rec = 12 + mid * 16
    var c = 0
    for i in 0 ..< 4:
      let d = u8(r, rec + i) - int(uint8(tag[i]))
      if c == 0: c = d
    if c == 0: return rec
    if c < 0: lo = mid + 1 else: hi = mid - 1
  -1

func table*(r: SfntReader, tag: string): int =
  ## Offset of a table in the font, 0 when absent.
  let rec = r.tableRecord(tag)
  if rec < 0: 0 else: u32(r, rec + 8)

func cmap12(r: SfntReader, table: int, codepoint: uint32): uint32 =
  ## Format 12 (segmented coverage); wraps like the C++ `uint32_t` math.
  let len = u32(r, table + 4)
  if len < 16 or not r.validate(table, len): return InvalidGlyph
  let entryCnt = u32(r, table + 12)
  for i in 0 ..< entryCnt:
    let firstCode = uint32(u32(r, table + i * 12 + 16))
    let lastCode = uint32(u32(r, table + i * 12 + 16 + 4))
    if codepoint >= firstCode and codepoint <= lastCode:
      let glyphOffset = uint32(u32(r, table + i * 12 + 16 + 8))
      return (codepoint - firstCode) + glyphOffset
  0

func cmap4(r: SfntReader, table: int, codepoint: uint32): uint32 =
  ## Format 4 (BMP segment mapping); `table` points at `segCountX2`.
  if not r.validate(table, 8): return InvalidGlyph
  if codepoint > 0xffff'u32: return 0
  let segmentCnt = u16(r, table)
  if segmentCnt == 0 or (segmentCnt and 1) != 0: return InvalidGlyph

  let endCodes = table + 8
  let startCodes = endCodes + segmentCnt + 2
  let idDeltas = startCodes + segmentCnt
  let idRangeOffsets = idDeltas + segmentCnt
  if not r.validate(idRangeOffsets, segmentCnt): return InvalidGlyph

  # binary search over the end codes (the next highest one when not found)
  let shortCode = int(codepoint)
  var lo = 0
  var hi = segmentCnt div 2 - 1
  while lo != hi:
    let mid = lo + (hi - lo) div 2
    if shortCode > u16(r, endCodes + mid * 2): lo = mid + 1 else: hi = mid
  let segmentIdx = lo * 2

  if u16(r, startCodes + segmentIdx) > shortCode: return 0
  let delta = u16(r, idDeltas + segmentIdx)
  let idRangeOffset = u16(r, idRangeOffsets + segmentIdx)
  if idRangeOffset == 0: return uint32((shortCode + delta) and 0xffff)

  let offset = idRangeOffsets + segmentIdx + idRangeOffset +
               2 * (shortCode - u16(r, startCodes + segmentIdx))
  if not r.validate(offset, 2): return InvalidGlyph
  let id = u16(r, offset)
  if id > 0: uint32((id + delta) and 0xffff) else: 0

func cmap6(r: SfntReader, table: int, codepoint: uint32): uint32 =
  ## Format 6 (trimmed table); `table` points at `firstCode`.
  if codepoint > 0xffff'u32: return 0
  let firstCode = u16(r, table)
  let entryCnt = u16(r, table + 2)
  if not r.validate(table, 4 + 2 * entryCnt): return InvalidGlyph
  let cp = int(codepoint)
  if cp < firstCode or cp - firstCode >= entryCnt: return 0
  uint32(u16(r, table + 4 + 2 * (cp - firstCode)))

func glyphIndex*(r: SfntReader, codepoint: uint32): uint32 =
  ## Glyph index of a Unicode codepoint: 0 = missing glyph, `InvalidGlyph` on
  ## malformed or unsupported cmap data.
  let entryCnt = u16(r, r.cmap + 2)
  if not r.validate(r.cmap, 4 + entryCnt * 8): return InvalidGlyph
  # full repertory (non-BMP map): only format 12 is supported
  for idx in 0 ..< entryCnt:
    let entry = r.cmap + 4 + idx * 8
    let kind = u16(r, entry) * 64 + u16(r, entry + 2)
    if kind == 4 or kind == 202:
      let table = r.cmap + u32(r, entry + 4)
      if not r.validate(table, 8): return InvalidGlyph
      if u16(r, table) == 12: return cmap12(r, table, codepoint)
      return InvalidGlyph
  # BMP map, including legacy Unicode 1.1 maps
  for idx in 0 ..< entryCnt:
    let entry = r.cmap + 4 + idx * 8
    let kind = u16(r, entry) * 64 + u16(r, entry + 2)
    if kind == 1 or kind == 3 or kind == 193:
      let table = r.cmap + u32(r, entry + 4)
      if not r.validate(table, 6): return InvalidGlyph
      case u16(r, table)
      of 4: return cmap4(r, table + 6, codepoint)
      of 6: return cmap6(r, table + 6, codepoint)
      else: return InvalidGlyph
  InvalidGlyph

func horizontalMetrics*(r: SfntReader, glyph: var SfntGlyph): bool =
  ## Fills `advance` and `lsb` of `glyph.idx` from the hmtx table.
  let idx = int(glyph.idx)
  if idx < r.numHmtx:
    let offset = r.hmtx + 4 * idx
    if not r.validate(offset, 4): return false
    glyph.advance = float32(u16(r, offset))
    glyph.lsb = float32(i16(r, offset + 2))
  else:
    let boundary = r.hmtx + 4 * r.numHmtx
    if boundary < 4 or not r.validate(boundary - 4, 4): return false
    glyph.advance = float32(u16(r, boundary - 4))
    let offset = boundary + 2 * (idx - r.numHmtx)
    if not r.validate(offset, 2): return false
    glyph.lsb = float32(i16(r, offset))
  true

func readHeader*(r: var SfntReader): Result =
  ## Parses head/hhea/maxp/cmap/hmtx (`SfntReader::header`).
  if not r.validate(0, 12): return Result.InvalidArguments
  let head = r.table("head")
  if head == 0 or not r.validate(head, 54): return Result.InvalidArguments
  r.unitsPerEm = u16(r, head + 18)
  r.locaFormat = u16(r, head + 50) and 0xff
  if r.unitsPerEm == 0: return Result.InvalidArguments  # C++ would divide by zero

  let hhea = r.table("hhea")
  if hhea == 0 or not r.validate(hhea, 36): return Result.InvalidArguments
  r.hhea.ascent = float32(i16(r, hhea + 4))
  r.hhea.descent = float32(i16(r, hhea + 6))
  r.hhea.linegap = float32(i16(r, hhea + 8))
  r.hhea.advance = r.hhea.ascent - r.hhea.descent + r.hhea.linegap
  r.numHmtx = u16(r, hhea + 34)

  r.maxp = r.table("maxp")
  if r.maxp == 0 or not r.validate(r.maxp, 6): return Result.InvalidArguments
  let glyphs = u16(r, r.maxp + 4)
  if glyphs == 0: return Result.InvalidArguments
  if r.numHmtx == 0 or r.numHmtx > glyphs: return Result.InvalidArguments

  r.cmap = r.table("cmap")
  if r.cmap == 0 or not r.validate(r.cmap, 4): return Result.InvalidArguments
  r.hmtx = r.table("hmtx")
  if not r.validate(r.hmtx, r.numHmtx * 4): return Result.InvalidArguments
  Result.Success
