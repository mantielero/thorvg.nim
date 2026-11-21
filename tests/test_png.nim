## PNG decoder / inflate / loader tests. The files in tests/data/png come from
## tests/parity/mkpng.js; `expected` below re-derives every pixel of that generator
## (and applies lodepng's RGBA8 conversion rules) so each decoded pixel is checked.
import std/[unittest, math, os, strutils]
import thorvg/core/types
import thorvg/renderer/[render, loader]
import thorvg/loaders/image/[inflate, png, loader_png]
import thorvg/display/imageio
import thorvg/engine/cpu/raster

const DataDir = currentSourcePath().parentDir / "data"

type Spec = tuple[name: string, ct, bits, w, h: int, trns: bool]

const Specs: seq[Spec] = @[
  ("gray1", 0, 1, 37, 29, false), ("gray2", 0, 2, 37, 29, false),
  ("gray4", 0, 4, 37, 29, false), ("gray8", 0, 8, 37, 29, false),
  ("gray16", 0, 16, 37, 29, false), ("rgb8", 2, 8, 37, 29, false),
  ("rgb16", 2, 16, 37, 29, false), ("pal1", 3, 1, 37, 29, false),
  ("pal2", 3, 2, 37, 29, false), ("pal4", 3, 4, 37, 29, true),
  ("pal8", 3, 8, 37, 29, true), ("graya8", 4, 8, 37, 29, false),
  ("graya16", 4, 16, 37, 29, false), ("rgba8", 6, 8, 37, 29, false),
  ("rgba16", 6, 16, 37, 29, false), ("rgba8_adam7", 6, 8, 37, 29, false),
  ("rgb8_adam7", 2, 8, 5, 3, false), ("gray4_adam7", 0, 4, 37, 29, false),
  ("rgba8_stored", 6, 8, 37, 29, false), ("rgba8_fixed", 6, 8, 37, 29, false),
  ("rgba8_sub", 6, 8, 37, 29, false), ("rgba8_up", 6, 8, 37, 29, false),
  ("rgba8_avg", 6, 8, 37, 29, false), ("rgba8_paeth", 6, 8, 37, 29, false),
  ("rgba8_big", 6, 8, 200, 150, false), ("rgb8_trns", 2, 8, 37, 29, true)]

func jsRound(v: float): int = int(floor(v + 0.5))

func pix(x, y, w, h: int): array[4, int] =
  ## Generator pattern, channels 0..65535 (`pix` of mkpng.js).
  let fx = x.float / max(1, w - 1).float
  let fy = y.float / max(1, h - 1).float
  let dx = x.float - w.float / 2
  let dy = y.float - h.float / 2
  let a = max(0.0, min(1.0, 1.3 - sqrt(dx * dx + dy * dy) / (min(w, h).float / 2)))
  [jsRound(fx * 65535), jsRound(fy * 65535),
   if (((x shr 2) + (y shr 2)) and 1) == 1: 65535 else: 8000, jsRound(a * 65535)]

func expected(s: Spec, x, y: int): array[4, int] =
  ## RGBA8 the C++ decoder yields for pixel (x, y).
  let p = pix(x, y, s.w, s.h)
  let maxv = (1 shl s.bits) - 1
  func q(v: int): int = (if s.bits == 16: v else: jsRound(v.float / 65535 * maxv.float))
  func to8(v: int): int =
    if s.bits == 16: v shr 8 elif s.bits == 8: v else: v * 255 div maxv
  case s.ct
  of 0: (let g = to8(q(p[1])); [g, g, g, 255])
  of 2:
    let r = to8(q(p[0]))
    let g = to8(q(p[1]))
    let b = to8(q(p[2]))
    [r, g, b, if s.trns and r == 0 and g == 0 and b == 0: 0 else: 255]
  of 3:
    let palN = min(1 shl s.bits, 16)
    let i = (x * 3 + y) mod palN
    let tlen = max(1, palN shr 1)
    [(i * 67) and 255, (i * 131 + 40) and 255, (255 - i * 29) and 255,
     if s.trns and i < tlen: (i * 40) and 255 else: 255]
  of 4: (let g = to8(q(p[0])); [g, g, g, to8(q(p[3]))])
  else: [to8(q(p[0])), to8(q(p[1])), to8(q(p[2])), to8(q(p[3]))]

proc loadPng(name: string): string = readFile(DataDir / "png" / (name & ".png"))

proc decode(data: string): tuple[error: int, image: PngImage] =
  result.error = pngDecode(data.toOpenArrayByte(0, data.high), result.image)

func bytes(s: string): seq[byte] =
  for c in s: result.add byte(c)

suite "png decode: generated files":
  for s in Specs:
    test s.name:
      let (error, img) = decode(loadPng(s.name))
      check error == 0
      check img.width == s.w
      check img.height == s.h
      var bad = 0
      for y in 0 ..< s.h:
        for x in 0 ..< s.w:
          let e = expected(s, x, y)
          let i = (y * s.w + x) * 4
          for k in 0 .. 3:
            if int(img.rgba[i + k]) != e[k]: inc bad
      check bad == 0

suite "png decode: known pixels":
  test "rgba8 corner pixels (hand checked)":
    let (_, img) = decode(loadPng("rgba8"))
    # (0,0): r=0 g=0 b=8000->31, far from the centre so alpha = 0
    check img.rgba[0 .. 3] == @[0'u8, 0'u8, 31'u8, 0'u8]
    let i = (14 * 37 + 18) * 4  # near the centre: opaque
    check img.rgba[i + 3] == 255'u8
  test "palette tRNS alpha":
    let (_, img) = decode(loadPng("pal8"))
    check img.rgba[3] == 0'u8  # index 0 -> alpha 0

suite "png decode: errors":
  test "bad signature":
    var d = loadPng("rgba8")
    d[1] = 'X'
    check decode(d).error == 28
  test "empty and short input":
    check decode("").error == 48
    check decode("\x89PNG\r\n\x1A\n").error == 27
  test "truncated file":
    let d = loadPng("rgba8")
    check decode(d[0 ..< d.len div 2]).error != 0
  test "corrupt zlib stream (adler)":
    var d = loadPng("rgba8_stored")
    let i = d.find("IEND") - 12  # last 4 bytes of the second IDAT = adler
    d[i + 1] = char(uint8(d[i + 1]) xor 0xFF)
    check decode(d).error == 58
  test "unknown critical chunk":
    let d = loadPng("rgba8")
    let k = d.find("IDAT") - 4
    check decode(d[0 ..< k] & "\0\0\0\0ABCD\0\0\0\0" & d[k .. ^1]).error == 69
  test "unknown ancillary chunk is ignored":
    let d = loadPng("rgba8")
    let k = d.find("IDAT") - 4
    check decode(d[0 ..< k] & "\0\0\0\0abcd\0\0\0\0" & d[k .. ^1]).error == 0
  test "palette image without PLTE":
    let d = loadPng("pal8")
    let k = d.find("PLTE") - 4
    let n = int(uint8(d[k + 3])) + 12
    check decode(d[0 ..< k] & d[k + n .. ^1]).error != 0

suite "inflate":
  test "zlib of 'a' (fixed huffman)":
    var o: seq[byte]
    check zlibDecompress(bytes("\x78\x9c\x4b\x04\x00\x00\x62\x00\x62"), o) == 0
    check o == @[byte('a')]
  test "stored block":
    var o: seq[byte]
    let z = bytes("\x78\x01\x01\x03\x00\xfc\xffabc") & @[byte 0x02, 0x4d, 0x01, 0x27]
    check zlibDecompress(z, o) == 0
    check o == bytes("abc")
  test "bad header and bad method":
    var o: seq[byte]
    check zlibDecompress(bytes("\x78\x9d\x03\x00"), o) == 24
    check zlibDecompress(bytes("\x79\x18\x03\x00"), o) == 25
    check zlibDecompress(bytes("\x78"), o) == 53
  test "reserved block type":
    var o: seq[byte]
    check inflate(@[byte 0x07, 0, 0, 0, 0, 0], o) == 20
  test "adler32 of 'Wikipedia'":
    check adler32(bytes("Wikipedia")) == 0x11E60398'u32

suite "png loader":
  test "registered: sniff + extension, bitmap is straight ABGR8888S":
    let data = loadPng("rgba8")
    var ret = Result.Unknown
    let l = acquireData(data, "", LoaderOps(), ret)
    check ret == Result.Success
    check l != nil
    check l.kind == FileType.Png
    let il = ImageLoader(l)
    check il.w == 37.0'f32 and il.h == 29.0'f32
    check l.read()
    let bm = il.bitmap()
    check bm != nil
    check bm.cs == ColorSpace.ABGR8888S
    check not bm.premultiplied
    let (_, img) = decode(data)
    let p = (7 * 37 + 11) * 4
    let expectWord = uint32(img.rgba[p]) or (uint32(img.rgba[p + 1]) shl 8) or
      (uint32(img.rgba[p + 2]) shl 16) or (uint32(img.rgba[p + 3]) shl 24)
    check bm.data[7 * 37 + 11] == expectWord
    check retrieve(l)
  test "by mime type and by file path":
    var ret = Result.Unknown
    let l = acquireData(loadPng("gray8"), "png", LoaderOps(), ret)
    check l != nil and ret == Result.Success
    let f = acquireFile(DataDir / "png" / "pal4.png", LoaderOps(), ret)
    check f != nil and ret == Result.Success
    check ImageLoader(f).w == 37.0'f32
    check f.read()
    check ImageLoader(f).bitmap() != nil
  test "invalid data is rejected":
    var ret = Result.Unknown
    check acquireData("not a png at all, really", "png", LoaderOps(), ret) == nil
    let bad = newPngLoader()
    check bad.openData("\x89PNG\r\n\x1A\n", LoaderOps()) == Result.InvalidArguments
    check not bad.read()
  test "decode error leaves the bitmap empty":
    var d = loadPng("rgba8_stored")
    d[d.find("IEND") - 11] = '\x55'
    let l = newPngLoader()
    check l.openData(d, LoaderOps()) == Result.Success
    check l.read()
    check l.bitmap() == nil
  test "round trip through imageio.encodePng":
    let (_, img) = decode(loadPng("rgba16"))
    var ret = Result.Unknown
    let l = acquireData(loadPng("rgba16"), "", LoaderOps(), ret)
    check l.read()
    let png = encodePng(ImageLoader(l).bitmap())
    let (error, back) = decode(png)
    check error == 0
    check back.width == img.width and back.height == img.height
    check back.rgba == img.rgba
  test "upstream test.png decodes":
    let path = DataDir / "upstream" / "test.png"
    let (error, img) = decode(readFile(path))
    check error == 0
    check img.width > 0 and img.height > 0
    check img.rgba.len == img.width * img.height * 4
    check decode(readFile(DataDir / "upstream" / "test2.png")).error == 0

suite "png loader vs C++ golden (native size = direct blit of the premultiplied bitmap)":
  const GoldenDir = currentSourcePath().parentDir.parentDir / "migration" / "golden"
  const Native = [
    "gray1", "gray2", "gray4", "gray4_adam7", "gray8", "gray16", "graya8", "graya16",
    "pal1", "pal2", "pal4", "pal8", "rgb8", "rgb16", "rgb8_adam7", "rgb8_trns", "rgba8",
    "rgba16", "rgba8_adam7", "rgba8_avg", "rgba8_big", "rgba8_fixed", "rgba8_paeth",
    "rgba8_stored", "rgba8_sub", "rgba8_up"]
  for name in Native:
    test name:
      let golden = GoldenDir / ("png_" & name & "_native.argb")
      if fileExists(golden):
        var ret = Result.Unknown
        let l = acquireData(loadPng(name), "", LoaderOps(), ret)
        check l.read()
        let bm = ImageLoader(l).bitmap()
        check rasterConvertCS(bm, ColorSpace.ARGB8888)
        rasterPremultiplySurface(bm)
        let ref0 = readFile(golden)
        check ref0.len == bm.data.len * 4
        var bad = 0
        for i, px in bm.data:
          let g = uint32(uint8(ref0[i * 4])) or (uint32(uint8(ref0[i * 4 + 1])) shl 8) or
            (uint32(uint8(ref0[i * 4 + 2])) shl 16) or (uint32(uint8(ref0[i * 4 + 3])) shl 24)
          if px != g: inc bad
        check bad == 0

  test "upstream test.png (dynamic huffman, 511x511)":
    let golden = GoldenDir / "png_upstream_test_native.argb"
    if fileExists(golden):
      var ret = Result.Unknown
      let l = acquireData(readFile(DataDir / "upstream" / "test.png"), "", LoaderOps(), ret)
      check l.read()
      let bm = ImageLoader(l).bitmap()
      check rasterConvertCS(bm, ColorSpace.ARGB8888)
      rasterPremultiplySurface(bm)
      let ref0 = readFile(golden)
      check ref0.len == bm.data.len * 4
      var bad = 0
      for i, px in bm.data:
        let g = uint32(uint8(ref0[i * 4])) or (uint32(uint8(ref0[i * 4 + 1])) shl 8) or
          (uint32(uint8(ref0[i * 4 + 2])) shl 16) or (uint32(uint8(ref0[i * 4 + 3])) shl 24)
        if px != g: inc bad
      check bad == 0
