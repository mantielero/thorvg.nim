import std/[unittest, os, strutils]
import thorvg/core/types
import thorvg/renderer/render
import thorvg/display/[imageio, window]

proc be32(s: string, o: int): uint32 =
  for i in 0..3: result = (result shl 8) or uint32(uint8(s[o + i]))

proc gradient(w, h: int, cs: ColorSpace): RenderSurface =
  ## Opaque-ish test pattern in the given 32-bit color space.
  result = newSurface(uint32(w), uint32(h), cs)
  for y in 0..<h:
    for x in 0..<w:
      let a = 255'u32
      let r = uint32(x * 255 div max(w - 1, 1))
      let g = uint32(y * 255 div max(h - 1, 1))
      let b = 77'u32
      result.data[y * w + x] =
        if cs == ColorSpace.ABGR8888: (a shl 24) or (b shl 16) or (g shl 8) or r
        else: (a shl 24) or (r shl 16) or (g shl 8) or b

proc chunks(png: string): seq[tuple[kind, body: string]] =
  ## Walks the chunks of a PNG, checking every CRC.
  check png.startsWith("\x89PNG\r\n\x1A\n")
  var pos = 8
  while pos < png.len:
    let n = int(be32(png, pos))
    let kind = png.substr(pos + 4, pos + 7)
    let body = png.substr(pos + 8, pos + 7 + n)
    check be32(png, pos + 8 + n) == crc32(kind & body)
    result.add (kind, body)
    pos += 12 + n
  check pos == png.len

proc inflateStored(z: string): string =
  ## Minimal zlib reader that only understands stored blocks.
  check z[0] == '\x78'
  var pos = 2
  var last = false
  while not last:
    last = (uint8(z[pos]) and 1) == 1
    check (uint8(z[pos]) and 6) == 0          # BTYPE = 00 (stored)
    let n = int(uint8(z[pos + 1])) or (int(uint8(z[pos + 2])) shl 8)
    let nn = int(uint8(z[pos + 3])) or (int(uint8(z[pos + 4])) shl 8)
    check n == (nn xor 0xFFFF)
    result.add z.substr(pos + 5, pos + 4 + n)
    pos += 5 + n
  check be32(z, pos) == adler32(result)

suite "checksums":
  test "crc32 and adler32 known values":
    check crc32("123456789") == 0xCBF43926'u32
    check crc32("") == 0'u32
    check crc32("6789", crc32("12345")) == 0xCBF43926'u32
    check adler32("Wikipedia") == 0x11E60398'u32
    check adler32("") == 1'u32

suite "pixel access":
  test "ARGB and ABGR give the same rgba":
    let a = gradient(5, 4, ColorSpace.ARGB8888)
    let b = gradient(5, 4, ColorSpace.ABGR8888)
    for y in 0..<4:
      for x in 0..<5: check a.rgbaAt(x, y) == b.rgbaAt(x, y)

  test "un-premultiply and over-black":
    let s = newSurface(1, 1)                       # premultiplied ARGB
    s.data[0] = 0x80400000'u32                     # a=128, r=64 (premultiplied)
    check s.rgbaAt(0, 0) == (r: 128'u8, g: 0'u8, b: 0'u8, a: 128'u8)
    check s.rgbOverBlack(0, 0) == (r: 64'u8, g: 0'u8, b: 0'u8, a: 255'u8)
    let t = newSurface(1, 1, ColorSpace.ARGB8888S)  # straight
    t.data[0] = 0x80FF0000'u32
    check t.rgbaAt(0, 0) == (r: 255'u8, g: 0'u8, b: 0'u8, a: 128'u8)
    check t.rgbOverBlack(0, 0) == (r: 128'u8, g: 0'u8, b: 0'u8, a: 255'u8)
    s.data[0] = 0
    check s.rgbaAt(0, 0) == (r: 0'u8, g: 0'u8, b: 0'u8, a: 0'u8)

  test "grayscale and stride":
    let g = newSurface(2, 1, ColorSpace.Grayscale8)
    g.buf8[1] = 200
    check g.rgbaAt(1, 0) == (r: 200'u8, g: 200'u8, b: 200'u8, a: 255'u8)
    let s = newSurface(2, 2)
    s.stride = 3
    s.data = newSeq[uint32](6)
    s.data[3] = 0xFF112233'u32
    check s.rgbaAt(0, 1) == (r: 0x11'u8, g: 0x22'u8, b: 0x33'u8, a: 255'u8)

suite "bmp":
  test "round trip opaque surface":
    let s = gradient(37, 11, ColorSpace.ARGB8888)    # odd width: exercises layout
    let back = decodeBmp(encodeBmp(s))
    check back.w == 37 and back.h == 11
    for y in 0..<11:
      for x in 0..<37: check back.rgbaAt(x, y) == s.rgbaAt(x, y)

  test "round trip through a file keeps alpha":
    let s = newSurface(3, 2, ColorSpace.ARGB8888S)
    s.data[0] = 0x80FF0000'u32
    s.data[4] = 0x00000000'u32
    s.data[5] = 0xFF0000FF'u32
    let path = getTempDir() / "thorvg_test_imageio.bmp"
    writeBmp(path, s)
    let back = readBmp(path)
    removeFile(path)
    for y in 0..1:
      for x in 0..2: check back.rgbaAt(x, y) == s.rgbaAt(x, y)

  test "file layout and rejects garbage":
    let bmp = encodeBmp(gradient(2, 2, ColorSpace.ARGB8888))
    check bmp.len == 54 + 16
    check bmp[0] == 'B' and bmp[1] == 'M'
    expect ImageIoError: discard decodeBmp("hello")
    expect ImageIoError: discard decodeBmp(bmp.substr(0, 60))
    expect ImageIoError: discard encodeBmp(newSurface(0, 0))

suite "ppm":
  test "header and composited bytes":
    let s = gradient(3, 2, ColorSpace.ARGB8888)
    let ppm = encodePpm(s)
    check ppm.startsWith("P6\n3 2\n255\n")
    check ppm.len == "P6\n3 2\n255\n".len + 18
    check ppm.substr("P6\n3 2\n255\n".len, "P6\n3 2\n255\n".len + 2) == "\0\0\x4D"

suite "png":
  test "signature, chunk order and CRCs":
    let png = encodePng(gradient(9, 5, ColorSpace.ARGB8888))
    let cs = chunks(png)
    check cs.len == 3
    check cs[0].kind == "IHDR" and cs[1].kind == "IDAT" and cs[2].kind == "IEND"
    check be32(cs[0].body, 0) == 9 and be32(cs[0].body, 4) == 5
    check cs[0].body.substr(8) == "\x08\x06\0\0\0"
    check cs[2].body.len == 0

  test "stored pixel data matches the surface":
    let s = gradient(9, 5, ColorSpace.ABGR8888)
    let raw = inflateStored(chunks(encodePng(s))[1].body)
    check raw.len == (9 * 4 + 1) * 5
    for y in 0..<5:
      check raw[y * 37] == '\0'
      for x in 0..<9:
        let p = s.rgbaAt(x, y)
        let o = y * 37 + 1 + x * 4
        check (uint8(raw[o]), uint8(raw[o + 1]), uint8(raw[o + 2]), uint8(raw[o + 3])) ==
          (p.r, p.g, p.b, p.a)

  test "large image needs several stored blocks":
    let s = gradient(200, 200, ColorSpace.ARGB8888)   # 160200 bytes > 65535
    let raw = inflateStored(chunks(encodePng(s))[1].body)
    check raw.len == (200 * 4 + 1) * 200

  test "write to file":
    let path = getTempDir() / "thorvg_test_imageio.png"
    writePng(path, gradient(4, 4, ColorSpace.ARGB8888))
    check getFileSize(path) > 60
    removeFile(path)

suite "window":
  test "smoke (set THORVG_GUI_TEST=1 to run)":
    if getEnv("THORVG_GUI_TEST") != "1":
      skip()
    else:
      let win = openWindow("thorvg imageio test", 160, 120, autoCloseMs = 400)
      check win.isOpen
      win.present(gradient(80, 60, ColorSpace.ARGB8888))
      var polls = 0
      while win.pollEvents():
        inc polls
        win.present(gradient(80, 60, ColorSpace.ARGB8888))
        sleep(10)
      check polls > 0
      check not win.isOpen
