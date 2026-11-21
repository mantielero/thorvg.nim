// Dumps the FINAL (vertex, fragment) source text of every GL program, as tvgGlShader.cpp would hand it to glShaderSource.
//
// initShaders() and getBlendProgram() of tvgGlRenderer.cpp need a GL context only inside `new GlProgram(...)`, so their
// string assembly is replicated here statement by statement (same snprintf calls, same buffer sizes) and `emit()`
// stands in for GlProgram/GlShader: vertex = preamble + vertPrefix + vertSrc, fragment = preamble + "" + fragSrc.
// Effect programs (tvgGlEffect.cpp) are plain (EFFECT_VERTEX, X) pairs.
//
// Build: g++ -std=c++14 -DTHORVG_GL_TARGET_GL=1 -Iupstream/thorvg/inc tests/gl/dump_programs.cpp
//            build/cppgl/obj/src/renderer/gpu_engine/gl/tvgGlShaderSrc.o -o build/gl/dump_programs.exe
// Run:   build\gl\dump_programs.exe migration\gl\programs_dump.txt
// Record: "@@ <index> <name> <vertLen> <fragLen>\n" + vertex bytes + fragment bytes + "\n"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <thorvg.h>
#include "../../upstream/thorvg/src/renderer/gpu_engine/gl/tvgGlShaderSrc.h"

using tvg::BlendMethod;

enum class BlendSource { Image, Scene, Solid, LinearGradient, RadialGradient, ConicGradient, Count };
static constexpr uint32_t BlendShaderCount = 13;

static FILE* out = nullptr;
static int emitted = 0;
static int truncated = 0;

static const char* PREAMBLE =
#if defined(THORVG_GL_TARGET_GLES)
    "#version 300 es\n"
#else
    "#version 330 core\n"
#endif
    "precision highp float;\nprecision highp int;\n";

static void emit(const std::string& name, const char* vertSrc, const char* fragSrc, const char* vertPrefix = "")
{
    // GlShader::compileShader: sources = {preamble, prefix, source}
    std::string v = std::string(PREAMBLE) + vertPrefix + vertSrc;
    std::string f = std::string(PREAMBLE) + "" + fragSrc;
    fprintf(out, "@@ %d %s %u %u\n", emitted++, name.c_str(), (unsigned) v.size(), (unsigned) f.size());
    fwrite(v.data(), 1, v.size(), out);
    fwrite(f.data(), 1, f.size(), out);
    fputs("\n", out);
}

// snprintf with the C++ buffer size; reports when the C++ code truncates
static void checkTrunc(const char* what, size_t need, size_t cap)
{
    if (need >= cap) { fprintf(stderr, "TRUNCATION in %s: need %zu, buffer %zu\n", what, need, cap); ++truncated; }
}

static void initShaders()
{
    #define LINEAR_TOTAL_LENGTH 2820
    #define RADIAL_TOTAL_LENGTH 5301
    #define CONIC_TOTAL_LENGTH 3069

    char linearGradientFragShader[LINEAR_TOTAL_LENGTH];
    checkTrunc("linear", snprintf(linearGradientFragShader, LINEAR_TOTAL_LENGTH, "%s%s%s%s%s",
        STR_GRADIENT_FRAG_COMMON_VARIABLES, STR_LINEAR_GRADIENT_BLOCK, STR_GRADIENT_FRAG_COMMON_FUNCTIONS,
        STR_LINEAR_GRADIENT_FUNCTIONS, STR_GRADIENT_MAIN), LINEAR_TOTAL_LENGTH);

    char radialGradientFragShader[RADIAL_TOTAL_LENGTH];
    checkTrunc("radial", snprintf(radialGradientFragShader, RADIAL_TOTAL_LENGTH, "%s%s%s%s%s",
        STR_GRADIENT_FRAG_COMMON_VARIABLES, STR_RADIAL_GRADIENT_BLOCK, STR_GRADIENT_FRAG_COMMON_FUNCTIONS,
        STR_RADIAL_GRADIENT_FUNCTIONS, STR_GRADIENT_MAIN), RADIAL_TOTAL_LENGTH);

    char conicGradientFragShader[CONIC_TOTAL_LENGTH];
    checkTrunc("conic", snprintf(conicGradientFragShader, CONIC_TOTAL_LENGTH, "%s%s%s%s%s",
        STR_GRADIENT_FRAG_COMMON_VARIABLES, STR_CONIC_GRADIENT_BLOCK, STR_GRADIENT_FRAG_COMMON_FUNCTIONS,
        STR_CONIC_GRADIENT_FUNCTIONS, STR_GRADIENT_MAIN), CONIC_TOTAL_LENGTH);

    emit("Color", COLOR_VERT_SHADER, COLOR_FRAG_SHADER);
    emit("LinGradient", STR_GRADIENT_VERT_BODY, linearGradientFragShader, STR_LINEAR_GRADIENT_BLOCK);
    emit("RadGradient", STR_GRADIENT_VERT_BODY, radialGradientFragShader, STR_RADIAL_GRADIENT_BLOCK);
    emit("ConGradient", STR_GRADIENT_VERT_BODY, conicGradientFragShader, STR_CONIC_GRADIENT_BLOCK);
    emit("Image", IMAGE_VERT_SHADER, IMAGE_FRAG_SHADER);
    emit("MaskAlpha", MASK_VERT_SHADER, MASK_ALPHA_FRAG_SHADER);
    emit("MaskAlphaInv", MASK_VERT_SHADER, MASK_INV_ALPHA_FRAG_SHADER);
    emit("MaskLuma", MASK_VERT_SHADER, MASK_LUMA_FRAG_SHADER);
    emit("MaskLumaInv", MASK_VERT_SHADER, MASK_INV_LUMA_FRAG_SHADER);
    emit("MaskAdd", MASK_VERT_SHADER, MASK_ADD_FRAG_SHADER);
    emit("MaskSub", MASK_VERT_SHADER, MASK_SUB_FRAG_SHADER);
    emit("MaskIntersect", MASK_VERT_SHADER, MASK_INTERSECT_FRAG_SHADER);
    emit("MaskDifference", MASK_VERT_SHADER, MASK_DIFF_FRAG_SHADER);
    emit("MaskLighten", MASK_VERT_SHADER, MASK_LIGHTEN_FRAG_SHADER);
    emit("MaskDarken", MASK_VERT_SHADER, MASK_DARKEN_FRAG_SHADER);
    emit("Stencil", STENCIL_VERT_SHADER, STENCIL_FRAG_SHADER);
    emit("Blit", BLIT_VERT_SHADER, BLIT_FRAG_SHADER);
}

static const char* SOURCE_NAMES[] = {"Image", "Scene", "Solid", "LinearGradient", "RadialGradient", "ConicGradient"};
static const char* METHOD_NAMES[BlendShaderCount] = {"Multiply", "Overlay", "Darken", "Lighten", "ColorDodge",
    "ColorBurn", "HardLight", "SoftLight", "Difference", "Hue", "Saturation", "Color", "Luminosity"};

// getBlendProgram without the program cache and with emit() instead of `new GlProgram`
static void getBlendProgram(BlendMethod method, BlendSource source)
{
    #define BLEND_TOTAL_LENGTH 7567
    static const char* shaderFunc[BlendShaderCount] {
        MULTIPLY_BLEND_FRAG, OVERLAY_BLEND_FRAG, DARKEN_BLEND_FRAG, LIGHTEN_BLEND_FRAG, COLOR_DODGE_BLEND_FRAG,
        COLOR_BURN_BLEND_FRAG, HARD_LIGHT_BLEND_FRAG, SOFT_LIGHT_BLEND_FRAG, DIFFERENCE_BLEND_FRAG, HUE_BLEND_FRAG,
        SATURATION_BLEND_FRAG, COLOR_BLEND_FRAG, LUMINOSITY_BLEND_FRAG
    };

    uint32_t methodInd = (uint32_t)method - 1 - (method > BlendMethod::Screen) - (method > BlendMethod::Exclusion);
    std::string name = std::string("Blend:") + SOURCE_NAMES[(int) source] + ":" + METHOD_NAMES[methodInd];

    const char* lumHelper = "";
    const char* satHelper = "";
    if (method == BlendMethod::Hue) {
        lumHelper = BLEND_FRAG_LUM_HELPER;
        satHelper = BLEND_FRAG_SAT_HELPER;
    } else if ((method == BlendMethod::Saturation) || (method == BlendMethod::Color) || (method == BlendMethod::Luminosity)) {
        lumHelper = BLEND_FRAG_LUM_HELPER;
    }

    const char* vertShader;
    char fragShader[BLEND_TOTAL_LENGTH];

    if (source == BlendSource::Scene || source == BlendSource::Image) {
        vertShader = BLIT_VERT_SHADER;
        const char* header = (source == BlendSource::Scene) ? BLEND_SCENE_FRAG_HEADER : BLEND_IMAGE_FRAG_HEADER;
        checkTrunc(name.c_str(), snprintf(fragShader, BLEND_TOTAL_LENGTH, "%s%s%s%s", header, lumHelper, satHelper,
            shaderFunc[methodInd]), BLEND_TOTAL_LENGTH);
        emit(name, vertShader, fragShader);
        return;
    }

    vertShader = COLOR_VERT_SHADER;
    const char* gradientUniforms = "";
    switch (source) {
        case BlendSource::Solid:
            checkTrunc(name.c_str(), snprintf(fragShader, BLEND_TOTAL_LENGTH, "%s%s%s%s",
                BLEND_SHAPE_SOLID_FRAG_HEADER, lumHelper, satHelper, shaderFunc[methodInd]), BLEND_TOTAL_LENGTH);
            break;
        case BlendSource::LinearGradient:
            vertShader = STR_GRADIENT_VERT_BODY;
            gradientUniforms = STR_LINEAR_GRADIENT_BLOCK;
            checkTrunc(name.c_str(), snprintf(fragShader, BLEND_TOTAL_LENGTH, "%s%s%s%s%s%s%s%s",
                STR_GRADIENT_FRAG_COMMON_VARIABLES, gradientUniforms, STR_GRADIENT_FRAG_COMMON_FUNCTIONS,
                STR_LINEAR_GRADIENT_FUNCTIONS, BLEND_SHAPE_GRADIENT_FRAG_HEADER, lumHelper, satHelper,
                shaderFunc[methodInd]), BLEND_TOTAL_LENGTH);
            break;
        case BlendSource::RadialGradient:
            vertShader = STR_GRADIENT_VERT_BODY;
            gradientUniforms = STR_RADIAL_GRADIENT_BLOCK;
            checkTrunc(name.c_str(), snprintf(fragShader, BLEND_TOTAL_LENGTH, "%s%s%s%s%s%s%s%s",
                STR_GRADIENT_FRAG_COMMON_VARIABLES, gradientUniforms, STR_GRADIENT_FRAG_COMMON_FUNCTIONS,
                STR_RADIAL_GRADIENT_FUNCTIONS, BLEND_SHAPE_GRADIENT_FRAG_HEADER, lumHelper, satHelper,
                shaderFunc[methodInd]), BLEND_TOTAL_LENGTH);
            break;
        case BlendSource::ConicGradient:
            vertShader = STR_GRADIENT_VERT_BODY;
            gradientUniforms = STR_CONIC_GRADIENT_BLOCK;
            checkTrunc(name.c_str(), snprintf(fragShader, BLEND_TOTAL_LENGTH, "%s%s%s%s%s%s%s%s",
                STR_GRADIENT_FRAG_COMMON_VARIABLES, gradientUniforms, STR_GRADIENT_FRAG_COMMON_FUNCTIONS,
                STR_CONIC_GRADIENT_FUNCTIONS, BLEND_SHAPE_GRADIENT_FRAG_HEADER, lumHelper, satHelper,
                shaderFunc[methodInd]), BLEND_TOTAL_LENGTH);
            break;
        default:
            break;
    }
    emit(name, vertShader, fragShader, gradientUniforms);
}

int main(int argc, char** argv)
{
    if (argc < 2) return 2;
    out = fopen(argv[1], "wb");
    if (!out) { fprintf(stderr, "cannot write %s\n", argv[1]); return 2; }

    initShaders();

    // RT_Blend + source * BlendShaderCount + methodInd: sources outermost, methods in shaderFunc order.
    for (int s = 0; s < (int) BlendSource::Count; ++s) {
        for (int m = 0; m <= (int) BlendMethod::Add; ++m) {
            auto method = (BlendMethod) m;
            // native blends (Normal, Screen, Exclusion, Add) have no custom shader slot
            if (method == BlendMethod::Normal || method == BlendMethod::Screen || method == BlendMethod::Exclusion ||
                method == BlendMethod::Add) continue;
            getBlendProgram(method, (BlendSource) s);
        }
    }

    // tvgGlEffect.cpp: lazily created, one (EFFECT_VERTEX, X) pair each
    emit("EffectGaussianV", EFFECT_VERTEX, GAUSSIAN_VERTICAL);
    emit("EffectGaussianH", EFFECT_VERTEX, GAUSSIAN_HORIZONTAL);
    emit("EffectMotionBlur", EFFECT_VERTEX, EFFECT_MOTIONBLUR);
    emit("EffectDropShadow", EFFECT_VERTEX, EFFECT_DROPSHADOW);
    emit("EffectFill", EFFECT_VERTEX, EFFECT_FILL);
    emit("EffectTint", EFFECT_VERTEX, EFFECT_TINT);
    emit("EffectTritone", EFFECT_VERTEX, EFFECT_TRITONE);

    fclose(out);
    fprintf(stderr, "programs=%d truncated=%d\n", emitted, truncated);
    return truncated ? 1 : 0;
}
