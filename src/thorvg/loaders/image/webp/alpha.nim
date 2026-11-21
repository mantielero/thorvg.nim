## `ALPH` chunk decoding. Ported from `dec/alpha.cpp` (`ALPHInit`, `ALPHDecode`,
## `VP8DecompressAlphaRows`) and `dec/alphai.h`.
##
## Upstream decodes the plane lazily in row batches while the VP8 rows are emitted; any error
## fails the whole picture ("Could not decode alpha data."), and the unfilter of a row only
## needs the rows above it, so decoding the full plane up front is equivalent.

from ./vp8l import decodeVp8lAlpha
import ./filters

const
  AlphaHeaderLen = 1
  AlphaNoCompression = 0
  AlphaLosslessCompression = 1
  AlphaPreprocessedLevels = 1

func alphaFilter*(header: byte): WebpFilter = WebpFilter((header shr 2) and 0x03)
  ## Filter type stored in bits 2..3 of the first `ALPH` byte.

proc decodeAlphaPlane*(data: openArray[byte], width, height: int): seq[byte] =
  ## `data` is the payload of the `ALPH` chunk (header byte included). Returns the unfiltered
  ## `width * height` plane, or an empty seq when the header is invalid, the data is too
  ## short or the lossless stream is corrupt.
  if width <= 0 or height <= 0 or data.len <= AlphaHeaderLen: return
  let meth = int(data[0] and 0x03)
  let preProcessing = int((data[0] shr 4) and 0x03)
  let reserved = int((data[0] shr 6) and 0x03)
  if meth < AlphaNoCompression or meth > AlphaLosslessCompression or
      preProcessing > AlphaPreprocessedLevels or reserved != 0:
    return
  if meth == AlphaNoCompression:
    let n = width * height
    if data.len - AlphaHeaderLen >= n:
      result = @(data.toOpenArray(AlphaHeaderLen, AlphaHeaderLen + n - 1))
  else:
    result = decodeVp8lAlpha(data.toOpenArray(AlphaHeaderLen, data.high), width, height)
  result.unfilter(width, height, alphaFilter(data[0]))
