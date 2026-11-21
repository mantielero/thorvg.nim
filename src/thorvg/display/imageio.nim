## Window-free image output: BMP, PPM and PNG writers plus a BMP reader.
##
## Surfaces are read through their color space (`RenderSurface.cs`): premultiplied
## colors are un-premultiplied for BMP/PNG (which store straight alpha). PPM has no
## alpha, so pixels are composited over black. PNG uses zlib "stored" blocks (no
## compression), which is valid and needs no deflate implementation.
##
## The `encode*` procs return the file contents as a `string` (a byte buffer).

import ../core/types
import ../renderer/render

type
  Rgba8* = tuple[r, g, b, a: uint8]

  ImageIoError* = object of CatchableError

# ---- pixel access -----------------------------------------------------------

proc rawChannels(s: RenderSurface, i: int): Rgba8 =
  ## Channels as stored (possibly premultiplied); alpha forced to 255 if opaque.
  if s.cs == ColorSpace.Grayscale8:
    let g = s.buf8[i]
    return (g, g, g, 255'u8)
  let p = s.data[i]
  let c0 = uint8((p shr 16) and 255)
  let c1 = uint8((p shr 8) and 255)
  let c2 = uint8(p and 255)
  let a = if s.opaque: 255'u8 else: uint8(p shr 24)
  case s.cs
  of ColorSpace.ARGB8888, ColorSpace.ARGB8888S: result = (c0, c1, c2, a)
  of ColorSpace.ABGR8888, ColorSpace.ABGR8888S: result = (c2, c1, c0, a)
  else: raise newException(ImageIoError, "unsupported color space: " & $s.cs)

func unpremul(c, a: uint8): uint8 =
  if a == 0: 0'u8
  elif a == 255: c
  else: uint8(min(255'u32, (uint32(c) * 255'u32 + uint32(a) div 2) div uint32(a)))

proc rgbaAt*(s: RenderSurface, x, y: int): Rgba8 =
  ## Straight (non-premultiplied) RGBA of pixel (x, y).
  result = s.rawChannels(y * int(s.stride) + x)
  if s.premultiplied and not s.opaque:
    result = (unpremul(result.r, result.a), unpremul(result.g, result.a),
              unpremul(result.b, result.a), result.a)

proc rgbOverBlack*(s: RenderSurface, x, y: int): Rgba8 =
  ## RGB of pixel (x, y) composited over black; alpha is returned as 255.
  var p = s.rawChannels(y * int(s.stride) + x)
  if not s.premultiplied and p.a != 255:
    let a = uint32(p.a)
    p = (uint8((uint32(p.r) * a + 127) div 255), uint8((uint32(p.g) * a + 127) div 255),
         uint8((uint32(p.b) * a + 127) div 255), p.a)
  result = (p.r, p.g, p.b, 255'u8)

proc checkSurface(s: RenderSurface) =
  if s == nil or s.w == 0 or s.h == 0:
    raise newException(ImageIoError, "empty surface")
  if s.cs == ColorSpace.Grayscale8:
    if s.buf8.len < int(s.stride) * int(s.h):
      raise newException(ImageIoError, "surface buffer too small")
  elif s.data.len < int(s.stride) * int(s.h):
    raise newException(ImageIoError, "surface buffer too small")

# ---- byte helpers -----------------------------------------------------------

func addLe16(b: var string, v: int) =
  b.add char(v and 255)
  b.add char((v shr 8) and 255)

func addLe32(b: var string, v: uint32) =
  for i in 0..3: b.add char((v shr (8 * i)) and 255'u32)

func addBe32(b: var string, v: uint32) =
  for i in countdown(3, 0): b.add char((v shr (8 * i)) and 255'u32)

func rdLe16(b: string, o: int): int = int(uint8(b[o])) or (int(uint8(b[o + 1])) shl 8)

func rdLe32(b: string, o: int): uint32 =
  for i in 0..3: result = result or (uint32(uint8(b[o + i])) shl (8 * i))

# ---- BMP --------------------------------------------------------------------

proc encodeBmp*(s: RenderSurface): string =
  ## 32-bit BGRA, bottom-up, BITMAPINFOHEADER, straight alpha.
  checkSurface(s)
  let w = int(s.w)
  let h = int(s.h)
  let size = w * h * 4
  result = newStringOfCap(54 + size)
  result.add "BM"
  result.addLe32 uint32(54 + size)
  result.addLe32 0
  result.addLe32 54
  result.addLe32 40
  result.addLe32 uint32(w)
  result.addLe32 uint32(h)
  result.addLe16 1
  result.addLe16 32
  result.addLe32 0
  result.addLe32 uint32(size)
  result.addLe32 2835
  result.addLe32 2835
  result.addLe32 0
  result.addLe32 0
  for y in countdown(h - 1, 0):
    for x in 0..<w:
      let p = s.rgbaAt(x, y)
      result.add char(p.b)
      result.add char(p.g)
      result.add char(p.r)
      result.add char(p.a)

proc decodeBmp*(data: string): RenderSurface =
  ## Reads uncompressed 24/32-bit BMP data. Returns a straight-alpha ARGB8888S
  ## surface (24-bit images are opaque). Raises `ImageIoError` otherwise.
  if data.len < 54 or data[0] != 'B' or data[1] != 'M':
    raise newException(ImageIoError, "not a BMP file")
  let offset = int(rdLe32(data, 10))
  let hdr = int(rdLe32(data, 14))
  let w = int(int32(rdLe32(data, 18)))
  let hRaw = int(int32(rdLe32(data, 22)))
  let bpp = rdLe16(data, 28)
  if hdr < 40 or rdLe32(data, 30) != 0 or (bpp != 24 and bpp != 32) or w <= 0 or hRaw == 0:
    raise newException(ImageIoError, "unsupported BMP variant")
  let h = abs(hRaw)
  let rowBytes = ((w * bpp + 31) div 32) * 4
  if offset < 0 or offset + rowBytes * h > data.len:
    raise newException(ImageIoError, "truncated BMP")
  result = newSurface(uint32(w), uint32(h), ColorSpace.ARGB8888S)
  let step = bpp div 8
  for y in 0..<h:
    let row = if hRaw > 0: h - 1 - y else: y
    for x in 0..<w:
      let o = offset + row * rowBytes + x * step
      let a = if bpp == 32: uint32(uint8(data[o + 3])) else: 255'u32
      result.data[y * w + x] = (a shl 24) or (uint32(uint8(data[o + 2])) shl 16) or
        (uint32(uint8(data[o + 1])) shl 8) or uint32(uint8(data[o]))

# ---- PPM --------------------------------------------------------------------

proc encodePpm*(s: RenderSurface): string =
  ## Binary PPM (P6); pixels composited over black.
  checkSurface(s)
  result = "P6\n" & $s.w & " " & $s.h & "\n255\n"
  for y in 0..<int(s.h):
    for x in 0..<int(s.w):
      let p = s.rgbOverBlack(x, y)
      result.add char(p.r)
      result.add char(p.g)
      result.add char(p.b)

# ---- PNG --------------------------------------------------------------------

func makeCrcTable(): array[256, uint32] =
  for n in 0..255:
    var c = uint32(n)
    for _ in 0..7:
      c = if (c and 1'u32) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
    result[n] = c

const CrcTable = makeCrcTable()

func crc32*(data: string, init: uint32 = 0): uint32 =
  ## CRC-32 (IEEE, as used by PNG); `init` is a previous result for chaining.
  var c = init xor 0xFFFFFFFF'u32
  for ch in data: c = CrcTable[int((c xor uint32(uint8(ch))) and 255'u32)] xor (c shr 8)
  result = c xor 0xFFFFFFFF'u32

func adler32*(data: string): uint32 =
  var a = 1'u32
  var b = 0'u32
  for ch in data:
    a = (a + uint32(uint8(ch))) mod 65521'u32
    b = (b + a) mod 65521'u32
  result = (b shl 16) or a

proc addChunk(png: var string, kind, body: string) =
  png.addBe32 uint32(body.len)
  png.add kind
  png.add body
  png.addBe32 crc32(body, crc32(kind))

proc encodePng*(s: RenderSurface): string =
  ## RGBA 8-bit PNG with zlib stored blocks and straight alpha.
  checkSurface(s)
  let w = int(s.w)
  let h = int(s.h)
  var raw = newStringOfCap((w * 4 + 1) * h)
  for y in 0..<h:
    raw.add '\0'                   # filter type: none
    for x in 0..<w:
      let p = s.rgbaAt(x, y)
      raw.add char(p.r)
      raw.add char(p.g)
      raw.add char(p.b)
      raw.add char(p.a)
  var z = "\x78\x01"
  var pos = 0
  while pos < raw.len:
    let n = min(65535, raw.len - pos)
    z.add (if pos + n == raw.len: '\1' else: '\0')
    z.addLe16 n
    z.addLe16 (n xor 0xFFFF)
    z.add raw.substr(pos, pos + n - 1)
    pos += n
  z.addBe32 adler32(raw)
  var ihdr = ""
  ihdr.addBe32 uint32(w)
  ihdr.addBe32 uint32(h)
  ihdr.add "\x08\x06\0\0\0"        # 8 bit, RGBA, deflate, adaptive filter, no interlace
  result = "\x89PNG\r\n\x1A\n"
  result.addChunk("IHDR", ihdr)
  result.addChunk("IDAT", z)
  result.addChunk("IEND", "")

# ---- files ------------------------------------------------------------------

proc writeBmp*(path: string, s: RenderSurface) = writeFile(path, encodeBmp(s))
proc writePpm*(path: string, s: RenderSurface) = writeFile(path, encodePpm(s))
proc writePng*(path: string, s: RenderSurface) = writeFile(path, encodePng(s))
proc readBmp*(path: string): RenderSurface = decodeBmp(readFile(path))
