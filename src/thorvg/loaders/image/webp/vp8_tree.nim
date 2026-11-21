## VP8 coding trees and probabilities: coefficient probabilities and intra mode parsing.
##
## Ported from `src/modules/webp/static/dec/tree.cpp` (generic 4x4 mode tree variant).

import ./[vp8_bits, vp8_tables, vp8_types]

const
  YModesIntra4 = [
    0'i8, 1, -BTmPred, 2, -BVePred, 3, 4, 6, -BHePred, 5, -BRdPred, -BVrPred, -BLdPred, 7,
    -BVlPred, 8, -BHdPred, -BHuPred]
  ## Paragraph 9.9; the last entry is a sentinel
  Bands* = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0]

proc resetProba*(dec: Vp8Decoder) =
  ## `VP8ResetProba`
  for s in 0 ..< 3: dec.segmentProbas[s] = 255

proc parseProba*(dec: Vp8Decoder) =
  ## `VP8ParseProba` (Paragraph 13)
  var i = 0
  for t in 0 ..< NumTypes:
    for b in 0 ..< NumBands:
      for c in 0 ..< NumCtx:
        for p in 0 ..< NumProbas:
          let v = if dec.br.getBit(int(CoeffsUpdateProba[i])) != 0: dec.br.getValue(8)
                  else: int(CoeffsProba0[i])
          dec.bands[probaBase(t, b, c) + p] = uint8(v)
          inc i
  dec.useSkipProba = dec.br.get() != 0
  if dec.useSkipProba: dec.skipP = dec.br.getValue(8)

proc parseIntraModeRow*(dec: Vp8Decoder): bool =
  ## `VP8ParseIntraModeRow`: parses the intra modes of one macroblock row from partition 0.
  ## Returns false at the end of the partition.
  for mbX in 0 ..< dec.mbW:
    let top = 4 * mbX
    template blk(): untyped = dec.mbData[mbX]
    # The segment map is not kept (only one key frame is ever decoded).
    if dec.segmentHdr.updateMap:
      blk.segment =
        if dec.br.getBit(dec.segmentProbas[0]) == 0: dec.br.getBit(dec.segmentProbas[1])
        else: 2 + dec.br.getBit(dec.segmentProbas[2])
    else:
      blk.segment = 0
    if dec.useSkipProba: blk.skip = dec.br.getBit(dec.skipP) != 0
    blk.isI4x4 = dec.br.getBit(145) == 0
    if not blk.isI4x4:
      let ymode =
        if dec.br.getBit(156) != 0: (if dec.br.getBit(128) != 0: TmPred else: HPred)
        else: (if dec.br.getBit(163) != 0: VPred else: DcPred)
      blk.imodes[0] = uint8(ymode)
      for i in 0 ..< 4:
        dec.intraT[top + i] = uint8(ymode)
        dec.intraL[i] = uint8(ymode)
    else:
      for y in 0 ..< 4:
        var ymode = int(dec.intraL[y])
        for x in 0 ..< 4:
          let prob = (int(dec.intraT[top + x]) * NumBModes + ymode) * 9
          var i = int(YModesIntra4[dec.br.getBit(int(BModesProba[prob]))])
          while i > 0:
            i = int(YModesIntra4[2 * i + dec.br.getBit(int(BModesProba[prob + i]))])
          ymode = -i
          dec.intraT[top + x] = uint8(ymode)
        for x in 0 ..< 4: blk.imodes[y * 4 + x] = dec.intraT[top + x]
        dec.intraL[y] = uint8(ymode)
    blk.uvmode =
      if dec.br.getBit(142) == 0: DcPred
      elif dec.br.getBit(114) == 0: VPred
      elif dec.br.getBit(183) != 0: TmPred
      else: HPred
  not dec.br.eof
