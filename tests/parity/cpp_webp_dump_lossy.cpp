// Dumps the output of the ORIGINAL ThorVG WebP lossy decoder (WebPDecodeBGRA / WebPDecodeRGBA).
//
// Usage: cpp_webp_dump_lossy <in.webp> <out.bin> [rgba]
//
// The input is a RIFF/WebP file; the decoder is given the bare VP8 bitstream, i.e. the
// payload of the first 'VP8 ' chunk up to the END of the file (that is what the upstream
// decoder uses internally), so that files carrying an ALPH chunk can be compared without
// the alpha plane. Output: int32 width, int32 height (both 0 on failure) followed by
// width*height little-endian 32-bit words (memory bytes B,G,R,A, or R,G,B,A with `rgba`).
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include "webp/decode.h"

static long vp8Payload(const std::vector<uint8_t>& f)
{
    if (f.size() < 12 || memcmp(f.data(), "RIFF", 4) || memcmp(f.data() + 8, "WEBP", 4)) return -1;
    size_t pos = 12;
    while (pos + 8 <= f.size()) {
        uint32_t sz = f[pos + 4] | (f[pos + 5] << 8) | (f[pos + 6] << 16) | ((uint32_t)f[pos + 7] << 24);
        if (!memcmp(f.data() + pos, "VP8 ", 4)) return (long)(pos + 8);
        size_t next = pos + 8 + (size_t)sz + (sz & 1);
        if (next <= pos) return -1;
        pos = next;
    }
    return -1;
}

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
    uint8_t* px = nullptr;
    long off = vp8Payload(file);
    if (off >= 0 && (size_t)off <= file.size()) {
        const uint8_t* d = file.data() + off;
        size_t size = file.size() - off;
        px = (argc > 3 && !strcmp(argv[3], "rgba")) ? WebPDecodeRGBA(d, size, &w, &h)
                                                     : WebPDecodeBGRA(d, size, &w, &h);
    }
    FILE* out = fopen(argv[2], "wb");
    if (!out) return 2;
    if (!px) { w = 0; h = 0; }
    int32_t hdr[2] = {w, h};
    fwrite(hdr, 4, 2, out);
    if (px) fwrite(px, 4, (size_t)w * h, out);
    fclose(out);
    return 0;
}
