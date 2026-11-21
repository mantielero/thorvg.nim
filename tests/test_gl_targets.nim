## G1b: GL render targets + pool, stage buffer, texture manager
## (render_target.nim, gpu_buffer.nim, texture_mgr.nim).
## Needs a GL 3.3 context from wgl_ffi; exits 0 with a message when none can be created.
import std/unittest
import thorvg/core/[types, geom]
import thorvg/renderer/render
import thorvg/engine/gl/[gl_ffi, wgl_ffi, state_cache, render_target, gpu_buffer, texture_mgr]

const
  W = 16'i32
  H = 8'i32
  # RGBA8 readback words: R | G<<8 | B<<16 | A<<24
  PxRed = 0xFF0000FF'u32
  PxGreen = 0xFF00FF00'u32

let (created, ctxInit) = wglCreateOffscreen(int(W), int(H))
if not created:
  echo "SKIP: no GL 3.3 context could be created"
  quit(0)

var ctx = ctxInit

let baseline = glLiveObjects()

proc readFbo(fbo: GlId, w, h: int): seq[uint32] =
  ## Raw readback of a framebuffer (the caller invalidates its state cache afterwards).
  bindFramebuffer(GlReadFramebuffer, fbo)
  readPixels(0, 0, int32(w), int32(h), result)

proc readTexture(tex: GlId, w, h: int): seq[uint32] =
  let fbo = genFramebuffer()
  bindFramebuffer(GlFramebuffer, fbo)
  framebufferTexture2D(GlFramebuffer, GlColorAttachment0, GlTexture2D, tex, 0)
  check checkFramebufferStatus(GlFramebuffer) == GlFramebufferComplete
  result = readFbo(fbo, w, h)
  bindFramebuffer(GlFramebuffer, ctx.fbo)
  deleteFramebuffer(fbo)

proc px(a, r, g, b: uint32): uint32 =
  ## One ARGB8888 word.
  (a shl 24) or (r shl 16) or (g shl 8) or b

func vp(w, h: int32): Region = initRegion(0, 0, w, h)

suite "render target":
  test "FBO is complete, 4x multisampled, resolve target is single sample":
    var cache: GlStateCache
    let t = newGlRenderTarget()
    check t.invalid
    t.init(cache, 16, 8, ctx.fbo)
    check not t.invalid
    check t.width == 16 and t.height == 8
    check t.fbo != 0 and t.resolvedFbo != 0 and t.colorTex != 0
    check cache.drawFramebuffer.value == ctx.fbo  # C++: rebinds `resolveId`
    bindFramebuffer(GlFramebuffer, t.fbo)
    check checkFramebufferStatus(GlFramebuffer) == GlFramebufferComplete
    check getInteger(GlSamples) == 4
    bindFramebuffer(GlFramebuffer, t.resolvedFbo)
    check checkFramebufferStatus(GlFramebuffer) == GlFramebufferComplete
    check getInteger(GlSamples) == 0
    bindFramebuffer(GlFramebuffer, ctx.fbo)
    cache.invalidate()
    t.reset(cache)
    check t.invalid and t.colorTex == 0 and t.resolvedFbo == 0
    t.reset(cache)  # idempotent
    check getError() == GlNoError

  test "zero size gives an invalid target":
    var cache: GlStateCache
    let t = newGlRenderTarget()
    t.init(cache, 0, 8, 0)
    check t.invalid

  test "MSAA resolve blit reads back exactly":
    var cache: GlStateCache
    let t = newGlRenderTarget()
    t.init(cache, uint32(W), uint32(H), ctx.fbo)
    bindFramebuffer(GlFramebuffer, t.fbo)
    viewport(0, 0, W, H)
    clearColor(1, 0, 0, 1)
    clear(GlColorBufferBit)
    enable(GlScissorTest)
    scissor(0, 0, W div 2, H)
    clearColor(0, 1, 0, 1)
    clear(GlColorBufferBit)
    disable(GlScissorTest)
    bindFramebuffer(GlReadFramebuffer, t.fbo)
    bindFramebuffer(GlDrawFramebuffer, t.resolvedFbo)
    blitFramebuffer(0, 0, W, H, 0, 0, W, H, GlColorBufferBit, GlNearest)
    let pixels = readFbo(t.resolvedFbo, int(W), int(H))
    check pixels.len == int(W * H)
    var wrong = 0
    for y in 0 ..< int(H):
      for x in 0 ..< int(W):
        let want = if x < int(W) div 2: PxGreen else: PxRed
        if pixels[y * int(W) + x] != want: inc wrong
    check wrong == 0
    check readTexture(t.colorTex, int(W), int(H)) == pixels
    bindFramebuffer(GlFramebuffer, ctx.fbo)
    cache.invalidate()
    t.reset(cache)
    check getError() == GlNoError

  test "alignPow2":
    check alignPow2(0) == 1
    check alignPow2(1) == 1
    check alignPow2(3) == 4
    check alignPow2(64) == 64
    check alignPow2(65) == 128

  test "pool: pow2 sizes, clamp to max, same object for same size":
    var cache: GlStateCache
    let before = glLiveObjects()
    let pool = newGlRenderTargetPool(64, 32)
    let a = pool.getRenderTarget(cache, vp(10, 5), ctx.fbo)
    check a.width == 16 and a.height == 8
    check a.viewport == vp(10, 5)
    let b = pool.getRenderTarget(cache, vp(12, 7))
    check b == a  # same object: the pool has no "in use" notion (as in C++)
    check b.viewport == vp(12, 7)
    let c = pool.getRenderTarget(cache, vp(40, 3))
    check c != a
    check c.width == 64  # 40 -> 64 (also the max width)
    check c.height == 4
    let d = pool.getRenderTarget(cache, vp(100, 100))
    check d.width == 64 and d.height == 32
    check pool.getRenderTarget(cache, vp(64, 32)) == d
    check pool.targets.len == 3
    check glLiveObjects() > before
    pool.destroy(cache)
    check pool.targets.len == 0
    check a.invalid and c.invalid and d.invalid
    check glLiveObjects() == before
    check getError() == GlNoError

  test "dropping a target without reset deletes its GL objects":
    var cache: GlStateCache
    let before = glLiveObjects()
    proc scoped() =
      let t = newGlRenderTarget()
      t.init(cache, 8, 8, ctx.fbo)
      check glLiveObjects() == before + 5  # 2 FBOs, 2 renderbuffers, 1 texture
    scoped()
    check glLiveObjects() == before

suite "stage buffer":
  test "alignment of UBO offsets":
    let aln = int(getInteger(GlUniformBufferOffsetAlignment))
    check aln > 0 and aln mod 4 == 0
    let s = newGlStageBuffer()
    check s.push([1'f32, 2, 3, 4], true) == 0  # empty array: already aligned
    check s.push([5'f32, 6, 7]) == 16
    let off = s.push([8'f32, 9, 10, 11], true)
    check off mod aln == 0
    check off >= 28
    check s.stageSize == off + 16
    check s.reserve(8) == off + 16
    check s.reserve(4, true) mod aln == 0

  test "reserve extends with zero words, push converts types":
    let s = newGlStageBuffer()
    check s.reserve(12) == 0
    check s.stage == @[0'u32, 0, 0]
    check s.push([1.5'f32]) == 12
    check s.push([-1'i32]) == 16
    check s.push([7'u32]) == 20
    check bitsFloat(s.stage[3]) == 1.5'f32
    check s.stage[4] == 0xFFFFFFFF'u32 and s.stage[5] == 7
    check s.reserveAux(8) == 0
    check s.pushAux([rgbaWord(1, 2, 3, 4)]) == 8
    check s.aux[2] == 0x04030201'u32
    check s.pushIndex([0'u32, 1, 2]) == 0
    check s.reserveIndex(4) == 12
    check s.indexSize == 16 and s.auxSize == 12

  test "image opacity block is pushed once per flush":
    var cache: GlStateCache
    let s = newGlStageBuffer()
    let o1 = s.getImageOpacityOffset(128)
    check s.getImageOpacityOffset(128) == o1
    let o2 = s.getImageOpacityOffset(255)
    check o2 != o1
    check s.stage[o1 div 4] == 128 and s.stage[o2 div 4] == 255
    check s.stage[o1 div 4 + 1] == 0
    discard s.pushIndex([0'u32])
    check s.flushToGPU(cache)
    check s.stage.len == 0
    check s.getImageOpacityOffset(128) == 0  # offsets were forgotten; stage restarted

  test "flushToGPU uploads stage, aux and index arrays (readback)":
    var cache: GlStateCache
    let s = newGlStageBuffer()
    discard s.push([0.25'f32, -1, 3, 4])
    let uni = s.push([9'f32, 8, 7, 6], true)
    discard s.pushAux([rgbaWord(10, 20, 30, 40), rgbaWord(255, 0, 255, 0)])
    discard s.pushIndex([0'u32, 1, 2, 2, 1, 3])
    let total = s.stageSize
    check s.flushToGPU(cache)
    check s.stage.len == 0 and s.aux.len == 0 and s.index.len == 0

    bindBuffer(GlArrayBuffer, s.getBufferId())
    var stage = newSeq[float32](total div 4)
    getBufferSubData(GlArrayBuffer, 0, stage)
    check stage[0 .. 3] == @[0.25'f32, -1, 3, 4]
    check stage[uni div 4 .. uni div 4 + 3] == @[9'f32, 8, 7, 6]
    bindBuffer(GlArrayBuffer, s.getAuxBufferId())
    var aux = newSeq[uint32](2)
    getBufferSubData(GlArrayBuffer, 0, aux)
    check aux == @[0x281E140A'u32, 0x00FF00FF'u32]
    bindBuffer(GlElementArrayBuffer, s.getIndexBufferId())
    var idx = newSeq[uint32](6)
    getBufferSubData(GlElementArrayBuffer, 0, idx)
    check idx == @[0'u32, 1, 2, 2, 1, 3]
    check getError() == GlNoError

    # bufferSubData round trip into the same buffer object
    bindBuffer(GlArrayBuffer, s.getBufferId())
    bufferSubData(GlArrayBuffer, 4, [42'f32])
    getBufferSubData(GlArrayBuffer, 0, stage)
    check stage[1] == 42'f32

  test "flushToGPU: nothing to draw returns false and empties the arrays":
    var cache: GlStateCache
    let s = newGlStageBuffer()
    discard s.push([1'f32, 2, 3, 4])
    check not s.flushToGPU(cache)  # no indices
    check s.stage.len == 0
    discard s.pushIndex([0'u32])
    check not s.flushToGPU(cache)  # no vertices
    check s.index.len == 0

  test "bind / unbind go through the state cache":
    var cache: GlStateCache
    let s = newGlStageBuffer()
    s.bindStage(cache)
    check cache.vertexArray.value == s.vaoId
    check cache.elementArrayBuffer.value == s.getIndexBufferId()
    check getInteger(GlArrayBufferBinding) == int32(s.getBufferId())
    s.unbind(cache)
    check cache.vertexArray.value == 0
    check getInteger(GlArrayBufferBinding) == 0
    check getError() == GlNoError

  test "stage buffer releases its VAO and buffers":
    let before = glLiveObjects()
    proc scoped() =
      let s = newGlStageBuffer()
      discard s.push([1'f32])
      check glLiveObjects() == before + 4  # VAO + 3 buffers
    scoped()
    check glLiveObjects() == before

suite "texture manager":
  test "retain / release: hit, miss, filters, dispose":
    var cache: GlStateCache
    var tm = initTextureMgr()
    let before = glLiveObjects()
    let a = newSurface(4, 2, ColorSpace.ABGR8888)
    let b = newSurface(4, 2, ColorSpace.ABGR8888)
    for i in 0 ..< a.data.len: a.data[i] = 0xFF000000'u32 or uint32(i * 0x010203)
    b.data = a.data

    let ta = tm.retain(cache, a, FilterMethod.Bilinear)
    check ta != 0
    check tm.surfaceCount == 1
    check tm.refCount(a, FilterMethod.Bilinear) == 1
    check tm.retain(cache, a, FilterMethod.Bilinear) == ta  # hit
    check tm.refCount(a, FilterMethod.Bilinear) == 2
    let tn = tm.retain(cache, a, FilterMethod.Nearest)  # other filter: own texture
    check tn != 0 and tn != ta
    check tm.surfaceCount == 1
    let tb = tm.retain(cache, b, FilterMethod.Bilinear)  # other surface identity: miss
    check tb notin [ta, tn]
    check tm.surfaceCount == 2
    check tm.texId(a, FilterMethod.Nearest) == tn
    check tm.texId(b, FilterMethod.Nearest) == 0
    check tm.find(b) == 1 and tm.find(newSurface(1, 1)) == -1

    check tm.release(a, FilterMethod.Bilinear, tn) == 0  # wrong texture id
    check tm.release(a, FilterMethod.Bilinear, ta) == 0  # 2 -> 1
    check tm.refCount(a, FilterMethod.Bilinear) == 1
    check tm.release(a, FilterMethod.Bilinear, ta) == ta  # last reference: caller disposes
    check tm.surfaceCount == 2  # nearest texture keeps the entry
    check tm.texId(a, FilterMethod.Bilinear) == 0
    check tm.release(a, FilterMethod.Nearest, tn) == tn
    check tm.surfaceCount == 1  # entry removed with its last texture
    check tm.release(a, FilterMethod.Nearest, tn) == 0  # unknown surface
    deleteTextures([ta, tn])
    check tm.release(b, FilterMethod.Bilinear, tb) == tb
    deleteTexture(tb)
    check tm.surfaceCount == 0
    check glLiveObjects() == before
    check getError() == GlNoError

  test "upload + flush round trip (premultiplied ABGR needs no preprocess)":
    var cache: GlStateCache
    var tm = initTextureMgr()
    let s = newSurface(4, 2, ColorSpace.ABGR8888)
    for i in 0 ..< s.data.len: s.data[i] = 0xFF000000'u32 or uint32(i * 0x0A0B0C)
    let tex = tm.retain(cache, s, FilterMethod.Nearest)
    check tm.prepRequests.len == 0
    check tm.flushPreprocess(cache, ctx.fbo)
    check readTexture(tex, 4, 2) == s.data
    # re-upload changed pixels into the same texture
    for p in s.data.mitems: p = not p
    tm.upload(cache, tex, s, FilterMethod.Nearest)
    check readTexture(tex, 4, 2) == s.data
    tm.clear()
    check getError() == GlNoError

  test "ARGB surfaces are swizzled and premultiplied on the GPU":
    var cache: GlStateCache
    var tm = initTextureMgr()
    let argb = newSurface(2, 2, ColorSpace.ARGB8888)  # premultiplied: swizzle only
    argb.data = @[px(255, 10, 20, 30), px(0, 0, 0, 0), px(128, 64, 32, 16), px(255, 255, 0, 1)]
    let ta = tm.retain(cache, argb, FilterMethod.Bilinear)
    check tm.prepRequests.len == 1
    check tm.prepRequests[0].flags == PrepBgr

    let straight = newSurface(2, 2, ColorSpace.ARGB8888S)  # straight alpha
    check not straight.premultiplied
    straight.data = @[px(255, 10, 20, 30), px(0, 200, 100, 50), px(128, 200, 100, 50),
      px(255, 1, 2, 3)]
    let ts = tm.retain(cache, straight, FilterMethod.Bilinear)
    check tm.prepRequests.len == 2
    check tm.prepRequests[1].flags == (PrepBgr or PrepPremultiply)

    let abgrS = newSurface(2, 1, ColorSpace.ABGR8888S)
    abgrS.data = @[0x80C86432'u32, 0xFF010203'u32]  # R=0x32 G=0x64 B=0xC8 A=0x80 | opaque
    let tg = tm.retain(cache, abgrS, FilterMethod.Bilinear)
    check tm.prepRequests[2].flags == PrepPremultiply

    check tm.flushPreprocess(cache, ctx.fbo)
    check tm.prepRequests.len == 0
    check cache.drawFramebuffer.value == ctx.fbo

    check readTexture(ta, 2, 2) == @[
      0xFF1E140A'u32, 0'u32, 0x80102040'u32, 0xFF0100FF'u32]
    let ps = readTexture(ts, 2, 2)
    check ps[0] == 0xFF1E140A'u32
    check ps[1] == 0x00000000'u32  # alpha 0: everything premultiplied away
    check ps[3] == 0xFF030201'u32
    # alpha 128: rgb * 128/255 within one unit of rounding
    check (ps[2] shr 24) == 128
    for (sh, want) in [(0'u32, 100), (8'u32, 50), (16'u32, 25)]:
      check abs(int((ps[2] shr sh) and 0xFF) - want) <= 1
    let pg = readTexture(tg, 2, 1)
    check pg[1] == 0xFF010203'u32  # opaque: unchanged
    check abs(int(pg[0] and 0xFF) - 25) <= 1  # 0x32 * 128/255
    check abs(int((pg[0] shr 8) and 0xFF) - 50) <= 1
    check abs(int((pg[0] shr 16) and 0xFF) - 100) <= 1
    check (pg[0] shr 24) == 0x80
    check getError() == GlNoError
    tm.clear()
    check getError() == GlNoError

  test "release cancels a queued preprocess":
    var cache: GlStateCache
    var tm = initTextureMgr()
    let s = newSurface(2, 2, ColorSpace.ARGB8888S)
    let t1 = tm.retain(cache, s, FilterMethod.Bilinear)
    let s2 = newSurface(2, 2, ColorSpace.ARGB8888S)
    let t2 = tm.retain(cache, s2, FilterMethod.Bilinear)
    check tm.prepRequests.len == 2
    check tm.release(s, FilterMethod.Bilinear, t1) == t1
    check tm.prepRequests.len == 1 and tm.prepRequests[0].texId == t2
    deleteTexture(t1)
    # requests of one texture are replaced, not duplicated
    tm.upload(cache, t2, s2, FilterMethod.Bilinear)
    check tm.prepRequests.len == 1
    tm.requestPreprocess(0, 4, 4, 1)  # texture 0 is ignored
    check tm.prepRequests.len == 1
    tm.clear()
    check tm.prepRequests.len == 0

  test "clear deletes the textures, bumps the stamp and frees the preprocess resources":
    var cache: GlStateCache
    let before = glLiveObjects()
    var tm = initTextureMgr()
    check tm.stamp == 1
    let s = newSurface(2, 2, ColorSpace.ARGB8888S)
    discard tm.retain(cache, s, FilterMethod.Bilinear)
    discard tm.retain(cache, s, FilterMethod.Nearest)
    check tm.flushPreprocess(cache, ctx.fbo)
    check glLiveObjects() > before + 2  # + staging FBO, target FBO, staging texture, VAO, program
    tm.clear()
    check tm.surfaceCount == 0
    check tm.stamp == 2
    check glLiveObjects() == before
    tm.stamp = high(uint16)
    tm.clear()
    check tm.stamp == 1  # never 0
    check getError() == GlNoError

  test "grayscale surface (no 32-bit pixels) allocates without reading data":
    var cache: GlStateCache
    var tm = initTextureMgr()
    let g = newSurface(3, 3, ColorSpace.Grayscale8)
    let tex = tm.retain(cache, g, FilterMethod.Bilinear)
    check tex != 0
    check tm.prepRequests.len == 0  # channelSize != 4
    check getError() == GlNoError
    tm.clear()

suite "end":
  test "no GL error and no leaked GL object":
    check getError() == GlNoError
    check glLiveObjects() == baseline

wglDestroy(ctx)
