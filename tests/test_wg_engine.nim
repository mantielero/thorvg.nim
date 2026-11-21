## WG engine tests mirroring upstream/test/src/testWgEngine.cpp (headless, type=1).
{.passL: "-lwgpu_native".}

import std/[os, streams]
import thorvg/core/types
import thorvg/core/fill
import thorvg/renderer/[shape, paint, canvas, picture, scene]
import thorvg/renderer/effect
import thorvg/engine/wg/[wg_ffi, wgcanvas]
import thorvg/loaders/svg/loader

type TestWgEngine = object
  instance: WGPUInstance
  adapter: WGPUAdapter
  device: WGPUDevice
  texture: WGPUTexture
  w, h: uint32

proc onAdapter(status: WGPURequestAdapterStatus; adapter: WGPUAdapter; message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
  cast[ptr WGPUAdapter](userdata1)[] = if status == WGPURequestAdapterStatus_Success: adapter else: WGPUAdapter(nil)
proc onDevice(status: WGPURequestDeviceStatus; device: WGPUDevice; message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} =
  cast[ptr WGPUDevice](userdata1)[] = if status == WGPURequestDeviceStatus_Success: device else: WGPUDevice(nil)
proc onDeviceError(device: ptr WGPUDevice; errType: WGPUErrorType; message: WGPUStringView; userdata1, userdata2: pointer) {.cdecl.} = discard

proc initEngine(w = 100'u32, h = 100'u32): TestWgEngine =
  result.w = w; result.h = h
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
    format: WGPUTextureFormat_BGRA8Unorm, mipLevelCount: 1, sampleCount: 1)
  result.texture = wgpuDeviceCreateTexture(result.device, addr texDesc)
  doAssert not result.texture.isNil

proc target(e: TestWgEngine; c: Canvas): Result =
  c.target(WgCanvasContext(instance: cast[pointer](e.instance), adapter: cast[pointer](e.adapter), device: cast[pointer](e.device)),
           cast[pointer](e.texture), e.w, e.h, ColorSpace.ABGR8888, 1)

proc destroy(e: var TestWgEngine) =
  if not e.texture.isNil: wgpuTextureDestroy(e.texture); wgpuTextureRelease(e.texture); e.texture = WGPUTexture(nil)
  if not e.device.isNil: wgpuDeviceRelease(e.device); e.device = WGPUDevice(nil)
  if not e.adapter.isNil: wgpuAdapterRelease(e.adapter); e.adapter = WGPUAdapter(nil)
  if not e.instance.isNil: wgpuInstanceRelease(e.instance); e.instance = WGPUInstance(nil)

template check(r: Result) =
  doAssert r == Result.Success, $r

proc loadRawFile(path: string; w, h: int): seq[uint32] =
  var f = open(path, fmRead)
  defer: f.close()
  let n = w * h
  result = newSeq[uint32](n)
  let readBytes = f.readBuffer(addr result[0], n * 4)
  doAssert readBytes == n * 4, "raw read failed: " & path

when isMainModule:
  let resDir = currentSourcePath().parentDir() / ".." / "upstream" / "test" / "res"

  # WG Basic draw
  block:
    var eng = initEngine()
    let c = newWgCanvas()
    check eng.target(c)
    let masks = [MaskMethod.None, MaskMethod.Alpha, MaskMethod.InvAlpha, MaskMethod.Luma, MaskMethod.InvLuma,
                 MaskMethod.Add, MaskMethod.Subtract, MaskMethod.Intersect, MaskMethod.Difference, MaskMethod.Lighten, MaskMethod.Darken]
    let methods = [BlendMethod.Normal, BlendMethod.Multiply, BlendMethod.Screen, BlendMethod.Overlay, BlendMethod.Darken, BlendMethod.Lighten,
                   BlendMethod.ColorDodge, BlendMethod.ColorBurn, BlendMethod.HardLight, BlendMethod.SoftLight, BlendMethod.Difference,
                   BlendMethod.Hue, BlendMethod.Saturation, BlendMethod.Color, BlendMethod.Luminosity, BlendMethod.Add, BlendMethod.Composition]
    proc mkMask(): Shape =
      result = newShape()
      doAssert result.appendRect(0, 10, 20, 30, 5, 5) == Result.Success
      result.opacity = 127
      doAssert result.fill(255'u8,255'u8,255'u8,255'u8) == Result.Success
    for bm in methods:
      for maskOp in masks:
        let s1 = newShape()
        check s1.strokeFill(255'u8,255'u8,255'u8,255'u8)
        check s1.strokeWidth(2)
        check s1.blend(bm)
        if maskOp != MaskMethod.None: check s1.mask(mkMask(), maskOp)
        check c.add(s1)

        let s2 = newShape()
        check s2.moveTo(50,25); check s2.cubicTo(62,25,75,38,75,50); check s2.close()
        check s2.strokeFill(255'u8,0'u8,0'u8,125'u8); check s2.strokeWidth(1)
        check s2.blend(bm)
        if maskOp != MaskMethod.None: check s2.mask(mkMask(), maskOp)
        check c.add(s2)

        let s3 = newShape()
        check s3.moveTo(0,0); check s3.lineTo(20,0); check s3.lineTo(20,20); check s3.lineTo(0,20); check s3.close()
        check s3.fill(255'u8,255'u8,255'u8,255'u8); check s3.blend(bm)
        if maskOp != MaskMethod.None: check s3.mask(mkMask(), maskOp)
        check c.add(s3)

        let s4 = newShape()
        check s4.moveTo(0,0); check s4.lineTo(25,25); check s4.cubicTo(50,50,75,-75,50,100); check s4.close()
        check s4.fill(255'u8,255'u8,255'u8,255'u8)
        check s4.strokeFill(255'u8,0'u8,0'u8,255'u8); check s4.strokeWidth(2)
        check s4.strokeDash([2.5'f32, 5.0'f32], 0.0'f32)
        check s4.strokeCap(StrokeCap.Round)
        check s4.blend(bm)
        if maskOp != MaskMethod.None: check s4.mask(mkMask(), maskOp)
        check c.add(s4)
      check c.draw(true)
      check c.sync()
      check c.remove(Paint(nil))
    c.destroy(); eng.destroy()

  echo "wg engine tests ok (basic draw)"

  # WG Image Draw
  block:
    let rawPath = resDir / "rawimage_200x300.raw"
    if fileExists(rawPath):
      var eng = initEngine()
      let c = newWgCanvas()
      check eng.target(c)
      let pixels = loadRawFile(rawPath, 200, 300)
      let masks = [MaskMethod.None, MaskMethod.Alpha, MaskMethod.InvAlpha, MaskMethod.Luma, MaskMethod.InvLuma,
                   MaskMethod.Add, MaskMethod.Subtract, MaskMethod.Intersect, MaskMethod.Difference, MaskMethod.Lighten, MaskMethod.Darken]
      let methods = [BlendMethod.Normal, BlendMethod.Multiply, BlendMethod.Screen, BlendMethod.Overlay, BlendMethod.Darken, BlendMethod.Lighten,
                     BlendMethod.ColorDodge, BlendMethod.ColorBurn, BlendMethod.HardLight, BlendMethod.SoftLight, BlendMethod.Difference,
                     BlendMethod.Hue, BlendMethod.Saturation, BlendMethod.Color, BlendMethod.Luminosity, BlendMethod.Add, BlendMethod.Composition]
      proc mkMask(): Shape =
        result = newShape()
        doAssert result.appendRect(0, 10, 20, 30, 5, 5) == Result.Success
        doAssert result.fill(255'u8,255'u8,255'u8,255'u8) == Result.Success
      for bm in methods:
        for maskOp in masks:
          let pic = newPicture()
          check pic.loadRaw(pixels, 200'u32, 300'u32, ColorSpace.ARGB8888)
          check pic.blend(bm)
          if maskOp != MaskMethod.None: check pic.mask(mkMask(), maskOp)
          check c.add(pic)

          let pic2 = Picture(pic.duplicate())
          check pic2.clip(mkMask())
          check c.add(pic2)

          let pic3 = Picture(pic.duplicate())
          check pic3.rotate(45)
          check c.add(pic3)

          let pic4 = Picture(pic.duplicate())
          check pic4.scale(2.0'f32)
          check c.add(pic4)

          let pic5 = Picture(pic.duplicate())
          check pic5.scale(0.25'f32)
          check c.add(pic5)

          let pic6 = newPicture()
          check pic6.loadRaw(pixels, 200'u32, 300'u32, ColorSpace.ARGB8888)
          check pic6.clip(mkMask())
          check pic6.blend(bm)
          check c.add(pic6)

          let pic7 = Picture(pic6.duplicate())
          check pic7.scale(2.0'f32)
          check c.add(pic7)
        check c.draw()
        check c.sync()
        check c.remove(Paint(nil))
      c.destroy(); eng.destroy()
      echo "wg engine tests ok (image draw)"
    else:
      echo "skip wg image draw (missing raw)"

  # WG Filling Draw
  block:
    var eng = initEngine()
    let c = newWgCanvas()
    check eng.target(c)
    let masks = [MaskMethod.None, MaskMethod.Alpha, MaskMethod.InvAlpha, MaskMethod.Luma, MaskMethod.InvLuma,
                 MaskMethod.Add, MaskMethod.Subtract, MaskMethod.Intersect, MaskMethod.Difference, MaskMethod.Lighten, MaskMethod.Darken]
    let methods = [BlendMethod.Normal, BlendMethod.Multiply, BlendMethod.Screen, BlendMethod.Overlay, BlendMethod.Darken, BlendMethod.Lighten,
                   BlendMethod.ColorDodge, BlendMethod.ColorBurn, BlendMethod.HardLight, BlendMethod.SoftLight, BlendMethod.Difference,
                   BlendMethod.Hue, BlendMethod.Saturation, BlendMethod.Color, BlendMethod.Luminosity, BlendMethod.Add, BlendMethod.Composition]
    proc mkMask(): Shape =
      result = newShape()
      doAssert result.appendRect(10, 10, 20, 30, 5, 5) == Result.Success
      result.opacity = 127
      doAssert result.fill(255'u8,255'u8,255'u8,255'u8) == Result.Success
    let cs = @[ColorStop(offset:0.1f, r:0,g:0,b:0,a:0), ColorStop(offset:0.2f, r:50,g:25,b:50,a:25),
               ColorStop(offset:0.5f, r:100,g:100,b:100,a:125), ColorStop(offset:0.9f, r:255,g:255,b:255,a:255)]
    for bm in methods:
      for maskOp in masks:
        var linear = linearGradient(0.0, 0.0, 100.0, 120.0)
        linear.stops = cs
        linear.spread = FillSpread.Repeat
        let s1 = newShape()
        check s1.appendRect(0, 0, 50, 50, 5, 5)
        check s1.fill(linear)
        check s1.blend(bm)
        if maskOp != MaskMethod.None: check s1.mask(mkMask(), maskOp)
        check c.add(s1)

        var radial = radialGradient(50.0, 50.0, 50.0, 50.0, 50.0, 0.0)
        radial.stops = cs
        radial.spread = FillSpread.Pad
        let s2 = newShape()
        check s2.appendRect(50, 0, 50, 50)
        check s2.fill(radial)
        check s2.blend(bm)
        if maskOp != MaskMethod.None: check s2.mask(mkMask(), maskOp)
        check c.add(s2)
    check c.draw()
    check c.sync()
    c.destroy(); eng.destroy()
    echo "wg engine tests ok (filling draw)"

  # WG Image Rotation
  block:
    let rawPath = resDir / "rawimage_250x375.raw"
    if fileExists(rawPath):
      var eng = initEngine(960, 960)
      let c = newWgCanvas()
      check eng.target(c)
      let pixels = loadRawFile(rawPath, 250, 375)
      let pic = newPicture()
      check pic.loadRaw(pixels, 250'u32, 375'u32, ColorSpace.ARGB8888)
      check pic.size(240, 240)
      check pic.transform(Matrix(e11:0.572866f, e12: -4.431353f, e13:336.605835f, e21:5.198910f, e22: -0.386219f, e23:30.710693f, e31:0.0f, e32:0.0f, e33:1.0f))
      check c.add(pic)
      check c.draw(true)
      check c.sync()
      c.destroy(); eng.destroy()
      echo "wg engine tests ok (image rotation)"
    else:
      echo "skip wg image rotation (missing raw)"

  # WG Scene Effects
  block:
    let svgPath = resDir / "test0.svg"
    if fileExists(svgPath):
      var eng = initEngine()
      let c = newWgCanvas()
      check eng.target(c)
      let shape = newShape()
      check shape.appendCircle(50, 50, 30, 30)
      check shape.fill(0'u8,255'u8,0'u8,255'u8)
      let scene = newScene()
      check scene.add(shape)
      let picture = newPicture()
      check picture.load(svgPath)
      check scene.add(picture)
      check c.add(scene)

      check scene.clearEffects(); check scene.gaussianBlur(1.5, 0, 0, 75); check c.update(); check c.draw(); check c.sync()
      check scene.clearEffects(); check scene.gaussianBlur(1.5, 1, 0, 75); check c.update(); check c.draw(); check c.sync()
      check scene.clearEffects(); check scene.gaussianBlur(1.5, 2, 0, 75); check c.update(); check c.draw(); check c.sync()

      check scene.clearEffects(); check scene.motionBlur(10.0, 0.0, 75); check c.update(); check c.draw(); check c.sync()
      check scene.clearEffects(); check scene.motionBlur(10.0, 45.0, 75); check c.update(); check c.draw(); check c.sync()
      check scene.clearEffects(); check scene.motionBlur(10.0, 90.0, 75); check c.update(); check c.draw(); check c.sync()
      check scene.clearEffects(); check scene.motionBlur(0.0, 45.0, 75); check c.update(); check c.draw(); check c.sync()

      check scene.clearEffects(); check scene.dropShadow(128,128,128,200,45.0,5.0,2.0,60); check c.update(); check c.draw(); check c.sync()
      check scene.clearEffects(); check scene.dropShadow(128,128,128,200,45.0,5.0,0.0,60); check c.update(); check c.draw(); check c.sync()

      check scene.clearEffects(); check scene.fill(255,0,0,128); check c.update(); check c.draw(); check c.sync()
      check scene.clearEffects(); check scene.tint(0,0,0,255,255,255,50.0); check c.update(); check c.draw(); check c.sync()
      check scene.clearEffects(); check scene.tritone([0,0,0],[128,128,128],[255,255,255],128); check c.update(); check c.draw(); check c.sync()

      check scene.gaussianBlur(1.5, 0, 0, 75)
      check scene.motionBlur(10.0, 45.0, 75)
      check scene.dropShadow(128,128,128,200,45.0,5.0,2.0,60)
      check c.add(Scene(scene.duplicate()))
      check c.update(); check c.draw(); check c.sync()
      c.destroy(); eng.destroy()
      echo "wg engine tests ok (scene effects)"
    else:
      echo "skip wg scene effects (missing svg)"
