## VP8L bit reader (the lossless part of utils/bit_reader.cpp/.h).
##
## Ported literally from libwebp's `VP8LBitReader`: a 64-bit prefetch window that is
## refilled 32 bits at a time (`fillBitWindow`) or byte by byte near the end of the
## buffer. The end-of-stream flag `eos` follows the exact upstream rules because the
## decoder accepts or rejects truncated streams based on it.
## The reader owns a copy of the input bytes (no pointers).

const
  MaxNumBitRead = 24   ## VP8L_MAX_NUM_BIT_READ
  LBits = 64           ## VP8L_LBITS
  WBits = 32           ## VP8L_WBITS

type
  Vp8lBitReader* = object
    val*: uint64        ## pre-fetched bits
    buf: seq[byte]
    pos: int            ## byte position in buf
    bitPos*: int        ## current bit-reading position in val
    eos*: bool          ## true if a bit was read past the end of the buffer

func initBitReader*(data: openArray[byte]): Vp8lBitReader =
  ## `VP8LInitBitReader`.
  result = Vp8lBitReader(buf: @data)
  let n = min(data.len, 8)
  for i in 0 ..< n:
    result.val = result.val or (uint64(data[i]) shl (8 * i))
  result.pos = n

func isEndOfStream*(br: Vp8lBitReader): bool {.inline.} =
  br.eos or (br.pos == br.buf.len and br.bitPos > LBits)

func setBitPos*(br: var Vp8lBitReader, v: int) {.inline.} =
  br.bitPos = v
  br.eos = br.isEndOfStream

func prefetchBits*(br: Vp8lBitReader): uint32 {.inline.} =
  uint32((br.val shr (br.bitPos and (LBits - 1))) and 0xFFFFFFFF'u64)

func setEndOfStream(br: var Vp8lBitReader) =
  br.eos = true
  br.bitPos = 0   # avoids undefined shifts

func shiftBytes(br: var Vp8lBitReader) =
  ## Reloads up to 64 bits byte by byte when not at the end of the stream.
  while br.bitPos >= 8 and br.pos < br.buf.len:
    br.val = br.val shr 8
    br.val = br.val or (uint64(br.buf[br.pos]) shl (LBits - 8))
    inc br.pos
    br.bitPos -= 8
  if br.isEndOfStream:
    br.setEndOfStream()

func doFillBitWindow(br: var Vp8lBitReader) =
  if br.pos + 8 < br.buf.len:
    br.val = br.val shr WBits
    br.bitPos -= WBits
    let w = uint64(br.buf[br.pos]) or (uint64(br.buf[br.pos + 1]) shl 8) or
      (uint64(br.buf[br.pos + 2]) shl 16) or (uint64(br.buf[br.pos + 3]) shl 24)
    br.val = br.val or (w shl (LBits - WBits))
    br.pos += 4
  else:
    br.shiftBytes()

func fillBitWindow*(br: var Vp8lBitReader) {.inline.} =
  if br.bitPos >= WBits: br.doFillBitWindow()

func readBits*(br: var Vp8lBitReader, nBits: int): uint32 =
  ## `VP8LReadBits`: flags `eos` when `nBits` > 24 or the stream is exhausted.
  if not br.eos and nBits <= MaxNumBitRead:
    result = br.prefetchBits() and uint32((1'u64 shl nBits) - 1)
    br.bitPos += nBits
    br.shiftBytes()
  else:
    br.setEndOfStream()
    result = 0
