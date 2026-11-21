## JPEG decoder state, input buffer, bit reader and Huffman tables.
##
## Port of the first half of `tvgJpgd.cpp` (Rich Geldreich's jpgd, public domain). The
## 8 KiB input buffer, the 0xFF/0xD9 padding at end of stream and the "stuff char" logic
## are reproduced literally so truncated or corrupt files behave exactly like upstream.
## A decode error is a flag (`failed`); upstream collapses every error to JPGD_FAILED.

const
  InBufSize* = 8192
  InBufPad* = 128
  MaxHuffTables* = 8
  MaxQuantTables* = 4
  MaxComponents* = 4
  MaxBlocksPerMcu* = 10
  MaxBlocksPerRow* = 8192
  MaxHeight* = 16384
  MaxWidth* = 16384

type
  HuffTable* = object
    lookUp*, lookUp2*: array[256, int]
    codeSize*: array[256, uint8]
    tree*: array[512, int]

  CoeffBuf* = object
    data*: seq[int16]
    blockNumX*, blockSize*: int

  ScanType* = enum
    Grayscale, Yh1v1, Yh2v1, Yh1v2, Yh2v2

  JpegDecoder* = ref object
    src*: string
    srcOfs*: int
    failed*, ready*, progressive*: bool
    imageX*, imageY*: int
    huffNum*, huffVal*: array[MaxHuffTables, seq[uint8]]  ## empty = table absent
    quant*: array[MaxQuantTables, seq[int16]]             ## empty = table absent
    scanType*: ScanType
    compsInFrame*, compsInScan*: int
    compHSamp*, compVSamp*, compQuant*, compIdent*: array[MaxComponents, int]
    compHBlocks*, compVBlocks*, compList*, compDcTab*, compAcTab*: array[MaxComponents, int]
    spectralStart*, spectralEnd*, successiveLow*, successiveHigh*: int
    maxMcuX*, maxMcuY*, blocksPerMcu*, maxBlocksPerRow*, mcusPerRow*, mcusPerCol*: int
    mcuOrg*: array[MaxBlocksPerMcu, int]
    totalLinesLeft*, mcuLinesLeft*, eobRun*: int
    huffTabs*: array[MaxHuffTables, HuffTable]
    huffBuilt*: array[MaxHuffTables, bool]
    dcCoeffs*, acCoeffs*: array[MaxComponents, CoeffBuf]
    blockYMcu*: array[MaxComponents, int]
    inBuf*: seq[uint8]
    inOfs*, inLeft*, temFlag*: int
    eofFlag*: bool
    bitsLeft*: int
    bitBuf*: uint32
    restartInterval*, restartsLeft*, nextRestartNum*: int
    maxMcusPerRow*, maxBlocksPerMcu*, maxMcusPerCol*: int
    lastDcVal*: array[MaxComponents, int]
    mcuCoeffs*: seq[int16]
    mcuBlockMaxZag*: array[MaxBlocksPerMcu, int]
    sampleBuf*: seq[uint8]
    crr*, cbb*, crg*, cbg*: array[256, int]
    scanLine0*, scanLine1*: seq[uint8]

const
  ExtendTest = [0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]

func wrap16*(x: int): int16 =
  ## C `static_cast<int16_t>`: keeps the low 16 bits.
  int16(((x and 0xFFFF) xor 0x8000) - 0x8000)

func huffExtend*(x, s: int): int =
  ## JPGD_HUFF_EXTEND: sign-extends a DPCM difference of category `s`.
  let n = s and 15
  if x < ExtendTest[n]: x + ((-1 shl n) + 1) else: x

func shamt(n: int): uint32 = uint32(n and 31)

proc stopDecoding*(d: JpegDecoder): bool =
  ## Marks the decoder failed; always returns false (like `stop_decoding`).
  d.failed = true
  d.eofFlag = true
  false

proc prepInBuffer*(d: JpegDecoder): bool =
  d.inLeft = 0
  d.inOfs = InBufPad
  if not d.eofFlag:
    var more = true
    while more:
      let remaining = d.src.len - d.srcOfs
      var n = InBufSize - d.inLeft
      d.eofFlag = false
      if n > remaining:
        n = remaining
        d.eofFlag = true
      for i in 0 ..< n: d.inBuf[d.inOfs + d.inLeft + i] = uint8(d.src[d.srcOfs + i])
      d.srcOfs += n
      d.inLeft += n
      more = d.inLeft < InBufSize and not d.eofFlag
    for i in 0 ..< 64:
      d.inBuf[d.inOfs + d.inLeft + 2 * i] = 0xFF'u8
      d.inBuf[d.inOfs + d.inLeft + 2 * i + 1] = 0xD9'u8
  true

proc getChar*(d: JpegDecoder, padding: var bool): uint32 =
  ## Next input byte; past the end of the stream it yields 0xFF, 0xD9, 0xFF, ...
  padding = false
  var done = false
  if d.inLeft == 0:
    if not d.prepInBuffer():
      result = 0xFF
      done = true
    elif d.inLeft == 0:
      padding = true
      let t = d.temFlag
      d.temFlag = d.temFlag xor 1
      result = if t != 0: 0xD9 else: 0xFF
      done = true
  if not done:
    result = uint32(d.inBuf[d.inOfs])
    inc d.inOfs
    dec d.inLeft

proc getChar*(d: JpegDecoder): uint32 =
  var padding = false
  d.getChar(padding)

proc stuffChar*(d: JpegDecoder, q: uint8) =
  dec d.inOfs
  d.inBuf[d.inOfs] = q
  inc d.inLeft

proc getOctet*(d: JpegDecoder): uint8 =
  ## Like `getChar` but never reads past a marker: returns 0xFF forever instead.
  var padding = false
  var c = d.getChar(padding)
  result = uint8(c)
  if c == 0xFF:
    result = 0xFF
    if not padding:
      c = d.getChar(padding)
      if padding:
        d.stuffChar(0xFF)
      elif c != 0:
        d.stuffChar(uint8(c))
        d.stuffChar(0xFF)

proc getBits*(d: JpegDecoder, numBits: int): uint32 =
  if numBits != 0:
    var n = numBits
    result = d.bitBuf shr shamt(32 - n)
    d.bitsLeft -= n
    if d.bitsLeft <= 0:
      n += d.bitsLeft
      d.bitBuf = d.bitBuf shl shamt(n)
      let c1 = d.getChar()
      let c2 = d.getChar()
      d.bitBuf = (d.bitBuf and 0xFFFF0000'u32) or (c1 shl 8) or c2
      d.bitBuf = d.bitBuf shl shamt(-d.bitsLeft)
      d.bitsLeft += 16
    else:
      d.bitBuf = d.bitBuf shl shamt(n)

proc getBitsNoMarkers*(d: JpegDecoder, numBits: int): uint32 =
  ## Markers are never loaded into the bit buffer: 1-bits are returned instead.
  if numBits != 0:
    var n = numBits
    result = d.bitBuf shr shamt(32 - n)
    d.bitsLeft -= n
    if d.bitsLeft <= 0:
      n += d.bitsLeft
      d.bitBuf = d.bitBuf shl shamt(n)
      if d.inLeft < 2 or d.inBuf[d.inOfs] == 0xFF or d.inBuf[d.inOfs + 1] == 0xFF:
        let c1 = uint32(d.getOctet())
        let c2 = uint32(d.getOctet())
        d.bitBuf = d.bitBuf or (c1 shl 8) or c2
      else:
        d.bitBuf = d.bitBuf or (uint32(d.inBuf[d.inOfs]) shl 8) or uint32(d.inBuf[d.inOfs + 1])
        d.inLeft -= 2
        d.inOfs += 2
      d.bitBuf = d.bitBuf shl shamt(-d.bitsLeft)
      d.bitsLeft += 16
    else:
      d.bitBuf = d.bitBuf shl shamt(n)

proc walkTree(d: JpegDecoder, h: HuffTable, first: int): (int, int) =
  ## Follows the code tree below the 8-bit lookup; returns (symbol, ofs).
  var symbol = first
  var ofs = 23
  while symbol < 0:
    symbol = h.tree[-(symbol + int((d.bitBuf shr shamt(ofs)) and 1))]
    dec ofs
  (symbol, ofs)

proc huffDecode*(d: JpegDecoder, h: HuffTable): int =
  result = h.lookUp[int(d.bitBuf shr 24)]
  if result < 0:
    let (symbol, ofs) = d.walkTree(h, result)
    result = symbol
    discard d.getBitsNoMarkers(8 + (23 - ofs))
  else:
    discard d.getBitsNoMarkers(int(h.codeSize[result]))

proc huffDecode*(d: JpegDecoder, h: HuffTable, extraBits: var int): int =
  ## Decodes a symbol and its `symbol & 15` extra bits.
  result = h.lookUp2[int(d.bitBuf shr 24)]
  if result < 0:
    let (symbol, ofs) = d.walkTree(h, result)
    result = symbol
    discard d.getBitsNoMarkers(8 + (23 - ofs))
    extraBits = int(d.getBitsNoMarkers(result and 0xF))
  else:
    if (result and 0x8000) != 0:
      discard d.getBitsNoMarkers((result shr 8) and 31)
      extraBits = result shr 16
    else:
      let codeSize = (result shr 8) and 31
      let numExtra = result and 0xF
      let bits = codeSize + numExtra
      if bits <= d.bitsLeft + 16:
        extraBits = int(d.getBitsNoMarkers(bits)) and ((1 shl numExtra) - 1)
      else:
        discard d.getBitsNoMarkers(codeSize)
        extraBits = int(d.getBitsNoMarkers(numExtra))
    result = result and 0xFF

proc makeHuffTable*(d: JpegDecoder, index: int) =
  ## Builds the lookup/tree tables of table `index` from its DHT counts and values.
  var huffSize: array[258, int]
  var huffCode: array[258, int]
  var p = 0
  for l in 1 .. 16:
    for _ in 1 .. int(d.huffNum[index][l]):
      huffSize[p] = l
      inc p
  huffSize[p] = 0
  let lastp = p
  var code = 0
  var si = huffSize[0]
  p = 0
  while huffSize[p] != 0:
    while huffSize[p] == si:
      huffCode[p] = code
      inc p
      inc code
    code = code shl 1
    inc si
  d.huffTabs[index] = HuffTable()
  d.huffBuilt[index] = true
  template h: untyped = d.huffTabs[index]
  var nextFree = -1
  p = 0
  while p < lastp:
    let i = int(d.huffVal[index][p])
    code = huffCode[p]
    let codeSize = huffSize[p]
    h.codeSize[i] = uint8(codeSize)
    if codeSize <= 8:
      code = code shl (8 - codeSize)
      for _ in 1 .. (1 shl (8 - codeSize)):
        h.lookUp[code] = i
        var hasExtra = false
        var extraBits = 0
        let numExtra = i and 15
        var bitsToFetch = codeSize
        if numExtra != 0 and codeSize + numExtra <= 8:
          hasExtra = true
          extraBits = ((1 shl numExtra) - 1) and (code shr (8 - codeSize - numExtra))
          bitsToFetch += numExtra
        if hasExtra: h.lookUp2[code] = i or 0x8000 or (extraBits shl 16) or (bitsToFetch shl 8)
        else: h.lookUp2[code] = i or (bitsToFetch shl 8)
        inc code
    else:
      let subtree = (code shr (codeSize - 8)) and 0xFF
      var cur = h.lookUp[subtree]
      if cur == 0:
        cur = nextFree
        h.lookUp[subtree] = cur
        h.lookUp2[subtree] = cur
        nextFree -= 2
      code = code shl (16 - (codeSize - 8))
      for _ in 1 .. codeSize - 9:
        if (code and 0x8000) == 0: dec cur
        if h.tree[-cur - 1] == 0:
          h.tree[-cur - 1] = nextFree
          cur = nextFree
          nextFree -= 2
        else:
          cur = h.tree[-cur - 1]
        code = code shl 1
      if (code and 0x8000) == 0: dec cur
      h.tree[-cur - 1] = i
    inc p
