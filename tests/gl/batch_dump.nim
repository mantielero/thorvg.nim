## Differential oracle for G2c (`solid_batch`, `stencil_batch`).
##
##   batch_dump gen <cases.txt> [seed]      writes the case file
##   batch_dump run <cases.txt> <out.txt>   runs the Nim port on the cases
##
## `batch_dump.cpp` reads the same case file, runs the ORIGINAL tvgGlSolidBatch.cpp /
## tvgGlStencilCoverBatch.cpp and writes the same text format: after every op the three stage
## arrays (words, or an FNV-1a 64 hash above 256 words), `DUMP` also lists the pass tasks.
## Geometry is synthetic: `nf ni seed` expands with an LCG (see `fillBuffer`).
import std/[strutils, options, os, sequtils]
import thorvg/core/[types, geom]
import thorvg/renderer/render
import thorvg/engine/gl/[gl_common, gl_ffi, gpu_buffer, program, render_pass, render_target,
  render_task, solid_batch, state_cache, stencil_batch]

const
  Blends = [BlendMethod.Normal, BlendMethod.Multiply, BlendMethod.Screen, BlendMethod.Overlay]
  RtColor = 0
  RtImage = 4
  RtStencil = 15

func hx(f: float32): string = toHex(floatBits(f), 8).toLowerAscii

# ------------------------------------------------------------------ generator

type Gen = object
  lines: seq[string]
  x: uint32

proc rnd(g: var Gen, n: int): int =
  g.x = g.x * 1664525'u32 + 1013904223'u32
  int((g.x shr 8) mod uint32(n))

proc region(g: var Gen, maxPos, maxSize: int): string =
  let x = g.rnd(maxPos)
  let y = g.rnd(maxPos)
  $x & " " & $y & " " & $(x + g.rnd(maxSize)) & " " & $(y + g.rnd(maxSize))

proc geom(g: var Gen, stride, maxV, maxI: int, allowEmpty = true): string =
  var nv = 1 + g.rnd(maxV)
  var ni = 3 * (1 + g.rnd(maxI))
  if allowEmpty and g.rnd(12) == 0: nv = 0
  if allowEmpty and g.rnd(12) == 0: ni = 0
  $(nv * stride) & " " & $ni & " " & $g.rnd(100000)

const
  Bounds = ["0 0 200 200", "0 0 120 90", "10 10 150 150"]
  Matrices = [
    "3f800000 0 0 0 3f800000 0 0 0 3f800000",
    "40000000 0 0 0 40000000 0 0 0 3f800000",
    "3f800000 0 41200000 0 3f800000 c1a00000 0 0 3f800000",
    "3f000000 3e800000 41500000 be800000 3f000000 40a00000 0 0 3f800000"]
  Viewports = ["0 0 200 200", "0 0 100 300", "20 30 220 130", "0 0 300 100"]

proc newPass(g: var Gen) =
  g.lines.add "NEWPASS " & Viewports[g.rnd(Viewports.len)]
  g.lines.add "SCLEAR"
  g.lines.add "TCLEAR"

proc solidOp(g: var Gen, vb: string) =
  g.lines.add "SOLID " & g.geom(2, 12, 6) & " " & $(if g.rnd(5) == 0: 256 + g.rnd(300) else: g.rnd(256)) &
    " " & $(g.rnd(3) * 100) & " " & $(g.rnd(2) * 50) & " 7 " & $(200 + g.rnd(2) * 55) & " " & $(1 + g.rnd(4)) & " " & g.region(100, 80) & " " & vb

proc imageOp(g: var Gen, vb: string) =
  g.lines.add "IMAGE " & g.geom(4, 8, 4) & " " & $(1 + g.rnd(2)) & " " & $(if g.rnd(6) == 0: 256 + g.rnd(300) else: 255 - g.rnd(2)) &
    " " & $(1 + g.rnd(5)) & " " & g.region(100, 80) & " " & vb

proc stencilOp(g: var Gen, vb: string, bb: string, nv, ni: int, fixedColor = -1) =
  let mode = if g.rnd(8) == 0: 0 else: 1 + g.rnd(3)
  let hasColor = if fixedColor >= 0: fixedColor else: (if g.rnd(3) == 0: 0 else: 1)
  let clipped = if g.rnd(7) == 0: 1 else: 0
  let gm = if nv > 0: $(nv * 2) & " " & $ni & " " & $g.rnd(100000)
    else: g.geom(2, 10, 5)
  let sg = g.geom(2, 10, 5)
  g.lines.add "STENCIL " & $(if g.rnd(4) == 0: g.rnd(5) else: 0) & " " & $mode & " " & $hasColor & " " &
    $g.rnd(256) & " " & $g.rnd(256) & " " & $g.rnd(4) & " 255 " & vb & " " & $clipped & " " &
    Matrices[if g.rnd(3) == 0: g.rnd(Matrices.len) else: 0] & " " & bb & " " &
    g.region(150, 60) & " " & gm & " " & sg & " " & $(g.rnd(3) * 5) & " " & $g.rnd(2) & " " &
    $(1 + g.rnd(4)) & " " & $(if g.rnd(9) == 0: 1 else: 0)

proc generate(seed: uint32): seq[string] =
  var g = Gen(x: seed)
  # A: random solid / image / blend / flush sequences
  for s in 0 ..< 60:
    g.newPass()
    g.lines.add "FLUSH"
    let vb = Bounds[g.rnd(Bounds.len)]
    for i in 0 ..< 30:
      let k = g.rnd(100)
      if k < 55: g.solidOp(if g.rnd(8) == 0: Bounds[g.rnd(Bounds.len)] else: vb)
      elif k < 72: g.imageOp(vb)
      elif k < 78: g.lines.add "BLEND " & $g.rnd(4)
      elif k < 82: g.lines.add "SCLEAR"
      elif k < 85: g.lines.add "FLUSH"
      elif k < 87: g.newPass()
      else: g.lines.add "DUMP"
    g.lines.add "DUMP"
  # B: random stencil sequences mixed with solid / image / clear
  for s in 0 ..< 60:
    g.newPass()
    g.lines.add "FLUSH"
    let vb = Bounds[g.rnd(Bounds.len)]
    for i in 0 ..< 25:
      let k = g.rnd(100)
      if k < 70: g.stencilOp(vb, g.region(150, 40), 0, 0, if s mod 2 == 0: 1 else: -1)
      elif k < 78: g.solidOp(vb)
      elif k < 83: g.imageOp(vb)
      elif k < 88: g.lines.add "TCLEAR"
      elif k < 91: g.lines.add "BLEND " & $g.rnd(4)
      elif k < 93: g.newPass()
      else: g.lines.add "DUMP"
    g.lines.add "DUMP"
  # C: limits. region count (512), vertex count (262144), index count (1048576)
  for ys in 0 .. 1:
    g.lines.add "NEWPASS " & (if ys == 0: "0 0 3000 100" else: "0 0 100 3000")
    g.lines.add "FLUSH"
    g.lines.add "TCLEAR"
    for i in 0 ..< 530:
      let a = i * 5
      let bb = (if ys == 0: $a & " 0 " & $(a + 4) & " 50" else: "0 " & $a & " 50 " & $(a + 4))
      g.lines.add "STENCIL 0 1 1 10 20 30 255 0 0 3000 3000 0 " & Matrices[0] & " " & bb & " 0 0 0 0 6 3 " &
        $g.rnd(100000) & " 0 0 0 5 0 1 0"
    g.lines.add "DUMP"
    g.lines.add "TCLEAR"
    var a = 0
    for (nv, ni) in [(150000, 30), (150000, 30), (4, 600000), (4, 600000), (4, 300000)]:
      a += 3
      g.lines.add "STENCIL 0 1 0 10 20 30 255 0 0 3000 3000 0 " & Matrices[0] & " " & $(a * 2) & " 0 " & $(a * 2 + 1) &
        " 50 0 0 0 0 " & $(nv * 2) & " " & $ni & " " & $g.rnd(100000) & " 0 0 0 5 0 1 0"
    g.lines.add "DUMP"
  g.lines

# ------------------------------------------------------------------ text io

type
  Reader = object
    tok: seq[string]
    pos: int

  Sim = object
    stage: GlStageBuffer
    programs: seq[GlProgram]
    pass: GlRenderPass
    blend: BlendMethod
    solid: GlSolidBatch
    stencil: GlStencilCoverBatch

proc next(r: var Reader): string =
  result = r.tok[r.pos]
  inc r.pos

proc rInt(r: var Reader): int = parseInt(r.next())
proc rU(r: var Reader): uint32 = uint32(parseBiggestUInt(r.next()))
proc rRegion(r: var Reader): Region =
  result.xMin = int32(r.rInt())
  result.yMin = int32(r.rInt())
  result.xMax = int32(r.rInt())
  result.yMax = int32(r.rInt())

proc rMatrix(r: var Reader): Matrix =
  var f: array[9, float32]
  for i in 0 ..< 9: f[i] = bitsFloat(uint32(parseHexInt(r.next())))
  Matrix(e11: f[0], e12: f[1], e13: f[2], e21: f[3], e22: f[4], e23: f[5],
    e31: f[6], e32: f[7], e33: f[8])

proc rGeom(r: var Reader, b: var GlGeometryBuffer, stride: uint32) =
  let nf = r.rU()
  let ni = r.rU()
  var x = r.rU()
  for i in 0'u32 ..< nf:
    x = x * 1664525'u32 + 1013904223'u32
    b.vertex.add float32((x shr 16) and 0x7ff'u32) / 8.0'f32 - 100.0'f32
  let nv = nf div stride
  for i in 0'u32 ..< ni:
    x = x * 1664525'u32 + 1013904223'u32
    b.index.add if nv == 0: 0'u32 else: (x shr 8) mod nv

func fmtRegion(r: Region): string = $r.xMin & " " & $r.yMin & " " & $r.xMax & " " & $r.yMax

func fmtMatrix(m: Matrix): string =
  [m.e11, m.e12, m.e13, m.e21, m.e22, m.e23, m.e31, m.e32, m.e33].mapIt(hx(it)).join(" ")

func fmtWords(w: seq[uint32]): string =
  result = $w.len
  if w.len <= 256:
    for v in w: result.add " " & $v
  else:
    var h = 1469598103934665603'u64
    for v in w:
      h = h xor uint64(v)
      h = h * 1099511628211'u64
    result.add " #" & $h

proc progId(s: Sim, p: GlProgram): int =
  if p == nil: return 0
  for i, q in s.programs:
    if q == p: return i + 1
  -1

proc fmtTask(s: Sim, t: GlRenderTask): string =
  let stc = t of GlStencilCoverTask
  result = (if stc: "STC" else: "TASK")
  result.add " " & $s.progId(t.program) & " " & hx(t.drawDepth) & " " & fmtRegion(t.viewport) & " " &
    $t.indexCnt & " " & $t.indexOffset & " " & $t.arrayOffset & " " & $t.arrayMode & " " &
    fmtMatrix(t.viewMatrix) & " " & hx(t.vertexColor[0]) & " " & hx(t.vertexColor[1]) & " " &
    hx(t.vertexColor[2]) & " " & hx(t.vertexColor[3]) & " " & $int(t.useViewMatrix) & " " &
    $int(t.useVertexColor) & " " & $int(t.useDrawArrays) & " " & $ord(t.blendMethod)
  result.add " L" & $t.vertexLayout.len
  for l in t.vertexLayout:
    result.add " " & $l.index & " " & $l.size & " " & $l.stride & " " & $l.offset & " " & $l.ty &
      " " & $int(l.normalized) & " " & $l.arrayBufferId
  result.add " B" & $t.bindResources.len
  for b in t.bindResources:
    let tex = b.kind == GlBindingKind.Texture
    result.add " " & $ord(b.kind) & " " & $(if tex: ord(b.uniform) else: 7) & " " &
      $(if tex: 7 else: ord(b.uniformBlock)) & " " & $b.bindPoint & " " & $b.resourceId & " " &
      $b.bufferOffset & " " & $b.bufferRange
  if stc:
    let c = GlStencilCoverTask(t)
    result.add " M" & $ord(c.stencilMode) & " S" & $c.stencilTasks.len
    for p in c.stencilTasks: result.add " ( " & s.fmtTask(p) & " )"
    result.add " C" & $c.coverTasks.len
    for p in c.coverTasks: result.add " ( " & s.fmtTask(p) & " )"

proc fmtPass(s: Sim): string =
  var tasks: seq[GlRenderTask]
  while true:
    let t = s.pass.takeLastTask()
    if t == nil: break
    tasks.add t
  result = "N" & $tasks.len
  for i in countdown(tasks.high, 0):
    result.add " [ " & s.fmtTask(tasks[i]) & " ]"
    s.pass.addRenderTask(tasks[i])

proc newPass(s: var Sim, vp: Region) =
  s.pass = newGlRenderPass(GlRenderTarget(viewport: vp, width: uint32(vp.sw),
    height: uint32(vp.sh), fbo: 1))

func rFlag(v: int): RenderUpdateFlag =
  case v
  of 0: RenderUpdateFlag.Path
  of 1: RenderUpdateFlag.Stroke
  of 2: RenderUpdateFlag.GradientStroke
  of 3: RenderUpdateFlag.Gradient
  else: RenderUpdateFlag.Color

proc runCases(casePath, outPath: string) =
  var r = Reader(tok: readFile(casePath).splitWhitespace())
  var s = Sim(stage: newCpuStageBuffer(256), blend: BlendMethod.Normal)
  for i in 0 ..< 24: s.programs.add newOfflineGlProgram()
  s.newPass(Region(xMin: 0, yMin: 0, xMax: 100, yMax: 100))
  var cache: GlStateCache
  var o = open(outPath, fmWrite)
  while r.pos < r.tok.len:
    let op = r.next()
    var line = op
    case op
    of "NEWPASS": s.newPass(r.rRegion())
    of "BLEND": s.blend = Blends[r.rInt()]
    of "FLUSH": discard s.stage.flushToGPU(cache)
    of "SCLEAR": s.solid.clear()
    of "TCLEAR": s.stencil.clear()
    of "SOLID":
      let shape = newGlShape(RenderShape())
      r.rGeom(shape.geometry.fill, 2)
      shape.opacity = r.rU()
      let c = RGBA(r: uint8(r.rInt()), g: uint8(r.rInt()), b: uint8(r.rInt()), a: uint8(r.rInt()))
      let depth = int32(r.rInt())
      let viewRegion = r.rRegion()
      let viewBounds = r.rRegion()
      s.solid.draw(s.stage, s.pass, s.programs[RtColor], s.blend, shape, c, depth, viewRegion,
        viewBounds)
    of "IMAGE":
      let image = newGlImage(RenderSurface())
      r.rGeom(image.geometry.fill, 4)
      image.texId = r.rU()
      image.opacity = r.rU()
      let depth = int32(r.rInt())
      let viewRegion = r.rRegion()
      let viewBounds = r.rRegion()
      s.solid.draw(s.stage, s.pass, s.programs[RtImage], s.blend, image, depth, viewRegion,
        viewBounds)
    of "STENCIL":
      let shape = newGlShape(RenderShape())
      let flag = rFlag(r.rInt())
      let mode = GlStencilMode(r.rInt())
      let hasColor = r.rInt() != 0
      let c = RGBA(r: uint8(r.rInt()), g: uint8(r.rInt()), b: uint8(r.rInt()), a: uint8(r.rInt()))
      let viewBounds = r.rRegion()
      if r.rInt() != 0: shape.clips.add RenderData(nil)
      shape.geometry.transform(r.rMatrix())
      shape.geometry.fillBBox = r.rRegion()
      shape.geometry.strokeBBox = r.rRegion()
      r.rGeom(shape.geometry.fill, 2)
      r.rGeom(shape.geometry.stroke, 2)
      let prog = int(r.rU())
      let blend = Blends[r.rInt()]
      let depth = int32(r.rInt())
      let coverBind = r.rInt() != 0
      let cover = newGlRenderTask(s.programs[prog], blend)
      cover.setViewMatrix(s.pass.getViewMatrix())
      cover.setDrawDepth(depth)
      if coverBind: cover.addBindResource(textureBinding(0, 5, GlShaderUniform.Texture))
      let prep = s.stencil.prepare(s.stage, s.pass, s.programs[RtStencil], cover, shape, flag,
        mode, if hasColor: some(c) else: none(RGBA), viewBounds)
      s.stencil.draw(s.pass, cover, prep)
    of "DUMP": line.add " " & s.fmtPass()
    else: quit("unknown op " & op, 2)
    line.add " | " & fmtWords(s.stage.stage) & " | " & fmtWords(s.stage.aux) & " | " &
      fmtWords(s.stage.index)
    o.writeLine line
  o.close()

proc main() =
  let args = commandLineParams()
  if args.len >= 2 and args[0] == "gen":
    let seed = if args.len > 2: uint32(parseInt(args[2])) else: 12345'u32
    writeFile(args[1], generate(seed).join("\n") & "\n")
  elif args.len == 3 and args[0] == "run":
    runCases(args[1], args[2])
  else:
    quit("usage: batch_dump gen <cases> [seed] | run <cases> <out>", 2)

main()
