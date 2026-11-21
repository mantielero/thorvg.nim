## GL render targets and their pool (port of tvgGlRenderTarget.cpp/.h).
##
## A target is a multisampled (4x) FBO with RGBA8 and DEPTH24_STENCIL8 renderbuffers, plus a
## single-sample `resolvedFbo` whose attachment is the texture `colorTex` (the resolve blit
## destination that shaders later sample).
##
## The C++ target keeps a `GlStateCache*`; the Nim cache is a move-only object, so every call that
## touches GL state takes `state: var GlStateCache` explicitly (`init`, `reset`,
## `getRenderTarget`, `destroy` of the pool). Dropping a target without `reset` still deletes its
## GL objects (the `=destroy` hook), but then the state cache is not told about it.

import ../../core/[types, geom]
import ./[gl_ffi, state_cache]

const
  MsaaSamples = 4'i32  ## what the C++ uses
  SetupUnit = GlTexture0  ## TVG_GL_TEXTURE_SETUP_UNIT

type
  GlRenderTargetObj* = object
    viewport*: Region
    width*, height*: uint32
    resolvedFbo*, fbo*, colorTex*: GlId
    colorBuffer, depthStencilBuffer: GlId

  GlRenderTarget* = ref GlRenderTargetObj

  GlRenderTargetPool* = ref object
    maxWidth, maxHeight: uint32
    targets*: seq[GlRenderTarget]

proc `=destroy`*(t: GlRenderTargetObj) =
  if t.fbo != 0 and glReady():
    try:
      deleteFramebuffer(t.fbo)
      deleteRenderbuffer(t.colorBuffer)
      deleteRenderbuffer(t.depthStencilBuffer)
      deleteFramebuffer(t.resolvedFbo)
      deleteTexture(t.colorTex)
    except Exception: discard

proc `=copy`*(a: var GlRenderTargetObj, b: GlRenderTargetObj) {.error.}

func invalid*(t: GlRenderTarget): bool = t.fbo == 0

proc newGlRenderTarget*(): GlRenderTarget = GlRenderTarget()

proc init*(t: GlRenderTarget, state: var GlStateCache, width, height: uint32,
    resolveId: GlId) =
  ## Creates the FBOs/attachments and rebinds `resolveId` as the framebuffer (as the C++ does).
  if width == 0 or height == 0: return
  t.width = width
  t.height = height
  let w = int32(width)
  let h = int32(height)

  glCheck((t.fbo = genFramebuffer()))
  state.bindFramebuffer(GlFramebuffer, t.fbo)

  glCheck((t.colorBuffer = genRenderbuffer()))
  glCheck(bindRenderbuffer(GlRenderbuffer, t.colorBuffer))
  glCheck(renderbufferStorageMultisample(GlRenderbuffer, MsaaSamples, GlRgba8, w, h))

  glCheck((t.depthStencilBuffer = genRenderbuffer()))
  glCheck(bindRenderbuffer(GlRenderbuffer, t.depthStencilBuffer))
  glCheck(renderbufferStorageMultisample(GlRenderbuffer, MsaaSamples, GlDepth24Stencil8, w, h))
  glCheck(bindRenderbuffer(GlRenderbuffer, 0))

  glCheck(framebufferRenderbuffer(GlFramebuffer, GlColorAttachment0, GlRenderbuffer,
    t.colorBuffer))
  glCheck(framebufferRenderbuffer(GlFramebuffer, GlDepthStencilAttachment, GlRenderbuffer,
    t.depthStencilBuffer))

  # resolve target
  glCheck((t.colorTex = genTexture()))
  state.bindTexture2D(SetupUnit, t.colorTex)
  glCheck(texImage2DEmpty(GlTexture2D, 0, int32(GlRgba8), w, h, GlRgba, GlUnsignedByte))
  glCheck(texParameteri(GlTexture2D, GlTextureWrapS, int32(GlClampToEdge)))
  glCheck(texParameteri(GlTexture2D, GlTextureWrapT, int32(GlClampToEdge)))
  glCheck(texParameteri(GlTexture2D, GlTextureMinFilter, int32(GlLinear)))
  glCheck(texParameteri(GlTexture2D, GlTextureMagFilter, int32(GlLinear)))
  state.bindTexture2D(SetupUnit, 0)

  glCheck((t.resolvedFbo = genFramebuffer()))
  state.bindFramebuffer(GlFramebuffer, t.resolvedFbo)
  glCheck(framebufferTexture2D(GlFramebuffer, GlColorAttachment0, GlTexture2D, t.colorTex, 0))

  state.bindFramebuffer(GlFramebuffer, resolveId)

proc reset*(t: GlRenderTarget, state: var GlStateCache) =
  ## Deletes the GL objects (idempotent); leaves framebuffer 0 bound.
  if t.fbo == 0: return
  state.bindFramebuffer(GlFramebuffer, 0)
  glCheck(deleteFramebuffer(t.fbo))
  glCheck(deleteRenderbuffer(t.colorBuffer))
  glCheck(deleteRenderbuffer(t.depthStencilBuffer))
  glCheck(deleteFramebuffer(t.resolvedFbo))
  glCheck(deleteTexture(t.colorTex))
  t.fbo = 0
  t.colorBuffer = 0
  t.depthStencilBuffer = 0
  t.resolvedFbo = 0
  t.colorTex = 0

# ---------------------------------------------------------------- pool

proc newGlRenderTargetPool*(maxWidth, maxHeight: uint32): GlRenderTargetPool =
  GlRenderTargetPool(maxWidth: maxWidth, maxHeight: maxHeight)

proc destroy*(pool: GlRenderTargetPool, state: var GlStateCache) =
  ## `~GlRenderTargetPool`: resets and drops every pooled target.
  for t in pool.targets: t.reset(state)
  pool.targets.setLen(0)

func alignPow2*(value: uint32): uint32 =
  ## Smallest power of two >= `value` (1 for 0).
  result = 1
  while result < value: result = result shl 1

func fitSize(value, maxValue: uint32): uint32 =
  if value >= maxValue: maxValue else: min(alignPow2(value), maxValue)

proc getRenderTarget*(pool: GlRenderTargetPool, state: var GlStateCache, vp: Region,
    resolveId: GlId = 0): GlRenderTarget =
  ## The pooled target whose pow2-aligned (clamped to the max size) dimensions fit `vp`; it is
  ## created on first use. The same target object is returned for every request of that size.
  let width = fitSize(uint32(max(vp.sw, 0)), pool.maxWidth)
  let height = fitSize(uint32(max(vp.sh, 0)), pool.maxHeight)

  for t in pool.targets:
    if t.width == width and t.height == height:
      t.viewport = vp
      return t

  result = newGlRenderTarget()
  result.init(state, width, height, resolveId)
  result.viewport = vp
  pool.targets.add result
