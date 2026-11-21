## WG surface (type=0) smoke: SDL2 window + wgpu-native surface present.
{.passL: "-lwgpu_native -lSDL2".}
{.passC: "-I/usr/include/SDL2 -D_REENTRANT".}
{.compile: "wg_surface_sdl.c".}

import std/os
import thorvg/core/types
import thorvg/renderer/[shape, canvas]
import thorvg/engine/wg/[wg_ffi, wgcanvas]

type WgNativeWindow {.bycopy.} = object
  display*: pointer
  window*: uint64
  is_x11*: cint

proc wg_sdl_init(outp: ptr WgNativeWindow; w, h: uint32): cint {.importc, cdecl.}
proc wg_create_surface_sdl(instance: WGPUInstance; nw: ptr WgNativeWindow): WGPUSurface {.importc, cdecl.}
proc wg_sdl_pump() {.importc, cdecl.}
proc wg_sdl_quit() {.importc, cdecl.}

proc onAdapter(status: WGPURequestAdapterStatus; adapter: WGPUAdapter; message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
  cast[ptr WGPUAdapter](userdata1)[] = if status == WGPURequestAdapterStatus_Success: adapter else: WGPUAdapter(nil)
proc onDevice(status: WGPURequestDeviceStatus; device: WGPUDevice; message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
  cast[ptr WGPUDevice](userdata1)[] = if status == WGPURequestDeviceStatus_Success: device else: WGPUDevice(nil)
proc onDeviceError(device: ptr WGPUDevice; errType: WGPUErrorType; message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} = discard

when isMainModule:
  var nw: WgNativeWindow
  let rc = wg_sdl_init(addr nw, 128, 128)
  if rc != 0:
    echo "sdl init failed: ", rc
    quit(0) # environment may not support window/surface
  let instance = wgpuCreateInstance(nil)
  doAssert not instance.isNil
  var adapter: WGPUAdapter
  var reqAdapterOpts = WGPURequestAdapterOptions(featureLevel: WGPUFeatureLevel_Compatibility, powerPreference: WGPUPowerPreference_HighPerformance)
  var reqAdapterCb = WGPURequestAdapterCallbackInfo(mode: WGPUCallbackMode_AllowProcessEvents, callback: onAdapter, userdata1: addr adapter)
  discard wgpuInstanceRequestAdapter(instance, addr reqAdapterOpts, reqAdapterCb)
  for _ in 0..<200:
    wgpuInstanceProcessEvents(instance)
    if not adapter.isNil: break
    sleep(10)
  doAssert not adapter.isNil, "adapter"
  var device: WGPUDevice
  var deviceDesc = WGPUDeviceDescriptor()
  deviceDesc.uncapturedErrorCallbackInfo.callback = onDeviceError
  var reqDeviceCb = WGPURequestDeviceCallbackInfo(mode: WGPUCallbackMode_AllowProcessEvents, callback: onDevice, userdata1: addr device)
  discard wgpuAdapterRequestDevice(adapter, addr deviceDesc, reqDeviceCb)
  for _ in 0..<200:
    wgpuInstanceProcessEvents(instance)
    if not device.isNil: break
    sleep(10)
  doAssert not device.isNil, "device"

  let surface = wg_create_surface_sdl(instance, addr nw)
  doAssert not surface.isNil, "surface"

  let c = newWgCanvas()
  let res = c.target(WgCanvasContext(instance: cast[pointer](instance), adapter: cast[pointer](adapter), device: cast[pointer](device)),
                     cast[pointer](surface), 128, 128, ColorSpace.ABGR8888, 0)
  echo "target: ", res
  doAssert res == Result.Success

  let bg = newShape()
  doAssert bg.appendRect(0, 0, 128, 128) == Result.Success
  doAssert bg.fill(20'u8, 120'u8, 220'u8, 255'u8) == Result.Success
  doAssert c.add(bg) == Result.Success
  echo "update: ", c.update()
  echo "draw: ", c.draw()
  echo "sync: ", c.sync()
  wg_sdl_pump()

  c.destroy()
  wgpuSurfaceRelease(surface)
  wgpuDeviceRelease(device)
  wgpuAdapterRelease(adapter)
  wgpuInstanceRelease(instance)
  wg_sdl_quit()
  echo "wg surface smoke ok"
