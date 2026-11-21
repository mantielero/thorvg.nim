## GL program table: which (vertex, fragment) sources make each program (pure strings, no GL calls).
##
## Ported from `GlRenderer::initShaders`, `GlRenderer::getBlendProgram` (tvgGlRenderer.cpp),
## the lazily built effect programs of tvgGlEffect.cpp and the source preamble of
## `GlShader::compileShader` (tvgGlShader.cpp, desktop GL branch).
##
## Program indices are those of the C++ `mPrograms` array: `RenderTypes` (0..16), then the custom
## blend shaders at `rtBlend + source * BlendShaderCount + methodIndex`, `RtNone` programs in total.
## The effect programs (not part of `mPrograms` in C++) are numbered after `RtNone` only for
## `programSource(index)` and the dump test.

import ../../core/types
import shader_src

const
  ShaderPreamble* = "#version 330 core\nprecision highp float;\nprecision highp int;\n"
    ## First source string of every shader (GL_TARGET_GL), before the vertex prefix.
  BlendShaderCount* = 13
    ## Custom blend shaders: Normal, Screen, Exclusion and Add are native GL blends.

type
  BlendSource* {.pure.} = enum
    Image
    Scene
    Solid
    LinearGradient
    RadialGradient
    ConicGradient

  RenderTypes* = enum
    ## Same order as the C++ enum `GlRenderer::RenderTypes`.
    rtColor
    rtLinGradient
    rtRadGradient
    rtConGradient
    rtImage
    rtMaskAlpha
    rtMaskAlphaInv
    rtMaskLuma
    rtMaskLumaInv
    rtMaskAdd
    rtMaskSub
    rtMaskIntersect
    rtMaskDifference
    rtMaskLighten
    rtMaskDarken
    rtStencil
    rtBlit
    rtBlend  ## first custom blend program

  EffectProgram* {.pure.} = enum
    GaussianV
    GaussianH
    MotionBlur
    DropShadow
    Fill
    Tint
    Tritone

  ProgramSource* = object
    ## What `new GlProgram(vert, frag, vertPrefix)` receives.
    vert*: string
    frag*: string
    vertPrefix*: string

const
  BlendSourceCount* = ord(BlendSource.ConicGradient) + 1
  RtNone* = ord(rtBlend) + BlendShaderCount * BlendSourceCount
    ## Number of entries of the C++ `mPrograms` array.
  NoProgram* = -1
  BlendFuncs: array[BlendShaderCount, string] = [
    MULTIPLY_BLEND_FRAG, OVERLAY_BLEND_FRAG, DARKEN_BLEND_FRAG, LIGHTEN_BLEND_FRAG,
    COLOR_DODGE_BLEND_FRAG, COLOR_BURN_BLEND_FRAG, HARD_LIGHT_BLEND_FRAG, SOFT_LIGHT_BLEND_FRAG,
    DIFFERENCE_BLEND_FRAG, HUE_BLEND_FRAG, SATURATION_BLEND_FRAG, COLOR_BLEND_FRAG,
    LUMINOSITY_BLEND_FRAG]

func fullVertex*(p: ProgramSource): string =
  ## Text handed to glShaderSource for the vertex shader.
  ShaderPreamble & p.vertPrefix & p.vert

func fullFragment*(p: ProgramSource): string =
  ## Text handed to glShaderSource for the fragment shader (no fragment prefix in C++).
  ShaderPreamble & p.frag

func isNativeBlend*(m: BlendMethod): bool =
  m in {BlendMethod.Normal, BlendMethod.Screen, BlendMethod.Exclusion, BlendMethod.Add}

func blendMethodIndex*(m: BlendMethod): int =
  ## Slot of a custom blend shader (`methodInd` in getBlendProgram). Not for native blends.
  doAssert not m.isNativeBlend and m != BlendMethod.Composition
  ord(m) - 1 - int(m > BlendMethod.Screen) - int(m > BlendMethod.Exclusion)

func blendProgramIndex*(m: BlendMethod, source: BlendSource): int =
  ## Index into the program table of the custom blend program (`shaderInd`).
  ord(rtBlend) + ord(source) * BlendShaderCount + blendMethodIndex(m)

func maskProgram*(m: MaskMethod): int =
  ## Program index for a mask compose (`NoProgram` when C++ leaves the pointer null).
  case m
  of MaskMethod.Alpha: ord(rtMaskAlpha)
  of MaskMethod.InvAlpha: ord(rtMaskAlphaInv)
  of MaskMethod.Luma: ord(rtMaskLuma)
  of MaskMethod.InvLuma: ord(rtMaskLumaInv)
  of MaskMethod.Add: ord(rtMaskAdd)
  of MaskMethod.Subtract: ord(rtMaskSub)
  of MaskMethod.Intersect: ord(rtMaskIntersect)
  of MaskMethod.Difference: ord(rtMaskDifference)
  of MaskMethod.Lighten: ord(rtMaskLighten)
  of MaskMethod.Darken: ord(rtMaskDarken)
  else: NoProgram

func gradientBlock(source: BlendSource): string =
  case source
  of BlendSource.LinearGradient: STR_LINEAR_GRADIENT_BLOCK
  of BlendSource.RadialGradient: STR_RADIAL_GRADIENT_BLOCK
  of BlendSource.ConicGradient: STR_CONIC_GRADIENT_BLOCK
  else: ""

func gradientFunctions(source: BlendSource): string =
  case source
  of BlendSource.LinearGradient: STR_LINEAR_GRADIENT_FUNCTIONS
  of BlendSource.RadialGradient: STR_RADIAL_GRADIENT_FUNCTIONS
  of BlendSource.ConicGradient: STR_CONIC_GRADIENT_FUNCTIONS
  else: ""

func gradientFragment*(source: BlendSource): string =
  ## Fragment of the plain gradient programs (rtLinGradient, rtRadGradient, rtConGradient).
  STR_GRADIENT_FRAG_COMMON_VARIABLES & gradientBlock(source) &
    STR_GRADIENT_FRAG_COMMON_FUNCTIONS & gradientFunctions(source) & STR_GRADIENT_MAIN

func blendFragment*(m: BlendMethod, source: BlendSource): string =
  ## Fragment source of a custom blend program: header, lum/sat helpers, blend function.
  var helpers = ""
  case m
  of BlendMethod.Hue: helpers = BLEND_FRAG_LUM_HELPER & BLEND_FRAG_SAT_HELPER
  of BlendMethod.Saturation, BlendMethod.Color, BlendMethod.Luminosity:
    helpers = BLEND_FRAG_LUM_HELPER
  else: discard
  let blendFunc = BlendFuncs[blendMethodIndex(m)]
  case source
  of BlendSource.Image: BLEND_IMAGE_FRAG_HEADER & helpers & blendFunc
  of BlendSource.Scene: BLEND_SCENE_FRAG_HEADER & helpers & blendFunc
  of BlendSource.Solid: BLEND_SHAPE_SOLID_FRAG_HEADER & helpers & blendFunc
  else:
    STR_GRADIENT_FRAG_COMMON_VARIABLES & gradientBlock(source) &
      STR_GRADIENT_FRAG_COMMON_FUNCTIONS & gradientFunctions(source) &
      BLEND_SHAPE_GRADIENT_FRAG_HEADER & helpers & blendFunc

func blendProgramSource*(m: BlendMethod, source: BlendSource): ProgramSource =
  ## The `(vertShader, fragShader, gradientUniforms)` triple of getBlendProgram.
  result = ProgramSource(frag: blendFragment(m, source))
  case source
  of BlendSource.Image, BlendSource.Scene: result.vert = BLIT_VERT_SHADER
  of BlendSource.Solid: result.vert = COLOR_VERT_SHADER
  else:
    result.vert = STR_GRADIENT_VERT_BODY
    result.vertPrefix = gradientBlock(source)

func fixedProgramSource(t: RenderTypes): ProgramSource =
  case t
  of rtColor: ProgramSource(vert: COLOR_VERT_SHADER, frag: COLOR_FRAG_SHADER)
  of rtLinGradient, rtRadGradient, rtConGradient:
    let source = BlendSource(ord(BlendSource.LinearGradient) + ord(t) - ord(rtLinGradient))
    ProgramSource(vert: STR_GRADIENT_VERT_BODY, frag: gradientFragment(source),
      vertPrefix: gradientBlock(source))
  of rtImage: ProgramSource(vert: IMAGE_VERT_SHADER, frag: IMAGE_FRAG_SHADER)
  of rtMaskAlpha: ProgramSource(vert: MASK_VERT_SHADER, frag: MASK_ALPHA_FRAG_SHADER)
  of rtMaskAlphaInv: ProgramSource(vert: MASK_VERT_SHADER, frag: MASK_INV_ALPHA_FRAG_SHADER)
  of rtMaskLuma: ProgramSource(vert: MASK_VERT_SHADER, frag: MASK_LUMA_FRAG_SHADER)
  of rtMaskLumaInv: ProgramSource(vert: MASK_VERT_SHADER, frag: MASK_INV_LUMA_FRAG_SHADER)
  of rtMaskAdd: ProgramSource(vert: MASK_VERT_SHADER, frag: MASK_ADD_FRAG_SHADER)
  of rtMaskSub: ProgramSource(vert: MASK_VERT_SHADER, frag: MASK_SUB_FRAG_SHADER)
  of rtMaskIntersect: ProgramSource(vert: MASK_VERT_SHADER, frag: MASK_INTERSECT_FRAG_SHADER)
  of rtMaskDifference: ProgramSource(vert: MASK_VERT_SHADER, frag: MASK_DIFF_FRAG_SHADER)
  of rtMaskLighten: ProgramSource(vert: MASK_VERT_SHADER, frag: MASK_LIGHTEN_FRAG_SHADER)
  of rtMaskDarken: ProgramSource(vert: MASK_VERT_SHADER, frag: MASK_DARKEN_FRAG_SHADER)
  of rtStencil: ProgramSource(vert: STENCIL_VERT_SHADER, frag: STENCIL_FRAG_SHADER)
  of rtBlit: ProgramSource(vert: BLIT_VERT_SHADER, frag: BLIT_FRAG_SHADER)
  of rtBlend: ProgramSource()

func initShaderSources*(): seq[ProgramSource] =
  ## The programs `initShaders` builds eagerly, in push order (indices 0 ..< rtBlend).
  result = @[]
  for i in 0 ..< ord(rtBlend): result.add fixedProgramSource(RenderTypes(i))

func effectSource*(e: EffectProgram): ProgramSource =
  ## Programs created on first use by GlEffect (EFFECT_VERTEX + one fragment each).
  let frag = case e
    of EffectProgram.GaussianV: GAUSSIAN_VERTICAL
    of EffectProgram.GaussianH: GAUSSIAN_HORIZONTAL
    of EffectProgram.MotionBlur: EFFECT_MOTIONBLUR
    of EffectProgram.DropShadow: EFFECT_DROPSHADOW
    of EffectProgram.Fill: EFFECT_FILL
    of EffectProgram.Tint: EFFECT_TINT
    of EffectProgram.Tritone: EFFECT_TRITONE
  ProgramSource(vert: EFFECT_VERTEX, frag: frag)

func blendSlot(index: int): (BlendMethod, BlendSource) =
  ## Inverse of blendProgramIndex.
  const Methods = [BlendMethod.Multiply, BlendMethod.Overlay, BlendMethod.Darken,
    BlendMethod.Lighten, BlendMethod.ColorDodge, BlendMethod.ColorBurn, BlendMethod.HardLight,
    BlendMethod.SoftLight, BlendMethod.Difference, BlendMethod.Hue, BlendMethod.Saturation,
    BlendMethod.Color, BlendMethod.Luminosity]
  let slot = index - ord(rtBlend)
  (Methods[slot mod BlendShaderCount], BlendSource(slot div BlendShaderCount))

func programSource*(index: int): ProgramSource =
  ## Sources of program `index`: 0 ..< RtNone as in `mPrograms` (the blend slots are filled
  ## here although C++ builds them lazily), then `RtNone + ord(EffectProgram)`.
  doAssert index in 0 ..< RtNone + ord(EffectProgram.Tritone) + 1
  if index < ord(rtBlend):
    fixedProgramSource(RenderTypes(index))
  elif index < RtNone:
    let (m, s) = blendSlot(index)
    blendProgramSource(m, s)
  else:
    effectSource(EffectProgram(index - RtNone))

func programName*(index: int): string =
  ## Stable debug name, also the key of tests/gl dump_programs.cpp.
  if index < ord(rtBlend): ($RenderTypes(index))[2 .. ^1]
  elif index < RtNone:
    let (m, s) = blendSlot(index)
    "Blend:" & $s & ":" & $m
  else: "Effect" & $EffectProgram(index - RtNone)
