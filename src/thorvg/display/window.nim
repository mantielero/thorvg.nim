## Cross-platform window API for showing rendered surfaces.
##
## Minimal backend interface provided by this module:
##   - open/openWindow: create a window
##   - presentBuffer/present: show a pixel buffer or a RenderSurface
##   - pollEvents: pump OS events and update input state
##   - close: destroy the window
##
## Backends:
##   - Windows: native Win32 implementation (`win32_ffi`)
##   - Other platforms: SDL2 loaded via dynlib (skeleton; requires SDL2 runtime)
##
## Typical loop:
##   let win = openWindow("demo", 800, 600)
##   win.present(surface)
##   while win.pollEvents(): discard   # or just `win.waitClose()`
##
## `autoCloseMs` (or the env var `THORVG_AUTOCLOSE_MS` when it is -1) closes the
## window after that many milliseconds, which eases automated runs.

import std/[os, strutils]
import ../renderer/render

const
  KeyEnter* = 13
  KeyEscape* = 27
  KeySpace* = 32
  KeyLeft* = 37
  KeyUp* = 38
  KeyRight* = 39
  KeyDown* = 40
  MouseLeft* = 0
  MouseRight* = 1
  MouseMiddle* = 2

type
  WindowError* = object of CatchableError

  ## Minimal event kinds used by the high-level input state.
  BkEventKind* = enum
    bkKeyDown, bkKeyUp, bkMouseMove, bkMouseDown, bkMouseUp, bkWheel, bkQuit

  BkEvent* = object
    kind*: BkEventKind
    a*, b*, button*: int

when defined(windows):
  import ./[win32_ffi, imageio]

  type
    Window* = ref object
      width*, height*: int          ## client area size in pixels
      hwnd: int
      frame: seq[uint32]            ## last presented frame, 0xAARRGGBB top-down
      frameW, frameH: int
      open: bool
      keys, pressed: array[256, bool]
      buttons: array[3, bool]
      mx, my, wheel: int
      deadline: uint64              ## tick at which to auto-close; 0 = never
      events: seq[W32Event]

  proc openWindow*(title: string, w, h: int, autoCloseMs: int = -1): Window =
    ## Opens a fixed-size window. `autoCloseMs`: > 0 closes after that many ms,
    ## 0 disables, -1 (default) reads `THORVG_AUTOCLOSE_MS` from the environment.
    if w <= 0 or h <= 0: raise newException(WindowError, "invalid window size")
    let hwnd = w32CreateWindow(title, w, h)
    if hwnd == 0: raise newException(WindowError, "cannot create window")
    var ms = autoCloseMs
    if ms < 0:
      ms = try: parseInt(getEnv("THORVG_AUTOCLOSE_MS", "0")) except ValueError: 0
    result = Window(width: w, height: h, hwnd: hwnd, open: true)
    if ms > 0: result.deadline = w32Ticks() + uint64(ms)

  proc isOpen*(win: Window): bool = win.open and w32IsWindow(win.hwnd)

  proc close*(win: Window) =
    if win.open:
      w32Destroy(win.hwnd)
      win.open = false

  proc setTitle*(win: Window, title: string) =
    if win.open: w32SetTitle(win.hwnd, title)

  proc presentBuffer*(win: Window, pixels: openArray[uint32], w, h, stride: int) =
    ## Minimal backend present: shows `w*h` pixels (0xAARRGGBB, top-down) with the
    ## given stride in pixels, stretched to the window client area.
    if win.open and w > 0 and h > 0 and stride >= w and pixels.len >= stride * h:
      win.frameW = w
      win.frameH = h
      win.frame.setLen(w * h)
      if stride == w:
        for i in 0 ..< w * h: win.frame[i] = pixels[i]
      else:
        for y in 0..<h:
          for x in 0..<w:
            win.frame[y * w + x] = pixels[y * stride + x]
      w32Blit(win.hwnd, win.frame, win.frameW, win.frameH, win.width, win.height)

  proc present*(win: Window, s: RenderSurface) =
    ## Shows `s` (any 32-bit or gray color space, composited over black),
    ## stretched to the client area.
    if win.open and s != nil and s.w > 0 and s.h > 0:
      win.frameW = int(s.w)
      win.frameH = int(s.h)
      win.frame.setLen(win.frameW * win.frameH)
      for y in 0..<win.frameH:
        for x in 0..<win.frameW:
          let p = s.rgbOverBlack(x, y)
          win.frame[y * win.frameW + x] = 0xFF000000'u32 or (uint32(p.r) shl 16) or
            (uint32(p.g) shl 8) or uint32(p.b)
      w32Blit(win.hwnd, win.frame, win.frameW, win.frameH, win.width, win.height)

  proc apply(win: Window, ev: W32Event) =
    case ev.kind
    of wkKeyDown:
      if ev.a in 0..255:
        win.keys[ev.a] = true
        win.pressed[ev.a] = true
    of wkKeyUp:
      if ev.a in 0..255: win.keys[ev.a] = false
    of wkMouseMove:
      win.mx = ev.a
      win.my = ev.b
    of wkMouseDown, wkMouseUp:
      win.mx = ev.a
      win.my = ev.b
      if ev.button in 0..2: win.buttons[ev.button] = ev.kind == wkMouseDown
    of wkWheel: win.wheel += ev.a

  proc pollEvents*(win: Window): bool =
    ## Processes pending OS messages and updates the input state.
    ## Returns false once the window is closed (by the user or by auto-close).
    if win.open:
      win.pressed = default(array[256, bool])
      win.wheel = 0
      win.events.setLen(0)
      let repaint = w32Pump(win.hwnd, win.events)
      for ev in win.events: win.apply(ev)
      if not w32IsWindow(win.hwnd): win.open = false
      elif win.deadline != 0 and w32Ticks() >= win.deadline: win.close()
      elif repaint and win.frame.len > 0:
        w32Blit(win.hwnd, win.frame, win.frameW, win.frameH, win.width, win.height)
    result = win.open

  proc waitClose*(win: Window) =
    ## Blocks (polling every 10 ms) until the window is closed.
    while win.pollEvents(): w32Sleep(10)

  proc keyDown*(win: Window, key: int): bool =
    ## True while virtual key `key` (e.g. `KeyEscape`, ord('A')) is held.
    key in 0..255 and win.keys[key]

  proc keyPressed*(win: Window, key: int): bool =
    ## True if `key` went down during the last `pollEvents`.
    key in 0..255 and win.pressed[key]

  proc mouseX*(win: Window): int = win.mx
  proc mouseY*(win: Window): int = win.my
  proc mouseDown*(win: Window, button: int): bool = button in 0..2 and win.buttons[button]
  proc wheelDelta*(win: Window): int = win.wheel   ## notches during the last poll

else:
  # SDL2 backend (Linux, macOS, ...), loaded at runtime via dynlib.
  # This is a minimal skeleton intended to provide the same high-level window API
  # as the Win32 backend. It requires the SDL2 runtime library to be available.
  #
  # NOTE on output parity: before relying on window presentation, verify that
  # headless `--no-window` image outputs (e.g. PNG) are identical across
  # platforms/builds. Differences there usually come from the render/port
  # (SIMD, endianness, font handling), not from the window backend.

  import ./imageio

  when defined(macosx):
    const sdlLib = "libSDL2.dylib"
  elif defined(windows):
    const sdlLib = "SDL2.dll"
  else:
    const sdlLib = "libSDL2-2.0.so.0(|.1|.2|.3|.4|.5|.6|.7|.8|.9|.10|.11|.12|.13|.14|.15)"

  const
    SDL_INIT_VIDEO = 0x00000020'u32
    SDL_WINDOW_SHOWN = 0x00000004'u32
    SDL_RENDERER_ACCELERATED = 0x00000002'u32
    SDL_RENDERER_PRESENTVSYNC = 0x00000004'u32
    SDL_TEXTUREACCESS_STREAMING = 1'i32
    SDL_PIXELFORMAT_ARGB8888 = 0x16362004'u32

    SDL_QUIT_EV = 0x100'u32
    SDL_KEYDOWN_EV = 0x300'u32
    SDL_KEYUP_EV = 0x301'u32
    SDL_MOUSEMOTION_EV = 0x400'u32
    SDL_MOUSEBUTTONDOWN_EV = 0x401'u32
    SDL_MOUSEBUTTONUP_EV = 0x402'u32
    SDL_MOUSEWHEEL_EV = 0x403'u32

    SDLK_ESCAPE = 27'i32
    SDLK_RETURN = 13'i32
    SDLK_SPACE = 32'i32
    SDLK_RIGHT = 0x4000004F'i32
    SDLK_LEFT  = 0x40000050'i32
    SDLK_DOWN  = 0x40000051'i32
    SDLK_UP    = 0x40000052'i32

  type
    SdlWindow = pointer
    SdlRenderer = pointer
    SdlTexture = pointer

    SdlKeysym {.bycopy.} = object
      scancode: int32
      sym: int32
      modState: uint16
      unused: uint32

    SdlCommonEvent {.bycopy.} = object
      kind: uint32
      timestamp: uint32

    SdlKeyboardEvent {.bycopy.} = object
      kind: uint32
      timestamp: uint32
      windowID: uint32
      state: uint8
      repeat: uint8
      pad2, pad3: uint8
      keysym: SdlKeysym

    SdlMouseMotionEvent {.bycopy.} = object
      kind: uint32
      timestamp: uint32
      windowID: uint32
      which: uint32
      state: uint32
      x, y: int32
      xrel, yrel: int32

    SdlMouseButtonEvent {.bycopy.} = object
      kind: uint32
      timestamp: uint32
      windowID: uint32
      which: uint32
      button: uint8
      state: uint8
      clicks: uint8
      pad1: uint8
      x, y: int32

    SdlMouseWheelEvent {.bycopy.} = object
      kind: uint32
      timestamp: uint32
      windowID: uint32
      which: uint32
      x, y: int32
      direction: uint32

    SdlEvent {.union, bycopy.} = object
      kind: uint32
      common: SdlCommonEvent
      key: SdlKeyboardEvent
      motion: SdlMouseMotionEvent
      button: SdlMouseButtonEvent
      wheel: SdlMouseWheelEvent
      pad: array[56, byte]

  {.push callconv: cdecl, dynlib: sdlLib.}
  proc SDL_Init(flags: uint32): cint {.importc.}
  proc SDL_Quit() {.importc.}
  proc SDL_GetError(): cstring {.importc.}
  proc SDL_Delay(ms: uint32) {.importc.}
  proc SDL_GetTicks(): uint32 {.importc.}
  proc SDL_CreateWindow(title: cstring, x, y, w, h: cint, flags: uint32): SdlWindow {.importc.}
  proc SDL_DestroyWindow(window: SdlWindow) {.importc.}
  proc SDL_SetWindowTitle(window: SdlWindow, title: cstring) {.importc.}
  proc SDL_CreateRenderer(window: SdlWindow, index: cint, flags: uint32): SdlRenderer {.importc.}
  proc SDL_DestroyRenderer(renderer: SdlRenderer) {.importc.}
  proc SDL_CreateTexture(renderer: SdlRenderer, format: uint32, access, w, h: cint): SdlTexture {.importc.}
  proc SDL_DestroyTexture(texture: SdlTexture) {.importc.}
  proc SDL_UpdateTexture(texture: SdlTexture, rect: pointer, pixels: pointer, pitch: cint): cint {.importc.}
  proc SDL_RenderClear(renderer: SdlRenderer): cint {.importc.}
  proc SDL_RenderCopy(renderer: SdlRenderer, texture: SdlTexture, srcrect, dstrect: pointer): cint {.importc.}
  proc SDL_RenderPresent(renderer: SdlRenderer) {.importc.}
  proc SDL_PollEvent(event: ptr SdlEvent): cint {.importc.}
  {.pop.}

  var sdlReady = false
  var sdlWindowCount = 0

  proc ensureSdl() =
    if not sdlReady:
      if SDL_Init(SDL_INIT_VIDEO) != 0:
        raise newException(WindowError, "SDL_Init failed: " & $SDL_GetError())
      sdlReady = true

  proc sdlMapKey(sym: int32): int =
    case sym
    of SDLK_ESCAPE: KeyEscape
    of SDLK_RETURN: KeyEnter
    of SDLK_SPACE: KeySpace
    of SDLK_LEFT: KeyLeft
    of SDLK_UP: KeyUp
    of SDLK_RIGHT: KeyRight
    of SDLK_DOWN: KeyDown
    else:
      if sym >= 0 and sym < 256: int(sym) else: -1

  type
    Window* = ref object
      width*, height*: int          ## client area size in pixels
      sdlWin: SdlWindow
      sdlRen: SdlRenderer
      sdlTex: SdlTexture
      texW, texH: int
      frame: seq[uint32]            ## last presented frame, 0xAARRGGBB top-down
      frameW, frameH: int
      open: bool
      keys, pressed: array[256, bool]
      buttons: array[3, bool]
      mx, my, wheel: int
      deadline: uint64              ## tick at which to auto-close; 0 = never

  proc openWindow*(title: string, w, h: int, autoCloseMs: int = -1): Window =
    ## Opens a fixed-size SDL2 window. Requires the SDL2 runtime library.
    if w <= 0 or h <= 0: raise newException(WindowError, "invalid window size")
    ensureSdl()
    let win = SDL_CreateWindow(title, 0x2FFF0000'i32, 0x2FFF0000'i32, cint(w), cint(h),
      SDL_WINDOW_SHOWN)
    if win == nil:
      raise newException(WindowError, "SDL_CreateWindow failed: " & $SDL_GetError())
    let ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED or SDL_RENDERER_PRESENTVSYNC)
    if ren == nil:
      SDL_DestroyWindow(win)
      raise newException(WindowError, "SDL_CreateRenderer failed: " & $SDL_GetError())
    var ms = autoCloseMs
    if ms < 0:
      ms = try: parseInt(getEnv("THORVG_AUTOCLOSE_MS", "0")) except ValueError: 0
    result = Window(width: w, height: h, sdlWin: win, sdlRen: ren, open: true)
    if ms > 0: result.deadline = uint64(SDL_GetTicks()) + uint64(ms)
    inc sdlWindowCount

  proc destroyTexture(win: Window) =
    if win.sdlTex != nil:
      SDL_DestroyTexture(win.sdlTex)
      win.sdlTex = nil
      win.texW = 0
      win.texH = 0

  proc close*(win: Window) =
    if win.open:
      destroyTexture(win)
      if win.sdlRen != nil: SDL_DestroyRenderer(win.sdlRen)
      if win.sdlWin != nil: SDL_DestroyWindow(win.sdlWin)
      win.sdlRen = nil
      win.sdlWin = nil
      win.open = false
      if sdlWindowCount > 0: dec sdlWindowCount
      # Keep SDL initialized for process lifetime in this skeleton.

  proc isOpen*(win: Window): bool = win.open

  proc setTitle*(win: Window, title: string) =
    if win.open and win.sdlWin != nil: SDL_SetWindowTitle(win.sdlWin, title)

  proc ensureTexture(win: Window, w, h: int): bool =
    if w <= 0 or h <= 0: return false
    if win.sdlTex != nil and win.texW == w and win.texH == h: return true
    destroyTexture(win)
    win.sdlTex = SDL_CreateTexture(win.sdlRen, SDL_PIXELFORMAT_ARGB8888,
      SDL_TEXTUREACCESS_STREAMING, cint(w), cint(h))
    if win.sdlTex == nil: return false
    win.texW = w
    win.texH = h
    true

  proc presentPixels(win: Window, pixels: ptr uint32, w, h, stride: int) =
    if not win.open or win.sdlRen == nil or pixels == nil: return
    if not ensureTexture(win, w, h): return
    discard SDL_UpdateTexture(win.sdlTex, nil, pixels, cint(stride * 4))
    discard SDL_RenderClear(win.sdlRen)
    discard SDL_RenderCopy(win.sdlRen, win.sdlTex, nil, nil)
    SDL_RenderPresent(win.sdlRen)

  proc presentBuffer*(win: Window, pixels: openArray[uint32], w, h, stride: int) =
    ## Minimal backend present: shows `w*h` pixels (0xAARRGGBB, top-down) with the
    ## given stride in pixels, stretched to the window client area.
    if not win.open or w <= 0 or h <= 0 or stride < w or pixels.len < stride * h: return
    if stride == w:
      presentPixels(win, unsafeAddr pixels[0], w, h, stride)
    else:
      win.frame.setLen(w * h)
      for y in 0..<h:
        for x in 0..<w:
          win.frame[y * w + x] = pixels[y * stride + x]
      presentPixels(win, unsafeAddr win.frame[0], w, h, w)

  proc present*(win: Window, s: RenderSurface) =
    ## Shows `s` (any 32-bit or gray color space, composited over black),
    ## stretched to the client area.
    if not win.open or s == nil or s.w == 0 or s.h == 0: return
    win.frameW = int(s.w)
    win.frameH = int(s.h)
    win.frame.setLen(win.frameW * win.frameH)
    for y in 0..<win.frameH:
      for x in 0..<win.frameW:
        let p = s.rgbOverBlack(x, y)
        win.frame[y * win.frameW + x] = 0xFF000000'u32 or (uint32(p.r) shl 16) or
          (uint32(p.g) shl 8) or uint32(p.b)
    presentPixels(win, unsafeAddr win.frame[0], win.frameW, win.frameH, win.frameW)

  proc applyMappedKey(win: Window, key: int, down: bool) =
    if key in 0..255:
      win.keys[key] = down
      if down: win.pressed[key] = true

  proc pollEvents*(win: Window): bool =
    ## Processes pending SDL events and updates the input state.
    ## Returns false once the window is closed (by the user or by auto-close).
    if win.open:
      win.pressed = default(array[256, bool])
      win.wheel = 0
      var ev: SdlEvent
      while SDL_PollEvent(addr ev) != 0:
        case ev.kind
        of SDL_QUIT_EV:
          win.open = false
        of SDL_KEYDOWN_EV:
          let k = sdlMapKey(ev.key.keysym.sym)
          applyMappedKey(win, k, true)
        of SDL_KEYUP_EV:
          let k = sdlMapKey(ev.key.keysym.sym)
          applyMappedKey(win, k, false)
        of SDL_MOUSEMOTION_EV:
          win.mx = int(ev.motion.x)
          win.my = int(ev.motion.y)
        of SDL_MOUSEBUTTONDOWN_EV, SDL_MOUSEBUTTONUP_EV:
          win.mx = int(ev.button.x)
          win.my = int(ev.button.y)
          let down = ev.kind == SDL_MOUSEBUTTONDOWN_EV
          case ev.button.button
          of 1'u8: win.buttons[MouseLeft] = down
          of 2'u8: win.buttons[MouseMiddle] = down
          of 3'u8: win.buttons[MouseRight] = down
          else: discard
        of SDL_MOUSEWHEEL_EV:
          win.wheel += int(ev.wheel.y)
        else:
          discard
      if win.open and win.deadline != 0 and uint64(SDL_GetTicks()) >= win.deadline:
        close(win)
    result = win.open

  proc waitClose*(win: Window) =
    ## Blocks (polling every 10 ms) until the window is closed.
    while win.pollEvents(): SDL_Delay(10)

  proc keyDown*(win: Window, key: int): bool =
    key in 0..255 and win.keys[key]

  proc keyPressed*(win: Window, key: int): bool =
    ## True if `key` went down during the last `pollEvents`.
    key in 0..255 and win.pressed[key]

  proc mouseX*(win: Window): int = win.mx
  proc mouseY*(win: Window): int = win.my
  proc mouseDown*(win: Window, button: int): bool = button in 0..2 and win.buttons[button]
  proc wheelDelta*(win: Window): int = win.wheel   ## notches during the last poll
