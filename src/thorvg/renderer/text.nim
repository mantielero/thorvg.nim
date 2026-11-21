## Text paint: a UTF-8 string laid out by a `FontLoader` into the path of an
## internal Shape (as upstream does), plus font/layout/style properties.
##
## Ported from `src/renderer/tvgText.h` / `tvgText.cpp` (`TextImpl`).
## Font loading lives in `fonts.nim` (re-exported here). Deviations
## (DECISIONS.md D-T19-*): no destructor, call `unload(text)` to give the font
## loader back; the setters that upstream leaves unmarked (`font`, `size`,
## `layout`, `spacing`, `italic`, `align`) also flag the path so a text that was
## already drawn re-lays itself out.

import std/options
import ../core/[types, geom, fill]
import ./[render, paint, shape, loader, fonts]

export fonts

type Text* = ref object of Paint
  glyphs: Shape           ## text shape (the glyph outlines)
  loader: FontLoader
  fm: FontMetrics
  utf8: string
  hasText: bool           ## text() was called (upstream: utf8 != nullptr)
  outlineWidth, italicShear: float32
  updated: bool

proc newText*(): Text =
  ## An empty text (no font, size 0): set `font`, `size` and `text` before use.
  result = Text(glyphs: newShape(), fm: initFontMetrics())
  initPaint(result)
  result.glyphs.parent = result
  discard result.glyphs.strokeJoin(StrokeJoin.Round)

proc glyphShape*(t: Text): Shape = t.glyphs
  ## The internal shape that holds the glyph path and the fill / outline.

proc unload*(t: Text) =
  ## Gives the font loader back (upstream does it in the destructor).
  if t.loader != nil:
    t.loader.release(t.fm)
    discard retrieve(t.loader)
    t.loader = nil

proc invalidate(t: Text) =
  t.updated = true
  t.mark RenderUpdateFlag.Path

proc ensureLayout(t: Text): bool =
  ## `TextImpl::load`: regenerates the glyph path when something changed.
  if t.loader == nil: return false
  if t.updated:
    if t.hasText and t.loader.get(t.fm, t.utf8, uint32(t.utf8.len), t.glyphs.rs.path):
      t.loader.transform(t.glyphs, t.fm, t.italicShear)
      t.glyphs.mark RenderUpdateFlag.Path
    t.updated = false
  true

# ---- Paint behaviour -----------------------------------------------------------

method kind*(t: Text): PaintKind = PaintKind.Text
method skipUpdate*(t: Text, flags: RenderUpdateFlags): bool = flags == {}

method regionImpl*(t: Text): Region =
  if t.ensureLayout() and t.glyphs.rd != nil and t.glyphs.renderer != nil:
    t.glyphs.regionImpl()
  else: Region()

method releaseChildren*(t: Text) = t.glyphs.disposeRender()

proc scaleGradient(f: var Fill, scale: float32) =
  case f.kind
  of FillKind.Linear:
    f.p1 *= scale
    f.p2 *= scale
  of FillKind.Radial:
    f.center *= scale
    f.r *= scale
    f.focal *= scale
    f.fr *= scale
  of FillKind.Conic:
    f.center *= scale

method updateImpl*(t: Text, r: RenderMethod, tm: Matrix, clips: var seq[RenderData],
    opacity: uint8, flags: RenderUpdateFlags, clipper: bool): bool =
  if not t.ensureLayout(): return true
  # the gradient coordinates follow the final scaled font
  if t.glyphs.rs.fill.isSome and t.glyphs.marked(RenderUpdateFlag.Gradient):
    var f = t.glyphs.rs.fill.get
    scaleGradient(f, t.fm.scale)
    t.glyphs.rs.fill = some(f)
  if t.outlineWidth > 0.0'f32 and t.marked(RenderUpdateFlag.Stroke):
    discard t.glyphs.strokeWidth(t.outlineWidth * t.fm.scale)
  discard t.glyphs.update(r, tm, clips, opacity, flags)
  true

method renderImpl*(t: Text, r: RenderMethod, flags: CompositionFlags): bool =
  if t.loader == nil or t.fm.engine == nil: return true
  discard r.blend(t.blendMethod)
  t.glyphs.render(r)

method boundsImpl*(t: Text, pt4: var array[4, Point], m: Matrix, obb: bool): bool =
  if not t.ensureLayout(): return true
  t.glyphs.paintBounds(pt4, m, obb)

method intersectsImpl*(t: Text, region: Region, visibleOnly: bool): bool =
  if not t.ensureLayout(): return false
  t.glyphs.intersectsImpl(region, false)

method duplicateImpl*(t: Text): Paint =
  discard t.ensureLayout()
  let dup = newText()
  dup.glyphs.rs = t.glyphs.rs
  if t.loader != nil:
    dup.loader = t.loader
    inc t.loader.sharing
    t.loader.copy(t.fm, dup.fm)
  else:
    dup.fm = t.fm
  dup.utf8 = t.utf8
  dup.hasText = t.hasText
  dup.italicShear = t.italicShear
  dup.outlineWidth = t.outlineWidth
  dup.updated = true
  dup

# ---- text, font, layout ------------------------------------------------------------

proc text*(t: Text, s: string): Result =
  t.utf8 = s
  t.hasText = true
  t.invalidate()
  Result.Success

proc text*(t: Text): string = t.utf8

proc font*(t: Text, name: string = ""): Result =
  ## Selects a loaded font by name; an empty name takes any loaded font.
  let ld = if name.len > 0: font(name) else: anyFont()
  if ld == nil: return Result.InsufficientCondition
  let fl = FontLoader(ld)
  if t.loader == fl:
    dec fl.sharing              # same resource: keep the reference count
    return Result.Success
  t.unload()
  t.loader = fl
  t.invalidate()
  Result.Success

proc size*(t: Text, fontSize: float32): Result =
  ## Font size in points.
  if fontSize <= 0.0'f32: return Result.InvalidArguments
  if t.fm.fontSize != fontSize:
    t.fm.fontSize = fontSize
    t.invalidate()
  Result.Success

proc font*(t: Text, name: string, fontSize: float32): Result =
  ## `font(name)` followed by `size(fontSize)`.
  result = t.font(name)
  if result == Result.Success: result = t.size(fontSize)

proc align*(t: Text, x, y: float32): Result =
  ## Alignment inside the layout box: 0 = left/top, 0.5 = center, 1 = right/bottom.
  t.fm.align = pt(x, y)
  t.mark RenderUpdateFlag.Transform
  t.invalidate()
  Result.Success

proc layout*(t: Text, w, h: float32): Result =
  ## Layout box in pixels (0 = unbounded) used by alignment and wrapping.
  t.fm.box = pt(w, h)
  t.invalidate()
  Result.Success

proc wrap*(t: Text, mode: TextWrap): Result =
  if t.fm.wrap != mode:
    t.fm.wrap = mode
    t.invalidate()
  Result.Success

proc spacing*(t: Text, letter, line: float32): Result =
  ## Scale of the letter and line spacing (1 = font default); negative is invalid.
  if letter < 0.0'f32 or line < 0.0'f32: return Result.InvalidArguments
  t.fm.spacing = pt(letter, line)
  t.invalidate()
  Result.Success

proc italic*(t: Text, shear: float32 = 0.18'f32): Result =
  ## Shear factor, clamped to 0..0.5.
  t.italicShear = clamp(shear, 0.0'f32, 0.5'f32)
  t.invalidate()
  Result.Success

# ---- appearance -------------------------------------------------------------------

proc fill*(t: Text, r, g, b: uint8): Result = t.glyphs.fill(r, g, b, 255)
proc fill*(t: Text, f: Fill): Result = t.glyphs.fill(f)

proc outline*(t: Text, width: float32, r, g, b: uint8): Result =
  t.outlineWidth = width
  discard t.glyphs.strokeFill(r, g, b, 255)
  t.mark RenderUpdateFlag.Stroke
  Result.Success

# ---- queries ------------------------------------------------------------------------

proc lines*(t: Text): uint32 =
  ## Number of laid-out lines.
  if t.ensureLayout(): t.fm.lines else: 0'u32

proc length*(t: Text): uint32 =
  ## Number of laid-out characters.
  if t.ensureLayout(): t.fm.length else: 0'u32

proc metrics*(t: Text, output: var TextMetrics): Result =
  ## Font metrics (ascent, descent, linegap, advance) at the current size.
  if t.loader == nil or t.fm.fontSize <= 0.0'f32: return Result.InsufficientCondition
  t.loader.metrics(t.fm, output)
  Result.Success

proc metrics*(t: Text, s: string, pos: int, output: var GlyphMetrics,
    next: var int): Result =
  ## Metrics of the character at byte `pos` of `s`; `next` gets the following index.
  if t.loader == nil or t.fm.fontSize <= 0.0'f32: return Result.InsufficientCondition
  if t.loader.glyphMetrics(t.fm, s, pos, output, next): Result.Success
  else: Result.InvalidArguments
