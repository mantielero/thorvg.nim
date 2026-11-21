## VP8 residual (DCT coefficient) parsing and macroblock decoding.
##
## Ported from `src/modules/webp/static/dec/vp8.cpp` (`GetLargeValue`, `GetCoeffs`,
## `TransformWHT`, `ParseResiduals`, `VP8DecodeMB`, `VP8InitScanline`).

import ./[vp8_bits, vp8_tree, vp8_types]

const
  Cat3 = [173, 148, 140]
  Cat4 = [176, 155, 140, 135]
  Cat5 = [180, 157, 141, 134, 130]
  Cat6 = [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129]
  Zigzag = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]

proc catBits(br: var Vp8BitReader, cat: int): int =
  ## Reads the extra bits of DCT categories 3..6.
  template run(tab: untyped) =
    for p in tab: result += result + br.getBit(p)
  case cat
  of 0: run(Cat3)
  of 1: run(Cat4)
  of 2: run(Cat5)
  else: run(Cat6)

proc getLargeValue(br: var Vp8BitReader, p: openArray[uint8], base: int): int =
  ## Section 13-2 of RFC 6386. `base` is the offset of the 11 probabilities in `p`.
  template pr(i: int): int = int(p[base + i])
  if br.getBit(pr(3)) == 0:
    if br.getBit(pr(4)) == 0: result = 2
    else: result = 3 + br.getBit(pr(5))
  elif br.getBit(pr(6)) == 0:
    if br.getBit(pr(7)) == 0:
      result = 5 + br.getBit(159)
    else:
      result = 7 + 2 * br.getBit(165)
      result += br.getBit(145)
  else:
    let bit1 = br.getBit(pr(8))
    let bit0 = br.getBit(pr(9 + bit1))
    let cat = 2 * bit1 + bit0
    result = br.catBits(cat)
    result += 3 + (8 shl cat)

proc getCoeffs(br: var Vp8BitReader, probas: openArray[uint8], t, ctx: int,
               dq: array[2, int], first: int, outp: var openArray[int16],
               dst: int): int =
  ## Returns the position of the last non-zero coefficient plus one.
  var n = first
  var p = probaBase(t, Bands[n], ctx)
  while n < 16:
    if br.getBit(int(probas[p])) == 0: return n   # previous coeff was the last one
    while br.getBit(int(probas[p + 1])) == 0:     # run of zero coeffs
      inc n
      p = probaBase(t, Bands[n], 0)
      if n == 16: return 16
    let pNext = probaBase(t, Bands[n + 1], 0)
    var v: int
    if br.getBit(int(probas[p + 2])) == 0:
      v = 1
      p = pNext + NumProbas
    else:
      v = getLargeValue(br, probas, p)
      p = pNext + 2 * NumProbas
    outp[dst + Zigzag[n]] = toI16(br.getSigned(v) * dq[if n > 0: 1 else: 0])
    inc n
  16

func nzCodeBits(nzCoeffs: uint32, nz, dcNz: int): uint32 =
  (nzCoeffs shl 2) or uint32(if nz > 3: 3 elif nz > 1: 2 else: dcNz)

proc transformWHT(inp: array[16, int16], outp: var array[384, int16]) =
  var tmp: array[16, int]
  for i in 0 ..< 4:
    let a0 = int(inp[i]) + int(inp[12 + i])
    let a1 = int(inp[4 + i]) + int(inp[8 + i])
    let a2 = int(inp[4 + i]) - int(inp[8 + i])
    let a3 = int(inp[i]) - int(inp[12 + i])
    tmp[i] = a0 + a1
    tmp[8 + i] = a0 - a1
    tmp[4 + i] = a3 + a2
    tmp[12 + i] = a3 - a2
  for i in 0 ..< 4:
    let dc = tmp[i * 4] + 3     # with rounder
    let a0 = dc + tmp[3 + i * 4]
    let a1 = tmp[1 + i * 4] + tmp[2 + i * 4]
    let a2 = tmp[1 + i * 4] - tmp[2 + i * 4]
    let a3 = dc - tmp[3 + i * 4]
    let o = i * 64
    outp[o] = toI16((a0 + a1) shr 3)
    outp[o + 16] = toI16((a3 + a2) shr 3)
    outp[o + 32] = toI16((a0 - a1) shr 3)
    outp[o + 48] = toI16((a3 - a2) shr 3)

proc parseResiduals(dec: Vp8Decoder, tokenIdx: int): bool =
  ## `ParseResiduals`: returns true when the macroblock has no non-zero coefficient.
  let mbX = dec.mbX
  let q = dec.dqm[dec.mbData[mbX].segment]
  var nzY, nzUv: uint32
  var dst = 0
  var first: int
  var acType: int
  dec.mbData[mbX].coeffs = default(array[384, int16])
  if not dec.mbData[mbX].isI4x4:      # parse DC
    var dc: array[16, int16]
    let ctx = dec.mbInfo[1 + mbX].nzDc + dec.mbInfo[0].nzDc
    let nz = getCoeffs(dec.parts[tokenIdx], dec.bands, 1, ctx, q.y2, 0, dc, 0)
    let flag = int(nz > 0)
    dec.mbInfo[1 + mbX].nzDc = flag
    dec.mbInfo[0].nzDc = flag
    if nz > 1:                         # more than just the DC: full transform
      transformWHT(dc, dec.mbData[mbX].coeffs)
    else:
      let dc0 = toI16((int(dc[0]) + 3) shr 3)
      for i in 0 ..< 16: dec.mbData[mbX].coeffs[i * 16] = dc0
    first = 1
    acType = 0
  else:
    first = 0
    acType = 3
  var tnz = uint32(dec.mbInfo[1 + mbX].nz and 0x0f)
  var lnz = uint32(dec.mbInfo[0].nz and 0x0f)
  for y in 0 ..< 4:
    var l = lnz and 1
    var nzCoeffs = 0'u32
    for x in 0 ..< 4:
      let ctx = int(l + (tnz and 1))
      let nz = getCoeffs(dec.parts[tokenIdx], dec.bands, acType, ctx, q.y1, first,
                         dec.mbData[mbX].coeffs, dst)
      l = uint32(nz > first)
      tnz = (tnz shr 1) or (l shl 7)
      nzCoeffs = nzCodeBits(nzCoeffs, nz, int(dec.mbData[mbX].coeffs[dst] != 0))
      dst += 16
    tnz = tnz shr 4
    lnz = (lnz shr 1) or (l shl 7)
    nzY = (nzY shl 8) or nzCoeffs
  var outTNz = tnz
  var outLNz = lnz shr 4
  for ch in countup(0, 2, 2):
    var nzCoeffs = 0'u32
    tnz = uint32(dec.mbInfo[1 + mbX].nz) shr uint32(4 + ch)
    lnz = uint32(dec.mbInfo[0].nz) shr uint32(4 + ch)
    for y in 0 ..< 2:
      var l = lnz and 1
      for x in 0 ..< 2:
        let ctx = int(l + (tnz and 1))
        let nz = getCoeffs(dec.parts[tokenIdx], dec.bands, 2, ctx, q.uv, 0,
                           dec.mbData[mbX].coeffs, dst)
        l = uint32(nz > 0)
        tnz = (tnz shr 1) or (l shl 3)
        nzCoeffs = nzCodeBits(nzCoeffs, nz, int(dec.mbData[mbX].coeffs[dst] != 0))
        dst += 16
      tnz = tnz shr 2
      lnz = (lnz shr 1) or (l shl 5)
    nzUv = nzUv or (nzCoeffs shl uint32(4 * ch))
    outTNz = outTNz or ((tnz shl 4) shl uint32(ch))
    outLNz = outLNz or ((lnz and 0xf0) shl uint32(ch))
  dec.mbInfo[1 + mbX].nz = int(outTNz)
  dec.mbInfo[0].nz = int(outLNz)
  dec.mbData[mbX].nonZeroY = nzY
  dec.mbData[mbX].nonZeroUv = nzUv
  (nzY or nzUv) == 0

proc decodeMB*(dec: Vp8Decoder, tokenIdx: int): bool =
  ## `VP8DecodeMB`: parses the residuals of macroblock `dec.mbX`. Returns false when the
  ## token partition ran out of data.
  let mbX = dec.mbX
  var skip = dec.useSkipProba and dec.mbData[mbX].skip
  if not skip:
    skip = dec.parseResiduals(tokenIdx)
  else:
    dec.mbInfo[0].nz = 0
    dec.mbInfo[1 + mbX].nz = 0
    if not dec.mbData[mbX].isI4x4:
      dec.mbInfo[0].nzDc = 0
      dec.mbInfo[1 + mbX].nzDc = 0
    dec.mbData[mbX].nonZeroY = 0
    dec.mbData[mbX].nonZeroUv = 0
  if dec.filterType > 0:
    dec.fInfo[mbX] = dec.fstrengths[dec.mbData[mbX].segment][int(dec.mbData[mbX].isI4x4)]
    if not skip: dec.fInfo[mbX].fInner = 1
  not dec.parts[tokenIdx].eof

proc initScanline*(dec: Vp8Decoder) =
  ## `VP8InitScanline`
  dec.mbInfo[0].nz = 0
  dec.mbInfo[0].nzDc = 0
  for i in 0 ..< 4: dec.intraL[i] = uint8(BDcPred)
  dec.mbX = 0
