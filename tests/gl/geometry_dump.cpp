// C++ side of the G2b differential oracle: reads the case file written by
// `geometry_dump gen`, runs the ORIGINAL tvgGlGeometry.cpp / tvgGlTessellator.cpp (no GL
// context) and writes the same text format as `geometry_dump run`.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>
#include "tvgGlCommon.h"
#include "tvgGlGpuBuffer.h"
#include "tvgGlRenderTask.h"

using namespace tvg;

// GlImage::destroy lives in tvgGlRenderer.cpp (needs the renderer) and GlGeometry::draw needs the
// GL stage buffer / render task: none of them is part of this unit, the oracle never calls them.
void GlImage::destroy(GlRenderer&) {}
uint32_t GlStageBuffer::push(void*, uint32_t, bool) { return 0; }
uint32_t GlStageBuffer::pushIndex(void*, uint32_t) { return 0; }
GLuint GlStageBuffer::getBufferId() { return 0; }
void GlRenderTask::addVertexLayout(const GlVertexLayout&) {}
void GlRenderTask::setDrawRange(uint32_t, uint32_t) {}

static std::vector<std::string> tok;
static size_t pos = 0;

static const std::string& next() { return tok[pos++]; }
static int rInt() { return atoi(next().c_str()); }
static float rF()
{
    uint32_t u = (uint32_t)strtoul(next().c_str(), nullptr, 16);
    float f;
    memcpy(&f, &u, 4);
    return f;
}
static Point rPt() { Point p; p.x = rF(); p.y = rF(); return p; }
static Matrix rMatrix()
{
    Matrix m;
    m.e11 = rF(); m.e12 = rF(); m.e13 = rF();
    m.e21 = rF(); m.e22 = rF(); m.e23 = rF();
    m.e31 = rF(); m.e32 = rF(); m.e33 = rF();
    return m;
}

static void rPath(RenderPath& p)
{
    auto nc = rInt();
    auto letters = next();
    if (nc > 0) {
        for (char ch : letters) {
            switch (ch) {
                case 'M': p.cmds.push(PathCommand::MoveTo); break;
                case 'L': p.cmds.push(PathCommand::LineTo); break;
                case 'C': p.cmds.push(PathCommand::CubicTo); break;
                default: p.cmds.push(PathCommand::Close); break;
            }
        }
    }
    auto np = rInt();
    for (int i = 0; i < np; ++i) p.pts.push(rPt());
}

static RenderRegion rRegion()
{
    int x = rInt(), y = rInt(), w = rInt(), h = rInt();
    return RenderRegion(x, y, x + w, y + h);
}

struct Spec
{
    Matrix matrix;
    RenderShape rshape;
};

static void rSpec(Spec& s)
{
    s.matrix = rMatrix();
    s.rshape.rule = (FillRule)rInt();
    s.rshape.color.a = (uint8_t)rInt();
    if (rInt() != 0) {
        auto st = new RenderStroke;
        st->width = rF();
        st->cap = (StrokeCap)rInt();
        st->join = (StrokeJoin)rInt();
        st->miterlimit = rF();
        st->trim.begin = rF();
        st->trim.end = rF();
        st->trim.simultaneous = rInt() != 0;
        st->dash.offset = rF();
        auto n = rInt();
        st->dash.count = n;
        if (n > 0) st->dash.pattern = tvg::malloc<float>(sizeof(float) * n);
        for (int i = 0; i < n; ++i) {
            auto v = rF();
            st->dash.pattern[i] = v;
            st->dash.length += v;
        }
        s.rshape.stroke = st;
    }
    rPath(s.rshape.path);
}

static std::string hx(float f)
{
    uint32_t u;
    memcpy(&u, &f, 4);
    char b[16];
    snprintf(b, sizeof(b), "%08x", u);
    return b;
}
static std::string fmtMatrix(const Matrix& m)
{
    return hx(m.e11) + " " + hx(m.e12) + " " + hx(m.e13) + " " + hx(m.e21) + " " + hx(m.e22) + " " + hx(m.e23) + " " +
           hx(m.e31) + " " + hx(m.e32) + " " + hx(m.e33);
}
static std::string fmtRegion(const RenderRegion& r)
{
    return std::to_string(r.xMin) + " " + std::to_string(r.yMin) + " " + std::to_string(r.xMax) + " " + std::to_string(r.yMax);
}
static std::string fmtPath(const RenderPath& p)
{
    std::string letters;
    for (uint32_t i = 0; i < p.cmds.count; ++i) {
        switch (p.cmds[i]) {
            case PathCommand::MoveTo: letters += 'M'; break;
            case PathCommand::LineTo: letters += 'L'; break;
            case PathCommand::CubicTo: letters += 'C'; break;
            case PathCommand::Close: letters += 'Z'; break;
        }
    }
    std::string s = std::to_string(p.cmds.count) + " " + (letters.empty() ? "-" : letters) + " " + std::to_string(p.pts.count);
    for (uint32_t i = 0; i < p.pts.count; ++i) s += " " + hx(p.pts[i].x) + " " + hx(p.pts[i].y);
    return s;
}
static std::string fmtFloats(const Array<float>& v)
{
    std::string s = std::to_string(v.count);
    for (uint32_t i = 0; i < v.count; ++i) s += " " + hx(v[i]);
    return s;
}
static std::string fmtUints(const Array<uint32_t>& v)
{
    std::string s = std::to_string(v.count);
    for (uint32_t i = 0; i < v.count; ++i) s += " " + std::to_string(v[i]);
    return s;
}

static std::string fmtShape(GlShape* shape, bool hit)
{
    auto& g = shape->geometry;
    auto s = std::to_string(int(g.optPathThin)) + " " + std::to_string(int(g.optPathSkipFill)) + " " +
             std::to_string(int(shape->valid.fill)) + " " + hx(shape->multiplier) + " " + std::to_string(int(g.fillRule)) + " " +
             std::to_string(int(g.convex)) + " " + std::to_string(int(g.fillWorld)) + " " + fmtRegion(g.fillBBox) + " " +
             std::to_string(int(g.strokeDirect)) + " " + std::to_string(int(shape->valid.stroke)) + " " + hx(g.strokeRenderWidth) + " " +
             fmtRegion(g.strokeBBox) + " " + fmtRegion(g.bounds());
    s += " " + std::to_string(int(g.stencilMode(RenderUpdateFlag::Path))) + " " + std::to_string(int(g.stencilMode(RenderUpdateFlag::Stroke))) +
         " " + std::to_string(int(g.stencilMode(RenderUpdateFlag::Image)));
    s += " " + std::to_string(int(g.drawable(RenderUpdateFlag::Stroke))) + " " + std::to_string(int(g.drawable(RenderUpdateFlag::Path)));
    s += " | " + fmtPath(g.optPath) + " | " + fmtPath(g.optStrokePath);
    s += " | " + fmtFloats(g.fill.vertex) + " | " + fmtUints(g.fill.index);
    s += " | " + fmtFloats(g.stroke.vertex) + " | " + fmtUints(g.stroke.index);
    s += " | " + std::to_string(int(hit));
    return s;
}

// the geometry part of GlRenderer::prepare(RenderShape) for a new shape
static GlShape* buildShape(Spec& spec)
{
    auto shape = new GlShape();  // value-initialized: the members the original leaves unset are zero
    shape->rshape = &spec.rshape;
    shape->geometry.transform(spec.matrix);
    shape->geometry.prepare(spec.rshape);
    shape->valid.fill = shape->geometry.tesselateShape(spec.rshape, shape->multiplier);
    shape->valid.stroke = shape->geometry.tesselateStroke(spec.rshape);
    return shape;
}

int main(int argc, char** argv)
{
    if (argc != 3) return 2;
    std::ifstream in(argv[1]);
    std::istringstream ss(std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>()));
    std::string t;
    while (ss >> t) tok.push_back(t);

    GlIntersector inter;
    std::ofstream out(argv[2], std::ios::binary);
    while (pos < tok.size()) {
        std::string o;
        auto op = next();
        o += op;
        if (op == "SIZES") {
            o += " " + std::to_string(sizeof(GlLinearGradientBlock)) + " " + std::to_string(sizeof(GlRadialGradientBlock)) + " " +
                 std::to_string(sizeof(GlConicGradientBlock)) + " " + std::to_string(sizeof(GlImageOpacityBlock));
        } else if (op == "SHAPE") {
            Spec spec;
            rSpec(spec);
            auto region = rRegion();
            auto shape = buildShape(spec);
            o += " " + fmtShape(shape, inter.intersect(shape, region));
            delete shape;
        } else if (op == "CLIP") {
            Spec spec, cspec;
            rSpec(spec);
            rSpec(cspec);
            auto region = rRegion();
            auto shape = buildShape(spec);
            auto clip = buildShape(cspec);
            shape->clips.push(clip);
            o += " " + fmtShape(shape, inter.intersect(shape, region));
            delete shape;
            delete clip;
        } else if (op == "IMAGE") {
            auto m = rMatrix();
            RenderSurface surface;
            surface.w = (uint32_t)rInt();
            surface.h = (uint32_t)rInt();
            auto image = new GlImage();
            image->geometry.transform(m);
            image->geometry.tesselateImage(&surface);
            auto region = rRegion();
            auto& g = image->geometry;
            o += " " + fmtFloats(g.fill.vertex) + " | " + fmtUints(g.fill.index) + " | " + fmtRegion(g.fillBBox) + " | " +
                 fmtRegion(g.bounds()) + " | " + std::to_string(int(inter.intersect(image, region)));
            delete image;
        } else {
            return 2;
        }
        o += "\n";
        out << o << std::flush;
    }
    return 0;
}
