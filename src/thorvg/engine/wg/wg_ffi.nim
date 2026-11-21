## Facade for WebGPU (wgpu-native) bindings used by the Nim port of ThorVG's WG engine.
## Import this module for handle types, constants and raw `wgpu*` declarations.
##
## UNSAFE surface is provided by `wgpu_raw_ffi` (importc procs, C structs). Higher-level
## safe wrappers/helpers should be added here or in `wg_common.nim` as the port progresses.

import std/os
import ./wg_types
import ./wgpu_raw_ffi

export wg_types, wgpu_raw_ffi

template wgPollEvents*(instance: WGPUInstance; timeoutMs: int; body: untyped): bool =
  ## Poll wgpu-native instance events until `body` becomes true or timeout.
  ## Avoids `wgpuInstanceWaitAny` (unimplemented in some wgpu-native builds).
  var ok = false
  let loops = max(1, timeoutMs div 10)
  for _ in 0 ..< loops:
    wgpuInstanceProcessEvents(instance)
    if body:
      ok = true
      break
    sleep(10)
  ok
