## JPEG decoder (baseline, extended sequential and progressive Huffman), port of jpgd.
##
## `tvgJpgd.cpp` of ThorVG (Rich Geldreich's public domain jpgd). Grayscale and YCbCr
## 4:4:4 / 4:2:2 (2x1) / 4:4:0 (1x2) / 4:2:0 images, 8-bit precision, restart intervals.
## No arithmetic coding, no CMYK. Output is bit-identical to the C++ decoder: integer
## IDCT, replicated chroma, jpgd's YCbCr -> RGB tables. See `jpgd_bits` for the input
## model and `jpgd_markers` for the marker parser.
##
## Use: `jpgdHeader(data)` (nil when the header is invalid, then `imageX`/`imageY` give the
## size) and `jpgdDecompress(d)` -> words `R | G << 8 | B << 16 | 0xFF << 24`
## (`ColorSpace.XBGR8888`), empty on failure.

import ./[jpgd_bits, jpgd_markers, jpgd_idct, jpgd_prog]

const
  StatusDone = 1
  StatusFailed = -1

proc newDecoder(data: string): JpegDecoder =
  result = JpegDecoder(src: data, inBuf: newSeq[uint8](InBufPad + InBufSize + 128 + InBufPad))
  for i in 0 ..< MaxBlocksPerMcu: result.mcuBlockMaxZag[i] = 64
  discard result.prepInBuffer()
  result.bitsLeft = 16
  result.bitBuf = 0
  discard result.getBits(16)
  discard result.getBits(16)

proc coeffBufOpen(nx, ny, blockLen: int): CoeffBuf =
  CoeffBuf(data: newSeq[int16](blockLen * nx * ny), blockNumX: nx, blockSize: blockLen)

proc transformMcu(d: JpegDecoder, mcuRow: int) =
  var dst = mcuRow * d.blocksPerMcu * 64
  for b in 0 ..< d.blocksPerMcu:
    idct(d.mcuCoeffs, b * 64, d.sampleBuf, dst)
    dst += 64

proc processRestart(d: JpegDecoder): bool =
  var i = 1536
  var c = 0'u32
  while i > 0:
    if d.getChar() == 0xFF: break
    dec i
  if i == 0: return d.stopDecoding()
  while i > 0:
    c = d.getChar()
    if c != 0xFF: break
    dec i
  if i == 0: return d.stopDecoding()
  if int(c) != d.nextRestartNum + 0xD0: return d.stopDecoding()
  for k in 0 ..< d.compsInFrame: d.lastDcVal[k] = 0
  d.eobRun = 0
  d.restartsLeft = d.restartInterval
  d.nextRestartNum = (d.nextRestartNum + 1) and 7
  d.bitsLeft = 16
  discard d.getBitsNoMarkers(16)
  discard d.getBitsNoMarkers(16)
  true

proc loadNextRow(d: JpegDecoder): bool =
  ## Progressive: dequantises the next MCU row of the stored coefficients.
  var blockXMcu: array[MaxComponents, int]
  for mcuRow in 0 ..< d.mcusPerRow:
    var xOfs = 0
    var yOfs = 0
    for mcuBlock in 0 ..< d.blocksPerMcu:
      let comp = d.mcuOrg[mcuBlock]
      let qi = d.compQuant[comp]
      if qi >= MaxQuantTables or d.quant[qi].len == 0: return d.stopDecoding()
      let base = 64 * mcuBlock
      let bx = blockXMcu[comp] + xOfs
      let by = d.blockYMcu[comp] + yOfs
      let pAc = coeffGetp(d.acCoeffs[comp], bx, by)
      let pDc = coeffGetp(d.dcCoeffs[comp], bx, by)
      d.mcuCoeffs[base] = d.dcCoeffs[comp].data[pDc]
      for j in 1 ..< 64: d.mcuCoeffs[base + j] = d.acCoeffs[comp].data[pAc + j]
      var i = 63
      while i > 0 and d.mcuCoeffs[base + Zag[i]] == 0: dec i
      d.mcuBlockMaxZag[mcuBlock] = i + 1
      while i >= 0:
        let at = base + Zag[i]
        if d.mcuCoeffs[at] != 0:
          d.mcuCoeffs[at] = wrap16(int(d.mcuCoeffs[at]) * int(d.quant[qi][i]))
        dec i
      if d.compsInScan == 1:
        inc blockXMcu[comp]
      else:
        inc xOfs
        if xOfs == d.compHSamp[comp]:
          xOfs = 0
          inc yOfs
          if yOfs == d.compVSamp[comp]:
            yOfs = 0
            blockXMcu[comp] += d.compHSamp[comp]
    d.transformMcu(mcuRow)
  if d.compsInScan == 1:
    inc d.blockYMcu[d.compList[0]]
  else:
    for n in 0 ..< d.compsInScan:
      let comp = d.compList[n]
      d.blockYMcu[comp] += d.compVSamp[comp]
  true

proc zeroRun(d: JpegDecoder, base, k, count: int) =
  for kt in k ..< k + count: d.mcuCoeffs[base + Zag[kt]] = 0

proc decodeNextRow(d: JpegDecoder): bool =
  ## Sequential: Huffman-decodes and dequantises the next MCU row.
  for mcuRow in 0 ..< d.mcusPerRow:
    if d.restartInterval != 0 and d.restartsLeft == 0:
      if not d.processRestart(): return false
    for mcuBlock in 0 ..< d.blocksPerMcu:
      let comp = d.mcuOrg[mcuBlock]
      let qi = d.compQuant[comp]
      let dcTab = d.compDcTab[comp]
      let acTab = d.compAcTab[comp]
      if qi >= MaxQuantTables or d.quant[qi].len == 0: return d.stopDecoding()
      if not d.tableOk(dcTab) or not d.tableOk(acTab): return d.stopDecoding()
      let base = 64 * mcuBlock
      var r = 0
      var s = d.huffDecode(d.huffTabs[dcTab], r)
      s = huffExtend(r, s) + d.lastDcVal[comp]
      d.lastDcVal[comp] = s
      d.mcuCoeffs[base] = wrap16(s * int(d.quant[qi][0]))
      let prevNumSet = d.mcuBlockMaxZag[mcuBlock]
      var k = 1
      while k < 64:
        var extraBits = 0
        s = d.huffDecode(d.huffTabs[acTab], extraBits)
        r = s shr 4
        s = s and 15
        if s != 0:
          if r != 0:
            if k + r > 63: return d.stopDecoding()
            if k < prevNumSet: d.zeroRun(base, k, min(r, prevNumSet - k))
            k += r
          s = huffExtend(extraBits, s)
          d.mcuCoeffs[base + Zag[k]] = wrap16(s * int(d.quant[qi][k]))
        elif r == 15:
          if k + 16 > 64: return d.stopDecoding()
          if k < prevNumSet: d.zeroRun(base, k, min(16, prevNumSet - k))
          k += 16 - 1
        else:
          break
        inc k
      if k < prevNumSet: d.zeroRun(base, k, prevNumSet - k)
      d.mcuBlockMaxZag[mcuBlock] = k
    d.transformMcu(mcuRow)
    dec d.restartsLeft
  true

proc decodeScan(d: JpegDecoder, kind: BlockKind): bool =
  var blockYMcu: array[MaxComponents, int]
  for _ in 0 ..< d.mcusPerCol:
    var blockXMcu: array[MaxComponents, int]
    for _ in 0 ..< d.mcusPerRow:
      var xOfs = 0
      var yOfs = 0
      if d.restartInterval != 0 and d.restartsLeft == 0:
        if not d.processRestart(): return false
      for mcuBlock in 0 ..< d.blocksPerMcu:
        let comp = d.mcuOrg[mcuBlock]
        if not d.decodeBlock(kind, comp, blockXMcu[comp] + xOfs, blockYMcu[comp] + yOfs):
          return false
        if d.compsInScan == 1:
          inc blockXMcu[comp]
        else:
          inc xOfs
          if xOfs == d.compHSamp[comp]:
            xOfs = 0
            inc yOfs
            if yOfs == d.compVSamp[comp]:
              yOfs = 0
              blockXMcu[comp] += d.compHSamp[comp]
      dec d.restartsLeft
    if d.compsInScan == 1:
      inc blockYMcu[d.compList[0]]
    else:
      for n in 0 ..< d.compsInScan:
        let comp = d.compList[n]
        blockYMcu[comp] += d.compVSamp[comp]
  true

proc calcMcuBlockOrder(d: JpegDecoder) =
  var maxH = 0
  var maxV = 0
  for c in 0 ..< d.compsInFrame:
    maxH = max(maxH, d.compHSamp[c])
    maxV = max(maxV, d.compVSamp[c])
  for c in 0 ..< d.compsInFrame:
    d.compHBlocks[c] = ((((d.imageX * d.compHSamp[c]) + (maxH - 1)) div maxH) + 7) div 8
    d.compVBlocks[c] = ((((d.imageY * d.compVSamp[c]) + (maxV - 1)) div maxV) + 7) div 8
  if d.compsInScan == 1:
    d.mcusPerRow = d.compHBlocks[d.compList[0]]
    d.mcusPerCol = d.compVBlocks[d.compList[0]]
    d.mcuOrg[0] = d.compList[0]
    d.blocksPerMcu = 1
  else:
    d.mcusPerRow = (((d.imageX + 7) div 8) + (maxH - 1)) div maxH
    d.mcusPerCol = (((d.imageY + 7) div 8) + (maxV - 1)) div maxV
    d.blocksPerMcu = 0
    for n in 0 ..< d.compsInScan:
      let comp = d.compList[n]
      for _ in 0 ..< d.compHSamp[comp] * d.compVSamp[comp]:
        d.mcuOrg[d.blocksPerMcu] = comp
        inc d.blocksPerMcu

proc initScan(d: JpegDecoder): bool =
  if not d.locateSosMarker(): return false
  d.calcMcuBlockOrder()
  for i in 0 ..< d.compsInScan:
    let comp = d.compList[i]
    if (d.spectralStart == 0 and d.huffNum[d.compDcTab[comp]].len == 0) or
        (d.spectralEnd > 0 and d.huffNum[d.compAcTab[comp]].len == 0):
      discard d.stopDecoding()
  for i in 0 ..< MaxHuffTables:
    if d.huffNum[i].len != 0 and not d.failed: d.makeHuffTable(i)
  for i in 0 ..< d.compsInScan:
    let qi = d.compQuant[d.compList[i]]
    if qi >= MaxQuantTables or d.quant[qi].len == 0: return d.stopDecoding()
  for k in 0 ..< d.compsInFrame: d.lastDcVal[k] = 0
  d.eobRun = 0
  if d.restartInterval != 0:
    d.restartsLeft = d.restartInterval
    d.nextRestartNum = 0
  if d.bitsLeft == 16: d.stuffChar(uint8(d.bitBuf and 0xFF))
  if d.bitsLeft >= 8: d.stuffChar(uint8((d.bitBuf shr 8) and 0xFF))
  d.stuffChar(uint8((d.bitBuf shr 16) and 0xFF))
  d.stuffChar(uint8((d.bitBuf shr 24) and 0xFF))
  d.bitsLeft = 16
  discard d.getBitsNoMarkers(16)
  discard d.getBitsNoMarkers(16)
  true

proc initFrame(d: JpegDecoder): bool =
  let h = d.compHSamp
  let v = d.compVSamp
  var blocks = 0
  if d.compsInFrame == 1:
    if h[0] != 1 or v[0] != 1: return d.stopDecoding()
    d.scanType = Grayscale
    blocks = 1
    d.maxMcuX = 8
    d.maxMcuY = 8
  elif d.compsInFrame == 3:
    if h[1] != 1 or v[1] != 1 or h[2] != 1 or v[2] != 1: return d.stopDecoding()
    if h[0] == 1 and v[0] == 1: (d.scanType, blocks, d.maxMcuX, d.maxMcuY) = (Yh1v1, 3, 8, 8)
    elif h[0] == 2 and v[0] == 1: (d.scanType, blocks, d.maxMcuX, d.maxMcuY) = (Yh2v1, 4, 16, 8)
    elif h[0] == 1 and v[0] == 2: (d.scanType, blocks, d.maxMcuX, d.maxMcuY) = (Yh1v2, 4, 8, 16)
    elif h[0] == 2 and v[0] == 2: (d.scanType, blocks, d.maxMcuX, d.maxMcuY) = (Yh2v2, 6, 16, 16)
    else: return d.stopDecoding()
  else:
    return d.stopDecoding()
  d.maxBlocksPerMcu = blocks
  d.maxMcusPerRow = (d.imageX + (d.maxMcuX - 1)) div d.maxMcuX
  d.maxMcusPerCol = (d.imageY + (d.maxMcuY - 1)) div d.maxMcuY
  if d.scanType != Grayscale:
    let lineSize = ((d.imageX + 15) and 0xFFF0) * 4
    d.scanLine0 = newSeq[uint8](lineSize)
    if d.scanType in {Yh1v2, Yh2v2}: d.scanLine1 = newSeq[uint8](lineSize)
  d.maxBlocksPerRow = d.maxMcusPerRow * d.maxBlocksPerMcu
  if d.maxBlocksPerRow > MaxBlocksPerRow: return d.stopDecoding()
  d.mcuCoeffs = newSeq[int16](d.maxBlocksPerMcu * 64)
  for i in 0 ..< d.maxBlocksPerMcu: d.mcuBlockMaxZag[i] = 64
  d.sampleBuf = newSeq[uint8](d.maxBlocksPerRow * 64)
  d.totalLinesLeft = d.imageY
  d.mcuLinesLeft = 0
  d.createLookUps()
  true

proc initProgressive(d: JpegDecoder): bool =
  for i in 0 ..< d.compsInFrame:
    let nx = d.maxMcusPerRow * d.compHSamp[i]
    let ny = d.maxMcusPerCol * d.compVSamp[i]
    d.dcCoeffs[i] = coeffBufOpen(nx, ny, 1)
    d.acCoeffs[i] = coeffBufOpen(nx, ny, 64)
  while d.initScan():
    let dcOnly = d.spectralStart == 0
    let refinement = d.successiveHigh != 0
    if d.spectralStart > d.spectralEnd or d.spectralEnd > 63: return d.stopDecoding()
    if dcOnly:
      if d.spectralEnd != 0: return d.stopDecoding()
    elif d.compsInScan != 1:
      return d.stopDecoding()
    if refinement and d.successiveLow != d.successiveHigh - 1: return d.stopDecoding()
    let kind = if dcOnly: (if refinement: DcRefine else: DcFirst)
               else: (if refinement: AcRefine else: AcFirst)
    if not d.decodeScan(kind): return false
    d.bitsLeft = 16
    discard d.getBits(16)
    discard d.getBits(16)
  d.compsInScan = d.compsInFrame
  for i in 0 ..< d.compsInFrame: d.compList[i] = i
  d.calcMcuBlockOrder()
  true

proc beginDecoding(d: JpegDecoder): bool =
  if d.ready: return true
  if d.failed: return false
  if not d.initFrame(): return false
  if d.progressive:
    if not d.initProgressive(): return false
  elif not d.initScan():
    return d.stopDecoding()
  d.ready = true
  true

proc findEoi(d: JpegDecoder) =
  if not d.progressive:
    d.bitsLeft = 16
    discard d.getBits(16)
    discard d.getBits(16)
    discard d.processMarkers()

proc decodeRow(d: JpegDecoder, dst: var seq[uint8], dstOfs: int): int =
  ## Writes the next RGBA scan line at `dst[dstOfs ..]`; 0 = line written, 1 = done.
  if d.failed or not d.ready: return StatusFailed
  if d.totalLinesLeft == 0: return StatusDone
  if d.mcuLinesLeft == 0:
    if d.progressive:
      if not d.loadNextRow(): return StatusFailed
    elif not d.decodeNextRow():
      return StatusFailed
    if d.totalLinesLeft <= d.maxMcuY: d.findEoi()
    d.mcuLinesLeft = d.maxMcuY
  var second = false
  case d.scanType
  of Yh2v2, Yh1v2:
    if (d.mcuLinesLeft and 1) == 0: d.convertRow() else: second = true
  of Yh2v1, Yh1v1: d.convertRow()
  of Grayscale:
    let row = d.maxMcuY - d.mcuLinesLeft
    for x in 0 ..< d.imageX:
      let y = d.sampleBuf[row * 8 + (x shr 3) * 64 + (x and 7)]
      for c in 0 .. 2: dst[dstOfs + x * 4 + c] = y
      dst[dstOfs + x * 4 + 3] = 255'u8
  if d.scanType != Grayscale:
    let line = if second: d.scanLine1 else: d.scanLine0
    for i in 0 ..< d.imageX * 4: dst[dstOfs + i] = line[i]
  dec d.mcuLinesLeft
  dec d.totalLinesLeft
  0

proc jpgdHeader*(data: string): JpegDecoder =
  ## A decoder primed with the image header, or nil when the data is not a usable JPEG.
  let d = newDecoder(data)
  discard d.locateSofMarker()
  if d.failed: nil else: d

proc jpgdDecompress*(d: JpegDecoder): seq[uint32] =
  ## Decodes the whole image to `R | G << 8 | B << 16 | 0xFF << 24` words (empty on failure).
  if d == nil: return @[]
  try:
    if not d.beginDecoding(): return @[]
    let w = d.imageX
    var row = newSeq[uint8](w * 4)
    result = newSeq[uint32](w * d.imageY)
    for y in 0 ..< d.imageY:
      if d.decodeRow(row, 0) != 0: return @[]
      for x in 0 ..< w:
        result[y * w + x] = uint32(row[x * 4]) or (uint32(row[x * 4 + 1]) shl 8) or
          (uint32(row[x * 4 + 2]) shl 16) or (uint32(row[x * 4 + 3]) shl 24)
  except IndexDefect, RangeDefect, OverflowDefect:
    result = @[]
