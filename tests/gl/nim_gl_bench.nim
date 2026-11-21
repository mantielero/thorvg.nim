## Nim twin of `cpp_gl_driver.cpp`: the SAME scenes as `tests/parity/nim_driver.nim` rendered with the
## Nim GL engine (`newGlCanvas`) on a hidden WGL window + FBO, dumped in the same format
## (`.argb` = premultiplied ARGB, top row first; `.rgba` = raw readback, bottom row first; `.ppm`).
##
##   nim_gl_driver <scene> <w> <h> [--dump <prefix>] [--repeat N]     (--repeat is ignored)
##
## Exit code 0 ok, 2 usage / load / context / render error. Build:
##   nimc.ps1 -Src tests\gl\nim_gl_driver.nim -Mode release -Out build\nim_gl_driver_release.exe
## (tests\gl files are placed in tests\gl\build by default: always pass -Out and a nimcache.)

import std/[os, strutils, monotimes, times, algorithm]

type ProcMemCounters = object
  cb: uint32
  pageFaultCount: uint32
  peakWorkingSetSize, workingSetSize: uint
  rest: array[6, uint]
proc getCurrentProcess(): int {.importc: "GetCurrentProcess", stdcall, dynlib: "kernel32.dll".}
proc getProcessMemoryInfo(p: int, c: ptr ProcMemCounters, cb: uint32): int32 {.importc: "K32GetProcessMemoryInfo", stdcall, dynlib: "kernel32.dll".}
var repeatN = 0
proc workingSet(): int =
  var pc: ProcMemCounters
  pc.cb = uint32(sizeof(pc))
  discard getProcessMemoryInfo(getCurrentProcess(), addr pc, pc.cb)
  int(pc.workingSetSize)
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
    block benchLoop:  # verifier bench: opacity touch -> update + draw + sync + glFinish per frame
      var ts: seq[float]
      let live0 = glLiveObjects()
      var wsSamples: seq[(int, int, int)]
      for f in 0 ..< repeatN:
        let t0 = getMonoTime()
        for p in c.paints(): discard p.opacity(if (f and 1) == 1: 254'u8 else: 255'u8)
        check c.update(), "update"
        check c.draw(true), "draw"
        check c.sync(), "sync"
        finish()
        ts.add float((getMonoTime() - t0).inNanoseconds) / 1e6
        if f mod 20 == 0 or f == repeatN - 1: wsSamples.add((f, workingSet(), glLiveObjects()))
      if ts.len > 0:
        var s = ts[min(3, ts.len - 1) .. ^1]
        s.sort()
        var sum = 0.0
        for v in s: sum += v
        stderr.writeLine "BENCH frames=" & $ts.len & " first_ms=" & ts[0].formatFloat(ffDecimal, 3) &
          " median_ms=" & s[s.len div 2].formatFloat(ffDecimal, 3) & " mean_ms=" & (sum / float(s.len)).formatFloat(ffDecimal, 3) &
          " min_ms=" & s[0].formatFloat(ffDecimal, 3)
        stderr.writeLine "LIVE before=" & $live0 & " during_first=" & $wsSamples[0][2] & " during_last=" & $wsSamples[^1][2]
        var line = "WS(frame:MB:gl)"
        for (f, ws, lv) in wsSamples: line.add " " & $f & ":" & (float(ws) / 1048576.0).formatFloat(ffDecimal, 1) & ":" & $lv
        stderr.writeLine line
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
  repeatN = a.repeat
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
