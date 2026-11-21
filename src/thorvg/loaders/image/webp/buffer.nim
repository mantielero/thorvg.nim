## Output buffer of the WebP decoder. Ported from `dec/buffer.cpp` for what ThorVG uses:
## only the premultiplied 32-bit `MODE_rgbA` / `MODE_bgrA` colour spaces exist and the
## decoder always allocates its own storage (no external buffers, no stride tricks).

from ./vp8 import Vp8Status
from ./vp8l import MaxPixels

type
  WebpMode* = enum
    modeRgbA, modeBgrA   ## `MODE_rgbA` (bytes R,G,B,A) and `MODE_bgrA` (bytes B,G,R,A)

  DecBuffer* = object
    ## `WebPDecBuffer`: `pixels` holds `width * height` little-endian words (byte order as in
    ## the mode name), premultiplied.
    mode*: WebpMode
    width*, height*: int
    pixels*: seq[uint32]

proc allocateDecBuffer*(buf: var DecBuffer, width, height: int): Vp8Status =
  ## `WebPAllocateDecBuffer`: invalid dimensions are `vsInvalidParam`; pictures above
  ## `MaxPixels` are `vsOutOfMemory` (upstream would just call malloc, D-L5cC-3).
  if width <= 0 or height <= 0: return vsInvalidParam
  if width * height > MaxPixels: return vsOutOfMemory
  buf.width = width
  buf.height = height
  buf.pixels = @[]   # filled by the decoder, which returns its own storage
  vsOk

proc freeDecBuffer*(buf: var DecBuffer) =
  ## `WebPFreeDecBuffer`.
  buf.pixels = @[]
