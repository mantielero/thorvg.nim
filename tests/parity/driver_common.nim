## Scene building and dump code shared by the two Nim parity drivers: `nim_driver.nim` (CPU) and
## `tests/gl/nim_gl_driver.nim` (GL). Both mirror `cpp_driver.cpp` (same scenes, same stdout line,
## same `.argb`/`.ppm` dumps).
##
##   scene = shapes | shapes:<part> | svg:<file.svg> | png:<file.png> | jpg:<file.jpg> |
##           webp:<file.webp> | pngrot:<file.png>[@deg,scale,shear,opacity] |
##           gif:<file.gif>[:f1,f2,..] | text | text:<file.ttf>

import std/[parseutils, strutils]
import thorvg
import ../../examples/shapes_scene
import ../../examples/text_scene
import ./rotscene

type Fail* = object of CatchableError

type DriverArgs* = object
  scene*: string
  w*, h*: int
  dump*: string
  repeat*: int

proc parseSize(s: string): int =
  var n = 0
  if parseInt(s, n) != s.len or n <= 0 or n > 16384: -1 else: n

proc parseDriverArgs*(name: string, args: seq[string], res: var DriverArgs): int =
  ## Parses `<scene> <w> <h> [--dump <prefix>] [--repeat N]`; returns 0 or the exit code 2.
  if args.len < 3:
    stderr.writeLine "usage: " & name & " <scene> <w> <h> [--dump <prefix>] [--repeat N]"
    return 2
  res = DriverArgs(scene: args[0], w: parseSize(args[1]), h: parseSize(args[2]), repeat: 1)
  if res.w < 0 or res.h < 0:
    stderr.writeLine "bad size"
    return 2
  var i = 3
  while i < args.len:
    if args[i] == "--dump" and i + 1 < args.len:
      res.dump = args[i + 1]
      i += 2
    elif args[i] == "--repeat" and i + 1 < args.len:
      res.repeat = parseInt(args[i + 1])
      i += 2
    else:
      stderr.writeLine "bad argument " & args[i]
      return 2
  0

proc gifPicture(path: string, w, h: int): Picture =
  ## `gif:<file>[:f1,f2,..]`: seeks the animation through the frame list (results
  ## ignored, like the C++ driver), then fits the picture like `png:`.
  var file = path
  var frames = "0"
  let colon = path.rfind(':')
  if colon >= 0:
    file = path.substr(0, colon - 1)
    frames = path.substr(colon + 1)
  let anim = newAnimation()
  result = anim.picture()
  if result.load(file) != Result.Success: raise newException(Fail, "cannot load " & file)
  var pw, ph = 0.0'f32
  check result.size(pw, ph), "picture size"
  if not (pw > 0.0'f32 and ph > 0.0'f32): raise newException(Fail, "bad picture size")
  for item in frames.split(','):
    var v = 0.0
    discard parseFloat(item, v)
    discard anim.frame(float32(v))
  let fw = float32(w)
  let fh = float32(h)
  let scale = min(fw / pw, fh / ph)
  let nw = pw * scale
  let nh = ph * scale
  check result.size(nw, nh), "picture size"
  check result.translate((fw - nw) * 0.5'f32, (fh - nh) * 0.5'f32), "translate"

proc buildScene*(c: Canvas, scene: string, w, h: int) =
  ## Adds the paints of `scene` to `c`; raises `Fail`/`ThorvgError` like the C++ driver exits 2.
  if scene == "shapes":
    discard buildShapes(c, "")
  elif scene.startsWith("shapes:"):
    if not buildShapes(c, scene.substr(7)): raise newException(Fail, "no such part")
  elif scene.startsWith("svg:") or scene.startsWith("png:") or scene.startsWith("jpg:"):
    check c.add(fitPicture(scene.substr(4), w, h))
  elif scene.startsWith("webp:"):
    check c.add(fitPicture(scene.substr(5), w, h))
  elif scene.startsWith("gif:"):
    check c.add(gifPicture(scene.substr(4), w, h))
  elif scene.startsWith("pngrot:"):
    check c.add(rotPicture(scene.substr(7), w, h))
  elif scene == "text" or scene.startsWith("text:"):
    buildText(c, if scene == "text": DefaultFont else: scene.substr(5))
  else:
    raise newException(Fail, "unknown scene " & scene)

proc fnv1a64(px: seq[uint32]): uint64 =
  result = 1469598103934665603'u64
  for p in px:
    for k in 0 ..< 4:
      result = (result xor ((p shr (8 * k)) and 0xff'u32)) * 1099511628211'u64

proc printSummary*(scene: string, w, h: int, px: seq[uint32]) =
  ## The one stdout line of the drivers.
  var nonzero, opaque = 0
  for p in px:
    if p != 0: inc nonzero
    if (p shr 24) == 255: inc opaque
  echo "scene=", scene, " size=", w, "x", h, " fnv1a64=", toHex(fnv1a64(px), 16).toLowerAscii,
    " nonzero=", nonzero, " opaque=", opaque

proc writeDump*(prefix: string, px: seq[uint32], w, h: int) =
  ## `<prefix>.argb` (little endian uint32, premultiplied ARGB, top row first) and `.ppm`
  ## (P6 composited over white).
  let n = w * h
  var argb = newString(n * 4)
  var ppm = "P6\n" & $w & " " & $h & "\n255\n"
  for i in 0 ..< n:
    let p = px[i]
    for k in 0 ..< 4: argb[i * 4 + k] = char((p shr (8 * k)) and 0xff'u32)
    let a = p shr 24
    for sh in [16'u32, 8, 0]:
      ppm.add char(min(((p shr sh) and 0xff'u32) + (255'u32 - a), 255'u32))
  writeFile(prefix & ".argb", argb)
  writeFile(prefix & ".ppm", ppm)
