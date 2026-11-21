## Alpha processing helpers of the WebP output stage. Ported from `dsp/alpha_processing.cpp`
## (`DispatchAlpha`, `ApplyAlphaMultiply`) as used by `EmitAlphaRGB` in `dec/io.cpp`.
##
## Pixel words follow the lossy decoder: little-endian `R | G << 8 | B << 16 | A << 24`
## (or `B | G << 8 | R << 16 | A << 24`); the alpha byte is always the top byte, so the same
## code serves both channel orders.

func hasNonTrivialAlpha*(plane: openArray[byte]): bool =
  ## The return value of `WebPDispatchAlpha`: some alpha byte differs from 0xff, i.e. the
  ## premultiplication has something to do.
  for a in plane:
    if a != 0xff: return true

func premultiply(x, mult: uint32): uint32 {.inline.} =
  ## `PREMULTIPLY(x, m)`: `(x * a * 32897) >> 23` equals `int(x * a / 255.)` for 8-bit x, a.
  (x * mult) shr 23

func applyAlphaMultiply*(pixels: var openArray[uint32]) =
  ## `ApplyAlphaMultiply` on a whole picture: colour channels times alpha / 255 (truncated);
  ## pixels with alpha 0xff are untouched.
  for p in pixels.mitems:
    let a = p shr 24
    if a != 0xff:
      let mult = a * 32897'u32
      p = (a shl 24) or (premultiply((p shr 16) and 0xff, mult) shl 16) or
        (premultiply((p shr 8) and 0xff, mult) shl 8) or premultiply(p and 0xff, mult)

func dispatchAlpha*(pixels: var openArray[uint32], plane: openArray[byte]): bool =
  ## `DispatchAlpha`: stores the alpha plane in the top byte of every pixel and tells whether
  ## the alpha is non trivial (`has_alpha`).
  result = hasNonTrivialAlpha(plane)
  for i in 0 ..< min(pixels.len, plane.len):
    pixels[i] = (pixels[i] and 0x00ffffff'u32) or (uint32(plane[i]) shl 24)
