## JPEG marker parsing: DHT, DQT, SOF, DRI, SOS, marker scanning and SOI/SOF/SOS lookup.
##
## Port of the marker half of `tvgJpgd.cpp`. Only baseline / extended-sequential (SOF0,
## SOF1) and progressive (SOF2) Huffman streams are accepted, like upstream.

import ./jpgd_bits

const
  MSof0 = 0xC0
  MSof1 = 0xC1
  MSof2 = 0xC2
  MDht = 0xC4
  MJpg = 0xC8
  MSof9 = 0xC9
  MDac = 0xCC
  MRst0 = 0xD0
  MRst7 = 0xD7
  MSoi = 0xD8
  MEoi = 0xD9
  MSos = 0xDA
  MDqt = 0xDB
  MDri = 0xDD
  MTem = 0x01

proc readDhtMarker(d: JpegDecoder): bool =
  var numLeft = int(d.getBits(16))
  result = true
  if numLeft < 2:
    result = d.stopDecoding()
  else:
    numLeft -= 2
    while result and numLeft != 0:
      var index = int(d.getBits(8))
      var huffNum = newSeq[uint8](17)
      var count = 0
      for i in 1 .. 16:
        huffNum[i] = uint8(d.getBits(8))
        count += int(huffNum[i])
      if count > 255: return d.stopDecoding()
      var huffVal = newSeq[uint8](256)
      for i in 0 ..< count: huffVal[i] = uint8(d.getBits(8))
      let used = 1 + 16 + count
      if numLeft < used: return d.stopDecoding()
      numLeft -= used
      index = (index and 0x0F) + ((index and 0x10) shr 4) * (MaxHuffTables shr 1)
      if index >= MaxHuffTables: return d.stopDecoding()
      d.huffNum[index] = huffNum
      d.huffVal[index] = huffVal

proc readDqtMarker(d: JpegDecoder): bool =
  var numLeft = int(d.getBits(16))
  result = true
  if numLeft < 2:
    result = d.stopDecoding()
  else:
    numLeft -= 2
    while result and numLeft != 0:
      var n = int(d.getBits(8))
      let prec = n shr 4
      n = n and 0x0F
      if n >= MaxQuantTables: return d.stopDecoding()
      if d.quant[n].len == 0: d.quant[n] = newSeq[int16](64)
      for i in 0 ..< 64:
        var temp = int(d.getBits(8))
        if prec != 0: temp = (temp shl 8) + int(d.getBits(8))
        d.quant[n][i] = wrap16(temp)
      let used = if prec != 0: 64 + 1 + 64 else: 64 + 1
      if numLeft < used: return d.stopDecoding()
      numLeft -= used

proc readSofMarker(d: JpegDecoder): bool =
  let numLeft = int(d.getBits(16))
  if d.getBits(8) != 8: return d.stopDecoding()
  d.imageY = int(d.getBits(16))
  if d.imageY < 1 or d.imageY > MaxHeight: return d.stopDecoding()
  d.imageX = int(d.getBits(16))
  if d.imageX < 1 or d.imageX > MaxWidth: return d.stopDecoding()
  d.compsInFrame = int(d.getBits(8))
  if d.compsInFrame > MaxComponents: return d.stopDecoding()
  if numLeft != d.compsInFrame * 3 + 8: return d.stopDecoding()
  for i in 0 ..< d.compsInFrame:
    d.compIdent[i] = int(d.getBits(8))
    d.compHSamp[i] = int(d.getBits(4))
    d.compVSamp[i] = int(d.getBits(4))
    d.compQuant[i] = int(d.getBits(8))
  true

proc skipVariableMarker(d: JpegDecoder): bool =
  var numLeft = int(d.getBits(16))
  result = true
  if numLeft < 2:
    result = d.stopDecoding()
  else:
    numLeft -= 2
    while numLeft != 0:
      discard d.getBits(8)
      dec numLeft

proc readDriMarker(d: JpegDecoder): bool =
  if d.getBits(16) != 4: return d.stopDecoding()
  d.restartInterval = int(d.getBits(16))
  true

proc readSosMarker*(d: JpegDecoder): bool =
  var numLeft = int(d.getBits(16))
  let n = int(d.getBits(8))
  d.compsInScan = n
  numLeft -= 3
  if numLeft != n * 2 + 3 or n < 1 or n > MaxComponents: return d.stopDecoding()
  for i in 0 ..< n:
    let cc = int(d.getBits(8))
    let c = int(d.getBits(8))
    numLeft -= 2
    var ci = 0
    while ci < d.compsInFrame and cc != d.compIdent[ci]: inc ci
    if ci >= d.compsInFrame: return d.stopDecoding()
    for j in 0 ..< i:
      if d.compList[j] == ci: return d.stopDecoding()
    d.compList[i] = ci
    d.compDcTab[ci] = (c shr 4) and 15
    d.compAcTab[ci] = (c and 15) + (MaxHuffTables shr 1)
  d.spectralStart = int(d.getBits(8))
  d.spectralEnd = int(d.getBits(8))
  d.successiveHigh = int(d.getBits(4))
  d.successiveLow = int(d.getBits(4))
  if not d.progressive:
    d.spectralStart = 0
    d.spectralEnd = 63
  numLeft -= 3
  while numLeft != 0:
    discard d.getBits(8)
    dec numLeft
  true

proc nextMarker(d: JpegDecoder): int =
  var c = 0'u32
  while true:
    c = d.getBits(8)
    while c != 0xFF: c = d.getBits(8)
    c = d.getBits(8)
    while c == 0xFF: c = d.getBits(8)
    if c != 0: break
  int(c)

proc processMarkers*(d: JpegDecoder): int =
  ## Returns at an SOFx, SOI, EOI or SOS marker (EOI also after an error).
  var done = false
  while not done:
    let c = d.nextMarker()
    result = c
    case c
    of MSof0, MSof1, MSof2, 0xC3, 0xC5, 0xC6, 0xC7, MSof9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
        MSoi, MEoi, MSos:
      done = true
    of MDht:
      if not d.readDhtMarker(): result = MEoi; done = true
    of MDac:
      discard d.stopDecoding()
      result = MEoi
      done = true
    of MDqt:
      if not d.readDqtMarker(): result = MEoi; done = true
    of MDri:
      if not d.readDriMarker(): result = MEoi; done = true
    of MJpg, MRst0 .. MRst7, MTem:
      discard d.stopDecoding()
      result = MEoi
      done = true
    else:
      if not d.skipVariableMarker(): result = MEoi; done = true

proc locateSoiMarker(d: JpegDecoder): bool =
  var lastChar = d.getBits(8)
  var thisChar = d.getBits(8)
  if lastChar == 0xFF and thisChar == MSoi: return true
  var bytesLeft = 4096
  while true:
    dec bytesLeft
    if bytesLeft == 0: return d.stopDecoding()
    lastChar = thisChar
    thisChar = d.getBits(8)
    if lastChar == 0xFF:
      if thisChar == MSoi: break
      elif thisChar == MEoi: return d.stopDecoding()
  thisChar = (d.bitBuf shr 24) and 0xFF
  if thisChar != 0xFF: return d.stopDecoding()
  true

proc locateSofMarker*(d: JpegDecoder): bool =
  if not d.locateSoiMarker(): return false
  case d.processMarkers()
  of MSof2:
    d.progressive = true
    d.readSofMarker()
  of MSof0, MSof1: d.readSofMarker()
  else: d.stopDecoding()

proc locateSosMarker*(d: JpegDecoder): bool =
  let c = d.processMarkers()
  if c == MEoi: false
  elif c != MSos: d.stopDecoding()
  else: d.readSosMarker()
