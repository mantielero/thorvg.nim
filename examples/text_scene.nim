## The text demo scene, shared by `examples/text.nim` and the parity driver
## (`text` scene of cpp_driver.cpp: four lines plus an italic gradient text).

import std/os
import thorvg

proc findDefaultFont(): string =
  ## Picks a reasonable default TrueType font for the current platform.
  ## Can be overridden by passing `--font <path>` to the example.
  when defined(windows):
    result = r"C:\Windows\Fonts\arial.ttf"
  elif defined(macosx):
    const candidates = [
      "/System/Library/Fonts/Supplemental/Arial.ttf",
      "/Library/Fonts/Arial.ttf",
      "/System/Library/Fonts/Supplemental/Helvetica.ttf"
    ]
    for p in candidates:
      if fileExists(p): return p
    result = candidates[0]
  else:
    const candidates = [
      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
      "/usr/share/fonts/TTF/DejaVuSans.ttf",
      "/usr/share/fonts/dejavu/DejaVuSans.ttf",
      "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
      "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
      "/usr/share/fonts/noto/NotoSans-Regular.ttf",
      "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
      "/usr/share/fonts/truetype/freefont/FreeSans.ttf"
    ]
    for p in candidates:
      if fileExists(p): return p
    result = candidates[0]

let DefaultFont* = findDefaultFont()

type Line = object
  txt: string
  size, x, y: float32
  r, g, b: uint8

func line(txt: string, size, x, y: float32, r, g, b: uint8): Line =
  Line(txt: txt, size: size, x: x, y: y, r: r, g: g, b: b)

proc newLabel(size: float32, s: string): Text =
  result = newText()
  check result.font(), "font"
  check result.size(size)
  check result.text(s)

proc buildText*(c: Canvas, fontPath: string, firstLine = "") =
  ## Loads `fontPath` and adds the demo texts to `c`; `firstLine` replaces the
  ## 40 pt headline when not empty. Raises `ThorvgError` when something fails.
  if loadFont(fontPath) != Result.Success:
    raise newException(ThorvgError, "cannot load font " & fontPath)
  let lines = [
    line(if firstLine.len > 0: firstLine else: "Hello, ThorVG!", 40, 10, 10, 20, 20, 20),
    line("The quick brown fox jumps over the lazy dog 0123456789", 14, 10, 70, 160, 20, 20),
    line("AVATAR Wiggly gjpqy {}[]()&@#%", 24, 10, 100, 20, 80, 160),
    line("Rotated", 30, 250, 150, 0, 120, 0)]
  for i, l in lines:
    let t = newLabel(l.size, l.txt)
    check t.fill(l.r, l.g, l.b)
    check t.translate(l.x, l.y)
    if i == 3: check t.rotate(-20.0'f32)
    check c.add(t)
  let t = newLabel(48, "Gradient")
  check t.italic()
  let g = linearGradient(0, 0, 200, 0).withStops(
    colorStop(0.0'f32, 255, 0, 0), colorStop(1.0'f32, 0, 0, 255))
  check t.fill(g)
  check t.translate(10, 200)
  check c.add(t)
