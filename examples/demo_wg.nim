## WebGPU demo: renders the shared demo scene with the WG (wgpu-native) backend.
##
##   demo_wg [--size WxH] [--out file.png|.bmp|.ppm] [--no-window]
##
## Linux (wgpu-native + SDL2): windowed mode uses a WG canvas type=0 on an SDL2
## surface and shows FPS in the window title; --no-window/--out uses an offscreen
## WG texture (type=1) readback and saves one frame.

import std/[os, strutils, times]

when defined(linux):
  {.passL: "-lwgpu_native -lSDL2".}
  {.passC: "-I/usr/include/SDL2 -D_REENTRANT".}
  {.compile: "wg_surface_sdl.c".}

  import std/[parseopt, tables]
  import thorvg/core/types
  from thorvg/core/fill import linearGradient, radialGradient, Fill
  import thorvg/renderer/[paint, shape, scene, canvas, render]
  import thorvg/engine/wg/[wg_ffi, wgcanvas]
  import thorvg/display/imageio
  import ./[demo_scene]

  type WgNativeWindow {.bycopy.} = object
    display*: pointer
    window*: uint64
    is_x11*: cint

  proc wg_sdl_init(outp: ptr WgNativeWindow; w, h: uint32): cint {.importc, cdecl.}
  proc wg_create_surface_sdl(instance: WGPUInstance; nw: ptr WgNativeWindow): WGPUSurface {.importc, cdecl.}
  proc wg_sdl_pump() {.importc, cdecl.}
  proc wg_sdl_set_title(title: cstring) {.importc, cdecl.}
  proc wg_sdl_quit() {.importc, cdecl.}

  type Options = object
    outFile: string
    noWindow: bool
    width, height: int

  proc parseSize(s: string, opts: var Options): bool =
    let parts = s.toLowerAscii.split('x')
    if parts.len == 2:
      try:
        opts.width = parseInt(parts[0]); opts.height = parseInt(parts[1])
        result = opts.width > 0 and opts.height > 0
      except ValueError: discard

  proc parseOptions(): Options =
    result = Options(width: 400, height: 300)
    var p = initOptParser(commandLineParams(), longNoVal = @["no-window"])
    for kind, key, val in p.getopt():
      case kind
      of cmdArgument: discard
      of cmdLongOption:
        case key
        of "out": result.outFile = val
        of "no-window": result.noWindow = true
        of "size":
          if not parseSize(val, result): quit("bad --size: " & val, 2)
        else: quit("unknown option --" & key, 2)
      else: discard

  proc onAdapter(status: WGPURequestAdapterStatus; adapter: WGPUAdapter;
                 message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
    cast[ptr WGPUAdapter](userdata1)[] =
      if status == WGPURequestAdapterStatus_Success: adapter else: WGPUAdapter(nil)

  proc onDevice(status: WGPURequestDeviceStatus; device: WGPUDevice;
                message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
    cast[ptr WGPUDevice](userdata1)[] =
      if status == WGPURequestDeviceStatus_Success: device else: WGPUDevice(nil)

  proc onDeviceError(device: ptr WGPUDevice; errType: WGPUErrorType;
                     message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
    discard

  proc requestAdapter(instance: WGPUInstance): WGPUAdapter =
    var adapter: WGPUAdapter
    var reqAdapterOpts = WGPURequestAdapterOptions(
      featureLevel: WGPUFeatureLevel_Compatibility,
      powerPreference: WGPUPowerPreference_HighPerformance)
    var reqAdapterCb = WGPURequestAdapterCallbackInfo(
      mode: WGPUCallbackMode_AllowProcessEvents, callback: onAdapter, userdata1: addr adapter)
    discard wgpuInstanceRequestAdapter(instance, addr reqAdapterOpts, reqAdapterCb)
    for _ in 0..<200:
      wgpuInstanceProcessEvents(instance)
      if not adapter.isNil: break
      sleep(10)
    result = adapter

  proc requestDevice(instance: WGPUInstance; adapter: WGPUAdapter): WGPUDevice =
    var device: WGPUDevice
    var deviceDesc = WGPUDeviceDescriptor()
    deviceDesc.uncapturedErrorCallbackInfo.callback = onDeviceError
    var reqDeviceCb = WGPURequestDeviceCallbackInfo(
      mode: WGPUCallbackMode_AllowProcessEvents, callback: onDevice, userdata1: addr device)
    discard wgpuAdapterRequestDevice(adapter, addr deviceDesc, reqDeviceCb)
    for _ in 0..<200:
      wgpuInstanceProcessEvents(instance)
      if not device.isNil: break
      sleep(10)
    result = device

  proc saveSurface(path: string, s: RenderSurface) =
    case splitFile(path).ext.toLowerAscii
    of ".bmp": writeBmp(path, s)
    of ".png": writePng(path, s)
    of ".ppm": writePpm(path, s)
    else: quit("--out must end in .bmp, .png or .ppm: " & path, 2)

  proc renderHeadless(opts: Options) =
    let w = uint32(opts.width)
    let h = uint32(opts.height)
    let instance = wgpuCreateInstance(nil)
    if instance.isNil: quit("wgpuCreateInstance failed", 1)
    let adapter = requestAdapter(instance)
    if adapter.isNil: quit("wgpu adapter request failed", 1)
    let device = requestDevice(instance, adapter)
    if device.isNil: quit("wgpu device request failed", 1)

    var texDesc = WGPUTextureDescriptor(
      usage: WGPUTextureUsage_CopySrc or WGPUTextureUsage_CopyDst or WGPUTextureUsage_RenderAttachment,
      dimension: WGPUTextureDimension_2D,
      size: WGPUExtent3D(width: w, height: h, depthOrArrayLayers: 1),
      format: WGPUTextureFormat_BGRA8Unorm,
      mipLevelCount: 1, sampleCount: 1)
    let texture = wgpuDeviceCreateTexture(device, addr texDesc)
    if texture.isNil: quit("wgpu texture create failed", 1)

    let c = newWgCanvas()
    check c.target(WgCanvasContext(instance: cast[pointer](instance), adapter: cast[pointer](adapter), device: cast[pointer](device)),
                   cast[pointer](texture), w, h, ColorSpace.ABGR8888, 1)
    buildDemoScene(c)
    check c.update(); check c.draw(); check c.sync()

    let bytesPerPixel = 4'u32
    let align = 256'u32
    let bytesPerRow = ((w * bytesPerPixel + align - 1'u32) div align) * align
    let bufSize = uint64(bytesPerRow) * uint64(h)
    var bufDesc = WGPUBufferDescriptor(usage: WGPUBufferUsage_CopyDst or WGPUBufferUsage_MapRead, size: bufSize, mappedAtCreation: WGPUBool(0'u32))
    let readBuf = wgpuDeviceCreateBuffer(device, addr bufDesc)
    if readBuf.isNil: quit("wgpu readback buffer failed", 1)

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
    if mapStatus != WGPUMapAsyncStatus_Success: quit("wgpu map failed", 1)

    let data = cast[ptr UncheckedArray[byte]](wgpuBufferGetConstMappedRange(readBuf, 0, csize_t(bufSize)))
    var surf = newSurface(w, h, ColorSpace.ABGR8888S)
    surf.premultiplied = true
    for y in 0..<int(h):
      for x in 0..<int(w):
        let off = y * int(bytesPerRow) + x * 4
        let b = uint32(data[off + 0])
        let g = uint32(data[off + 1])
        let r = uint32(data[off + 2])
        let a = uint32(data[off + 3])
        surf.data[y * int(w) + x] = (a shl 24) or (b shl 16) or (g shl 8) or r
    wgpuBufferUnmap(readBuf)
    wgpuBufferDestroy(readBuf); wgpuBufferRelease(readBuf)

    if opts.outFile.len > 0:
      saveSurface(opts.outFile, surf)
      echo "saved: ", opts.outFile

    c.destroy()
    wgpuTextureDestroy(texture); wgpuTextureRelease(texture)
    wgpuDeviceRelease(device); wgpuAdapterRelease(adapter); wgpuInstanceRelease(instance)

  proc renderWindowed(opts: Options) =
    let w = uint32(opts.width)
    let h = uint32(opts.height)
    var nw: WgNativeWindow
    let rc = wg_sdl_init(addr nw, w, h)
    if rc != 0:
      echo "demo_wg: SDL2 window init failed (", rc, "), falling back to headless."
      renderHeadless(opts)
      return

    let instance = wgpuCreateInstance(nil)
    if instance.isNil: wg_sdl_quit(); quit("wgpuCreateInstance failed", 1)
    let adapter = requestAdapter(instance)
    let device = if not adapter.isNil: requestDevice(instance, adapter) else: WGPUDevice(nil)
    let surface = if not device.isNil: wg_create_surface_sdl(instance, addr nw) else: WGPUSurface(nil)
    if adapter.isNil or device.isNil or surface.isNil:
      echo "demo_wg: wgpu init/surface failed, falling back to headless."
      if not surface.isNil: wgpuSurfaceRelease(surface)
      if not device.isNil: wgpuDeviceRelease(device)
      if not adapter.isNil: wgpuAdapterRelease(adapter)
      wgpuInstanceRelease(instance)
      wg_sdl_quit()
      renderHeadless(opts)
      return

    let c = newWgCanvas()
    let tgt = c.target(WgCanvasContext(instance: cast[pointer](instance), adapter: cast[pointer](adapter), device: cast[pointer](device)),
                       cast[pointer](surface), w, h, ColorSpace.ABGR8888, 0)
    if tgt != Result.Success:
      echo "demo_wg: WG surface target failed: ", tgt, "; falling back to headless."
      c.destroy(); wgpuSurfaceRelease(surface); wgpuDeviceRelease(device); wgpuAdapterRelease(adapter); wgpuInstanceRelease(instance); wg_sdl_quit()
      renderHeadless(opts)
      return

    buildDemoScene(c)
    check c.update(); check c.draw(); check c.sync()
    wg_sdl_pump()

    if opts.outFile.len > 0:
      echo "note: --out with windowed WG uses headless texture readback for save"
      c.destroy(); wgpuSurfaceRelease(surface); wgpuDeviceRelease(device); wgpuAdapterRelease(adapter); wgpuInstanceRelease(instance); wg_sdl_quit()
      renderHeadless(opts)
      return

    echo "demo_wg: window open (close window or Ctrl+C to exit)"
    var frames = 0
    var last = epochTime()
    for _ in 0..<6000: # ~100s at 60fps-ish; user can close/Ctrl+C
      wg_sdl_pump()
      check c.update()
      check c.draw()
      check c.sync()
      inc frames
      let now = epochTime()
      if now - last >= 1.0:
        let fps = frames.float / (now - last)
        frames = 0
        last = now
        wg_sdl_set_title(("ThorVG WebGPU demo - FPS: " & $int(fps)).cstring)
      sleep(1)

    c.destroy()
    wgpuSurfaceRelease(surface)
    wgpuDeviceRelease(device); wgpuAdapterRelease(adapter); wgpuInstanceRelease(instance)
    wg_sdl_quit()

  proc main() =
    let opts = parseOptions()
    if opts.noWindow or opts.outFile.len > 0:
      renderHeadless(opts)
    else:
      renderWindowed(opts)

  main()

else:
  proc main() =
    echo "demo_wg: WebGPU demo currently targets Linux + wgpu-native + SDL2."
    echo "Build on Linux with libwgpu_native and SDL2 installed."
  main()
