# thorvg.nim

Nim port of [ThorVG](https://github.com/thorvg/thorvg) (v1.2.0 C++ reference), targeting modular, idiomatic, safe Nim 2.x.

> Status: active migration. See [`migration/STATUS.md`](migration/STATUS.md) for the canonical, detailed project status.

## Overview

This repository contains a Nim implementation of ThorVG components, including core/vector types, renderer contracts, CPU rendering, SVG/image loaders, GL/WG engine work, and an in-progress Lottie runtime with a **zero-JS AOT expression** pipeline.

Key principles:

- **Behavior-first porting**: verify against the original C++ where parity infrastructure exists.
- **No silent degradation**: unsupported/uncompiled behavior must be explicit/diagnostic.
- **AOT expressions, no JS runtime**: Lottie expressions are compiled/AOT-bound; no embedded JS engine, no runtime interpreter, no global mutable expression state.
- **Safe boundaries**: unsafe FFI/pointer/cast/importc usage is confined to explicitly designated `*_ffi.nim`/`*_unsafe.nim`/`*_oracle.nim` files.

## Repository Layout

| Path | Purpose |
|---|---|
| `src/thorvg/` | Nim implementation (core, renderer, engines, loaders, lottie, etc.) |
| `src/generated/` | Generated AOT expression packs (e.g. `expr_audio_layer.nim`) |
| `tests/` | Unit/parity/Lottie tests and harnesses |
| `tools/exprc/` | Expression compiler/AOT pack generators |
| `examples/` | Demo programs; compiled output goes to `examples/build/` |
| `docs/` | Project documentation and canonical status |
| `upstream/` | ThorVG C++ reference (read-only, not edited) |
| `migration/` | Local resumable migration audit trail (may be ignored/uncommitted) |

## Quick Start

### Requirements

- Nim >= 2.0.0 (Nim 2.x; verify with `nim -v`).
- For C++ parity/golden workflows, use the platform-specific toolchain/scripts documented in `tests/parity/README.md`, `tests/gl/README.md`, and `migration/STATUS.md`.

### Compile checks

```bash
# Compile-check a module
nim c -c --path:src src/thorvg/lottie/parser/parser.nim

# Compile-check an expression tool/test with exprc sources
nim c -c --path:src --path:tools tests/lottie/test_exprc.nim
```

### Run tests

```bash
# Lottie Phase 2 builder gate
nim c -r --path:src --path:tools tests/lottie/test_phase2_builder.nim

# Lottie expression gates
nim c -r --path:src tests/lottie/test_expr_boundary.nim
nim c -r --path:src --path:tools tests/lottie/test_exprc.nim
nim c -r --path:src tests/lottie/test_expr_runtime.nim
nim c -r --path:src --path:tools tests/lottie/test_expr_pack.nim
nim c -r --path:src tests/lottie/test_expr_audio_dense.nim

# Text compose oracle
nim c -r --path:src tests/lottie/test_text_compose.nim
```

### Nimble tasks

```bash
nimble examples      # compile examples into examples/build/
nimble lottieTest    # compile Lottie grid stress test
nimble lottieAot     # compile Lottie expressions AOT pack (LOTTIE_AOT_INPUT="...")
nimble testLottieHarness
```

## Lottie / Expressions

- Lottie is implemented as runtime-first, with AOT expression compilation (no JS engine).
- Expression registry uses hash lookup with D2 policy: `Strict` by default; `IgnoreCounted` only when explicitly requested.
- Generated packs can be checked/regenerated via exprc tools, e.g.:

```bash
nim c -r --path:src --path:tools tools/exprc/gen_audio_pack.nim -- --check
```

See:
- [`migration/STATUS.md`](migration/STATUS.md) — canonical status and gates
- [`docs/lottie-notes.md`](docs/lottie-notes.md) — implementation notes
- [`docs/lottie-expressions-notes.md`](docs/lottie-expressions-notes.md) — expression/AOT decisions and findings
- [`docs/AGENTS-expressions-aot.md`](docs/AGENTS-expressions-aot.md) — AOT plan/constraints

## Development Notes

- Do not commit generated test binaries, `HELP.md`, `HELP_extra.md`, or local `migration/STATE.md`.
- Keep `upstream/` read-only.
- Capture goldens from C++ harnesses/drivers, not from Nim.
- When changing AOT expression behavior, add/update tests first where practical and keep gates green.

## License

MIT (see `thorvg.nimble`). ThorVG upstream is subject to its own license in `upstream/`.
