## G0 acceptance test: GL FFI (`gl_ffi`) + WGL offscreen context (`wgl_ffi`).
## Replaces the feasibility PoC `poc_context.nim`. Skips (exit 0) when no GL 3.3
## context can be created (no desktop session / no driver).
##
## Also run with `-d:glDebug` to exercise the `glCheck` error path.
import std/unittest
import thorvg/engine/gl/[gl_ffi, wgl_ffi]

const
  W = 32'i32
  H = 16'i32

let (created, ctxInit) = wglCreateOffscreen(int(W), int(H))
if not created:
  echo "SKIP: no GL 3.3 context could be created"
  quit(0)

var ctx = ctxInit

proc pixel(buf: seq[uint32], x, y: int): uint32 = buf[y * int(W) + x]

proc readAll(): seq[uint32] =
  var buf: seq[uint32]
  readPixels(0, 0, W, H, buf)
  result = buf

proc compile(ty: GlEnum, src: string): GlId =
  result = createShader(ty)
  shaderSource(result, src)
  compileShader(result)

proc buildProgram(vs, fs: string): GlId =
  ## Returns 0 when compile or link fails.
  let v = compile(GlVertexShader, vs)
  let f = compile(GlFragmentShader, fs)
  result = createProgram()
  attachShader(result, v)
  attachShader(result, f)
  linkProgram(result)
  let ok = getShaderiv(v, GlCompileStatus) == 1 and getShaderiv(f, GlCompileStatus) == 1 and
    getProgramiv(result, GlLinkStatus) == 1
  deleteShader(v)
  deleteShader(f)
  if not ok:
    deleteProgram(result)
    result = 0

const
  Header = "#version 330 core\nprecision highp float;\nprecision highp int;\n"
  UboVert = Header & """
layout(location = 0) in vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
"""
  UboFrag = Header & """
layout(std140) uniform ColorBlock { vec4 color; };
out vec4 fragColor;
void main() { fragColor = color; }
"""
  UniVert = Header & """
layout(location = 0) in vec2 aPos;
uniform mat3 uMat;
void main() { gl_Position = vec4((uMat * vec3(aPos, 1.0)).xy, 0.0, 1.0); }
"""
  UniFrag = Header & """
uniform vec4 uColor;
out vec4 fragColor;
void main() { fragColor = uColor; }
"""

proc setupTriangle(verts: openArray[float32]): (GlId, GlId) =
  let vao = genVertexArray()
  let vbo = genBuffer()
  bindVertexArray(vao)
  bindBuffer(GlArrayBuffer, vbo)
  bufferData(GlArrayBuffer, verts, GlStaticDraw)
  enableVertexAttribArray(0)
  vertexAttribPointer(0, 2, GlFloat, false, 8, 0)
  result = (vao, vbo)

suite "gl context":
  test "context and version":
    check ctx.rc != 0
    check ctx.dc != 0
    check ctx.mode in ["3.3 core", "3.3 compat", "legacy"]
    check wglCurrentContext() == ctx.rc
    check wglCurrentDc() == ctx.dc
    let v = getString(GlVersion)
    check v.len > 0 and v[0] in {'3' .. '9'}
    check getInteger(GlMajorVersion) >= 3
    check getString(GlRenderer).len > 0
    check getString(GlShadingLanguageVersion).len > 0
    check glReady()
    check glInitError() == ""
    check glInit()  # idempotent

  test "fbo is complete and bound":
    check ctx.fbo != 0
    bindFramebuffer(GlFramebuffer, ctx.fbo)
    check checkFramebufferStatus(GlFramebuffer) == GlFramebufferComplete
    check getInteger(GlFramebufferBinding) == int32(ctx.fbo)
    check getIntegers(GlViewport, 4) == @[0'i32, 0, W, H]

  test "clear and readPixels are exact":
    clearColor(1.0, 0.5, 0.25, 1.0)
    clear(GlColorBufferBit)
    let buf = readAll()
    check buf.len == int(W * H)
    let expected = 255'u32 or (128'u32 shl 8) or (64'u32 shl 16) or (255'u32 shl 24)
    for p in buf: check p == expected
    check getError() == GlNoError

  test "std140 uniform block program draws a triangle":
    let prog = buildProgram(UboVert, UboFrag)
    check prog != 0
    let idx = getUniformBlockIndex(prog, "ColorBlock")
    check idx != GlInvalidIndex
    check getUniformBlockIndex(prog, "NoSuchBlock") == GlInvalidIndex
    uniformBlockBinding(prog, idx, 2)
    let ubo = genBuffer()
    bindBuffer(GlUniformBuffer, ubo)
    bufferData(GlUniformBuffer, [0.0'f32, 1.0, 0.0, 1.0], GlStaticDraw)
    bindBufferRange(GlUniformBuffer, 2, ubo, 0, 16)
    let (vao, vbo) = setupTriangle([-1.0'f32, -1.0, 1.0, -1.0, 0.0, 1.0])
    clearColor(0, 0, 0, 0)
    clear(GlColorBufferBit)
    useProgram(prog)
    glCheck(drawArrays(GlTriangles, 0, 3))
    let buf = readAll()
    check pixel(buf, 16, 4) == 0xFF00FF00'u32    # green inside (R | G<<8 | B<<16 | A<<24)
    check pixel(buf, 0, 15) == 0'u32              # outside the triangle (top-left corner)
    check getUniformBlockIndex(prog, "ColorBlock") == idx
    bindVertexArray(0)
    deleteVertexArray(vao)
    deleteBuffer(vbo)
    deleteBuffer(ubo)
    deleteProgram(prog)

  test "uniforms, matrix and indexed draw":
    let prog = buildProgram(UniVert, UniFrag)
    check prog != 0
    let locM = getUniformLocation(prog, "uMat")
    let locC = getUniformLocation(prog, "uColor")
    check locM >= 0 and locC >= 0
    check getUniformLocation(prog, "nope") == -1
    let (vao, vbo) = setupTriangle([-1.0'f32, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0])
    let ebo = genBuffer()
    bindBuffer(GlElementArrayBuffer, ebo)
    bufferData(GlElementArrayBuffer, [0'u32, 1, 2, 0, 2, 3], GlStaticDraw)
    clearColor(0, 0, 0, 0)
    clear(GlColorBufferBit)
    useProgram(prog)
    uniform4fv(locC, [1.0'f32, 0.0, 0.0, 1.0])
    uniformMatrix3fv(locM, [0.5'f32, 0, 0, 0, 0.5, 0, 0, 0, 1])  # scale 0.5 -> centered quad
    glCheck(drawElements(GlTriangles, 6, GlUnsignedInt, 0))
    let buf = readAll()
    check pixel(buf, 16, 8) == 0xFF0000FF'u32     # red in the middle
    check pixel(buf, 2, 2) == 0'u32               # background near the border
    check pixel(buf, 29, 13) == 0'u32
    bindVertexArray(0)
    deleteVertexArray(vao)
    deleteBuffer(vbo)
    deleteBuffer(ebo)
    deleteProgram(prog)

  test "failed compile gives a log":
    let s = compile(GlFragmentShader, Header & "void main() { nonsense }")
    check getShaderiv(s, GlCompileStatus) == 0
    check getShaderInfoLog(s).len > 0
    deleteShader(s)
    check buildProgram(UniVert, Header & "void main() {") == 0

  test "texture upload and readback":
    var pixels = newSeq[uint32](16)
    for i in 0 ..< 16: pixels[i] = 0xFF000000'u32 or uint32(i * 16) or (uint32(255 - i) shl 8)
    let tex = genTexture()
    bindTexture(GlTexture2D, tex)
    texParameteri(GlTexture2D, GlTextureMinFilter, int32(GlNearest))
    texParameteri(GlTexture2D, GlTextureMagFilter, int32(GlNearest))
    texImage2D(GlTexture2D, 0, int32(GlRgba8), 4, 4, GlRgba, GlUnsignedByte, pixels)
    let fbo2 = genFramebuffer()
    bindFramebuffer(GlFramebuffer, fbo2)
    framebufferTexture2D(GlFramebuffer, GlColorAttachment0, GlTexture2D, tex, 0)
    check checkFramebufferStatus(GlFramebuffer) == GlFramebufferComplete
    var back: seq[uint32]
    readPixels(0, 0, 4, 4, back)
    check back == pixels
    let patch = [0xFF112233'u32, 0xFF445566'u32]
    texSubImage2D(GlTexture2D, 0, 1, 2, 2, 1, GlRgba, GlUnsignedByte, patch)
    readPixels(0, 0, 4, 4, back)
    check back[2 * 4 + 1] == patch[0] and back[2 * 4 + 2] == patch[1]
    check back[0] == pixels[0]
    bindFramebuffer(GlFramebuffer, ctx.fbo)
    deleteFramebuffer(fbo2)
    deleteTexture(tex)
    check getError() == GlNoError

  test "errors: getError and glCheck":
    discard getError()
    enable(0xFFFF'u32)
    check getError() == GlInvalidEnum
    check getError() == GlNoError
    check errorName(GlInvalidEnum) == "GL_INVALID_ENUM"
    when defined(glDebug):
      expect GlError:
        glCheck(enable(0xFFFF'u32))
    else:
      glCheck(enable(0xFFFF'u32))  # no check without -d:glDebug
      check getError() == GlInvalidEnum
    discard getError()

  test "context handling":
    wglReleaseCurrent()
    check wglCurrentContext() == 0
    check wglMakeCurrent(ctx)
    check wglCurrentContext() == ctx.rc

  test "no leaked objects":
    # only the three objects of the app FBO are alive
    check glLiveObjects() == 3
    check glLiveObjects(okFramebuffer) == 1
    check glLiveObjects(okRenderbuffer) == 2
    check glLiveObjects(okBuffer) == 0
    check glLiveObjects(okTexture) == 0
    check glLiveObjects(okProgram) == 0
    check glLiveObjects(okShader) == 0
    check glLiveObjects(okVertexArray) == 0

  test "destroy releases everything":
    wglDestroy(ctx)
    check ctx.rc == 0 and ctx.hwnd == 0 and ctx.fbo == 0
    check wglCurrentContext() == 0
    check glLiveObjects() == 0
    wglDestroy(ctx)  # idempotent
    # a second context works after the first one is gone
    var (ok, c2) = wglCreateOffscreen(8, 8)
    check ok
    check c2.rc != 0
    wglDestroy(c2)
