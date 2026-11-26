#!/usr/bin/env bash
set -euo pipefail
# Reproducible Phase 1 expr dump.
# Requires: /tmp/opencode/thorvg-lottie-build (meson build of upstream 1.2.0-dev, extra=lottie_exp)
# Usage: ./run_expr_dump.sh <in.lot> <w> <h> <out.jsonl> [frames...]
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="/tmp/opencode/thorvg-lottie-build"
HARNESS="$ROOT/tests/lottie/harness/dump_expr.cpp"
BIN="/tmp/dump_expr"
if [ ! -d "$BUILD" ]; then echo "missing build dir: $BUILD" >&2; exit 1; fi
# compile harness linking against build objects (internal symbols hidden in .so)
OBJS=$(find "$BUILD/src/libthorvg-1.so.1.2.0.p" -name '*.o')
SIMD=$(find "$BUILD/src/renderer/cpu_engine" -name '*.a' | head -1)
g++ -std=c++17 -O2 \
  -I"$BUILD" -I"$ROOT/upstream/inc" -I"$ROOT/upstream/src" -I"$ROOT/upstream/src/common" \
  -I"$ROOT/upstream/src/renderer" -I"$ROOT/upstream/src/renderer/sw_engine" \
  -I"$ROOT/upstream/src/loaders" -I"$ROOT/upstream/src/loaders/lottie" \
  -I"$ROOT/upstream/src/modules" -I"$ROOT/upstream/src/modules/lottie" \
  -I"$ROOT/upstream/src/loaders/raw" \
  -I"$ROOT/upstream/src/modules/lottie/jerryscript/jerry-core/include" \
  -I"$ROOT/upstream/src/modules/lottie/jerryscript/jerry-core" \
  -I"$ROOT/upstream/src/modules/lottie/jerryscript/jerry-port/default/include" \
  -I"$BUILD/src" \
  "$HARNESS" $OBJS $SIMD -lpthread -ldl -lm -o "$BIN"
"$BIN" "$@"
