#define private public
#define protected public
#include <thorvg.h>
#include <thorvg_lottie.h>
#include "tvgPicture.h"
#include "tvgLoader.h"
#include "tvgLottieLoader.h"
#include "tvgLottieModel.h"
#include "tvgLottieBuilder.h"
#include "tvgLottieProperty.h"
#include "tvgPaint.h"
#undef private
#undef protected

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <algorithm>
#include <memory>
#include <cmath>

namespace fs = std::filesystem;
using namespace tvg;

static bool writePPM(const std::string& path, const uint32_t* buf, uint32_t w, uint32_t h) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f << "P6\n" << w << " " << h << "\n255\n";
    for (uint32_t i = 0; i < w * h; ++i) {
        uint32_t px = buf[i]; // ARGB8888
        uint8_t a = (px >> 24) & 0xFF;
        uint8_t r = (px >> 16) & 0xFF;
        uint8_t g = (px >> 8) & 0xFF;
        uint8_t b = px & 0xFF;
        if (a > 0 && a < 255) {
            r = (uint8_t)std::min(255, (r * 255 + a / 2) / a);
            g = (uint8_t)std::min(255, (g * 255 + a / 2) / a);
            b = (uint8_t)std::min(255, (b * 255 + a / 2) / a);
        } else if (a == 0) { r = g = b = 0; }
        f.put((char)r); f.put((char)g); f.put((char)b);
    }
    return true;
}

static void writeRaw(const std::string& path, const uint32_t* buf, uint32_t w, uint32_t h) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return;
    f.write((const char*)buf, w * h * 4);
}

struct Case { std::string name; std::string file; uint32_t w; uint32_t h; std::vector<float> frames; };

static LottieLoader* getLoader(Animation* anim) {
    auto pic = anim->picture();
    if (!pic) return nullptr;
    // Picture::Impl is internal; use PP macro from tvgPicture.h
    auto impl = static_cast<PictureImpl*>(pic);
    if (!impl || !impl->loader) return nullptr;
    if (impl->loader->type != FileType::Lot) return nullptr;
    return static_cast<LottieLoader*>(impl->loader);
}

static void dumpLayerProps(std::ofstream& out, LottieLayer* layer, float frameNo, LottieExpressions* exps, int indent, bool& first) {
    if (!layer) return;
    if (!first) out << ",\n";
    first = false;
    std::string pad(indent, ' ');
    std::string pad2(indent+2, ' ');
    out << pad << "{\n";
    out << pad2 << "\"name\": \"" << (layer->name ? layer->name : "") << "\",\n";
    out << pad2 << "\"id\": " << layer->id << ",\n";
    out << pad2 << "\"type\": " << (int)layer->type << ",\n";
    if (layer->transform) {
        auto t = layer->transform;
        auto pos = t->position(frameNo, exps);
        auto scale = t->scale(frameNo, exps);
        auto rot = t->rotation(frameNo, exps);
        auto op = t->opacity(frameNo, exps);
        out << pad2 << "\"pos\": [" << pos.x << ", " << pos.y << "],\n";
        out << pad2 << "\"scale\": [" << scale.x << ", " << scale.y << "],\n";
        out << pad2 << "\"rotation\": " << rot << ",\n";
        out << pad2 << "\"opacity\": " << (float)op << "\n";
    } else {
        out << pad2 << "\"pos\": [0,0],\n";
        out << pad2 << "\"scale\": [100,100],\n";
        out << pad2 << "\"rotation\": 0,\n";
        out << pad2 << "\"opacity\": 255\n";
    }
    out << pad << "}";
}

static void collectLayers(LottieGroup* g, std::vector<LottieLayer*>& out) {
    if (!g) return;
    for (auto child : g->children) {
        if (!child) continue;
        if (child->type == LottieObject::Layer) {
            auto layer = static_cast<LottieLayer*>(child);
            out.push_back(layer);
            // recurse into precomp? maybe not for phase 0
        } else if (child->type == LottieObject::Group || child->type == LottieObject::Composition) {
            collectLayers(static_cast<LottieGroup*>(child), out);
        }
    }
}

int main(int argc, char** argv) {
    std::string outRoot = "tests/lottie/golden";
    std::string resDir = "upstream/test/res";
    if (argc > 1) outRoot = argv[1];
    if (argc > 2) resDir = argv[2];

    if (Initializer::init(0) != Result::Success) {
        fprintf(stderr, "init failed\n"); return 1;
    }

    std::vector<Case> cases = {
        {"test", resDir + "/test.lot", 500, 500, {}},
        {"test2", resDir + "/test2.lot", 500, 500, {}},
        {"test3", resDir + "/test3.lot", 500, 500, {}},
        {"test4", resDir + "/test4.lot", 500, 500, {}},
        {"test5", resDir + "/test5.lot", 500, 500, {}},
        {"test6", resDir + "/test6.lot", 500, 500, {}},
        {"test7", resDir + "/test7.lot", 500, 500, {}},
        {"test8", resDir + "/test8.lot", 500, 500, {}},
        {"test9", resDir + "/test9.lot", 500, 500, {}},
        {"test10", resDir + "/test10.lot", 500, 500, {}},
        {"test11", resDir + "/test11.lot", 500, 500, {}},
        {"test12", resDir + "/test12.lot", 500, 500, {}},
        {"test13", resDir + "/test13.lot", 500, 500, {}},
        {"test14", resDir + "/test14.lot", 500, 500, {}},
        {"embedded_font", resDir + "/embedded_font.lot", 500, 500, {}},
        {"segment", resDir + "/segment.lot", 500, 500, {}},
        {"slot", resDir + "/slot.lot", 500, 500, {}},
        {"tween", resDir + "/tween.lot", 500, 500, {}},
        {"audio_layer", resDir + "/audio_layer.json", 500, 500, {}},
    };

    std::ofstream manifest(outRoot + "/manifest.json");
    manifest << "{\n  \"cases\": [\n";

    bool firstCase = true;
    for (auto& c : cases) {
        fs::create_directories(outRoot + "/" + c.name);
        float total = 0, dur = 0;
        {
            auto anim = std::unique_ptr<LottieAnimation>(LottieAnimation::gen());
            auto picture = anim->picture();
            auto res = picture->load(c.file.c_str());
            if (res != Result::Success) { fprintf(stderr, "load failed: %s (%d)\n", c.file.c_str(), (int)res); continue; }
            picture->size((float)c.w, (float)c.h);
            auto cv = std::unique_ptr<SwCanvas>(SwCanvas::gen());
            std::vector<uint32_t> b(c.w * c.h, 0);
            cv->target(b.data(), c.w, c.w, c.h, ColorSpace::ARGB8888);
            cv->add(picture); cv->draw(); cv->sync();
            total = anim->totalFrame(); dur = anim->duration();
        }
        c.frames = {0.0f, total * 0.25f, total * 0.5f, total * 0.75f, std::max(0.0f, total - 1.0f)};
        std::sort(c.frames.begin(), c.frames.end());
        c.frames.erase(std::unique(c.frames.begin(), c.frames.end(), [&](float a, float b){ return std::fabs(a-b) < 0.001f; }), c.frames.end());

        if (!firstCase) manifest << ",\n";
        firstCase = false;
        manifest << "    {\n";
        manifest << "      \"name\": \"" << c.name << "\",\n";
        manifest << "      \"file\": \"" << c.file << "\",\n";
        manifest << "      \"w\": " << c.w << ", \"h\": " << c.h << ",\n";
        manifest << "      \"totalFrame\": " << total << ",\n";
        manifest << "      \"duration\": " << dur << ",\n";
        manifest << "      \"frames\": [\n";

        bool firstFrame = true;
        for (float fno : c.frames) {
            auto anim = std::unique_ptr<LottieAnimation>(LottieAnimation::gen());
            auto picture = anim->picture();
            auto res = picture->load(c.file.c_str());
            if (res != Result::Success) { fprintf(stderr, "load failed: %s\n", c.file.c_str()); continue; }
            picture->size((float)c.w, (float)c.h);
            anim->frame(fno);
            auto canvas = std::unique_ptr<SwCanvas>(SwCanvas::gen());
            std::vector<uint32_t> buf(c.w * c.h, 0);
            canvas->target(buf.data(), c.w, c.w, c.h, ColorSpace::ARGB8888);
            canvas->add(picture);
            canvas->draw();
            canvas->sync();

            char fnb[64]; snprintf(fnb, sizeof(fnb), "%06.2f", fno);
            std::string base = outRoot + "/" + c.name + "/frame_" + fnb;
            writePPM(base + ".ppm", buf.data(), c.w, c.h);
            writeRaw(base + ".rgba", buf.data(), c.w, c.h);

            auto loader = getLoader(anim.get());
            LottieComposition* fcomp = loader ? loader->comp : nullptr;
            LottieExpressions* fexps = loader ? loader->builder.exps : nullptr;
            std::string propsPath = base + ".props.json";
            std::ofstream pf(propsPath);
            pf << "{\n  \"frame\": " << fno << ",\n  \"layers\": [\n";
            std::vector<LottieLayer*> layers;
            if (fcomp && fcomp->root) collectLayers(fcomp->root, layers);
            bool firstL = true;
            for (auto* l : layers) { if (!l) continue; dumpLayerProps(pf, l, fno, fexps, 4, firstL); }
            pf << "\n  ]\n}\n";
            pf.close();

            if (!firstFrame) manifest << ",\n";
            firstFrame = false;
            manifest << "        {\n";
            manifest << "          \"frame\": " << fno << ",\n";
            manifest << "          \"ppm\": \"" << c.name << "/frame_" << fnb << ".ppm\",\n";
            manifest << "          \"rgba\": \"" << c.name << "/frame_" << fnb << ".rgba\",\n";
            manifest << "          \"props\": \"" << c.name << "/frame_" << fnb << ".props.json\"\n";
            manifest << "        }";
            printf("ok %s frame %.2f layers=%zu\n", c.name.c_str(), fno, layers.size());
        }
        manifest << "\n      ]\n    }";
    }
    manifest << "\n  ]\n}\n";
    manifest.close();

    Initializer::term();
    return 0;
}
