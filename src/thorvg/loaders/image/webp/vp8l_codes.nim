## Reading the Huffman codes of a VP8L image stream (ReadHuffmanCodeLengths, ReadHuffmanCode
## and the group loop of ReadHuffmanCodes in dec/vp8l.cpp).
##
## The optional meta prefix image is decoded by the caller (`vp8l.nim`, it needs the full
## stream decoder); this module only reads the `numGroups` groups of five codes that follow.

import ./[vp8l_bits, huffman]

const
  NumLiteralCodes* = 256
  NumLengthCodes* = 24
  NumDistanceCodes = 40
  NumCodeLengthCodes = 19
  DefaultCodeLength = 8
  MaxCacheBits* = 11
  Green* = 0
  Red* = 1
  Blue* = 2
  Alpha* = 3
  Dist* = 4
  AlphabetSize = [NumLiteralCodes + NumLengthCodes, NumLiteralCodes, NumLiteralCodes,
                  NumLiteralCodes, NumDistanceCodes]
  LiteralMap = [false, true, true, true, false]
  CodeLengthCodeOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  CodeLengthExtraBits = [2, 3, 7]
  CodeLengthRepeatOffsets = [3, 3, 11]

func readHuffmanCodeLengths(br: var Vp8lBitReader, clcl: array[NumCodeLengthCodes, int],
                            numSymbols: int, lengths: var seq[int]): bool =
  var tables: HuffmanTables
  if buildHuffmanTable(tables, LengthsTableBits, clcl, NumCodeLengthCodes) == 0:
    return false
  var maxSymbol = numSymbols
  if br.readBits(1) != 0:   # use length
    let lengthNbits = 2 + 2 * int(br.readBits(3))
    maxSymbol = 2 + int(br.readBits(lengthNbits))
    if maxSymbol > numSymbols: return false
  var symbol = 0
  var prevCodeLen = DefaultCodeLength
  while symbol < numSymbols:
    let more = maxSymbol != 0
    dec maxSymbol
    if not more: break
    br.fillBitWindow()
    let p = tables[int(br.prefetchBits()) and LengthsTableMask]
    br.setBitPos(br.bitPos + int(p.bits))
    let codeLen = int(p.value)
    if codeLen < 16:
      lengths[symbol] = codeLen
      inc symbol
      if codeLen != 0: prevCodeLen = codeLen
    else:
      let slot = codeLen - 16
      var repeat = int(br.readBits(CodeLengthExtraBits[slot])) + CodeLengthRepeatOffsets[slot]
      if symbol + repeat > numSymbols: return false
      let length = if codeLen == 16: prevCodeLen else: 0
      while repeat > 0:
        lengths[symbol] = length
        inc symbol
        dec repeat
  true

func readHuffmanCode(br: var Vp8lBitReader, alphabetSize: int, lengths: var seq[int],
                     tables: var HuffmanTables): int =
  ## Returns the size of the table appended to `tables`, or 0 on error.
  let simpleCode = br.readBits(1) != 0
  for i in 0 ..< alphabetSize: lengths[i] = 0
  var ok = false
  if simpleCode:
    let numSymbols = int(br.readBits(1)) + 1
    let firstSymbolLenCode = br.readBits(1)
    var symbol = int(br.readBits(if firstSymbolLenCode == 0: 1 else: 8))
    lengths[symbol] = 1
    if numSymbols == 2:
      symbol = int(br.readBits(8))
      lengths[symbol] = 1
    ok = true
  else:
    var clcl: array[NumCodeLengthCodes, int]
    let numCodes = int(br.readBits(4)) + 4
    if numCodes > NumCodeLengthCodes: return 0
    for i in 0 ..< numCodes:
      clcl[CodeLengthCodeOrder[i]] = int(br.readBits(3))
    ok = readHuffmanCodeLengths(br, clcl, alphabetSize, lengths)
  ok = ok and not br.eos
  if not ok: return 0
  buildHuffmanTable(tables, HuffmanTableBits, lengths, alphabetSize)

func readHuffmanCodes*(br: var Vp8lBitReader, numGroups, cacheBits: int,
                       tables: var HuffmanTables, groups: var seq[HTreeGroup]): bool =
  ## Reads `numGroups` groups (green+length+cache, red, blue, alpha, distance).
  var maxAlphabetSize = 0
  for j in 0 ..< HuffmanCodesPerMetaCode:
    var size = AlphabetSize[j]
    if j == 0 and cacheBits > 0: size += 1 shl cacheBits
    maxAlphabetSize = max(maxAlphabetSize, size)
  var lengths = newSeq[int](maxAlphabetSize)
  groups = newSeq[HTreeGroup](numGroups)
  for i in 0 ..< numGroups:
    var trivial = true
    for j in 0 ..< HuffmanCodesPerMetaCode:
      var size = AlphabetSize[j]
      if j == 0 and cacheBits > 0: size += 1 shl cacheBits
      let start = tables.len
      if readHuffmanCode(br, size, lengths, tables) == 0: return false
      groups[i].htrees[j] = start
      if trivial and LiteralMap[j]:
        trivial = tables[start].bits == 0
    groups[i].isTrivialLiteral = trivial
    if trivial:
      let red = uint32(tables[groups[i].htrees[Red]].value)
      let blue = uint32(tables[groups[i].htrees[Blue]].value)
      let alpha = uint32(tables[groups[i].htrees[Alpha]].value)
      groups[i].literalArb = (alpha shl 24) or (red shl 16) or blue
  true
