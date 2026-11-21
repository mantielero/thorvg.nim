## WebP lossy (VP8 key frame) decoder: public API.
##
## Ported from `src/modules/webp/static/dec/vp8.cpp` (`VP8Decode`, `ParseFrame`) and the
## lossy path of `dec/webp.cpp`. The output is bit-exact with the C++ decoder.
##
## **Input.** `data` is the VP8 chunk payload *starting at the 10-byte frame header* and
## running to the END of the file buffer (not only to the end of the chunk): the last token
## partition extends to the end of `data`, exactly as upstream does with `io.data_size`.
## The RIFF container and the `ALPH` chunk are handled by the caller (L5c-C).
##
## **Output.** `width * height` words, premultiplied, with the same word layout as the
## PNG loader: for `bgra == false` the bytes in memory are R, G, B, A (word =
## `R | G << 8 | B << 16 | A << 24`); for `bgra == true` they are B, G, R, A. `alpha`,
## when not empty, must hold `width * height` bytes (one per pixel, row by row; the
## dimensions are those returned in `width`/`height`) and is merged and premultiplied.
## Without it the alpha channel is 255.
##
## Failures (corrupt, truncated or unsupported data) return an empty seq, never raise.

import ./[vp8_frame, vp8_hdr, vp8_resid, vp8_tree, vp8_types, vp8_yuv]

export Vp8Status, vp8GetInfo

proc parseFrame(dec: Vp8Decoder): bool =
  ## `ParseFrame`: decodes every macroblock row and reconstructs/filters it.
  dec.mbY = 0
  while dec.mbY < dec.mbH:
    let tokenIdx = dec.mbY and (dec.numParts - 1)
    if not dec.parseIntraModeRow():
      return dec.setError(vsNotEnoughData, "Premature end-of-partition0 encountered.")
    while dec.mbX < dec.mbW:
      if not dec.decodeMB(tokenIdx):
        return dec.setError(vsNotEnoughData, "Premature end-of-file encountered.")
      inc dec.mbX
    dec.initScanline()
    dec.reconstructRow()
    if dec.filterType > 0: dec.filterRow()
    inc dec.mbY
  true

proc decodeVp8Ex*(data: openArray[byte], width, height: var int, pixels: var seq[uint32],
                  alpha: openArray[byte] = [], bgra = false): Vp8Status =
  ## Like `decodeVp8` but reports the failure reason (`vsOk` on success).
  pixels = @[]
  var w, h: int
  if not vp8GetInfo(data, data.len, w, h): return vsBitstreamError
  let dec = newVp8Decoder()
  if not dec.getHeaders(data): return dec.status
  if dec.pic.width * dec.pic.height > MaxPixels: return vsOutOfMemory
  if alpha.len > 0 and alpha.len < dec.pic.width * dec.pic.height: return vsInvalidParam
  dec.initFrame()
  dec.initScanline()
  if not dec.parseFrame(): return dec.status
  width = dec.pic.width
  height = dec.pic.height
  pixels = dec.toPixels(width, height, alpha, bgra)
  vsOk

proc decodeVp8*(data: openArray[byte], width, height: var int, alpha: openArray[byte] = [],
                bgra = false): seq[uint32] =
  ## Decodes a lossy WebP frame; see the module documentation. Returns an empty seq on
  ## failure.
  if decodeVp8Ex(data, width, height, result, alpha, bgra) != vsOk: result = @[]
