#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include <fstream>
#include <memory>
#include <cmath>
#include <algorithm>
#include <filesystem>
#define private public
#define protected public
#include <thorvg.h>
#include "tvgLottieModel.h"
#include "tvgLottieProperty.h"
#include "tvgLottieLoader.h"
#include "tvgPicture.h"
#include "tvgLottieBuilder.h"
#undef private
#undef protected

namespace fs = std::filesystem;
using namespace tvg;

static LottieLoader* getLoader(Animation* anim) {
    auto pic = anim->picture();
    if (!pic) return nullptr;
    auto impl = static_cast<PictureImpl*>(pic);
    if (!impl || !impl->loader) return nullptr;
    if (impl->loader->type != FileType::Lot) return nullptr;
    return static_cast<LottieLoader*>(impl->loader);
}

static void collectLayers(LottieGroup* g, std::vector<LottieLayer*>& out) {
    if (!g) return;
    for (auto child : g->children) {
        if (!child) continue;
        if (child->type == LottieObject::Layer) {
            auto layer = static_cast<LottieLayer*>(child);
            out.push_back(layer);
            collectLayers(static_cast<LottieGroup*>(layer), out);
        } else if (child->type == LottieObject::Group || child->type == LottieObject::Composition) {
            collectLayers(static_cast<LottieGroup*>(child), out);
        }
    }
}

static void dumpProp(std::ofstream& out, bool& first, const char* layerName, int layerId, const char* prop, float frameNo, const std::vector<float>& vals) {
    if (!first) out << "\n";
    first = false;
    out << "{\"layer\":\"" << (layerName?layerName:"") << "\",\"id\":" << layerId << ",\"prop\":\"" << prop << "\",\"frame\":" << frameNo << ",\"value\":[";
    for (size_t i=0;i<vals.size();++i) { if(i) out<<","; char b[64]; snprintf(b,sizeof(b),"%.9g",(double)vals[i]); out<<b; }
    out << "]}";
}

static void dumpFrame(std::ofstream& out, bool& first, Animation* anim, LottieLoader* loader, float fno, uint32_t W, uint32_t H) {
    anim->frame(fno);
    auto picture = anim->picture();
    auto canvas = std::unique_ptr<SwCanvas>(SwCanvas::gen());
    std::vector<uint32_t> buf(W*H,0);
    canvas->target(buf.data(), W, W, H, ColorSpace::ARGB8888);
    canvas->add(picture); canvas->draw(); canvas->sync();

    LottieComposition* comp = loader ? loader->comp : nullptr;
    LottieExpressions* exps = loader ? loader->builder.exps : nullptr;
    std::vector<LottieLayer*> layers;
    if (comp && comp->root) collectLayers(comp->root, layers);
    for (auto* layer : layers) {
        if (!layer || !layer->transform) continue;
        auto t = layer->transform;
        auto nm = layer->name ? layer->name : "";
        if (t->rotation.exp) {
            auto v = t->rotation(fno, exps);
            dumpProp(out, first, nm, layer->id, "ks.r", fno, {v});
        }
        if (t->position.exp) {
            auto v = t->position(fno, exps);
            dumpProp(out, first, nm, layer->id, "ks.p", fno, {v.x, v.y});
        }
        if (t->scale.exp) {
            auto v = t->scale(fno, exps);
            dumpProp(out, first, nm, layer->id, "ks.s", fno, {v.x, v.y});
        }
        if (t->anchor.exp) {
            auto v = t->anchor(fno, exps);
            dumpProp(out, first, nm, layer->id, "ks.a", fno, {v.x, v.y});
        }
        if (t->opacity.exp) {
            auto v = t->opacity(fno, exps);
            dumpProp(out, first, nm, layer->id, "ks.o", fno, {(float)v});
        }
    }
}

int main(int argc, char** argv){
    bool reuse = false;
    int argi = 1;
    if (argi < argc && std::string(argv[argi]) == "--reuse") { reuse = true; ++argi; }
    if (argc - argi < 4) { fprintf(stderr,"usage: %s [--reuse] in w h out.jsonl [frames...]\n",argv[0]); return 2; }
    std::string in=argv[argi++]; uint32_t W=atoi(argv[argi++]), H=atoi(argv[argi++]); std::string outPath=argv[argi++];
    std::vector<float> frames;
    for (int i=argi;i<argc;i++) frames.push_back((float)atof(argv[i]));
    if (Initializer::init(0) != Result::Success) { fprintf(stderr,"init fail\n"); return 1; }
    if (frames.empty()) {
        auto anim = std::unique_ptr<Animation>(Animation::gen());
        auto picture = anim->picture();
        if (picture->load(in.c_str()) != Result::Success) { fprintf(stderr,"load fail\n"); return 1; }
        picture->size((float)W,(float)H);
        float total = anim->totalFrame();
        frames = {0.f, total*0.25f, total*0.5f, total*0.75f, std::max(0.f,total-1.f)};
    }
    std::ofstream out(outPath);
    bool first = true;
    if (reuse) {
        auto anim = std::unique_ptr<Animation>(Animation::gen());
        auto picture = anim->picture();
        if (picture->load(in.c_str()) != Result::Success) { fprintf(stderr,"load fail %s\n",in.c_str()); return 1; }
        picture->size((float)W,(float)H);
        auto loader = getLoader(anim.get());
        for (float fno : frames) dumpFrame(out, first, anim.get(), loader, fno, W, H);
    } else {
        for (float fno : frames) {
            auto anim = std::unique_ptr<Animation>(Animation::gen());
            auto picture = anim->picture();
            if (picture->load(in.c_str()) != Result::Success) { fprintf(stderr,"load fail %s\n",in.c_str()); return 1; }
            picture->size((float)W,(float)H);
            dumpFrame(out, first, anim.get(), getLoader(anim.get()), fno, W, H);
        }
    }
    out << "\n";
    Initializer::term();
    return 0;
}
