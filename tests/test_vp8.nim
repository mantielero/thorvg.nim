## WebP lossy (VP8) decoder tests.
##
## tests/data/webp/lossy holds real files (see README.md there) and files made by
## tests/parity/mkwebp_lossy.nim (random key frames that use every filter/partition/segment
## option). The expected values below are the dimensions and the FNV-1a hash of the BGRA
## words produced by the ORIGINAL C++ decoder (tests/parity/cpp_webp_dump_lossy.cpp), so the
## decoded pixels are checked bit for bit. The big files are only hashed in release builds.
## Corrupt and truncated inputs must never crash. The full C++ comparison, including mutated
## inputs, is tests/parity/webp_lossy_compare.ps1.
import std/[unittest, os]
import thorvg/loaders/image/webp/vp8
import ./parity/webp_lossy_util

const
  DataDir = currentSourcePath().parentDir / "data" / "webp" / "lossy"
  Fast = defined(release) or defined(danger)
  Expected = [
    ("acro_clip-maker", 400, 280, 0xA21FE110B233A3E8'u64),
    ("acro_collage-maker", 800, 560, 0xDD6FC5FF0BD0DB06'u64),
    ("acro_convert-to-png", 400, 281, 0x8A652D69E7C243D9'u64),
    ("acro_crop-video", 400, 280, 0x23968CD790627134'u64),
    ("acro_export-pdf", 400, 280, 0xF35E4B3F6E9E9B33'u64),
    ("acro_generate-qr-code", 400, 280, 0xE4CF9BFF3B2BD17D'u64),
    ("acro_illu_theme_DeepBlue_lightmode_1366x900", 1600, 1054, 0xCA3D348905994C2B'u64),
    ("acro_illu_theme_MutedYellow_lightmode_1366x900", 1600, 1054, 0x1D33C1200C7B533F'u64),
    ("acro_illu_theme_graphiteblue_dark", 2049, 1350, 0x4C1B88B432AFD1AA'u64),
    ("acro_illu_theme_softsage_dark", 2049, 1350, 0x4C596C47E3354C97'u64),
    ("acro_logo-maker", 800, 560, 0xFC0C508FED1535FD'u64),
    ("acro_remove-background", 400, 280, 0xF53F5380F63A1174'u64),
    ("acro_resize-image", 400, 281, 0x25BC18AFD02DAB80'u64),
    ("gen_16x1_skip", 16, 1, 0xABEAC711A31D2546'u64),
    ("gen_1x1", 1, 1, 0xFF64AA7EACA96223'u64),
    ("gen_complex_lfdelta_50x50", 50, 50, 0xA63241D975D45454'u64),
    ("gen_nofilter_q0_48x32", 48, 32, 0x891C3A52A2FE1ED4'u64),
    ("gen_parts2_80x80", 80, 80, 0x154BADC659B23AB4'u64),
    ("gen_parts4_skip_seg1_97x65", 97, 65, 0xA6D279E8FAFF61FB'u64),
    ("gen_parts8_17x130", 17, 130, 0x5443A5D8F5321DB5'u64),
    ("gen_q127_complex_45x20", 45, 20, 0x4E663A7F111969FA'u64),
    ("gen_seg2_parts4_complex_120x40", 120, 40, 0x20908FC4E60E32A5'u64),
    ("gen_seg2_simple_lfdelta_70x31", 70, 31, 0x3A0F7B01E9C26222'u64),
    ("gen_simple_33x17", 33, 17, 0x659FE77AB7E9CA4A'u64),
    ("gen_simple_sharp5_64x48", 64, 48, 0xD10F323D3443FBF3'u64),
    ("office_darkErrorIma", 257, 256, 0x17AC1EFA4C5E7FAA'u64),
    ("office_errorImage", 256, 256, 0x34D76B5E2ABDB963'u64),
    ("office_hcErrorImage", 256, 256, 0xD591EC801F7A2426'u64),
    ("thorvg_test_511x511", 511, 511, 0x9CAD6EC4764870D9'u64)]

proc payload(name: string): seq[byte] = payloadOf(readBytes(DataDir / (name & ".webp")))

proc fnv(px: seq[uint32]): uint64 =
  ## FNV-1a over the little-endian bytes of the words.
  result = 0xcbf29ce484222325'u64
  for v in px:
    for b in 0 ..< 4:
      result = (result xor uint64((v shr uint32(8 * b)) and 0xff'u32)) * 0x100000001b3'u64

proc nextRnd(s: var uint32): int =
  s = s * 1664525'u32 + 1013904223'u32
  int(s shr 8)

proc swapRb(v: uint32): uint32 =
  (v and 0xff00ff00'u32) or ((v and 0xff'u32) shl 16) or ((v shr 16) and 0xff'u32)

suite "vp8 decoder":
  test "pixels are bit-exact with the C++ decoder":
    for (name, w, h, hash) in Expected:
      let data = payload(name)
      check data.len > 10
      var gw, gh: int
      check vp8GetInfo(data, data.len, gw, gh)
      check (gw, gh) == (w, h)
      if Fast or w * h <= 600_000:
        let px = decodeVp8(data, gw, gh, bgra = true)
        check (gw, gh) == (w, h)
        check px.len == w * h
        check fnv(px) == hash

  test "real pictures are not trivial":
    for name in ["acro_clip-maker", "thorvg_test_511x511", "office_errorImage"]:
      var w, h: int
      let px = decodeVp8(payload(name), w, h)
      check px.len == w * h
      var diffs = 0
      for i in 1 ..< px.len:
        if px[i] != px[i - 1]: inc diffs
      check diffs > px.len div 20
      for v in px: check (v shr 24) == 255'u32

  test "rgba output is bgra with red and blue swapped":
    var w, h: int
    let data = payload("gen_simple_33x17")
    let a = decodeVp8(data, w, h, bgra = true)
    let b = decodeVp8(data, w, h, bgra = false)
    check a.len == 33 * 17
    check b.len == a.len
    for i in 0 ..< a.len: check swapRb(a[i]) == b[i]

  test "alpha plane is merged and premultiplied":
    var w, h: int
    let data = payload("gen_complex_lfdelta_50x50")
    let opaque = decodeVp8(data, w, h)
    check opaque.len == 2500
    var alpha = newSeq[byte](w * h)
    for i in 0 ..< alpha.len: alpha[i] = 255
    check decodeVp8(data, w, h, alpha) == opaque
    for i in 0 ..< alpha.len: alpha[i] = byte(i mod 256)
    let px = decodeVp8(data, w, h, alpha)
    check px.len == opaque.len
    for i in 0 ..< px.len:
      let a = uint32(alpha[i])
      check (px[i] shr 24) == a
      for sh in [0'u32, 8, 16]:
        let c = (opaque[i] shr sh) and 0xff'u32
        check ((px[i] shr sh) and 0xff'u32) == (c * (a * 32897'u32)) shr 23
    check decodeVp8(data, w, h, alpha[0 ..< 10]).len == 0   # alpha plane too short

  test "invalid input returns an empty result":
    var w, h: int
    check decodeVp8(newSeq[byte](), w, h).len == 0
    check decodeVp8(newSeq[byte](9), w, h).len == 0
    let good = payload("gen_1x1")
    var bad = good
    bad[3] = 0                                   # start code
    check decodeVp8(bad, w, h).len == 0
    bad = good
    bad[0] = bad[0] or 1                         # inter frame
    check decodeVp8(bad, w, h).len == 0
    bad = good
    bad[0] = bad[0] and 0xef                     # frame not shown
    check decodeVp8(bad, w, h).len == 0
    bad = good
    bad[6] = 0
    bad[7] = 0                                   # zero width
    check decodeVp8(bad, w, h).len == 0
    check vp8GetInfo(bad, bad.len, w, h) == false
    var px: seq[uint32]
    check decodeVp8Ex(good[0 ..< 20], w, h, px) != vsOk
    check px.len == 0

  test "huge dimensions are rejected before allocating":
    var w, h: int
    var huge = payload("gen_1x1")
    huge[6] = 0xff
    huge[7] = 0x3f
    huge[8] = 0xff
    huge[9] = 0x3f
    check decodeVp8(huge, w, h).len == 0

  test "corrupt and truncated inputs never crash":
    var seed = 12345'u32
    var decoded = 0
    for name in ["gen_16x1_skip", "gen_simple_33x17", "gen_parts4_skip_seg1_97x65",
                 "gen_seg2_simple_lfdelta_70x31", "gen_parts8_17x130", "acro_remove-background"]:
      let orig = payload(name)
      let count = if name == "acro_remove-background": 20 else: 50
      for k in 0 ..< count:
        var d = orig
        case k mod 3
        of 0:
          for _ in 0 ..< 1 + nextRnd(seed) mod 8:
            d[10 + nextRnd(seed) mod (d.len - 10)] = byte(nextRnd(seed) and 0xff)
        of 1:
          d.setLen(10 + nextRnd(seed) mod (d.len - 10))
        else:
          d[nextRnd(seed) mod 3] = byte(nextRnd(seed) and 0xff)
          d[10 + nextRnd(seed) mod 12] = byte(nextRnd(seed) and 0xff)
        var w, h: int
        let px = decodeVp8(d, w, h)
        if px.len > 0:
          inc decoded
          check px.len == w * h
    check decoded > 30
