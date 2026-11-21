## WebP RIFF container parsing. Ported from `dec/webp.cpp` (`ParseRIFF`, `ParseVP8X`,
## `ParseOptionalChunks`, `ParseVP8Header`, `ParseHeadersInternal`, `WebPParseHeaders`,
## `WebPGetFeatures`) and `dec/webpi.h`.
##
## Positions are byte offsets into the caller's buffer instead of pointers. Every status code
## of upstream is kept (`Vp8Status`), including the odd-chunk padding, the RIFF/chunk size
## checks and the "ALPH + VP8" / raw VP8 / raw VP8L forms that upstream accepts.

from ./vp8 import Vp8Status, vp8GetInfo
from ./vp8l import vp8lGetInfo

const
  TagSize = 4
  ChunkHeaderSize = 8
  RiffHeaderSize = 12
  Vp8xChunkSize = 10
  Vp8FrameHeaderSize = 10
  Vp8lFrameHeaderSize = 5
  MaxChunkPayload = 0xFFFFFFFF - ChunkHeaderSize - 1
  MaxImageArea = 1 shl 32
  AnimationFlag = 0x02'u32
  FragmentsFlag = 0x01'u32
  AlphaFlag = 0x10'u32

type
  WebpFeatures* = object
    ## `WebPBitstreamFeatures`; `format`: 0 undefined, 1 lossy, 2 lossless.
    width*, height*: int
    hasAlpha*, hasAnimation*: bool
    format*: int

  WebpHeaders* = object
    ## `WebPHeaderStructure` after a successful `parseHeaders`.
    offset*: int                ## start of the VP8/VP8L payload
    hasAlphaChunk*: bool        ## an `ALPH` chunk was found (the last one wins)
    alphaOffset*, alphaSize*: int
    compressedSize*: int        ## size announced by the VP8/VP8L chunk header
    riffSize*: int              ## 0 when the data has no RIFF header
    isLossless*: bool
    width*, height*: int        ## image size from the VP8/VP8L frame header

func le24(d: openArray[byte], p: int): int =
  int(d[p]) or (int(d[p + 1]) shl 8) or (int(d[p + 2]) shl 16)

func le32(d: openArray[byte], p: int): int = le24(d, p) or (int(d[p + 3]) shl 24)

func tagIs(d: openArray[byte], p: int, tag: string): bool =
  if p < 0 or p + TagSize > d.len: return false
  for i in 0 ..< TagSize:
    if d[p + i] != byte(tag[i]): return false
  true

func checkSignatureLossless(d: openArray[byte], p: int): bool =
  ## `VP8LCheckSignature` on `d[p ..]`.
  d.len - p >= Vp8lFrameHeaderSize and d[p] == 0x2f and (d[p + 4] shr 5) == 0

func parseRiff(d: openArray[byte], pos: var int, haveAllData: bool,
               riffSize: var int): Vp8Status =
  ## Validates the RIFF header (when present) and skips it.
  riffSize = 0
  let size = d.len - pos
  if size >= RiffHeaderSize and tagIs(d, pos, "RIFF"):
    if not tagIs(d, pos + 8, "WEBP"): return vsBitstreamError
    let riff = le32(d, pos + TagSize)
    if riff < TagSize + ChunkHeaderSize or riff > MaxChunkPayload: return vsBitstreamError
    if haveAllData and riff > size - ChunkHeaderSize: return vsNotEnoughData
    riffSize = riff
    pos += RiffHeaderSize
  vsOk

func parseVp8x(d: openArray[byte], pos: var int, found: var bool, width, height: var int,
               flags: var uint32): Vp8Status =
  ## Validates the VP8X chunk and skips it.
  found = false
  let size = d.len - pos
  if size < ChunkHeaderSize: return vsNotEnoughData
  if tagIs(d, pos, "VP8X"):
    if le32(d, pos + TagSize) != Vp8xChunkSize: return vsBitstreamError
    if size < ChunkHeaderSize + Vp8xChunkSize: return vsNotEnoughData
    flags = uint32(le32(d, pos + 8))
    width = 1 + le24(d, pos + 12)
    height = 1 + le24(d, pos + 15)
    if width * height >= MaxImageArea: return vsBitstreamError   # image is too large
    pos += ChunkHeaderSize + Vp8xChunkSize
    found = true
  vsOk

func parseOptionalChunks(d: openArray[byte], pos: var int, riffSize: int,
                         h: var WebpHeaders): Vp8Status =
  ## Skips the chunks between VP8X and the VP8/VP8L chunk, remembering the `ALPH` one.
  var buf = pos
  var total = uint32(TagSize + ChunkHeaderSize + Vp8xChunkSize)
  while true:
    pos = buf
    let bufSize = d.len - buf
    if bufSize < ChunkHeaderSize: return vsNotEnoughData
    let chunkSize = le32(d, buf + TagSize)
    if chunkSize > MaxChunkPayload: return vsBitstreamError
    let diskSize = (ChunkHeaderSize + chunkSize + 1) and not 1   # odd payloads are padded
    total += uint32(diskSize)                                    # uint32 arithmetic, wraps
    if riffSize > 0 and int(total) > riffSize: return vsBitstreamError
    # a (possibly incomplete) VP8/VP8L chunk ends the optional chunks
    if tagIs(d, buf, "VP8 ") or tagIs(d, buf, "VP8L"): return vsOk
    if bufSize < diskSize: return vsNotEnoughData
    if tagIs(d, buf, "ALPH"):
      h.hasAlphaChunk = true
      h.alphaOffset = buf + ChunkHeaderSize
      h.alphaSize = chunkSize
    buf += diskSize

func parseVp8Header(d: openArray[byte], pos: var int, haveAllData: bool, riffSize: int,
                    chunkSize: var int, isLossless: var bool): Vp8Status =
  ## Validates the "VP8 nnnn" / "VP8Lnnnn" header and skips it; raw bitstreams are detected
  ## by their signature.
  let size = d.len - pos
  if size < ChunkHeaderSize: return vsNotEnoughData
  let isVp8 = tagIs(d, pos, "VP8 ")
  let isVp8l = tagIs(d, pos, "VP8L")
  if isVp8 or isVp8l:
    let sz = le32(d, pos + TagSize)
    if riffSize >= TagSize + ChunkHeaderSize and sz > riffSize - (TagSize + ChunkHeaderSize):
      return vsBitstreamError                       # inconsistent size information
    if haveAllData and sz > size - ChunkHeaderSize: return vsNotEnoughData
    chunkSize = sz
    pos += ChunkHeaderSize
    isLossless = isVp8l
  else:
    isLossless = checkSignatureLossless(d, pos)
    chunkSize = size
  vsOk

func parseInternal(d: openArray[byte], wantHeaders: bool, f: var WebpFeatures,
                   h: var WebpHeaders): Vp8Status =
  ## `ParseHeadersInternal`; `wantHeaders` is `headers != NULL` (which also implies
  ## `have_all_data`, as in `DecodeInto`).
  f = WebpFeatures()
  h = WebpHeaders()
  if d.len < RiffHeaderSize: return vsNotEnoughData
  var pos = 0
  var canvasW, canvasH, imageW, imageH = 0
  var flags = 0'u32
  var foundVp8x = false
  var status = parseRiff(d, pos, wantHeaders, h.riffSize)
  if status != vsOk: return status
  let foundRiff = h.riffSize > 0
  status = parseVp8x(d, pos, foundVp8x, canvasW, canvasH, flags)
  if status != vsOk: return status
  let animation = (flags and AnimationFlag) != 0
  let fragments = (flags and FragmentsFlag) != 0
  if not foundRiff and foundVp8x: return vsBitstreamError
  f.hasAlpha = (flags and AlphaFlag) != 0
  f.hasAnimation = animation
  imageW = canvasW
  imageH = canvasH
  block parse:
    if foundVp8x and (animation or fragments) and not wantHeaders:
      status = vsOk
      break parse                      # just return the features of the VP8X header
    if d.len - pos < TagSize:
      status = vsNotEnoughData
      break parse
    if (foundRiff and foundVp8x) or (not foundRiff and not foundVp8x and tagIs(d, pos, "ALPH")):
      status = parseOptionalChunks(d, pos, h.riffSize, h)
      if status != vsOk: break parse
    status = parseVp8Header(d, pos, wantHeaders, h.riffSize, h.compressedSize, h.isLossless)
    if status != vsOk: break parse
    if h.compressedSize > MaxChunkPayload: return vsBitstreamError
    if not (animation or fragments): f.format = if h.isLossless: 2 else: 1
    if not h.isLossless:
      if d.len - pos < Vp8FrameHeaderSize:
        status = vsNotEnoughData
        break parse
      if not vp8GetInfo(d.toOpenArray(pos, d.high), h.compressedSize and 0xFFFFFFFF,
                        imageW, imageH):
        return vsBitstreamError
    else:
      if d.len - pos < Vp8lFrameHeaderSize:
        status = vsNotEnoughData
        break parse
      if not vp8lGetInfo(d.toOpenArray(pos, d.high), imageW, imageH, f.hasAlpha):
        return vsBitstreamError
    if foundVp8x and (canvasW != imageW or canvasH != imageH): return vsBitstreamError
    if wantHeaders:
      h.offset = pos
      h.width = imageW
      h.height = imageH
  if status == vsOk or (status == vsNotEnoughData and foundVp8x and not wantHeaders):
    f.hasAlpha = f.hasAlpha or h.hasAlphaChunk   # alpha may only be known from an ALPH chunk
    f.width = imageW
    f.height = imageH
    return vsOk
  status

func getFeatures*(data: openArray[byte], features: var WebpFeatures): Vp8Status =
  ## `WebPGetFeatures`: parses just enough of `data` (which may be truncated) to report the
  ## size, alpha and animation flags and the format.
  var h: WebpHeaders
  parseInternal(data, false, features, h)

func parseHeaders*(data: openArray[byte], headers: var WebpHeaders): Vp8Status =
  ## `WebPParseHeaders` with `have_all_data = 1`: locates the VP8/VP8L payload (`offset`) and
  ## the alpha chunk. Animated files give `vsUnsupportedFeature`.
  var f: WebpFeatures
  result = parseInternal(data, true, f, headers)
  if (result == vsOk or result == vsNotEnoughData) and f.hasAnimation:
    result = vsUnsupportedFeature
