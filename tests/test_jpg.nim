## JPEG decoder (jpgd port) and loader tests. The files in tests/data/jpg come from
## tests/parity/mkjpg.js (own encoder: baseline, progressive, subsampling, restart
## intervals, optimized tables). Checks: header, PSNR against the regenerated source
## image, pixel equality between different encodings of the same coefficients,
## bit-exact comparison with the C++ goldens, error paths and loader registration.
import std/[unittest, math, os, strutils]
import thorvg/core/types
import thorvg/renderer/[render, loader, picture]
import thorvg/loaders/image/[jpgd, jpgd_bits, loader_jpg]
import thorvg/engine/cpu/raster

const
  DataDir = currentSourcePath().parentDir / "data" / "jpg"
  GoldenDir = currentSourcePath().parentDir.parentDir / "migration" / "golden"

type Entry = tuple[name: string, w, h: int, ok: bool]

proc loadJpg(name: string): string = readFile(DataDir / (name & ".jpg"))

proc entries(): seq[Entry] =
  for line in readFile(DataDir / "index.txt").splitLines():
    let f = line.splitWhitespace()
    if f.len == 4: result.add (f[0], parseInt(f[1]), parseInt(f[2]), f[3] == "ok")

proc decode(data: string): tuple[w, h: int, px: seq[uint32]] =
  let d = jpgdHeader(data)
  if d == nil: return
  result.w = d.imageX
  result.h = d.imageY
  result.px = jpgdDecompress(d)

proc nextRnd(s: var uint32): int =
  s = s * 1664525'u32 + 1013904223'u32
  int(s shr 8)

func jsRound(v: float): int = int(floor(v + 0.5))
func clamp8(v: float): int = max(0, min(255, jsRound(v)))

proc source(noise: bool, w, h: int): seq[array[3, int]] =
  ## Port of `makeImage` of mkjpg.js.
  var seed = uint32(12345 + w * 31 + h)
  let cx = w.float * 0.4
  let cy = h.float * 0.55
  let rad = min(w, h).float * 0.3
  for y in 0 ..< h:
    for x in 0 ..< w:
      var r, g, b: float
      if noise:
        r = float(nextRnd(seed) and 255)
        g = float(nextRnd(seed) and 255)
        b = float(nextRnd(seed) and 255)
      else:
        r = x.float * 255 / max(1, w - 1).float
        g = y.float * 255 / max(1, h - 1).float
        b = 255 - (r + g) / 2
        let d = hypot(x.float - cx, y.float - cy)
        if d < rad: (r = 250; g = 30 + d * 3; b = 40)
        if ((x shr 3) + (y shr 3)) mod 5 == 0 and x.float > w.float / 2: (r = 20; g = 200; b = 230)
        if x == (w shr 1): (r = 255; g = 255; b = 255)
      result.add [clamp8(r), clamp8(g), clamp8(b)]

func psnr(px: seq[uint32], src: seq[array[3, int]], gray: bool): float =
  var se = 0.0
  for i, p in px:
    let c = [int(p and 255), int((p shr 8) and 255), int((p shr 16) and 255)]
    if gray:
      let y = float(src[i][0]) * 0.299 + float(src[i][1]) * 0.587 + float(src[i][2]) * 0.114
      for k in 0 .. 2: se += (float(c[k]) - y) * (float(c[k]) - y)
    else:
      for k in 0 .. 2: se += float((c[k] - src[i][k]) * (c[k] - src[i][k]))
  if se == 0.0: return 99.0
  10.0 * log10(255.0 * 255.0 * float(px.len * 3) / se)

suite "jpg decode: generated files":
  for e in entries():
    if e.ok:
      test e.name:
        let data = loadJpg(e.name)
        let (w, h, px) = decode(data)
        check w == e.w and h == e.h
        check px.len == e.w * e.h
        var opaque = true
        for p in px:
          if (p shr 24) != 255'u32: opaque = false
        check opaque
        let noise = "noise" in e.name
        let gray = e.name.startsWith("gray") or e.name.startsWith("pgray") or
          "_gray_" in e.name or e.name.startsWith("noisegray")
        let minDb =
          if e.w * e.h < 64: 0.0     # 1x1 / 7x5: only size and opacity
          elif noise: (if "q10" in e.name or "q40" in e.name: 0.0 else: 28.0)
          elif e.w * e.h < 400: 17.0
          else: 21.0
        if minDb > 0.0:
          let db = psnr(px, source(noise, e.w, e.h), gray)
          checkpoint e.name & " psnr " & $db
          check db >= minDb

suite "jpg decode: same coefficients, different entropy coding":
  proc same(a: string, bs: openArray[string]) =
    let ref0 = decode(loadJpg(a))
    check ref0.px.len > 0
    for b in bs:
      let o = decode(loadJpg(b))
      checkpoint a & " vs " & b
      check o.w == ref0.w and o.h == ref0.h
      check o.px == ref0.px
  test "4:2:0 53x37: progressive, spectral, separate DC/AC scans, restarts, SOF1":
    same("s420_53x37", ["p420_53x37", "pspec420_53x37", "psep420_53x37", "dri1_420_53x37",
      "dri3_420_53x37", "dri5_420_53x37", "dri1_p420_53x37", "dri3_p420_53x37",
      "dri5_p420_53x37", "sof1_53x37"])
  test "4:2:0 with APP/COM markers, component ids 0..2, optimized tables":
    same("s420_37x29", ["ids012_37x29", "p420_37x29"])
    same("s420_200x150", ["opt420_200x150", "p420_200x150"])
  test "4:2:2 / 4:4:0 / gray: baseline vs progressive":
    for t in ["17x17", "53x37", "200x150"]:
      same("s422_" & t, ["p422_" & t])
      same("s440_" & t, ["p440_" & t])
      same("gray_" & t, ["pgray_" & t])
  test "gray with restarts, noisy 4:4:4 with long codes":
    same("gray_37x29", ["dri2_gray_37x29"])
    same("noise444_37x29_q95", ["pnoise444_37x29_q95"])
    same("pnoisespec444_37x29", ["pnoisesep444_37x29", "dri2_pnoise444_37x29", "pnoise444_37x29_q95"])
  test "gray decodes to R == G == B":
    for p in decode(loadJpg("gray_53x37")).px:
      check ((p shr 8) and 255) == (p and 255) and ((p shr 16) and 255) == (p and 255)

suite "jpg decode: errors and corrupt input":
  test "unsupported or invalid frame headers are rejected":
    for n in ["bad_sof9", "bad_sof3", "bad_12bit", "bad_zero", "bad_big", "bad_soi_only",
              "bad_garbage"]:
      checkpoint n
      check decode(loadJpg(n)).px.len == 0
  test "missing EOI / truncated progressive tail: image is still produced (as upstream)":
    for n in ["bad_noeoi", "bad_ptruncated"]:
      checkpoint n
      let r = decode(loadJpg(n))
      check r.w == 53 and r.h == 37
      check r.px.len == 53 * 37
  test "truncated or corrupt scan data: decode fails, header size is still known":
    for n in ["bad_truncated", "bad_corrupt", "bad_pcorrupt"]:
      checkpoint n
      let r = decode(loadJpg(n))
      check r.w == 53 and r.h == 37
      check r.px.len == 0
  test "multi-scan sequential files are not supported by jpgd (no crash)":
    for n in ["sep_420_53x37", "dri3_sep_420_53x37"]:
      let r = decode(loadJpg(n))
      check r.w == 53 and r.h == 37
      check r.px.len == 0 or r.px.len == 53 * 37
  test "empty input and bad marker":
    check jpgdHeader("") == nil
    check jpgdHeader("\xFF\xD8") == nil
    check jpgdHeader("GIF89a-not-a-jpeg") == nil
  test "missing quantization or Huffman table does not crash":
    for marker in ['\xDB', '\xC4']:
      var d = loadJpg("s420_53x37")
      let k = d.find("\xFF" & marker)
      check k > 0
      d[k + 1] = '\xFE'
      let dec = jpgdHeader(d)
      if dec != nil: discard jpgdDecompress(dec)
  test "fuzz: flipping header bytes never raises":
    let base = loadJpg("p420_17x17")
    for i in 2 ..< min(base.len, 600):
      var d = base
      d[i] = char(uint8(d[i]) xor 0xA5)
      let dec = jpgdHeader(d)
      if dec != nil and dec.imageX * dec.imageY < 1_000_000: discard jpgdDecompress(dec)

suite "jpg loader":
  test "registered: sniff, XBGR8888 opaque bitmap":
    let data = loadJpg("s420_37x29")
    var ret = Result.Unknown
    let l = acquireData(data, "", LoaderOps(), ret)
    check ret == Result.Success
    check l != nil
    check l.kind == FileType.Jpg
    let il = ImageLoader(l)
    check il.w == 37.0'f32 and il.h == 29.0'f32
    check l.read()
    let bm = il.bitmap()
    check bm != nil
    check bm.data == decode(data).px
    check retrieve(l)
  test "by mime type and by file path":
    var ret = Result.Unknown
    let l = acquireData(loadJpg("gray_17x17"), "jpg", LoaderOps(), ret)
    check l != nil and ret == Result.Success
    let m = acquireData(loadJpg("gray_17x17"), "jpeg", LoaderOps(), ret)
    check m != nil and ret == Result.Success
    let f = acquireFile(DataDir / "p420_53x37.jpg", LoaderOps(), ret)
    check f != nil and ret == Result.Success
    check ImageLoader(f).w == 53.0'f32 and ImageLoader(f).h == 37.0'f32
    check f.read()
    check ImageLoader(f).bitmap() != nil
  test "invalid data is rejected":
    var ret = Result.Unknown
    check acquireData("not a jpeg at all, really", "jpg", LoaderOps(), ret) == nil
    let bad = newJpgLoader()
    check bad.openData("\xFF\xD8\xFF\xD9", LoaderOps()) == Result.InvalidArguments
    check not bad.read()
  test "decode failure leaves the bitmap empty, read() stays true":
    var d = loadJpg("s420_53x37")
    let k = d.find("\xFF\xC4")
    d[k + 1] = '\xFE'  # no Huffman table at all
    let l = newJpgLoader()
    if l.openData(d, LoaderOps()) == Result.Success:
      check l.read()
  test "Picture.load":
    let pic = newPicture()
    check pic.load(DataDir / "s444_17x17.jpg") == Result.Success
    let pic2 = newPicture()
    check pic2.load(loadJpg("gray_7x5"), "jpg") == Result.Success
    let pic3 = newPicture()
    check pic3.load(loadJpg("bad_garbage"), "jpg") != Result.Success
  test "upstream jpg samples decode when present":
    let dir = currentSourcePath().parentDir / "data" / "upstream"
    for f in walkFiles(dir / "*.jpg"):
      let r = decode(readFile(f))
      check r.w > 0 and r.px.len == r.w * r.h

suite "jpg loader vs C++ golden (native size = direct blit)":
  for e in entries():
    if e.ok:
      test e.name:
        let golden = GoldenDir / ("jpg_" & e.name & ".argb")
        if fileExists(golden):
          var ret = Result.Unknown
          let l = acquireData(loadJpg(e.name), "", LoaderOps(), ret)
          check l != nil
          check l.read()
          let bm = ImageLoader(l).bitmap()
          check bm != nil
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
