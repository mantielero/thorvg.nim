#include <thorvg.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <cmath>
#include <algorithm>

extern "C" void tvg_layout_dump_set(FILE* fp);

static std::vector<float> parseFrames(int argc, char** argv, int start) {
    std::vector<float> frames;
    for (int i = start; i < argc; ++i) frames.push_back(std::strtof(argv[i], nullptr));
    std::sort(frames.begin(), frames.end());
    frames.erase(std::unique(frames.begin(), frames.end(), [&](float a, float b){ return std::fabs(a-b) < 1e-5f; }), frames.end());
    return frames;
}

int main(int argc, char** argv) {
    if (argc < 5) {
        std::fprintf(stderr, "usage: dump_layout <file.lot> <w> <h> <out.jsonl> [frames...]\n");
        return 1;
    }
    const char* file = argv[1];
    int w = std::atoi(argv[2]);
    int h = std::atoi(argv[3]);
    const char* outPath = argv[4];
    auto frames = parseFrames(argc, argv, 5);

    tvg::Initializer::init(0);
    auto anim = tvg::Animation::gen();
    auto pic = anim->picture();
    if (pic->load(file) != tvg::Result::Success) {
        std::fprintf(stderr, "load failed: %s\n", file);
        tvg::Initializer::term();
        return 2;
    }
    pic->size((float)w, (float)h);

    if (frames.empty()) {
        float total = anim->totalFrame();
        frames = {0.0f, total * 0.25f, total * 0.5f, total * 0.75f, total - 1.0f};
        std::sort(frames.begin(), frames.end());
    }

    FILE* fp = std::fopen(outPath, "wb");
    if (!fp) { std::fprintf(stderr, "cannot open %s\n", outPath); tvg::Initializer::term(); return 3; }
    tvg_layout_dump_set(fp);

    auto canvas = tvg::SwCanvas::gen();
    std::vector<uint32_t> buf((size_t)w * (size_t)h, 0);
    canvas->target(buf.data(), w, w, h, tvg::ColorSpace::ARGB8888);
    canvas->add(pic);

    float total = anim->totalFrame();
    for (float fr : frames) {
        float f = fr;
        if (f < 0.0f) f = 0.0f;
        if (f > total - 1.0f) f = total - 1.0f;
        anim->frame(f);
        std::fill(buf.begin(), buf.end(), 0u);
        canvas->update();
        if (canvas->draw(true) != tvg::Result::Success) {
            std::fprintf(stderr, "draw failed at frame %f\n", f);
        }
        canvas->sync();
    }

    tvg_layout_dump_set(nullptr);
    std::fclose(fp);
    delete canvas;
    delete anim;
    tvg::Initializer::term();
    return 0;
}
