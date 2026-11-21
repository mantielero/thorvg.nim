## PNG decoder: all color types and bit depths (1-16), palette, tRNS, Adam7 and filters.
##
## Ported from the lodepng copy in `src/modules/png/static/tvgLodePng.cpp` (ThorVG only
## requests RGBA8 output). The result is straight-alpha RGBA, 4 bytes per pixel, row
## major. 16-bit samples keep their high byte (no rounding) and 1/2/4-bit gray is scaled
## with `value * 255 div max`, exactly like lodepng. CRCs are not checked (ThorVG
## disables them). Error codes are lodepng's (0 = ok). Deviation: iCCP chunks are
## skipped, so no ICC-to-sRGB conversion is applied (see DECISIONS.md D-T15-2).

import ./inflate

type
  PngImage* = object
    width*, height*: int
    rgba*: seq[byte]       ## straight alpha, `width * height * 4` bytes

  PngColor = object
    colorType, bitDepth, interlace: int
    palette: array[256, array[4, byte]]
    hasPalette: bool
    paletteSize: int
    keyDefined: bool
    keyR, keyG, keyB: int

const
  PngSignature* = "\x89PNG\r\n\x1A\n"
  AdamX = [0, 4, 0, 2, 0, 1, 0]
  AdamY = [0, 0, 4, 0, 2, 0, 1]
  AdamDx = [8, 8, 4, 4, 2, 2, 1]
  AdamDy = [8, 8, 8, 4, 4, 2, 2]

func be32(data: openArray[byte], pos: int): int =
  (int(data[pos]) shl 24) or (int(data[pos + 1]) shl 16) or (int(data[pos + 2]) shl 8) or
    int(data[pos + 3])

func hasPngSignature*(data: openArray[byte]): bool =
  if data.len < PngSignature.len: return false
  for i, c in PngSignature:
    if data[i] != byte(c): return false
  true

func channels(colorType: int): int =
  case colorType
  of 0, 3: 1
  of 2: 3
  of 4: 2
  of 6: 4
  else: 0

func validColor(colorType, depth: int): bool =
  case colorType
  of 0: depth in [1, 2, 4, 8, 16]
  of 2, 4, 6: depth in [8, 16]
  of 3: depth in [1, 2, 4, 8]
  else: false

func inspectHeader(data: openArray[byte], c: var PngColor, w, h: var int): int =
  ## `lodepng_inspect`: signature, IHDR and its field validation.
  if data.len == 0: return 48
  if data.len < 33: return 27
  if not hasPngSignature(data): return 28
  if be32(data, 8) != 13: return 94
  if data[12] != byte('I') or data[13] != byte('H') or data[14] != byte('D') or
      data[15] != byte('R'): return 29
  w = be32(data, 16)
  h = be32(data, 20)
  c = PngColor(bitDepth: int(data[24]), colorType: int(data[25]), interlace: int(data[28]))
  if w == 0 or h == 0: return 93
  if not validColor(c.colorType, c.bitDepth):
    return if c.colorType in [0, 2, 3, 4, 6]: 37 else: 31
  if data[26] != 0: return 32
  if data[27] != 0: return 33
  if c.interlace > 1: return 34
  0

proc pngInspect*(data: openArray[byte], w, h: var int): int =
  ## Reads the dimensions from the header. Returns a lodepng error code (0 = ok).
  var c: PngColor
  inspectHeader(data, c, w, h)

func rawSizeIdat(w, h, bpp: int): int =
  ## Bytes of `h` scanlines including the filter byte of each.
  h * ((w div 8) * bpp + 1 + ((w and 7) * bpp + 7) div 8)

func expectedSize(c: PngColor, w, h: int): int =
  let bpp = channels(c.colorType) * c.bitDepth
  if c.interlace == 0: return rawSizeIdat(w, h, bpp)
  result = rawSizeIdat((w + 7) shr 3, (h + 7) shr 3, bpp)
  if w > 4: result += rawSizeIdat((w + 3) shr 3, (h + 7) shr 3, bpp)
  result += rawSizeIdat((w + 3) shr 2, (h + 3) shr 3, bpp)
  if w > 2: result += rawSizeIdat((w + 1) shr 2, (h + 3) shr 2, bpp)
  result += rawSizeIdat((w + 1) shr 1, (h + 1) shr 2, bpp)
  if w > 1: result += rawSizeIdat(w shr 1, (h + 1) shr 1, bpp)
  result += rawSizeIdat(w, h shr 1, bpp)

func readPalette(c: var PngColor, data: openArray[byte]): int =
  c.paletteSize = data.len div 3
  if c.paletteSize == 0 or c.paletteSize > 256: return 38
  for i in 0 ..< 256: c.palette[i] = [0'u8, 0'u8, 0'u8, 255'u8]
  for i in 0 ..< c.paletteSize:
    for k in 0 ..< 3: c.palette[i][k] = data[i * 3 + k]
  c.hasPalette = true
  0

func readTrns(c: var PngColor, data: openArray[byte]): int =
  case c.colorType
  of 3:
    if data.len > c.paletteSize: return 39
    for i in 0 ..< data.len: c.palette[i][3] = data[i]
  of 0:
    if data.len != 2: return 30
    c.keyDefined = true
    c.keyR = int(data[0]) * 256 + int(data[1])
    c.keyG = c.keyR
    c.keyB = c.keyR
  of 2:
    if data.len != 6: return 41
    c.keyDefined = true
    c.keyR = int(data[0]) * 256 + int(data[1])
    c.keyG = int(data[2]) * 256 + int(data[3])
    c.keyB = int(data[4]) * 256 + int(data[5])
  else: return 42
  0

func unfilter(src: openArray[byte], start, w, h, bpp: int, dst: var seq[byte],
    dstStart: int): int =
  ## Undoes the PNG row filters of one (reduced) image into `dst` (padded rows).
  let bw = (bpp + 7) div 8
  let lb = (w * bpp + 7) div 8
  for y in 0 ..< h:
    let si = start + y * (lb + 1)
    let o = dstStart + y * lb
    let ft = src[si]
    if ft > 4: return 36
    for i in 0 ..< lb:
      let a = if i >= bw: int(dst[o + i - bw]) else: 0
      let b = if y > 0: int(dst[o - lb + i]) else: 0
      let c = if y > 0 and i >= bw: int(dst[o - lb + i - bw]) else: 0
      var pred = 0
      case ft
      of 1: pred = a
      of 2: pred = b
      of 3: pred = (a + b) shr 1
      of 4:
        let pa = abs(b - c)
        let pb = abs(a - c)
        let pc = abs(a + b - c - c)
        pred = if pc < min(pa, pb): c elif pb < pa: b else: a
      else: discard
      dst[o + i] = byte((int(src[si + 1 + i]) + pred) and 255)
  0

func sample(buf: openArray[byte], base, x, bits: int): int =
  ## Sample `x` of a row starting at `base` (1/2/4-bit samples are MSB first).
  let bp = x * bits
  (int(buf[base + (bp shr 3)]) shr (8 - bits - (bp and 7))) and ((1 shl bits) - 1)

func convertPixel(c: PngColor, buf: openArray[byte], base, x: int, o: var seq[byte], oi: int) =
  ## One pixel of any PNG color model to RGBA8 (`getPixelColorsRGBA8`).
  var r, g, b = 0
  var alpha = 255
  let bd = c.bitDepth
  case c.colorType
  of 0:
    var v = 0
    if bd == 8: v = int(buf[base + x]); g = v
    elif bd == 16:
      g = int(buf[base + 2 * x])
      v = g * 256 + int(buf[base + 2 * x + 1])
    else:
      v = sample(buf, base, x, bd)
      g = v * 255 div ((1 shl bd) - 1)
    if c.keyDefined and v == c.keyR: alpha = 0
    r = g
    b = g
  of 2:
    let step = bd div 8
    let p = base + x * 3 * step
    r = int(buf[p])
    g = int(buf[p + step])
    b = int(buf[p + 2 * step])
    if c.keyDefined:
      let match = if bd == 8: r == c.keyR and g == c.keyG and b == c.keyB
        else: r * 256 + int(buf[p + 1]) == c.keyR and
          g * 256 + int(buf[p + step + 1]) == c.keyG and
          b * 256 + int(buf[p + 2 * step + 1]) == c.keyB
      if match: alpha = 0
  of 3:
    let e = c.palette[if bd == 8: int(buf[base + x]) else: sample(buf, base, x, bd)]
    r = int(e[0])
    g = int(e[1])
    b = int(e[2])
    alpha = int(e[3])
  of 4:
    let step = bd div 8
    r = int(buf[base + x * 2 * step])
    g = r
    b = r
    alpha = int(buf[base + x * 2 * step + step])
  else:
    let step = bd div 8
    let p = base + x * 4 * step
    r = int(buf[p])
    g = int(buf[p + step])
    b = int(buf[p + 2 * step])
    alpha = int(buf[p + 3 * step])
  o[oi] = byte(r)
  o[oi + 1] = byte(g)
  o[oi + 2] = byte(b)
  o[oi + 3] = byte(alpha)

func postProcess(c: PngColor, w, h: int, scan: openArray[byte], output: var seq[byte]): int =
  ## Unfilters, de-interlaces and converts to RGBA8.
  let bpp = channels(c.colorType) * c.bitDepth
  var start = 0
  let passes = if c.interlace == 0: 1 else: 7
  for p in 0 ..< passes:
    let ix = if c.interlace == 0: 0 else: AdamX[p]
    let iy = if c.interlace == 0: 0 else: AdamY[p]
    let dx = if c.interlace == 0: 1 else: AdamDx[p]
    let dy = if c.interlace == 0: 1 else: AdamDy[p]
    var pw = (w + dx - ix - 1) div dx
    var ph = (h + dy - iy - 1) div dy
    if pw == 0 or ph == 0:
      pw = 0
      ph = 0
    if pw > 0:
      let lb = (pw * bpp + 7) div 8
      var rows = newSeq[byte](lb * ph)
      let error = unfilter(scan, start, pw, ph, bpp, rows, 0)
      if error != 0: return error
      start += ph * (lb + 1)
      for py in 0 ..< ph:
        for px in 0 ..< pw:
          let oi = ((iy + py * dy) * w + ix + px * dx) * 4
          convertPixel(c, rows, py * lb, px, output, oi)
  0

proc pngDecode*(data: openArray[byte], image: var PngImage): int =
  ## Decodes a PNG file into straight RGBA8. Returns a lodepng error code (0 = ok);
  ## `image` is left empty on error.
  image = PngImage()
  var c: PngColor
  var w, h = 0
  var error = inspectHeader(data, c, w, h)
  if error != 0: return error
  if w > (high(int) div 64) div h: return 92
  var idat: seq[byte]
  var pos = 33
  var seenEnd = false
  while not seenEnd and error == 0:
    if pos + 12 > data.len: error = 30
    else:
      let len = be32(data, pos)
      if len > 2147483647: error = 63
      elif pos + len + 12 > data.len: error = 64
      else:
        let kind = char(data[pos + 4]) & char(data[pos + 5]) & char(data[pos + 6]) &
          char(data[pos + 7])
        let body = @(data.toOpenArray(pos + 8, pos + 7 + len))
        case kind
        of "IDAT": idat.add body
        of "IEND": seenEnd = true
        of "PLTE": error = readPalette(c, body)
        of "tRNS": error = readTrns(c, body)
        of "iCCP": discard
        else:
          if (data[pos + 4] and 32) == 0: error = 69
        pos += len + 12
  if error == 0 and c.colorType == 3 and not c.hasPalette: error = 106
  if error != 0: return error
  let expected = expectedSize(c, w, h)
  var scan: seq[byte]
  error = zlibDecompress(idat, scan)
  if error == 0 and scan.len != expected: error = 91
  if error != 0: return error
  var output = newSeq[byte](w * h * 4)
  error = postProcess(c, w, h, scan, output)
  if error == 0: image = PngImage(width: w, height: h, rgba: output)
  error
