# tests\gl

GL unit oracles and the GL parity driver. Full instructions: `tests\parity\README.md` section 7.

| file | purpose |
|---|---|
| `Makefile.gl` | builds the original C++ CPU+GL engines + `cpp_gl_driver.cpp` -> `build\cppgl\cpp_gl_driver.exe` |
| `cpp_gl_driver.cpp` / `nim_gl_driver.nim` | C++ / Nim GL parity drivers (hidden WGL window + FBO, same dump format) |
| `glx_scene.nim` (+ `buildGlx` in the C++ driver) | GL-only extra scenes `glx:<name>` |
| `run_gl_cases.ps1` | runs a case list with the Nim GL driver (`-Mode debug|release`) and compares with `migration\golden_gl` |
| `gl_sanity.ps1` | GL vs CPU golden deltas -> `migration\GL_SANITY.md` |
| `*_compare.ps1`, `*_dump.{cpp,nim}` | bit-exact unit oracles (gpucommon, geometry, batch) |
| `dump_programs.cpp`, `dump_shaders.cpp` | GLSL program assembly dump (G3b) |
| `test_gl_context.nim` | WGL/GL acceptance test (G0) |
| `nim_gl_bench.nim` / `cpp_gl_bench.cpp` | per-frame benchmark and leak loop (`--repeat N`: opacity touch + update/draw/sync/glFinish per frame; prints `BENCH`, `LIVE` (glLiveObjects) and `WS` lines on stderr). C++: compile the file with the Makefile.gl flags and link it with every `build\cppgl\obj` object except `driver.o` -> `build\cppgl\cpp_gl_bench.exe` |

`nimc.ps1` puts the output of files under `tests\gl` in `tests\gl\build`: pass `-Out build\x.exe -Extra '--nimcache:build\nimcache\<name>'`.
