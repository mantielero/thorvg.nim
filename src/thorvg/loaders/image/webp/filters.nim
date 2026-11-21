## WebP alpha-plane spatial filters. Ported from `dsp/filters.cpp` (`DoHorizontalFilter`,
## `DoVerticalFilter`, `DoGradientFilter`, the `*Unfilter` entry points).
##
## `unfilter` reverses the prediction of an `ALPH` chunk in place for the whole plane
## (stride = width): upstream calls it once per batch of rows, and every row only depends on
## the already reconstructed rows above it, so one call over all rows gives the same bytes.
## `filter` is the forward direction (`inverse = 0` upstream); it is only used by the encoder
## side of the tests.

type WebpFilter* = enum
  wfNone, wfHorizontal, wfVertical, wfGradient   ## `WEBP_FILTER_TYPE`

func gradientPredictor(a, b, c: byte): int =
  let g = int(a) + int(b) - int(c)
  if (g and not 0xff) == 0: g elif g < 0: 0 else: 255   # clip to 8 bit

func predict(input: openArray[byte], w, h: int, kind: WebpFilter, inverse: bool): seq[byte] =
  ## `DoXxxFilter` for rows `0 ..< h`. For the inverse direction the predictors are the
  ## already reconstructed output (`preds = out`), otherwise the original input.
  result = newSeq[byte](w * h)
  if w <= 0 or h <= 0 or input.len < w * h: return
  template pred(i: int): byte = (if inverse: result[i] else: input[i])
  template put(i: int, p: int) =
    result[i] = byte((if inverse: int(input[i]) + p else: int(input[i]) - p) and 0xff)
  result[0] = input[0]
  for x in 1 ..< w: put(x, int(pred(x - 1)))     # topmost scanline is left-predicted
  for y in 1 ..< h:
    let row = y * w
    case kind
    of wfHorizontal:
      put(row, int(pred(row - w)))               # leftmost pixel is predicted from above
      for x in 1 ..< w: put(row + x, int(pred(row + x - 1)))
    of wfVertical:
      for x in 0 ..< w: put(row + x, int(pred(row + x - w)))
    of wfGradient:
      put(row, int(pred(row - w)))
      for x in 1 ..< w:
        let i = row + x
        put(i, gradientPredictor(pred(i - 1), pred(i - w), pred(i - w - 1)))
    of wfNone:
      for x in 0 ..< w: result[row + x] = input[row + x]

proc unfilter*(plane: var seq[byte], w, h: int, kind: WebpFilter) =
  ## `WebPUnfilters[kind]` over the whole `w x h` plane (`wfNone` leaves it untouched).
  if kind != wfNone and w > 0 and h > 0 and plane.len >= w * h:
    plane = predict(plane, w, h, kind, true)

func filter*(plane: openArray[byte], w, h: int, kind: WebpFilter): seq[byte] =
  ## Forward filter (what an encoder stores in an `ALPH` chunk).
  if kind == wfNone: @plane else: predict(plane, w, h, kind, false)
