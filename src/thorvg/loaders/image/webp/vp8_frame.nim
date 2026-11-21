## VP8 frame reconstruction and in-loop filtering.
##
## Ported from `src/modules/webp/static/dec/frame.cpp`. Whole Y/U/V planes replace the
## C++ row cache (D-L5cB-1): a macroblock row is predicted in the 32-stride work buffer
## `yuvB`, copied to the planes, then filtered in place. The filter only touches rows that
## the C++ decoder keeps in its cache, so the result is identical.

import ./[vp8_dsp, vp8_filter, vp8_types]

func scanOffset(n: int): int = (n and 3) * 4 + (n shr 2) * 4 * Bps

func checkMode(mbX, mbY, mode: int): int =
  if mode == BDcPred:
    if mbX == 0:
      (if mbY == 0: BDcPredNoTopLeft else: BDcPredNoLeft)
    else:
      (if mbY == 0: BDcPredNoTop else: BDcPred)
  else:
    mode

proc doTransform(bits: uint32, src: openArray[int16], s0: int, dst: var openArray[uint8],
                 d: int) =
  case bits shr 30
  of 3: transformTwo(src, s0, dst, d, false)
  of 2: transformAC3(src, s0, dst, d)
  of 1: transformDC(src, s0, dst, d)
  else: discard

proc doUVTransform(bits: uint32, src: openArray[int16], s0: int, dst: var openArray[uint8],
                   d: int) =
  if (bits and 0xff) != 0:       # any non-zero coeff at all?
    if (bits and 0xaa) != 0:     # any non-zero AC coefficient?
      transformUV(src, s0, dst, d)
    else:
      transformDCUV(src, s0, dst, d)

proc copy4(b: var seq[uint8], dst, src: int) =
  for k in 0 ..< 4: b[dst + k] = b[src + k]

proc reconstructRow*(dec: Vp8Decoder) =
  ## `ReconstructRow`: predicts and reconstructs macroblock row `dec.mbY`.
  let mbY = dec.mbY
  template yb(): untyped = dec.yuvB
  const
    yD = YOff
    uD = UOff
    vD = VOff
  for j in 0 ..< 16: yb[yD + j * Bps - 1] = 129
  for j in 0 ..< 8:
    yb[uD + j * Bps - 1] = 129
    yb[vD + j * Bps - 1] = 129
  if mbY > 0:     # top-left sample on the left column too
    yb[yD - 1 - Bps] = 129
    yb[uD - 1 - Bps] = 129
    yb[vD - 1 - Bps] = 129
  else:
    for i in 0 ..< 16 + 4 + 1: yb[yD - Bps - 1 + i] = 127
    for i in 0 ..< 8 + 1:
      yb[uD - Bps - 1 + i] = 127
      yb[vD - Bps - 1 + i] = 127
  for mbX in 0 ..< dec.mbW:
    template mbd(): untyped = dec.mbData[mbX]
    if mbX > 0:   # rotate in the left samples from the previous block
      for j in -1 ..< 16: yb.copy4(yD + j * Bps - 4, yD + j * Bps + 12)
      for j in -1 ..< 8:
        yb.copy4(uD + j * Bps - 4, uD + j * Bps + 4)
        yb.copy4(vD + j * Bps - 4, vD + j * Bps + 4)
    var bits = mbd.nonZeroY
    if mbY > 0:   # bring top samples into the work buffer
      for i in 0 ..< 16: yb[yD - Bps + i] = dec.topY[mbX * 16 + i]
      for i in 0 ..< 8:
        yb[uD - Bps + i] = dec.topU[mbX * 8 + i]
        yb[vD - Bps + i] = dec.topV[mbX * 8 + i]
    if mbd.isI4x4:
      let tr = yD - Bps + 16
      if mbY > 0:
        if mbX >= dec.mbW - 1:   # on rightmost border
          for i in 0 ..< 4: yb[tr + i] = dec.topY[mbX * 16 + 15]
        else:
          for i in 0 ..< 4: yb[tr + i] = dec.topY[(mbX + 1) * 16 + i]
      for k in 1 .. 3:           # replicate the top-right pixels below
        for i in 0 ..< 4: yb[tr + 4 * Bps * k + i] = yb[tr + i]
      for n in 0 ..< 16:
        let dst = yD + scanOffset(n)
        predLuma4(int(mbd.imodes[n]), yb, dst)
        doTransform(bits, mbd.coeffs, n * 16, yb, dst)
        bits = bits shl 2
    else:
      predLuma16(checkMode(mbX, mbY, int(mbd.imodes[0])), yb, yD)
      if bits != 0:
        for n in 0 ..< 16:
          doTransform(bits, mbd.coeffs, n * 16, yb, yD + scanOffset(n))
          bits = bits shl 2
    let uvPred = checkMode(mbX, mbY, mbd.uvmode)
    predChroma8(uvPred, yb, uD)
    predChroma8(uvPred, yb, vD)
    doUVTransform(mbd.nonZeroUv shr 0, mbd.coeffs, 16 * 16, yb, uD)
    doUVTransform(mbd.nonZeroUv shr 8, mbd.coeffs, 20 * 16, yb, vD)
    if mbY < dec.mbH - 1:        # stash away top samples for the next row
      for i in 0 ..< 16: dec.topY[mbX * 16 + i] = yb[yD + 15 * Bps + i]
      for i in 0 ..< 8:
        dec.topU[mbX * 8 + i] = yb[uD + 7 * Bps + i]
        dec.topV[mbX * 8 + i] = yb[vD + 7 * Bps + i]
    for j in 0 ..< 16:           # transfer to the final planes
      let o = (mbY * 16 + j) * dec.yStride + mbX * 16
      for i in 0 ..< 16: dec.yPlane[o + i] = yb[yD + j * Bps + i]
    for j in 0 ..< 8:
      let o = (mbY * 8 + j) * dec.uvStride + mbX * 8
      for i in 0 ..< 8:
        dec.uPlane[o + i] = yb[uD + j * Bps + i]
        dec.vPlane[o + i] = yb[vD + j * Bps + i]

proc doFilter(dec: Vp8Decoder, mbX, mbY: int) =
  let info = dec.fInfo[mbX]
  let yBps = dec.yStride
  let yDst = mbY * 16 * yBps + mbX * 16
  let ilevel = info.fIlevel
  let limit = info.fLimit
  if limit == 0: return
  if dec.filterType == 1:   # simple
    if mbX > 0: simpleHFilter16(dec.yPlane, yDst, yBps, limit + 4)
    if info.fInner != 0: simpleHFilter16i(dec.yPlane, yDst, yBps, limit)
    if mbY > 0: simpleVFilter16(dec.yPlane, yDst, yBps, limit + 4)
    if info.fInner != 0: simpleVFilter16i(dec.yPlane, yDst, yBps, limit)
  else:                     # complex
    let uvBps = dec.uvStride
    let uvDst = mbY * 8 * uvBps + mbX * 8
    let hevT = info.hevThresh
    if mbX > 0:
      hFilter16(dec.yPlane, yDst, yBps, limit + 4, ilevel, hevT)
      hFilter8(dec.uPlane, uvDst, uvBps, limit + 4, ilevel, hevT)
      hFilter8(dec.vPlane, uvDst, uvBps, limit + 4, ilevel, hevT)
    if info.fInner != 0:
      hFilter16i(dec.yPlane, yDst, yBps, limit, ilevel, hevT)
      hFilter8i(dec.uPlane, uvDst, uvBps, limit, ilevel, hevT)
      hFilter8i(dec.vPlane, uvDst, uvBps, limit, ilevel, hevT)
    if mbY > 0:
      vFilter16(dec.yPlane, yDst, yBps, limit + 4, ilevel, hevT)
      vFilter8(dec.uPlane, uvDst, uvBps, limit + 4, ilevel, hevT)
      vFilter8(dec.vPlane, uvDst, uvBps, limit + 4, ilevel, hevT)
    if info.fInner != 0:
      vFilter16i(dec.yPlane, yDst, yBps, limit, ilevel, hevT)
      vFilter8i(dec.uPlane, uvDst, uvBps, limit, ilevel, hevT)
      vFilter8i(dec.vPlane, uvDst, uvBps, limit, ilevel, hevT)

proc filterRow*(dec: Vp8Decoder) =
  ## `FilterRow`: filters the macroblock row `dec.mbY` (no cropping: every macroblock).
  for mbX in 0 ..< dec.mbW: dec.doFilter(mbX, dec.mbY)

proc precomputeFilterStrengths(dec: Vp8Decoder) =
  if dec.filterType == 0: return
  let hdr = dec.filterHdr
  for s in 0 ..< NumMbSegments:
    var baseLevel = hdr.level
    if dec.segmentHdr.useSegment:
      baseLevel = dec.segmentHdr.filterStrength[s]
      if not dec.segmentHdr.absoluteDelta: baseLevel += hdr.level
    for i4x4 in 0 .. 1:
      var info = Vp8FInfo()
      var level = baseLevel
      if hdr.useLfDelta:
        level += hdr.refLfDelta[0]
        if i4x4 == 1: level += hdr.modeLfDelta[0]
      level = clamp(level, 0, 63)
      if level > 0:
        var ilevel = level
        if hdr.sharpness > 0:
          ilevel = ilevel shr (if hdr.sharpness > 4: 2 else: 1)
          if ilevel > 9 - hdr.sharpness: ilevel = 9 - hdr.sharpness
        if ilevel < 1: ilevel = 1
        info.fIlevel = ilevel
        info.fLimit = 2 * level + ilevel
        info.hevThresh = if level >= 40: 2 elif level >= 15: 1 else: 0
      info.fInner = i4x4
      dec.fstrengths[s][i4x4] = info

proc initFrame*(dec: Vp8Decoder) =
  ## `VP8InitFrame` / `VP8EnterCritical` / `AllocateMemory`: allocates the per-frame state.
  dec.precomputeFilterStrengths()
  dec.yStride = 16 * dec.mbW
  dec.uvStride = 8 * dec.mbW
  dec.intraT = newSeq[uint8](4 * dec.mbW)         # B_DC_PRED == 0
  dec.topY = newSeq[uint8](16 * dec.mbW)
  dec.topU = newSeq[uint8](8 * dec.mbW)
  dec.topV = newSeq[uint8](8 * dec.mbW)
  dec.mbInfo = newSeq[Vp8Mb](dec.mbW + 1)
  dec.fInfo = newSeq[Vp8FInfo](if dec.filterType > 0: dec.mbW else: 0)
  dec.yuvB = newSeq[uint8](YuvSize)
  dec.mbData = newSeq[Vp8MbData](dec.mbW)
  dec.yPlane = newSeq[uint8](dec.yStride * 16 * dec.mbH)
  dec.uPlane = newSeq[uint8](dec.uvStride * 8 * dec.mbH)
  dec.vPlane = newSeq[uint8](dec.uvStride * 8 * dec.mbH)
  dec.mbX = 0
  dec.mbY = 0
