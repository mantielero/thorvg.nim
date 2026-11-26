# ThorVG → Nim Migration Status

> Canonical project status. Last updated: 2026-11-26 (Linux session).

## Snapshot

- **Goal**: Port ThorVG v1.2.0 C++ to modular, idiomatic, safe Nim 2.x, with behavior verified against the original C++ where parity infrastructure exists.
- **Upstream reference**: `upstream/` (read-only, never edit). Canonical Lottie/expr reference build: `/tmp/opencode/thorvg-lottie-build` (`-Dloaders=lottie -Dextra=lottie_exp`).
- **Project state**: Active migration. Core/CPU/SVG/image loaders/GL have historical Windows parity baselines; Lottie runtime + AOT expressions are in active development on Linux.
- **Language**: User communication may be Spanish; repository docs are English.

## Environment

### Linux (current active Lottie/expr work)
- Nim 2.x toolchain available at `/home/jose/.nimble/bin/nim` (verify with `nim -v`).
- Typical compile check: `/home/jose/.nimble/bin/nim c -c --path:src [--path:tools] <file>`.
- Typical tests: `/home/jose/.nimble/bin/nim c -r --path:src [--path:tools] tests/lottie/<test>.nim`.
- Prefer `/tmp/opencode` for temporary artifacts.

### Windows historical baseline (offline, 2026-11-20)
- Nim 2.4.0 + MinGW-w64 gcc 11.1, stdlib only. PowerShell 5.1 (no `&&`).
- Env/script bootstrap: `. "C:\Users\C08937\.config\opencode\skills\nim-toolchain-win\scripts\env.ps1"`.
- Scripts: `nimc.ps1`, `run-tests.ps1`, `nim-scan.ps1`, `parity.ps1`.
- GL hardware baseline: AMD Radeon, driver 23.19.24.251211, OpenGL 3.3 core via WGL, hidden window.

## Hard Rules

- Nim files <= ~400 code lines where practical (historical baseline tracked strict limit).
- No `ptr`/`addr`/`cast`/`importc`/`emit` outside `*_ffi.nim`, `*_unsafe.nim`, `*_oracle.nim` (or explicitly accepted exempt files documented in `migration/DECISIONS.md`).
- No stubs; deviations from C++ must be logged in `migration/DECISIONS.md` with rationale.
- `float32` where C++ uses `float`; pixels `uint32` with wrap-around math. Enums `{.pure.}` qualified. Class hierarchies: `ref object of RootObj` + `method` where appropriate.
- Goldens are captured from C++ drivers/harnesses, never from Nim. Never relax tolerance or weaken tests to pass.
- Lottie/expr: runtime first, AOT later; pure Nim, **zero JS**, no runtime interpreter; no silent degradations; no global mutable state (`ExprCtx` explicit); use `jsony` for JSON.
- For AOT expressions: uncompiled expression => declared policy (never silent). D2 registry: hash lookup, `Strict` default, `IgnoreCounted` only when explicitly requested.

## Architecture (layers)

| Layer | Path | Contents |
|---|---|---|
| Core | `src/thorvg/core` | types, geom, bezier, path, fill, str, compressor |
| Renderer | `src/thorvg/renderer` | RenderMethod/RenderSurface/RenderShape contract, paint, shape, scene, picture, canvas, loaders, text, fonts, effects, trim, animation, accessor, saver |
| CPU engine | `src/thorvg/engine/cpu` | software rasterizer: rle, stroke, dash, fill, blend, raster*, texmap*, effects*, SwRenderer/canvas |
| GL engine | `src/thorvg/engine/gl` | OpenGL engine modules, `glcanvas.nim` facade |
| WG engine | `src/thorvg/engine/wg` | WebGPU engine/FFI (platform/runtime dependent) |
| Loaders | `src/thorvg/loaders/{image,svg,font}` | PNG, JPG, GIF, WebP, SVG, TTF |
| Display | `src/thorvg/display` | window/imageio; platform FFI where needed |
| Savers | `src/thorvg/savers` | PNG saver (addition) |
| Lottie | `src/thorvg/lottie` | model, parser, builder, animation, expr runtime/boundary/registry |
| Facade | `src/thorvg.nim` | public API; GL not re-exported by default (D-GL-3) |

## Status by Area

| Area | Status | Evidence / Notes |
|---|---|---|
| Core, renderer, CPU engine, scene graph (T00..T20) | Verified (historical Windows baseline) | Unit tests + parity |
| Scene effects (L1), texmap/rotated images (L3) | Verified | Parity cases |
| SVG loader, TTF + Text | Verified | Parity svg/text |
| PNG, JPG, GIF, WebP | Verified | Parity suites |
| Window + image writers (T14) | Verified | Tests; GUI tests may require platform flags |
| OpenGL engine (G0..G5) | Verified on baseline GPU/driver | 728/728 + 56 glx, 3 oracles (Windows baseline) |
| Animation + Accessor + Saver (L7) | Ported, not parity-verified | Unit tests only, no C++ parity cases |
| Lottie (L4) | **Phase 2 in progress** (runtime, no JS/AOT) | See Lottie section below |
| WebGPU, C API, partial render, OTF, GIF/Lottie savers, threads/SIMD | Not started / blocked / deferred | See Pending/Decisions |

## Lottie Status

### Phase 0 — Corpus and comparison harness
- **Complete**. C++ harness `tests/lottie/harness/dump_lottie.cpp`; goldens in `tests/lottie/golden/` (19 cases x 5 frames): RGBA, PPM, props, manifest. `nimble testLottieHarness` / comparator green.

### Phase 1 — Parser/model/keyframe evaluator (no expressions)
- **Complete (core)**. Modules: `src/thorvg/lottie/model/{common,property,model}.nim`, `animation/interpolator.nim`, `parser/parser.nim`.
- Tests: `test_phase1_eval.nim` ALL OK (19 cases x 5 frames, tol pos/scale 0.5, rot 0.05, op 1.5), `test_phase1_parse_corpus.nim` parsed 20 files / 1295 shapes, `test_phase1_types.nim` ok.
- Ty5 text Phase 1 model/parser landed; compose wm ty5 oracle: `tests/lottie/test_text_compose.nim` **44/44 pass**.

### Phase 2 — Builder over ThorVG Nim
- **In progress**. Module: `src/thorvg/lottie/builder/builder.nim`.
- Gate: `tests/lottie/test_phase2_builder.nim` → **19/19 pass, 0 fail, 0 skip** (tol channel 2, RGBA vs C++ 1.2.0 goldens).
- `audio_layer`: **OK with documented AAEDGE** (not XFAIL). Dense expr oracle 229/229 green; residual render diffs are narrow AA/coverage edges with evidence:
  - `@0.0`: 1/250000 px, maxDiff 255, gold `a=1` nim `0` at `(231,297)`.
  - `@28.5`: 33/250000 px, maxDiff <= 45, edge alpha gradient diffs; expr rotation value matches oracle.
- Other narrow AAEDGE allowances remain case-specific and evidence-based (`test5`, `test6`, `test8`, `test9`, `test10`, `test11`); no global tolerance increase.

## Expressions AOT Status (zero JS)

### Decisions / guardrails
- **D1-exc1**: do not replicate C++ `$bm_rt` global leak/order-dependent behavior in AOT. Expr without definitive `$bm_rt` assignment => `Option[Val]` none/static fallback + counted warning.
- **D1-exc2**: opacity OOB/UB clamp+divergence declared. `NaN->0; p<=0->0; p>=255->255; else uint8(trunc(p))`, `p=float32(pct)*2.55f32`. No direct `uint8(x)`. +Inf clamp 255 in Nim; C++ UB documented.
- **D1-exc3**: non-numeric/nested array elements -> 0; NaN preserved only if element is number NaN. C++ garbage/UB-like values not replicated; `nimExpected` + Nim divergence golden recorded.
- **D2**: hash registry; `Strict` default (uncompiled expression => structured error); `IgnoreCounted` only when explicitly requested.
- **D3 (open, Phase 6)**: `wiggle/random/noise/gaussRandom` parity strategy.

### Implemented (Phase 0-1d/2/3a/3b/3c partial)
- C++ ref build with `lottie_exp`; inventory/oracles/boundary/exprc/runtime/boundary/hash/registry/pack pipeline.
- `src/thorvg/lottie/expr/{val,boundary,runtime,hash,registry,packs}.nim`: pure runtime, single boundary, shared FNV-1a hash, D2 registry, builtin pack registration.
- `tools/exprc/*`: lexer/parser/analysis/emitter/registry; `gen_audio_pack.nim` + generic `genpacks.nim`/`gen_lottie_packs.nim` for generated packs. `--check` for regen/diff guard.
- Generic pack generator: `tools/exprc/genpacks.nim` + CLI `gen_lottie_packs.nim` compile expressions from any `.json`/`.lot` and emit `src/generated/expr_packs_auto.nim`. `src/thorvg/lottie/expr/packs.nim` imports it only when present (`when fileExists`), so the tree compiles without it. Empty packs are not created. End-to-end verified: a compiled opacity expression changed render (center `159,0,0` vs static `255,0,0`).
- Scope note: only transform properties (`ks.o/.r/.p/.a/.s/.sk/.sa`) reach `exprEval`; fill/stroke currently emit warnings. `genpacks` marks each expression as `[evaluated]` or `[parsed-only]`.
- `src/generated/expr_audio_layer.nim`: generated audio_layer AOT pack (hash `7ef68f4253eeaf2b`).
- Parser/builder integration: definitive exprc analysis (no `$bm_rt` string heuristic), transform props bind through registry; builder frame clamp `[inPoint, outPoint-1]`.
- Dense capture: `tests/lottie/test_expr_audio_dense.nim` **229/229** vs `tests/lottie/expr_golden/audio_layer_dense.jsonl`.

### Current Lottie/Expr test snapshot (verified 2026-11-26)
| Test | Result |
|---|---:|
| `tests/lottie/test_expr_boundary.nim` | 116 pass / 0 fail / 0 pending |
| `tests/lottie/test_exprc.nim` | 46 pass |
| `tests/lottie/test_expr_runtime.nim` | 61 pass |
| `tests/lottie/test_expr_pack.nim` | 4 pass |
| `tests/lottie/test_expr_audio_dense.nim` | 229/229 pass |
| `tests/lottie/test_phase2_builder.nim` | 19/19 pass / 0 fail / 0 skip |
| `tests/lottie/test_text_compose.nim` | 44/44 pass |

## Pending / Next Steps

1. **Lottie Phase 2 parity**: continue closing residual render differences by root cause; keep AAEDGE allowances narrow, per-case, evidence-based.
2. **AOT coverage expansion**: integrate more expressions/properties/corpus cases through registry+generated packs; no silent fallback.
3. **CI/guard**: formalize `gen_audio_pack --check` / pack regen diff guard in stable CI/test path as needed.
4. **AOT phases**: continue per `docs/AGENTS-expressions-aot.md`; D3 (`wiggle/random/noise/gaussRandom`) deferred to Phase 6.
5. **Historical migration decisions**: see `migration/DECISIONS.md` and `migration/STATE.md` for full audit trail (local, not committed where ignored).

## Known Quirks / Risks

- AA/coverage edge diffs can be rasterization-sensitive; do not convert them into global tolerance increases.
- GL bit-exactness is only meaningful on the same GPU/driver as the baseline.
- `audio_layer` render gate is green with documented AAEDGE; do not claim pixel-identical render unless evidence changes.
- Do not commit `HELP.md`, `HELP_extra.md`, `migration/STATE.md`, or test binaries.
- `migration/` is ignored/resumable local state; keep it updated locally when doing migration work.

## Key References

- `README.md` — project overview and quick commands.
- `docs/STATUS.md` — this file, canonical status.
- `docs/lottie-notes.md` — Lottie implementation notes/findings.
- `docs/lottie-expressions-notes.md` — AOT expression decisions/findings.
- `docs/AGENTS-expressions-aot.md` — AOT expression plan/constraints.
- `migration/STATE.md`, `migration/PLAN.md`, `migration/DECISIONS.md` — local migration audit trail (if present).
- `tests/parity/README.md`, `tests/gl/README.md` — parity/GL workflows.
