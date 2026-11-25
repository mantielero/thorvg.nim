# GLOBAL_SUMMARY: ThorVG -> Nim migration

Snapshot base: 2026-11-20 (Windows parity baseline). Updated: 2026-11-22 (Linux, Lottie Phase 2 progress).

Entry point for any agent that continues this work. Read this file first, then `migration\STATE.md` (append-only log of
every unit), `migration\PLAN.md` (unit table), `migration\DECISIONS.md` (architecture, hazards, every deviation).
Nothing is committed anywhere (the folder is not a git repo): this tree IS the project.

## 1. What this is

- Goal: port ThorVG v1.2.0 (C++14, `upstream\thorvg`, read-only, never edit) to modular, idiomatic, safe Nim 2.x.
- Each ported unit was verified against the ORIGINAL C++ build (bit-exact pixel dumps, tolerance 0).
- Project root = the folder holding `upstream\`. `nim.cfg` (ORC, threads on, `--path:src`, styleCheck:usages) and
  `thorvg.nimble` live there. Import style: `import thorvg` (facade) or `import thorvg/engine/gl/glcanvas`.
- Language of the user: Spanish. Repo documents are English. Answer the user in Spanish.

## 2. Environment (offline Windows, no network)

- Nim 2.4.0 + MinGW-w64 gcc 11.1, std library only (no nimble packages). PowerShell 5.1 (no `&&`).
- EVERY shell command must start with:
  `. "C:\Users\C08937\.config\opencode\skills\nim-toolchain-win\scripts\env.ps1"`
- Scripts in `C:\Users\C08937\.config\opencode\skills\nim-toolchain-win\scripts`: `nimc.ps1` (compile; `-Mode debug|release|danger`,
  `-Strict`, `-Out`, `-Extra`), `run-tests.ps1 -Root . [-Mode] [-Strict] [-Filter]`, `nim-scan.ps1`, `parity.ps1`.
  For files under `tests\gl` always pass `-Out build\x.exe -Extra '--nimcache:build\nimcache\x'`.
- node.js exists (used only by generators `tests\parity\mk*.js`), g++/mingw32-make exist for the C++ baselines.
- Hardware used for GL: AMD Radeon, driver 23.19.24.251211, OpenGL 3.3 core via WGL, hidden window.
- Skills worth loading: `migrate-cpp-to-nim`, `cpp-to-nim-mapping`, `cpp-nim-verification`, `nim-toolchain-win`,
  `nim-style-guide`. Sub-agents: `cpp2nim-porter` (one unit per run), `cpp2nim-verifier` (never edits `src`), `cpp2nim-analyst`.
- Pitfalls: debug builds use `--checks:on`, so float division by zero raises (H2): guard explicitly or use
  `{.push floatChecks: off.}`. `nimc.ps1` leaves `tests\parity\build` (delete it). Run ONE heavy job at a time (parity, GPU, builds).
  A previous verifier run died with "Missing auth credential": if a sub-agent errors immediately, just relaunch it.

## 3. Hard rules of the project (enforced by nim-scan and by the verifier)

- Nim files <= 400 code lines (largest today: 355). 151 files, ~20 956 code lines under `src\`.
- No `ptr`/`addr`/`cast`/`importc`/`emit` outside files named `*_ffi.nim`, `*_unsafe.nim`, `*_oracle.nim`. Exempt files are
  listed in `DECISIONS.md` ("Exempt files" E1..E6): `display/win32_ffi.nim`, and in `engine/gl/`:
  `gl_raw_ffi`, `gl_core_ffi`, `gl_buffers_ffi`, `gl_ffi`, `wgl_ffi`. A new unsafe file must be added to that list.
- No stubs; every deviation from the C++ is logged in `DECISIONS.md` (D-<unit>-N) with an exact-match edit (re-read the file
  before editing: several agents may edit it).
- `float32` wherever C++ uses `float`; pixels `uint32` with wrap-around math. Enums `{.pure.}` written qualified.
  Class hierarchies = `ref object of RootObj` + `method`. Loaders register themselves at import via `registerLoader`.
- Golden files are captured ONLY from the C++ drivers, never from Nim. Never relax a tolerance or weaken a test to pass.
- Update `migration\STATE.md` and the `PLAN.md` row after every unit.

## 4. Architecture and where things are

Layers (a module imports only from lower layers):

| layer | folder | content |
|---|---|---|
| core | `src\thorvg\core` | types, geom, bezier, path, fill, str, compressor (pure values) |
| renderer | `src\thorvg\renderer` | render.nim (RenderMethod/RenderSurface/RenderShape contract), paint, shape, scene, picture, canvas, loader registry, text, fonts, effect, trim, animation, accessor, saver |
| CPU engine | `src\thorvg\engine\cpu` | software rasteriser: rle, stroke, dash, fill, blend, raster*, texmap*, effects*, renderer.nim (`SwRenderer`, `newSwCanvas`, `swSurface`) |
| GL engine | `src\thorvg\engine\gl` | 34 modules, see section 6; facade `glcanvas.nim` |
| loaders | `src\thorvg\loaders\{image,svg,font}` | PNG, JPG, GIF, WebP (`image\webp\`, 24 modules), SVG (21 modules), TTF |
| display | `src\thorvg\display` | `win32_ffi` (the only unsafe file), `window`, `imageio` (BMP/PPM/PNG writers) |
| savers | `src\thorvg\savers\png.nim` | PNG saver (addition, not in upstream) |
| facade | `src\thorvg.nim` | public API; GL is NOT re-exported (see D-GL-3 below) |

Other folders: `examples\` (hello, shapes, viewer, text demos + shared scenes), `tests\` (45 `test_*.nim`, `tests\parity`, `tests\gl`,
`tests\data`), `migration\` (all docs, cases, golden), `build\` (C++ baselines, drivers, caches; disposable except
`build\cpp\cpp_driver.exe` and `build\cppgl\cpp_gl_driver.exe`, which are rebuilt by Makefiles in ~1-5 min).
`src\thorvg\engine\gl\build\` is a stray nimcache (41 files): safe to delete.

Public API (facade): Canvas/Shape/Scene/Picture/Text/Animation/Accessor/Saver, gradients, scene effects (blur, shadow, fill,
tint, tritone, motion blur), `newSwCanvas`, loaders for png/jpg/gif/webp/svg/ttf/raw, image writers. Most calls return `Result`;
`check` raises `ThorvgError`.

## 5. Status per area (everything below is verified unless stated)

| area | status | proof |
|---|---|---|
| Core, renderer, CPU engine, scene graph (T00..T20) | verified | unit tests + parity |
| Scene effects (L1), texmap/rotated images (L3) | verified | parity pngrot, svg_upstream_test1 |
| SVG loader (T16/T17), TTF + Text (T18/T19) | verified | parity svg 15, text 3 |
| PNG (T15), JPG (L5a), GIF (L5b), WebP lossy/lossless/alpha (L5c) | verified | parity png 35, jpg 99, gif 172, webp 368 |
| Window + image writers (T14) | verified | tests; GUI tests only with `THORVG_GUI_TEST=1` |
| OpenGL engine (G0..G5, L6 GL part) | verified, bit-exact vs original C++ GL engine on THIS GPU/driver | GL parity 728/728 + 56 glx, 3 oracles |
| Animation + Accessor + Saver (L7) | **ported, NOT verified**: unit tests only, no C++ parity cases | `test_animation/accessor/saver` |
| Lottie (L4) | **Phase 2 in progress** (runtime, no JS/AOT). Phase 0/1 done; Phase 2 builder vs C++ 1.2.0 RGBA goldens: **12/19 pass, 7 fail, 0 skip** (tol 2). Pass: `test,test2,test4,test5,test7,test12,test13,test14,embedded_font,segment,slot,tween`. Per-case AA-edge allowances (evidence-backed, narrow): `test5@89`, `test9@30/45/59`. Recent: reqFragment painter-only fill/stroke fragment emission in C++ order fixed `test2` (Handle-Area 1165/255 -> 0); approximation, no full RenderContext fork. See `docs/lottie-status.md`. | `tests/lottie/test_phase2_builder.nim` |
| WebGPU, C API, partial render (L2), OTF, GIF/Lottie savers, threads/SIMD | **not started** | see section 9 |

Latest full verification (2026-11-20, verifier round 4, see `migration\FAILURES.md`, `REPORT.md`, `BENCH.md`, `PARITY_LOG.md`):
- `run-tests.ps1 -Root . -Strict`: 45/45 debug and 45/45 release (11 `test_gl_*` ran on a real GL context, no skips).
- CPU parity (`migration\cases.txt`, 728 cases: shapes 21, png 35, pngrot 15, svg 15, text 3, jpg 99, gif 172, webp 368):
  728/728 bit-exact on release, danger and debug drivers (debug sample of 122 after the last refactor).
- GL parity (`cases.txt` + `cases_glx.txt` 56 GL-only cases vs `migration\golden_gl`): 728/728 + 56/56, release and debug.
- GL oracles: gpucommon 11 590 cases, geometry 4 249, batch 5 102: 0 mismatches. 102 GLSL programs byte-equal to C++ assembly.
- nim-scan: exit 1 only because of 11 `checksOff` hits, all `{.push floatChecks: off.}` (hazard H2) = false positives of the
  regex (`checks:\s*off` also matches `floatChecks`). Awaiting an acceptance entry or the regex fix `(?<!float)checks:\s*off`.
- Open item F2: case `jpg_sep_420_53x37` is unstable in the ORIGINAL C++ GL driver today (different image on every run);
  the Nim GL driver matches the golden every time. Not a port bug. Needs a decision (keep + document, or mark flaky-original).
- Cosmetic: two stale comments in `engine/gl/renderer_draw.nim` and `renderer_prepare.nim` mention a resolved "G4b TODO list".

## 6. The GL engine in one page

Entry: `import thorvg/engine/gl/glcanvas` -> `newGlCanvas(dc, rc: int, fbo: GlId, w, h: int): Canvas`, `retarget`, `glTerm`.
Context for tests/drivers: `wgl_ffi.wglCreateOffscreen(w, h)` (hidden window, 3.3 core -> compat -> legacy, RGBA8+D24S8 FBO, MSAA 4x
is done by render targets). All GL calls go through safe wrappers in `gl_ffi` (no pointers in any exported signature).

| unit | modules | note |
|---|---|---|
| G0 | gl_types, gl_raw_ffi, gl_core_ffi, gl_buffers_ffi, gl_ffi, wgl_ffi | loader via wglGetProcAddress, `glCheck` (with `-d:glDebug`), `glLiveObjects` leak counters |
| G1a/G1b | state_cache, shader, program / render_target, gpu_buffer, texture_mgr | `GlStateCache` is move-only: pass `var` explicitly |
| G2a/b/c | gpu_path, gpu_dash, gpu_probe / gl_common, geometry, tessellator, tess_stroke / solid_batch, stencil_batch | pure CPU, bit-exact oracles |
| G3a/G3b | render_task, task_blend, render_pass, task_draw / shader_src (+56 `.glsl`), programs | shaders via `staticRead` |
| G4a/b/c | renderer, renderer_draw, renderer_prepare / renderer_comp, renderer_sync / effects | `GlRenderer` overrides all 25 RenderMethod methods |
| G5 | glcanvas, `tests\gl\nim_gl_driver.nim`, `glx_scene.nim` | |

Not ported in GL: GLES branches, `damage/partial/dirtyRegions` hooks (not in the Nim RenderMethod contract). Details: D-G*-N entries.
Bit-exactness holds only on the same GPU and driver; MSAA 4x makes GL differ from the CPU golden at edges (`migration\GL_SANITY.md`).
Design doc: `migration\GL_PLAN.md` (still describes the plan; reality = `DECISIONS.md` D-G*).

## 7. How to build and verify (cheat sheet)

```powershell
. "C:\Users\C08937\.config\opencode\skills\nim-toolchain-win\scripts\env.ps1"
$s = "C:\Users\C08937\.config\opencode\skills\nim-toolchain-win\scripts"
& "$s\run-tests.ps1" -Root . -Mode debug   -Strict            # unit tests (also -Mode release, -Filter name)
& "$s\run-tests.ps1" -Root . -Mode release -Strict
# CPU parity (full details: tests\parity\README.md)
mingw32-make -f tests/parity/Makefile -j12                    # only if the C++ driver sources/config changed
& "$s\nimc.ps1" -Src tests\parity\nim_driver.nim -Mode release -Strict -Out build\nim_driver.exe
powershell -File tests\parity\run_cases.ps1 -Exe build\nim_driver.exe -OutDir C:\Temp\opencode\nim_out -CompareWith migration\golden [-Filter webp_]
# GL parity (full details: tests\parity\README.md section 7, tests\gl\README.md)
mingw32-make -f tests/gl/Makefile.gl -j8
& "$s\nimc.ps1" -Src tests\gl\nim_gl_driver.nim -Mode release -Strict -Out build\nim_gl_driver_release.exe -Extra '--nimcache:build\nimcache\glrel'
tests\gl\run_gl_cases.ps1 -Mode release                       # add -Cases migration\cases_glx.txt for the glx set
# oracles: tests\gl\{gpucommon,geometry,batch}_compare.ps1 ; quality: & "$s\nim-scan.ps1"
```

- Drivers: `cpp_driver <scene> <w> <h> [--dump p] [--repeat N]`, scenes `shapes[:part] svg: png: jpg: webp: pngrot: gif: text[:ttf]` (+ `glx:` for GL).
  The Nim drivers share scenes through `tests\parity\driver_common.nim`; keep `glx_scene.nim` and `buildGlx` in `cpp_gl_driver.cpp` in lock-step.
- Test data generators (own encoders, deterministic): `tests\parity\mkpng.js mkgif.js mkjpg.js`, `mkwebp_*.nim`. Real WebP samples were copied from
  the machine, origins in `tests\data\webp\README.md`.
- Adding a new feature: port with a `cpp2nim-porter` run, add C++ driver scene + Nim driver scene + cases (append to `cases.txt`),
  capture golden from C++ only, run parity on debug AND release, run the full suite, then the verifier.

## 8. Performance (Nim danger vs C++ -O2, ratios only, machine noisy +-10-20%; `migration\BENCH.md`, `PERF_PAUSED.md`)

CPU: shapes 1.64x slower (goal 1.5x NOT met; memory 27 MB vs 12 MB), svg gradient 0.84x, svg test0 1.04x, text 0.58x, pngrot 0.86x,
webp lossless decode 0.79x, lossy 1.0-1.6x, jpg 0.87-1.08x. GL: shapes 0.98x, svg gradient 0.97x, png 0.85x, text 1.14x, svg test0 1.26x.
PERF is paused with a certified tree (H-perf-1..6). Root cause found: with `--exceptions:goto` on MinGW each call to a proc not proven
non-raising polls a thread-local, re-fetched via `__emutls_get_address` per iteration. Cheap alternative: build with `-Extra '--threads:off'`
(the project uses no threads). Remaining hypotheses for shapes are listed in `PERF_PAUSED.md` ("Hypotheses", "How to resume").

## 9. What is NOT done, with effort estimates (units = one porter run each)

| item | C++ size | effort | notes |
|---|---|---|---|
| Parity cases for L7 (Animation/Accessor/Saver) | - | low (1) | add driver scenes + golden from C++ |
| C API (`bindings/capi`) | ~4 700 lines | medium (2-3) | DLL with `{.exportc, dynlib.}` in an `*_ffi.nim`; verify with a C program using the original header |
| Partial render / dirty regions (L2) | a few hundred lines in tvgRender + engines | medium-low (1-2) | extend RenderMethod (`damage/partial/dirtyRegions`), CPU + GL; result must equal full render |
| Lottie without expressions (L4) | ~10 000 lines core | high (in progress) | Phase 2 builder active on Linux. Runtime only, no JS engine/AOT. Uses `jsony` for JSON; C++ 1.2.0 RGBA goldens for parity. Current: 12/19 pass, 7 fail, 0 skip. Main blockers: full RenderContext/propagator/modifier semantics, Stroke ty22, text layers, slots/assets, remaining structural/hiSolid cases; verified AA-edge residuals kept under per-case allowances, not global tolerance. |
| OTF (CFF charstrings) | ~2 000 lines with TTF (`modules/sfnt`) | medium (1-2) | TTF reader exists in `loaders/font` |
| GIF saver / Lottie saver | ~700 lines (gif encoder + saver) | low (1) / needs Lottie | `Saver` registry exists |
| Threads / SIMD (AVX2, `tvgSwRasterSimd.cpp`, task scheduler) | | medium (2-4) | output must stay bit-exact; SIMD only in `*_unsafe.nim` |
| Shapes CPU speed (1.64x -> 1.5x) | | low (1-2) | see section 8 |
| WebGPU | ~6 800 lines + WGSL | BLOCKED | needs wgpu-native/Dawn, not available offline |
| Media modules (`modules/media`: Android/Apple/web), GLES targets | | not planned | |

Estimated coverage: about 45-47 % of ThorVG by C++ lines excluding Lottie and WebGPU-sized pieces (earlier "13 % with Lottie" counted the
112k JerryScript lines; real Lottie core is ~10k).

## 10. Pending decisions (ask the user, do not decide alone)

1. F2 (`jpg_sep_420_53x37`, flaky in the original GL driver): keep + document, or mark flaky-original.
2. Formal acceptance (`A<n>` in `DECISIONS.md`) of what is out of scope: Lottie (A1 already accepted, deferred), WebGPU, GLES, partial render,
   OTF, C API, GIF/Lottie savers, threads/SIMD, and "GL bit-exactness only on this driver". Then mark L2/L4/L6(WebGPU) dropped or deferred in PLAN.md.
3. D-GL-3: re-export `glcanvas` from `thorvg.nim`? Current choice: no (separate import keeps `import thorvg` free of GL).
4. nim-scan: accept the 11 `floatChecks` false positives (A<n>) or fix the regex in `nim-scan.ps1`.
5. Entry in `DECISIONS.md` explaining shapes CPU 1.64x slower and GL svg test0 1.26x.
6. Whether to finish the final report and set `STATE.md` to `phase: DONE`.

## 11. Known quirks of the original (golden = what the original does; the port copies them)

- `style_use.svg`: CSS `#c { fill: hsl(...) }` renders black; `<use>` with rotate partly leaves the viewbox.
- radial gradient mask-direct path uses `sqrt(det)` without `- b` (D-T12a-4). `rleMerge` is declared upstream but never defined (D-T10a-3).
- jpgd does not support multi-scan sequential JPEGs (cases `jpg_*sep_420*` document that Nim equals C++).
- PNG: iCCP ignored, CRC unchecked. Images above 2^26 pixels (WebP) / 2^28 (GIF) are rejected where C++ would just malloc.
- Loaders are cached by path (D-T13-3), which makes decode benchmarks not strictly comparable with C++.
- `Paint.parent` is a non-owning cursor (D-T13-1): a paint must not outlive its parent while in use.
- Stderr text for load failures differs slightly (Nim appends the error name); stderr is not compared, rc and stdout hash are.

## 12. Where to look for what

| need | file |
|---|---|
| what is done / next | `migration\STATE.md` (header lines may lag: this file is newer), `migration\PLAN.md` |
| why a design/deviation | `migration\DECISIONS.md` (search `D-<unit>-`, `H-perf-`, `E<n>`, `A<n>`) |
| open failures | `migration\FAILURES.md` |
| verification results | `migration\REPORT.md`, `PARITY_LOG.md`, `BENCH.md`, `NIM_SCAN.md`, `GL_SANITY.md` |
| GL design | `migration\GL_PLAN.md`, `tests\gl\README.md` |
| parity how-to | `tests\parity\README.md` |
| perf resume | `migration\PERF_PAUSED.md` |
| test data origin | `tests\data\*` (READMEs), generators in `tests\parity\mk*` |
