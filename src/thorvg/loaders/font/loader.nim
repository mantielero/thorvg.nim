## `FontLoader` for TrueType (sfnt) fonts; registers itself for `FileType.Sfnt`.
##
## Ported from `src/modules/sfnt/tvgSfntLoader.{h,cpp}`. Importing this module
## is enough to make `.ttf` files and TTF data loadable through the loader
## manager (`acquireFile`, `acquireFont`). OpenType/CFF ("OTTO") fonts are
## reported as `Result.NonSupport`, as in a build without the OTF reader.
##
## Text layout API (called by `renderer/text`):
## - `get(fm, text, len, path)`: lays out the first `len` UTF-8 bytes of `text`
##   into `path` (font units, y down) and fills `fm.size/lines/length/scale`.
## - `transform(paint, fm, italicShear)`: sets the paint matrix that scales the
##   font-unit path to pixels (and shears it for italic).
## - `metrics(fm, out)` and `glyphMetrics(fm, text, pos, out, next)`.

import std/[tables, strutils]
import ../../core/[types, geom, path, str]
import ../../renderer/[loader, paint]
import ./[reader, ttf, wrap]

export reader, ttf, wrap

type SfntLoader* = ref object of FontLoader
  src*: GlyphSource

proc newSfntLoader*(): SfntLoader = SfntLoader(kind: FileType.Sfnt)

func sniffTtf(data: string): bool =
  data.len > 4 and (data[0 .. 3] == "\x00\x01\x00\x00" or data[0 .. 3] == "true")

method openData*(l: SfntLoader, data: string, ops: LoaderOps): Result =
  if data.len <= 4: return Result.InvalidArguments
  if data[0 .. 3] == "OTTO": return Result.NonSupport  # OpenType/CFF is not supported
  if not sniffTtf(data): return Result.InvalidArguments
  l.src = GlyphSource(reader: TtfReader(sfnt: SfntReader(data: data)))
  l.src.reader.readHeader()

method openFile*(l: SfntLoader, path: string, ops: LoaderOps): Result =
  var content = ""
  try:
    content = readFile(path)
  except IOError:
    return Result.InvalidArguments
  result = l.openData(content, ops)
  if result == Result.Success: l.name = strFilename(path)

method get*(l: SfntLoader, fm: var FontMetrics, text: string, len: uint32,
    output: var RenderPath): bool =
  output.clear()
  fm.lines = 1
  fm.length = 0
  if fm.fontSize == 0.0'f32: return false

  fm.scale = float32(l.src.reader.sfnt.unitsPerEm) / (fm.fontSize * FontDpi)
  fm.size = Point()
  if fm.engine == nil: fm.engine = SfntMetrics()
  let eng = SfntMetrics(fm.engine)
  let box = fm.box * fm.scale
  let endPos = min(int(len), text.len)

  if fm.wrap == TextWrap.None or fm.box.x == 0.0'f32:
    wrapNone(l.src, fm, eng, box, text, endPos, output)
  elif fm.wrap == TextWrap.Character: wrapChar(l.src, fm, eng, box, text, endPos, output)
  elif fm.wrap == TextWrap.Word: wrapWord(l.src, fm, eng, box, text, endPos, output, false)
  elif fm.wrap == TextWrap.Smart: wrapWord(l.src, fm, eng, box, text, endPos, output, true)
  else: wrapEllipsis(l.src, fm, eng, box, text, endPos, output)
  true

method transform*(l: SfntLoader, p: Paint, fm: var FontMetrics, italicShear: float32) =
  let scale = 1.0'f32 / fm.scale
  var baseWidth = 0.0'f32
  if fm.engine != nil:
    let code = SfntMetrics(fm.engine).baseCode
    if code in l.src.glyphs: baseWidth = l.src.glyphs[code].glyph.bbox.w()
  let m = Matrix(e11: scale, e12: -italicShear * scale, e13: italicShear * baseWidth * scale,
                 e21: 0.0'f32, e22: scale, e23: l.src.reader.sfnt.hhea.ascent * scale,
                 e31: 0.0'f32, e32: 0.0'f32, e33: 1.0'f32)
  discard p.transform(m)

method release*(l: SfntLoader, fm: var FontMetrics) =
  fm.engine = nil

method copy*(l: SfntLoader, src: FontMetrics, dst: var FontMetrics) =
  dst = src
  if src.engine != nil:
    dst.engine = SfntMetrics(baseCode: SfntMetrics(src.engine).baseCode)

method metrics*(l: SfntLoader, fm: FontMetrics, output: var TextMetrics) =
  let hhea = l.src.reader.sfnt.hhea
  let scale = (fm.fontSize * FontDpi) / float32(l.src.reader.sfnt.unitsPerEm)
  output.advance = hhea.advance * scale
  output.ascent = hhea.ascent * scale
  output.descent = hhea.descent * scale
  output.linegap = hhea.linegap * scale

method glyphMetrics*(l: SfntLoader, fm: FontMetrics, text: string, pos: int,
    output: var GlyphMetrics, next: var int): bool =
  var endPos = text.find('\0', pos)   # the C++ reads a NUL-terminated string
  if endPos < 0: endPos = text.len
  if pos < 0 or pos >= endPos: return false
  var p = pos
  let code = codepoint(text, p, endPos)
  let cell = l.src.request(code)
  if cell == nil: return false

  let scale = (fm.fontSize * FontDpi) / float32(l.src.reader.sfnt.unitsPerEm)
  output.advance = cell.glyph.advance * scale
  output.bearing = cell.glyph.lsb * scale
  # no bbox in the file: compute it (sfnt y is up, the path y is down)
  if cell.glyph.bbox.max.x == 0.0'f32 and cell.glyph.bbox.max.y == 0.0'f32:
    var box: BBox
    if cell.path.bounds(box):
      cell.glyph.bbox = BBox(min: pt(box.min.x, -box.max.y), max: pt(box.max.x, -box.min.y))
  output.min = cell.glyph.bbox.min * scale
  output.max = cell.glyph.bbox.max * scale
  next = p
  true

registerLoader(FileType.Sfnt, proc (): Loader = newSfntLoader(), sniffTtf)
