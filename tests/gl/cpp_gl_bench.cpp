// GL parity driver: renders the SAME scenes as tests/parity/cpp_driver.cpp, but with the original
// ThorVG GlCanvas on a hidden WGL window + FBO (RGBA8 + DEPTH24_STENCIL8) and dumps the glReadPixels
// result in the same .argb format (little-endian uint32, premultiplied ARGB, top row first).
// Usage: cpp_gl_driver.exe <scene> <w> <h> [--dump <prefix>] [--repeat N]
// Extra outputs: <prefix>.rgba = raw readback (bottom row first), gl info on stderr.
#define render render_sw_unused
#define main main_sw_unused
#include "../parity/cpp_driver.cpp"
#undef render
#undef main

#include <windows.h>

// NOTE: <GL/gl.h> + -lopengl32 CANNOT be used here: tvgGl.h defines global glViewport/glClear/... function
// pointers that collide with the import-library symbols. Everything below is loaded by name instead.
typedef unsigned int GLuint; typedef unsigned int GLenum; typedef int GLsizei; typedef float GLfloat; typedef int GLint;
#define GL_FRAMEBUFFER 0x8D40
#define GL_RENDERBUFFER 0x8D41
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_DEPTH_STENCIL_ATTACHMENT 0x821A
#define GL_DEPTH24_STENCIL8 0x88F0
#define GL_RGBA8 0x8058
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
typedef HGLRC (WINAPI* PFNCTXATTR)(HDC, HGLRC, const int*);
typedef void (APIENTRY* PFNGEN)(GLsizei, GLuint*);
typedef void (APIENTRY* PFNBIND)(GLenum, GLuint);
typedef void (APIENTRY* PFNRBSTORE)(GLenum, GLenum, GLsizei, GLsizei);
typedef void (APIENTRY* PFNFBRB)(GLenum, GLenum, GLenum, GLuint);
typedef GLenum (APIENTRY* PFNCHECK)(GLenum);
typedef void (APIENTRY* PFNVIEWPORT)(GLint, GLint, GLsizei, GLsizei);
typedef void (APIENTRY* PFNCLEARCOLOR)(GLfloat, GLfloat, GLfloat, GLfloat);
typedef void (APIENTRY* PFNCLEARSTENCIL)(GLint);
typedef void (APIENTRY* PFNCLEAR)(GLuint);
typedef void (APIENTRY* PFNPIXELSTOREI)(GLenum, GLint);
typedef void (APIENTRY* PFNREADPIXELS)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*);

static void* glfn(const char* n)
{
    void* p = (void*)wglGetProcAddress(n);
    if (!p) p = (void*)GetProcAddress(GetModuleHandleA("opengl32.dll"), n);
    return p;
}

struct GlEnv { HWND wnd = nullptr; HDC dc = nullptr; HGLRC rc = nullptr; GLuint fbo = 0, rbc = 0, rbd = 0; };

static bool createContext(GlEnv& e)
{
    WNDCLASSA wc{}; wc.lpfnWndProc = DefWindowProcA; wc.hInstance = GetModuleHandleA(nullptr); wc.lpszClassName = "tvgGlDriver";
    RegisterClassA(&wc);
    e.wnd = CreateWindowA("tvgGlDriver", "gl", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64, nullptr, nullptr, wc.hInstance, nullptr); // never shown
    e.dc = GetDC(e.wnd);
    PIXELFORMATDESCRIPTOR pfd{}; pfd.nSize = sizeof(pfd); pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER; pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32; pfd.cDepthBits = 24; pfd.cStencilBits = 8;
    int pf = ChoosePixelFormat(e.dc, &pfd);
    if (!pf || !SetPixelFormat(e.dc, pf, &pfd)) return false;
    HGLRC legacy = wglCreateContext(e.dc);
    if (!legacy || !wglMakeCurrent(e.dc, legacy)) return false;
    auto create = (PFNCTXATTR)glfn("wglCreateContextAttribsARB");
    if (!create) return false;
    int attrs[] = {0x2091, 3, 0x2092, 3, 0x9126, 1, 0};   // 3.3 core
    e.rc = create(e.dc, nullptr, attrs);
    wglMakeCurrent(nullptr, nullptr);
    wglDeleteContext(legacy);
    return e.rc && wglMakeCurrent(e.dc, e.rc);
}

static bool createFbo(GlEnv& e, uint32_t W, uint32_t H)
{
    auto gen = (PFNGEN)glfn("glGenFramebuffers"); auto bind = (PFNBIND)glfn("glBindFramebuffer");
    auto genr = (PFNGEN)glfn("glGenRenderbuffers"); auto bindr = (PFNBIND)glfn("glBindRenderbuffer");
    auto store = (PFNRBSTORE)glfn("glRenderbufferStorage"); auto attach = (PFNFBRB)glfn("glFramebufferRenderbuffer");
    auto check = (PFNCHECK)glfn("glCheckFramebufferStatus");
    gen(1, &e.fbo); bind(GL_FRAMEBUFFER, e.fbo);
    genr(1, &e.rbc); bindr(GL_RENDERBUFFER, e.rbc); store(GL_RENDERBUFFER, GL_RGBA8, W, H);
    attach(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, e.rbc);
    genr(1, &e.rbd); bindr(GL_RENDERBUFFER, e.rbd); store(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, W, H);
    attach(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, e.rbd);
    return check(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}

//---------------------------------------------------------------------------------------------
// GL-only scenes `glx:<name>` (design canvas 200x150), mirrored statement by statement by tests/gl/glx_scene.nim.
// They cover what the CPU suite lacks: the 16 blend modes on shapes and scenes, the 10 mask methods, the scene effects,
// 16-stop / conic / focal gradients, thin strokes, trim paths, nested clips and nested opacity scenes.
//---------------------------------------------------------------------------------------------
struct BlendName { const char* name; BlendMethod m; };
static const BlendName kBlends[] = {{"multiply", BlendMethod::Multiply}, {"screen", BlendMethod::Screen},
    {"overlay", BlendMethod::Overlay}, {"darken", BlendMethod::Darken}, {"lighten", BlendMethod::Lighten},
    {"colordodge", BlendMethod::ColorDodge}, {"colorburn", BlendMethod::ColorBurn}, {"hardlight", BlendMethod::HardLight},
    {"softlight", BlendMethod::SoftLight}, {"difference", BlendMethod::Difference}, {"exclusion", BlendMethod::Exclusion},
    {"hue", BlendMethod::Hue}, {"saturation", BlendMethod::Saturation}, {"color", BlendMethod::Color},
    {"luminosity", BlendMethod::Luminosity}, {"add", BlendMethod::Add}};
struct MaskName { const char* name; MaskMethod m; };
static const MaskName kMasks[] = {{"alpha", MaskMethod::Alpha}, {"invalpha", MaskMethod::InvAlpha}, {"luma", MaskMethod::Luma},
    {"invluma", MaskMethod::InvLuma}, {"add", MaskMethod::Add}, {"subtract", MaskMethod::Subtract},
    {"intersect", MaskMethod::Intersect}, {"difference", MaskMethod::Difference}, {"lighten", MaskMethod::Lighten},
    {"darken", MaskMethod::Darken}};

static Shape* glxBase()
{
    auto s = Shape::gen();
    s->appendRect(10, 10, 180, 130);
    auto g = LinearGradient::gen();
    g->linear(10, 10, 190, 140);
    Fill::ColorStop st[3] = {{0.0f, 230, 60, 60, 255}, {0.5f, 60, 200, 90, 255}, {1.0f, 60, 80, 230, 255}};
    g->colorStops(st, 3);
    s->fill(g);
    return s;
}

static Shape* glxTop(float dx)
{
    auto s = Shape::gen();
    s->appendRect(70 + dx, 40, 100, 70, 12, 12);
    auto g = LinearGradient::gen();
    g->linear(70 + dx, 40, 170 + dx, 110);
    Fill::ColorStop st[2] = {{0.0f, 255, 220, 120, 255}, {1.0f, 40, 30, 120, 200}};
    g->colorStops(st, 2);
    s->fill(g);
    return s;
}

static Scene* glxContent()
{
    auto sc = Scene::gen();
    auto a = Shape::gen();
    a->appendCircle(70, 70, 35, 35);
    a->fill(220, 40, 40);
    auto b = Shape::gen();
    b->appendRect(90, 50, 70, 60);
    b->fill(40, 60, 220, 230);
    auto c = Shape::gen();
    c->moveTo(30, 120);
    c->lineTo(170, 30);
    c->strokeWidth(6);
    c->strokeFill(250, 250, 250);
    sc->add(a);
    sc->add(b);
    sc->add(c);
    return sc;
}

static void glxFill16(Fill* g)
{
    Fill::ColorStop st[16];
    for (int i = 0; i < 16; ++i)
        st[i] = {i / 15.0f, (uint8_t)((i * 53) & 255), (uint8_t)((i * 97 + 40) & 255), (uint8_t)((i * 29 + 120) & 255), (uint8_t)(255 - (i % 4) * 20)};
    g->colorStops(st, 16);
}

static bool buildGlx(Canvas* canvas, const std::string& name)
{
    auto colon = name.find(':');
    std::string kind = name.substr(0, colon), arg = colon == std::string::npos ? "" : name.substr(colon + 1);
    if (kind == "blend") {
        for (auto& b : kBlends) if (arg == b.name) {
            auto top = glxTop(0);
            top->blend(b.m);
            canvas->add(glxBase());
            canvas->add(top);
            return true;
        }
    } else if (kind == "sblend") {
        for (auto& b : kBlends) if (arg == b.name) {
            auto sc = Scene::gen();
            sc->add(glxTop(-30));
            auto c = Shape::gen();
            c->appendCircle(120, 90, 40, 40);
            c->fill(30, 200, 220, 200);
            sc->add(c);
            sc->blend(b.m);
            canvas->add(glxBase());
            canvas->add(sc);
            return true;
        }
    } else if (kind == "mask") {
        for (auto& k : kMasks) if (arg == k.name) {
            auto bg = Shape::gen();
            bg->appendRect(0, 0, 200, 150);
            bg->fill(40, 40, 40);
            auto s = Shape::gen();
            s->appendRect(30, 30, 140, 90);
            auto g = LinearGradient::gen();
            g->linear(30, 30, 170, 120);
            Fill::ColorStop st[2] = {{0.0f, 255, 200, 40, 255}, {1.0f, 40, 120, 255, 255}};
            g->colorStops(st, 2);
            s->fill(g);
            auto m = Shape::gen();
            m->appendCircle(100, 75, 45, 45);
            auto mg = RadialGradient::gen();
            mg->radial(100, 75, 45, 100, 75, 0);
            Fill::ColorStop ms[2] = {{0.0f, 255, 255, 255, 255}, {1.0f, 60, 30, 90, 90}};
            mg->colorStops(ms, 2);
            m->fill(mg);
            s->mask(m, k.m);
            canvas->add(bg);
            canvas->add(s);
            return true;
        }
    } else if (kind == "fx") {
        auto sc = glxContent();
        if (arg == "blur") sc->add(SceneEffect::GaussianBlur, 6.0, 0, 0, 100);
        else if (arg == "blur_h") sc->add(SceneEffect::GaussianBlur, 4.0, 1, 0, 100);
        else if (arg == "blur_v") sc->add(SceneEffect::GaussianBlur, 4.0, 2, 0, 100);
        else if (arg == "blur_q50") sc->add(SceneEffect::GaussianBlur, 10.0, 0, 0, 50);
        else if (arg == "shadow") sc->add(SceneEffect::DropShadow, 0, 0, 0, 160, 45.0, 10.0, 4.0, 100);
        else if (arg == "motion") sc->add(SceneEffect::MotionBlur, 20.0, 30.0, 100);
        else if (arg == "fill") sc->add(SceneEffect::Fill, 30, 200, 120, 200);
        else if (arg == "tint") sc->add(SceneEffect::Tint, 0, 0, 60, 255, 230, 180, 80.0);
        else if (arg == "tritone") sc->add(SceneEffect::Tritone, 0, 0, 80, 200, 60, 60, 255, 255, 200, 128);
        else if (arg == "chain") { sc->add(SceneEffect::GaussianBlur, 3.0, 0, 0, 100); sc->add(SceneEffect::Tint, 0, 0, 60, 255, 230, 180, 80.0); }
        else { delete sc; return false; }
        canvas->add(sc);
        return true;
    } else if (kind == "grad") {
        auto s = Shape::gen();
        if (arg == "linear16") {
            s->appendRect(10, 10, 180, 130);
            auto g = LinearGradient::gen(); g->linear(10, 0, 190, 0); glxFill16(g); s->fill(g);
        } else if (arg == "reflect16") {
            s->appendRect(10, 10, 180, 130);
            auto g = LinearGradient::gen(); g->linear(20, 20, 70, 50); glxFill16(g); g->spread(FillSpread::Reflect); s->fill(g);
        } else if (arg == "radial16") {
            s->appendCircle(100, 75, 65, 65);
            auto g = RadialGradient::gen(); g->radial(100, 75, 60, 90, 70, 10); glxFill16(g); s->fill(g);
        } else if (arg == "radial_repeat") {
            s->appendRect(10, 10, 180, 130);
            auto g = RadialGradient::gen(); g->radial(100, 75, 30, 100, 75, 0); glxFill16(g); g->spread(FillSpread::Repeat); s->fill(g);
        } else if (arg == "radial_focal") {
            s->appendRect(10, 10, 180, 130);
            auto g = RadialGradient::gen(); g->radial(100, 75, 30, 160, 75, 10);
            Fill::ColorStop st[3] = {{0.0f, 255, 0, 0, 255}, {0.5f, 0, 255, 0, 255}, {1.0f, 0, 0, 255, 255}};
            g->colorStops(st, 3); s->fill(g);
        } else if (arg == "conic") {
            s->appendRect(10, 10, 180, 130);
            auto g = ConicGradient::gen(); g->conic(100, 75, 30);
            Fill::ColorStop st[5] = {{0.0f, 255, 0, 0, 255}, {0.25f, 255, 255, 0, 255}, {0.5f, 0, 255, 0, 255}, {0.75f, 0, 0, 255, 255}, {1.0f, 255, 0, 0, 255}};
            g->colorStops(st, 5); s->fill(g);
        } else if (arg == "conic_stroke") {
            s->appendCircle(100, 75, 50, 50);
            s->strokeWidth(20);
            auto g = ConicGradient::gen(); g->conic(100, 75, 0);
            Fill::ColorStop st[3] = {{0.0f, 255, 0, 0, 255}, {0.5f, 0, 0, 255, 128}, {1.0f, 0, 255, 0, 255}};
            g->colorStops(st, 3); s->strokeFill(g);
        } else { Paint::rel(s); return false; }
        canvas->add(s);
        return true;
    } else if (kind == "thin") {
        const float widths[8] = {0.1f, 0.25f, 0.5f, 0.75f, 0.99f, 1.0f, 1.5f, 2.0f};
        for (int i = 0; i < 8; ++i) {
            auto s = Shape::gen();
            s->moveTo(10, 10.5f + i * 8);
            s->lineTo(90, 10.5f + i * 8);
            s->strokeWidth(widths[i]);
            s->strokeFill(20, 20, 20);
            canvas->add(s);
            auto t = Shape::gen();
            t->moveTo(110, 10.5f + i * 8);
            t->lineTo(190, 14.0f + i * 8);
            t->strokeWidth(widths[i]);
            t->strokeFill(200, 30, 30, 200);
            canvas->add(t);
        }
        auto c = Shape::gen();
        c->appendCircle(50, 105, 30, 25);
        c->strokeWidth(0.5f);
        c->strokeFill(0, 0, 0);
        canvas->add(c);
        auto r = Shape::gen();
        r->appendRect(110, 85, 70, 45, 6, 6);
        r->fill(250, 220, 120);
        r->strokeWidth(0.8f);
        r->strokeFill(0, 0, 160);
        canvas->add(r);
        return true;
    } else if (kind == "trim") {
        auto a = Shape::gen();
        a->appendCircle(55, 75, 40, 40);
        a->strokeWidth(8);
        a->strokeFill(200, 40, 40);
        a->strokeCap(StrokeCap::Round);
        a->trimpath(0.1f, 0.6f, true);
        canvas->add(a);
        auto b = Shape::gen();
        b->appendRect(110, 30, 70, 90, 8, 8);
        b->strokeWidth(5);
        b->strokeFill(20, 100, 200);
        float pat[2] = {10, 5};
        b->strokeDash(pat, 2, 0);
        b->trimpath(0.8f, 0.3f, true);
        canvas->add(b);
        return true;
    } else if (kind == "clip") {
        auto s = Shape::gen();
        s->appendRect(10, 10, 180, 130);
        auto g = LinearGradient::gen();
        g->linear(10, 10, 190, 140);
        Fill::ColorStop st[2] = {{0.0f, 255, 80, 0, 255}, {1.0f, 0, 80, 255, 255}};
        g->colorStops(st, 2);
        s->fill(g);
        auto c = Shape::gen();
        c->appendCircle(70, 70, 40, 40);
        c->appendRect(90, 50, 60, 60);
        c->rotate(20);
        s->clip(c);
        canvas->add(s);
        auto sc = Scene::gen();
        auto a = Shape::gen();
        a->appendRect(120, 90, 70, 50);
        a->fill(30, 160, 60);
        auto in = Shape::gen();
        in->appendCircle(150, 115, 30, 30);
        in->fill(250, 250, 40, 200);
        auto ic = Shape::gen();
        ic->appendRect(140, 100, 50, 50);
        in->clip(ic);
        sc->add(a);
        sc->add(in);
        sc->opacity(200);
        auto oc = Shape::gen();
        oc->appendCircle(155, 105, 35, 30);
        sc->clip(oc);
        canvas->add(sc);
        return true;
    } else if (kind == "nest") {
        auto outer = Scene::gen();
        auto inner = Scene::gen();
        auto a = Shape::gen();
        a->appendCircle(80, 75, 40, 40);
        a->fill(255, 0, 0);
        auto b = Shape::gen();
        b->appendCircle(110, 75, 40, 40);
        b->fill(0, 0, 255);
        inner->add(a);
        inner->add(b);
        inner->opacity(128);
        auto d = Shape::gen();
        d->appendRect(60, 90, 90, 30);
        d->fill(0, 200, 0);
        outer->add(inner);
        outer->add(d);
        outer->opacity(200);
        if (arg == "mask") {
            auto m = Shape::gen();
            m->appendCircle(95, 75, 55, 40);
            m->fill(0, 0, 0, 255);
            outer->mask(m, MaskMethod::Alpha);
        }
        canvas->add(glxBase());
        canvas->add(outer);
        return true;
    }
    fprintf(stderr, "unknown glx scene %s\n", name.c_str());
    return false;
}

// renders `scene` into `out` (premultiplied ARGB, top row first); `raw` = RGBA bytes bottom row first
#include <chrono>
#include <algorithm>
static int gRepeat = 0;
static bool renderGl(const std::string& scene, uint32_t W, uint32_t H, std::vector<uint32_t>& out, std::vector<uint8_t>& raw)
{
    GlEnv e;
    if (!createContext(e)) { fprintf(stderr, "context failed\n"); return false; }
    if (!createFbo(e, W, H)) { fprintf(stderr, "fbo incomplete\n"); return false; }
    ((PFNVIEWPORT)glfn("glViewport"))(0, 0, W, H);
    ((PFNCLEARCOLOR)glfn("glClearColor"))(0, 0, 0, 0); ((PFNCLEARSTENCIL)glfn("glClearStencil"))(0);
    ((PFNCLEAR)glfn("glClear"))(0x4000 | 0x400 | 0x100);

    auto canvas = GlCanvas::gen();
    if (!canvas) { fprintf(stderr, "GlCanvas::gen failed\n"); return false; }
    if (canvas->target(nullptr, e.dc, e.rc, (int32_t)e.fbo, W, H, ColorSpace::ABGR8888S) != Result::Success) {
        fprintf(stderr, "target failed\n"); return false;
    }
    bool ok = false;
    if (scene == "shapes") ok = buildShapes(canvas, "");
    else if (scene.rfind("shapes:", 0) == 0) ok = buildShapes(canvas, scene.substr(7));
    else if (scene.rfind("svg:", 0) == 0) ok = fitPicture(canvas, scene.substr(4), W, H, true);
    else if (scene.rfind("png:", 0) == 0) ok = fitPicture(canvas, scene.substr(4), W, H, false);
    else if (scene.rfind("jpg:", 0) == 0) ok = fitPicture(canvas, scene.substr(4), W, H, false);
    else if (scene.rfind("webp:", 0) == 0) ok = fitPicture(canvas, scene.substr(5), W, H, false);
    else if (scene.rfind("gif:", 0) == 0) ok = gifPicture(canvas, scene.substr(4), W, H);
    else if (scene.rfind("pngrot:", 0) == 0) ok = rotPicture(canvas, scene.substr(7), W, H);
    else if (scene.rfind("glx:", 0) == 0) ok = buildGlx(canvas, scene.substr(4));
    else if (scene == "text") ok = buildText(canvas, "C:\\Windows\\Fonts\\arial.ttf");
    else if (scene.rfind("text:", 0) == 0) ok = buildText(canvas, scene.substr(5));
    else fprintf(stderr, "unknown scene %s\n", scene.c_str());
    if (!ok) { delete canvas; return false; }
    if (canvas->update() != Result::Success) { fprintf(stderr, "update failed\n"); return false; }
    if (canvas->draw(true) != Result::Success) { fprintf(stderr, "draw failed\n"); return false; }
    if (canvas->sync() != Result::Success) { fprintf(stderr, "sync failed\n"); return false; }
    {   // verifier bench: per-frame time (touch opacity of top-level paints -> update + draw + sync + glFinish)
        auto fin = (void(__stdcall*)())glfn("glFinish");
        auto now = []{ return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); };
        std::vector<double> ts;
        for (int f = 0; f < gRepeat; ++f) {
            double t0 = now();
            for (auto p : canvas->paints()) p->opacity((f & 1) ? 254 : 255);
            canvas->update(); canvas->draw(true); canvas->sync(); fin();
            ts.push_back(now() - t0);
        }
        if (!ts.empty()) {
            std::vector<double> s(ts.begin() + (ts.size() > 3 ? 3 : 0), ts.end());
            std::sort(s.begin(), s.end());
            double sum = 0; for (double v : s) sum += v;
            fprintf(stderr, "BENCH frames=%zu first_ms=%.3f median_ms=%.3f mean_ms=%.3f min_ms=%.3f\n", ts.size(), ts[0], s[s.size() / 2], sum / s.size(), s[0]);
        }
    }

    auto bind = (PFNBIND)glfn("glBindFramebuffer");
    bind(GL_FRAMEBUFFER, e.fbo);
    raw.assign((size_t)W * H * 4, 0);
    ((PFNPIXELSTOREI)glfn("glPixelStorei"))(0x0D05, 1);
    ((PFNREADPIXELS)glfn("glReadPixels"))(0, 0, W, H, 0x1908, 0x1401, raw.data());
    out.assign((size_t)W * H, 0);
    for (uint32_t y = 0; y < H; ++y) {
        const uint8_t* s = &raw[(size_t)(H - 1 - y) * W * 4];   // GL origin is bottom-left
        for (uint32_t x = 0; x < W; ++x, s += 4)
            out[(size_t)y * W + x] = ((uint32_t)s[3] << 24) | ((uint32_t)s[0] << 16) | ((uint32_t)s[1] << 8) | s[2];
    }
    delete canvas;   // releases GL objects while the context is still current
    wglMakeCurrent(nullptr, nullptr);
    wglDeleteContext(e.rc);
    return true;
}

int main(int argc, char** argv)
{
    if (argc < 4) { fprintf(stderr, "usage: %s <scene> <w> <h> [--dump <prefix>] [--repeat N]\n", argv[0]); return 2; }
    std::string scene = argv[1];
    uint32_t W = 0, H = 0;
    if (!parseSize(argv[2], W) || !parseSize(argv[3], H)) { fprintf(stderr, "bad size\n"); return 2; }
    std::string dump;
    for (int i = 4; i < argc; ++i) {
        if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump = argv[++i];
        else if (!strcmp(argv[i], "--repeat") && i + 1 < argc) gRepeat = atoi(argv[++i]);   // accepted, ignored (one context per process)
        else { fprintf(stderr, "bad argument %s\n", argv[i]); return 2; }
    }
    if (Initializer::init(0) != Result::Success) { fprintf(stderr, "init failed\n"); return 2; }
    std::vector<uint32_t> buf; std::vector<uint8_t> raw;
    bool ok = renderGl(scene, W, H, buf, raw);
    Initializer::term();
    if (!ok) return 2;

    uint64_t h = 1469598103934665603ULL, nonzero = 0, opaque = 0;
    for (size_t i = 0; i < buf.size(); ++i) {
        uint32_t p = buf[i];
        for (int k = 0; k < 4; ++k) { h ^= (uint8_t)(p >> (8 * k)); h *= 1099511628211ULL; }
        if (p) ++nonzero;
        if ((p >> 24) == 255) ++opaque;
    }
    printf("scene=%s size=%ux%u fnv1a64=%016llx nonzero=%llu opaque=%llu\n", scene.c_str(), W, H,
           (unsigned long long)h, (unsigned long long)nonzero, (unsigned long long)opaque);
    if (!dump.empty()) {
        FILE* f = fopen((dump + ".argb").c_str(), "wb");
        if (!f) return 2;
        fwrite(buf.data(), 4, buf.size(), f); fclose(f);
        f = fopen((dump + ".rgba").c_str(), "wb");
        if (!f) return 2;
        fwrite(raw.data(), 1, raw.size(), f); fclose(f);
        f = fopen((dump + ".ppm").c_str(), "wb");
        if (!f) return 2;
        fprintf(f, "P6\n%u %u\n255\n", W, H);
        std::vector<uint8_t> rgb(buf.size() * 3);
        for (size_t i = 0; i < buf.size(); ++i) {
            uint32_t p = buf[i], a = p >> 24;
            uint32_t c[3] = {((p >> 16) & 0xff) + (255 - a), ((p >> 8) & 0xff) + (255 - a), (p & 0xff) + (255 - a)};
            for (int k = 0; k < 3; ++k) rgb[i * 3 + k] = (uint8_t)(c[k] > 255 ? 255 : c[k]);
        }
        fwrite(rgb.data(), 1, rgb.size(), f); fclose(f);
    }
    return 0;
}


