// C++ side of the G2a differential oracle: reads the case file written by
// `gpucommon_dump gen`, runs the ORIGINAL tvgGpuCommon.cpp and writes the same text
// format as `gpucommon_dump run` (hex float32 bit patterns, one line per case).
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>
#include "tvgGpuCommon.h"

using namespace tvg;

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

static std::string hx(float f)
{
    uint32_t u;
    memcpy(&u, &f, 4);
    char b[16];
    snprintf(b, sizeof(b), "%08x", u);
    return b;
}
static std::string fmtPt(const Point& p) { return hx(p.x) + " " + hx(p.y); }
static std::string fmtMatrix(const Matrix& m)
{
    return hx(m.e11) + " " + hx(m.e12) + " " + hx(m.e13) + " " + hx(m.e21) + " " + hx(m.e22) + " " + hx(m.e23) + " " +
           hx(m.e31) + " " + hx(m.e32) + " " + hx(m.e33);
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

static std::string probeState(const GpuConvexProbe& p)
{
    return std::to_string(int(p.convex)) + " " + std::to_string(int(p.winding)) + " " + fmtPt(p.firstEdge) + " " +
           fmtPt(p.prevEdge) + " " + std::to_string(int(p.prevXDir)) + " " + std::to_string(int(p.prevYDir)) + " " +
           std::to_string(int(p.xDirChanges)) + " " + std::to_string(int(p.yDirChanges)) + " " +
           std::to_string(int(p.reversals)) + " " + std::to_string(int(p.contourHasEdges));
}

static std::string runProbe(const RenderPath& path)
{
    std::string res;
    GpuConvexProbe probe;
    uint32_t pi = 0;
    Point cur{}, first{};
    for (uint32_t i = 0; i < path.cmds.count; ++i) {
        switch (path.cmds[i]) {
            case PathCommand::MoveTo:
                probe.nextContour();
                cur = path.pts[pi];
                first = cur;
                ++pi;
                break;
            case PathCommand::LineTo: {
                auto pt = path.pts[pi];
                probe.addEdge(pt - cur);
                cur = pt;
                ++pi;
                break;
            }
            case PathCommand::CubicTo: {
                auto c1 = path.pts[pi];
                auto c2 = path.pts[pi + 1];
                auto e = path.pts[pi + 2];
                auto x = gpuEdgesCross(cur, c1, c2, e);
                res += std::to_string(int(x)) + " ";
                if (x) probe.convex = false;
                probe.addEdge(c1 - cur);
                probe.addEdge(c2 - c1);
                probe.addEdge(e - c2);
                cur = e;
                pi += 3;
                break;
            }
            case PathCommand::Close:
                probe.addContourClose(first - cur);
                cur = first;
                break;
        }
        res += probeState(probe) + " | ";
    }
    return res;
}

int main(int argc, char** argv)
{
    if (argc != 3) return 2;
    std::ifstream in(argv[1]);
    std::istringstream ss(std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>()));
    std::string t;
    while (ss >> t) tok.push_back(t);

    std::string o;
    while (pos < tok.size()) {
        auto op = next();
        o += op;
        if (op == "OPT") {
            auto want = rInt() != 0;
            auto m = rMatrix();
            RenderPath p;
            rPath(p);
            RenderPath tr, lo;
            GpuOptimizeResult res;
            res.transformed = &tr;
            res.local = want ? &lo : nullptr;
            gpuOptimize(p, res, m);
            o += " " + std::to_string(int(res.thin)) + " " + std::to_string(int(res.skipFill)) + " T " + fmtPath(tr);
            if (want) o += " L " + fmtPath(lo);
        } else if (op == "DASH") {
            auto m = rMatrix();
            auto apply = rInt() != 0;
            RenderShape rs;
            rs.stroke = new RenderStroke;
            rs.stroke->cap = (StrokeCap)rInt();
            rs.stroke->trim.begin = rF();
            rs.stroke->trim.end = rF();
            rs.stroke->trim.simultaneous = rInt() != 0;
            rs.stroke->dash.offset = rF();
            auto n = rInt();
            rs.stroke->dash.count = n;
            if (n > 0) rs.stroke->dash.pattern = tvg::malloc<float>(sizeof(float) * n);
            for (int i = 0; i < n; ++i) {
                auto v = rF();
                rs.stroke->dash.pattern[i] = v;
                rs.stroke->dash.length += v;
            }
            rPath(rs.path);
            RenderPath outp;
            auto ok = gpuStrokeDash(rs, outp, apply ? &m : nullptr);
            o += " " + std::to_string(int(ok)) + " " + fmtPath(outp);
        } else if (op == "PROBE") {
            RenderPath p;
            rPath(p);
            o += " " + runProbe(p);
        } else if (op == "CROSS") {
            auto a = rPt(); auto b = rPt(); auto c = rPt(); auto d = rPt();
            o += " " + std::to_string(int(gpuEdgesCross(a, b, c, d)));
        } else if (op == "ARC") {
            auto a = rF();
            auto r = rF();
            o += " " + std::to_string(gpuArcSegmentsCnt(a, r));
        } else if (op == "CONIC") {
            auto c = rPt();
            o += " " + fmtMatrix(gpuConicTransform(c, rF()));
        } else if (op == "BOUNDS") {
            int x0 = rInt(), y0 = rInt(), x1 = rInt(), y1 = rInt();
            auto res = gpuTransformBounds(RenderRegion(x0, y0, x1, y1), rMatrix());
            o += " " + std::to_string(res.xMin) + " " + std::to_string(res.yMin) + " " + std::to_string(res.xMax) + " " + std::to_string(res.yMax);
        } else if (op == "MESH") {
            std::vector<Point> verts;
            auto nv = rInt();
            for (int i = 0; i < nv; ++i) verts.push_back(rPt());
            std::vector<uint32_t> idx;
            auto ni = rInt();
            for (int i = 0; i < ni; ++i) idx.push_back((uint32_t)rInt());
            auto p = rPt();
            o += " " + std::to_string(int(gpuPointInAnyMesh(p, verts.data(), idx.data(), ni))) + " " +
                 std::to_string(int(gpuPointInFillMesh(p, verts.data(), idx.data(), ni, FillRule::NonZero))) + " " +
                 std::to_string(int(gpuPointInFillMesh(p, verts.data(), idx.data(), ni, FillRule::EvenOdd)));
        } else if (op == "TRI") {
            auto p = rPt(); auto a = rPt(); auto b = rPt(); auto c = rPt();
            o += " " + std::to_string(int(gpuPointInTriangle(p, a, b, c)));
        } else if (op == "QUAD") {
            auto p = rPt();
            Point q[6];
            for (int i = 0; i < 6; ++i) q[i] = rPt();
            o += " " + std::to_string(int(gpuPointInQuad(p, q)));
        } else {
            fprintf(stderr, "unknown op %s\n", op.c_str());
            return 2;
        }
        o += "\n";
    }
    std::ofstream out(argv[2], std::ios::binary);
    out << o;
    return 0;
}
