version       = "0.1.0"
author        = "migration"
description   = "Nim port of ThorVG (vector graphics engine), CPU renderer first"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task examples, "Compile example programs into examples/build/":
  mkDir "examples/build"
  for name in ["hello", "shapes", "text", "viewer", "demo_cpu", "demo_gl", "demo_wg"]:
    exec "nim c --outdir:examples/build --nimcache:examples/build/nimcache/" & name &
      " examples/" & name & ".nim"

task testLottieHarness, "Compare Lottie golden outputs (Phase 0 self-check)":
  exec "nim c -r --hints:off --warnings:off tests/lottie/harness/compare.nim tests/lottie/golden"
