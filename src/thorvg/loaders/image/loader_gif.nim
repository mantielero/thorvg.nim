## GIF animation loader (`GifLoader` of `tvgGifLoader.cpp`).
##
## Importing this module registers the loader for `FileType.Gif` (extension `.gif`, header
## sniffing on `GIF87a` / `GIF89a`). It is an `AnimLoader` that yields a bitmap: the
## decoded canvas (`ARGB8888`, or `ABGR8888` when the canvas asked for it) is rebuilt by
## `frame(no)` exactly like the original (incremental when stepping forward by one frame
## unless the current frame restores the previous canvas, otherwise from frame 0).
## Deviations (DECISIONS.md D-L5b-*): decoding and composition are synchronous (no task
## scheduler, D4), the data is a copied string, GIFs larger than 2^28 pixels are rejected.

import std/[math, strutils]
import ../../core/types
import ../../renderer/[render, loader]
import ./gif

type GifLoader* = ref object of AnimLoader
  surface: RenderSurface
  decoder: GifDecoder
  curIdx: int
  durationCache: float32      ## negative: not yet computed
  updated: bool

proc newGifLoader*(): GifLoader =
  result = GifLoader(durationCache: -1.0'f32, updated: true)
  result.initAnimLoader(FileType.Gif)

method openData*(l: GifLoader, data: string, ops: LoaderOps): Result =
  if not gifLoad(l.decoder, data, desiredColorSpace()): return Result.InvalidArguments
  l.w = float32(l.decoder.width)
  l.h = float32(l.decoder.height)
  l.segmentEnd = float32(l.decoder.frames.len)
  Result.Success

proc canvas(l: GifLoader): var seq[uint32] = l.surface.data

method read*(l: GifLoader): bool =
  if l.decoder.frames.len == 0 or not l.baseRead(): return true
  l.surface = newSurface(l.decoder.width, l.decoder.height, l.decoder.cs)
  l.decoder.compositeFrame(0, true, l.canvas)
  true

method sync*(l: GifLoader): bool =
  if not l.updated: return false
  l.updated = false
  true

method cacheable*(l: GifLoader): bool = false

method bitmap*(l: GifLoader): RenderSurface =
  if l.surface != nil and l.surface.data.len > 0: l.surface else: nil

method frame*(l: GifLoader, no: float32): bool =
  if l.surface == nil: return false
  var no = no + l.segmentBegin  # `no` is segment-relative
  if no < l.segmentBegin: no = l.segmentBegin
  if no > l.segmentEnd: no = l.segmentEnd
  var newIdx = if no == no: int(no) else: 0  # NaN converts to 0 like x86
  let endIdx = int(ceil(l.segmentEnd)) - 1
  if endIdx >= 0 and newIdx > endIdx: newIdx = endIdx
  if newIdx == l.curIdx: return false
  if newIdx < l.curIdx or newIdx > l.curIdx + 1 or
      l.decoder.frames[l.curIdx].disposal == DisposalPrevious:
    # rebuild the canvas by accumulating frames from frame 0
    for i in 0 ..< l.canvas.len: l.canvas[i] = 0
    for i in 0 .. newIdx:
      let draw = i == newIdx or l.decoder.frames[i].disposal != DisposalPrevious
      l.decoder.compositeFrame(i, draw, l.canvas)
  else:
    l.decoder.compositeFrame(newIdx, true, l.canvas)
  l.curIdx = newIdx
  l.updated = true
  true

method curFrame*(l: GifLoader): float32 = float32(l.curIdx) - l.segmentBegin

method duration*(l: GifLoader): float32 =
  if l.durationCache < 0.0'f32:
    l.durationCache = l.decoder.duration(l.segmentBegin, l.segmentEnd)
  l.durationCache

method segment*(l: GifLoader, b, e: float32): Result =
  var (b, e) = (b, e)
  if b < 0.0'f32: b = 0.0'f32
  if e > float32(l.decoder.frames.len): e = float32(l.decoder.frames.len)
  if b > e: return Result.InvalidArguments
  l.segmentBegin = b
  l.segmentEnd = e
  l.durationCache = -1.0'f32
  Result.Success

proc sniffGif(data: string): bool =
  data.len >= 6 and data.startsWith("GIF") and data[3 .. 5] in ["87a", "89a"]

registerLoader(FileType.Gif, proc (): Loader = newGifLoader(), sniffGif)
