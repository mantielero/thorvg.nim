## GIF container decoder and frame compositor (`GifDecoder` of `tvgGifDecoder.cpp`).
##
## `load` parses every block up front into `frames` (palette-resolved 32-bit pixels of each
## image rectangle, with the GCE delay / disposal / transparency). The canvas is NOT held
## by the decoder: `compositeFrame` draws into a caller-owned `output` (width * height
## pixels), so a loader can share it with its `RenderSurface`.
##
## Pixel format: `0xAARRGGBB` (ColorSpace.ARGB8888) or `0xAABBGGRR` (ABGR8888); every pixel
## is either opaque or 0, so premultiplication is the identity.
## Deviations: a logical screen or frame larger than `MaxPixels` fails to load (the C++
## would try to `malloc` it); sizes below that behave exactly as the original.

import ../../core/types
import ./gif_lzw

const
  ExtensionIntroducer = 0x21'u8
  ImageSeparator = 0x2C'u8
  Trailer = 0x3B'u8
  ExtensionGce = 0xF9'u8
  DisposalBackground* = 2'u8
  DisposalPrevious* = 3'u8
  MaxPixels = 1 shl 28

type
  GifFrame* = object
    pixels*: seq[uint32]
    delay*: uint16               ## 1/100 s
    left*, top*, width*, height*: uint16
    disposal*: uint8
    transparentIndex*: uint8
    transparent*: bool

  GifDecoder* = object
    data: string
    pos: int
    width*, height*: uint32
    frames*: seq[GifFrame]
    gPalette: seq[uint8]         ## global palette (r, g, b triplets); empty = none
    cs*: ColorSpace              ## ARGB8888 or ABGR8888

func readByte(d: var GifDecoder): uint8 =
  if d.pos < d.data.len:
    result = uint8(d.data[d.pos])
    inc d.pos

func readWord(d: var GifDecoder): uint16 =
  let low = uint16(d.readByte())
  let high = uint16(d.readByte())
  low or (high shl 8)

func readColorTable(d: var GifDecoder, packed: uint8): seq[uint8] =
  ## The palette announced by `packed` (empty when the table flag is clear).
  if (packed and 0x80) == 0: return @[]
  let size = 1 shl ((packed and 0x07) + 1)
  result = newSeq[uint8](size * 3)
  for i in 0 ..< size * 3: result[i] = d.readByte()

func skipExtension(d: var GifDecoder) =
  var more = true
  while more and d.pos < d.data.len:
    let blockSize = int(d.data[d.pos])
    inc d.pos
    if blockSize == 0 or blockSize > d.data.len - d.pos: more = false
    else: d.pos += blockSize

func readGce(d: var GifDecoder, pending: var GifFrame): bool =
  if d.readByte() != 4: return false  # the GCE block size is always 4
  let packed = d.readByte()
  pending.disposal = (packed shr 2) and 0x07
  pending.transparent = (packed and 0x01) != 0
  pending.delay = d.readWord()
  pending.transparentIndex = d.readByte()
  discard d.readByte()  # block terminator
  true

func readImageData(d: var GifDecoder, ok: var bool): seq[uint8] =
  ## Concatenates the length-prefixed sub-blocks up to the zero-sized terminator.
  ok = true
  var blockSize = int(d.readByte())
  while ok and blockSize != 0:
    if blockSize > d.data.len - d.pos:
      ok = false
    else:
      for i in 0 ..< blockSize: result.add uint8(d.data[d.pos + i])
      d.pos += blockSize
      blockSize = int(d.readByte())

func deinterlace(pixels: seq[uint8], width, height: int): seq[uint8] =
  ## GIF stores interlaced frames in 4 passes (image descriptor bit 0x40).
  const istart = [0, 4, 2, 1]
  const istep = [8, 8, 4, 2]
  result = newSeq[uint8](width * height)
  var srcRow = 0
  for p in 0 ..< 4:
    var y = istart[p]
    while y < height:
      for x in 0 ..< width: result[y * width + x] = pixels[srcRow * width + x]
      inc srcRow
      y += istep[p]

func indexToPixels(d: GifDecoder, frame: var GifFrame, pixels, palette: seq[uint8]) =
  var colors: array[256, uint32]
  let abgr = d.cs == ColorSpace.ABGR8888
  for i in 0 ..< min(palette.len div 3, 256):
    var r = uint32(palette[i * 3])
    let g = uint32(palette[i * 3 + 1])
    var b = uint32(palette[i * 3 + 2])
    if abgr: swap(r, b)
    colors[i] = 0xFF000000'u32 or b or (g shl 8) or (r shl 16)
  if frame.transparent: colors[frame.transparentIndex] = 0
  frame.pixels = newSeq[uint32](pixels.len)
  for i in 0 ..< pixels.len: frame.pixels[i] = colors[pixels[i]]

func readImageFrame(d: var GifDecoder, frame: var GifFrame): bool =
  frame.left = d.readWord()
  frame.top = d.readWord()
  frame.width = d.readWord()
  frame.height = d.readWord()
  let packed = d.readByte()
  let pixelCnt = int(frame.width) * int(frame.height)
  let localPalette = d.readColorTable(packed)
  let palette = if localPalette.len > 0: localPalette else: d.gPalette
  if palette.len == 0 or pixelCnt > MaxPixels: return false
  let minCodeSize = int(d.readByte())
  var ok = false
  let image = d.readImageData(ok)
  if not ok: return false
  var pixels = newSeq[uint8](pixelCnt)
  if lzwDecode(image, pixels, minCodeSize) != pixelCnt: return false
  if (packed and 0x40) != 0: pixels = deinterlace(pixels, int(frame.width), int(frame.height))
  d.indexToPixels(frame, pixels, palette)
  true

func parseBlocks(d: var GifDecoder): bool =
  var pending = GifFrame()
  var running = true
  result = true
  while result and running and d.pos < d.data.len:
    let marker = d.readByte()
    if marker == ExtensionIntroducer:
      let label = d.readByte()
      if label == ExtensionGce: result = d.readGce(pending)
      elif d.pos < d.data.len: d.skipExtension()
      else: running = false
    elif marker == ImageSeparator:
      d.frames.add pending
      pending = GifFrame()
      result = d.readImageFrame(d.frames[^1])
    elif marker == Trailer:
      running = false

func gifLoad*(d: var GifDecoder, data: string, cs: ColorSpace): bool =
  ## Parses `data`; false for a bad header, a broken block or no frame at all.
  if data.len < 13: return false  # smaller than a header + logical screen descriptor
  d = GifDecoder(data: data)
  d.cs = if cs in {ColorSpace.ARGB8888, ColorSpace.ARGB8888S, ColorSpace.XRGB8888}:
           ColorSpace.ARGB8888
         else: ColorSpace.ABGR8888
  let sig = data[0 .. 5]
  if data[0 .. 2] != "GIF" or (sig[3 .. 5] != "87a" and sig[3 .. 5] != "89a"): return false
  d.pos = 6
  d.width = uint32(d.readWord())
  d.height = uint32(d.readWord())
  let packed = d.readByte()
  discard d.readByte()  # background color index
  discard d.readByte()  # pixel aspect ratio
  d.gPalette = d.readColorTable(packed)
  result = int(d.width) * int(d.height) <= MaxPixels and d.parseBlocks() and d.frames.len > 0
  d.data = ""

func blitFrame(d: GifDecoder, frame: GifFrame, output: var seq[uint32]) =
  let (width, height) = (int(d.width), int(d.height))
  let (left, top) = (int(frame.left), int(frame.top))
  if top >= height or left >= width: return
  let endY = min(int(frame.height), height - top)
  let endX = min(int(frame.width), width - left)
  let copyRows = not frame.transparent and left + int(frame.width) <= width
  for y in 0 ..< endY:
    let frameIdx = y * int(frame.width)
    let canvasIdx = (top + y) * width + left
    if copyRows:
      for x in 0 ..< int(frame.width): output[canvasIdx + x] = frame.pixels[frameIdx + x]
    else:
      for x in 0 ..< endX:
        let pixel = frame.pixels[frameIdx + x]
        if (pixel and 0xFF000000'u32) != 0: output[canvasIdx + x] = pixel

proc compositeFrame*(d: GifDecoder, frameIndex: int, draw: bool, output: var seq[uint32]) =
  ## Applies the disposal of the previous frame (background only), then draws the frame.
  if frameIndex < 0 or frameIndex >= d.frames.len: return
  let (width, height) = (int(d.width), int(d.height))
  if frameIndex > 0 and d.frames[frameIndex - 1].disposal == DisposalBackground:
    let prev = d.frames[frameIndex - 1]
    let (left, top) = (int(prev.left), int(prev.top))
    if top < height and left < width:
      let endY = min(int(prev.height), height - top)
      let endX = min(int(prev.width), width - left)
      for y in 0 ..< endY:
        for x in 0 ..< endX: output[(top + y) * width + left + x] = 0
  if draw: d.blitFrame(d.frames[frameIndex], output)

func duration*(d: GifDecoder, b, e: float32): float32 =
  ## Seconds covered by the frame range `b ..< e` (fractional overlap allowed).
  result = 0.0'f32
  for i in 0 ..< d.frames.len:
    let frameBegin = float32(i)
    let frameEnd = frameBegin + 1.0'f32
    let overlapBegin = if b > frameBegin: b else: frameBegin
    let overlapEnd = if e < frameEnd: e else: frameEnd
    if overlapBegin < overlapEnd:
      result += (overlapEnd - overlapBegin) * float32(d.frames[i].delay) * 0.01'f32
