## GIF decoder / loader tests (tvgGifDecoder.cpp, tvgGifLoader.cpp). The files in tests/data/gif and
## expected.json come from tests/parity/mkgif.js: its encoder writes the GIFs and its reference model
## (independent of any decoder: it works from the palette indices) gives the canvas of every frame.
import std/[unittest, json, os, strutils]
import thorvg/core/types
import thorvg/renderer/[render, loader, picture, canvas, animation]
import thorvg/engine/cpu/renderer
import thorvg/loaders/image/[gif_lzw, loader_gif]

const DataDir = currentSourcePath().parentDir / "data" / "gif"

let expected = parseJson(readFile(DataDir / "expected.json"))

proc names(): seq[string] =
  for k, _ in expected: result.add k

proc canvasOf(name: string, n: int): seq[uint32] =
  for v in expected[name]["canvases"][n]: result.add uint32(v.getInt())

proc frameCount(name: string): int = expected[name]["canvases"].len

proc open(data: string): (GifLoader, Result) =
  let l = newGifLoader()
  (l, l.openData(data, LoaderOps()))

proc opened(name: string): GifLoader =
  let (l, r) = open(readFile(DataDir / name))
  doAssert r == Result.Success, name
  doAssert l.read()
  l

proc pixels(l: GifLoader): seq[uint32] = l.bitmap().data

suite "lzw":
  test "hand made stream with the code == next code case":
    var out8 = newSeq[uint8](3)
    check lzwDecode([0x8C'u8, 0x0B'u8], out8, 2) == 3
    check out8 == @[1'u8, 1, 1]
    var big = newSeq[uint8](8)
    check lzwDecode([0x8C'u8, 0x0B'u8], big, 2) == 3  # ends early on the end code

  test "parameter and stream errors":
    var o = newSeq[uint8](4)
    check lzwDecode([0x8C'u8], o, 1) == 0
    check lzwDecode([0x8C'u8], o, 9) == 0
    check lzwDecode(newSeq[uint8](), o, 2) == 0
    var none = newSeq[uint8]()
    check lzwDecode([0x8C'u8], none, 2) == 0
    check lzwDecode([0b00110100'u8, 0x00'u8], o, 2) == 0   # clear, then 6: not a literal
    check lzwDecode([0x04'u8], o, 2) == 1                  # clear, literal 0, then dry
    check lzwDecode([0xCC'u8, 0x01'u8], o, 2) == 1         # clear, 1, 7 (> next code)

suite "gif frames match the reference model":
  test "header and sizes":
    for name in names():
      let l = opened(name)
      check l.w == float32(expected[name]["w"].getInt())
      check l.h == float32(expected[name]["h"].getInt())
      check l.totalFrame() == float32(frameCount(name))
      check l.curFrame() == 0.0'f32
      check l.playable
      check l.kind == FileType.Gif

  test "frame 0 after read":
    for name in names():
      check opened(name).pixels() == canvasOf(name, 0)

  test "forward, backward and jumping access":
    for name in names():
      let n = frameCount(name)
      let l = opened(name)
      var cur = 0
      var order: seq[int]
      for i in 0 ..< n: order.add i
      for i in countdown(n - 1, 0): order.add i
      for i in 0 ..< n * 2: order.add (i * 3 + 1) mod n
      for i in order:
        check l.frame(float32(i)) == (i != cur)
        check l.pixels() == canvasOf(name, i)
        check l.curFrame() == float32(i)
        cur = i

  test "frame numbers are clamped and fractions truncated":
    let l = opened("anim3.gif")
    check l.frame(99.0'f32)
    check l.curFrame() == 2.0'f32
    check l.pixels() == canvasOf("anim3.gif", 2)
    check not l.frame(3.0'f32)           # still frame 2
    check l.frame(-4.0'f32)
    check l.curFrame() == 0.0'f32
    check l.frame(1.9'f32)
    check l.curFrame() == 1.0'f32

  test "sync reports a pending change once":
    let l = opened("anim3.gif")
    check l.sync()                       # first sync after loading (updated starts true)
    check not l.sync()
    check l.frame(1.0'f32)
    check l.sync()
    check not l.sync()

suite "gif timing and segments":
  test "duration is the sum of the delays":
    for name in names():
      let l = opened(name)
      var total = 0.0'f32
      for d in expected[name]["delays"]: total += float32(d.getInt()) * 0.01'f32
      check abs(l.duration() - total) < 1e-5'f32
    check abs(opened("anim3.gif").duration() - 0.6'f32) < 1e-6'f32

  test "segments restrict the frames and shift the numbers":
    let l = opened("anim3.gif")
    check l.segment(1.0'f32, 3.0'f32) == Result.Success
    check l.totalFrame() == 2.0'f32
    check abs(l.duration() - 0.5'f32) < 1e-6'f32
    check l.frame(0.0'f32)               # relative 0 = absolute 1
    check l.pixels() == canvasOf("anim3.gif", 1)
    check l.curFrame() == 0.0'f32
    check l.frame(1.0'f32)
    check l.pixels() == canvasOf("anim3.gif", 2)
    check l.curFrame() == 1.0'f32
    check not l.frame(5.0'f32)           # clamped to the last frame
    check (l.segmentBegin, l.segmentEnd) == (1.0'f32, 3.0'f32)

  test "fractional segment durations":
    let l = opened("anim3.gif")
    check l.segment(0.5'f32, 2.5'f32) == Result.Success
    # 0.5 * 10 + 20 + 0.5 * 30 = 40 centiseconds
    check abs(l.duration() - 0.4'f32) < 1e-6'f32

  test "invalid segments":
    let l = opened("anim3.gif")
    check l.segment(2.0'f32, 1.0'f32) == Result.InvalidArguments
    check l.segment(-5.0'f32, 99.0'f32) == Result.Success
    check (l.segmentBegin, l.segmentEnd) == (0.0'f32, 3.0'f32)

suite "gif errors":
  let good = readFile(DataDir / "anim3.gif")

  test "bad header":
    check open("GIF86a" & good[6 .. ^1])[1] == Result.InvalidArguments
    check open("PNG89a" & good[6 .. ^1])[1] == Result.InvalidArguments
    check open(good[0 .. 11])[1] == Result.InvalidArguments
    check open("")[1] == Result.InvalidArguments

  test "no frame, no palette, bad GCE size":
    check open(good[0 .. 12] & good[good.len - 1 .. ^1])[1] == Result.InvalidArguments
    var noPalette = good
    noPalette[10] = char(uint8(noPalette[10]) and 0x7F)   # drop the global palette flag
    check open(noPalette)[1] == Result.InvalidArguments
    var badGce = good
    badGce[good.find("\x21\xF9") + 2] = '\x05'
    check open(badGce)[1] == Result.InvalidArguments

  test "truncated streams never crash; whole frames survive":
    for name in ["disp_prev.gif", "local_pal.gif", "interlaced.gif", "big.gif"]:
      let data = readFile(DataDir / name)
      for n in countup(0, data.len - 1, if data.len > 1000: 61 else: 1):
        let (l, r) = open(data[0 ..< n])
        if r == Result.Success:
          discard l.read()
          check l.bitmap() != nil
    check open(readFile(DataDir / "disp_prev.gif")[0 .. ^2])[1] == Result.Success  # no trailer

  test "corrupted bytes never crash":
    for name in ["anim3.gif", "transparent.gif", "interlaced.gif", "clip.gif"]:
      let data = readFile(DataDir / name)
      for i in 0 ..< data.len:
        for v in ['\x00', '\xFF', '\x2C', '\x21']:
          var bad = data
          bad[i] = v
          let (l, r) = open(bad)
          if r == Result.Success:
            discard l.read()
            for f in [1, 0, 2, 1]: discard l.frame(float32(f))

suite "gif in the scene graph":
  test "registered for .gif and sniffed from data":
    let pic = newPicture()
    check pic.load(DataDir / "anim3.gif") == Result.Success
    var w, h = 0.0'f32
    check pic.size(w, h) == Result.Success
    check (w, h) == (8.0'f32, 8.0'f32)
    let pic2 = newPicture()
    check pic2.load(readFile(DataDir / "single.gif"), "") == Result.Success
    let pic3 = newPicture()
    check pic3.load(readFile(DataDir / "single.gif"), "gif") == Result.Success
    check newPicture().load(DataDir / "missing.gif") == Result.InvalidArguments

  test "animation plays through the canvas":
    let a = newAnimation()
    check a.picture.load(DataDir / "anim3.gif") == Result.Success
    check a.totalFrame() == 3.0'f32
    check abs(a.duration() - 0.6'f32) < 1e-6'f32
    let c = newSwCanvas(8, 8)
    check c.add(a.picture) == Result.Success
    proc draw() =
      check c.update() == Result.Success
      check c.draw(true) == Result.Success
      check c.sync() == Result.Success
    draw()
    check swSurface(c).data[10] == 0xFFFF0000'u32
    check a.frame(1.0'f32) == Result.Success
    draw()
    check swSurface(c).data[10] == 0xFF00FF00'u32
    check a.frame(1.0'f32) == Result.InsufficientCondition
    check a.frame(2.0'f32) == Result.Success
    draw()
    check swSurface(c).data[63] == 0xFF0000FF'u32
    check a.curFrame() == 2.0'f32
    check a.segment(1.0'f32, 2.0'f32) == Result.Success
    check a.totalFrame() == 1.0'f32

  test "transparent pixels stay transparent on the canvas":
    let a = newAnimation()
    check a.picture.load(DataDir / "disp_bg.gif") == Result.Success
    check a.frame(1.0'f32) == Result.Success
    let c = newSwCanvas(6, 6)
    check c.add(a.picture) == Result.Success
    check c.update() == Result.Success
    check c.draw(true) == Result.Success
    check c.sync() == Result.Success
    let px = swSurface(c).data
    check px[0] == 0'u32                  # frame 0 rectangle was disposed to background
    check px[2 * 6 + 2] == 0xFF00FF00'u32

  test "ABGR canvases get ABGR pixels":
    setDesiredColorSpace(ColorSpace.ABGR8888)
    let l = opened("single.gif")
    setDesiredColorSpace(ColorSpace.ARGB8888)
    check l.bitmap().cs == ColorSpace.ABGR8888
    # palette entry 0 is (10, 20, 30): ABGR word = A | B<<16 | G<<8 | R
    check l.pixels()[0] == (0xFF000000'u32 or (30'u32 shl 16) or (20'u32 shl 8) or 10'u32)
    let argb = opened("single.gif")
    check argb.bitmap().cs == ColorSpace.ARGB8888
    check argb.pixels()[0] == (0xFF000000'u32 or (10'u32 shl 16) or (20'u32 shl 8) or 30'u32)
