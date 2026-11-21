## WebP lossless (VP8L) decoder. Ported from `dec/vp8l.cpp`, `dec/vp8li.h`, `dec/alpha.cpp`
## (lossless alpha part) of the libwebp copy in `src/modules/webp/static`.
##
## Public API (input = the raw VP8L payload, i.e. the bytes of the `VP8L` chunk starting at
## the 0x2f signature byte; for alpha, the bytes after the 1-byte `ALPH` header):
##
## * `vp8lGetInfo(data, width, height, hasAlpha): bool` - header only (`VP8LGetInfo`).
## * `decodeVp8l(data, width, height, hasAlpha, abgr = false): seq[uint32]` - what
##   `WebPDecodeBGRA` (default) / `WebPDecodeRGBA` (`abgr = true`) returns for a lossless
##   image: PREMULTIPLIED pixels, one word each, row major, `width * height` words. Default
##   word = `a shl 24 or r shl 16 or g shl 8 or b` (memory bytes B,G,R,A = `ARGB8888`);
##   `abgr` word = `a shl 24 or b shl 16 or g shl 8 or r` (bytes R,G,B,A = `ABGR8888`).
##   Empty seq = failure (corrupt/truncated/unsupported stream); `width`/`height` are set as
##   soon as the header was valid.
## * `decodeVp8lAlpha(data, width, height): seq[byte]` - the alpha plane of an `ALPH`
##   chunk with lossless compression (green channel of the stream, `ExtractAlphaRows` /
##   paletted `DecodeAlphaData`), `width * height` bytes, still FILTERED (no unfilter
##   here). Empty seq = failure.
##
## Decoding is whole-image instead of upstream's 16-row blocks; inverse transforms are
## applied once afterwards (lossless_dsp.nim). See DECISIONS.md D-L5cA-*.

import ./[vp8l_bits, huffman, colorcache, lossless_dsp, vp8l_codes]

const
  MaxPixels* = 1 shl 26   ## D-L5cA-1: larger images are rejected (upstream would malloc)
  Vp8lMagicByte = 0x2f
  ImageSizeBits = 14
  FrameHeaderSize = 5
  CodeToPlaneCodes = 120
  CodeToPlane* = [
    0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a,
    0x26, 0x2a, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a,
    0x25, 0x2b, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b,
    0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03,
    0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d, 0x44, 0x4c,
    0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e,
    0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b,
    0x32, 0x3e, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f,
    0x64, 0x6c, 0x42, 0x4e, 0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b,
    0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e, 0x00, 0x74, 0x7c, 0x41,
    0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f,
    0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70]

type
  Meta = object        ## VP8LMetadata of one image stream
    cache: ColorCache
    huffmanBits: int
    huffmanXsize: int
    huffmanImage: seq[uint32]   ## group index per tile (empty = single group)
    groups: seq[HTreeGroup]
    tables: HuffmanTables

  Decoder = object
    br: Vp8lBitReader
    width, height: int          ## size after the transforms that change it
    meta: Meta
    transforms: seq[Vp8lTransform]
    seen: uint32

func readImageInfo(br: var Vp8lBitReader, w, h: var int, hasAlpha: var bool): bool =
  if br.readBits(8) != Vp8lMagicByte: return false
  w = int(br.readBits(ImageSizeBits)) + 1
  h = int(br.readBits(ImageSizeBits)) + 1
  hasAlpha = br.readBits(1) != 0
  if br.readBits(3) != 0: return false
  not br.eos

func vp8lGetInfo*(data: openArray[byte], width, height: var int, hasAlpha: var bool): bool =
  ## `VP8LGetInfo` (including `VP8LCheckSignature`).
  if data.len < FrameHeaderSize or data[0] != Vp8lMagicByte or (data[4] shr 5) != 0:
    return false
  var br = initBitReader(data)
  var w, h = 0
  var a = false
  if not readImageInfo(br, w, h, a): return false
  width = w
  height = h
  hasAlpha = a
  true

func getCopyDistance(sym: int, br: var Vp8lBitReader): int =
  if sym < 4: return sym + 1
  let extraBits = (sym - 2) shr 1
  let offset = (2 + (sym and 1)) shl extraBits
  offset + int(br.readBits(extraBits)) + 1

func planeCodeToDistance(xsize, planeCode: int): int =
  if planeCode > CodeToPlaneCodes: return planeCode - CodeToPlaneCodes
  let distCode = CodeToPlane[planeCode - 1]
  let dist = (distCode shr 4) * xsize + 8 - (distCode and 0xf)
  if dist >= 1: dist else: 1   # dist < 1 can happen if xsize is very small

func groupAt(m: Meta, x, y: int): int {.inline.} =
  if m.huffmanBits == 0: 0
  else: int(m.huffmanImage[m.huffmanXsize * (y shr m.huffmanBits) + (x shr m.huffmanBits)])

proc decodeImageData(br: var Vp8lBitReader, m: var Meta, data: var seq[uint32],
                     width, height: int): bool =
  ## `DecodeImageData` for the whole image (no row callback). Color cache insertions are
  ## done eagerly per pixel, which equals upstream's lazy `last_cached` catch-up.
  var src, col, row = 0
  let srcEnd = width * height
  let lenCodeLimit = NumLiteralCodes + NumLengthCodes
  let cacheLimit = lenCodeLimit + m.cache.colors.len
  let mask = if m.huffmanBits == 0: -1 else: (1 shl m.huffmanBits) - 1
  var g = m.groupAt(0, 0)
  while src < srcEnd:
    if (col and mask) == 0: g = m.groupAt(col, row)
    br.fillBitWindow()
    let code = readSymbol(m.tables, m.groups[g].htrees[Green], br)
    if br.eos: break
    if code < NumLiteralCodes or code >= lenCodeLimit:
      if code < NumLiteralCodes:
        if m.groups[g].isTrivialLiteral:
          data[src] = m.groups[g].literalArb or (uint32(code) shl 8)
        else:
          let red = readSymbol(m.tables, m.groups[g].htrees[Red], br)
          br.fillBitWindow()
          let blue = readSymbol(m.tables, m.groups[g].htrees[Blue], br)
          let alpha = readSymbol(m.tables, m.groups[g].htrees[Alpha], br)
          if br.eos: break
          data[src] = (uint32(alpha) shl 24) or (uint32(red) shl 16) or
            (uint32(code) shl 8) or uint32(blue)
      elif code < cacheLimit:
        data[src] = m.cache.lookup(code - lenCodeLimit)
      else:
        return false
      if m.cache.enabled: m.cache.insert(data[src])
      inc src
      inc col
      if col >= width:
        col = 0
        inc row
    else:
      var length = getCopyDistance(code - NumLiteralCodes, br)
      let distSymbol = readSymbol(m.tables, m.groups[g].htrees[Dist], br)
      br.fillBitWindow()
      let dist = planeCodeToDistance(width, getCopyDistance(distSymbol, br))
      if br.eos: break
      if src < dist or srcEnd - src < length: return false
      for i in 0 ..< length:
        data[src + i] = data[src + i - dist]
        if m.cache.enabled: m.cache.insert(data[src + i])
      src += length
      col += length
      while col >= width:
        col -= width
        inc row
      if (col and mask) != 0: g = m.groupAt(col, row)
  not br.eos

proc decodeAlphaData(br: var Vp8lBitReader, m: Meta, data: var seq[byte],
                     width, height: int): bool =
  ## `DecodeAlphaData` (8-bit path: one palette transform, trivial R/B/A, no cache). Unlike
  ## `decodeImageData` it tolerates the stream ending exactly with the last pixel.
  var pos, col, row = 0
  let endPos = width * height
  let lenCodeLimit = NumLiteralCodes + NumLengthCodes
  let mask = if m.huffmanBits == 0: -1 else: (1 shl m.huffmanBits) - 1
  var g = m.groupAt(0, 0)
  while not br.eos and pos < endPos:
    if (col and mask) == 0: g = m.groupAt(col, row)
    br.fillBitWindow()
    let code = readSymbol(m.tables, m.groups[g].htrees[Green], br)
    if code < NumLiteralCodes:
      data[pos] = byte(code)
      inc pos
      inc col
      if col >= width:
        col = 0
        inc row
    elif code < lenCodeLimit:
      let length = getCopyDistance(code - NumLiteralCodes, br)
      let distSymbol = readSymbol(m.tables, m.groups[g].htrees[Dist], br)
      br.fillBitWindow()
      let dist = planeCodeToDistance(width, getCopyDistance(distSymbol, br))
      if pos >= dist and endPos - pos >= length:
        for i in 0 ..< length: data[pos + i] = data[pos + i - dist]
      else:
        return false
      pos += length
      col += length
      while col >= width:
        col -= width
        inc row
      if pos < endPos and (col and mask) != 0: g = m.groupAt(col, row)
    else:
      return false
  not (br.eos and pos < endPos)

proc decodeImageStream(d: var Decoder, xsize, ysize: int, level0: bool,
                       data: var seq[uint32]): bool

proc readTransform(d: var Decoder, xsize, ysize: var int): bool =
  let kind = TransformKind(d.br.readBits(2))
  if (d.seen and (1'u32 shl uint32(ord(kind)))) != 0: return false   # one per type
  d.seen = d.seen or (1'u32 shl uint32(ord(kind)))
  var t = Vp8lTransform(kind: kind, xsize: xsize, ysize: ysize)
  case kind
  of tkPredictor, tkCrossColor:
    t.bits = int(d.br.readBits(3)) + 2
    result = d.decodeImageStream(subSampleSize(t.xsize, t.bits),
                                 subSampleSize(t.ysize, t.bits), false, t.data)
  of tkColorIndexing:
    let numColors = int(d.br.readBits(8)) + 1
    t.bits = if numColors > 16: 0 elif numColors > 4: 1 elif numColors > 2: 2 else: 3
    xsize = subSampleSize(t.xsize, t.bits)
    result = d.decodeImageStream(numColors, 1, false, t.data)
    if result:
      # remap to span all bundled values; the tail is transparent black
      let finalNumColors = 1 shl (8 shr t.bits)
      var map = newSeq[uint32](finalNumColors)
      map[0] = t.data[0]
      for i in 1 ..< numColors: map[i] = addPixels(t.data[i], map[i - 1])
      t.data = map
  of tkSubtractGreen:
    result = true
  d.transforms.add t

proc readMetaImage(d: var Decoder, m: var Meta, xsize, ysize: int): int =
  ## Optional meta prefix image: fills `m.huffmanImage`, returns the group count (0 = error).
  result = 1
  if d.br.readBits(1) != 0:
    m.huffmanBits = int(d.br.readBits(3)) + 2
    m.huffmanXsize = subSampleSize(xsize, m.huffmanBits)
    if not d.decodeImageStream(m.huffmanXsize, subSampleSize(ysize, m.huffmanBits), false,
                               m.huffmanImage):
      return 0
    for i in 0 ..< m.huffmanImage.len:
      let group = (m.huffmanImage[i] shr 8) and 0xffff
      m.huffmanImage[i] = group
      result = max(result, int(group) + 1)

proc decodeImageStream(d: var Decoder, xsize, ysize: int, level0: bool,
                       data: var seq[uint32]): bool =
  ## `DecodeImageStream`: level 0 reads transforms + codes and leaves the metadata in `d`;
  ## sub-images (transform data, meta image) are decoded to `data`.
  var txs = xsize
  var tys = ysize
  if level0:
    while d.br.readBits(1) != 0:
      if not d.readTransform(txs, tys): return false
  var cacheBits = 0
  if d.br.readBits(1) != 0:
    cacheBits = int(d.br.readBits(4))
    if cacheBits < 1 or cacheBits > MaxCacheBits: return false
  var m = Meta()
  let numGroups = if level0: d.readMetaImage(m, txs, tys) else: 1
  if numGroups == 0 or d.br.eos: return false
  if not readHuffmanCodes(d.br, numGroups, cacheBits, m.tables, m.groups): return false
  if cacheBits > 0: m.cache = initColorCache(cacheBits)
  d.width = txs
  d.height = tys
  if level0:
    d.meta = m
    return true
  if txs * tys > MaxPixels: return false
  data = newSeq[uint32](txs * tys)
  decodeImageData(d.br, m, data, txs, tys)

func applyTransforms(d: Decoder, pix: var seq[uint32], width: int): seq[uint32] =
  ## Inverse transforms in reverse reading order; `width` = decoded (packed) width.
  discard width
  for i in countdown(d.transforms.high, 0):
    let t = d.transforms[i]
    if t.kind == tkColorIndexing: pix = colorIndexInverse(t, pix, t.ysize)
    else: inverseTransform(t, pix, t.ysize)
  pix

proc decodeUnchecked*(data: openArray[byte], width, height: var int, hasAlpha: var bool,
                      abgr = false): seq[uint32] =
  ## `decodeVp8l` without the defect safety net (used by the robustness tests).
  var d = Decoder(br: initBitReader(data))
  var w, h = 0
  var a = false
  if not readImageInfo(d.br, w, h, a): return
  width = w
  height = h
  hasAlpha = a
  var dummy: seq[uint32]
  if not d.decodeImageStream(w, h, true, dummy): return
  if d.width * d.height > MaxPixels: return
  var pix = newSeq[uint32](d.width * d.height)
  if not decodeImageData(d.br, d.meta, pix, d.width, d.height): return
  result = d.applyTransforms(pix, d.width)
  convertFromBgra(result, abgr)

proc decodeVp8l*(data: openArray[byte], width, height: var int, hasAlpha: var bool,
                 abgr = false): seq[uint32] =
  ## See the module header. Never raises: stray defects on hostile input become failure.
  try:
    result = decodeUnchecked(data, width, height, hasAlpha, abgr)
  except IndexDefect, RangeDefect, OverflowDefect:
    result = @[]

proc decodeAlphaUnchecked*(data: openArray[byte], width, height: int): seq[byte] =
  if data.len == 0 or width <= 0 or height <= 0: return
  var d = Decoder(br: initBitReader(data))
  var dummy: seq[uint32]
  if not d.decodeImageStream(width, height, true, dummy): return
  let m = d.meta
  var opt = d.transforms.len == 1 and d.transforms[0].kind == tkColorIndexing and
    m.cache.colors.len == 0
  if opt:   # Is8bOptimizable: only trivial red/blue/alpha trees
    for g in m.groups:
      for j in [Red, Blue, Alpha]:
        if m.tables[g.htrees[j]].bits > 0: opt = false
  if d.width * d.height > MaxPixels: return
  if opt:
    var packed = newSeq[byte](d.width * d.height)
    var mm = d.meta
    if not decodeAlphaData(d.br, mm, packed, d.width, d.height): return
    return colorIndexInverseAlpha(d.transforms[0], packed, d.transforms[0].ysize)
  var pix = newSeq[uint32](d.width * d.height)
  if not decodeImageData(d.br, d.meta, pix, d.width, d.height): return
  pix = d.applyTransforms(pix, d.width)
  result = newSeq[byte](pix.len)
  for i in 0 ..< pix.len: result[i] = byte((pix[i] shr 8) and 0xff)

proc decodeVp8lAlpha*(data: openArray[byte], width, height: int): seq[byte] =
  ## See the module header. Never raises.
  try:
    result = decodeAlphaUnchecked(data, width, height)
  except IndexDefect, RangeDefect, OverflowDefect:
    result = @[]
