## GL texture cache for image surfaces (port of tvgGlTextureMgr.cpp/.h).
##
## `retain` / `release` reference-count one texture per (surface, filter); the cache key is the
## identity of the `RenderSurface` ref (`std/hashes`), the C++ `const RenderSurface*`. When the last
## reference of a surface is released its entry disappears and `release` returns the texture id,
## which the caller deletes (C++ `GlRenderer::disposeTexture`).
##
## Uploaded pixels are raw; a pending "preprocess" request per texture makes `flushPreprocess`
## swizzle ARGB -> ABGR and premultiply on the GPU with a tiny full-screen-triangle program,
## exactly like the C++. Call `flushPreprocess` before the textures are sampled.

import ../../core/types
import ../../renderer/render
import ./[gl_ffi, program, state_cache]

const
  PrepPremultiply* = 1'i32
  PrepBgr* = 2'i32
  SetupUnit = GlTexture0  ## TVG_GL_TEXTURE_SETUP_UNIT

  PreprocessVertShader = "void main(){vec2 p=vec2(gl_VertexID==2?3.0:-1.0,gl_VertexID==1?" &
    "3.0:-1.0);gl_Position=vec4(p,0.0,1.0);}"
  PreprocessFragShader = "uniform sampler2D uTexture;uniform int uFlags;out vec4 FragColor;" &
    "void main(){vec4 c=texelFetch(uTexture,ivec2(gl_FragCoord.xy),0);if((uFlags&2)!=0)" &
    "c=c.bgra;if((uFlags&1)!=0)c.rgb*=c.a;FragColor=c;}"

type
  TexEntry* = object
    texId*: GlId
    refCnt*: uint32

  SurfaceEntry* = object
    surface*: RenderSurface  ## compared by identity
    entries*: array[FilterMethod, TexEntry]

  PreprocessRequest* = object
    texId*: GlId
    width*, height*: uint32
    flags*: int32

  TextureMgr* = object
    surfaces*: seq[SurfaceEntry]  ## cached textures, found by surface identity (linear, as C++)
    stamp*: uint16 = 1  ## non-zero rolling stamp for stale texture ownership checks
    prepFlagsLoc: int32 = -1
    prepProgram: GlProgram
    prepStagingFbo, prepTargetFbo, prepStagingTex, prepVao: GlId
    prepStagingWidth, prepStagingHeight: uint32
    prepRequests*: seq[PreprocessRequest]

proc `=copy`*(a: var TextureMgr, b: TextureMgr) {.error.}

proc initTextureMgr*(): TextureMgr = TextureMgr()

func surfaceCount*(tm: TextureMgr): int = tm.surfaces.len

func find*(tm: TextureMgr, surface: RenderSurface): int =
  ## Index in `tm.surfaces` of the entry of `surface`, -1 when it has none.
  for i in 0 ..< tm.surfaces.len:
    if tm.surfaces[i].surface == surface: return i
  result = -1

func texId*(tm: TextureMgr, surface: RenderSurface, filter: FilterMethod): GlId =
  ## Cached texture of (surface, filter); 0 when absent.
  let i = tm.find(surface)
  if i >= 0: tm.surfaces[i].entries[filter].texId else: 0

func refCount*(tm: TextureMgr, surface: RenderSurface, filter: FilterMethod): uint32 =
  let i = tm.find(surface)
  if i >= 0: tm.surfaces[i].entries[filter].refCnt else: 0

proc requestPreprocess*(tm: var TextureMgr, texId: GlId, width, height: uint32, flags: int32) =
  ## Queues (or replaces) the preprocess of `texId`; no flags/size cancels a queued one.
  if texId == 0: return
  let wanted = flags != 0 and width > 0 and height > 0
  for i in 0 ..< tm.prepRequests.len:
    if tm.prepRequests[i].texId == texId:
      if wanted:
        tm.prepRequests[i] = PreprocessRequest(texId: texId, width: width, height: height,
          flags: flags)
      else:
        tm.prepRequests[i] = tm.prepRequests[^1]
        tm.prepRequests.setLen(tm.prepRequests.len - 1)
      return
  if wanted:
    tm.prepRequests.add PreprocessRequest(texId: texId, width: width, height: height,
      flags: flags)

proc flushPreprocess*(tm: var TextureMgr, state: var GlStateCache, restoreFbo: GlId): bool =
  ## Runs the queued swizzle/premultiply passes and restores `restoreFbo`.
  if tm.prepRequests.len == 0: return true

  if tm.prepProgram == nil:
    tm.prepProgram = newGlProgram(PreprocessVertShader, PreprocessFragShader)
    glCheck((tm.prepFlagsLoc = getUniformLocation(tm.prepProgram.getProgramId(), "uFlags")))
  if tm.prepStagingFbo == 0: glCheck((tm.prepStagingFbo = genFramebuffer()))
  if tm.prepTargetFbo == 0: glCheck((tm.prepTargetFbo = genFramebuffer()))
  if tm.prepVao == 0: glCheck((tm.prepVao = genVertexArray()))
  if tm.prepStagingTex == 0: glCheck((tm.prepStagingTex = genTexture()))
  if not tm.prepProgram.isValid or tm.prepStagingFbo == 0 or tm.prepTargetFbo == 0 or
      tm.prepVao == 0 or tm.prepStagingTex == 0:
    return false

  state.bindFramebuffer(GlFramebuffer, tm.prepStagingFbo)
  state.colorMask(true, true, true, true)
  state.disable(GlBlend)
  state.disable(GlCullFace)
  state.disable(GlDither)
  state.disable(GlRasterizerDiscard)
  state.disable(GlScissorTest)
  state.disable(GlColorLogicOp)  # THORVG_GL_TARGET_GL

  state.useProgram(tm.prepProgram.getProgramId())
  tm.prepProgram.setSampler(GlShaderUniform.Texture, 0)
  state.bindVertexArray(tm.prepVao)

  var currentFlags = 0'i32
  for request in tm.prepRequests:
    let w = int32(request.width)
    let h = int32(request.height)
    if request.width > tm.prepStagingWidth or request.height > tm.prepStagingHeight:
      let attach = tm.prepStagingWidth == 0
      state.bindTexture2D(SetupUnit, tm.prepStagingTex)
      # Only a non-layered level-0 FBO attachment that is never sampled: sampling parameters
      # and mipmap completeness do not affect framebuffer completeness.
      glCheck(texImage2DEmpty(GlTexture2D, 0, int32(GlRgba8), w, h, GlRgba, GlUnsignedByte))
      tm.prepStagingWidth = request.width
      tm.prepStagingHeight = request.height
      if attach:
        glCheck(framebufferTexture2D(GlFramebuffer, GlColorAttachment0, GlTexture2D,
          tm.prepStagingTex, 0))
    state.bindFramebuffer(GlDrawFramebuffer, tm.prepStagingFbo)
    state.viewport(0, 0, w, h)
    state.bindTexture2D(SetupUnit, request.texId)
    if currentFlags != request.flags:
      currentFlags = request.flags
      glCheck(uniform1i(tm.prepFlagsLoc, currentFlags))
    glCheck(drawArrays(GlTriangles, 0, 3))

    state.bindFramebuffer(GlDrawFramebuffer, tm.prepTargetFbo)
    glCheck(framebufferTexture2D(GlDrawFramebuffer, GlColorAttachment0, GlTexture2D,
      request.texId, 0))
    glCheck(blitFramebuffer(0, 0, w, h, 0, 0, w, h, GlColorBufferBit, GlNearest))
  tm.prepRequests.setLen(0)

  glCheck(framebufferTexture2D(GlDrawFramebuffer, GlColorAttachment0, GlTexture2D, 0, 0))
  state.bindTexture2D(SetupUnit, 0)
  state.bindVertexArray(0)
  state.bindFramebuffer(GlFramebuffer, restoreFbo)
  state.enable(GlDither)
  result = true

proc prepFlags(surface: RenderSurface): int32 =
  ## GPU fix-ups the raw upload needs: ARGB -> ABGR swizzle and premultiplication.
  result = 0
  if surface.channelSize == 4:
    var supported = true
    if surface.cs == ColorSpace.ARGB8888 or surface.cs == ColorSpace.ARGB8888S:
      result = result or PrepBgr
    elif surface.cs != ColorSpace.ABGR8888 and surface.cs != ColorSpace.ABGR8888S:
      supported = false
    if supported and not surface.premultiplied: result = result or PrepPremultiply

proc upload*(tm: var TextureMgr, state: var GlStateCache, texId: GlId, surface: RenderSurface,
    filter: FilterMethod, initialize = false) =
  ## (Re)uploads the surface pixels into `texId`; `initialize` also sets wrap/filter parameters.
  let flags = prepFlags(surface)
  let w = int32(surface.w)
  let h = int32(surface.h)
  state.bindTexture2D(SetupUnit, texId)
  if surface.data.len >= int(w) * int(h):
    glCheck(texImage2D(GlTexture2D, 0, int32(GlRgba8), w, h, GlRgba, GlUnsignedByte,
      surface.data))
  else:  # no 32-bit pixels (grayscale surface): allocate only, never read past the data
    glCheck(texImage2DEmpty(GlTexture2D, 0, int32(GlRgba8), w, h, GlRgba, GlUnsignedByte))
  if initialize:
    let mode = int32(if filter == FilterMethod.Bilinear: GlLinear else: GlNearest)
    glCheck(texParameteri(GlTexture2D, GlTextureWrapS, int32(GlClampToEdge)))
    glCheck(texParameteri(GlTexture2D, GlTextureWrapT, int32(GlClampToEdge)))
    glCheck(texParameteri(GlTexture2D, GlTextureMinFilter, mode))
    glCheck(texParameteri(GlTexture2D, GlTextureMagFilter, mode))
  state.bindTexture2D(SetupUnit, 0)
  tm.requestPreprocess(texId, surface.w, surface.h, flags)

proc retain*(tm: var TextureMgr, state: var GlStateCache, surface: RenderSurface,
    filter: FilterMethod): GlId =
  ## Texture of (surface, filter): the cached one (+1 reference) or a new uploaded one.
  var i = tm.find(surface)
  if i < 0:
    tm.surfaces.add SurfaceEntry(surface: surface)
    i = tm.surfaces.high
  if tm.surfaces[i].entries[filter].texId != 0:
    inc tm.surfaces[i].entries[filter].refCnt
    return tm.surfaces[i].entries[filter].texId

  var id = 0'u32
  glCheck((id = genTexture()))
  tm.upload(state, id, surface, filter, true)
  tm.surfaces[i].entries[filter] = TexEntry(texId: id, refCnt: 1)
  result = id

proc release*(tm: var TextureMgr, surface: RenderSurface, filter: FilterMethod,
    texId: GlId): GlId =
  ## Drops one reference. Returns the texture id once the last one is gone (the caller deletes
  ## the GL texture), else 0. The surface entry vanishes with its last texture.
  let i = tm.find(surface)
  if i < 0: return 0
  if tm.surfaces[i].entries[filter].texId != texId: return 0

  if tm.surfaces[i].entries[filter].refCnt > 0:
    dec tm.surfaces[i].entries[filter].refCnt
  if tm.surfaces[i].entries[filter].refCnt > 0: return 0

  tm.surfaces[i].entries[filter] = TexEntry()
  tm.requestPreprocess(texId, 0, 0, 0)
  let entry = tm.surfaces[i]
  if entry.entries[FilterMethod.Bilinear].texId == 0 and
      entry.entries[FilterMethod.Nearest].texId == 0:
    tm.surfaces.delete(i)
  result = texId

proc clear*(tm: var TextureMgr) =
  ## Deletes every cached texture and the preprocess resources; bumps the stamp so that owners
  ## (`GlImage.stamp`) notice their texture ids are stale.
  var textures: seq[GlId]
  for entry in tm.surfaces:
    for e in entry.entries:
      if e.texId != 0: textures.add e.texId
  tm.surfaces.setLen(0)
  tm.prepRequests.setLen(0)
  if tm.prepProgram != nil:
    tm.prepProgram.destroy()
    tm.prepProgram = nil
  if tm.prepStagingFbo != 0: glCheck(deleteFramebuffer(tm.prepStagingFbo))
  if tm.prepTargetFbo != 0: glCheck(deleteFramebuffer(tm.prepTargetFbo))
  if tm.prepStagingTex != 0: glCheck(deleteTexture(tm.prepStagingTex))
  if tm.prepVao != 0: glCheck(deleteVertexArray(tm.prepVao))
  tm.prepStagingFbo = 0
  tm.prepTargetFbo = 0
  tm.prepStagingTex = 0
  tm.prepVao = 0
  tm.prepStagingWidth = 0
  tm.prepStagingHeight = 0
  tm.prepFlagsLoc = -1
  tm.stamp = if tm.stamp == high(uint16): 1'u16 else: tm.stamp + 1  # 0 means stale
  if textures.len > 0: glCheck(deleteTextures(textures))
