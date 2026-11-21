## WebP image loader (`WebpLoader` of the static `tvgWebpLoader.cpp`).
##
## Importing this module registers the loader for `FileType.Webp` (extension `.webp`, header
## sniffing on `RIFF....WEBP`). Opening only parses the features (size, alpha); the pixels
## are decoded on the first `read()`. Like the C++ loader the bitmap is PREMULTIPLIED: BGRA
## bytes (`ARGB8888`) when the canvas wants ARGB8888/ARGB8888S, RGBA bytes (`ABGR8888`)
## otherwise, and opaque (`X*8888`) when the file announces no alpha. Decoding is synchronous
## (no task scheduler, D4); a decode failure leaves `bitmap()` empty and `read()` still true.

import std/strutils
import ../../core/types
import ../../renderer/[render, loader]
import ./webp/decode

type WebpLoader* = ref object of BitmapLoader
  data: string
  opaque: bool

proc newWebpLoader*(): WebpLoader = WebpLoader(kind: FileType.Webp)

method openData*(l: WebpLoader, data: string, ops: LoaderOps): Result =
  var features: WebpFeatures
  if getFeatures(data.toOpenArrayByte(0, data.high), features) != vsOk:
    return Result.InvalidArguments
  l.data = data
  l.w = float32(features.width)
  l.h = float32(features.height)
  l.opaque = not features.hasAlpha
  Result.Success

method read*(l: WebpLoader): bool =
  if not l.baseRead(): return true
  if l.data.len == 0 or l.w == 0.0'f32 or l.h == 0.0'f32: return false
  # the static decoders return premultiplied pixels
  let cs = desiredColorSpace()
  let bgra = cs == ColorSpace.ARGB8888 or cs == ColorSpace.ARGB8888S
  let surfaceCs =
    if bgra: (if l.opaque: ColorSpace.XRGB8888 else: ColorSpace.ARGB8888)
    else: (if l.opaque: ColorSpace.XBGR8888 else: ColorSpace.ABGR8888)
  var w, h = 0
  template bytes(): untyped = l.data.toOpenArrayByte(0, l.data.high)
  let pixels = if bgra: webpDecodeBgra(bytes, w, h) else: webpDecodeRgba(bytes, w, h)
  if pixels.len > 0:
    let surface = newSurface(uint32(l.w), uint32(l.h), surfaceCs)
    surface.data = pixels
    l.surface = surface
  l.data = ""
  true

method close*(l: WebpLoader): bool =
  if not l.baseClose(): return false
  l.data = ""
  true

proc sniffWebp(data: string): bool =
  data.len >= 12 and data.startsWith("RIFF") and data.continuesWith("WEBP", 8)

registerLoader(FileType.Webp, proc (): Loader = newWebpLoader(), sniffWebp)
