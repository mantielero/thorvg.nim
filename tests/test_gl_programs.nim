import std/[unittest, os, strutils]
import thorvg/core/types
import thorvg/engine/gl/[shader_src, programs]

const
  Root = currentSourcePath().parentDir().parentDir()
  DumpFile = Root / "migration" / "gl" / "programs_dump.txt"
  ShaderDir = Root / "migration" / "gl" / "shaders"

type Dumped = tuple[index: int, name, vert, frag: string]

template e(x: untyped): untyped = (astToStr(x), x)

proc parseDump(path: string): seq[Dumped] =
  ## Records: "@@ <index> <name> <vertLen> <fragLen>\n" vertex fragment "\n".
  let data = readFile(path)
  var pos = 0
  while pos < data.len:
    let eol = data.find('\n', pos)
    let head = data[pos ..< eol].split(' ')
    doAssert head.len == 5 and head[0] == "@@"
    let vl = parseInt(head[3])
    let fl = parseInt(head[4])
    let start = eol + 1
    result.add (parseInt(head[1]), head[2], data[start ..< start + vl],
      data[start + vl ..< start + vl + fl])
    doAssert data[start + vl + fl] == '\n'
    pos = start + vl + fl + 1

suite "gl shader sources":
  test "56 shader constants equal the extracted C++ strings (staticRead path works)":
    let all = [
    e(BLEND_FRAG_LUM_HELPER),
    e(BLEND_FRAG_SAT_HELPER),
    e(BLEND_IMAGE_FRAG_HEADER),
    e(BLEND_SCENE_FRAG_HEADER),
    e(BLEND_SHAPE_GRADIENT_FRAG_HEADER),
    e(BLEND_SHAPE_SOLID_FRAG_HEADER),
    e(BLIT_FRAG_SHADER),
    e(BLIT_VERT_SHADER),
    e(COLOR_BLEND_FRAG),
    e(COLOR_BURN_BLEND_FRAG),
    e(COLOR_DODGE_BLEND_FRAG),
    e(COLOR_FRAG_SHADER),
    e(COLOR_VERT_SHADER),
    e(DARKEN_BLEND_FRAG),
    e(DIFFERENCE_BLEND_FRAG),
    e(EFFECT_DROPSHADOW),
    e(EFFECT_FILL),
    e(EFFECT_MOTIONBLUR),
    e(EFFECT_TINT),
    e(EFFECT_TRITONE),
    e(EFFECT_VERTEX),
    e(GAUSSIAN_HORIZONTAL),
    e(GAUSSIAN_VERTICAL),
    e(HARD_LIGHT_BLEND_FRAG),
    e(HUE_BLEND_FRAG),
    e(IMAGE_FRAG_SHADER),
    e(IMAGE_VERT_SHADER),
    e(LIGHTEN_BLEND_FRAG),
    e(LUMINOSITY_BLEND_FRAG),
    e(MASK_ADD_FRAG_SHADER),
    e(MASK_ALPHA_FRAG_SHADER),
    e(MASK_DARKEN_FRAG_SHADER),
    e(MASK_DIFF_FRAG_SHADER),
    e(MASK_INTERSECT_FRAG_SHADER),
    e(MASK_INV_ALPHA_FRAG_SHADER),
    e(MASK_INV_LUMA_FRAG_SHADER),
    e(MASK_LIGHTEN_FRAG_SHADER),
    e(MASK_LUMA_FRAG_SHADER),
    e(MASK_SUB_FRAG_SHADER),
    e(MASK_VERT_SHADER),
    e(MULTIPLY_BLEND_FRAG),
    e(OVERLAY_BLEND_FRAG),
    e(SATURATION_BLEND_FRAG),
    e(SOFT_LIGHT_BLEND_FRAG),
    e(STENCIL_FRAG_SHADER),
    e(STENCIL_VERT_SHADER),
    e(STR_CONIC_GRADIENT_BLOCK),
    e(STR_CONIC_GRADIENT_FUNCTIONS),
    e(STR_GRADIENT_FRAG_COMMON_FUNCTIONS),
    e(STR_GRADIENT_FRAG_COMMON_VARIABLES),
    e(STR_GRADIENT_MAIN),
    e(STR_GRADIENT_VERT_BODY),
    e(STR_LINEAR_GRADIENT_BLOCK),
    e(STR_LINEAR_GRADIENT_FUNCTIONS),
    e(STR_RADIAL_GRADIENT_BLOCK),
    e(STR_RADIAL_GRADIENT_FUNCTIONS)
    ]
    check all.len == 56
    for (name, text) in all:
      check text == readFile(ShaderDir / name & ".glsl")
      check text.len > 0

  test "preamble is the desktop GL one":
    check ShaderPreamble == "#version 330 core\nprecision highp float;\nprecision highp int;\n"

suite "gl programs":
  test "table sizes and indices follow RenderTypes":
    check ord(rtBlit) == 16
    check ord(rtBlend) == 17
    check RtNone == 17 + 13 * 6
    check initShaderSources().len == 17
    check blendProgramIndex(BlendMethod.Multiply, BlendSource.Image) == 17
    check blendProgramIndex(BlendMethod.Luminosity, BlendSource.ConicGradient) == RtNone - 1

  test "blend method slots (native blends have none)":
    for m in [BlendMethod.Normal, BlendMethod.Screen, BlendMethod.Exclusion, BlendMethod.Add]:
      check m.isNativeBlend
    var seen: seq[int]
    for m in [BlendMethod.Multiply, BlendMethod.Screen, BlendMethod.Overlay, BlendMethod.Darken,
        BlendMethod.Lighten, BlendMethod.ColorDodge, BlendMethod.ColorBurn,
        BlendMethod.HardLight, BlendMethod.SoftLight, BlendMethod.Difference,
        BlendMethod.Exclusion, BlendMethod.Hue, BlendMethod.Saturation, BlendMethod.Color,
        BlendMethod.Luminosity, BlendMethod.Add]:
      if not m.isNativeBlend: seen.add blendMethodIndex(m)
    check seen == @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    check blendMethodIndex(BlendMethod.Overlay) == 1
    check blendMethodIndex(BlendMethod.Hue) == 9

  test "mask methods map to the mask programs":
    check maskProgram(MaskMethod.None) == NoProgram
    check maskProgram(MaskMethod.Alpha) == ord(rtMaskAlpha)
    check maskProgram(MaskMethod.Darken) == ord(rtMaskDarken)
    check maskProgram(MaskMethod.Subtract) == ord(rtMaskSub)

  test "every program equals the C++ assembled text":
    let dump = parseDump(DumpFile)
    check dump.len == RtNone + 7
    for d in dump:
      let p = programSource(d.index)
      check programName(d.index) == d.name
      check p.fullVertex == d.vert
      check p.fullFragment == d.frag
      check d.vert.startsWith(ShaderPreamble)
      check d.frag.startsWith(ShaderPreamble)

  test "gradient programs carry their uniform block in the vertex prefix":
    check programSource(ord(rtLinGradient)).vertPrefix == STR_LINEAR_GRADIENT_BLOCK
    check programSource(ord(rtColor)).vertPrefix == ""
    check blendProgramSource(BlendMethod.Hue, BlendSource.RadialGradient).vertPrefix ==
      STR_RADIAL_GRADIENT_BLOCK
    check blendProgramSource(BlendMethod.Hue, BlendSource.Solid).vertPrefix == ""
