## GL shader pair: compile a vertex and a fragment shader (port of tvgGlShader.cpp/.h).
##
## The text handed to GL is `ShaderPreamble & vertPrefix & vert` for the vertex shader and
## `ShaderPreamble & frag` for the fragment shader (`programs.fullVertex/fullFragment`); the C++
## passes the three pieces as separate strings to `glShaderSource`, which concatenates them.
##
## A stage that fails to compile is logged (`logGlError`), deleted and reported as id 0.

import ./[gl_ffi, programs]

type
  GlShader* = object
    ## Owns the two shader objects; they are deleted by `destroy` / `=destroy`.
    vtShader*: GlId
    frShader*: GlId

var
  glLogEnabled* = true
    ## When true `logGlError` also writes to stderr (the C++ `TVGERR`).
  glLastError* = ""
    ## Last message passed to `logGlError`; tests read it.

proc logGlError*(msg: string) =
  glLastError = msg
  if glLogEnabled: stderr.writeLine "[GL_ENGINE] " & msg

proc compileShader*(ty: GlEnum, source: string): GlId =
  ## Compiles one stage; returns 0 (after logging the info log) when it does not compile.
  let shader = createShader(ty)
  if shader == 0:
    logGlError "Error creating shader"
    return 0
  shaderSource(shader, source)
  compileShader(shader)
  if getShaderiv(shader, GlCompileStatus) != 0: return shader
  let log = getShaderInfoLog(shader)
  if log.len > 0: logGlError "Error compiling shader: " & log
  deleteShader(shader)
  result = 0

proc destroy*(s: var GlShader) =
  ## Deletes both shader objects (idempotent).
  if s.vtShader != 0: deleteShader(s.vtShader)
  if s.frShader != 0: deleteShader(s.frShader)
  s.vtShader = 0
  s.frShader = 0

proc `=destroy`*(s: GlShader) =
  if glReady():
    try:
      if s.vtShader != 0: deleteShader(s.vtShader)
      if s.frShader != 0: deleteShader(s.frShader)
    except Exception: discard

proc `=copy`*(a: var GlShader, b: GlShader) {.error.}

proc newShader*(src: ProgramSource): GlShader =
  ## `GlShader(vertSrc, fragSrc, vertPrefix)`: a failed stage has id 0.
  result = GlShader(vtShader: compileShader(GlVertexShader, src.fullVertex),
    frShader: compileShader(GlFragmentShader, src.fullFragment))

proc newShader*(vert, frag: string, vertPrefix = ""): GlShader =
  newShader(ProgramSource(vert: vert, frag: frag, vertPrefix: vertPrefix))

func getVertexShader*(s: GlShader): GlId = s.vtShader
func getFragmentShader*(s: GlShader): GlId = s.frShader

func ok*(s: GlShader): bool =
  ## Both stages compiled.
  s.vtShader != 0 and s.frShader != 0
