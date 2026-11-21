## VP8 decoder state and constants (`dec/vp8i.h`, `dec/common.h`, `dsp/dsp.h`).
##
## Ported from `src/modules/webp/static/dec/vp8i.h`. Pointers of the C++ decoder become
## indices: `mbInfo[0]` is the "left" context (`mb_info_ - 1`), `mbInfo[1 + x]` belongs to
## macroblock `x`. Output rows are not cached: the decoder keeps whole Y/U/V planes (see
## D-L5cB-1 in DECISIONS.md).

import ./vp8_bits

const
  # intra prediction modes (dec/common.h)
  BDcPred* = 0
  BTmPred* = 1
  BVePred* = 2
  BHePred* = 3
  BRdPred* = 4
  BVrPred* = 5
  BLdPred* = 6
  BVlPred* = 7
  BHdPred* = 8
  BHuPred* = 9
  NumBModes* = 10
  DcPred* = BDcPred
  VPred* = BVePred
  HPred* = BHePred
  TmPred* = BTmPred
  BDcPredNoTop* = 4
  BDcPredNoLeft* = 5
  BDcPredNoTopLeft* = 6
  NumMbSegments* = 4
  NumRefLfDeltas* = 4
  NumModeLfDeltas* = 4
  MaxNumPartitions* = 8
  NumTypes* = 4
  NumBands* = 8
  NumCtx* = 3
  NumProbas* = 11
  FrameHeaderSize* = 10    ## `VP8_FRAME_HEADER_SIZE`
  # work buffer layout (stride 32, one cache line)
  Bps* = 32
  YuvSize* = Bps * 17 + Bps * 9
  YOff* = Bps * 1 + 8
  UOff* = YOff + Bps * 16 + Bps
  VOff* = UOff + 16
  ## Largest picture (in pixels) accepted; the C++ decoder is only limited by malloc.
  MaxPixels* = 1 shl 26

type
  Vp8Status* = enum
    vsOk, vsOutOfMemory, vsInvalidParam, vsBitstreamError, vsUnsupportedFeature,
    vsSuspended, vsUserAbort, vsNotEnoughData

  Vp8FrameHeader* = object
    keyFrame*, show*: bool
    profile*, partitionLength*: int

  Vp8PictureHeader* = object
    width*, height*, xscale*, yscale*, colorspace*, clampType*: int

  Vp8SegmentHeader* = object
    useSegment*, updateMap*, absoluteDelta*: bool
    quantizer*, filterStrength*: array[NumMbSegments, int]

  Vp8FilterHeader* = object
    simple*: bool
    level*, sharpness*: int
    useLfDelta*: bool
    refLfDelta*: array[NumRefLfDeltas, int]
    modeLfDelta*: array[NumModeLfDeltas, int]

  Vp8FInfo* = object
    fLimit*, fIlevel*, fInner*, hevThresh*: int

  Vp8Mb* = object
    nz*, nzDc*: int       ## non-zero contexts (8 bits / 1 bit)

  Vp8MbData* = object
    coeffs*: array[384, int16]
    isI4x4*: bool
    imodes*: array[16, uint8]
    uvmode*: int
    nonZeroY*, nonZeroUv*: uint32
    skip*: bool
    segment*: int

  Vp8QuantMatrix* = object
    y1*, y2*, uv*: array[2, int]    ## [DC, AC]

  Vp8Decoder* = ref object
    status*: Vp8Status
    errorMsg*: string
    ready*: bool
    br*: Vp8BitReader
    frm*: Vp8FrameHeader
    pic*: Vp8PictureHeader
    filterHdr*: Vp8FilterHeader
    segmentHdr*: Vp8SegmentHeader
    mbW*, mbH*: int
    numParts*: int
    parts*: array[MaxNumPartitions, Vp8BitReader]
    dqm*: array[NumMbSegments, Vp8QuantMatrix]
    segmentProbas*: array[3, int]
    bands*: array[NumTypes * NumBands * NumCtx * NumProbas, uint8]
    useSkipProba*: bool
    skipP*: int
    intraT*: seq[uint8]
    intraL*: array[4, uint8]
    topY*, topU*, topV*: seq[uint8]
    mbInfo*: seq[Vp8Mb]
    fInfo*: seq[Vp8FInfo]
    yuvB*: seq[uint8]
    mbData*: seq[Vp8MbData]
    yPlane*, uPlane*, vPlane*: seq[uint8]
    yStride*, uvStride*: int
    mbX*, mbY*: int
    filterType*: int      ## 0 = off, 1 = simple, 2 = complex
    fstrengths*: array[NumMbSegments, array[2, Vp8FInfo]]

proc newVp8Decoder*(): Vp8Decoder =
  Vp8Decoder(numParts: 1)

proc setError*(dec: Vp8Decoder, error: Vp8Status, msg: string): bool {.discardable.} =
  ## `VP8SetError`: the oldest error wins. Always returns false.
  if dec.status == vsOk:
    dec.status = error
    dec.errorMsg = msg
    dec.ready = false
  false

func probaBase*(t, band, ctx: int): int {.inline.} =
  ## Start of the 11 probabilities of (type, band, context) in `Vp8Decoder.bands`.
  ((t * NumBands + band) * NumCtx + ctx) * NumProbas

func toI16*(x: int): int16 {.inline.} =
  ## C `int` to `int16_t` conversion (two's complement wrap).
  int16(((x + 32768) and 0xffff) - 32768)
