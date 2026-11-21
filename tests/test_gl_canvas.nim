## G5: GL canvas facade (`thorvg/engine/gl/glcanvas`). Needs a GL 3.3 context from wgl_ffi;
## exits 0 with a message when none can be created.
import std/unittest
import thorvg
import thorvg/engine/gl/[glcanvas, gl_ffi, wgl_ffi]

const
  W = 32
  H = 32

let (created, ctxInit) = wglCreateOffscreen(W, H)
if not created:
  echo "SKIP: no GL 3.3 context could be created"
  quit(0)

var ctx = ctxInit
let baseline = glLiveObjects()

proc readFbo(): seq[uint32] =
  bindFramebuffer(GlReadFramebuffer, ctx.fbo)
  readPixels(0, 0, int32(W), int32(H), result)

func at(px: seq[uint32], x, y: int): uint32 = px[(H - 1 - y) * W + x]

proc redSquare(): Shape =
  result = newShape()
  check result.appendRect(8, 8, 16, 16)
  check result.fill(255, 0, 0)

suite "GlCanvas facade":
  test "newGlCanvas draws a shape into the framebuffer":
    let c = newGlCanvas(ctx.dc, ctx.rc, ctx.fbo, W, H)
    check c.add(redSquare()) == Result.Success
    c.render()
    let px = readFbo()
    check px.at(16, 16) == 0xff0000ffu32  # RGBA bytes 255,0,0,255 read as little endian
    check px.at(2, 2) == 0'u32
    c.destroy()

  test "invalid sizes and handles raise ValueError":
    expect ValueError: discard newGlCanvas(ctx.dc, ctx.rc, ctx.fbo, 0, H)
    expect ValueError: discard newGlCanvas(ctx.dc, 0, ctx.fbo, W, H)

  test "target to the same framebuffer again keeps working":
    let c = newGlCanvas(ctx.dc, ctx.rc, ctx.fbo, W, H)
    check c.add(redSquare()) == Result.Success
    c.render()
    check c.retarget(ctx.dc, ctx.rc, ctx.fbo, W, H) == Result.Success
    c.render()
    check readFbo().at(16, 16) == 0xff0000ffu32
    check c.target(ctx.dc, ctx.rc, ctx.fbo, 0, H) == Result.InvalidArguments
    c.destroy()

  test "a software canvas is not a GL canvas":
    let c = newSwCanvas(8, 8)
    check c.target(ctx.dc, ctx.rc, ctx.fbo, W, H) == Result.InsufficientCondition
    c.destroy()  # no-op

  test "destroy releases every GL object (once the canvas is out of scope)":
    proc frameAndDestroy() =
      let c = newGlCanvas(ctx.dc, ctx.rc, ctx.fbo, W, H)
      check c.add(redSquare()) == Result.Success
      c.render()
      c.destroy()
    frameAndDestroy()
    check glLiveObjects() == baseline
    check getError() == GlNoError

wglDestroy(ctx)
