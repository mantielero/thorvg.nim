## Scan converter: turns a fixed-point `SwOutline` into coverage spans (`SwRle`).
##
## Ported from `src/renderer/cpu_engine/tvgSwRle.cpp` (derived from the FreeType
## smooth rasterizer, see the FreeType license in the C++ file).
##
## Differences from C++: the pooled cell buffer and the vertical band splitting that
## only exists to bound memory are gone; the cells live in a local `seq` and the whole
## region is swept as one band (the spans produced are identical). All arithmetic uses
## 64-bit `int`; C++ `long` is 32-bit on Windows, the values stay in range for sane
## inputs. The clip / intersect / merge operations live in `rle_clip.nim`.

import ../../core/[types, geom]
import common, rle_clip, rle_cells

export rle_clip

const
  PixelBits = 8
  OnePixel = 1 shl PixelBits
  ShrtMax = 32767
  BezStackSize = 32 * 3 + 1
  LineStackSize = 32 + 1

type
  Pt = tuple[x, y: int]

  Worker = object
    rle: SwRle
    outline: SwOutline
    cellPos, cellMin, cellMax: Pt
    cellXCnt, cellYCnt: int
    area, cover: int
    grid: CellGrid          ## cells of every row (rle_cells.nim)
    pos: Pt
    bezStack: array[BezStackSize + 8, Pt]
    lineStack: array[LineStackSize + 4, Pt]
    invalid, antiAlias: bool

func `-`(a, b: Pt): Pt = (a.x - b.x, a.y - b.y)
func `==`(a, b: Pt): bool {.inline.} = a.x == b.x and a.y == b.y  # system's is an out-of-line call

func wrap32(v: int): int =
  ## Wraps to the signed 32-bit range like a C `int32_t` conversion.
  let u = v and 0xFFFFFFFF
  if u >= 0x80000000: u - 0x100000000 else: u

func upscale(p: SwPoint): Pt =
  (wrap32(int(p.x) shl (PixelBits - 6)), wrap32(int(p.y) shl (PixelBits - 6)))

func trunc(x: int): int = x shr PixelBits
func trunc(p: Pt): Pt = (trunc(p.x), trunc(p.y))
func fract(p: Pt): Pt = (p.x and (OnePixel - 1), p.y and (OnePixel - 1))

func hypot(p: Pt): int =
  ## `alpha max plus beta min` approximation of sqrt(x*x+y*y), error < 7%.
  let x = abs(p.x)
  let y = abs(p.y)
  if x > y: x + ((3 * y) shr 3) else: y + ((3 * x) shr 3)

func udiv(a, b: int): int =
  ## `(int32_t)((uint64_t(a) * uint64_t(b)) >> 32)` of the C++ `SW_UDIV` macro.
  wrap32(int((uint64(a) * uint64(b)) shr 32))

func splitCubic(base: var openArray[Pt], i: int) =
  base[i + 6].x = base[i + 3].x
  var c = base[i + 1].x
  var d = base[i + 2].x
  var a = (base[i].x + c) shr 1
  base[i + 1].x = a
  var b = (base[i + 3].x + d) shr 1
  base[i + 5].x = b
  c = (c + d) shr 1
  a = (a + c) shr 1
  base[i + 2].x = a
  b = (b + c) shr 1
  base[i + 4].x = b
  base[i + 3].x = (a + b) shr 1

  base[i + 6].y = base[i + 3].y
  c = base[i + 1].y
  d = base[i + 2].y
  a = (base[i].y + c) shr 1
  base[i + 1].y = a
  b = (base[i + 3].y + d) shr 1
  base[i + 5].y = b
  c = (c + d) shr 1
  a = (a + c) shr 1
  base[i + 2].y = a
  b = (b + c) shr 1
  base[i + 4].y = b
  base[i + 3].y = (a + b) shr 1

func splitLine(base: var openArray[Pt], i: int) =
  base[i + 2] = base[i + 1]
  base[i + 1] = ((base[i].x shr 1) + (base[i + 1].x shr 1),
                 (base[i].y shr 1) + (base[i + 1].y shr 1))

proc horizLine(rw: var Worker, x0, y0, area, aCount: int) =
  var x = x0 + rw.cellMin.x
  let y = y0 + rw.cellMin.y

  # clip the Y range
  if y < rw.cellMin.y or y >= rw.cellMax.y: return

  # the coverage is area / (PIXEL_BITS * PIXEL_BITS * 2), range 0 - 255
  var coverage = abs(area shr (PixelBits * 2 + 1 - 8))
  if rw.outline.fillRule == FillRule.EvenOdd:
    coverage = coverage and 511
    if coverage > 255: coverage = 511 - coverage
  elif coverage > 255:
    coverage = 255

  if coverage == 0: return
  if not rw.antiAlias: coverage = 255

  # see whether we can extend the last span
  if rw.rle.spans.len > 0:
    let last = rw.rle.spans.len - 1
    let span = rw.rle.spans[last]
    if int(span.coverage) == coverage and int(span.y) == y and int(span.x + span.len) == x:
      var xOver = 0
      if x + aCount >= rw.cellMax.x: xOver -= x + aCount - rw.cellMax.x
      if x < rw.cellMin.x: xOver -= rw.cellMin.x - x
      rw.rle.spans[last].len = span.len + int32(aCount + xOver)
      return

  var xOver = 0
  if x + aCount >= rw.cellMax.x: xOver -= x + aCount - rw.cellMax.x
  if x < rw.cellMin.x:
    xOver -= rw.cellMin.x - x
    x = rw.cellMin.x

  # nothing to draw
  if aCount + xOver <= 0: return

  rw.rle.spans.add SwSpan(x: int32(x), y: int32(y), len: int32(aCount + xOver),
                          coverage: uint8(coverage))

proc sweep(rw: var Worker) =
  if rw.grid.cells.len == 0: return
  for y in 0 ..< rw.cellYCnt:
    var cover = 0
    var x = 0
    var ci = rw.grid.firstCell(y)
    while ci >= 0:
      let cell = rw.grid.cells[ci]
      if cell.x > x and cover != 0: horizLine(rw, x, y, cover * (OnePixel * 2), cell.x - x)
      cover += cell.cover
      let area = cover * (OnePixel * 2) - cell.area
      if area != 0 and cell.x >= 0: horizLine(rw, cell.x, y, area, 1)
      x = int(cell.x) + 1
      ci = int(cell.next)
    if cover != 0: horizLine(rw, x, y, cover * (OnePixel * 2), rw.cellXCnt - x)

proc recordCell(rw: var Worker) =
  if rw.area != 0 or rw.cover != 0:
    let ci = rw.grid.findCell(rw.cellPos.y, min(rw.cellPos.x, rw.cellXCnt))
    rw.grid.cells[ci].area += rw.area
    rw.grid.cells[ci].cover += rw.cover

proc setCell(rw: var Worker, p: Pt) =
  ## Moves the cell cursor; cells left of the clip region go to x = -1 and cells
  ## outside the band are flagged `invalid` (not recorded).
  var pos = p - rw.cellMin
  if pos.x < 0: pos.x = -1
  elif pos.x > rw.cellMax.x: pos.x = rw.cellMax.x

  if pos != rw.cellPos:
    if not rw.invalid: recordCell(rw)
    rw.area = 0
    rw.cover = 0
    rw.cellPos = pos
  rw.invalid = pos.y < 0 or pos.y >= rw.cellYCnt or pos.x >= rw.cellXCnt

proc startCell(rw: var Worker, p: Pt) =
  var pos = p
  if pos.x > rw.cellMax.x: pos.x = rw.cellMax.x
  if pos.x < rw.cellMin.x: pos.x = rw.cellMin.x - 1
  rw.area = 0
  rw.cover = 0
  rw.cellPos = pos - rw.cellMin
  rw.invalid = false
  setCell(rw, pos)

proc moveTo(rw: var Worker, to: Pt) =
  if not rw.invalid: recordCell(rw)
  startCell(rw, trunc(to))
  rw.pos = to

proc addArea(rw: var Worker, f1, f2: Pt) =
  rw.cover += f2.y - f1.y
  rw.area += (f2.y - f1.y) * (f1.x + f2.x)

proc lineVertical(rw: var Worker, e1: var Pt, e2y: int, f1: var Pt, up: bool) =
  var more = true
  while more:
    let fy = if up: OnePixel else: 0
    rw.cover += fy - f1.y
    rw.area += (fy - f1.y) * f1.x * 2
    f1.y = OnePixel - fy
    e1.y += (if up: 1 else: -1)
    setCell(rw, e1)
    more = e1.y != e2y

proc lineSlope(rw: var Worker, e1: var Pt, e2: Pt, f1: var Pt, diff: Pt) =
  # `prod` tells on which side and where the line leaves the current cell
  var prod = diff.x * f1.y - diff.y * f1.x
  # divisions are replaced by multiplications and shifts
  let dxr = if e1.x != e2.x: 0xffffffff div diff.x else: 0
  let dyr = if e1.y != e2.y: 0xffffffff div diff.y else: 0
  let px = diff.x * OnePixel
  let py = diff.y * OnePixel
  var f2: Pt
  var more = true
  while more:
    if prod <= 0 and prod - px > 0:                       # left
      f2 = (0, udiv(-prod, -dxr))
      prod -= py
      addArea(rw, f1, f2)
      f1 = (OnePixel, f2.y)
      dec e1.x
    elif prod - px <= 0 and prod - px + py > 0:           # up
      prod -= px
      f2 = (udiv(-prod, dyr), OnePixel)
      addArea(rw, f1, f2)
      f1 = (f2.x, 0)
      inc e1.y
    elif prod - px + py <= 0 and prod + py >= 0:          # right
      prod += py
      f2 = (OnePixel, udiv(prod, dxr))
      addArea(rw, f1, f2)
      f1 = (0, f2.y)
      inc e1.x
    else:                                                 # down
      f2 = (udiv(prod, -dyr), 0)
      prod += px
      addArea(rw, f1, f2)
      f1 = (f2.x, OnePixel)
      dec e1.y
    setCell(rw, e1)
    more = e1 != e2

proc drawLine(rw: var Worker, a, b: Pt) =
  ## Renders the segment a -> b, whose length is small enough to avoid overflows.
  let diff = b - a
  var e1 = trunc(a)
  let e2 = trunc(b)
  var f1 = fract(a)
  if e1 == e2: discard                       # inside one cell
  elif diff.y == 0:                          # any horizontal line
    e1.x = e2.x
    setCell(rw, e1)
  elif diff.x == 0:                          # vertical line
    lineVertical(rw, e1, e2.y, f1, diff.y > 0)
  else:
    lineSlope(rw, e1, e2, f1, diff)
  addArea(rw, f1, fract(b))
  rw.pos = b

proc lineTo(rw: var Worker, to: Pt): bool =
  ## False only if the subdivision stack overflows.
  let e1 = trunc(rw.pos)
  let e2 = trunc(to)

  # vertical clipping
  if (e1.y >= rw.cellMax.y and e2.y >= rw.cellMax.y) or
      (e1.y < rw.cellMin.y and e2.y < rw.cellMin.y):
    rw.pos = to
    return true

  var line = 0
  rw.lineStack[0] = to
  rw.lineStack[1] = rw.pos
  while line < LineStackSize:
    # split to avoid possible arithmetic overflow
    if hypot(rw.lineStack[line] - rw.lineStack[line + 1]) > ShrtMax:
      splitLine(rw.lineStack, line)
      inc line
    else:
      drawLine(rw, rw.lineStack[line + 1], rw.lineStack[line])
      if line == 0: return true
      dec line
  false

func cubicNeedsSplit(arc: openArray[Pt], i: int): bool =
  ## Rapid termination evaluation of Hain: decides whether to split or draw.
  let diff = arc[i + 3] - arc[i]                     # the P0 - P3 chord vector
  let l = hypot(diff)
  if l > ShrtMax: return true                        # avoid arithmetic overflow
  let sLimit = l * (OnePixel div 6)                  # deviation up to (s/L) * 3/4
  let diff1 = arc[i + 1] - arc[i]
  let diff2 = arc[i + 2] - arc[i]
  # s is L * the perpendicular distance from P1 / P2 to the line P0 - P3
  if abs(diff.y * diff1.x - diff.x * diff1.y) > sLimit: return true
  if abs(diff.y * diff2.x - diff.x * diff2.y) > sLimit: return true
  # acute angles P0-P1-P3 or P0-P2-P3 (very curvy segments)
  diff1.x * (diff1.x - diff.x) + diff1.y * (diff1.y - diff.y) > 0 or
    diff2.x * (diff2.x - diff.x) + diff2.y * (diff2.y - diff.y) > 0

proc cubicTo(rw: var Worker, ctrl1, ctrl2, to: Pt): bool =
  rw.bezStack[0] = to
  rw.bezStack[1] = ctrl2
  rw.bezStack[2] = ctrl1
  rw.bezStack[3] = rw.pos

  # short-cut the arc that does not cross the band
  var ymin = to.y
  var ymax = to.y
  for i in 1 .. 3:
    ymin = min(ymin, rw.bezStack[i].y)
    ymax = max(ymax, rw.bezStack[i].y)
  if trunc(ymin) >= rw.cellMax.y or trunc(ymax) < rw.cellMin.y:
    return lineTo(rw, to)

  var arc = 0
  while arc < BezStackSize:
    if cubicNeedsSplit(rw.bezStack, arc):
      splitCubic(rw.bezStack, arc)
      arc += 3
    else:
      if not lineTo(rw, rw.bezStack[arc]): return false
      if arc == 0: return true
      arc -= 3
  false

proc decomposeOutline(rw: var Worker): bool =
  let outline = rw.outline
  var idx = 0
  var start = upscale(outline.pts[0])
  var open = false

  for cmd in outline.cmds:
    case cmd
    of PathCommand.MoveTo:
      if open and not lineTo(rw, start): return false
      start = upscale(outline.pts[idx])
      inc idx
      moveTo(rw, start)
      open = true
    of PathCommand.LineTo:
      if not open: moveTo(rw, start)
      if not lineTo(rw, upscale(outline.pts[idx])): return false
      inc idx
      open = true
    of PathCommand.CubicTo:
      if not open: moveTo(rw, start)
      let c1 = upscale(outline.pts[idx])
      let c2 = upscale(outline.pts[idx + 1])
      let to = upscale(outline.pts[idx + 2])
      if not cubicTo(rw, c1, c2, to): return false
      idx += 3
      open = true
    of PathCommand.Close:
      if open and not lineTo(rw, start): return false
      open = false
  not open or lineTo(rw, start)

proc rleRender*(rle: SwRle, outline: SwOutline, bbox: Region, antiAlias: bool): SwRle =
  ## Rasterizes `outline` inside `bbox`, appending the spans to `rle` (a new list
  ## when `rle` is nil). Returns nil if the outline is nil or too complex.
  if outline == nil: return nil
  result = if rle == nil: newRle() else: rle
  if outline.pts.len == 0 or outline.cmds.len == 0 or bbox.invalid: return

  var rw = Worker(
    rle: result, outline: outline, invalid: true, antiAlias: antiAlias,
    cellMin: (int(bbox.xMin), int(bbox.yMin)), cellMax: (int(bbox.xMax), int(bbox.yMax)))
  rw.cellXCnt = rw.cellMax.x - rw.cellMin.x
  rw.cellYCnt = rw.cellMax.y - rw.cellMin.y
  rw.grid = initGrid(rw.cellYCnt)

  if decomposeOutline(rw):
    if not rw.invalid: recordCell(rw)
    sweep(rw)
  else:
    result = nil
