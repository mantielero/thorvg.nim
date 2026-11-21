## Generator of lossy WebP test files that exercise decoder features absent from files made
## by real encoders (simple filter, sharpness, loop-filter deltas, several token partitions,
## skip probability, relative segment data, tiny sizes, extreme quantizers).
##
## A bool decoder turns ANY byte string into a valid sequence of symbols distributed
## like the model, so the key frame is built as: header bits written with a real bool
## encoder (RFC 6386 section 7.3), followed by seeded random bytes that decode to random
## intra modes and DCT tokens. The decoded images are noise, but every mode, token
## category and filter path gets used; parity with the C++ decoder is what matters.
##
##   mkwebp_lossy [outdir]      (default: tests/data/webp/lossy)

import std/[os, random]
import thorvg/loaders/image/webp/vp8_tables

type
  BoolEnc = object
    buf: seq[byte]
    rng: int
    bottom: uint32
    bitCount: int

  Cfg = object
    name: string
    w, h: int
    simple: bool
    level, sharp: int
    lfDelta: bool
    parts: int            ## log2 of the number of token partitions
    seg: int              ## 0 = none, 1 = absolute data + map, 2 = relative data + map
    skipP: int            ## 0 = no skip probability
    q: int
    seed: int64

proc initEnc(): BoolEnc = BoolEnc(rng: 255, bitCount: 24)

proc addOne(e: var BoolEnc) =
  var i = e.buf.len - 1
  while i >= 0 and e.buf[i] == 255:
    e.buf[i] = 0
    dec i
  if i >= 0: inc e.buf[i]

proc putBit(e: var BoolEnc, prob, bit: int) =
  let split = 1 + (((e.rng - 1) * prob) shr 8)
  if bit != 0:
    e.bottom += uint32(split)
    e.rng -= split
  else:
    e.rng = split
  while e.rng < 128:
    e.rng = e.rng shl 1
    if (e.bottom and 0x80000000'u32) != 0: e.addOne()
    e.bottom = e.bottom shl 1
    dec e.bitCount
    if e.bitCount == 0:
      e.buf.add byte(e.bottom shr 24)
      e.bottom = e.bottom and 0xffffff'u32
      e.bitCount = 8

proc putFlag(e: var BoolEnc, b: bool) = e.putBit(128, int(b))

proc putValue(e: var BoolEnc, v, bits: int) =
  for i in countdown(bits - 1, 0): e.putBit(128, (v shr i) and 1)

proc putSigned(e: var BoolEnc, v, bits: int) =
  e.putValue(abs(v), bits)
  e.putFlag(v < 0)

proc flush(e: var BoolEnc) =
  var c = e.bitCount
  var v = e.bottom
  if (v and (1'u32 shl uint32(32 - c))) != 0: e.addOne()
  v = v shl uint32(c and 7)
  c = c shr 3
  for _ in 0 ..< c: v = v shl 8
  for _ in 0 ..< 4:
    e.buf.add byte(v shr 24)
    v = v shl 8

proc putOptSigned(e: var BoolEnc, v, bits: int) =
  e.putFlag(v != 0)
  if v != 0: e.putSigned(v, bits)

proc header(c: Cfg): seq[byte] =
  ## Partition 0 header bits (colorspace .. skip probability).
  var e = initEnc()
  e.putFlag(false)    # colorspace
  e.putFlag(false)    # clamp type
  e.putFlag(c.seg != 0)
  if c.seg != 0:
    e.putFlag(true)   # update map
    e.putFlag(true)   # update data
    e.putFlag(c.seg == 1)
    for s in 0 ..< 4: e.putOptSigned(if c.seg == 1: 20 + 30 * s else: (s - 1) * 9, 7)
    for s in 0 ..< 4: e.putOptSigned(if c.seg == 1: 8 + 12 * s else: (s - 2) * 5, 6)
    for p in [120, 0, 200]:
      e.putFlag(p != 0)
      if p != 0: e.putValue(p, 8)
  e.putFlag(c.simple)
  e.putValue(c.level, 6)
  e.putValue(c.sharp, 3)
  e.putFlag(c.lfDelta)
  if c.lfDelta:
    e.putFlag(true)   # update deltas
    for d in [4, 0, -3, 7]: e.putOptSigned(d, 6)
    for d in [-5, 3, 0, 9]: e.putOptSigned(d, 6)
  e.putValue(c.parts, 2)
  e.putValue(c.q, 7)
  for d in [0, 3, -2, 0, 5]: e.putOptSigned(d, 4)
  e.putFlag(false)    # ignored update-proba flag
  for i in 0 ..< CoeffsUpdateProba.len: e.putBit(int(CoeffsUpdateProba[i]), 0)
  e.putFlag(c.skipP != 0)
  if c.skipP != 0: e.putValue(c.skipP, 8)
  e.flush()
  e.buf

proc randomBytes(r: var Rand, n: int): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< n: result[i] = byte(r.rand(255))

proc le(v, n: int): seq[byte] =
  for i in 0 ..< n: result.add byte((v shr (8 * i)) and 0xff)

proc build(c: Cfg): seq[byte] =
  var r = initRand(c.seed)
  let mbs = ((c.w + 15) div 16) * ((c.h + 15) div 16)
  let nparts = 1 shl c.parts
  var part0 = header(c)
  part0.add r.randomBytes(80 * mbs + 16)
  var frame: seq[byte]
  let tag = 0 + (0 shl 1) + (1 shl 4) + (part0.len shl 5)    # key frame, version 0, show
  frame.add le(tag, 3)
  frame.add [0x9d'u8, 0x01, 0x2a]
  frame.add le(c.w, 2)
  frame.add le(c.h, 2)
  frame.add part0
  var parts: seq[seq[byte]]
  for p in 0 ..< nparts: parts.add r.randomBytes(500 * mbs div nparts + 64)
  for p in 0 ..< nparts - 1: frame.add le(parts[p].len, 3)
  for p in parts: frame.add p
  var f: seq[byte]
  let chunk = frame.len + (frame.len and 1)
  f.add "RIFF".toOpenArrayByte(0, 3)
  f.add le(4 + 8 + chunk, 4)
  f.add "WEBPVP8 ".toOpenArrayByte(0, 7)
  f.add le(frame.len, 4)
  f.add frame
  if (frame.len and 1) != 0: f.add 0'u8
  f

proc main() =
  let dir = if paramCount() > 0: paramStr(1) else: "tests/data/webp/lossy"
  createDir(dir)
  let cfgs = [
    Cfg(name: "gen_simple_33x17", w: 33, h: 17, simple: true, level: 20, q: 40, seed: 1),
    Cfg(name: "gen_simple_sharp5_64x48", w: 64, h: 48, simple: true, level: 40, sharp: 5, q: 25,
        seed: 2),
    Cfg(name: "gen_complex_lfdelta_50x50", w: 50, h: 50, level: 30, sharp: 3, lfDelta: true,
        q: 60, seed: 3),
    Cfg(name: "gen_parts2_80x80", w: 80, h: 80, level: 12, parts: 1, q: 30, seed: 4),
    Cfg(name: "gen_parts4_skip_seg1_97x65", w: 97, h: 65, level: 25, parts: 2, seg: 1,
        skipP: 100, q: 50, seed: 5),
    Cfg(name: "gen_parts8_17x130", w: 17, h: 130, level: 8, sharp: 7, parts: 3, q: 20, seed: 6),
    Cfg(name: "gen_seg2_simple_lfdelta_70x31", w: 70, h: 31, simple: true, level: 33,
        lfDelta: true, seg: 2, skipP: 200, q: 70, seed: 7),
    Cfg(name: "gen_nofilter_q0_48x32", w: 48, h: 32, q: 0, seed: 8),
    Cfg(name: "gen_q127_complex_45x20", w: 45, h: 20, level: 63, q: 127, seed: 9),
    Cfg(name: "gen_1x1", w: 1, h: 1, level: 10, q: 10, seed: 10),
    Cfg(name: "gen_16x1_skip", w: 16, h: 1, level: 5, skipP: 30, q: 90, seed: 11),
    Cfg(name: "gen_seg2_parts4_complex_120x40", w: 120, h: 40, level: 44, sharp: 2, parts: 2,
        seg: 2, lfDelta: true, q: 35, seed: 12)]
  for c in cfgs:
    let f = build(c)
    var s = newString(f.len)
    for i in 0 ..< f.len: s[i] = char(f[i])
    writeFile(dir / (c.name & ".webp"), s)

main()
