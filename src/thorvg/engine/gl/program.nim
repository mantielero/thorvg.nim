## GL program: link two shaders, cached uniform / uniform block lookups\n## (port of tvgGlProgram.cpp/.h).
##
## A program that fails to compile or link is logged and has `programId == 0` (the C++ asserts);
## check `isValid`. The GL object is released by `destroy` (idempotent) or by the `=destroy` hook
## of the object when the last reference goes away while a GL context is still loaded.
##
## `load(program, cache)` / `unload(cache)` bind through the state cache (the C++ callers do
## `state.useProgram(program->getProgramId())`).

import ./[gl_ffi, programs, shader, state_cache]

const
  UnknownLocation = -2'i32
  UnknownBinding = high(uint32)

type
  GlShaderUniform* {.pure.} = enum
    Depth
    ViewMatrix
    SourceTexture
    BlurTexture
    DestinationTexture
    MaskTexture
    Texture

  GlShaderUniformBlock* {.pure.} = enum
    Gaussian
    Viewport
    DropShadow
    Params
    BlendRegion
    GradientInfo
    ColorInfo

  GlProgramObj* = object
    programObj: GlId
    uniformLocations: array[GlShaderUniform, int32]
    uniformBlockIndices: array[GlShaderUniformBlock, int32]
    uniformBlockBindings: array[GlShaderUniformBlock, uint32]
    samplerBindings: array[GlShaderUniform, int32]

  GlProgram* = ref GlProgramObj

const
  UniformNames: array[GlShaderUniform, string] = ["uDepth", "uViewMatrix", "uSrcTexture",
    "uBlrTexture", "uDstTexture", "uMaskTexture", "uTexture"]
  UniformBlockNames: array[GlShaderUniformBlock, string] = ["Gaussian", "Viewport",
    "DropShadow", "Params", "BlendRegion", "GradientInfo", "ColorInfo"]

proc `=destroy`*(p: GlProgramObj) =
  if p.programObj != 0 and glReady():
    try: deleteProgram(p.programObj)
    except Exception: discard

proc link(sh: GlShader): GlId =
  ## Creates and links a program from compiled shaders; 0 on failure.
  let prog = createProgram()
  if prog == 0:
    logGlError "Error creating program"
    return 0
  attachShader(prog, sh.getVertexShader())
  attachShader(prog, sh.getFragmentShader())
  linkProgram(prog)
  if getProgramiv(prog, GlLinkStatus) != 0: return prog
  let log = getProgramInfoLog(prog)
  if log.len > 0: logGlError "Error linking shader: " & log
  deleteProgram(prog)
  result = 0

proc newGlProgram*(src: ProgramSource): GlProgram =
  ## `new GlProgram(vertSrc, fragSrc, vertPrefix)`.
  result = GlProgram()
  for u in GlShaderUniform:
    result.uniformLocations[u] = UnknownLocation
    result.samplerBindings[u] = -1
  for b in GlShaderUniformBlock:
    result.uniformBlockIndices[b] = UnknownLocation
    result.uniformBlockBindings[b] = UnknownBinding
  var sh = newShader(src)
  if sh.ok: result.programObj = link(sh)
  sh.destroy()

proc newGlProgram*(vert, frag: string, vertPrefix = ""): GlProgram =
  newGlProgram(ProgramSource(vert: vert, frag: frag, vertPrefix: vertPrefix))

proc newOfflineGlProgram*(): GlProgram =
  ## GL-free stand-in (no GL object, every uniform block "exists" at index 0) used by CPU-only
  ## batch tests and oracles. `isValid` is false.
  result = GlProgram()
  for u in GlShaderUniform:
    result.uniformLocations[u] = -1
    result.samplerBindings[u] = -1
  for b in GlShaderUniformBlock:
    result.uniformBlockIndices[b] = 0
    result.uniformBlockBindings[b] = UnknownBinding

proc destroy*(p: GlProgram) =
  ## `~GlProgram`: deletes the GL program (idempotent).
  if p.programObj != 0: deleteProgram(p.programObj)
  p.programObj = 0

func getProgramId*(p: GlProgram): GlId = p.programObj
func programId*(p: GlProgram): GlId = p.programObj
func isValid*(p: GlProgram): bool = p.programObj != 0

proc getUniformLocation*(p: GlProgram, uniform: GlShaderUniform): int32 =
  ## Cached `glGetUniformLocation` (-1 when the program has no such uniform).
  if p.uniformLocations[uniform] != UnknownLocation: return p.uniformLocations[uniform]
  glCheck((p.uniformLocations[uniform] = getUniformLocation(p.programObj,
    UniformNames[uniform])))
  result = p.uniformLocations[uniform]

proc getUniformBlockIndex*(p: GlProgram, blk: GlShaderUniformBlock): int32 =
  ## Cached `glGetUniformBlockIndex` (-1 when the program has no such block).
  if p.uniformBlockIndices[blk] != UnknownLocation: return p.uniformBlockIndices[blk]
  var blockIndex = 0'u32
  glCheck((blockIndex = getUniformBlockIndex(p.programObj, UniformBlockNames[blk])))
  p.uniformBlockIndices[blk] = if blockIndex == GlInvalidIndex: -1 else: int32(blockIndex)
  result = p.uniformBlockIndices[blk]

proc setUniformBlockBinding*(p: GlProgram, blk: GlShaderUniformBlock,
    bindingPoint: uint32): bool =
  ## False when the block does not exist or is already bound to another binding point.
  let blockIndex = p.getUniformBlockIndex(blk)
  if blockIndex < 0: return false
  if p.uniformBlockBindings[blk] != UnknownBinding:
    return p.uniformBlockBindings[blk] == bindingPoint
  if p.programObj != 0:
    glCheck(uniformBlockBinding(p.programObj, uint32(blockIndex), bindingPoint))
  p.uniformBlockBindings[blk] = bindingPoint
  result = true

proc setSampler*(p: GlProgram, uniform: GlShaderUniform, textureUnit: int32) =
  ## `glUniform1iv` of a sampler, skipped when it already holds `textureUnit`.
  ## The program must be in use (as in the C++).
  let location = p.getUniformLocation(uniform)
  if location < 0 or p.samplerBindings[uniform] == textureUnit: return
  glCheck(uniform1i(location, textureUnit))
  p.samplerBindings[uniform] = textureUnit

proc load*(p: GlProgram, c: var GlStateCache) =
  ## Makes the program current through the state cache.
  c.useProgram(p.programObj)

proc unload*(c: var GlStateCache) =
  ## Unbinds the current program through the state cache.
  c.useProgram(0)
