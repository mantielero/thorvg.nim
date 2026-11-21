## VP8 dequantizer setup (Paragraph 9.6).
##
## Ported from `src/modules/webp/static/dec/quant.cpp`.

import ./[vp8_bits, vp8_tables, vp8_types]

func clip(v, m: int): int = (if v < 0: 0 elif v > m: m else: v)

proc parseQuant*(dec: Vp8Decoder) =
  ## `VP8ParseQuant`: reads the quantizer indices from partition 0 and fills `dqm`.
  template optSigned(): int = (if dec.br.get() != 0: dec.br.getSignedValue(4) else: 0)
  let baseQ0 = dec.br.getValue(7)
  let dqy1Dc = optSigned()
  let dqy2Dc = optSigned()
  let dqy2Ac = optSigned()
  let dquvDc = optSigned()
  let dquvAc = optSigned()
  let hdr = dec.segmentHdr
  for i in 0 ..< NumMbSegments:
    var q = baseQ0
    var copyFirst = false
    if hdr.useSegment:
      q = hdr.quantizer[i]
      if not hdr.absoluteDelta: q += baseQ0
    elif i > 0:
      dec.dqm[i] = dec.dqm[0]
      copyFirst = true
    if not copyFirst:
      template m(): untyped = dec.dqm[i]
      m.y1[0] = int(DcTable[clip(q + dqy1Dc, 127)])
      m.y1[1] = int(AcTable[clip(q, 127)])
      m.y2[0] = int(DcTable[clip(q + dqy2Dc, 127)]) * 2
      # For all x in [0..284], x * 155 / 100 is bitwise equal to (x * 101581) >> 16.
      m.y2[1] = (int(AcTable[clip(q + dqy2Ac, 127)]) * 101581) shr 16
      if m.y2[1] < 8: m.y2[1] = 8
      m.uv[0] = int(DcTable[clip(q + dquvDc, 117)])
      m.uv[1] = int(AcTable[clip(q + dquvAc, 127)])
