## Command line handling and output shared by the example programs.
##
## Flags: `--out <file.bmp|.png|.ppm>` (write the frame), `--no-window` (do not open a
## window), `--size WxH`. Every other argument is returned as a positional argument.
## Without `--no-window` a window is opened and shown until it is closed
## (Esc also closes it); `THORVG_AUTOCLOSE_MS` closes it automatically.

import std/[os, parseopt, strutils, tables]
import thorvg
import thorvg/display/window

type
  Options* = object
    outFile*: string
    noWindow*: bool
    width*, height*: int
    args*: seq[string]
    extra*: Table[string, string]  ## values of the program specific options

proc parseSize(s: string, opts: var Options): bool =
  let parts = s.toLowerAscii.split('x')
  if parts.len == 2:
    try:
      opts.width = parseInt(parts[0])
      opts.height = parseInt(parts[1])
      result = opts.width > 0 and opts.height > 0
    except ValueError:
      result = false

proc parseOptions*(defaultW, defaultH: int, extraNames: openArray[string] = []): Options =
  ## Parses the process arguments; exits with a usage message on a bad flag.
  ## `extraNames` lists program specific `--name value` options (see `extra`).
  result = Options(width: defaultW, height: defaultH)
  var p = initOptParser(commandLineParams(), longNoVal = @["no-window"])
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: result.args.add key
    of cmdLongOption:
      case key
      of "out": result.outFile = val
      of "no-window": result.noWindow = true
      of "size":
        if not parseSize(val, result):
          quit("bad --size (expected WxH): " & val, 2)
      elif key in extraNames: result.extra[key] = val
      else: quit("unknown option --" & key, 2)
    else: quit("unknown option " & key, 2)

proc saveImage*(path: string, s: RenderSurface) =
  ## Writes `.bmp`, `.png` or `.ppm` depending on the extension.
  case splitFile(path).ext.toLowerAscii
  of ".bmp": writeBmp(path, s)
  of ".png": writePng(path, s)
  of ".ppm": writePpm(path, s)
  else: quit("--out must end in .bmp, .png or .ppm: " & path, 2)

proc output*(opts: Options, title: string, s: RenderSurface) =
  ## Saves the frame when `--out` was given, then shows it unless `--no-window`.
  if opts.outFile.len > 0:
    saveImage(opts.outFile, s)
  if not opts.noWindow:
    let win = openWindow(title, int(s.w), int(s.h))
    win.present(s)
    while win.pollEvents():
      if win.keyPressed(KeyEscape): win.close()
      else: sleep(10)
