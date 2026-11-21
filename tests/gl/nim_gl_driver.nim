## Nim twin of `cpp_gl_driver.cpp`: the SAME scenes as `tests/parity/nim_driver.nim` rendered with the
## Nim GL engine (`newGlCanvas`) on a hidden WGL window + FBO, dumped in the same format
## (`.argb` = premultiplied ARGB, top row first; `.rgba` = raw readback, bottom row first; `.ppm`).
##
##   nim_gl_driver <scene> <w> <h> [--dump <prefix>] [--repeat N]     (--repeat is ignored)
##
## Exit code 0 ok, 2 usage / load / context / render error. Build:
##   nimc.ps1 -Src tests\gl\nim_gl_driver.nim -Mode release -Out build\nim_gl_driver_release.exe
## (tests\gl files are placed in tests\gl\build by default: always pass -Out and a nimcache.)

import std/[os, strutils]
import thorvg
import thorvg/engine/gl/[glcanvas, gl_ffi, wgl_ffi]
import ../parity/driver_common
import ./glx_scene

proc renderGl(scene: string, w, h: int, argb, raw: var seq[uint32]) =
  ## Renders into `argb` (premultiplied ARGB, top row first); `raw` = readback words
  ## (bytes R,G,B,A, bottom row first).
  var (created, ctx) = wglCreateOffscreen(w, h)
  if not created: raise newException(Fail, "context failed")
  try:
    clearColor(0, 0, 0, 0)
    clearStencil(0)
    clear(GlColorBufferBit or GlDepthBufferBit or GlStencilBufferBit)
    let c = newGlCanvas(ctx.dc, ctx.rc, ctx.fbo, w, h)
    if scene.startsWith("glx:"):
      if not buildGlx(c, scene.substr(4)): raise newException(Fail, "unknown glx scene")
    else:
      buildScene(c, scene, w, h)
    check c.update(), "update"
    check c.draw(true), "draw"
    check c.sync(), "sync"
    bindFramebuffer(GlFramebuffer, ctx.fbo)
    pixelStorei(GlPackAlignment, 1)
    readPixels(0, 0, int32(w), int32(h), raw)
    argb = newSeq[uint32](w * h)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let s = raw[(h - 1 - y) * w + x]  # GL origin is bottom-left; word = R | G<<8 | B<<16 | A<<24
        argb[y * w + x] = (s and 0xff00ff00'u32) or ((s and 0xff'u32) shl 16) or
          ((s shr 16) and 0xff'u32)
    c.destroy()  # releases GL objects while the context is still current
  finally:
    wglDestroy(ctx)

proc writeRgba(prefix: string, raw: seq[uint32]) =
  var bytes = newString(raw.len * 4)
  for i, p in raw:
    for k in 0 ..< 4: bytes[i * 4 + k] = char((p shr (8 * k)) and 0xff'u32)
  writeFile(prefix & ".rgba", bytes)

proc main(): int =
  var a: DriverArgs
  let rc = parseDriverArgs("nim_gl_driver", commandLineParams(), a)
  if rc != 0: return rc
  var argb, raw: seq[uint32]
  try:
    renderGl(a.scene, a.w, a.h, argb, raw)
  except CatchableError as e:
    stderr.writeLine e.msg
    return 2
  glTerm()
  printSummary(a.scene, a.w, a.h, argb)
  if a.dump.len > 0:
    writeDump(a.dump, argb, a.w, a.h)
    writeRgba(a.dump, raw)
  0

quit(main())
