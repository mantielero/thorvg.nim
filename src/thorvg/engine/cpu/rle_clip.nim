## Clipping, merging and hit tests of RLE span lists.
##
## Ported from the second half of `src/renderer/cpu_engine/tvgSwRle.cpp`
## (`rleClip`, `rleIntersect`, `rleReset`, `rleRender(bbox)`) plus `SwRle::fetch`
## of `tvgSwCommon.h`. Spans are kept sorted by `y`, then `x`; indices replace the
## C++ `const SwSpan*` iterators.

import ../../core/[types, geom]
import common

func newRle*(): SwRle = SwRle(spans: @[])

func spanRange*(rle: SwRle, ymin, ymax: int32): Slice[int] =
  ## Indices `a..b` (inclusive) of the spans with `ymin <= y <= ymax`
  ## (C++ `SwRle::fetch`); an empty range has `a > b`. `rle` must not be empty.
  let n = rle.spans.len
  var a = 0
  if ymin > rle.spans[0].y:
    var lo = 0
    var hi = n
    while lo < hi:
      let mid = (lo + hi) shr 1
      if rle.spans[mid].y < ymin: lo = mid + 1
      else: hi = mid
    a = lo
  var e = n
  if ymax < rle.spans[n - 1].y:
    var lo = 0
    var hi = n
    while lo < hi:
      let mid = (lo + hi) shr 1
      if ymax < rle.spans[mid].y: hi = mid
      else: lo = mid + 1
    e = lo
  a .. e - 1

func rleRender*(bbox: Region): SwRle =
  ## A fully covered rectangle: one span of coverage 255 per row.
  result = newRle()
  let h = max(0, int(bbox.yMax) - int(bbox.yMin))
  result.spans = newSeq[SwSpan](h)
  let len = bbox.xMax - bbox.xMin
  for i in 0 ..< h:
    result.spans[i] = SwSpan(x: bbox.xMin, y: bbox.yMin + int32(i), len: len, coverage: 255)

proc rleReset*(rle: SwRle) =
  if rle != nil: rle.spans.setLen(0)

proc rleMerge*(rle, clip1, clip2: SwRle) =
  ## Replaces the spans of `rle` by the union of both lists, ordered by (y, x).
  ## Overlapping spans are kept as they are (the C++ declares this function but
  ## never defines it; this is the minimal sensible behavior, see DECISIONS D-T10a).
  var merged: seq[SwSpan] = @[]
  var i = 0
  var j = 0
  let n1 = if clip1 == nil: 0 else: clip1.spans.len
  let n2 = if clip2 == nil: 0 else: clip2.spans.len
  while i < n1 or j < n2:
    let takeFirst = j >= n2 or
      (i < n1 and (clip1.spans[i].y < clip2.spans[j].y or
        (clip1.spans[i].y == clip2.spans[j].y and clip1.spans[i].x <= clip2.spans[j].x)))
    if takeFirst:
      merged.add clip1.spans[i]
      inc i
    else:
      merged.add clip2.spans[j]
      inc j
  rle.spans = merged

proc rleClip*(rle, clip: SwRle): bool =
  ## Intersects `rle` with the spans of `clip`, multiplying the coverages.
  if rle.spans.len == 0 or clip.spans.len == 0: return false
  var res: seq[SwSpan] = @[]
  let r = rle.spanRange(clip.spans[0].y, clip.spans[^1].y)
  if r.a > r.b:
    rle.spans.setLen(0)
    return false
  let cr = clip.spanRange(rle.spans[r.a].y, rle.spans[r.b].y)
  var i = r.a
  var j = cr.a
  while i <= r.b and j <= cr.b:
    let s = rle.spans[i]
    let c = clip.spans[j]
    # align the y-coordinates, then skip empty or disjoint spans
    if c.y > s.y: inc i
    elif s.y > c.y: inc j
    elif s.len <= 0: inc i
    elif c.len <= 0: inc j
    elif s.x + s.len <= c.x: inc i
    elif c.x + c.len <= s.x: inc j
    else:
      let spanEnd = s.x + s.len
      let clipEnd = c.x + c.len
      let x = max(s.x, c.x)
      let cov = (int(s.coverage) * int(c.coverage) + 0xff) shr 8
      res.add SwSpan(x: x, y: s.y, len: min(spanEnd, clipEnd) - x, coverage: uint8(cov))
      if spanEnd <= clipEnd: inc i
      if clipEnd <= spanEnd: inc j
  rle.spans = res
  rle.spans.len > 0

proc rleClip*(rle: SwRle, clip: Region): bool =
  ## Crops `rle` to the rectangle `clip`.
  if rle.spans.len == 0 or clip.invalid: return false
  var res: seq[SwSpan] = @[]
  let r = rle.spanRange(clip.yMin, clip.yMax - 1)
  var i = r.a
  while i <= r.b and rle.spans[i].y < clip.yMax:
    let p = rle.spans[i]
    if p.y >= clip.yMin and p.x < clip.xMax and p.x + p.len > clip.xMin:
      var x = p.x
      var len = min(p.len, clip.xMax - x)
      if p.x < clip.xMin:
        x = clip.xMin
        len = min(p.len - (x - p.x), clip.xMax - x)
      if len > 0: res.add SwSpan(x: x, y: p.y, len: len, coverage: p.coverage)
    inc i
  rle.spans = res
  rle.spans.len > 0

proc rleIntersect*(rle: SwRle, region: Region): bool =
  ## True if some span of `rle` overlaps `region`.
  if rle == nil or rle.spans.len == 0: return false
  let r = rle.spanRange(region.yMin, region.yMax - 1)
  var i = r.a
  while i <= r.b and rle.spans[i].y < region.yMax:
    let p = rle.spans[i]
    if p.y >= region.yMin and p.x < region.xMax and p.x + p.len > region.xMin:
      return true
    inc i
  false
