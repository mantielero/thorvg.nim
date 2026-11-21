# WebP test data

## Real files (this directory)

Copied unchanged from files found on this machine. Classified by RIFF chunk fourcc
(`ALPH(m,f)` = ALPH compression method / filter; every ALPH here is method 1 = lossless).

| file | origin | chunks |
|---|---|---|
| `acrobat_illu_theme_deepslate_dark.webp` | Adobe Acrobat DC `Acrobat\WebResources\SA\app1\dc-desktop-app-dropin\1.0.0_1.0.0` | VP8L 2049x1350 |
| `acrobat_illu_theme_softsage_light.webp` | same | VP8L 2049x1350 |
| `acrobat_illu_theme_mistblue_dark.webp` | same | VP8L 2049x1350 (160 bytes, flat) |
| `acrobat_illu_theme_warmivory_light.webp` | same | VP8L 2049x1350 (160 bytes, flat) |
| `acrobat_illu_theme_softsage_dark.webp`, `acrobat_illu_theme_warmtaupe_dark.webp` | same | VP8 (lossy, no container extension) |
| `acrobat_illu_theme_DeepBlue_lightmode_1366x900.webp` | same | VP8X, VP8, PSAI |
| `acrobat_caption-video`, `crop-video`, `firefly-boards`, `gen-fill-insert`, `generate-qr-code`, `generate-variation`, `logo-maker`, `remove-background` (`.webp`) | same | VP8X, ALPH(m1,f0), VP8 |
| `office_errorImage.webp` | Microsoft Office 16 `root\Office16\sdxs\FA000000194\OfflineFiles\errorImage.*.webp` | VP8X, ALPH(m1,f0), VP8 |
| `thorvg_test.webp` | `upstream/thorvg/test/res/test.webp` | VP8X, ICCP, VP8 |

Only the four `VP8L` files are inputs of the lossless decoder (unit L5c-A); the others are
for the lossy decoder (L5c-B) and the container / alpha plane (L5c-C).

## `gen/` (generated)

`gen/*.webp` are produced by `tests/parity/mkwebp_cases.nim` (own VP8L encoder,
`mkwebp_ll.nim` / `mkwebp_tf.nim`): every transform alone and chained, color cache,
palette packing 1/2/4/8 bits, backward references, meta prefix images with several Huffman
groups, simple / normal / repeat-coded Huffman descriptions, sizes from 1x1 to 101x23.
Regenerate with `nim c -r tests/parity/mkwebp_cases.nim tests/data/webp/gen`.
`tests/parity/webp_ll_compare.ps1` decodes all of them (and the real VP8L files) with the
C++ original and with the Nim port and compares the raw ARGB output.

## `lossy/` (lossy decoder L5c-B)

29 files: 17 real + 12 generated (`gen_*.webp`). ALPH chunks are ignored by the lossy tests (decoded without alpha).

| file | origin |
|---|---|
| `acro_*.webp` (13) | Adobe Acrobat DC `Acrobat\WebResources\SA\app1\dc-desktop-app-dropin\1.0.0_1.0.0` (same set as above, VP8 payloads) |
| `office_*.webp` (3) | Microsoft Office 16 `root\Office16\sdxs\...\OfflineFiles` |
| `thorvg_test_511x511.webp` | `upstream/thorvg/test/res/test.webp` |
| `gen_*.webp` (12) | `tests/parity/mkwebp_lossy.nim`: real frame-header bits written with a bool encoder (simple filter, sharpness, lf deltas, 2/4/8 partitions, skip proba, segments, tiny sizes, q0/q127), then random bytes as modes/tokens |

Real files only cover the complex filter, one partition and segments or none; the rest comes from `gen_*`.
Regenerate: `nim c -r tests/parity/mkwebp_lossy.nim tests/data/webp/lossy`.
`tests/parity/webp_lossy_compare.ps1` compares C++ and Nim BGRA/RGBA output bit by bit (plus mutated/truncated variants).

## `alph/` (container + ALPH, unit L5c-C)

143 files made by `tests/parity/mkwebp_alph.nim` (`nim c -r tests/parity/mkwebp_alph.nim tests/data/webp/alph`); about 1.7 MB, the biggest are the `acro_crop-video` (400x280) ones. The VP8 chunk of the `alph_*` files is taken unchanged from `lossy/` (`gen_simple_33x17`, `gen_parts2_80x80`, `gen_1x1`, `gen_16x1_skip`, `gen_parts4_skip_seg1_97x65`, `acro_crop-video`), the alpha plane is synthetic (ramp, opaque/transparent blocks, noise) and stored raw (`m0`) or lossless (`m1`, own VP8L encoder with palette / predictor / meta-prefix / backrefs variants `c0..c2`) with every filter `f0..f3`.

| group | files |
|---|---|
| `alph_<base>_m<method>[_c<k>]_f<filter>` | valid VP8X + ALPH + VP8, 4 filters x raw/lossless x configs |
| `ct_*` | unusual containers: unknown chunks, two ALPH, ALPH without flag, flag without ALPH, canvas mismatch, animation/fragment flags, bad VP8X size, bad/huge/odd RIFF and chunk sizes, truncations, trailing bytes, plain VP8, odd VP8 size |
| `raw_*` | bitstreams without RIFF (VP8, ALPH+VP8, VP8L) |
| `vp8l_*` | VP8L plain / inside VP8X (flag on/off, ALPH ignored, canvas mismatch, truncated, bad signature/version) |
| `alph_bad_*`, `alph_empty`, `alph_header_only`, `alph_short_raw`, `alph_lossless_*`, `alph_all_*_raw` | invalid / degenerate ALPH chunks |
| `tiny_*` | empty, 12-20 byte and garbage files |

The expected alpha plane of every valid file is in `cases()` of the generator; `tests/test_webp.nim` checks the decoded pixels against an independent premultiply model and `migration/golden/webp_*` holds the C++ results.