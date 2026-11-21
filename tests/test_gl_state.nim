## G1a: GL state cache, shader, program (state_cache.nim, shader.nim, program.nim).
## Needs a GL 3.3 context from wgl_ffi; exits 0 with a message when none can be created.
##
## "Real GL call" counting: the test changes the GL state behind the cache's back with the raw
## wrappers of gl_ffi, then repeats a cache call. A redundant call must be skipped (the raw
## value stays), after `invalidate()` it must reach the driver (the cached value comes back).
import std/[unittest, strutils]
import thorvg/core/types
import thorvg/engine/gl/[gl_ffi, wgl_ffi, programs, state_cache, shader, program]

const
  W = 16'i32
  H = 8'i32
  # glGet pnames that gl_types does not carry
  ElementArrayBufferBinding = 0x8895'u32
  TextureBinding2D = 0x8069'u32
  ActiveTextureBinding = 0x84E0'u32
  Texture1 = 0x84C1'u32
  ScissorBox = 0x0C10'u32
  VertexArrayBinding = 0x85B5'u32
  BlendDstRgb = 0x80C8'u32
  BlendSrcRgb = 0x80C9'u32
  BlendDstAlpha = 0x80CA'u32
  BlendSrcAlpha = 0x80CB'u32
  DepthFuncName = 0x0B74'u32
  DepthWriteMask = 0x0B72'u32
  DepthClearValue = 0x0B73'u32
  ColorWriteMask = 0x0C23'u32
  StencilFuncName = 0x0B92'u32
  StencilRef = 0x0B97'u32
  StencilValueMask = 0x0B93'u32
  StencilFail = 0x0B94'u32
  StencilPassDepthFail = 0x0B95'u32
  StencilPassDepthPass = 0x0B96'u32
  StencilBackFunc = 0x8800'u32
  StencilBackFail = 0x8801'u32
  StencilBackRef = 0x8CA3'u32
  StencilClearValue = 0x0B91'u32
  Gequal = 0x0206'u32
  Incr = 0x1E02'u32
  Decr = 0x1E03'u32
  Lequal = 0x0203'u32
  NotEqual = 0x0205'u32
  # RGBA8 readback words: R | G<<8 | B<<16 | A<<24
  PxRed = 0xFF0000FF'u32
  PxGreen = 0xFF00FF00'u32
  PxBlue = 0xFFFF0000'u32

let (created, ctxInit) = wglCreateOffscreen(int(W), int(H))
if not created:
  echo "SKIP: no GL 3.3 context could be created"
  quit(0)

var ctx = ctxInit

proc gi(name: GlEnum): int32 = getInteger(name)
proc gb(name: GlEnum): bool = getInteger(name) != 0

proc quiet(on: bool) = glLogEnabled = not on

proc initTriangle(): (GlId, GlId) =
  ## VAO + VBO with one oversized triangle that covers the whole viewport.
  let vao = genVertexArray()
  let vbo = genBuffer()
  bindVertexArray(vao)
  bindBuffer(GlArrayBuffer, vbo)
  bufferData(GlArrayBuffer, [-1'f32, -1, 3, -1, -1, 3], GlStaticDraw)
  result = (vao, vbo)

proc firstPixel(): uint32 =
  var buf: seq[uint32]
  readPixels(0, 0, W, H, buf)
  result = buf[0]
  for p in buf: doAssert p == result, "framebuffer is not uniform"

suite "state cache":
  setup:
    bindFramebuffer(GlFramebuffer, ctx.fbo)
    bindVertexArray(0)
    useProgram(0)

  test "CachedValue":
    var v: CachedValue[int32]
    check not v.matches(0)
    v.store(5)
    check v.matches(5) and not v.matches(6)
    v.invalidate()
    check not v.matches(5)

  test "useProgram skips redundant calls":
    var c: GlStateCache
    let a = newGlProgram(programSource(ord(rtColor)))
    let b = newGlProgram(programSource(ord(rtBlit)))
    c.useProgram(a.programId)
    check gi(GlCurrentProgram) == int32(a.programId)
    useProgram(b.programId)  # behind the cache's back
    c.useProgram(a.programId)
    check gi(GlCurrentProgram) == int32(b.programId)  # skipped
    c.invalidate()
    c.useProgram(a.programId)
    check gi(GlCurrentProgram) == int32(a.programId)
    c.useProgram(0)
    check gi(GlCurrentProgram) == 0
    a.destroy()
    b.destroy()

  test "bindVertexArray and bindBuffer":
    var c: GlStateCache
    let vao = genVertexArray()
    let vao2 = genVertexArray()
    let bufs = genBuffers(3)
    c.bindVertexArray(vao)
    check gi(VertexArrayBinding) == int32(vao)
    bindVertexArray(vao2)
    c.bindVertexArray(vao)
    check gi(VertexArrayBinding) == int32(vao2)  # skipped
    c.invalidate()
    c.bindVertexArray(vao)
    check gi(VertexArrayBinding) == int32(vao)

    c.bindBuffer(GlArrayBuffer, bufs[0])
    check gi(GlArrayBufferBinding) == int32(bufs[0])
    bindBuffer(GlArrayBuffer, bufs[1])
    c.bindBuffer(GlArrayBuffer, bufs[0])
    check gi(GlArrayBufferBinding) == int32(bufs[1])  # skipped
    c.bindBuffer(GlArrayBuffer, bufs[2])
    check gi(GlArrayBufferBinding) == int32(bufs[2])
    check c.buffers.len == 1

    c.bindBuffer(GlElementArrayBuffer, bufs[0])
    check gi(ElementArrayBufferBinding) == int32(bufs[0])
    bindBuffer(GlElementArrayBuffer, bufs[1])
    c.bindBuffer(GlElementArrayBuffer, bufs[0])
    check gi(ElementArrayBufferBinding) == int32(bufs[1])  # skipped
    check c.buffers.len == 1  # the element buffer has its own slot
    # binding another VAO forgets the element buffer binding (it is VAO state)
    c.bindVertexArray(vao2)
    check not c.elementArrayBuffer.valid
    c.bindVertexArray(0)
    bindBuffer(GlArrayBuffer, 0)
    bindBuffer(GlElementArrayBuffer, 0)
    deleteBuffers(bufs)
    deleteVertexArray(vao)
    deleteVertexArray(vao2)

  test "bindTexture2D tracks one texture per unit":
    var c: GlStateCache
    let tex = genTextures(3)
    c.bindTexture2D(GlTexture0, tex[0])
    c.bindTexture2D(Texture1, tex[1])
    check gi(ActiveTextureBinding) == int32(Texture1)
    check gi(TextureBinding2D) == int32(tex[1])
    c.bindTexture2D(GlTexture0, tex[0])  # unit switch only
    check gi(ActiveTextureBinding) == int32(GlTexture0)
    check gi(TextureBinding2D) == int32(tex[0])
    bindTexture(GlTexture2D, tex[2])  # behind the cache's back
    c.bindTexture2D(GlTexture0, tex[0])
    check gi(TextureBinding2D) == int32(tex[2])  # skipped
    c.invalidate()
    c.bindTexture2D(GlTexture0, tex[0])
    check gi(TextureBinding2D) == int32(tex[0])
    check c.textures.len == 2
    c.bindTexture2D(GlTexture0, 0)
    c.bindTexture2D(Texture1, 0)
    activeTexture(GlTexture0)
    deleteTextures(tex)

  test "viewport and scissor":
    var c: GlStateCache
    c.viewport(1, 2, 8, 4)
    check getIntegers(GlViewport, 4) == @[1'i32, 2, 8, 4]
    viewport(0, 0, 3, 3)
    c.viewport(1, 2, 8, 4)
    check getIntegers(GlViewport, 4) == @[0'i32, 0, 3, 3]  # skipped
    c.viewport(1, 2, 8, 5)
    check getIntegers(GlViewport, 4) == @[1'i32, 2, 8, 5]
    c.scissor(2, 1, 5, 6)
    check getIntegers(ScissorBox, 4) == @[2'i32, 1, 5, 6]
    scissor(0, 0, 1, 1)
    c.scissor(2, 1, 5, 6)
    check getIntegers(ScissorBox, 4) == @[0'i32, 0, 1, 1]  # skipped
    c.invalidate()
    c.scissor(2, 1, 5, 6)
    check getIntegers(ScissorBox, 4) == @[2'i32, 1, 5, 6]
    c.viewport(0, 0, W, H)
    scissor(0, 0, W, H)

  test "bindFramebuffer targets":
    var c: GlStateCache
    let fbo = genFramebuffer()
    c.bindFramebuffer(GlFramebuffer, ctx.fbo)
    check gi(GlFramebufferBinding) == int32(ctx.fbo)
    check gi(GlReadFramebufferBinding) == int32(ctx.fbo)
    check c.readFramebuffer.value == ctx.fbo and c.drawFramebuffer.value == ctx.fbo
    c.bindFramebuffer(GlReadFramebuffer, fbo)
    check gi(GlReadFramebufferBinding) == int32(fbo)
    check gi(GlFramebufferBinding) == int32(ctx.fbo)
    bindFramebuffer(GlReadFramebuffer, ctx.fbo)
    c.bindFramebuffer(GlReadFramebuffer, fbo)
    check gi(GlReadFramebufferBinding) == int32(ctx.fbo)  # skipped
    c.bindFramebuffer(GlDrawFramebuffer, fbo)
    check gi(GlFramebufferBinding) == int32(fbo)
    # GL_FRAMEBUFFER is only skipped when both targets already match
    c.bindFramebuffer(GlFramebuffer, ctx.fbo)
    check gi(GlReadFramebufferBinding) == int32(ctx.fbo)
    check gi(GlFramebufferBinding) == int32(ctx.fbo)
    c.bindFramebuffer(GlFramebuffer, ctx.fbo)
    bindFramebuffer(GlFramebuffer, fbo)
    c.bindFramebuffer(GlFramebuffer, ctx.fbo)
    check gi(GlFramebufferBinding) == int32(fbo)  # skipped
    c.invalidate()
    c.bindFramebuffer(GlFramebuffer, ctx.fbo)
    check gi(GlFramebufferBinding) == int32(ctx.fbo)
    deleteFramebuffer(fbo)

  test "capabilities":
    var c: GlStateCache
    for cap in [GlBlend, GlDepthTest, GlStencilTest, GlScissorTest]:
      c.disable(cap)
      check not gb(cap)
      enable(cap)
      c.disable(cap)
      check gb(cap)  # skipped
      c.enable(cap)
      check gb(cap)
      disable(cap)
      c.enable(cap)
      check not gb(cap)  # skipped
      c.invalidate()
      c.enable(cap)
      check gb(cap)
      c.disable(cap)
      check not gb(cap)
    check c.capabilities.len == 4

  test "blend, depth and color mask":
    var c: GlStateCache
    c.blendFuncSeparate(GlOne, GlOneMinusSrcAlpha, GlSrcAlpha, GlZero)
    check [gi(BlendSrcRgb), gi(BlendDstRgb), gi(BlendSrcAlpha), gi(BlendDstAlpha)] ==
      [int32(GlOne), int32(GlOneMinusSrcAlpha), int32(GlSrcAlpha), int32(GlZero)]
    blendFuncSeparate(GlZero, GlZero, GlZero, GlZero)
    c.blendFuncSeparate(GlOne, GlOneMinusSrcAlpha, GlSrcAlpha, GlZero)
    check gi(BlendSrcRgb) == int32(GlZero)  # skipped
    c.blendFuncSeparate(GlOne, GlOne, GlOne, GlOne)
    check gi(BlendDstAlpha) == int32(GlOne)

    c.depthFunc(GlLess)
    check gi(DepthFuncName) == int32(GlLess)
    depthFunc(Gequal)
    c.depthFunc(GlLess)
    check gi(DepthFuncName) == int32(Gequal)  # skipped
    c.depthFunc(Lequal)
    check gi(DepthFuncName) == int32(Lequal)

    c.depthMask(false)
    check not gb(DepthWriteMask)
    depthMask(true)
    c.depthMask(false)
    check gb(DepthWriteMask)  # skipped
    c.depthMask(true)
    check gb(DepthWriteMask)

    c.colorMask(true, false, true, false)
    check getIntegers(ColorWriteMask, 4) == @[1'i32, 0, 1, 0]
    colorMask(true, true, true, true)
    c.colorMask(true, false, true, false)
    check getIntegers(ColorWriteMask, 4) == @[1'i32, 1, 1, 1]  # skipped
    c.invalidate()
    c.colorMask(true, false, true, false)
    check getIntegers(ColorWriteMask, 4) == @[1'i32, 0, 1, 0]
    c.colorMask(true, true, true, true)

  test "stencil func and op, all and separate faces":
    var c: GlStateCache
    c.stencilFunc(GlEqual, 3, 0xF0)
    check [gi(StencilFuncName), gi(StencilRef), gi(StencilValueMask)] ==
      [int32(GlEqual), 3'i32, 0xF0'i32]
    check [gi(StencilBackFunc), gi(StencilBackRef)] == [int32(GlEqual), 3'i32]
    stencilFunc(GlAlways, 0, 0xFF)
    c.stencilFunc(GlEqual, 3, 0xF0)
    check gi(StencilFuncName) == int32(GlAlways)  # skipped (both faces cached)
    c.stencilFuncSeparate(GlFront, GlEqual, 3, 0xF0)
    check gi(StencilFuncName) == int32(GlAlways)  # front already cached: skipped
    c.stencilFuncSeparate(GlBack, GlEqual, 3, 0xF0)
    check gi(StencilBackFunc) == int32(GlAlways)  # back too
    c.stencilFuncSeparate(GlBack, GlLess, 7, 0xFF)
    check [gi(StencilBackFunc), gi(StencilBackRef)] == [int32(GlLess), 7'i32]
    check gi(StencilFuncName) == int32(GlAlways)  # front untouched
    check c.backStencilFunction.value.function == GlLess
    check c.frontStencilFunction.value.function == GlEqual
    c.stencilFuncSeparate(GlFrontAndBack, NotEqual, 1, 1)
    check gi(StencilFuncName) == int32(NotEqual)
    check gi(StencilBackFunc) == int32(NotEqual)

    c.stencilOp(GlKeep, Incr, GlReplace)
    check [gi(StencilFail), gi(StencilPassDepthFail), gi(StencilPassDepthPass)] ==
      [int32(GlKeep), int32(Incr), int32(GlReplace)]
    stencilOp(GlKeep, GlKeep, GlKeep)
    c.stencilOp(GlKeep, Incr, GlReplace)
    check gi(StencilPassDepthFail) == int32(GlKeep)  # skipped
    c.stencilOpSeparate(GlBack, GlReplace, Decr, GlKeep)
    check gi(StencilBackFail) == int32(GlReplace)
    check gi(StencilFail) == int32(GlKeep)  # front untouched
    c.stencilOpSeparate(GlFront, GlReplace, Decr, GlKeep)
    check gi(StencilFail) == int32(GlReplace)
    c.stencilOpSeparate(GlFrontAndBack, GlKeep, GlKeep, GlKeep)
    check gi(StencilBackFail) == int32(GlKeep) and gi(StencilFail) == int32(GlKeep)
    c.stencilFunc(GlAlways, 0, 0xFF)
    c.stencilOp(GlKeep, GlKeep, GlKeep)

  test "clear values":
    var c: GlStateCache
    bindFramebuffer(GlFramebuffer, ctx.fbo)
    c.clearColor(1, 0, 0, 1)
    clearColor(0, 1, 0, 1)  # behind the cache's back
    c.clearColor(1, 0, 0, 1)  # skipped
    clear(GlColorBufferBit)
    check firstPixel() == PxGreen
    c.invalidate()
    c.clearColor(1, 0, 0, 1)
    clear(GlColorBufferBit)
    check firstPixel() == PxRed

    c.clearStencil(5)
    check gi(StencilClearValue) == 5
    clearStencil(9)
    c.clearStencil(5)
    check gi(StencilClearValue) == 9  # skipped
    c.clearStencil(6)
    check gi(StencilClearValue) == 6

    c.clearDepth(1.0)
    check gi(DepthClearValue) == high(int32)
    clearDepth(0.0)
    c.clearDepth(1.0)
    check gi(DepthClearValue) == 0  # skipped
    c.invalidate()
    c.clearDepth(1.0)
    check gi(DepthClearValue) == high(int32)

  test "invalidate forgets everything and issues no GL call":
    var c: GlStateCache
    let (vao, vbo) = initTriangle()
    c.bindVertexArray(vao)
    c.bindBuffer(GlArrayBuffer, vbo)
    c.useProgram(0)
    c.bindTexture2D(GlTexture0, 0)
    c.viewport(0, 0, W, H)
    c.scissor(0, 0, W, H)
    c.bindFramebuffer(GlFramebuffer, ctx.fbo)
    c.enable(GlBlend)
    c.blendFuncSeparate(GlOne, GlOne, GlOne, GlOne)
    c.depthFunc(GlLess)
    c.depthMask(true)
    c.colorMask(true, true, true, true)
    c.stencilFunc(GlAlways, 0, 1)
    c.stencilOp(GlKeep, GlKeep, GlKeep)
    c.clearColor(0, 0, 0, 0)
    c.clearStencil(0)
    c.clearDepth(1)
    c.setVertexAttrib4f(1, 1, 2, 3, 4)
    c.setVertexAttribPointer(0, 2, GlFloat, false, 8, 0, vbo)
    check c.program.valid and c.vertexArray.valid and c.elementArrayBuffer.valid == false
    c.invalidate()
    check not (c.program.valid or c.vertexArray.valid or c.elementArrayBuffer.valid)
    check not (c.activeTextureUnit.valid or c.viewportState.valid or c.scissorState.valid)
    check not (c.readFramebuffer.valid or c.drawFramebuffer.valid or c.blendFunction.valid)
    check not (c.depthFunction.valid or c.depthWriteEnabled.valid or c.colorWriteMask.valid)
    check not (c.frontStencilFunction.valid or c.backStencilFunction.valid)
    check not (c.frontStencilOperation.valid or c.backStencilOperation.valid)
    check not (c.clearColorState.valid or c.clearStencilValue.valid or c.clearDepthValue.valid)
    for b in c.buffers: check not b.buffer.valid
    for t in c.textures: check not t.texture.valid
    for s in c.capabilities: check not s.enabled.valid
    for a in c.vertexAttributes:
      check not (a.enabled.valid or a.attribPointer.valid or a.constant.valid or a.used)
    check c.vertexAttributes[0].known  # table itself is kept
    check c.buffers.len == 1 and c.capabilities.len == 1
    check getError() == GlNoError
    bindVertexArray(0)
    deleteBuffer(vbo)
    deleteVertexArray(vao)

suite "vertex layout and drawing through the cache":
  setup:
    bindFramebuffer(GlFramebuffer, ctx.fbo)
    viewport(0, 0, W, H)
    useProgram(0)
    disable(GlBlend)

  test "attribute pointer, constant attribute and endVertexLayout":
    var c: GlStateCache
    let prog = newGlProgram(programSource(ord(rtColor)))
    check prog.isValid
    let (vao, vbo) = initTriangle()
    c.invalidate()
    c.bindVertexArray(vao)
    prog.load(c)
    uniformMatrix3fv(prog.getUniformLocation(GlShaderUniform.ViewMatrix),
      [1'f32, 0, 0, 0, 1, 0, 0, 0, 1])
    uniform1f(prog.getUniformLocation(GlShaderUniform.Depth), 0.0)
    c.beginVertexLayout()
    c.setVertexAttribPointer(0, 2, GlFloat, false, 8, 0, vbo)
    c.setVertexAttrib4f(1, 0, 0, 1, 1)
    c.endVertexLayout()
    check c.vertexAttributes[0].enabled.value and c.vertexAttributes[0].attribPointer.valid
    check not c.vertexAttributes[1].enabled.value
    check c.vertexAttributes[1].constant.value == (0'f32, 0'f32, 1'f32, 1'f32)
    clearColor(0, 0, 0, 0)
    clear(GlColorBufferBit)
    drawArrays(GlTriangles, 0, 3)
    check firstPixel() == PxBlue
    check getError() == GlNoError

    # a layout that no longer uses attribute 0 disables its array; attribute 2 is enabled
    c.beginVertexLayout()
    c.setVertexAttribPointer(2, 2, GlFloat, false, 8, 0, vbo)
    c.setVertexAttrib4f(1, 1, 0, 0, 1)
    c.endVertexLayout()
    check not c.vertexAttributes[0].enabled.value
    check c.vertexAttributes[2].enabled.value and c.vertexAttributes[1].constant.valid
    # drawing a pointer again invalidates the constant of that attribute
    c.beginVertexLayout()
    c.setVertexAttribPointer(1, 2, GlFloat, false, 8, 0, vbo)
    check not c.vertexAttributes[1].constant.valid and c.vertexAttributes[1].enabled.value
    c.endVertexLayout()
    check not c.vertexAttributes[2].enabled.value
    check getError() == GlNoError
    c.bindVertexArray(0)
    c.bindBuffer(GlArrayBuffer, 0)
    deleteBuffer(vbo)
    deleteVertexArray(vao)
    prog.destroy()

suite "shader and program":
  test "compile failure returns 0, logs and does not crash":
    quiet(true)
    glLastError = ""
    let shaders = glLiveObjects(okShader)
    let programs = glLiveObjects(okProgram)
    var sh = newShader("this is not glsl", "neither is this")
    check sh.vtShader == 0 and sh.frShader == 0 and not sh.ok
    check glLastError.startsWith("Error compiling shader")
    check compileShader(GlVertexShader, "void main() {") == 0
    let p = newGlProgram("garbage", "garbage")
    check not p.isValid and p.programId == 0
    check getError() == GlNoError
    quiet(false)
    check glLiveObjects(okShader) == shaders
    check glLiveObjects(okProgram) == programs

  test "good vertex shader with bad fragment shader":
    quiet(true)
    let src = programSource(ord(rtColor))
    var sh = newShader(src.vert, "void main() { undefinedCall(); }")
    check sh.vtShader != 0 and sh.frShader == 0 and not sh.ok
    quiet(false)
    sh.destroy()
    check sh.vtShader == 0

  test "link failure returns an invalid program":
    quiet(true)
    glLastError = ""
    const
      # the same uniform with two different types is a link error
      Vert = "layout(location = 0) in vec2 aPos; uniform vec4 uX;\n" &
        "void main() { gl_Position = vec4(aPos, 0.0, 1.0) + uX; }"
      Frag = "uniform float uX; out vec4 FragColor; void main() { FragColor = vec4(uX); }"
    let sh = newShader(Vert, Frag)
    check sh.ok
    let programs = glLiveObjects(okProgram)
    let p = newGlProgram(Vert, Frag)
    check not p.isValid
    check glLastError.startsWith("Error linking shader")
    quiet(false)
    check glLiveObjects(okProgram) == programs

  test "link success, uniform locations and block indices":
    let p = newGlProgram(programSource(ord(rtImage)))
    check p.isValid and p.programId == p.getProgramId
    check getProgramiv(p.programId, GlLinkStatus) == 1
    check p.getUniformLocation(GlShaderUniform.Depth) >= 0
    check p.getUniformLocation(GlShaderUniform.ViewMatrix) >= 0
    check p.getUniformLocation(GlShaderUniform.Texture) >= 0
    check p.getUniformLocation(GlShaderUniform.MaskTexture) == -1  # absent: cached -1
    check p.getUniformLocation(GlShaderUniform.Depth) ==
      getUniformLocation(p.programId, "uDepth")
    check p.getUniformBlockIndex(GlShaderUniformBlock.ColorInfo) >= 0
    check p.getUniformBlockIndex(GlShaderUniformBlock.ColorInfo) ==
      int32(getUniformBlockIndex(p.programId, "ColorInfo"))
    check p.getUniformBlockIndex(GlShaderUniformBlock.Gaussian) == -1
    check p.getUniformBlockIndex(GlShaderUniformBlock.Gaussian) == -1  # cached

    # block binding: first binding wins, only the same point is accepted afterwards
    check p.setUniformBlockBinding(GlShaderUniformBlock.ColorInfo, 1)
    check p.setUniformBlockBinding(GlShaderUniformBlock.ColorInfo, 1)
    check not p.setUniformBlockBinding(GlShaderUniformBlock.ColorInfo, 2)
    check not p.setUniformBlockBinding(GlShaderUniformBlock.Gaussian, 1)
    check getError() == GlNoError
    p.destroy()
    check not p.isValid
    p.destroy()  # idempotent

  test "uniform upload round trip and setSampler cache":
    var c: GlStateCache
    let p = newGlProgram(programSource(ord(rtImage)))
    p.load(c)
    check gi(GlCurrentProgram) == int32(p.programId)
    let depth = p.getUniformLocation(GlShaderUniform.Depth)
    uniform1f(depth, 0.25)
    check getUniformfv(p.programId, depth, 1) == @[0.25'f32]
    let view = p.getUniformLocation(GlShaderUniform.ViewMatrix)
    let m = [1'f32, 2, 3, 4, 5, 6, 7, 8, 9]
    uniformMatrix3fv(view, m)
    check getUniformfv(p.programId, view, 9) == @m
    let tex = p.getUniformLocation(GlShaderUniform.Texture)
    p.setSampler(GlShaderUniform.Texture, 3)
    check getUniformfv(p.programId, tex, 1) == @[3'f32]
    uniform1i(tex, 5)  # behind the program's back
    p.setSampler(GlShaderUniform.Texture, 3)
    check getUniformfv(p.programId, tex, 1) == @[5'f32]  # skipped
    p.setSampler(GlShaderUniform.Texture, 4)
    check getUniformfv(p.programId, tex, 1) == @[4'f32]
    p.setSampler(GlShaderUniform.MaskTexture, 1)  # no such uniform: no GL call, no error
    check getError() == GlNoError
    unload(c)
    check gi(GlCurrentProgram) == 0
    p.destroy()

  test "=destroy releases the GL object, destroy twice is harmless":
    let before = glLiveObjects(okProgram)
    proc scoped() =
      let p = newGlProgram(programSource(ord(rtColor)))
      doAssert p.isValid
      doAssert glLiveObjects(okProgram) == before + 1
    scoped()
    check glLiveObjects(okProgram) == before
    let before2 = glLiveObjects(okShader)
    proc scopedShader() =
      let sh = newShader(programSource(ord(rtColor)))
      doAssert sh.ok
      doAssert glLiveObjects(okShader) == before2 + 2
    scopedShader()
    check glLiveObjects(okShader) == before2

suite "all GL programs of the renderer":
  const
    Methods = [BlendMethod.Multiply, BlendMethod.Overlay, BlendMethod.Darken,
      BlendMethod.Lighten, BlendMethod.ColorDodge, BlendMethod.ColorBurn,
      BlendMethod.HardLight, BlendMethod.SoftLight, BlendMethod.Difference,
      BlendMethod.Hue, BlendMethod.Saturation, BlendMethod.Color, BlendMethod.Luminosity]

  proc linkAll(list: seq[(string, ProgramSource)]): seq[string] =
    ## Names of the programs that do not link.
    result = @[]
    let programs = glLiveObjects(okProgram)
    quiet(true)
    for (name, src) in list:
      let p = newGlProgram(src)
      if p.isValid and getProgramiv(p.programId, GlLinkStatus) == 1:
        p.destroy()
      else:
        result.add name & ": " & glLastError
    quiet(false)
    doAssert glLiveObjects(okProgram) == programs

  test "initShaders programs (17) link":
    var list: seq[(string, ProgramSource)] = @[]
    for i, src in initShaderSources(): list.add (programName(i), src)
    check list.len == ord(rtBlend)
    check linkAll(list).len == 0

  test "blend programs (13 methods x 6 sources = 78) link":
    var list: seq[(string, ProgramSource)] = @[]
    for s in BlendSource:
      for m in Methods:
        list.add ("Blend:" & $s & ":" & $m, blendProgramSource(m, s))
    check list.len == 78
    let failed = linkAll(list)
    if failed.len > 0: echo "FAILED: " & failed.join("; ")
    check failed.len == 0

  test "effect programs (7) link":
    var list: seq[(string, ProgramSource)] = @[]
    for e in EffectProgram: list.add ($e, effectSource(e))
    check list.len == 7
    check linkAll(list).len == 0

  test "programSource(0 ..< RtNone + 7) is the same 102":
    var list: seq[(string, ProgramSource)] = @[]
    for i in 0 ..< RtNone + ord(EffectProgram.Tritone) + 1:
      list.add (programName(i), programSource(i))
    check list.len == 102
    check linkAll(list).len == 0

  test "no GL error and no leaked GL object at the end":
    check getError() == GlNoError

wglDestroy(ctx)
