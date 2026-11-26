# Agent Guide

This guide is for humans and coding agents working in this repository.

## Read First

1. `README.md` - project overview and quick commands.
2. `migration/STATUS.md` - canonical current status (local migration state).
3. `docs/ARCHITECTURE.md` - architecture and design boundaries.
4. `docs/lottie-notes.md` and `docs/lottie-expressions-notes.md` - Lottie/AOT implementation notes.
5. `migration/DECISIONS.md` and `migration/STATE.md` - migration rationale and history (local).

## Working Rules

- **Do not edit `upstream/`**. It is the C++ reference.
- **No silent degradation**. Unsupported or uncompiled behavior must be explicit: structured error, diagnostic, or documented XFAIL/AAEDGE with evidence.
- **Keep unsafe code isolated**. `ptr`/`addr`/`cast`/`importc`/`emit` only in `*_ffi.nim`, `*_unsafe.nim`, or `*_oracle.nim` files (or explicitly accepted exemptions).
- **Preserve behavior**. Prefer fixes with root-cause evidence; do not relax tolerances or weaken tests to pass.
- **Small, verifiable changes**. Run targeted tests/gates before claiming success.
- **English for repo docs**. Keep documentation text in English.

## Lottie / AOT Expression Rules

- **Zero JS**: no JS engine, no runtime interpreter, no `eval`/`Function`/`with`/regex literals/dynamic global-name access.
- **AOT only**: expressions are compiled into generated Nim packs and bound by hash.
- **D2 policy**: registry hash lookup. `Strict` by default (unknown/uncompiled hash => structured error). `IgnoreCounted` only when explicitly requested.
- **D1-exc1**: no C++ `$bm_rt` global leak/order-dependent behavior. Missing definitive `$bm_rt` assignment => static fallback + counted warning.
- **No global mutable expression state**. Use explicit `ExprCtx`.
- **Boundary single source**: `src/thorvg/lottie/expr/boundary.nim` (`toPropScalar`, `toPropVec`, `toPropOpacityU8`).
- **One phase/iteration** for expression work; tests first for new behavior; keep gates green.

## Verification

Common commands (adjust paths/toolchain as needed):

```bash
# Lottie gates
nim c -r --path:src --path:tools tests/lottie/test_phase2_builder.nim
nim c -r --path:src tests/lottie/test_text_compose.nim

# Expression gates
nim c -r --path:src tests/lottie/test_expr_boundary.nim
nim c -r --path:src --path:tools tests/lottie/test_exprc.nim
nim c -r --path:src tests/lottie/test_expr_runtime.nim
nim c -r --path:src --path:tools tests/lottie/test_expr_pack.nim
nim c -r --path:src tests/lottie/test_expr_audio_dense.nim
```

When adding/changing generated expression packs, also verify regen/check:

```bash
nim c -r --path:src --path:tools tools/exprc/gen_audio_pack.nim -- --check
```

## Documentation and State

- **Canonical status**: `migration/STATUS.md` (local, gitignored by current repo config).
- **Architecture**: `docs/ARCHITECTURE.md`.
- **Lottie notes**: `docs/lottie-notes.md`, `docs/lottie-expressions-notes.md`.
- **AOT plan**: `docs/AGENTS-expressions-aot.md`.
- Do not commit `HELP.md`, `HELP_extra.md`, `migration/STATE.md`, or generated test binaries unless explicitly requested.

## Commit Hygiene

- Commit code + docs needed to explain/verify the change.
- Do not include unrelated local work.
- Prefer clear commit messages describing scope and verification.