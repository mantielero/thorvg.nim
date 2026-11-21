## WebP container, ALPH alpha plane, filters, output buffer and loader tests (unit L5c-C).
##
## The input files are `tests/data/webp/alph` (made by `tests/parity/mkwebp_alph.nim`, whose
## `cases()` carries the expected alpha plane of every file) plus all the other WebP files of
## `tests/data/webp`. Pixels are checked against an independent model (decode the VP8 chunk
## without alpha, premultiply with the plane by hand); the C++ comparison is the `webp_`
## group of tests/parity (`run_cases.ps1`). Mutated and truncated inputs must never raise.
import std/[unittest, os, random, sequtils, strutils]
import thorvg/core/types
import thorvg/renderer/[render, loader]
import thorvg/loaders/image/webp/[container, alpha, filters, alpha_proc, buffer, decode, vp8]
import thorvg/loaders/image/loader_webp
import ./parity/[mkwebp_alph, webp_lossy_util]

const
  DataDir = currentSourcePath().parentDir / "data" / "webp"
  Fast = defined(release) or defined(danger)
  MustFail = [
    "alph_bad_method2", "alph_bad_pre2", "alph_bad_reserved", "alph_empty", "alph_header_only",
    "alph_short_raw", "alph_lossless_header_only", "alph_lossless_truncated",
    "ct_two_alph_last_bad"]

proc fromString(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc toStr(d: openArray[byte]): string =
  result = newString(d.len)
  for i, v in d: result[i] = char(v)

proc premul(c, a: uint32): uint32 = (c * a * 32897'u32) shr 23

proc model(base: seq[uint32], plane: seq[byte]): seq[uint32] =
  ## Independent alpha model: top byte = alpha, colors premultiplied unless alpha = 0xff.
  result = base
  for i in 0 ..< base.len:
    let a = uint32(plane[i])
    let p = base[i]
    result[i] =
      if a == 0xff: (p and 0x00ffffff'u32) or 0xff000000'u32
      else: (a shl 24) or (premul((p shr 16) and 0xff, a) shl 16) or
        (premul((p shr 8) and 0xff, a) shl 8) or premul(p and 0xff, a)

proc baseFile(base: string): seq[byte] = payloadOf(readBytes(DataDir / "lossy" / (base & ".webp")))

proc decodeAll(d: seq[byte], w, h: var int): seq[uint32] = webpDecodeBgra(d, w, h)

let allCases = cases()

suite "filters":
  test "hand-computed 3x2 plane":
    let p = @[10'u8, 20, 30, 40, 50, 60]
    check filter(p, 3, 2, wfHorizontal) == @[10'u8, 10, 10, 30, 10, 10]
    check filter(p, 3, 2, wfVertical) == @[10'u8, 10, 10, 30, 30, 30]
    check filter(p, 3, 2, wfGradient) == @[10'u8, 10, 10, 30, 0, 0]
    check filter(p, 3, 2, wfNone) == p
  test "gradient predictor clips to 0..255":
    let p = @[0'u8, 255, 255, 0]
    var f = filter(p, 2, 2, wfGradient)
    f.unfilter(2, 2, wfGradient)
    check f == p
  test "round trip, all kinds and shapes":
    var r = initRand(42)
    for (w, h) in [(1, 1), (1, 9), (9, 1), (2, 2), (7, 5), (33, 17), (64, 3)]:
      var p = newSeq[byte](w * h)
      for v in p.mitems: v = byte(r.rand(255))
      for k in WebpFilter:
        var f = filter(p, w, h, k)
        if k != wfNone and w * h > 1: check f != p
        f.unfilter(w, h, k)
        check f == p
  test "unfilter ignores too short planes and empty sizes":
    var p = @[1'u8, 2, 3]
    p.unfilter(2, 2, wfHorizontal)
    check p == @[1'u8, 2, 3]
    p.unfilter(0, 0, wfGradient)
    check p == @[1'u8, 2, 3]

suite "alpha plane":
  test "raw, all filters":
    for k in WebpFilter:
      let pl = @[5'u8, 9, 200, 1, 7, 7, 0, 255, 33, 4, 5, 6]
      let data = @[byte(ord(k) shl 2)] & filter(pl, 4, 3, k)
      check decodeAlphaPlane(data, 4, 3) == pl
  test "invalid headers and sizes":
    check decodeAlphaPlane(@[byte 0], 1, 1).len == 0           # header only
    check decodeAlphaPlane(newSeq[byte](), 1, 1).len == 0
    check decodeAlphaPlane(@[byte 2, 1], 1, 1).len == 0        # method 2
    check decodeAlphaPlane(@[byte 0x20, 1], 1, 1).len == 0     # pre-processing 2
    check decodeAlphaPlane(@[byte 0x40, 1], 1, 1).len == 0     # reserved bits
    check decodeAlphaPlane(@[byte 0, 1, 2, 3], 2, 2).len == 0  # too short
    check decodeAlphaPlane(@[byte 0, 1], 0, 1).len == 0
    check decodeAlphaPlane(@[byte 0x10, 1, 2], 2, 1) == @[1'u8, 2]
  test "the generated lossless planes decode to the source plane":
    var n = 0
    for c in allCases:
      if c.alpha.len > 0 and c.name.startsWith("alph_") and "_m1_" in c.name:
        var hdr: WebpHeaders
        check parseHeaders(c.data, hdr) == vsOk
        let a = c.data[hdr.alphaOffset ..< hdr.alphaOffset + hdr.alphaSize]
        check decodeAlphaPlane(a, hdr.width, hdr.height) == c.alpha
        inc n
    check n > 40

suite "alpha processing":
  test "hasNonTrivialAlpha":
    check not hasNonTrivialAlpha(newSeq[byte]())
    check not hasNonTrivialAlpha([255'u8, 255])
    check hasNonTrivialAlpha([255'u8, 254])
  test "applyAlphaMultiply is int(c * a / 255)":
    var px = @[0x80ff8040'u32, 0xff123456'u32, 0x00ffffff'u32, 0x01ffffff'u32]
    applyAlphaMultiply(px)
    check px == @[0x80804020'u32, 0xff123456'u32, 0x00000000'u32, 0x01010101'u32]
    for a in 0'u32 .. 255:
      for c in [0'u32, 1, 127, 128, 254, 255]:
        var one = @[(a shl 24) or c]
        applyAlphaMultiply(one)
        check (one[0] and 0xff) == (if a == 255: c else: uint32(int(float64(c) * float64(a) / 255.0)))
  test "dispatchAlpha":
    var px = @[0x11223344'u32, 0xaabbccdd'u32]
    check dispatchAlpha(px, [255'u8, 0])
    check px == @[0xff223344'u32, 0x00bbccdd'u32]
    check not dispatchAlpha(px, [255'u8, 255])
    check px == @[0xff223344'u32, 0xffbbccdd'u32]

suite "decode buffer":
  test "dimension limits":
    var b = DecBuffer(mode: modeBgrA)
    check allocateDecBuffer(b, 0, 5) == vsInvalidParam
    check allocateDecBuffer(b, 5, -1) == vsInvalidParam
    check allocateDecBuffer(b, 1 shl 20, 1 shl 20) == vsOutOfMemory
    check allocateDecBuffer(b, 7, 3) == vsOk
    check b.width == 7 and b.height == 3
    freeDecBuffer(b)
    check b.pixels.len == 0

suite "container":
  test "plain VP8 and VP8L features":
    let vp8 = allCases.filterIt(it.name == "ct_plain_vp8")[0]
    var f: WebpFeatures
    check getFeatures(vp8.data, f) == vsOk
    check f.width == 33 and f.height == 17 and not f.hasAlpha and not f.hasAnimation
    let ll = allCases.filterIt(it.name == "vp8l_plain")[0]
    check getFeatures(ll.data, f) == vsOk
    check f.width == 33 and f.height == 17 and f.hasAlpha
    let op = allCases.filterIt(it.name == "vp8l_plain_opaque")[0]
    check getFeatures(op.data, f) == vsOk and not f.hasAlpha
  test "VP8X alpha flag is OR-ed with ALPH, VP8L header bit wins":
    var f: WebpFeatures
    for (name, alpha) in [("ct_alph_no_flag", true), ("ct_flag_no_alph", true),
                          ("vp8l_x_noflag", true), ("vp8l_x_noflag_opaque", false),
                          ("vp8l_x_flag_opaque", false), ("vp8l_x_ignores_alph", true)]:
      let c = allCases.filterIt(it.name == name)[0]
      check getFeatures(c.data, f) == vsOk
      check f.hasAlpha == alpha
  test "ALPH chunk bookkeeping":
    var h: WebpHeaders
    let c = allCases.filterIt(it.name == "ct_unknown_chunks")[0]
    check parseHeaders(c.data, h) == vsOk
    check h.hasAlphaChunk and not h.isLossless and h.width == 33 and h.height == 17
    check c.data[h.offset - 8 ..< h.offset - 4] == @[byte('V'), byte('P'), byte('8'), byte(' ')]
    let last = allCases.filterIt(it.name == "ct_two_alph_last_wins")[0]
    check parseHeaders(last.data, h) == vsOk
    check h.alphaSize > 1
  test "animation and fragments are unsupported, bad VP8X rejected":
    var h: WebpHeaders
    for name in ["ct_vp8x_animation"]:
      check parseHeaders(allCases.filterIt(it.name == name)[0].data, h) != vsOk
    for name in ["ct_vp8x_bad_size", "ct_vp8x_canvas_mismatch", "ct_riff_not_webp",
                 "ct_chunk_size_huge", "tiny_empty", "tiny_garbage", "tiny_zero_vp8"]:
      check parseHeaders(allCases.filterIt(it.name == name)[0].data, h) != vsOk
  test "truncated files: features may be known, headers/decode fail":
    var f: WebpFeatures
    var h: WebpHeaders
    var w, hh = 0
    for c in allCases:
      if c.name.startsWith("ct_truncated_"):
        discard getFeatures(c.data, f)
        discard parseHeaders(c.data, h)
        check decodeAll(c.data, w, hh).len == 0
  test "never raises on any case, prefix or mutation":
    var r = initRand(7)
    var w, h = 0
    for c in allCases:
      discard decodeAll(c.data, w, h)
      if c.data.len > 40 and (Fast or c.data.len < 12000):
        for _ in 0 ..< 6:
          var d = c.data
          for _ in 0 ..< 1 + r.rand(3): d[r.rand(d.high)] = byte(r.rand(255))
          discard decodeAll(d, w, h)
        discard decodeAll(c.data[0 ..< r.rand(c.data.high)], w, h)

suite "decode with alpha":
  test "every file with a known plane matches the independent model":
    var n = 0
    for c in allCases:
      if c.alpha.len == 0 or c.base == "": continue
      if not Fast and c.base == "acro_crop-video" and "_m0_f1" notin c.name and
          "_m1_c0_f2" notin c.name: continue
      var w, h = 0
      let got = decodeAll(c.data, w, h)
      var bw, bh = 0
      let base = decodeVp8(baseFile(c.base), bw, bh, bgra = true)
      check base.len > 0
      check got.len == base.len
      check w == bw and h == bh
      if got.len == base.len:
        check got == model(base, c.alpha)
      inc n
    check n > 60
  test "files that must fail do fail (even though the VP8 data is fine)":
    for c in allCases:
      if c.name in MustFail:
        var w, h = 0
        check decodeAll(c.data, w, h).len == 0
  test "all-opaque plane equals the file without alpha":
    var w, h = 0
    let a = allCases.filterIt(it.name == "alph_all_opaque_raw")[0]
    let p = allCases.filterIt(it.name == "ct_plain_vp8")[0]
    check decodeAll(a.data, w, h) == decodeAll(p.data, w, h)
  test "RGBA mode swaps R and B only":
    var w, h = 0
    let c = allCases.filterIt(it.name == "alph_gen_simple_33x17_m0_f2")[0]
    let bgra = webpDecodeBgra(c.data, w, h)
    let rgba = webpDecodeRgba(c.data, w, h)
    check bgra.len == 33 * 17 and rgba.len == bgra.len
    for i in 0 ..< bgra.len:
      let p = bgra[i]
      check rgba[i] == ((p and 0xff00ff00'u32) or ((p and 0xff) shl 16) or ((p shr 16) and 0xff))
  test "VP8L inside VP8X ignores ALPH; raw VP8L / VP8 without RIFF decode":
    var w, h = 0
    let a = allCases.filterIt(it.name == "vp8l_x_ignores_alph")[0]
    let b = allCases.filterIt(it.name == "vp8l_plain_opaque")[0]
    check decodeAll(a.data, w, h) == decodeAll(b.data, w, h)
    check decodeAll(a.data, w, h).len == 33 * 17
    for name in ["raw_vp8", "raw_vp8l", "raw_alph_vp8"]:
      let c = allCases.filterIt(it.name == name)[0]
      var f: WebpFeatures
      check getFeatures(c.data, f) == vsOk
      check decodeAll(c.data, w, h).len == f.width * f.height

suite "webp loader":
  setup:
    let saved = desiredColorSpace()
  teardown:
    setDesiredColorSpace(saved)
  proc open(data: seq[byte], ext = ""): (Loader, Result) =
    var ret = Result.Unknown
    let l = acquireData(toStr(data), ext, LoaderOps(), ret)
    (l, ret)
  test "sniffed by RIFF/WEBP, extension and mime":
    let c = allCases.filterIt(it.name == "alph_gen_simple_33x17_m0_f1")[0]
    let (l, ret) = open(c.data)
    check ret == Result.Success and l != nil and l.kind == FileType.Webp and l of WebpLoader
    let im = ImageLoader(l)
    check im.w == 33.0'f32 and im.h == 17.0'f32
    check retrieve(l)
    let (l2, r2) = open(c.data, "webp")
    check r2 == Result.Success and l2.kind == FileType.Webp
    let raw = allCases.filterIt(it.name == "raw_vp8")[0]
    check open(raw.data)[1] != Result.Success
    check open(raw.data, "webp")[1] == Result.Success
    check open(newSeq[byte](), "webp")[1] != Result.Success
  test "color space: BGRA premultiplied, opaque flag from the file":
    for (name, opaque) in [("alph_gen_simple_33x17_m0_f1", false), ("ct_plain_vp8", true),
                           ("vp8l_plain", false), ("vp8l_plain_opaque", true)]:
      let c = allCases.filterIt(it.name == name)[0]
      for (want, expect) in [(ColorSpace.ARGB8888, ColorSpace.ARGB8888),
                             (ColorSpace.ARGB8888S, ColorSpace.ARGB8888),
                             (ColorSpace.ABGR8888, ColorSpace.ABGR8888),
                             (ColorSpace.ABGR8888S, ColorSpace.ABGR8888)]:
        setDesiredColorSpace(want)
        let (l, ret) = open(c.data)
        check ret == Result.Success
        check l.read()
        let bm = ImageLoader(l).bitmap()
        check bm != nil
        if bm != nil:
          check bm.cs == expect
          check bm.opaque == opaque
          check bm.premultiplied
          check bm.data.len == 33 * 17
          var w, h = 0
          let direct =
            if want in [ColorSpace.ARGB8888, ColorSpace.ARGB8888S]: webpDecodeBgra(c.data, w, h)
            else: webpDecodeRgba(c.data, w, h)
          check bm.data == direct
        check retrieve(l)
  test "decode failure: open succeeds, bitmap stays nil, read is true":
    for name in ["alph_empty", "alph_bad_method2", "ct_truncated_60", "alph_lossless_truncated",
                 "ct_vp8x_animation"]:
      let c = allCases.filterIt(it.name == name)[0]
      let (l, ret) = open(c.data)
      check ret == Result.Success
      if ret == Result.Success:
        check l.read()
        check ImageLoader(l).bitmap() == nil
        check retrieve(l)
  test "unsupported containers do not open":
    for name in ["ct_riff_not_webp", "tiny_garbage", "tiny_empty", "ct_vp8x_bad_size"]:
      let c = allCases.filterIt(it.name == name)[0]
      check open(c.data, "webp")[1] != Result.Success
  test "every WebP file of tests/data/webp loads":
    var n = 0
    for dir in ["", "gen", "lossy", "alph"]:
      for f in walkFiles(DataDir / dir / "*.webp"):
        let d = readBytes(f)
        var feat: WebpFeatures
        let ok = getFeatures(d, feat) == vsOk
        if ok and not Fast and feat.width * feat.height > 300_000: continue
        let (l, ret) = open(d, "webp")
        check (ret == Result.Success) == ok
        if ret == Result.Success:
          check l.read()
          let isFail = extractFilename(f).splitFile.name in MustFail
          let bm = ImageLoader(l).bitmap()
          if not isFail and bm != nil:
            check bm.w == uint32(feat.width) and bm.h == uint32(feat.height)
          check retrieve(l)
        inc n
    check n > 300




