## VP8 frame header parsing: frame/picture header, segment header, filter header, partitions.
##
## Ported from `src/modules/webp/static/dec/vp8.cpp` (`VP8GetInfo`, `VP8GetHeaders`).

import ./[vp8_bits, vp8_quant, vp8_tree, vp8_types]

func checkSignature(data: openArray[byte], start: int): bool =
  data.len - start >= 3 and data[start] == 0x9d and data[start + 1] == 0x01 and
    data[start + 2] == 0x2a

proc vp8GetInfo*(data: openArray[byte], chunkSize: int, width, height: var int): bool =
  ## `VP8GetInfo`: validates the 10-byte frame header of a key frame and returns its size.
  ## `chunkSize` is the size of the VP8 chunk payload (the partition length must be below it).
  if data.len < FrameHeaderSize or not checkSignature(data, 3): return false
  let bits = int(data[0]) or (int(data[1]) shl 8) or (int(data[2]) shl 16)
  let keyFrame = (bits and 1) == 0
  let w = ((int(data[7]) shl 8) or int(data[6])) and 0x3fff
  let h = ((int(data[9]) shl 8) or int(data[8])) and 0x3fff
  if not keyFrame: return false
  if ((bits shr 1) and 7) > 3: return false         # unknown profile
  if ((bits shr 4) and 1) == 0: return false        # first frame is invisible
  if (bits shr 5) >= chunkSize: return false        # inconsistent size information
  if w == 0 or h == 0: return false
  width = w
  height = h
  true

proc parseSegmentHeader(dec: Vp8Decoder): bool =
  ## Paragraph 9.3
  template hdr(): untyped = dec.segmentHdr
  hdr.useSegment = dec.br.get() != 0
  if hdr.useSegment:
    hdr.updateMap = dec.br.get() != 0
    if dec.br.get() != 0:   # update data
      hdr.absoluteDelta = dec.br.get() != 0
      for s in 0 ..< NumMbSegments:
        hdr.quantizer[s] = if dec.br.get() != 0: dec.br.getSignedValue(7) else: 0
      for s in 0 ..< NumMbSegments:
        hdr.filterStrength[s] = if dec.br.get() != 0: dec.br.getSignedValue(6) else: 0
    if hdr.updateMap:
      for s in 0 ..< 3:
        dec.segmentProbas[s] = if dec.br.get() != 0: dec.br.getValue(8) else: 255
  else:
    hdr.updateMap = false
  not dec.br.eof

proc parsePartitions(dec: Vp8Decoder, data: openArray[byte], start: int): Vp8Status =
  ## Paragraph 9.5. `start` is the offset just after partition 0. The last partition runs
  ## to the end of `data`.
  dec.numParts = 1 shl dec.br.getValue(2)
  let lastPart = dec.numParts - 1
  var partStart = start + lastPart * 3
  if data.len < partStart: return vsNotEnoughData   # cannot even read the sizes
  var sz = start
  for p in 0 ..< lastPart:
    let psize = int(data[sz]) or (int(data[sz + 1]) shl 8) or (int(data[sz + 2]) shl 16)
    let partEnd = min(partStart + psize, data.len)
    dec.parts[p] = initBitReader(data[partStart ..< partEnd])
    partStart = partEnd
    sz += 3
  dec.parts[lastPart] = initBitReader(data[partStart ..< data.len])
  if partStart < data.len: vsOk else: vsSuspended

proc parseFilterHeader(dec: Vp8Decoder): bool =
  ## Paragraph 9.4
  template hdr(): untyped = dec.filterHdr
  hdr.simple = dec.br.get() != 0
  hdr.level = dec.br.getValue(6)
  hdr.sharpness = dec.br.getValue(3)
  hdr.useLfDelta = dec.br.get() != 0
  if hdr.useLfDelta and dec.br.get() != 0:   # update lf-delta?
    for i in 0 ..< NumRefLfDeltas:
      if dec.br.get() != 0: hdr.refLfDelta[i] = dec.br.getSignedValue(6)
    for i in 0 ..< NumModeLfDeltas:
      if dec.br.get() != 0: hdr.modeLfDelta[i] = dec.br.getSignedValue(6)
  dec.filterType = if hdr.level == 0: 0 elif hdr.simple: 1 else: 2
  not dec.br.eof

proc getHeaders*(dec: Vp8Decoder, data: openArray[byte]): bool =
  ## `VP8GetHeaders`: parses everything up to the first macroblock. On success
  ## `dec.ready` is set and `dec.pic` holds the picture size.
  dec.status = vsOk
  dec.errorMsg = "OK"
  if data.len < 4: return dec.setError(vsNotEnoughData, "Truncated header.")
  var pos = 0
  let bits = int(data[0]) or (int(data[1]) shl 8) or (int(data[2]) shl 16)
  dec.frm = Vp8FrameHeader(keyFrame: (bits and 1) == 0, profile: (bits shr 1) and 7,
    show: ((bits shr 4) and 1) != 0, partitionLength: bits shr 5)
  if dec.frm.profile > 3: return dec.setError(vsBitstreamError, "Incorrect keyframe parameters.")
  if not dec.frm.show: return dec.setError(vsUnsupportedFeature, "Frame not displayable.")
  pos += 3
  if dec.frm.keyFrame:
    if data.len - pos < 7: return dec.setError(vsNotEnoughData, "cannot parse picture header")
    if not checkSignature(data, pos): return dec.setError(vsBitstreamError, "Bad code word")
    dec.pic.width = ((int(data[pos + 4]) shl 8) or int(data[pos + 3])) and 0x3fff
    dec.pic.xscale = int(data[pos + 4]) shr 6
    dec.pic.height = ((int(data[pos + 6]) shl 8) or int(data[pos + 5])) and 0x3fff
    dec.pic.yscale = int(data[pos + 6]) shr 6
    pos += 7
    dec.mbW = (dec.pic.width + 15) shr 4
    dec.mbH = (dec.pic.height + 15) shr 4
    dec.resetProba()
    dec.segmentHdr = Vp8SegmentHeader(absoluteDelta: true)
  if dec.frm.partitionLength > data.len - pos:
    return dec.setError(vsNotEnoughData, "bad partition length")
  dec.br = initBitReader(data[pos ..< pos + dec.frm.partitionLength])
  pos += dec.frm.partitionLength
  if dec.frm.keyFrame:
    dec.pic.colorspace = dec.br.get()
    dec.pic.clampType = dec.br.get()
  if not dec.parseSegmentHeader():
    return dec.setError(vsBitstreamError, "cannot parse segment header")
  if not dec.parseFilterHeader():
    return dec.setError(vsBitstreamError, "cannot parse filter header")
  let status = dec.parsePartitions(data, pos)
  if status != vsOk: return dec.setError(status, "cannot parse partitions")
  dec.parseQuant()
  if not dec.frm.keyFrame: return dec.setError(vsUnsupportedFeature, "Not a key frame.")
  discard dec.br.get()   # ignore the value of update_proba_
  dec.parseProba()
  dec.ready = true
  true
