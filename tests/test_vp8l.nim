## WebP lossless (VP8L) decoder tests. Images are produced by the independent test encoder
## (tests/parity/mkwebp_*.nim: every transform, color cache, palette packing, backward
## references, meta prefix images, all Huffman code description forms) and must decode to
## exactly the (premultiplied) source pixels. Real files in tests/data/webp are decoded for
## sanity (their bit-exactness against the C++ original is checked by
## tests/parity/webp_ll_compare.ps1). A mutation test feeds corrupt/truncated streams to the
## UNCHECKED decoder entry points, which must never raise.
import std/[unittest, os, random]
import thorvg/loaders/image/webp/vp8l
import parity/[mkwebp_ll, mkwebp_cases, mkwebp_tf]

const DataDir = currentSourcePath().parentDir / "data" / "webp"

func premul(argb: uint32): uint32 =
  let a = argb shr 24
  if a == 0xff: return argb
  func m(c, a: uint32): uint32 = (c * a * 32897'u32) shr 23
  (a shl 24) or (m((argb shr 16) and 0xff, a) shl 16) or (m((argb shr 8) and 0xff, a) shl 8) or
    m(argb and 0xff, a)

func swapRb(p: uint32): uint32 =
  (p and 0xff00ff00'u32) or ((p shr 16) and 0xff) or ((p and 0xff) shl 16)

proc toBytes(s: string): seq[byte] =
  for c in s: result.add byte(c)

proc chunkPayload(file: seq[byte], fourcc: string): seq[byte] =
  ## Payload of the first chunk `fourcc` of a RIFF/WEBP file (empty if absent).
  var pos = 12
  while pos + 8 <= file.len:
    let size = int(file[pos + 4]) or (int(file[pos + 5]) shl 8) or
      (int(file[pos + 6]) shl 16) or (int(file[pos + 7]) shl 24)
    var tag = ""
    for i in 0 ..< 4: tag.add char(file[pos + i])
    if tag == fourcc: return file[pos + 8 ..< min(file.len, pos + 8 + size)]
    pos += 8 + size + (size and 1)

proc pattern(w, h, seed: int): seq[byte] =
  var r = initRand(seed)
  for i in 0 ..< w * h:
    result.add byte(if r.rnd(3) == 0: r.rnd(256) else: (i div 5) mod 13 * 20)

suite "vp8l encoder round trip":
  test "every case decodes to the premultiplied source":
    var count = 0
    for c in cases():
      let src = synth(c)
      let data = encodeVp8l(src, c.w, c.h, c.cfg, c.seed, hasAlpha = c.kind == ikAlpha)
      var w, h = 0
      var hasAlpha = false
      let px = decodeUnchecked(data, w, h, hasAlpha)
      check (w, h) == (c.w, c.h)
      check hasAlpha == (c.kind == ikAlpha)
      var expected = newSeq[uint32](src.len)
      for i, p in src: expected[i] = premul(p)
      var ok = px == expected
      check ok
      if not ok: echo "FAILED case ", c.name
      var w2, h2 = 0
      var a2 = false
      let abgrPx = decodeVp8l(data, w2, h2, a2, abgr = true)
      for i in 0 ..< expected.len: expected[i] = swapRb(expected[i])
      ok = abgrPx == expected
      check ok
      inc count
    check count >= 150

  test "vp8lGetInfo and error paths":
    let c = cases()[40]
    let data = encodeVp8l(synth(c), c.w, c.h, c.cfg, c.seed)
    var w, h = 0
    var a = false
    check vp8lGetInfo(data, w, h, a)
    check (w, h) == (c.w, c.h)
    check not vp8lGetInfo(data[0 ..< 4], w, h, a)
    var bad = data
    bad[0] = 0x2e
    check not vp8lGetInfo(bad, w, h, a)
    check decodeVp8l(bad, w, h, a).len == 0
    bad = data
    bad[4] = bad[4] or 0x20     # non-zero version bits
    check not vp8lGetInfo(bad, w, h, a)
    check decodeVp8l(data[0 ..< data.len div 2], w, h, a).len == 0
    check decodeVp8l(newSeq[byte](0), w, h, a).len == 0

suite "vp8l alpha plane":
  test "headerless streams give the exact (still filtered) plane":
    let cfgs = [
      Cfg(transforms: @[TfSpec(kind: tfPalette)]),
      Cfg(transforms: @[TfSpec(kind: tfPalette)], backrefs: true, simpleCodes: true),
      Cfg(transforms: @[TfSpec(kind: tfPalette)], cacheBits: 3),    # general 32-bit path
      Cfg(transforms: @[TfSpec(kind: tfPalette)], metaBits: 2, groups: 3, backrefs: true),
      Cfg(),
      Cfg(backrefs: true, cacheBits: 5),
      Cfg(transforms: @[TfSpec(kind: tfPredictor, bits: 2)], backrefs: true)]
    for size in [(1, 1), (7, 5), (33, 17), (64, 20)]:
      for k, cfg in cfgs:
        let (w, h) = size
        var src = pattern(w, h, k + w)
        if cfg.transforms.len > 0 and cfg.transforms[0].kind == tfPalette:
          for i in 0 ..< src.len: src[i] = src[i] mod 6 * 3
        let data = encodeAlpha(src, w, h, cfg, k)
        check decodeAlphaUnchecked(data, w, h) == src
        check decodeVp8lAlpha(data, w, h) == src
    check decodeVp8lAlpha(newSeq[byte](0), 4, 4).len == 0
    check decodeVp8lAlpha(@[byte 1, 2, 3], 0, 4).len == 0

suite "vp8l real files":
  test "lossless samples decode with the dimensions of their header":
    var found = 0
    for f in walkFiles(DataDir / "*.webp"):
      let file = toBytes(readFile(f))
      let payload = chunkPayload(file, "VP8L")
      if payload.len > 0 and chunkPayload(file, "ALPH").len == 0:
        var w, h = 0
        var a = false
        check vp8lGetInfo(payload, w, h, a)
        var w2, h2 = 0
        let px = decodeVp8l(payload, w2, h2, a)
        check (w2, h2) == (w, h)
        check px.len == w * h
        if not a:
          for p in px: check (p shr 24) == 0xff
        inc found
    check found >= 1

suite "vp8l robustness":
  test "300 mutated or truncated streams never raise":
    var all: seq[seq[byte]]
    for c in cases():
      if c.w == 33 or c.w == 5:
        all.add encodeVp8l(synth(c), c.w, c.h, c.cfg, c.seed)
    for f in walkFiles(DataDir / "*.webp"):
      let payload = chunkPayload(toBytes(readFile(f)), "VP8L")
      if payload.len > 0 and payload.len < 20000: all.add payload
    var r = initRand(2024)
    var failures = 0
    for iter in 0 ..< 300:
      var d = all[r.rnd(all.len)]
      if iter mod 3 == 0:
        d.setLen(r.rnd(d.len))
      else:
        for _ in 0 ..< 1 + r.rnd(4):
          let lo = if r.rnd(8) == 0: 0 else: min(5, d.high)
          d[lo + r.rnd(d.len - lo)] = byte(r.rnd(256))
      var w, h = 0
      var a = false
      let px = decodeUnchecked(d, w, h, a)
      if px.len == 0: inc failures
      else: check px.len == w * h
      let alpha = decodeAlphaUnchecked(d, 1 + iter mod 40, 1 + iter mod 7)
      check alpha.len == 0 or alpha.len == (1 + iter mod 40) * (1 + iter mod 7)
    check failures > 50
