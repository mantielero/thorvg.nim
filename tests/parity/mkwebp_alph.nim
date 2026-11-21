## Container / alpha-plane test files for the WebP loader (unit L5c-C).
## `cases()` is shared by `tests/test_webp.nim` and by the generator below
## (`nim c -r tests/parity/mkwebp_alph.nim [dir]` writes `<name>.webp` into
## `tests/data/webp/alph`). The files are built from the lossy test pictures in
## `tests/data/webp/lossy` (their VP8 chunk is reused unchanged) and a synthetic alpha plane;
## the ALPH chunks use every method / filter / pre-processing combination, and a second
## group wraps the same payloads in odd, truncated, inconsistent or unusual containers.
import std/[os, random, sequtils]
import thorvg/loaders/image/webp/filters
import ./[mkwebp_ll, webp_lossy_util]

type
  Case* = object
    name*: string
    data*: seq[byte]
    base*: string        ## lossy file the VP8 chunk comes from ("" = none)
    alpha*: seq[byte]    ## expected alpha plane (empty = none / not decodable)

const LossyDir = currentSourcePath().parentDir.parentDir / "data" / "webp" / "lossy"

func le(v, n: int): seq[byte] =
  for i in 0 ..< n: result.add byte((v shr (8 * i)) and 0xff)

func chunk*(fourcc: string, payload: openArray[byte], size = -1): seq[byte] =
  ## `fourcc size payload [pad]`; `size` overrides the announced size.
  for c in fourcc: result.add byte(c)
  result.add le(if size >= 0: size else: payload.len, 4)
  result.add payload
  if (payload.len and 1) != 0: result.add 0'u8

func riff*(chunks: openArray[seq[byte]], size = -1, form = "WEBP"): seq[byte] =
  var body: seq[byte]
  for c in form: body.add byte(c)
  for c in chunks: body.add c
  result = @[byte('R'), byte('I'), byte('F'), byte('F')] & le(if size >= 0: size else: body.len, 4) &
    body

func vp8x*(flags, w, h: int, size = 10): seq[byte] =
  chunk("VP8X", le(flags, 4) & le(w - 1, 3) & le(h - 1, 3), size)

proc vp8Chunk(base: string): (seq[byte], int, int) =
  ## VP8 payload (size taken from the chunk header) and the picture size of a lossy file.
  let f = readBytes(LossyDir / (base & ".webp"))
  let off = vp8Payload(f)
  let sz = int(f[off - 4]) or (int(f[off - 3]) shl 8) or (int(f[off - 2]) shl 16)
  let p = f[off ..< off + sz]
  (p, (int(p[6]) or (int(p[7]) shl 8)) and 0x3fff, (int(p[8]) or (int(p[9]) shl 8)) and 0x3fff)

func plane(w, h, seed: int): seq[byte] =
  ## Alpha pattern: smooth ramp, opaque and transparent blocks and noise.
  var r = initRand(seed)
  result = newSeq[byte](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let blk = ((x div 5) + (y div 4)) mod 7
      result[y * w + x] = byte(case blk
        of 0: 255
        of 1: 0
        of 2: r.rand(255)
        else: (x * 7 + y * 3) and 0xff)

func alphHeader(meth, filter, pre: int, rsrv = 0): byte =
  byte(meth or (filter shl 2) or (pre shl 4) or (rsrv shl 6))

proc alphChunk(pl: seq[byte], w, h, meth, fk: int, cfg: Cfg, seed: int, pre = 0): seq[byte] =
  ## ALPH payload for `pl` (the plane is filtered here, as an encoder does).
  let f = filter(pl, w, h, WebpFilter(fk))
  if meth == 0: @[alphHeader(0, fk, pre)] & f
  else: @[alphHeader(1, fk, pre)] & encodeAlpha(f, w, h, cfg, seed)

proc cases*(): seq[Case] =
  let palCfg = Cfg(transforms: @[TfSpec(kind: tfPalette)])
  let genCfg = Cfg(transforms: @[TfSpec(kind: tfPredictor, bits: 2)], backrefs: true, cacheBits: 4)
  let metaCfg = Cfg(metaBits: 2, groups: 3, backrefs: true)
  let plainCfg = Cfg()
  proc add(res: var seq[Case], name, base: string, data: seq[byte], alpha: seq[byte] = @[]) =
    res.add Case(name: name, data: data, base: base, alpha: alpha)
  # ---- ALPH variants on small lossy pictures ----
  for (base, cfgs) in [("gen_simple_33x17", @[palCfg, genCfg, plainCfg]),
                       ("gen_parts2_80x80", @[metaCfg, palCfg]),
                       ("gen_1x1", @[plainCfg]), ("gen_16x1_skip", @[genCfg]),
                       ("gen_parts4_skip_seg1_97x65", @[genCfg, metaCfg]),
                       ("acro_crop-video", @[palCfg, genCfg])]:
    let (vp8, w, h) = vp8Chunk(base)
    var pl = plane(w, h, w + h)
    for filter in 0 .. 3:
      let name = "alph_" & base & "_"
      let hasAlpha = vp8x(0x10, w, h)
      result.add name & "m0_f" & $filter, base,
        riff([hasAlpha, chunk("ALPH", alphChunk(pl, w, h, 0, filter, plainCfg, 0)),
              chunk("VP8 ", vp8)]), pl
      for k, cfg in cfgs:
        var src = pl
        if cfg.transforms.len > 0 and cfg.transforms[0].kind == tfPalette:
          for i in 0 ..< src.len: src[i] = byte(src[i] mod 5 * 60)   # few distinct values
        result.add name & "m1_c" & $k & "_f" & $filter, base,
          riff([hasAlpha, chunk("ALPH", alphChunk(src, w, h, 1, filter, cfg, k + filter)),
                chunk("VP8 ", vp8)]), src
  # ---- unusual containers ----
  let (vp8, w, h) = vp8Chunk("gen_simple_33x17")
  let pl = plane(w, h, 5)
  let alph = alphChunk(pl, w, h, 1, 1, genCfg, 3)
  let alphRaw = alphChunk(pl, w, h, 0, 2, plainCfg, 0)
  let hdr = vp8x(0x10, w, h)
  let b = "gen_simple_33x17"
  let vp8c = chunk("VP8 ", vp8)
  let alphC = chunk("ALPH", alph)
  result.add "ct_unknown_chunks", b, riff([hdr, chunk("ICCP", [1'u8, 2, 3, 4, 5]), chunk("ZZZZ", @[7'u8]),
    alphC, chunk("EXIF", [9'u8, 8, 7]), vp8c, chunk("EXIF", [1'u8, 2, 3])]), pl
  result.add "ct_unknown_after_vp8", b, riff([hdr, alphC, vp8c, chunk("XMP ", [1'u8, 2, 3])]), pl
  result.add "ct_two_alph_last_wins", b, riff([hdr, chunk("ALPH", @[byte 2]), alphC, vp8c]), pl
  result.add "ct_two_alph_last_bad", b, riff([hdr, alphC, chunk("ALPH", @[byte 0x40, 1, 2]), vp8c])
  result.add "ct_alph_odd_size", b, riff([hdr, chunk("ALPH", alphRaw & @[0'u8]), vp8c]), pl
  result.add "ct_alph_no_flag", b, riff([vp8x(0, w, h), alphC, vp8c]), pl
  result.add "ct_flag_no_alph", b, riff([hdr, vp8c])
  result.add "ct_no_vp8x_alph_chunk", b, riff([alphC, vp8c])
  result.add "ct_vp8x_canvas_mismatch", b, riff([vp8x(0x10, w + 1, h), alphC, vp8c])
  result.add "ct_vp8x_animation", b, riff([vp8x(0x12, w, h), alphC, vp8c])
  result.add "ct_vp8x_fragments", b, riff([vp8x(0x11, w, h), alphC, vp8c])
  result.add "ct_vp8x_bad_size", b, riff([vp8x(0x10, w, h, 11), alphC, vp8c])
  result.add "ct_vp8x_huge", b, riff([vp8x(0x10, 1 shl 24, 1 shl 24), alphC, vp8c])
  result.add "ct_riff_size_small", b, riff([hdr, alphC, vp8c], 30)
  result.add "ct_riff_size_tiny", b, riff([hdr, alphC, vp8c], 8)
  result.add "ct_riff_size_big", b, riff([hdr, alphC, vp8c], 100000)
  result.add "ct_riff_size_minus2", b, riff([hdr, alphC, vp8c], riff([hdr, alphC, vp8c]).len - 10)
  result.add "ct_riff_not_webp", b, riff([hdr, alphC, vp8c], form = "WEBX")
  result.add "ct_chunk_size_huge", b, riff([hdr, chunk("ZZZZ", @[1'u8], 0xfffffff7), alphC, vp8c])
  result.add "ct_chunk_size_past_end", b, riff([hdr, chunk("ZZZZ", @[1'u8], 4000), alphC, vp8c])
  result.add "ct_vp8_size_too_big", b, riff([hdr, alphC, chunk("VP8 ", vp8, vp8.len + 40)])
  result.add "ct_vp8_size_small", b, riff([hdr, alphC, chunk("VP8 ", vp8, 12)])
  let full = riff([hdr, alphC, vp8c])
  for cut in [12, 20, 25, 30, 40, 60, full.len div 2, full.len - 9, full.len - 1]:
    result.add "ct_truncated_" & $cut, b, full[0 ..< cut]
  result.add "ct_trailing_bytes", b, full & @[byte 1, 2, 3, 4, 5, 6, 7, 8, 9], pl
  let plain = riff([vp8c])
  result.add "ct_plain_vp8", b, plain
  result.add "ct_plain_vp8_trailing", b, plain & @[byte 0, 0, 0]
  let vp8odd = vp8 & @[0'u8]
  result.add "ct_plain_vp8_odd", b, riff([chunk("VP8 ", vp8odd)])
  result.add "ct_plain_vp8_odd_nopad", b, riff([chunk("VP8 ", vp8odd)])[0 ..< ^1]
  # ---- raw bitstreams without RIFF ----
  result.add "raw_vp8", b, vp8
  result.add "raw_vp8_trailing", b, vp8 & @[byte 0, 0, 0, 0]
  result.add "raw_alph_vp8", b, alphC & vp8c
  var ll = newSeq[uint32](w * h)
  for i in 0 ..< ll.len: ll[i] = 0xff000000'u32 or uint32((i * 2654435761) and 0xffffff)
  let llOpaque = encodeVp8l(ll, w, h, genCfg, 1, hasAlpha = false)
  let llAlpha = encodeVp8l(ll, w, h, plainCfg, 2, hasAlpha = true)
  result.add "raw_vp8l", "", llAlpha
  result.add "raw_vp8l_opaque", "", llOpaque
  # ---- VP8L inside VP8X ----
  let llC = chunk("VP8L", llAlpha)
  let llOpC = chunk("VP8L", llOpaque)
  result.add "vp8l_plain", "", riff([llC])
  result.add "vp8l_plain_opaque", "", riff([llOpC])
  result.add "vp8l_x_alpha_flag", "", riff([vp8x(0x10, w, h), llC])
  result.add "vp8l_x_noflag", "", riff([vp8x(0, w, h), llC])
  result.add "vp8l_x_noflag_opaque", "", riff([vp8x(0, w, h), llOpC])
  result.add "vp8l_x_flag_opaque", "", riff([vp8x(0x10, w, h), llOpC])
  result.add "vp8l_x_ignores_alph", "", riff([vp8x(0x10, w, h), alphC, llOpC])
  result.add "vp8l_x_canvas_mismatch", "", riff([vp8x(0x10, w + 2, h), llC])
  result.add "vp8l_trailing", "", riff([llC]) & @[byte 1, 2, 3]
  result.add "vp8l_truncated", "", riff([llC])[0 ..< 40]
  result.add "vp8l_size_big", "", riff([chunk("VP8L", llAlpha, llAlpha.len + 100)])
  result.add "vp8l_bad_sig", "", riff([chunk("VP8L", @[byte 0x2e] & llAlpha[1 .. ^1])])
  result.add "vp8l_bad_version", "", riff([chunk("VP8L", llAlpha[0 .. 3] & @[llAlpha[4] or 0xe0'u8] & llAlpha[5 .. ^1])])
  # ---- bad ALPH headers ----
  let rawBody = pl
  result.add "alph_bad_method2", b, riff([hdr, chunk("ALPH", @[byte 2] & rawBody), vp8c])
  result.add "alph_bad_pre2", b, riff([hdr, chunk("ALPH", @[byte 0x20] & rawBody), vp8c])
  result.add "alph_bad_reserved", b, riff([hdr, chunk("ALPH", @[byte 0x40] & rawBody), vp8c])
  result.add "alph_pre1_raw", b, riff([hdr, chunk("ALPH", @[byte 0x10] & rawBody), vp8c]), pl
  result.add "alph_empty", b, riff([hdr, chunk("ALPH", newSeq[byte]()), vp8c])
  result.add "alph_header_only", b, riff([hdr, chunk("ALPH", @[byte 0]), vp8c])
  result.add "alph_short_raw", b, riff([hdr, chunk("ALPH", @[byte 0] & rawBody[0 ..< rawBody.len - 1]), vp8c])
  result.add "alph_long_raw", b, riff([hdr, chunk("ALPH", @[byte 0] & rawBody & @[byte 1, 2, 3]), vp8c]), pl
  result.add "alph_lossless_header_only", b, riff([hdr, chunk("ALPH", @[byte 1]), vp8c])
  result.add "alph_lossless_truncated", b,
    riff([hdr, chunk("ALPH", alph[0 ..< alph.len div 2]), vp8c])
  result.add "alph_lossless_garbage", b,
    riff([hdr, chunk("ALPH", @[byte 1, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), vp8c])
  result.add "alph_all_opaque_raw", b, riff([hdr, chunk("ALPH", @[byte 0] & newSeq[byte](w * h).mapIt(255'u8)), vp8c]),
    newSeq[byte](w * h).mapIt(255'u8)
  result.add "alph_all_zero_raw", b, riff([hdr, chunk("ALPH", @[byte 0] & newSeq[byte](w * h)), vp8c]),
    newSeq[byte](w * h)
  # ---- tiny / degenerate files ----
  result.add "tiny_empty", "", newSeq[byte]()
  result.add "tiny_riff_only", "", riff(newSeq[seq[byte]]())
  result.add "tiny_12", "", riff(newSeq[seq[byte]]())[0 ..< 12]
  result.add "tiny_16", "", (riff([chunk("VP8 ", newSeq[byte]())]))[0 ..< 16]
  result.add "tiny_20", "", riff([chunk("VP8 ", @[byte 1, 2, 3, 4])])
  result.add "tiny_zero_vp8", "", riff([chunk("VP8 ", newSeq[byte](30))])
  result.add "tiny_zero_vp8l", "", riff([chunk("VP8L", newSeq[byte](30))])
  result.add "tiny_garbage", "", @[byte 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]

when isMainModule:
  let dir = if paramCount() >= 1: paramStr(1) else: currentSourcePath().parentDir.parentDir / "data" / "webp" / "alph"
  createDir dir
  var n = 0
  for c in cases():
    var s = newString(c.data.len)
    for i, v in c.data: s[i] = char(v)
    writeFile(dir / (c.name & ".webp"), s)
    inc n
  echo n, " files written to ", dir


