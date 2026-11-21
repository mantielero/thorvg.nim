## Canonical Huffman tables for VP8L (utils/huffman.cpp/.h).
##
## Same two-level lookup as libwebp: a root table indexed by the next `rootBits` bits and,
## for longer codes, second-level tables reached through an entry whose `bits` exceeds
## `rootBits` and whose `value` is the offset to the sub table. All tables of a stream live
## in ONE `seq[HuffmanCode]` (`HuffmanTables`) and are addressed by start index instead of
## pointer. The builder accepts and rejects exactly the same code-length sets as upstream
## (incomplete or over-subscribed codes are errors, a single symbol gets a 0-bit code).

import ./vp8l_bits

const
  HuffmanTableBits* = 8
  HuffmanTableMask = (1 shl HuffmanTableBits) - 1
  LengthsTableBits* = 7
  LengthsTableMask* = (1 shl LengthsTableBits) - 1
  MaxAllowedCodeLength = 15
  HuffmanCodesPerMetaCode* = 5

type
  HuffmanCode* = object
    bits*: uint8
    value*: uint16

  HuffmanTables* = seq[HuffmanCode]

  HTreeGroup* = object
    htrees*: array[HuffmanCodesPerMetaCode, int]   ## start index of each root table
    isTrivialLiteral*: bool    ## red, blue and alpha trees have a single symbol
    literalArb*: uint32        ## ARGB of such a pixel with green = 0

func getNextKey(key: uint32, len: int): uint32 =
  ## reverse(reverse(key, len) + 1, len)
  var step = 1'u32 shl (len - 1)
  while (key and step) != 0: step = step shr 1
  (key and (step - 1)) + step

func replicateValue(t: var HuffmanTables, base, step, endv: int, code: HuffmanCode) =
  var e = endv
  while true:
    e -= step
    t[base + e] = code
    if e <= 0: break

func nextTableBitSize(count: array[MaxAllowedCodeLength + 1, int], len, rootBits: int): int =
  var l = len
  var left = 1 shl (l - rootBits)
  while l < MaxAllowedCodeLength:
    left -= count[l]
    if left <= 0: break
    inc l
    left = left shl 1
  l - rootBits

func buildTable(t: var HuffmanTables, start, rootBits: int, lengths: openArray[int],
                size: int, fill: bool): int =
  ## `BuildHuffmanTable`: returns the total table size or 0 for an invalid code.
  ## `fill = false` is the sizing/validation pass (upstream's `root_table == NULL`).
  var count: array[MaxAllowedCodeLength + 1, int]
  var offset: array[MaxAllowedCodeLength + 1, int]
  var totalSize = 1 shl rootBits
  for symbol in 0 ..< size:
    if lengths[symbol] > MaxAllowedCodeLength: return 0
    inc count[lengths[symbol]]
  if count[0] == size: return 0
  offset[1] = 0
  for len in 1 ..< MaxAllowedCodeLength:
    if count[len] > (1 shl len): return 0
    offset[len + 1] = offset[len] + count[len]
  var sorted = newSeq[uint16](if fill: size else: 0)
  for symbol in 0 ..< size:
    let l = lengths[symbol]
    if l > 0:
      if fill: sorted[offset[l]] = uint16(symbol)
      inc offset[l]
  if offset[MaxAllowedCodeLength] == 1:
    if fill:
      replicateValue(t, start, 1, totalSize, HuffmanCode(bits: 0, value: sorted[0]))
    return totalSize
  var
    low = 0xffffffff'u32
    mask = uint32(totalSize - 1)
    key = 0'u32
    numNodes = 1
    numOpen = 1
    tableSize = 1 shl rootBits
    table = start            # start of the current (sub) table
    symbol = 0
    step = 2
  for len in 1 .. rootBits:
    numOpen = numOpen shl 1
    numNodes += numOpen
    numOpen -= count[len]
    if numOpen < 0: return 0
    if fill:
      while count[len] > 0:
        replicateValue(t, start + int(key), step, tableSize,
                       HuffmanCode(bits: uint8(len), value: sorted[symbol]))
        inc symbol
        key = getNextKey(key, len)
        dec count[len]
    step = step shl 1
  step = 2
  for len in rootBits + 1 .. MaxAllowedCodeLength:
    numOpen = numOpen shl 1
    numNodes += numOpen
    numOpen -= count[len]
    if numOpen < 0: return 0
    while count[len] > 0:
      if (key and mask) != low:
        if fill: table += tableSize
        let tableBits = nextTableBitSize(count, len, rootBits)
        tableSize = 1 shl tableBits
        totalSize += tableSize
        low = key and mask
        if fill:
          t[start + int(low)] = HuffmanCode(bits: uint8(tableBits + rootBits),
                                            value: uint16(table - start - int(low)))
      if fill:
        replicateValue(t, table + int(key shr uint32(rootBits)), step, tableSize,
                       HuffmanCode(bits: uint8(len - rootBits), value: sorted[symbol]))
        inc symbol
      key = getNextKey(key, len)
      dec count[len]
    step = step shl 1
  if numNodes != 2 * offset[MaxAllowedCodeLength] - 1: return 0
  totalSize

proc buildHuffmanTable*(t: var HuffmanTables, rootBits: int, lengths: openArray[int],
                        size: int): int =
  ## `VP8LBuildHuffmanTable`: appends one table to `t` and returns its size (0 = error,
  ## nothing appended). The table starts at the old `t.len`.
  result = buildTable(t, 0, rootBits, lengths, size, false)
  if result != 0:
    let start = t.len
    t.setLen(start + result)
    discard buildTable(t, start, rootBits, lengths, size, true)

func readSymbol*(t: HuffmanTables, start: int, br: var Vp8lBitReader): int {.inline.} =
  ## Decodes the next Huffman code. `fillBitWindow` must have been called at least every
  ## second call to prefetch enough bits.
  var val = br.prefetchBits()
  var idx = start + int(val and HuffmanTableMask)
  let nbits = int(t[idx].bits) - HuffmanTableBits
  if nbits > 0:
    br.setBitPos(br.bitPos + HuffmanTableBits)
    val = br.prefetchBits()
    idx += int(t[idx].value)
    idx += int(val and uint32((1 shl nbits) - 1))
  br.setBitPos(br.bitPos + int(t[idx].bits))
  int(t[idx].value)
