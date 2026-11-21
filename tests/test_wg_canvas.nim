## WG canvas tests mirroring upstream/test/src/testWgCanvas.cpp (headless, type=1).
{.passL: "-lwgpu_native".}

import std/os
import thorvg/core/types
import thorvg/renderer/[shape, paint, canvas, picture, scene]
import thorvg/engine/wg/[wg_ffi, wgcanvas]

type TestWgEngine = object
  instance: WGPUInstance
  adapter: WGPUAdapter
  device: WGPUDevice
  texture: WGPUTexture
  w, h: uint32
  format: WGPUTextureFormat

proc onAdapter(status: WGPURequestAdapterStatus; adapter: WGPUAdapter;
               message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
  let p = cast[ptr WGPUAdapter](userdata1)
  p[] = if status == WGPURequestAdapterStatus_Success: adapter else: WGPUAdapter(nil)

proc onDevice(status: WGPURequestDeviceStatus; device: WGPUDevice;
              message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
  let p = cast[ptr WGPUDevice](userdata1)
  p[] = if status == WGPURequestDeviceStatus_Success: device else: WGPUDevice(nil)

proc onDeviceError(device: ptr WGPUDevice; errType: WGPUErrorType;
                   message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} = discard

proc initEngine(w = 100'u32, h = 100'u32): TestWgEngine =
  result.w = w; result.h = h; result.format = WGPUTextureFormat_BGRA8Unorm
  result.instance = wgpuCreateInstance(nil)
  doAssert not result.instance.isNil
  var reqAdapterOpts = WGPURequestAdapterOptions(featureLevel: WGPUFeatureLevel_Compatibility, powerPreference: WGPUPowerPreference_HighPerformance)
  var reqAdapterCb = WGPURequestAdapterCallbackInfo(mode: WGPUCallbackMode_AllowProcessEvents, callback: onAdapter, userdata1: addr result.adapter)
  discard wgpuInstanceRequestAdapter(result.instance, addr reqAdapterOpts, reqAdapterCb)
  for _ in 0..<200:
    wgpuInstanceProcessEvents(result.instance)
    if not result.adapter.isNil: break
    sleep(10)
  doAssert not result.adapter.isNil
  var deviceDesc = WGPUDeviceDescriptor()
  deviceDesc.uncapturedErrorCallbackInfo.callback = onDeviceError
  var reqDeviceCb = WGPURequestDeviceCallbackInfo(mode: WGPUCallbackMode_AllowProcessEvents, callback: onDevice, userdata1: addr result.device)
  discard wgpuAdapterRequestDevice(result.adapter, addr deviceDesc, reqDeviceCb)
  for _ in 0..<200:
    wgpuInstanceProcessEvents(result.instance)
    if not result.device.isNil: break
    sleep(10)
  doAssert not result.device.isNil
  var texDesc = WGPUTextureDescriptor(
    usage: WGPUTextureUsage_CopySrc or WGPUTextureUsage_CopyDst or WGPUTextureUsage_RenderAttachment,
    dimension: WGPUTextureDimension_2D,
    size: WGPUExtent3D(width: w, height: h, depthOrArrayLayers: 1),
    format: result.format, mipLevelCount: 1, sampleCount: 1)
  result.texture = wgpuDeviceCreateTexture(result.device, addr texDesc)
  doAssert not result.texture.isNil

proc target(e: TestWgEngine; c: Canvas): Result =
  c.target(WgCanvasContext(instance: cast[pointer](e.instance), adapter: cast[pointer](e.adapter), device: cast[pointer](e.device)),
           cast[pointer](e.texture), e.w, e.h, ColorSpace.ABGR8888, 1)

proc destroy(e: var TestWgEngine) =
  if not e.texture.isNil:
    wgpuTextureDestroy(e.texture); wgpuTextureRelease(e.texture); e.texture = WGPUTexture(nil)
  if not e.device.isNil: wgpuDeviceRelease(e.device); e.device = WGPUDevice(nil)
  if not e.adapter.isNil: wgpuAdapterRelease(e.adapter); e.adapter = WGPUAdapter(nil)
  if not e.instance.isNil: wgpuInstanceRelease(e.instance); e.instance = WGPUInstance(nil)

template check(r: Result) =
  doAssert r == Result.Success, $r

when isMainModule:
  # Basic Creation
  block:
    var eng = initEngine()
    let c1 = newWgCanvas(); doAssert c1 != nil
    let c2 = newWgCanvas(); doAssert c2 != nil
    c1.destroy(); c2.destroy(); eng.destroy()

  # Pushing Paints
  block:
    var eng = initEngine()
    let c = newWgCanvas()
    check eng.target(c)
    check c.add(newShape())
    check c.add(newPicture())
    check c.add(newScene())
    check c.update()
    check c.add(newShape())
    check c.add(newShape())
    check c.remove(Paint(nil))
    let p0 = Paint(newShape()); check c.add(p0)
    let p1 = Paint(newShape()); check c.add(p1)
    check c.draw()
    let list = c.paints()
    doAssert list.len == 2
    doAssert list[0] == p0
    doAssert list[1] == p1
    c.destroy(); eng.destroy()

  # Update
  block:
    var eng = initEngine()
    let c = newWgCanvas()
    check eng.target(c)
    check c.update()
    check c.add(newShape())
    check c.add(newShape())
    check c.update()
    check c.draw()
    doAssert c.update() == Result.InsufficientCondition
    check c.sync()
    check c.update()
    c.destroy(); eng.destroy()

  # Synchronized Drawing
  block:
    var eng = initEngine()
    let c = newWgCanvas()
    check c.sync()
    doAssert c.draw() == Result.InsufficientCondition
    check eng.target(c)
    check c.draw()
    check c.sync()
    check c.add(newShape()) # empty shape
    check c.draw()
    check c.sync()
    let s2 = newShape()
    doAssert s2.appendRect(0, 0, 100, 100) == Result.Success
    doAssert s2.fill(255'u8,255'u8,255'u8,255'u8) == Result.Success
    check c.add(s2)
    check c.draw()
    check c.sync()
    c.destroy(); eng.destroy()

  # Viewport
  block:
    var eng = initEngine()
    let c = newWgCanvas()
    check c.viewport(25, 25, 100, 100)
    check eng.target(c)
    check c.viewport(25, 25, 50, 50)
    let s = newShape()
    doAssert s.appendRect(0, 0, 100, 100) == Result.Success
    doAssert s.fill(255'u8,255'u8,255'u8,255'u8) == Result.Success
    check c.add(s)
    # Negative, not allowed while drawing/sync? C++ expects InsufficientCondition after draw/sync constraints.
    doAssert c.viewport(15, 25, 5, 5) == Result.InsufficientCondition
    check c.draw()
    doAssert c.viewport(25, 25, 10, 10) == Result.InsufficientCondition
    check c.sync()
    c.destroy(); eng.destroy()

  echo "wg canvas tests ok"
