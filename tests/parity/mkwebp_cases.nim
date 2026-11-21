## Test images and encoder configurations for the VP8L decoder tests.
## `cases()` is shared by `tests/test_vp8l.nim` (exact round trip) and by the generator below
## (`nim c -r tests/parity/mkwebp_cases.nim <dir>` writes every case as `<name>.webp`, the
## input of `webp_ll_compare.ps1`).
import std/random
import ./[mkwebp_ll, mkwebp_tf]

type
  ImgKind* = enum ikGradient, ikColors, ikTiles, ikSkewed, ikAlpha
  Case* = object
    name*: string
    cfg*: Cfg
    kind*: ImgKind
    colors*: int       ## palette size of `ikColors`
    w*, h*, seed*: int

const Sizes* = [(1, 1), (1, 9), (9, 1), (5, 7), (33, 17), (64, 40), (101, 23)]

func mk(a, r, g, b: int): uint32 =
  (uint32(a and 0xff) shl 24) or (uint32(r and 0xff) shl 16) or
    (uint32(g and 0xff) shl 8) or uint32(b and 0xff)

proc synth*(c: Case): seq[uint32] =
  ## Deterministic test image (premultiplication is applied by the decoder, not here).
  var r = initRand(c.seed * 7919 + 13)
  let w = c.w
  let h = c.h
  result = newSeq[uint32](w * h)
  var pal: seq[uint32]
  for _ in 0 ..< max(c.colors, 24):
    pal.add mk(255, r.rnd(256), r.rnd(256), r.rnd(256))
  var tile: seq[uint32]
  for _ in 0 ..< 48: tile.add pal[r.rnd(16)]
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      case c.kind
      of ikGradient, ikAlpha:
        let a = if c.kind == ikGradient: 255 else: (case r.rnd(4)
                                                      of 0: 0
                                                      of 1: 255
                                                      else: r.rnd(256))
        result[i] = mk(a, x * 5 + y + r.rnd(4), x + y * 3, x * y + r.rnd(3))
      of ikColors:
        if x > 0 and r.rnd(10) < 7: result[i] = result[i - 1]
        elif y > 0 and r.rnd(2) == 0: result[i] = result[i - w]
        else: result[i] = pal[r.rnd(max(c.colors, 1))]
      of ikTiles:
        result[i] = if r.rnd(20) == 0: pal[16 + r.rnd(8)] else: tile[(y mod 6) * 8 + x mod 8]
      of ikSkewed:
        var v: array[3, int]
        for k in 0 ..< 3:
          while r.rnd(100) < 72 and v[k] < 255: inc v[k]
        result[i] = mk(255, v[0], v[1], v[2])

func tf(kind: TfKind, bits = 0): TfSpec = TfSpec(kind: kind, bits: bits)

proc cases*(): seq[Case] =
  var n = 0
  proc add(res: var seq[Case], name: string, kind: ImgKind, size: (int, int), cfg: Cfg,
           colors = 0) =
    inc n
    res.add Case(name: name & "_" & $size[0] & "x" & $size[1], cfg: cfg, kind: kind,
                 colors: colors, w: size[0], h: size[1], seed: n)
  let pred = tf(tfPredictor, 2)
  for size in Sizes:
    result.add "plain", ikGradient, size, Cfg()
    result.add "pred2", ikGradient, size, Cfg(transforms: @[pred])
    result.add "pred4", ikAlpha, size, Cfg(transforms: @[tf(tfPredictor, 4)])
    result.add "cross3", ikGradient, size, Cfg(transforms: @[tf(tfCrossColor, 3)])
    result.add "subgreen", ikAlpha, size, Cfg(transforms: @[tf(tfSubtractGreen)])
    result.add "chain", ikGradient, size, Cfg(transforms:
      @[tf(tfSubtractGreen), tf(tfPredictor, 3), tf(tfCrossColor, 2)], cacheBits: 6)
    result.add "chain2", ikAlpha, size, Cfg(transforms:
      @[tf(tfCrossColor, 5), tf(tfPredictor, 2), tf(tfSubtractGreen)], backrefs: true)
    for k in [2, 3, 4, 7, 16, 17, 200]:
      result.add "pal" & $k, ikColors, size, Cfg(transforms: @[tf(tfPalette)]), k
    result.add "palpred", ikTiles, size, Cfg(transforms: @[tf(tfPalette), tf(tfPredictor, 2)],
                                           backrefs: true)
    result.add "cache1", ikTiles, size, Cfg(cacheBits: 1)
    result.add "cache11", ikColors, size, Cfg(cacheBits: 11, backrefs: true), 40
    result.add "refs", ikTiles, size, Cfg(backrefs: true)
    result.add "refsub", ikColors, size, Cfg(backrefs: true, subCacheBits: 3, transforms:
      @[tf(tfPredictor, 2), tf(tfCrossColor, 2)]), 5
    result.add "meta2", ikGradient, size, Cfg(metaBits: 2, groups: 2)
    result.add "meta9", ikTiles, size, Cfg(metaBits: 3, groups: 9, backrefs: true, cacheBits: 4)
    result.add "codes", ikColors, size, Cfg(simpleCodes: true, repeatCodes: true, useMax: true,
                                          backrefs: true), 3
    result.add "skew", ikSkewed, size, Cfg(repeatCodes: true, useMax: true, simpleCodes: true,
                                         metaBits: 2, groups: 3)
    result.add "all", ikAlpha, size, Cfg(transforms:
      @[tf(tfSubtractGreen), tf(tfPredictor, 3), tf(tfCrossColor, 4)], cacheBits: 8,
      subCacheBits: 2, metaBits: 3, groups: 4, backrefs: true, simpleCodes: true,
      repeatCodes: true, useMax: true)

when isMainModule:
  import std/os
  let dir = if paramCount() > 0: paramStr(1) else: "tests/data/webp/gen"
  createDir dir
  for c in cases():
    let data = riffWebp(encodeVp8l(synth(c), c.w, c.h, c.cfg, c.seed, hasAlpha = c.kind == ikAlpha))
    var s = newStringOfCap(data.len)
    for b in data: s.add char(b)
    writeFile(dir / (c.name & ".webp"), s)
