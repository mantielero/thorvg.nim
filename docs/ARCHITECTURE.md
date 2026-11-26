# Architecture

This document describes the current architecture of the ThorVG → Nim port.

## Goals and Boundaries

- **Port target**: ThorVG v1.2.0 C++ behavior, implemented in modular, idiomatic, safe Nim 2.x.
- **Reference**: `upstream/` contains the original ThorVG C++ source and is read-only.
- **Verification model**: where parity infrastructure exists, Nim output is compared against C++-generated goldens/drivers. Goldens are never captured from Nim.
- **Safety model**: unsafe operations (`ptr`, `addr`, `cast`, `importc`, `emit`) are confined to explicitly designated `*_ffi.nim`, `*_unsafe.nim`, or `*_oracle.nim` files.

## Layered Layout

The codebase is organized by layers. Lower layers should not depend on higher layers.

| Layer | Path | Responsibility |
|---|---|---|
| Core | `src/thorvg/core` | Pure/value types and math: geometry, bezier, path, fill, string/compression helpers. |
| Renderer contract | `src/thorvg/renderer` | Renderer interfaces and scene graph objects: `RenderMethod`, `RenderSurface`, paint/shape/scene/picture/canvas, loader registry, text/fonts, effects, trim, animation, accessor, saver. |
| CPU engine | `src/thorvg/engine/cpu` | Software rasterizer: RLE, stroke, dash, fill/blend, raster, texmap, effects, `SwRenderer`, `newSwCanvas`, `swSurface`. |
| GL engine | `src/thorvg/engine/gl` | OpenGL backend: FFI wrappers, state/program/targets/buffers/textures, geometry/tessellation/batches/tasks, renderer, effects, `glcanvas`. |
| WG engine | `src/thorvg/engine/wg` | WebGPU backend scaffold/port: FFI/types, WGSL, context/bind groups/targets, pipelines, batches/compositor/tasks, renderer, `wgcanvas`. Runtime/parity may be environment-blocked. |
| Loaders | `src/thorvg/loaders/{image,svg,font}` | Asset decoding/parsing: PNG/JPG/GIF/WebP, SVG, TTF/font loading. Loaders register through the loader registry. |
| Display | `src/thorvg/display` | Platform/window/image I/O helpers. Platform FFI is isolated. |
| Savers | `src/thorvg/savers` | Output savers (e.g., PNG saver). |
| Lottie | `src/thorvg/lottie` | Lottie model, parser, animation/interpolators, builder, and AOT expression runtime/boundary/registry. |
| Facade | `src/thorvg.nim` | Public API exports. GL is intentionally not re-exported by default (separate import keeps base import GL-free). |

## Key Runtime Flows

### CPU rendering
1. User creates a canvas via `newSwCanvas` and scene graph objects (`Shape`, `Scene`, `Picture`, `Text`, etc.).
2. Objects are prepared/updated through renderer contracts.
3. CPU engine rasterizes into a software surface (`swSurface`).
4. Result can be written through image I/O utilities.

### Lottie rendering
1. JSON is parsed by `src/thorvg/lottie/parser/parser.nim` into Lottie model objects.
2. Properties/keyframes are evaluated through model/property/animator code.
3. `src/thorvg/lottie/builder/builder.nim` rebuilds a ThorVG scene for a frame/time.
4. Scene is rendered by the selected backend (CPU in current parity gates).

### Lottie expressions (AOT, zero JS)
1. Expression source is parsed/analyzed by `tools/exprc/*` (lexer, parser, definitive `$bm_rt` analysis, emitter).
2. AOT pack code is generated into `src/generated/*.nim` (or checked with `--check`).
3. At load/bind time, parser/registry resolves expression hash using D2 policy:
   - `Strict` (default): uncompiled/unknown hash is a structured error/diagnostic.
   - `IgnoreCounted`: only when explicitly requested; skip and count.
4. Bound expression evaluation receives explicit `ExprCtx` (time/frame); no global mutable expression state.
5. Boundary conversion is centralized in `src/thorvg/lottie/expr/boundary.nim` (`toPropScalar`, `toPropVec`, `toPropOpacityU8`), including declared D1 divergence rules.

## Design Decisions

- **D1-exc1**: Do not replicate C++ `$bm_rt` global leak/order-dependent behavior in AOT. No definitive `$bm_rt` => static fallback + counted warning.
- **D1-exc2**: Opacity boundary uses `NaN->0; p<=0->0; p>=255->255; else uint8(trunc(p))`, `p=float32(pct)*2.55f32`; +Inf clamps to 255 in Nim; C++ UB documented.
- **D1-exc3**: Non-numeric/nested array elements -> 0; NaN preserved only for numeric NaN. C++ garbage/UB-like values are not replicated; Nim expected/divergence golden recorded.
- **D2**: Expression registry by hash; `Strict` default; `IgnoreCounted` explicit opt-in.
- **D3 (open, Phase 6)**: `wiggle/random/noise/gaussRandom` parity strategy.
- **GL bit-exactness**: meaningful only on the same GPU/driver as the baseline.

## Verification and Quality Gates

- **Unit tests**: `tests/test_*.nim` and subsystem tests (Lottie, GL, parity helpers).
- **Lottie parity gates**: C++ golden RGBA/props dumps compared by Nim harness/tests.
- **AOT checks**: generated pack `--check`, expr boundary/runtime tests, dense oracle comparisons.
- **Quality rule**: no tolerance relaxation or weakened tests to make failures pass; document narrow, evidence-based AAEDGE allowances only when justified.

## Where to Look

| Topic | Location |
|---|---|
| Canonical status | `migration/STATUS.md` |
| Migration decisions/history | `migration/DECISIONS.md`, `migration/STATE.md` |
| Lottie notes | `docs/lottie-notes.md` |
| Expression AOT notes | `docs/lottie-expressions-notes.md` |
| Expression AOT plan | `docs/AGENTS-expressions-aot.md` |
| Agent working guide | `docs/AGENTS.md` |
