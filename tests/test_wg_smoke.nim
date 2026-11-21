## Minimal W8 smoke test: wgpu-native headless init + ThorVG WG canvas target.
## Requires libwgpu_native installed (Linux: /usr/lib/libwgpu_native.so).

{.passL: "-lwgpu_native".}

import std/os
import thorvg/core/types
import thorvg/renderer/[shape, canvas]
import thorvg/engine/wg/[wg_ffi, wgcanvas]

proc onAdapter(status: WGPURequestAdapterStatus; adapter: WGPUAdapter;
               message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
  let p = cast[ptr WGPUAdapter](userdata1)
  if status == WGPURequestAdapterStatus_Success:
    p[] = adapter
  else:
    p[] = WGPUAdapter(nil)

proc onDevice(status: WGPURequestDeviceStatus; device: WGPUDevice;
              message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
  let p = cast[ptr WGPUDevice](userdata1)
  if status == WGPURequestDeviceStatus_Success:
    p[] = device
  else:
    p[] = WGPUDevice(nil)

proc onDeviceError(device: ptr WGPUDevice; errType: WGPUErrorType;
                   message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
  discard

when isMainModule:
  let w = 64'u32
  let h = 64'u32

  let instance = wgpuCreateInstance(nil)
  doAssert not instance.isNil, "wgpuCreateInstance failed"

  var adapter: WGPUAdapter
  var reqAdapterOpts = WGPURequestAdapterOptions(
    featureLevel: WGPUFeatureLevel_Compatibility,
    powerPreference: WGPUPowerPreference_HighPerformance
  )
  var reqAdapterCb = WGPURequestAdapterCallbackInfo(
    mode: WGPUCallbackMode_AllowProcessEvents,
    callback: onAdapter,
    userdata1: addr adapter
  )
  discard wgpuInstanceRequestAdapter(instance, addr reqAdapterOpts, reqAdapterCb)
  for _ in 0..<200:
    wgpuInstanceProcessEvents(instance)
    if not adapter.isNil: break
    sleep(10)
  doAssert not adapter.isNil, "wgpuInstanceRequestAdapter failed"

  var device: WGPUDevice
  var deviceDesc = WGPUDeviceDescriptor()
  deviceDesc.uncapturedErrorCallbackInfo.callback = onDeviceError
  var reqDeviceCb = WGPURequestDeviceCallbackInfo(
    mode: WGPUCallbackMode_AllowProcessEvents,
    callback: onDevice,
    userdata1: addr device
  )
  discard wgpuAdapterRequestDevice(adapter, addr deviceDesc, reqDeviceCb)
  for _ in 0..<200:
    wgpuInstanceProcessEvents(instance)
    if not device.isNil: break
    sleep(10)
  doAssert not device.isNil, "wgpuAdapterRequestDevice failed"

  var texDesc = WGPUTextureDescriptor(
    usage: WGPUTextureUsage_CopySrc or WGPUTextureUsage_CopyDst or WGPUTextureUsage_RenderAttachment,
    dimension: WGPUTextureDimension_2D,
    size: WGPUExtent3D(width: w, height: h, depthOrArrayLayers: 1),
    format: WGPUTextureFormat_BGRA8Unorm,
    mipLevelCount: 1,
    sampleCount: 1
  )
  let texture = wgpuDeviceCreateTexture(device, addr texDesc)
  doAssert not texture.isNil, "wgpuDeviceCreateTexture failed"

  let c = newWgCanvas()
  let res = c.target(WgCanvasContext(instance: cast[pointer](instance), adapter: cast[pointer](adapter), device: cast[pointer](device)),
                     cast[pointer](texture), w, h, ColorSpace.ABGR8888, 1)
  echo "target: ", res
  doAssert res == Result.Success

  let bg = newShape()
  doAssert bg.appendRect(0, 0, float32(w), float32(h)) == Result.Success
  doAssert bg.fill(40'u8, 80'u8, 160'u8, 255'u8) == Result.Success
  doAssert c.add(bg) == Result.Success
  echo "update: ", c.update()
  echo "draw: ", c.draw()
  echo "sync: ", c.sync()

  # Readback: copy rendered texture to mappable buffer and verify some pixel changed.
  let bytesPerPixel = 4'u32
  let unalignedBpr = w * bytesPerPixel
  let align = 256'u32
  let bytesPerRow = ((unalignedBpr + align - 1'u32) div align) * align
  let bufSize = uint64(bytesPerRow) * uint64(h)
  var bufDesc = WGPUBufferDescriptor(
    usage: WGPUBufferUsage_CopyDst or WGPUBufferUsage_MapRead,
    size: bufSize,
    mappedAtCreation: WGPUBool(0'u32)
  )
  let readBuf = wgpuDeviceCreateBuffer(device, addr bufDesc)
  doAssert not readBuf.isNil, "readback buffer create failed"

  var srcTex = WGPUTexelCopyTextureInfo(texture: texture, mipLevel: 0, origin: WGPUOrigin3D(x:0,y:0,z:0), aspect: WGPUTextureAspect_All)
  var dstBuf = WGPUTexelCopyBufferInfo(layout: WGPUTexelCopyBufferLayout(offset: 0'u64, bytesPerRow: bytesPerRow, rowsPerImage: h), buffer: readBuf)
  var copySize = WGPUExtent3D(width: w, height: h, depthOrArrayLayers: 1)
  let enc = wgpuDeviceCreateCommandEncoder(device, nil)
  wgpuCommandEncoderCopyTextureToBuffer(enc, addr srcTex, addr dstBuf, addr copySize)
  let cmd = wgpuCommandEncoderFinish(enc, nil)
  var cmdArr = [cmd]
  wgpuQueueSubmit(wgpuDeviceGetQueue(device), 1, addr cmdArr[0])
  wgpuCommandBufferRelease(cmd)
  wgpuCommandEncoderRelease(enc)

  var mapStatus = WGPUMapAsyncStatus_Error
  proc onMap(status: WGPUMapAsyncStatus; message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
    cast[ptr WGPUMapAsyncStatus](userdata1)[] = status
  var mapCb = WGPUBufferMapCallbackInfo(mode: WGPUCallbackMode_AllowProcessEvents, callback: onMap, userdata1: addr mapStatus)
  discard wgpuBufferMapAsync(readBuf, WGPUMapMode_Read, 0, csize_t(bufSize), mapCb)
  for _ in 0..<200:
    wgpuInstanceProcessEvents(instance)
    if mapStatus == WGPUMapAsyncStatus_Success: break
    sleep(10)
  echo "map: ", mapStatus
  doAssert mapStatus == WGPUMapAsyncStatus_Success, "buffer map failed"
  let data = cast[ptr UncheckedArray[byte]](wgpuBufferGetConstMappedRange(readBuf, 0, csize_t(bufSize)))
  # Check center pixel is not all-zero (bg was drawn with alpha)
  let px = int((h div 2) * bytesPerRow + (w div 2) * bytesPerPixel)
  echo "px: ", data[px], ",", data[px+1], ",", data[px+2], ",", data[px+3]
  doAssert data[px+3] != 0'u8, "expected rendered alpha"
  wgpuBufferUnmap(readBuf)
  wgpuBufferDestroy(readBuf)
  wgpuBufferRelease(readBuf)

  c.destroy()

  wgpuTextureDestroy(texture)
  wgpuTextureRelease(texture)
  wgpuDeviceRelease(device)
  wgpuAdapterRelease(adapter)
  wgpuInstanceRelease(instance)
  echo "wg smoke ok"
