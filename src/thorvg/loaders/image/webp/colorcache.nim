## VP8L color cache (utils/color_cache.cpp/.h): a direct-mapped cache of recent ARGB values
## addressed by a multiplicative hash.

const HashMul = 0x1e35a7bd'u32

type
  ColorCache* = object
    colors*: seq[uint32]
    hashShift: uint32

func initColorCache*(hashBits: int): ColorCache =
  ## `VP8LColorCacheInit`: `1 shl hashBits` zeroed entries.
  ColorCache(colors: newSeq[uint32](1 shl hashBits), hashShift: uint32(32 - hashBits))

func enabled*(cc: ColorCache): bool {.inline.} = cc.colors.len > 0

func insert*(cc: var ColorCache, argb: uint32) {.inline.} =
  cc.colors[int((HashMul * argb) shr cc.hashShift)] = argb

func lookup*(cc: ColorCache, key: int): uint32 {.inline.} = cc.colors[key]
