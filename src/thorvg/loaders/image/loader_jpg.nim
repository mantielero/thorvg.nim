## JPEG image loader (`JpgLoader` of `tvgJpgLoader.cpp`, static jpgd flavour).
##
## Importing this module registers the loader for `FileType.Jpg` (extensions `.jpg`,
## `.jpeg`; header sniffing on the SOI marker `FF D8`). The bitmap is opaque
## `ColorSpace.XBGR8888` (RGBA bytes, alpha 255) like the C++ loader. Decoding is
## synchronous (no task scheduler, D4) and runs on the first `read()`; a decode failure
## leaves `bitmap()` empty and `read()` still true.

import ../../core/types
import ../../renderer/[render, loader]
import ./[jpgd, jpgd_bits]

type JpgLoader* = ref object of BitmapLoader
  decoder: JpegDecoder

proc newJpgLoader*(): JpgLoader = JpgLoader(kind: FileType.Jpg)

method openData*(l: JpgLoader, data: string, ops: LoaderOps): Result =
  let d = jpgdHeader(data)
  if d == nil: return Result.InvalidArguments
  l.decoder = d
  l.w = float32(d.imageX)
  l.h = float32(d.imageY)
  Result.Success

method read*(l: JpgLoader): bool =
  if not l.baseRead(): return true
  if l.decoder == nil or l.w == 0.0'f32 or l.h == 0.0'f32: return false
  let pixels = jpgdDecompress(l.decoder)
  if pixels.len > 0:
    let surface = newSurface(uint32(l.w), uint32(l.h), ColorSpace.XBGR8888)
    surface.data = pixels
    l.surface = surface
  l.decoder = nil
  true

method close*(l: JpgLoader): bool =
  if not l.baseClose(): return false
  l.decoder = nil
  true

proc sniffJpg(data: string): bool =
  data.len >= 2 and data[0] == '\xFF' and data[1] == '\xD8'

registerLoader(FileType.Jpg, proc (): Loader = newJpgLoader(), sniffJpg)
