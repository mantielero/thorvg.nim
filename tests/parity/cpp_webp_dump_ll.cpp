// Dumps the output of the ORIGINAL ThorVG WebP decoder (WebPDecodeBGRA / WebPDecodeRGBA) for
// lossless (VP8L) files, called on the WHOLE RIFF file exactly like tvgWebpLoader.cpp does.
//
// Usage: cpp_webp_dump_ll <in.webp> <out.bin> [rgba]
//
// Output: int32 width, int32 height (both 0 on failure) followed by width*height
// little-endian 32-bit words (memory bytes B,G,R,A, or R,G,B,A with `rgba`); the pixels are
// premultiplied as ThorVG's static loader requests.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include "webp/decode.h"

int main(int argc, char** argv)
{
    if (argc < 3) return 2;
    FILE* in = fopen(argv[1], "rb");
    if (!in) return 2;
    std::vector<uint8_t> file;
    uint8_t chunk[65536];
    size_t n;
    while ((n = fread(chunk, 1, sizeof(chunk), in)) > 0) file.insert(file.end(), chunk, chunk + n);
    fclose(in);

    int w = 0, h = 0;
    const bool rgba = argc > 3 && !strcmp(argv[3], "rgba");
    uint8_t* px = rgba ? WebPDecodeRGBA(file.data(), file.size(), &w, &h)
                       : WebPDecodeBGRA(file.data(), file.size(), &w, &h);
    FILE* out = fopen(argv[2], "wb");
    if (!out) return 2;
    if (!px) { w = 0; h = 0; }
    int32_t hdr[2] = {w, h};
    fwrite(hdr, 4, 2, out);
    if (px) fwrite(px, 4, (size_t)w * h, out);
    fclose(out);
    return 0;
}
