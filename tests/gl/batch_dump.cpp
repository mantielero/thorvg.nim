// C++ side of the G2c differential oracle: reads the case file written by `batch_dump gen`
// (Nim) and runs the ORIGINAL tvgGlSolidBatch.cpp / tvgGlStencilCoverBatch.cpp /
// tvgGlRenderPass.cpp / tvgGlGeometry.cpp (no GL context), then dumps the stage arrays and the
// render tasks recorded in the pass in the same text format as `batch_dump run`.
//
// No GL: GlStageBuffer (arrays only, UBO alignment 256, buffer ids 1 = stage / 2 = aux) and the
// few GlRenderTask / GlStencilCoverTask members the batches touch are re-implemented below
// (the bodies are copies of the originals minus GL); GlRenderer is a zeroed block of memory of
// which only mPrograms, mGpuBuffer and mBlendMethod are initialised.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <new>
#include <sstream>
#include <string>
#include <vector>
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#define private public  // the dump reads the private stage arrays of GlStageBuffer
#include "tvgGlRenderer.h"

using namespace tvg;

// ---------------------------------------------------------------- stubs
static GlRenderPass* gPass = nullptr;
static constexpr uint32_t ALIGNMENT = 256;

void GlImage::destroy(GlRenderer&) {}
GlRenderPass* GlRenderer::currentPass() { return gPass; }

RenderRegion GlRenderer::viewportRegion(const RenderRegion& vp, const RenderRegion& bbox)
{
    auto x = bbox.sx() - vp.sx();
    auto y = bbox.sy() - vp.sy();
    auto w = bbox.sw();
    auto h = bbox.sh();
    auto yGl = vp.sh() - y - h;
    return {x, yGl, x + w, yGl + h};
}

GlGpuBuffer::GlGpuBuffer() {}
GlGpuBuffer::~GlGpuBuffer() {}
GlStageBuffer::GlStageBuffer() { memset(mImageOpacityOffsets, 0xff, sizeof(mImageOpacityOffsets)); }
GlStageBuffer::~GlStageBuffer() {}
GLuint GlStageBuffer::getBufferId() { return 1; }
GLuint GlStageBuffer::getAuxBufferId() { return 2; }

uint32_t GlStageBuffer::push(void* data, uint32_t size, bool alignGpuOffset)
{
    void* dst = nullptr;
    auto offset = reserve(size, &dst, alignGpuOffset);
    if (size > 0) memcpy(dst, data, size);
    return offset;
}

uint32_t GlStageBuffer::pushAux(void* data, uint32_t size)
{
    void* dst = nullptr;
    auto offset = reserveAux(size, &dst);
    if (size > 0) memcpy(dst, data, size);
    return offset;
}

uint32_t GlStageBuffer::pushIndex(void* data, uint32_t size)
{
    void* dst = nullptr;
    auto offset = reserveIndex(size, &dst);
    if (size > 0) memcpy(dst, data, size);
    return offset;
}

uint32_t GlStageBuffer::getImageOpacityOffset(uint8_t opacity)
{
    auto& offset = mImageOpacityOffsets[opacity];
    if (offset == UINT32_MAX) {
        GlImageOpacityBlock block = {opacity, 0, 0, 0};
        offset = push(block, sizeof(block), true);
    }
    return offset;
}

uint32_t GlStageBuffer::reserve(uint32_t size, void** dst, bool alignGpuOffset)
{
    if (alignGpuOffset) alignOffset(size);
    auto offset = mStageBuffer.count;
    if (this->mStageBuffer.reserved - this->mStageBuffer.count < size) {
        this->mStageBuffer.grow(max(size, this->mStageBuffer.reserved));
    }
    *dst = this->mStageBuffer.data + offset;
    this->mStageBuffer.count += size;
    return offset;
}

uint32_t GlStageBuffer::reserveAux(uint32_t size, void** dst)
{
    auto offset = mAuxBuffer.count;
    if (this->mAuxBuffer.reserved - this->mAuxBuffer.count < size) {
        this->mAuxBuffer.grow(max(size, this->mAuxBuffer.reserved));
    }
    *dst = this->mAuxBuffer.data + offset;
    this->mAuxBuffer.count += size;
    return offset;
}

uint32_t GlStageBuffer::reserveIndex(uint32_t size, void** dst)
{
    auto offset = mIndexBuffer.count;
    if (this->mIndexBuffer.reserved - this->mIndexBuffer.count < size) {
        this->mIndexBuffer.grow(max(size, this->mIndexBuffer.reserved));
    }
    *dst = this->mIndexBuffer.data + offset;
    this->mIndexBuffer.count += size;
    return offset;
}

void GlStageBuffer::alignOffset(uint32_t size)
{
    uint32_t alignment = ALIGNMENT;
    if (mStageBuffer.count % alignment == 0) return;
    uint32_t offset = alignment - mStageBuffer.count % alignment;
    if (mStageBuffer.count + offset + size > mStageBuffer.reserved) {
        mStageBuffer.grow(max(offset + size, mStageBuffer.reserved));
    }
    memset(mStageBuffer.data + mStageBuffer.count, 0, offset);  // padding bytes are stale in the original: zero them for the dump
    mStageBuffer.count += offset;
}

// the CPU half of flushToGPU: forget the opacity offsets and empty the arrays
bool GlStageBuffer::flushToGPU(GlStateCache&)
{
    memset(mImageOpacityOffsets, 0xff, sizeof(mImageOpacityOffsets));
    mStageBuffer.clear();
    mAuxBuffer.clear();
    mIndexBuffer.clear();
    return true;
}

void GlRenderTask::run(GlStateCache&) {}
void GlRenderTask::addVertexLayout(const GlVertexLayout& layout) { vertexLayout.push(layout); }
void GlRenderTask::setVertexColor(float r, float g, float b, float a)
{
    useVertexColor = true;
    vertexColor[0] = r;
    vertexColor[1] = g;
    vertexColor[2] = b;
    vertexColor[3] = a;
}
// the program query of the original needs GL: offline programs have every block at index 0 and an
// unknown binding; a block already bound to another point drops the new binding (as the original)
static uint32_t blockBindings[32][16];
static void resetBlockBindings() { memset(blockBindings, 0xff, sizeof(blockBindings)); }
void GlRenderTask::addBindResource(const GlBindingResource& binding)
{
    if (binding.type == GlBindingType::kUniformBuffer) {
        auto& bound = blockBindings[(uintptr_t)program][(int)binding.uniformBlock];
        if (bound != UINT32_MAX) {
            if (bound != binding.bindPoint) return;
        } else bound = binding.bindPoint;
    }
    bindResources.push(binding);
}
void GlRenderTask::setDrawRange(uint32_t offset, uint32_t count)
{
    useDrawArrays = false;
    indexOffset = offset;
    indexCnt = count;
}
void GlRenderTask::setViewport(const RenderRegion& viewport)
{
    this->viewport = viewport;
    this->viewport.xMax = std::max(viewport.xMin, viewport.xMax);
    this->viewport.yMax = std::max(viewport.yMin, viewport.yMax);
}
GlStencilCoverTask::GlStencilCoverTask(GlRenderTask* stencil, GlRenderTask* cover, GlStencilMode mode) :
    GlRenderTask(nullptr), stencilMode(mode)
{
    stencilTasks.push(stencil);
    coverTasks.push(cover);
}
GlStencilCoverTask::~GlStencilCoverTask()
{
    for (auto& p : stencilTasks) delete (p);
    for (auto& p : coverTasks) delete (p);
    stencilTasks.clear();
    coverTasks.clear();
}
void GlStencilCoverTask::run(GlStateCache&) {}
void GlStencilCoverTask::normalizeDrawDepth(int32_t) {}

// ---------------------------------------------------------------- tokens
static std::vector<std::string> tok;
static size_t pos = 0;

static const std::string& next() { return tok[pos++]; }
static int rInt() { return atoi(next().c_str()); }
static uint32_t rU() { return (uint32_t)strtoul(next().c_str(), nullptr, 10); }
static float rF()
{
    uint32_t u = (uint32_t)strtoul(next().c_str(), nullptr, 16);
    float f;
    memcpy(&f, &u, 4);
    return f;
}
static RenderRegion rRegion()
{
    int x0 = rInt(), y0 = rInt(), x1 = rInt(), y1 = rInt();
    return RenderRegion(x0, y0, x1, y1);
}
static Matrix rMatrix()
{
    Matrix m;
    m.e11 = rF(); m.e12 = rF(); m.e13 = rF();
    m.e21 = rF(); m.e22 = rF(); m.e23 = rF();
    m.e31 = rF(); m.e32 = rF(); m.e33 = rF();
    return m;
}

// synthetic geometry: `nf` floats, `ni` indices below nf / stride, from an LCG
static void fillBuffer(GlGeometryBuffer& b, uint32_t nf, uint32_t ni, uint32_t seed, uint32_t stride)
{
    auto x = seed;
    for (uint32_t i = 0; i < nf; ++i) {
        x = x * 1664525u + 1013904223u;
        b.vertex.push(float((x >> 16) & 0x7ffu) / 8.0f - 100.0f);
    }
    auto nv = nf / stride;
    for (uint32_t i = 0; i < ni; ++i) {
        x = x * 1664525u + 1013904223u;
        b.index.push(nv == 0 ? 0u : (x >> 8) % nv);
    }
}

static void rGeom(GlGeometryBuffer& b, uint32_t stride)
{
    auto nf = rU();
    auto ni = rU();
    auto seed = rU();
    fillBuffer(b, nf, ni, seed, stride);
}

// ---------------------------------------------------------------- dump
static std::string hx(float f)
{
    uint32_t u;
    memcpy(&u, &f, 4);
    char b[16];
    snprintf(b, sizeof(b), "%08x", u);
    return b;
}
static std::string num(uint64_t v) { return std::to_string(v); }
static std::string fmtRegion(const RenderRegion& r)
{
    return std::to_string(r.xMin) + " " + std::to_string(r.yMin) + " " + std::to_string(r.xMax) + " " + std::to_string(r.yMax);
}
static std::string fmtMatrix(const Matrix& m)
{
    return hx(m.e11) + " " + hx(m.e12) + " " + hx(m.e13) + " " + hx(m.e21) + " " + hx(m.e22) + " " + hx(m.e23) + " " +
           hx(m.e31) + " " + hx(m.e32) + " " + hx(m.e33);
}

// words of a byte array: full list up to 256 words, otherwise the FNV-1a 64 hash of the words
static std::string fmtWords(const uint8_t* data, uint32_t bytes)
{
    auto n = bytes / 4;
    std::string s = std::to_string(n);
    const uint32_t* w = reinterpret_cast<const uint32_t*>(data);
    if (n <= 256) {
        for (uint32_t i = 0; i < n; ++i) s += " " + std::to_string(w[i]);
    } else {
        uint64_t h = 1469598103934665603ull;
        for (uint32_t i = 0; i < n; ++i) {
            h ^= w[i];
            h *= 1099511628211ull;
        }
        s += " #" + std::to_string(h);
    }
    return s;
}

static std::string fmtTask(GlRenderTask* t)
{
    std::string s;
    auto stc = dynamic_cast<GlStencilCoverTask*>(t);
    s += stc ? "STC" : "TASK";
    s += " " + num((uintptr_t)t->program) + " " + hx(t->drawDepth) + " " + fmtRegion(t->viewport) + " " + num(t->indexCnt) + " " +
         num(t->indexOffset) + " " + num(t->arrayOffset) + " " + num(t->arrayMode) + " " + fmtMatrix(t->viewMatrix) + " " +
         hx(t->vertexColor[0]) + " " + hx(t->vertexColor[1]) + " " + hx(t->vertexColor[2]) + " " + hx(t->vertexColor[3]) + " " +
         num(t->useViewMatrix) + " " + num(t->useVertexColor) + " " + num(t->useDrawArrays) + " " + num(int(t->blendMethod));
    s += " L" + num(t->vertexLayout.count);
    for (uint32_t i = 0; i < t->vertexLayout.count; ++i) {
        auto& l = t->vertexLayout[i];
        s += " " + num(l.index) + " " + num(l.size) + " " + num(l.stride) + " " + num(l.offset) + " " + num(l.type) + " " +
             num(l.normalized) + " " + num(l.arrayBufferId);
    }
    s += " B" + num(t->bindResources.count);
    for (uint32_t i = 0; i < t->bindResources.count; ++i) {
        auto& b = t->bindResources[i];
        s += " " + num(int(b.type)) + " " + num(int(b.uniform)) + " " + num(int(b.uniformBlock)) + " " + num(b.bindPoint) + " " +
             num(b.resourceId) + " " + num(b.bufferOffset) + " " + num(b.bufferRange);
    }
    if (stc) {
        s += " M" + num(int(stc->stencilMode)) + " S" + num(stc->stencilTasks.count);
        for (auto& p : stc->stencilTasks) s += " ( " + fmtTask(p) + " )";
        s += " C" + num(stc->coverTasks.count);
        for (auto& p : stc->coverTasks) s += " ( " + fmtTask(p) + " )";
    }
    return s;
}

// non destructive listing of the pass tasks (the list is private: pop all, push back)
static std::string fmtPass(GlRenderPass* pass)
{
    std::vector<GlRenderTask*> tasks;
    while (auto t = pass->takeLastTask()) tasks.push_back(t);
    std::string s = "N" + num(tasks.size());
    for (size_t i = tasks.size(); i-- > 0;) {
        s += " [ " + fmtTask(tasks[i]) + " ]";
        pass->addRenderTask(tasks[i]);
    }
    return s;
}

// ---------------------------------------------------------------- scenario state
static alignas(GlRenderer) unsigned char rendererMem[sizeof(GlRenderer)];
static GlRenderer* renderer = nullptr;
alignas(GlRenderTarget) static unsigned char fboMem[sizeof(GlRenderTarget)];
static GlRenderTarget* fbo = nullptr;
static alignas(GlStateCache) unsigned char stateMem[sizeof(GlStateCache)];
static GlSolidBatch solid;
static GlStencilCoverBatch stencil;

static void setup()
{
    resetBlockBindings();
    memset(rendererMem, 0, sizeof(rendererMem));
    renderer = reinterpret_cast<GlRenderer*>(rendererMem);
    new (&renderer->mGpuBuffer) GlStageBuffer();
    new (&renderer->mPrograms) Array<GlProgram*>();
    for (uintptr_t i = 1; i <= 24; ++i) renderer->mPrograms.push(reinterpret_cast<GlProgram*>(i));
    renderer->mBlendMethod = BlendMethod::Normal;
    memset(fboMem, 0, sizeof(fboMem));
    fbo = reinterpret_cast<GlRenderTarget*>(fboMem);
}

static void newPass(const RenderRegion& vp)
{
    delete gPass;
    fbo->viewport = vp;
    fbo->width = vp.w();
    fbo->height = vp.h();
    fbo->fbo = 1;
    gPass = new GlRenderPass(fbo);
}

static RenderUpdateFlag rFlag(int v)
{
    switch (v) {
        case 0: return RenderUpdateFlag::Path;
        case 1: return RenderUpdateFlag::Stroke;
        case 2: return RenderUpdateFlag::GradientStroke;
        case 3: return RenderUpdateFlag::Gradient;
        default: return RenderUpdateFlag::Color;
    }
}

int main(int argc, char** argv)
{
    if (argc != 3) return 2;
    std::ifstream in(argv[1]);
    std::istringstream ss(std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>()));
    std::string t;
    while (ss >> t) tok.push_back(t);

    setup();
    newPass(RenderRegion(0, 0, 100, 100));
    std::ofstream out(argv[2], std::ios::binary);
    auto& stage = renderer->mGpuBuffer;
    auto& state = *reinterpret_cast<GlStateCache*>(stateMem);
    while (pos < tok.size()) {
        std::string o;
        auto op = next();
        o += op;
        if (op == "NEWPASS") {
            newPass(rRegion());
        } else if (op == "BLEND") {
            renderer->mBlendMethod = (BlendMethod)rInt();
        } else if (op == "FLUSH") {
            stage.flushToGPU(state);
        } else if (op == "SCLEAR") {
            solid.clear();
        } else if (op == "TCLEAR") {
            stencil.clear();
        } else if (op == "SOLID") {
            auto shape = new GlShape();
            rGeom(shape->geometry.fill, 2);
            shape->opacity = rU();
            RenderColor c;
            c.r = rInt(); c.g = rInt(); c.b = rInt(); c.a = rInt();
            auto depth = rInt();
            auto viewRegion = rRegion();
            auto viewBounds = rRegion();
            solid.draw(*renderer, *shape, c, depth, viewRegion, viewBounds);
            delete shape;
        } else if (op == "IMAGE") {
            auto image = new GlImage();
            rGeom(image->geometry.fill, 4);
            image->texId = rU();
            image->opacity = rU();
            auto depth = rInt();
            auto viewRegion = rRegion();
            auto viewBounds = rRegion();
            solid.draw(*renderer, *image, depth, viewRegion, viewBounds);
            delete image;
        } else if (op == "STENCIL") {
            auto shape = new GlShape();
            auto flag = rFlag(rInt());
            auto mode = (GlStencilMode)rInt();
            auto hasColor = rInt() != 0;
            RenderColor c;
            c.r = rInt(); c.g = rInt(); c.b = rInt(); c.a = rInt();
            auto viewBounds = rRegion();
            if (rInt() != 0) shape->clips.push(nullptr);
            shape->geometry.transform(rMatrix());
            shape->geometry.fillBBox = rRegion();
            shape->geometry.strokeBBox = rRegion();
            rGeom(shape->geometry.fill, 2);
            rGeom(shape->geometry.stroke, 2);
            auto prog = rU();
            auto blend = (BlendMethod)rInt();
            auto depth = rInt();
            auto coverBind = rInt() != 0;
            auto cover = new GlRenderTask(renderer->mPrograms[prog], blend);
            cover->setViewMatrix(gPass->getViewMatrix());
            cover->setDrawDepth(depth);
            if (coverBind) cover->addBindResource(GlBindingResource{0, 5, GlShaderUniform::Texture});
            auto prep = stencil.prepare(*renderer, cover, *shape, flag, mode, hasColor ? &c : nullptr, viewBounds);
            stencil.draw(gPass, cover, prep);
            delete shape;
        } else if (op == "DUMP") {
            o += " " + fmtPass(gPass);
        } else {
            return 2;
        }
        // stage arrays after every op
        o += " | " + fmtWords(stage.mStageBuffer.data, stage.mStageBuffer.count) + " | " +
             fmtWords(stage.mAuxBuffer.data, stage.mAuxBuffer.count) + " | " + fmtWords(stage.mIndexBuffer.data, stage.mIndexBuffer.count);
        o += "\n";
        out << o << std::flush;
    }
    delete gPass;
    return 0;
}
