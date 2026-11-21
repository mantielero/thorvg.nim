// Parity driver for the ORIGINAL ThorVG (C++) software engine.
//
// usage: cpp_driver <scene> <width> <height> [--dump <prefix>] [--repeat N]
//   scene:  gif:<file.gif>:<frame>[,<frame>...] | shapes | shapes:<part> | svg:<file.svg> | png:<file.png> | webp:<file.webp> | pngrot:<file.png>[@deg,scale,shear,opacity] | text | text:<file.ttf>
//   Renders into a ColorSpace::ARGB8888 (premultiplied) buffer that starts as all zero (transparent).
//   --dump <prefix>  writes <prefix>.argb (w*h little-endian uint32, premultiplied ARGB, no header)
//                    and <prefix>.ppm (P6, the image composited over white).
//   stdout (one line, used by parity.ps1):
//     scene=<s> size=<w>x<h> fnv1a64=<16 hex> nonzero=<n> opaque=<n>
//   exit code: 0 ok, 2 bad usage / load or render failure (message on stderr)
//
// The Nim port must ship an equivalent driver (same arguments, same scene definitions, same stdout line).
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <string>
#include <vector>
#include <thorvg.h>

using namespace tvg;

static const float PI = 3.14159265358979323846f;

//---------------------------------------------------------------------------------------------
// Scene parts. Design canvas = 400x300; each part sits in its own region.
//---------------------------------------------------------------------------------------------
static Shape* part_rect()
{
    auto s = Shape::gen();
    s->appendRect(10, 10, 80, 80);
    s->fill(220, 60, 40);
    return s;
}

static Shape* part_roundrect()
{
    auto s = Shape::gen();
    s->appendRect(110, 10, 80, 80, 15, 25);
    s->fill(40, 120, 220, 200);
    s->strokeWidth(3);
    s->strokeFill(10, 10, 10);
    return s;
}

static Shape* part_ellipse()
{
    auto s = Shape::gen();
    s->appendCircle(240, 50, 40, 30);
    s->fill(60, 180, 90);
    return s;
}

static Shape* part_star_nonzero()
{
    auto s = Shape::gen();
    const float cx = 345, cy = 50, r = 40;
    for (int i = 0; i < 5; ++i) {
        float a = -PI / 2 + i * 4 * PI / 5;
        float x = cx + r * cosf(a), y = cy + r * sinf(a);
        if (i == 0) s->moveTo(x, y); else s->lineTo(x, y);
    }
    s->close();
    s->fill(250, 190, 20);
    s->fillRule(FillRule::NonZero);
    return s;
}

static Shape* part_star_evenodd()
{
    auto s = Shape::gen();
    const float cx = 385, cy = 80, r = 14;
    for (int i = 0; i < 5; ++i) {
        float a = -PI / 2 + i * 4 * PI / 5;
        float x = cx + r * cosf(a), y = cy + r * sinf(a);
        if (i == 0) s->moveTo(x, y); else s->lineTo(x, y);
    }
    s->close();
    s->fill(150, 40, 200);
    s->fillRule(FillRule::EvenOdd);
    return s;
}

static Shape* part_lingrad()
{
    auto s = Shape::gen();
    s->appendRect(10, 110, 80, 80, 8, 8);
    auto g = LinearGradient::gen();
    g->linear(10, 110, 90, 190);
    Fill::ColorStop st[3] = {{0.0f, 255, 0, 0, 255}, {0.5f, 255, 255, 0, 255}, {1.0f, 0, 0, 255, 128}};
    g->colorStops(st, 3);
    s->fill(g);
    return s;
}

static Shape* part_radgrad()
{
    auto s = Shape::gen();
    s->appendCircle(150, 150, 40, 40);
    auto g = RadialGradient::gen();
    g->radial(150, 150, 40, 135, 140, 0);
    Fill::ColorStop st[2] = {{0.0f, 255, 255, 255, 255}, {1.0f, 20, 40, 160, 255}};
    g->colorStops(st, 2);
    s->fill(g);
    return s;
}

static Shape* part_spread_reflect()
{
    auto s = Shape::gen();
    s->appendRect(210, 110, 80, 36);
    auto g = LinearGradient::gen();
    g->linear(220, 0, 250, 0);
    Fill::ColorStop st[2] = {{0.0f, 255, 80, 0, 255}, {1.0f, 0, 80, 255, 255}};
    g->colorStops(st, 2);
    g->spread(FillSpread::Reflect);
    s->fill(g);
    return s;
}

static Shape* part_spread_repeat()
{
    auto s = Shape::gen();
    s->appendRect(210, 154, 80, 36);
    auto g = LinearGradient::gen();
    g->linear(220, 0, 250, 0);
    Fill::ColorStop st[2] = {{0.0f, 255, 80, 0, 255}, {1.0f, 0, 80, 255, 255}};
    g->colorStops(st, 2);
    g->spread(FillSpread::Repeat);
    s->fill(g);
    return s;
}

static Shape* part_gradstroke()
{
    auto s = Shape::gen();
    s->appendCircle(345, 150, 30, 30);
    s->strokeWidth(14);
    auto g = RadialGradient::gen();
    g->radial(345, 150, 44, 345, 150, 0);
    Fill::ColorStop st[2] = {{0.6f, 255, 0, 0, 255}, {1.0f, 0, 0, 255, 255}};
    g->colorStops(st, 2);
    s->strokeFill(g);
    return s;
}

static void parts_caps(std::vector<Paint*>& out)
{
    const StrokeCap caps[3] = {StrokeCap::Butt, StrokeCap::Round, StrokeCap::Square};
    for (int i = 0; i < 3; ++i) {
        auto s = Shape::gen();
        s->moveTo(15, 215 + i * 25);
        s->lineTo(85, 215 + i * 25);
        s->strokeWidth(14);
        s->strokeFill(30, 30, 30);
        s->strokeCap(caps[i]);
        out.push_back(s);
    }
}

static void parts_joins(std::vector<Paint*>& out)
{
    const StrokeJoin joins[3] = {StrokeJoin::Miter, StrokeJoin::Round, StrokeJoin::Bevel};
    for (int i = 0; i < 3; ++i) {
        auto s = Shape::gen();
        float x = 110 + i * 30;
        s->moveTo(x, 270);
        s->lineTo(x + 12, 210);
        s->lineTo(x + 24, 270);
        s->strokeWidth(9);
        s->strokeFill(120, 30, 30);
        s->strokeJoin(joins[i]);
        s->strokeMiterlimit(4);
        out.push_back(s);
    }
}

static Shape* part_dash()
{
    auto s = Shape::gen();
    s->appendRect(205, 210, 80, 70, 10, 10);
    s->strokeWidth(5);
    s->strokeFill(0, 100, 100);
    float pat[2] = {12, 6};
    s->strokeDash(pat, 2, 3);
    s->strokeCap(StrokeCap::Round);
    return s;
}

static Shape* part_transform()
{
    auto s = Shape::gen();
    s->appendRect(-25, -15, 50, 30, 4, 4);
    s->fill(200, 100, 0);
    s->strokeWidth(2);
    s->strokeFill(0, 0, 0);
    s->translate(335, 230);
    s->rotate(30);
    s->scale(1.3f);
    return s;
}

static void parts_opacity(std::vector<Paint*>& out)
{
    auto a = Shape::gen();
    a->appendRect(300, 255, 40, 40);
    a->fill(255, 0, 0);
    auto b = Shape::gen();
    b->appendRect(320, 265, 40, 30);
    b->fill(0, 0, 255);
    b->opacity(128);
    out.push_back(a);
    out.push_back(b);
}

static Shape* part_clip(Paint*& dummy)
{
    auto s = Shape::gen();
    s->appendRect(10, 5, 100, 20);
    s->fill(0, 160, 0);
    auto c = Shape::gen();
    c->appendCircle(60, 15, 18, 18);
    s->clip(c);
    dummy = nullptr;
    return s;
}

static Shape* part_mask()
{
    auto s = Shape::gen();
    s->appendRect(120, 195, 70, 10);
    s->fill(200, 0, 200);
    auto m = Shape::gen();
    m->appendCircle(155, 200, 12, 12);
    m->fill(0, 0, 0, 255);
    s->mask(m, MaskMethod::Alpha);
    return s;
}

static void parts_blend(std::vector<Paint*>& out)
{
    auto a = Shape::gen();
    a->appendRect(300, 5, 40, 20);
    a->fill(250, 200, 100);
    auto b = Shape::gen();
    b->appendRect(320, 10, 40, 20);
    b->fill(100, 150, 250);
    b->blend(BlendMethod::Multiply);
    out.push_back(a);
    out.push_back(b);
}

static Scene* part_nested()
{
    auto sc = Scene::gen();
    auto a = Shape::gen();
    a->appendCircle(250, 245, 10, 10);
    a->fill(255, 0, 0);
    auto b = Shape::gen();
    b->appendCircle(258, 245, 10, 10);
    b->fill(0, 255, 0);
    sc->add(a);
    sc->add(b);
    sc->opacity(128);
    return sc;
}

static bool buildShapes(Canvas* canvas, const std::string& part)
{
    std::vector<std::pair<std::string, std::vector<Paint*>>> all;
    auto one = [&](const char* name, Paint* p) { all.push_back({name, {p}}); };
    Paint* d = nullptr;
    one("rect", part_rect());
    one("roundrect", part_roundrect());
    one("ellipse", part_ellipse());
    one("star_nonzero", part_star_nonzero());
    one("star_evenodd", part_star_evenodd());
    one("lingrad", part_lingrad());
    one("radgrad", part_radgrad());
    one("spread_reflect", part_spread_reflect());
    one("spread_repeat", part_spread_repeat());
    one("gradstroke", part_gradstroke());
    { std::vector<Paint*> v; parts_caps(v); all.push_back({"caps", v}); }
    { std::vector<Paint*> v; parts_joins(v); all.push_back({"joins", v}); }
    one("dash", part_dash());
    one("transform", part_transform());
    { std::vector<Paint*> v; parts_opacity(v); all.push_back({"opacity", v}); }
    one("clip", part_clip(d));
    one("mask", part_mask());
    { std::vector<Paint*> v; parts_blend(v); all.push_back({"blend", v}); }
    one("nested", part_nested());

    bool found = false;
    for (auto& e : all) {
        bool use = part.empty() || part == e.first;
        for (auto p : e.second) {
            if (use) canvas->add(p); else Paint::rel(p);
        }
        if (use) found = true;
    }
    return found;
}

//---------------------------------------------------------------------------------------------
static bool fitPicture(Canvas* canvas, const std::string& file, uint32_t W, uint32_t H, bool isSvg)
{
    auto pic = Picture::gen();
    if (pic->load(file.c_str()) != Result::Success) {
        fprintf(stderr, "cannot load %s\n", file.c_str());
        Paint::rel(pic);
        return false;
    }
    float w = 0, h = 0;
    pic->size(&w, &h);
    if (w <= 0 || h <= 0) {
        fprintf(stderr, "bad picture size %gx%g\n", w, h);
        Paint::rel(pic);
        return false;
    }
    // Scale to fit the canvas, keep aspect ratio, center.
    float scale = fminf((float)W / w, (float)H / h);
    float nw = w * scale, nh = h * scale;
    pic->size(nw, nh);
    pic->translate(((float)W - nw) * 0.5f, ((float)H - nh) * 0.5f);
    (void)isSvg;
    canvas->add(pic);
    return true;
}

// gif:<file>:<frames>: loads the GIF into an Animation, calls Animation::frame() for every number of the
// comma separated list in order (results ignored: an unchanged frame is InsufficientCondition), then fits
// the picture to the canvas like png:. Without ':<frames>' the first frame is shown.
static bool gifPicture(Canvas* canvas, const std::string& spec, uint32_t W, uint32_t H)
{
    std::string file = spec, frames = "0";
    auto colon = spec.rfind(':');
    if (colon != std::string::npos) {
        file = spec.substr(0, colon);
        frames = spec.substr(colon + 1);
    }
    auto anim = Animation::gen();
    auto pic = anim->picture();
    if (pic->load(file.c_str()) != Result::Success) {
        fprintf(stderr, "cannot load %s\n", file.c_str());
        return false;
    }
    float w = 0, h = 0;
    pic->size(&w, &h);
    if (w <= 0 || h <= 0) {
        fprintf(stderr, "bad picture size %gx%g\n", w, h);
        return false;
    }
    for (size_t pos = 0; pos <= frames.size();) {
        auto comma = frames.find(',', pos);
        if (comma == std::string::npos) comma = frames.size();
        anim->frame((float)atof(frames.substr(pos, comma - pos).c_str()));
        pos = comma + 1;
    }
    float scale = fminf((float)W / w, (float)H / h);
    float nw = w * scale, nh = h * scale;
    pic->size(nw, nh);
    pic->translate(((float)W - nw) * 0.5f, ((float)H - nh) * 0.5f);
    canvas->add(pic);
    return true;
}

// pngrot:<file>[@angle,scale,shear,opacity]: the picture at native size, mapped about the canvas
// center by M = T(c) * R(angle deg) * Shear(x += shear*y) * S(scale) * T(-size/2) (texmap path).
// Defaults: angle 30, scale 1, shear 0, opacity 255. The matrix is computed in double, then rounded to float.
static bool rotPicture(Canvas* canvas, const std::string& spec, uint32_t W, uint32_t H)
{
    std::string file = spec;
    double deg = 30, sc = 1, k = 0, op = 255;
    auto at = spec.rfind('@');
    if (at != std::string::npos) {
        file = spec.substr(0, at);
        sscanf(spec.c_str() + at + 1, "%lf,%lf,%lf,%lf", &deg, &sc, &k, &op);
    }
    auto pic = Picture::gen();
    if (pic->load(file.c_str()) != Result::Success) {
        fprintf(stderr, "cannot load %s\n", file.c_str());
        Paint::rel(pic);
        return false;
    }
    float w = 0, h = 0;
    pic->size(&w, &h);
    if (w <= 0 || h <= 0) {
        fprintf(stderr, "bad picture size %gx%g\n", w, h);
        Paint::rel(pic);
        return false;
    }
    const double a = deg * 3.14159265358979323846 / 180.0, c = cos(a), s = sin(a);
    const double e11 = sc * c, e12 = sc * (c * k - s), e21 = sc * s, e22 = sc * (s * k + c);
    const double hw = w * 0.5, hh = h * 0.5;
    Matrix m = {(float)e11, (float)e12, (float)(W * 0.5 - (e11 * hw + e12 * hh)),
                (float)e21, (float)e22, (float)(H * 0.5 - (e21 * hw + e22 * hh)), 0.0f, 0.0f, 1.0f};
    pic->transform(m);
    pic->opacity((uint8_t)op);
    canvas->add(pic);
    return true;
}

static bool buildText(Canvas* canvas, const std::string& font)
{
    if (Text::load(font.c_str()) != Result::Success) {
        fprintf(stderr, "cannot load font %s\n", font.c_str());
        return false;
    }
    struct Line { const char* txt; float size; float x, y; uint8_t r, g, b; };
    const Line lines[] = {
        {"Hello, ThorVG!", 40, 10, 10, 20, 20, 20},
        {"The quick brown fox jumps over the lazy dog 0123456789", 14, 10, 70, 160, 20, 20},
        {"AVATAR Wiggly gjpqy {}[]()&@#%", 24, 10, 100, 20, 80, 160},
        {"Rotated", 30, 250, 150, 0, 120, 0},
    };
    for (int i = 0; i < 4; ++i) {
        auto t = Text::gen();
        if (t->font(nullptr) != Result::Success) { fprintf(stderr, "font() failed\n"); return false; }
        t->size(lines[i].size);
        t->text(lines[i].txt);
        t->fill(lines[i].r, lines[i].g, lines[i].b);
        t->translate(lines[i].x, lines[i].y);
        if (i == 3) t->rotate(-20);
        canvas->add(t);
    }
    // gradient filled text + italic
    {
        auto t = Text::gen();
        t->font(nullptr);
        t->size(48);
        t->text("Gradient");
        t->italic();
        auto g = LinearGradient::gen();
        g->linear(0, 0, 200, 0);
        Fill::ColorStop st[2] = {{0.0f, 255, 0, 0, 255}, {1.0f, 0, 0, 255, 255}};
        g->colorStops(st, 2);
        t->fill(g);
        t->translate(10, 200);
        canvas->add(t);
    }
    return true;
}

//---------------------------------------------------------------------------------------------
static bool parseSize(const char* s, uint32_t& v)
{
    char* e = nullptr;
    long n = strtol(s, &e, 10);
    if (!e || *e || n <= 0 || n > 16384) return false;
    v = (uint32_t)n;
    return true;
}

static bool render(const std::string& scene, uint32_t W, uint32_t H, std::vector<uint32_t>& buf)
{
    std::fill(buf.begin(), buf.end(), 0u);
    auto canvas = SwCanvas::gen();
    if (canvas->target(buf.data(), W, W, H, ColorSpace::ARGB8888) != Result::Success) {
        fprintf(stderr, "target failed\n");
        return false;
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
    else if (scene == "text") ok = buildText(canvas, "C:\\Windows\\Fonts\\arial.ttf");
    else if (scene.rfind("text:", 0) == 0) ok = buildText(canvas, scene.substr(5));
    else fprintf(stderr, "unknown scene %s\n", scene.c_str());
    if (!ok) { delete canvas; return false; }
    if (canvas->update() != Result::Success) { fprintf(stderr, "update failed\n"); delete canvas; return false; }
    if (canvas->draw(true) != Result::Success) { fprintf(stderr, "draw failed\n"); delete canvas; return false; }
    if (canvas->sync() != Result::Success) { fprintf(stderr, "sync failed\n"); delete canvas; return false; }
    delete canvas;
    return true;
}

int main(int argc, char** argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s <scene> <w> <h> [--dump <prefix>] [--repeat N]\n", argv[0]);
        return 2;
    }
    std::string scene = argv[1];
    uint32_t W = 0, H = 0;
    if (!parseSize(argv[2], W) || !parseSize(argv[3], H)) { fprintf(stderr, "bad size\n"); return 2; }
    std::string dump;
    int repeat = 1;
    for (int i = 4; i < argc; ++i) {
        if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump = argv[++i];
        else if (!strcmp(argv[i], "--repeat") && i + 1 < argc) repeat = atoi(argv[++i]);
        else { fprintf(stderr, "bad argument %s\n", argv[i]); return 2; }
    }

    if (Initializer::init(0) != Result::Success) { fprintf(stderr, "init failed\n"); return 2; }
    std::vector<uint32_t> buf((size_t)W * H);
    bool ok = true;
    for (int r = 0; r < repeat && ok; ++r) ok = render(scene, W, H, buf);
    Initializer::term();
    if (!ok) return 2;

    uint64_t h = 1469598103934665603ULL;
    uint64_t nonzero = 0, opaque = 0;
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
        if (!f) { fprintf(stderr, "cannot write %s.argb\n", dump.c_str()); return 2; }
        fwrite(buf.data(), 4, buf.size(), f);
        fclose(f);
        f = fopen((dump + ".ppm").c_str(), "wb");
        if (!f) { fprintf(stderr, "cannot write %s.ppm\n", dump.c_str()); return 2; }
        fprintf(f, "P6\n%u %u\n255\n", W, H);
        std::vector<uint8_t> rgb(buf.size() * 3);
        for (size_t i = 0; i < buf.size(); ++i) {
            uint32_t p = buf[i];
            uint32_t a = p >> 24;
            uint32_t r = ((p >> 16) & 0xff) + (255 - a);
            uint32_t g = ((p >> 8) & 0xff) + (255 - a);
            uint32_t b = (p & 0xff) + (255 - a);
            rgb[i * 3 + 0] = (uint8_t)(r > 255 ? 255 : r);
            rgb[i * 3 + 1] = (uint8_t)(g > 255 ? 255 : g);
            rgb[i * 3 + 2] = (uint8_t)(b > 255 ? 255 : b);
        }
        fwrite(rgb.data(), 1, rgb.size(), f);
        fclose(f);
    }
    return 0;
}
