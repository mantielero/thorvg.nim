## VP8 boolean decoder (the lossy part of `utils/bit_reader*.{h,cpp}`).
##
## Ported from `src/modules/webp/static/utils/bit_reader.cpp` and `bit_reader_inl.h`.
## It mirrors the x86-64 build (`BITS == 56`): 7 bytes per refill while at least 8 bytes
## remain, then one byte at a time. Following the refill granularity exactly matters even for
## corrupt streams (a first byte of 0xFF breaks the `value <= range` invariant and the
## 64-bit window then overflows), so decoded bits and the `eof` flag match the C++ decoder.
## Each reader owns a copy of its partition bytes, which keeps all accesses bounds-checked.

const
  Log2Range = [
    7, 6, 6, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0]
  ## range = ((range - 1) << Log2Range[range]) + 1
  NewRange = [
    127, 127, 191, 127, 159, 191, 223, 127, 143, 159, 175, 191, 207, 223, 239, 127,
    135, 143, 151, 159, 167, 175, 183, 191, 199, 207, 215, 223, 231, 239, 247, 127,
    131, 135, 139, 143, 147, 151, 155, 159, 163, 167, 171, 175, 179, 183, 187, 191,
    195, 199, 203, 207, 211, 215, 219, 223, 227, 231, 235, 239, 243, 247, 251, 127,
    129, 131, 133, 135, 137, 139, 141, 143, 145, 147, 149, 151, 153, 155, 157, 159,
    161, 163, 165, 167, 169, 171, 173, 175, 177, 179, 181, 183, 185, 187, 189, 191,
    193, 195, 197, 199, 201, 203, 205, 207, 209, 211, 213, 215, 217, 219, 221, 223,
    225, 227, 229, 231, 233, 235, 237, 239, 241, 243, 245, 247, 249, 251, 253, 127]

type
  Vp8BitReader* = object
    value*: uint64        ## current value window
    rng*: int             ## current range minus 1, in [127, 254]
    bits*: int            ## number of valid bits left
    buf*: seq[byte]       ## the partition bytes
    pos*: int             ## next byte to be read
    eof*: bool            ## true once the input is exhausted

proc loadNewBytes(br: var Vp8BitReader) =
  ## `VP8LoadNewBytes`; the tail is `VP8LoadFinalBytes`: one byte per call, then one zero
  ## byte, then a no-op reset.
  if br.pos + 8 <= br.buf.len:
    var bits = 0'u64
    for i in 0 ..< 7: bits = (bits shl 8) or uint64(br.buf[br.pos + i])
    br.pos += 7
    br.value = bits or (br.value shl 56)
    br.bits += 56
  elif br.pos < br.buf.len:
    br.bits += 8
    br.value = uint64(br.buf[br.pos]) or (br.value shl 8)
    inc br.pos
  elif not br.eof:
    br.value = br.value shl 8
    br.bits += 8
    br.eof = true
  else:
    br.bits = 0

proc initBitReader*(buf: seq[byte]): Vp8BitReader =
  ## `VP8InitBitReader`: loads the first byte.
  result = Vp8BitReader(rng: 254, bits: -8, buf: buf)
  result.loadNewBytes()

proc getBit*(br: var Vp8BitReader, prob: int): int {.inline.} =
  ## `VP8GetBit`: reads one bit whose probability of being 0 is `prob / 256`.
  var rng = br.rng
  if br.bits < 0: br.loadNewBytes()
  let pos = br.bits
  let split = (rng * prob) shr 8
  let value = int((br.value shr pos) and 0xffffffff'u64)
  if value > split:
    rng -= split + 1
    br.value -= uint64(split + 1) shl pos
    result = 1
  else:
    rng = split
    result = 0
  if rng <= 0x7e:
    br.bits -= Log2Range[rng]
    rng = NewRange[rng]
  br.rng = rng

proc getSigned*(br: var Vp8BitReader, v: int): int {.inline.} =
  ## `VP8GetSigned`: applies a sign read with probability 1/2 to `v`.
  if br.bits < 0: br.loadNewBytes()
  let pos = br.bits
  let split = br.rng shr 1
  let value = int((br.value shr pos) and 0xffffffff'u64)
  # C++: (int32_t)(split - value) >> 31 on 32-bit unsigned values
  let mask = if ((split - value) and 0xffffffff) >= 0x80000000: -1 else: 0
  br.bits -= 1
  br.rng = (br.rng + mask) or 1
  br.value -= uint64((split + 1) and mask) shl pos
  (v xor mask) - mask

proc getValue*(br: var Vp8BitReader, bits: int): int =
  ## `VP8GetValue`: `bits` literal bits, most significant first.
  for i in countdown(bits - 1, 0):
    result = result or (br.getBit(0x80) shl i)

proc get*(br: var Vp8BitReader): int = br.getValue(1)

proc getSignedValue*(br: var Vp8BitReader, bits: int): int =
  ## `VP8GetSignedValue`: magnitude then sign bit.
  let value = br.getValue(bits)
  if br.get() != 0: -value else: value
