## zlib / DEFLATE decompressor (RFC 1950 / 1951) for the PNG loader.
##
## Behaves like the inflater of lodepng (`tvgLodePng.cpp`): same checks, same numeric
## error codes (0 = ok), `Huffman` decoding is a canonical-code walk instead of
## lodepng's lookup tables (same results, simpler). Reading past the end of the input
## yields zero bits and is reported as an error after the current symbol.

type
  Huffman = object
    count: array[16, int]      ## number of codes of each bit length
    symbols: seq[int]          ## symbols ordered by (length, value)

const
  MaxBits = 15
  CodeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
  LengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
    67, 83, 99, 115, 131, 163, 195, 227, 258]
  LengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0]
  DistanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
    513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
  DistanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10,
    10, 11, 11, 12, 12, 13, 13]

func readBit(data: openArray[byte], bp: var int): int =
  let i = bp shr 3
  result = if i < data.len: int(data[i] shr uint8(bp and 7)) and 1 else: 0
  inc bp

func readBits(data: openArray[byte], bp: var int, n: int): int =
  ## LSB-first bit field of `n` bits.
  for i in 0 ..< n: result = result or (readBit(data, bp) shl i)

func makeHuffman(lengths: openArray[int], error: var int): Huffman =
  ## Builds a canonical code. An over-subscribed code, or an incomplete code with
  ## two or more symbols, is error 55 (lodepng); 0 or 1 symbols may stay incomplete.
  var present = 0
  for l in lengths:
    inc result.count[l]
    if l > 0: inc present
  var left = 1
  for len in 1 .. MaxBits:
    left = (left shl 1) - result.count[len]
    if left < 0: error = 55
  if left > 0 and present >= 2: error = 55
  var offsets: array[17, int]
  for len in 1 .. MaxBits: offsets[len + 1] = offsets[len] + result.count[len]
  result.symbols = newSeq[int](lengths.len)
  for sym, l in lengths:
    if l != 0:
      result.symbols[offsets[l]] = sym
      inc offsets[l]

func decodeSymbol(h: Huffman, data: openArray[byte], bp: var int): int =
  ## -1 when the bits form no valid code.
  var code, first, index = 0
  for len in 1 .. MaxBits:
    code = code or readBit(data, bp)
    let count = h.count[len]
    if code - count < first: return h.symbols[index + (code - first)]
    index += count
    first = (first + count) shl 1
    code = code shl 1
  -1

func fixedLengths(lit: bool): seq[int] =
  if lit:
    result = newSeq[int](288)
    for i in 0 ..< 288:
      result[i] = if i <= 143: 8 elif i <= 255: 9 elif i <= 279: 7 else: 8
  else:
    result = newSeq[int](32)
    for i in 0 ..< 32: result[i] = 5

proc readDynamicTrees(data: openArray[byte], bp: var int, lit, dist: var Huffman): int =
  if bp + 14 > data.len * 8: return 49
  let hlit = readBits(data, bp, 5) + 257
  let hdist = readBits(data, bp, 5) + 1
  let hclen = readBits(data, bp, 4) + 4
  if bp + hclen * 3 > data.len * 8: return 50
  var clens = newSeq[int](19)
  for i in 0 ..< hclen: clens[CodeLengthOrder[i]] = readBits(data, bp, 3)
  var error = 0
  let clTree = makeHuffman(clens, error)
  if error != 0: return error
  var lens = newSeq[int](hlit + hdist)
  var i = 0
  while i < hlit + hdist and error == 0:
    let code = clTree.decodeSymbol(data, bp)
    var rep = 0
    var value = 0
    if code < 0 or code > 18: error = 16
    elif code <= 15:
      lens[i] = code
      inc i
    elif code == 16:
      if i == 0: error = 54
      else:
        value = lens[i - 1]
        rep = 3 + readBits(data, bp, 2)
    elif code == 17: rep = 3 + readBits(data, bp, 3)
    else: rep = 11 + readBits(data, bp, 7)
    if error == 0 and rep > 0:
      if i + rep > hlit + hdist: error = if code == 16: 13 elif code == 17: 14 else: 15
      else:
        for n in 0 ..< rep: lens[i + n] = value
        i += rep
    if error == 0 and bp > data.len * 8: error = 50
  if error != 0: return error
  if lens[256] == 0: return 64
  lit = makeHuffman(lens[0 ..< hlit], error)
  if error != 0: return error
  dist = makeHuffman(lens[hlit ..< hlit + hdist], error)
  error

proc inflateHuffman(data: openArray[byte], bp: var int, output: var seq[byte],
    dynamic: bool): int =
  var lit, dist: Huffman
  var error = 0
  if dynamic: error = readDynamicTrees(data, bp, lit, dist)
  else:
    lit = makeHuffman(fixedLengths(true), error)
    if error == 0: dist = makeHuffman(fixedLengths(false), error)
  while error == 0:
    let sym = lit.decodeSymbol(data, bp)
    if sym < 0: error = 16
    elif sym <= 255: output.add byte(sym)
    elif sym == 256: break
    elif sym <= 285:
      let length = LengthBase[sym - 257] + readBits(data, bp, LengthExtra[sym - 257])
      let dcode = dist.decodeSymbol(data, bp)
      if dcode < 0: error = 16
      elif dcode > 29: error = 18
      else:
        let distance = DistanceBase[dcode] + readBits(data, bp, DistanceExtra[dcode])
        if distance > output.len: error = 52
        else:
          var src = output.len - distance
          for _ in 0 ..< length:
            output.add output[src]
            inc src
    else: error = 16
    if error == 0 and bp > data.len * 8: error = 51
  error

proc inflateStored(data: openArray[byte], bp: var int, output: var seq[byte]): int =
  var pos = (bp + 7) shr 3
  if pos + 4 >= data.len: return 52
  let len = int(data[pos]) + (int(data[pos + 1]) shl 8)
  let nlen = int(data[pos + 2]) + (int(data[pos + 3]) shl 8)
  pos += 4
  if len + nlen != 65535: return 21
  if pos + len > data.len: return 23
  output.add data[pos ..< pos + len]
  bp = (pos + len) shl 3
  0

proc inflate*(data: openArray[byte], output: var seq[byte]): int =
  ## Raw DEFLATE stream; appends to `output`. Returns a lodepng error code (0 = ok).
  var bp = 0
  var final = 0
  var error = 0
  while final == 0 and error == 0:
    if bp + 3 > data.len * 8: return 52
    final = readBits(data, bp, 1)
    let btype = readBits(data, bp, 2)
    case btype
    of 0: error = inflateStored(data, bp, output)
    of 3: error = 20
    else: error = inflateHuffman(data, bp, output, btype == 2)
  error

func adler32*(data: openArray[byte]): uint32 =
  var s1 = 1'u32
  var s2 = 0'u32
  for b in data:
    s1 = (s1 + uint32(b)) mod 65521'u32
    s2 = (s2 + s1) mod 65521'u32
  (s2 shl 16) or s1

proc zlibDecompress*(data: openArray[byte], output: var seq[byte]): int =
  ## zlib container (header check, DEFLATE, Adler-32). Lodepng error codes.
  if data.len < 2: return 53
  if (int(data[0]) * 256 + int(data[1])) mod 31 != 0: return 24
  if (data[0] and 15) != 8 or ((data[0] shr 4) and 15) > 7: return 25
  if ((data[1] shr 5) and 1) != 0: return 26
  let first = output.len
  result = inflate(data.toOpenArray(2, data.high), output)
  if result == 0:
    var expected = 0'u32
    for i in data.len - 4 ..< data.len: expected = (expected shl 8) or uint32(data[i])
    if adler32(output.toOpenArray(first, output.high)) != expected: result = 58
