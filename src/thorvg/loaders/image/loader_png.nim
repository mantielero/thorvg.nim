## PNG image loader (`PngLoader` of `tvgPngLoader.cpp`, static lodepng flavour).
##
## Importing this module registers the loader for `FileType.Png` (extension `.png`,
## header sniffing on the PNG signature). The decoded bitmap is straight-alpha
## `ColorSpace.ABGR8888S` like the C++ loader; the renderer converts / premultiplies it
## when preparing the image. Decoding is synchronous (no task scheduler, D4) and runs on
## the first `read()`; a decode failure leaves `bitmap()` empty and `read()` still true.

import std/strutils
import ../../core/types
import ../../renderer/[render, loader]
import ./png

type PngLoader* = ref object of BitmapLoader
  data: string

proc newPngLoader*(): PngLoader = PngLoader(kind: FileType.Png)

method openData*(l: PngLoader, data: string, ops: LoaderOps): Result =
  var w, h = 0
  if pngInspect(data.toOpenArrayByte(0, data.high), w, h) != 0:
    return Result.InvalidArguments
  l.data = data
  l.w = float32(w)
  l.h = float32(h)
  Result.Success

func pack(rgba: openArray[byte], i: int): uint32 =
  ## Bytes R,G,B,A in memory = ABGR8888 as a little-endian word.
  uint32(rgba[i]) or (uint32(rgba[i + 1]) shl 8) or (uint32(rgba[i + 2]) shl 16) or
    (uint32(rgba[i + 3]) shl 24)

method read*(l: PngLoader): bool =
  if l.data.len == 0 or l.w == 0.0'f32 or l.h == 0.0'f32: return false
  if not l.baseRead(): return true
  var image: PngImage
  if pngDecode(l.data.toOpenArrayByte(0, l.data.high), image) == 0:
    let surface = newSurface(uint32(image.width), uint32(image.height), ColorSpace.ABGR8888S)
    for i in 0 ..< image.width * image.height: surface.data[i] = pack(image.rgba, i * 4)
    l.surface = surface
  true

proc sniffPng(data: string): bool =
  data.len >= PngSignature.len and data.startsWith(PngSignature)

registerLoader(FileType.Png, proc (): Loader = newPngLoader(), sniffPng)
