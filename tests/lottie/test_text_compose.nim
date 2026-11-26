## tests/lottie/test_text_compose.nim
##
## Compara, por glifo y frame, la matriz final en espacio de escena (`wm`, 6
## floats) y los campos escalares del volcado de Nim contra el oraculo C++ 1.2.0.
## Recorre TODOS los casos de `layout_golden/compose/`: anadir un caso al
## generador lo incorpora sin tocar este fichero.
##
## Unico punto a conectar: `nimLayoutDump` (abajo). Mientras no este conectado
## el test falla de forma ruidosa; es lo esperado (tests en rojo primero).

import std/[json, os, strformat, unittest, strutils, sequtils, algorithm, sets]
import thorvg/lottie/parser/parser
import thorvg/lottie/builder/builder

const
  Dir          = "tests/lottie/layout_golden/compose"
  Width        = 400          # debe coincidir con gen_compose_cases.py
  Height       = 200
  TolLinear    = 1e-4         # terminos lineales de wm (adimensionales)
  TolTranslate = 1e-3         # px
  TolScalar    = 1e-4         # opacity, rangeFactor, strokeWidth
  # wm = [e11, e12, e13, e21, e22, e23] (orden de tvg::Matrix). Si el dump usa
  # otro orden, ajustar solo esto.
  TranslateIdx = [2, 5]
  MaxReport    = 5

type Rec = object
  frame: float
  layer: string
  idx: int
  wm: array[6, float]
  raw: JsonNode

# ---------------------------------------------------------------- adaptador
proc nimLayoutDump(lotPath: string; w, h: int; frames: seq[float]): seq[string] =
  ## Conecta con el hook de builder.nim (captureLayout / layoutDumpLines).
  ## Pura a nivel observable: nueva composicion/builder por llamada, sin estado global.
  let comp = parseLottieFile(readFile(lotPath))
  let b = newLottieBuilder(comp)
  b.captureLayout = true
  for fr in frames:
    discard b.update(float32(fr), float32(w), float32(h))
    result.add b.layoutDumpLines

# ------------------------------------------------------------------ lectura
proc parseDump(lines: seq[string]): seq[Rec] =
  for line in lines:
    if line.strip().len == 0: continue
    let j = parseJson(line)
    var r = Rec(
      frame: j["frame"].getFloat,
      layer: $j.getOrDefault("layer"),
      idx: j["idx"].getInt,
      raw: j)
    let wm = j["wm"]
    doAssert wm.len == 6, "wm debe tener 6 floats"
    for i in 0 ..< 6: r.wm[i] = wm[i].getFloat
    result.add r

proc readOracle(path: string): seq[Rec] =
  parseDump(toSeq(lines(path)))

proc framesOf(recs: seq[Rec]): seq[float] =
  var s = initHashSet[float]()
  for r in recs: s.incl r.frame
  result = toSeq(s.items)
  result.sort()

# --------------------------------------------------------------- comparacion
proc num(r: Rec; key: string): (bool, float) =
  if r.raw.hasKey(key) and r.raw[key].kind in {JInt, JFloat}:
    (true, r.raw[key].getFloat)
  else:
    (false, 0.0)

proc compare(exp, got: seq[Rec]): seq[string] =
  ## Devuelve la lista de discrepancias (vacia = coincide).
  if got.len != exp.len:
    return @[&"numero de glifos distinto: nim={got.len} c++={exp.len}"]
  for i in 0 ..< exp.len:
    let e = exp[i]; let g = got[i]
    if (e.frame, e.layer, e.idx) != (g.frame, g.layer, g.idx):
      result.add &"#{i}: orden/identidad distinta nim=({g.frame},{g.layer},{g.idx}) c++=({e.frame},{e.layer},{e.idx})"
      continue
    for k in 0 ..< 6:
      let tol = if k in TranslateIdx: TolTranslate else: TolLinear
      if abs(e.wm[k] - g.wm[k]) > tol:
        result.add &"frame={e.frame} idx={e.idx} wm[{k}]: nim={g.wm[k]:.6f} c++={e.wm[k]:.6f} (d={abs(e.wm[k]-g.wm[k]):.2e}, tol={tol})"
    for key in ["opacity", "rangeFactor", "strokeWidth"]:
      let (he, ve) = e.num(key); let (hg, vg) = g.num(key)
      if he != hg:
        let only = if he: "c++" else: "nim"
        result.add &"frame={e.frame} idx={e.idx} {key}: presente solo en {only}"
      elif he and abs(ve - vg) > TolScalar:
        result.add &"frame={e.frame} idx={e.idx} {key}: nim={vg:.6f} c++={ve:.6f}"

proc report(name: string; problems: seq[string]) =
  if problems.len > 0:
    checkpoint &"{name}: {problems.len} discrepancias; primeras {min(MaxReport, problems.len)}:"
    for p in problems[0 ..< min(MaxReport, problems.len)]: checkpoint "  " & p

# ----------------------------------------------------------- descubrimiento
proc stems(ext: string): seq[string] =
  for f in walkFiles(Dir / ("*." & ext)):
    let n = f.extractFilename.changeFileExt("")
    if not n.endsWith(".repeat"): result.add n
  result.sort()

let lots = stems("lot")
let oracles = stems("jsonl")

# Base de sensibilidad para cada familia de casos (el generador debe crearlas).
proc baseFor(name: string): string =
  if name.startsWith("groupscale_"): "base_multi"
  elif name.startsWith("group_"): "base_multi"
  elif name.startsWith("range_"): "base_range"  # cubre range_*_opacity
  elif name.startsWith("track_"): "base_track"
  elif ["single_", "pair_", "full_"].anyIt(name.startsWith(it)): "base_single"
  else: ""

# ---------------------------------------------------------------- ratchet
const KnownFile = Dir / "known_failing.txt"

proc loadKnown(): HashSet[string] =
  ## Una entrada por linea; todo lo que sigue a '#' es comentario.
  if not fileExists(KnownFile): return initHashSet[string]()
  for line in lines(KnownFile):
    let name = line.split('#')[0].strip()
    if name.len > 0: result.incl name

let known = loadKnown()
let snapshotMode = getEnv("KNOWN_SNAPSHOT") == "1"
var failingNow: seq[string]

# -------------------------------------------------------------------- tests
suite "descubrimiento":
  test "hay casos":
    check lots.len > 0
  test "cada .lot tiene oraculo y viceversa":
    checkpoint "sin oraculo: " & $(lots.filterIt(it notin oracles))
    checkpoint "sin .lot: " & $(oracles.filterIt(it notin lots))
    check lots.toHashSet == oracles.toHashSet

suite "known_failing coherente":
  test "toda entrada de known_failing existe como caso":
    let stale = toSeq(known.items).filterIt(it notin lots)
    checkpoint "entradas sin caso: " & $stale
    check stale.len == 0

suite "wm contra oraculo C++":
  for name in lots:
    test name:
      let lotPath = Dir / (name & ".lot")
      let jsonl = Dir / (name & ".jsonl")
      doAssert fileExists(jsonl), &"falta oraculo {jsonl} (ejecutar gen_compose_cases.py)"
      let exp = readOracle(jsonl)
      doAssert exp.len > 0, &"oraculo vacio: {jsonl}"
      let got = parseDump(nimLayoutDump(lotPath, Width, Height, framesOf(exp)))
      let problems = compare(exp, got)
      let passes = problems.len == 0
      if snapshotMode:
        if not passes: failingNow.add name
      elif name in known:
        checkpoint name & " ahora PASA: eliminarlo de known_failing.txt"
        check not passes
      else:
        report(name, problems)
        check passes

suite "sensibilidad del oraculo":
  # Si el oraculo de un caso es identico al de su base, la parametrizacion del
  # caso o el punto de flush del dump son incorrectos: el test no probaria nada.
  for name in lots:
    let base = baseFor(name)
    if base.len == 0: continue
    test name & " difiere de " & base:
      doAssert base in oracles, &"falta caso base {base} en el generador"
      let a = readOracle(Dir / (name & ".jsonl"))
      let b = readOracle(Dir / (base & ".jsonl"))
      proc sig(r: Rec): string =
        var s = ""
        for v in r.wm: s.add &"{v:.5f},"
        for k in ["opacity", "rangeFactor", "strokeWidth"]:
          let (h, v) = r.num(k)
          if h: s.add k & ":" & &"{v:.5f},"
        s
      let same = a.len == b.len and zip(a, b).allIt(sig(it[0]) == sig(it[1]))
      check not same

suite "determinismo de Nim":
  test "dos ejecuciones identicas":
    for name in lots:
      let lotPath = Dir / (name & ".lot")
      let fr = framesOf(readOracle(Dir / (name & ".jsonl")))
      check nimLayoutDump(lotPath, Width, Height, fr) ==
            nimLayoutDump(lotPath, Width, Height, fr)

if snapshotMode:
  let outPath = KnownFile & ".new"
  writeFile(outPath, failingNow.sorted.join("\n") & "\n")
  echo "known_failing.txt.new escrito: ", failingNow.len, " casos que fallan hoy"
