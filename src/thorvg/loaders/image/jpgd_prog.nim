## Progressive-scan block decoding of the jpgd port (DC/AC first and refinement passes).
##
## Split from jpgd to keep files short; see there for the overall design.

import ./[jpgd_bits, jpgd_idct]

type BlockKind* = enum
  DcFirst, DcRefine, AcFirst, AcRefine

proc tableOk*(d: JpegDecoder, idx: int): bool =
  idx >= 0 and idx < MaxHuffTables and d.huffBuilt[idx]

func coeffGetp*(cb: CoeffBuf, bx, by: int): int =
  bx * cb.blockSize + by * (cb.blockSize * cb.blockNumX)

proc refineCoef(d: JpegDecoder, c: var int16, p1, m1: int) =
  ## Correction bit of an already non-zero coefficient (AC refinement scans).
  if d.getBitsNoMarkers(1) != 0 and (int(c) and p1) == 0:
    c = wrap16(int(c) + (if c >= 0: p1 else: m1))

proc decodeAcRefine(d: JpegDecoder, comp, bx, by: int): bool =
  let p1 = 1 shl d.successiveLow
  let m1 = -p1
  let base = coeffGetp(d.acCoeffs[comp], bx, by)
  let tab = d.compAcTab[comp]
  if not d.tableOk(tab): return d.stopDecoding()
  var k = d.spectralStart
  if d.eobRun == 0:
    while k <= d.spectralEnd:
      var s = d.huffDecode(d.huffTabs[tab])
      var r = s shr 4
      s = s and 15
      var stop = false
      if s != 0:
        if s != 1: return d.stopDecoding()
        s = if d.getBitsNoMarkers(1) != 0: p1 else: m1
      elif r != 15:
        d.eobRun = 1 shl r
        if r != 0: d.eobRun += int(d.getBitsNoMarkers(r))
        stop = true
      if stop: break
      while true:
        let at = base + Zag[k and 63]
        if d.acCoeffs[comp].data[at] != 0:
          d.refineCoef(d.acCoeffs[comp].data[at], p1, m1)
        else:
          dec r
          if r < 0: break
        inc k
        if k > d.spectralEnd: break
      if s != 0 and k < 64: d.acCoeffs[comp].data[base + Zag[k]] = wrap16(s)
      inc k
  if d.eobRun > 0:
    while k <= d.spectralEnd:
      let at = base + Zag[k and 63]
      if d.acCoeffs[comp].data[at] != 0:
        d.refineCoef(d.acCoeffs[comp].data[at], p1, m1)
      inc k
    dec d.eobRun
  true

proc decodeAcFirst(d: JpegDecoder, comp, bx, by: int): bool =
  result = true
  if d.eobRun != 0:
    dec d.eobRun
  else:
    let base = coeffGetp(d.acCoeffs[comp], bx, by)
    let tab = d.compAcTab[comp]
    if not d.tableOk(tab): return d.stopDecoding()
    var k = d.spectralStart
    while k <= d.spectralEnd:
      var s = d.huffDecode(d.huffTabs[tab])
      var r = s shr 4
      s = s and 15
      if s != 0:
        k += r
        if k > 63: return d.stopDecoding()
        r = int(d.getBitsNoMarkers(s))
        s = huffExtend(r, s)
        d.acCoeffs[comp].data[base + Zag[k]] = wrap16(s * (1 shl d.successiveLow))
      elif r == 15:
        k += 15
        if k > 63: return d.stopDecoding()
      else:
        d.eobRun = 1 shl r
        if r != 0: d.eobRun += int(d.getBitsNoMarkers(r))
        dec d.eobRun
        break
      inc k

proc decodeBlock*(d: JpegDecoder, kind: BlockKind, comp, bx, by: int): bool =
  case kind
  of DcFirst:
    let tab = d.compDcTab[comp]
    if not d.tableOk(tab): return d.stopDecoding()
    let p = coeffGetp(d.dcCoeffs[comp], bx, by)
    var s = d.huffDecode(d.huffTabs[tab])
    if s != 0: s = huffExtend(int(d.getBitsNoMarkers(s)), s)
    s += d.lastDcVal[comp]
    d.lastDcVal[comp] = s
    d.dcCoeffs[comp].data[p] = wrap16(s * (1 shl d.successiveLow))
    true
  of DcRefine:
    if d.getBitsNoMarkers(1) != 0:
      let p = coeffGetp(d.dcCoeffs[comp], bx, by)
      d.dcCoeffs[comp].data[p] = wrap16(int(d.dcCoeffs[comp].data[p]) or (1 shl d.successiveLow))
    true
  of AcFirst: d.decodeAcFirst(comp, bx, by)
  of AcRefine: d.decodeAcRefine(comp, bx, by)
