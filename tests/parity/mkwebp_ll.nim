## Minimal WebP lossless (VP8L) ENCODER used only to build test images for the VP8L decoder.
## It is written from the bitstream specification and deliberately simple (greedy matching,
## random choices from a seed) but covers every decoder feature: all four transforms in any
## order, color cache, palette packing (1/2/4/8 bits), backward references with plane
## codes, meta prefix images with several Huffman groups, simple / normal / repeat-coded
## Huffman code descriptions and `max_symbol`.
import std/[random, bitops]
import ./mkwebp_tf
import thorvg/loaders/image/webp/vp8l

export mkwebp_tf.subSample

type
  TfKind* = enum tfPredictor, tfCrossColor, tfSubtractGreen, tfPalette   ## spec order
  TfSpec* = object
    kind*: TfKind
    bits*: int
  Cfg* = object
    transforms*: seq[TfSpec]
    cacheBits*, subCacheBits*: int      ## 0 = no color cache
    metaBits*, groups*: int             ## metaBits 0 = single group
    backrefs*, simpleCodes*, repeatCodes*, useMax*: bool

  BitWriter = object
    buf: seq[byte]
    acc: uint64
    n: int

  Code = object
    bits: seq[int]       ## code length per symbol (0 when the code has a single symbol)
    codes: seq[uint32]   ## canonical codes (MSB first)

  Tok = object
    kind: int            ## 0 literal, 1 cache hit, 2 copy
    pos, length, distCode: int
    value: uint32        ## literal pixel or cache index

const
  CodeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  CacheMul = 0x1e35a7bd'u32

proc put(bw: var BitWriter, v, nbits: int) =
  doAssert v >= 0 and v < (1 shl nbits), "value does not fit"
  bw.acc = bw.acc or (uint64(v) shl uint64(bw.n))
  bw.n += nbits
  while bw.n >= 8:
    bw.buf.add byte(bw.acc and 0xff)
    bw.acc = bw.acc shr 8
    bw.n -= 8

proc finish(bw: var BitWriter): seq[byte] =
  if bw.n > 0: bw.buf.add byte(bw.acc and 0xff)
  bw.buf

func huffLengths(freq: seq[int], maxLen: int): seq[int] =
  ## Huffman code lengths limited to `maxLen` by halving the counts until the tree fits.
  result = newSeq[int](freq.len)
  var f = freq
  var leaves: seq[int]
  for i, v in f:
    if v > 0: leaves.add i
  if leaves.len == 1:
    result[leaves[0]] = 1
    return
  while true:
    var weight: seq[int]
    var parent: seq[int]
    for i in leaves:
      weight.add f[i]
      parent.add -1
    let n = leaves.len
    for _ in 1 ..< n:
      var a, b = -1
      for j in 0 ..< weight.len:
        if parent[j] < 0:
          if a < 0 or weight[j] < weight[a]:
            b = a
            a = j
          elif b < 0 or weight[j] < weight[b]:
            b = j
      weight.add weight[a] + weight[b]
      parent.add -1
      parent[a] = weight.len - 1
      parent[b] = weight.len - 1
    var depth = newSeq[int](weight.len)
    for j in countdown(weight.len - 2, 0): depth[j] = depth[parent[j]] + 1
    if max(depth[0 ..< n]) <= maxLen:
      for k, i in leaves: result[i] = depth[k]
      return
    for i in leaves: f[i] = (f[i] + 1) div 2

func canonical(lens: seq[int]): seq[uint32] =
  var count: array[17, uint32]
  for l in lens:
    if l > 0: inc count[l]
  var next: array[17, uint32]
  var code = 0'u32
  for l in 1 .. 16:
    code = (code + count[l - 1]) shl 1
    next[l] = code
  result = newSeq[uint32](lens.len)
  for i, l in lens:
    if l > 0:
      result[i] = next[l]
      inc next[l]

func reverseBits(v: uint32, n: int): int =
  for i in 0 ..< n:
    if ((v shr uint32(i)) and 1) != 0: result = result or (1 shl (n - 1 - i))

func makeCode(lens: seq[int]): Code =
  var nz = 0
  for l in lens:
    if l > 0: inc nz
  result = Code(codes: canonical(lens), bits: lens)
  if nz == 1: result.bits = newSeq[int](lens.len)

proc putSym(bw: var BitWriter, c: Code, sym: int) =
  let n = c.bits[sym]
  if n > 0: bw.put(reverseBits(c.codes[sym], n), n)

proc writeLengths(bw: var BitWriter, lens: seq[int], cfg: Cfg) =
  ## Normal code description: code-length code, optional `max_symbol`, tokens.
  var n = lens.len
  if cfg.useMax:
    while n > 1 and lens[n - 1] == 0: dec n
  var toks: seq[tuple[sym, extra: int]]
  var prev = 8
  var i = 0
  while i < n:
    let v = lens[i]
    var run = 1
    while i + run < n and lens[i + run] == v: inc run
    i += run
    var left = run
    if v == 0:
      while left > 0:
        if cfg.repeatCodes and left >= 11:
          let k = min(left, 138)
          toks.add (18, k - 11)
          left -= k
        elif cfg.repeatCodes and left >= 3:
          let k = min(left, 10)
          toks.add (17, k - 3)
          left -= k
        else:
          toks.add (0, 0)
          dec left
    else:
      if v != prev:
        toks.add (v, 0)
        prev = v
        dec left
      while cfg.repeatCodes and left >= 3:
        let k = min(left, 6)
        toks.add (16, k - 3)
        left -= k
      while left > 0:
        toks.add (v, 0)
        dec left
  if cfg.useMax and toks.len < 2: toks.add (0, 0)
  var freq = newSeq[int](19)
  for t in toks: inc freq[t.sym]
  let cl = huffLengths(freq, 7)
  let cc = makeCode(cl)
  var numCodes = 19
  while numCodes > 4 and cl[CodeLengthOrder[numCodes - 1]] == 0: dec numCodes
  bw.put(numCodes - 4, 4)
  for k in 0 ..< numCodes: bw.put(cl[CodeLengthOrder[k]], 3)
  if cfg.useMax:
    var k = 0
    while toks.len - 2 >= (1 shl (2 + 2 * k)): inc k
    bw.put(1, 1)
    bw.put(k, 3)
    bw.put(toks.len - 2, 2 + 2 * k)
  else:
    bw.put(0, 1)
  for t in toks:
    bw.putSym(cc, t.sym)
    if t.sym == 16: bw.put(t.extra, 2)
    elif t.sym == 17: bw.put(t.extra, 3)
    elif t.sym == 18: bw.put(t.extra, 7)

proc writeCode(bw: var BitWriter, freq0: seq[int], cfg: Cfg, r: var Rand): Code =
  var freq = freq0
  var used: seq[int]
  for i, v in freq:
    if v > 0: used.add i
  if used.len == 0:
    freq[0] = 1
    used = @[0]
  let lens = huffLengths(freq, 15)
  result = makeCode(lens)
  if used.len <= 2 and used[^1] < 256 and cfg.simpleCodes and r.rnd(2) == 0:
    bw.put(1, 1)
    bw.put(used.len - 1, 1)
    if used[0] < 2:
      bw.put(0, 1)
      bw.put(used[0], 1)
    else:
      bw.put(1, 1)
      bw.put(used[0], 8)
    if used.len == 2: bw.put(used[1], 8)
  else:
    bw.put(0, 1)
    bw.writeLengths(lens, cfg)

func prefixEncode(v: int): tuple[sym, nbits, extra: int] =
  if v <= 4: return (v - 1, 0, 0)
  let d = v - 1
  let h = fastLog2(d)
  let second = (d shr (h - 1)) and 1
  (2 * h + second, h - 1, d and ((1 shl (h - 1)) - 1))

func planeDist(pc, w: int): int =
  let code = CodeToPlane[pc - 1]
  max(1, (code shr 4) * w + 8 - (code and 0xf))

func cacheHash(p: uint32, bits: int): int = int((p * CacheMul) shr uint32(32 - bits))

func tokenize(pix: seq[uint32], w, cacheBits: int, backrefs: bool): seq[Tok] =
  var cache = newSeq[uint32](if cacheBits > 0: 1 shl cacheBits else: 0)
  var cands: seq[int]
  for pc in 1 .. 120:
    let d = planeDist(pc, w)
    if d notin cands: cands.add d
  cands.add [300, 1000, w * 9 + 3]
  var pos = 0
  while pos < pix.len:
    var bestLen, bestDist = 0
    if backrefs:
      let maxLen = min(4096, pix.len - pos)
      for d in cands:
        if d <= pos:
          var l = 0
          while l < maxLen and pix[pos + l] == pix[pos + l - d]: inc l
          if l > bestLen:
            bestLen = l
            bestDist = d
    var t = Tok(pos: pos, value: pix[pos])
    var step = 1
    if bestLen >= 3:
      t.kind = 2
      t.length = bestLen
      t.distCode = bestDist + 120
      for pc in countdown(120, 1):
        if planeDist(pc, w) == bestDist: t.distCode = pc
      step = bestLen
    elif cacheBits > 0 and cache[cacheHash(pix[pos], cacheBits)] == pix[pos]:
      t.kind = 1
      t.value = uint32(cacheHash(pix[pos], cacheBits))
    result.add t
    for k in pos ..< pos + step:
      if cacheBits > 0: cache[cacheHash(pix[k], cacheBits)] = pix[k]
    pos += step

proc encodeImage(bw: var BitWriter, pix: seq[uint32], w, h: int, level0: bool, cfg: Cfg,
                 r: var Rand)

proc writeMeta(bw: var BitWriter, w, h: int, cfg: Cfg, r: var Rand): seq[int] =
  ## Meta prefix image: returns the Huffman group of every tile.
  let mb = cfg.metaBits
  bw.put(1, 1)
  bw.put(mb - 2, 3)
  var meta: seq[uint32]
  for _ in 0 ..< subSample(w, mb) * subSample(h, mb):
    let g = r.rnd(cfg.groups)
    result.add g
    meta.add (uint32(r.rnd(256)) shl 24) or (uint32(g) shl 8) or uint32(r.rnd(256))
  bw.encodeImage(meta, subSample(w, mb), subSample(h, mb), false, cfg, r)

proc encodeImage(bw: var BitWriter, pix: seq[uint32], w, h: int, level0: bool, cfg: Cfg,
                 r: var Rand) =
  let cacheBits = if level0: cfg.cacheBits else: cfg.subCacheBits
  let toks = tokenize(pix, w, cacheBits, cfg.backrefs)
  if cacheBits > 0:
    bw.put(1, 1)
    bw.put(cacheBits, 4)
  else:
    bw.put(0, 1)
  var tileGroup: seq[int]
  if level0:
    if cfg.metaBits > 0: tileGroup = bw.writeMeta(w, h, cfg, r)
    else: bw.put(0, 1)
  let numGroups = if tileGroup.len == 0: 1 else: max(tileGroup) + 1
  let tw = if cfg.metaBits > 0: subSample(w, cfg.metaBits) else: 1
  proc groupOf(pos: int): int =
    if tileGroup.len == 0: return 0
    tileGroup[((pos div w) shr cfg.metaBits) * tw + ((pos mod w) shr cfg.metaBits)]
  let sizes = [280 + (if cacheBits > 0: 1 shl cacheBits else: 0), 256, 256, 256, 40]
  var freq = newSeq[array[5, seq[int]]](numGroups)
  for g in 0 ..< numGroups:
    for k in 0 ..< 5: freq[g][k] = newSeq[int](sizes[k])
  for t in toks:
    let g = groupOf(t.pos)
    case t.kind
    of 0:
      inc freq[g][0][int((t.value shr 8) and 0xff)]
      inc freq[g][1][int((t.value shr 16) and 0xff)]
      inc freq[g][2][int(t.value and 0xff)]
      inc freq[g][3][int(t.value shr 24)]
    of 1: inc freq[g][0][280 + int(t.value)]
    else:
      inc freq[g][0][256 + prefixEncode(t.length).sym]
      inc freq[g][4][prefixEncode(t.distCode).sym]
  var codes = newSeq[array[5, Code]](numGroups)
  for g in 0 ..< numGroups:
    for k in 0 ..< 5: codes[g][k] = bw.writeCode(freq[g][k], cfg, r)
  for t in toks:
    let c = codes[groupOf(t.pos)]
    case t.kind
    of 0:
      bw.putSym(c[0], int((t.value shr 8) and 0xff))
      bw.putSym(c[1], int((t.value shr 16) and 0xff))
      bw.putSym(c[2], int(t.value and 0xff))
      bw.putSym(c[3], int(t.value shr 24))
    of 1: bw.putSym(c[0], 280 + int(t.value))
    else:
      let l = prefixEncode(t.length)
      bw.putSym(c[0], 256 + l.sym)
      bw.put(l.extra, l.nbits)
      let d = prefixEncode(t.distCode)
      bw.putSym(c[4], d.sym)
      bw.put(d.extra, d.nbits)

proc encodeVp8l*(pix: seq[uint32], w, h: int, cfg: Cfg, seed: int, hasAlpha = true,
                 header = true): seq[byte] =
  ## VP8L payload (signature byte onwards); `header = false` gives the headerless stream of
  ## an `ALPH` chunk. Palette transforms need at most 256 distinct colors.
  var bw: BitWriter
  var r = initRand(seed)
  if header:
    bw.put(0x2f, 8)
    bw.put(w - 1, 14)
    bw.put(h - 1, 14)
    bw.put(int(hasAlpha), 1)
    bw.put(0, 3)
  var cur = pix
  var cw = w
  for spec in cfg.transforms:
    bw.put(1, 1)
    bw.put(ord(spec.kind), 2)
    var t: Tf
    case spec.kind
    of tfPredictor, tfCrossColor:
      t = if spec.kind == tfPredictor: predictor(cur, cw, h, spec.bits, r)
          else: crossColor(cur, cw, h, spec.bits, r)
      bw.put(spec.bits - 2, 3)
      bw.encodeImage(t.side, subSample(cw, spec.bits), subSample(h, spec.bits), false, cfg, r)
    of tfSubtractGreen: t = subtractGreen(cur, cw)
    of tfPalette:
      t = palette(cur, cw, h)
      bw.put(t.numColors - 1, 8)
      bw.encodeImage(t.side, t.numColors, 1, false, cfg, r)
    cur = t.pix
    cw = t.width
  bw.put(0, 1)
  bw.encodeImage(cur, cw, h, true, cfg, r)
  bw.finish()

proc encodeAlpha*(alpha: seq[byte], w, h: int, cfg: Cfg, seed: int): seq[byte] =
  ## Headerless lossless stream of an alpha plane (alpha value in the green channel).
  var pix = newSeq[uint32](alpha.len)
  for i, a in alpha: pix[i] = 0xff000000'u32 or (uint32(a) shl 8)
  encodeVp8l(pix, w, h, cfg, seed, header = false)

proc le32(v: int): seq[byte] = @[byte(v and 255), byte((v shr 8) and 255),
                                 byte((v shr 16) and 255), byte((v shr 24) and 255)]

proc riffWebp*(payload: seq[byte], fourcc = "VP8L"): seq[byte] =
  ## RIFF/WEBP container with one chunk.
  let padded = payload.len + (payload.len and 1)
  result = @[byte('R'), byte('I'), byte('F'), byte('F')] & le32(4 + 8 + padded) &
    @[byte('W'), byte('E'), byte('B'), byte('P')]
  for c in fourcc: result.add byte(c)
  result.add le32(payload.len)
  result.add payload
  if payload.len != padded: result.add 0'u8
