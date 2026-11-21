## GIF LZW decompressor (`GifLzwState` / `GifDecoder::lzwDecode` of `tvgGifDecoder.cpp`).
##
## `lzwDecode` fills `output` (its length is the number of pixel indices wanted) from the
## de-blocked image data and returns how many bytes were produced. The routine is
## deliberately as forgiving / strict as the original: a broken stream just stops early
## (the caller compares the count), a literal expected after a clear code that is not one
## stops it, and an over-long dictionary chain is an error.

const
  NoCode = 0xFFFF'u32           ## prefix of a single-byte string
  DictSize = 4096

type
  LzwState = object
    prefix: array[DictSize, uint32]   ## entry minus its last byte, or `NoCode`
    suffix: array[DictSize, uint8]
    stack: array[DictSize, uint8]
    minCodeSize: int
    clearCode, endCode, nextCode, codeSize, codeMask: uint32
    bitPos: int
    bitBuffer: uint32
    bitsInBuffer: uint32
    outputPos: int
    oldCode: uint32

proc reset(s: var LzwState) =
  s.codeSize = uint32(s.minCodeSize + 1)
  s.codeMask = (1'u32 shl s.codeSize) - 1
  s.nextCode = s.endCode + 1
  s.oldCode = NoCode

proc readCode(s: var LzwState, input: openArray[uint8]): uint32 =
  ## GIF packs codes LSB-first across byte boundaries; running dry yields the end code.
  while s.bitsInBuffer < s.codeSize and (s.bitPos div 8) < input.len:
    s.bitBuffer = s.bitBuffer or (uint32(input[s.bitPos div 8]) shl s.bitsInBuffer)
    s.bitsInBuffer += 8
    s.bitPos += 8
  if s.bitsInBuffer < s.codeSize: return s.endCode
  result = s.bitBuffer and s.codeMask
  s.bitBuffer = s.bitBuffer shr s.codeSize
  s.bitsInBuffer -= s.codeSize

proc outputSequence(s: var LzwState, output: var openArray[uint8], code: uint32): bool =
  var stackPos = 0
  var current = code
  while current != NoCode and stackPos < DictSize:
    if current >= s.nextCode: return false
    s.stack[stackPos] = s.suffix[current]
    inc stackPos
    current = s.prefix[current]
  if current != NoCode and stackPos >= DictSize: return false
  while stackPos > 0 and s.outputPos < output.len:
    dec stackPos
    output[s.outputPos] = s.stack[stackPos]
    inc s.outputPos
  true

func firstByte(s: LzwState, code: uint32): uint8 =
  if code < s.clearCode: return uint8(code)
  if code >= s.nextCode: return 0
  var walk = code
  while walk != NoCode and walk >= s.clearCode: walk = s.prefix[walk]
  if walk < s.clearCode: uint8(walk) else: 0

proc extendDictionary(s: var LzwState, oldCode, code: uint32) =
  if s.nextCode >= DictSize: return
  s.prefix[s.nextCode] = oldCode
  let tempCode = if code >= s.nextCode: oldCode else: code
  s.suffix[s.nextCode] = s.firstByte(tempCode)
  inc s.nextCode
  if s.nextCode >= (1'u32 shl s.codeSize) and s.codeSize < 12:
    inc s.codeSize
    s.codeMask = (1'u32 shl s.codeSize) - 1

proc emitSequence(s: var LzwState, output: var openArray[uint8], code: uint32): bool =
  if code > s.nextCode: return false
  if code == s.nextCode:
    if not s.outputSequence(output, s.oldCode): return false
    if s.outputPos >= output.len: return false
    output[s.outputPos] = s.firstByte(s.oldCode)
    inc s.outputPos
  elif not s.outputSequence(output, code):
    return false
  s.extendDictionary(s.oldCode, code)
  s.oldCode = code
  true

proc decode(s: var LzwState, input: openArray[uint8], output: var openArray[uint8]): int =
  var running = true
  while running and s.outputPos < output.len:
    let code = s.readCode(input)
    if code == s.endCode:
      running = false
    elif code == s.clearCode:
      # a clear code resets the code width and dictionary growth state
      s.reset()
    elif s.oldCode == NoCode:
      # the first code after a reset must be a literal
      if code >= s.clearCode:
        running = false
      else:
        output[s.outputPos] = uint8(code)
        inc s.outputPos
        s.oldCode = code
    elif not s.emitSequence(output, code):
      running = false
  s.outputPos

proc lzwDecode*(input: openArray[uint8], output: var openArray[uint8],
    minCodeSize: int): int =
  ## Decodes `input` into `output`; returns the number of bytes written.
  if minCodeSize < 2 or minCodeSize > 8: return 0
  if input.len == 0 or output.len == 0: return 0
  var s = LzwState(minCodeSize: minCodeSize, oldCode: NoCode)
  s.clearCode = 1'u32 shl minCodeSize
  s.endCode = s.clearCode + 1
  s.reset()
  for i in 0 ..< int(s.clearCode):
    s.prefix[i] = NoCode
    s.suffix[i] = uint8(i)
  s.decode(input, output)
