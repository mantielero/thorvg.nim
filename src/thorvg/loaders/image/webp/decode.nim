## Top-level WebP decoding: `WebPDecodeBGRA` / `WebPDecodeRGBA` of `dec/webp.cpp`
## (`Decode`, `DecodeInto`) glued to the container parser, the alpha plane and the VP8 / VP8L
## decoders.
##
## The result is what ThorVG's static loader gets: premultiplied pixels, one word each
## (`modeBgrA` = bytes B,G,R,A = `ARGB8888`, `modeRgbA` = bytes R,G,B,A = `ABGR8888`).
## The VP8/VP8L decoders receive the data from the payload start to the END of the buffer,
## exactly like upstream's `io.data_size = headers.data_size - headers.offset`.

from ./vp8 import Vp8Status, decodeVp8Ex
from ./vp8l import decodeVp8l
import ./[alpha, alpha_proc, buffer, container]

export Vp8Status, WebpMode, DecBuffer, WebpFeatures, getFeatures

proc decodeInto*(data: openArray[byte], output: var DecBuffer): Vp8Status =
  ## `DecodeInto`: fills `output.pixels` (`output.mode` selects the byte order).
  var hdr: WebpHeaders
  result = parseHeaders(data, hdr)
  if result != vsOk: return
  template payload(): untyped = data.toOpenArray(hdr.offset, data.high)
  let bgra = output.mode == modeBgrA
  result = allocateDecBuffer(output, hdr.width, hdr.height)
  if result != vsOk: return
  if not hdr.isLossless:
    var plane: seq[byte]
    if hdr.hasAlphaChunk:
      plane = decodeAlphaPlane(
        data.toOpenArray(hdr.alphaOffset, hdr.alphaOffset + hdr.alphaSize - 1),
        hdr.width, hdr.height)
      if plane.len == 0: result = vsBitstreamError   # "Could not decode alpha data."
      elif not hasNonTrivialAlpha(plane): plane = @[]  # nothing to premultiply
    if result == vsOk:
      var w, h = 0
      result = decodeVp8Ex(payload, w, h, output.pixels, plane, bgra)
  else:
    var w, h = 0
    var hasAlpha = false
    output.pixels = decodeVp8l(payload, w, h, hasAlpha, abgr = not bgra)
    if output.pixels.len == 0: result = vsBitstreamError
  if result != vsOk: freeDecBuffer(output)

proc webpDecode*(data: openArray[byte], mode: WebpMode, width, height: var int): seq[uint32] =
  ## `Decode`: empty seq on any failure. `width`/`height` are set from the features first
  ## (like upstream) as soon as they are known.
  var features: WebpFeatures
  if getFeatures(data, features) != vsOk: return
  width = features.width
  height = features.height
  var output = DecBuffer(mode: mode)
  if decodeInto(data, output) == vsOk: result = move output.pixels

proc webpDecodeBgra*(data: openArray[byte], width, height: var int): seq[uint32] =
  ## `WebPDecodeBGRA`.
  webpDecode(data, modeBgrA, width, height)

proc webpDecodeRgba*(data: openArray[byte], width, height: var int): seq[uint32] =
  ## `WebPDecodeRGBA`.
  webpDecode(data, modeRgbA, width, height)
