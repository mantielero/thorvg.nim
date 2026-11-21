## Hand-written Win32 bindings (user32 / gdi32 / kernel32), loaded at run time.
##
## This is the ONLY file of the project that talks to the OS (DECISIONS.md D8, E1).
## Raw pointers never leave it: the exported `w32*` procs use plain Nim types so
## that `window.nim` stays free of unsafe constructs.
##
## The window class uses a tiny `DefWindowProcW` forwarder as window procedure;
## input is observed in the message loop (`w32Pump`) instead of a callback, so no
## global state is needed. Closing the window (X button / Alt+F4) destroys it
## inside `DefWindowProcW`; callers detect that with `w32IsWindow`.

import std/unicode

type
  Hwnd = pointer
  WndProc = proc(h: Hwnd, msg: uint32, wp: uint, lp: int): int {.stdcall.}

  WndClassExW {.bycopy.} = object
    cbSize, style: uint32
    lpfnWndProc: WndProc
    cbClsExtra, cbWndExtra: int32
    hInstance, hIcon, hCursor, hbrBackground: pointer
    lpszMenuName, lpszClassName: pointer
    hIconSm: pointer

  Point {.bycopy.} = object
    x, y: int32

  Rect {.bycopy.} = object
    left, top, right, bottom: int32

  Msg {.bycopy.} = object
    hwnd: Hwnd
    message: uint32
    wParam: uint
    lParam: int
    time: uint32
    pt: Point
    lPrivate: uint32

  BitmapInfoHeader {.bycopy.} = object
    biSize: uint32
    biWidth, biHeight: int32
    biPlanes, biBitCount: uint16
    biCompression, biSizeImage: uint32
    biXPelsPerMeter, biYPelsPerMeter: int32
    biClrUsed, biClrImportant: uint32

  W32EventKind* = enum
    wkKeyDown, wkKeyUp, wkMouseMove, wkMouseDown, wkMouseUp, wkWheel

  W32Event* = object
    ## `a` = virtual key code (keys), x (mouse) or wheel notches (wheel);
    ## `b` = y (mouse); `button` = 0 left, 1 right, 2 middle (mouse buttons).
    kind*: W32EventKind
    a*, b*, button*: int

{.push stdcall, dynlib: "user32.dll".}
proc registerClassExW(c: ptr WndClassExW): uint16 {.importc: "RegisterClassExW".}
proc createWindowExW(exStyle: uint32, cls, title: pointer, style: uint32,
    x, y, w, h: int32, parent, menu, inst, param: pointer): Hwnd
    {.importc: "CreateWindowExW".}
proc showWindow(h: Hwnd, cmd: int32): int32 {.importc: "ShowWindow".}
proc peekMessageW(m: ptr Msg, h: Hwnd, lo, hi, remove: uint32): int32
    {.importc: "PeekMessageW".}
proc translateMessage(m: ptr Msg): int32 {.importc: "TranslateMessage".}
proc dispatchMessageW(m: ptr Msg): int {.importc: "DispatchMessageW".}
proc defWindowProcW(h: Hwnd, msg: uint32, wp: uint, lp: int): int
    {.importc: "DefWindowProcW".}
proc destroyWindow(h: Hwnd): int32 {.importc: "DestroyWindow".}
proc isWindow(h: Hwnd): int32 {.importc: "IsWindow".}
proc adjustWindowRect(r: ptr Rect, style: uint32, menu: int32): int32
    {.importc: "AdjustWindowRect".}
proc loadCursorW(inst, name: pointer): pointer {.importc: "LoadCursorW".}
proc getDC(h: Hwnd): pointer {.importc: "GetDC".}
proc releaseDC(h: Hwnd, dc: pointer): int32 {.importc: "ReleaseDC".}
proc validateRect(h: Hwnd, r: ptr Rect): int32 {.importc: "ValidateRect".}
proc setWindowTextW(h: Hwnd, text: pointer): int32 {.importc: "SetWindowTextW".}
proc setForegroundWindow(h: Hwnd): int32 {.importc: "SetForegroundWindow".}
{.pop.}

{.push stdcall, dynlib: "gdi32.dll".}
proc stretchDIBits(dc: pointer, xd, yd, wd, hd, xs, ys, ws, hs: int32,
    bits: pointer, info: ptr BitmapInfoHeader, usage, rop: uint32): int32
    {.importc: "StretchDIBits".}
{.pop.}

{.push stdcall, dynlib: "kernel32.dll".}
proc getModuleHandleW(name: pointer): pointer {.importc: "GetModuleHandleW".}
proc getTickCount64(): uint64 {.importc: "GetTickCount64".}
proc sleepMs(ms: uint32) {.importc: "Sleep".}
{.pop.}

const
  WmPaint = 0x000F'u32
  WmKeyDown = 0x0100'u32
  WmKeyUp = 0x0101'u32
  WmSysKeyDown = 0x0104'u32
  WmSysKeyUp = 0x0105'u32
  WmMouseMove = 0x0200'u32
  WmLButtonDown = 0x0201'u32
  WmLButtonUp = 0x0202'u32
  WmRButtonDown = 0x0204'u32
  WmRButtonUp = 0x0205'u32
  WmMButtonDown = 0x0207'u32
  WmMButtonUp = 0x0208'u32
  WmMouseWheel = 0x020A'u32
  PmRemove = 1'u32
  WsWindowStyle = 0x00CA0000'u32   # OVERLAPPED | CAPTION | SYSMENU | MINIMIZEBOX
  CwUseDefault = int32.low
  SwShow = 5'i32
  SrcCopy = 0x00CC0020'u32
  ClassName = "ThorvgNimWindow"

proc wndProc(h: Hwnd, msg: uint32, wp: uint, lp: int): int {.stdcall.} =
  defWindowProcW(h, msg, wp, lp)

proc toHwnd(h: int): Hwnd = cast[Hwnd](h)

proc wideZ(s: string): seq[uint16] =
  ## UTF-8 -> zero-terminated UTF-16.
  for r in s.runes:
    let c = uint32(int(r))
    if c < 0x10000'u32:
      result.add uint16(c)
    else:
      let v = c - 0x10000'u32
      result.add uint16(0xD800'u32 + (v shr 10))
      result.add uint16(0xDC00'u32 + (v and 0x3FF'u32))
  result.add 0'u16

proc registerClass() =
  let wide = wideZ(ClassName)
  # Registering twice fails with "class exists": harmless, the class is reused.
  var wc = WndClassExW(
    cbSize: uint32(sizeof(WndClassExW)),
    lpfnWndProc: wndProc,
    hInstance: getModuleHandleW(nil),
    hCursor: loadCursorW(nil, cast[pointer](32512)),
    hbrBackground: cast[pointer](6),
    lpszClassName: unsafeAddr wide[0])
  discard registerClassExW(addr wc)

proc w32CreateWindow*(title: string, clientW, clientH: int): int =
  ## Creates and shows a fixed-size window with the given client area.
  ## Returns the window handle, or 0 on failure.
  registerClass()
  var rc = Rect(right: int32(clientW), bottom: int32(clientH))
  discard adjustWindowRect(addr rc, WsWindowStyle, 0)
  let wideClass = wideZ(ClassName)
  let wideTitle = wideZ(title)
  let h = createWindowExW(0, unsafeAddr wideClass[0], unsafeAddr wideTitle[0],
    WsWindowStyle, CwUseDefault, CwUseDefault, rc.right - rc.left,
    rc.bottom - rc.top, nil, nil, getModuleHandleW(nil), nil)
  if h != nil:
    discard showWindow(h, SwShow)
    discard setForegroundWindow(h)
  result = cast[int](h)

proc w32IsWindow*(h: int): bool = h != 0 and isWindow(toHwnd(h)) != 0

proc w32Destroy*(h: int) =
  if w32IsWindow(h): discard destroyWindow(toHwnd(h))

proc w32SetTitle*(h: int, title: string) =
  let wide = wideZ(title)
  discard setWindowTextW(toHwnd(h), unsafeAddr wide[0])

proc w32Ticks*(): uint64 = getTickCount64()

proc w32Sleep*(ms: int) = sleepMs(uint32(max(ms, 0)))

proc loWord(v: int): int = int(int16(v and 0xFFFF))
proc hiWord(v: int): int = int(int16((v shr 16) and 0xFFFF))

proc toEvent(m: Msg, ev: var W32Event): bool =
  ## Translates a window message into an event; false if it is not one we track.
  let lp = m.lParam
  result = true
  case m.message
  of WmKeyDown, WmSysKeyDown: ev = W32Event(kind: wkKeyDown, a: int(m.wParam))
  of WmKeyUp, WmSysKeyUp: ev = W32Event(kind: wkKeyUp, a: int(m.wParam))
  of WmMouseMove: ev = W32Event(kind: wkMouseMove, a: loWord(lp), b: hiWord(lp))
  of WmLButtonDown:
    ev = W32Event(kind: wkMouseDown, a: loWord(lp), b: hiWord(lp), button: 0)
  of WmLButtonUp:
    ev = W32Event(kind: wkMouseUp, a: loWord(lp), b: hiWord(lp), button: 0)
  of WmRButtonDown:
    ev = W32Event(kind: wkMouseDown, a: loWord(lp), b: hiWord(lp), button: 1)
  of WmRButtonUp:
    ev = W32Event(kind: wkMouseUp, a: loWord(lp), b: hiWord(lp), button: 1)
  of WmMButtonDown:
    ev = W32Event(kind: wkMouseDown, a: loWord(lp), b: hiWord(lp), button: 2)
  of WmMButtonUp:
    ev = W32Event(kind: wkMouseUp, a: loWord(lp), b: hiWord(lp), button: 2)
  of WmMouseWheel: ev = W32Event(kind: wkWheel, a: hiWord(int(m.wParam)) div 120)
  else: result = false

proc w32Pump*(h: int, events: var seq[W32Event]): bool =
  ## Drains the thread's message queue, appending tracked input to `events`.
  ## Returns true when the client area needs repainting (WM_PAINT seen).
  var m: Msg
  var ev: W32Event
  while peekMessageW(addr m, nil, 0, 0, PmRemove) != 0:
    if m.message == WmPaint:
      discard validateRect(m.hwnd, nil)
      result = true
    else:
      if m.hwnd == toHwnd(h) and toEvent(m, ev): events.add ev
      discard translateMessage(addr m)
      discard dispatchMessageW(addr m)

proc w32Blit*(h: int, pixels: seq[uint32], srcW, srcH, dstW, dstH: int) =
  ## Draws `pixels` (0xAARRGGBB, top-down, `srcW*srcH` entries) stretched to the
  ## `dstW x dstH` client area. The alpha byte is ignored by GDI.
  if srcW > 0 and srcH > 0 and pixels.len >= srcW * srcH:
    var info = BitmapInfoHeader(biSize: uint32(sizeof(BitmapInfoHeader)),
      biWidth: int32(srcW), biHeight: -int32(srcH), biPlanes: 1, biBitCount: 32)
    let dc = getDC(toHwnd(h))
    if dc != nil:
      discard stretchDIBits(dc, 0, 0, int32(dstW), int32(dstH), 0, 0, int32(srcW),
        int32(srcH), unsafeAddr pixels[0], addr info, 0, SrcCopy)
      discard releaseDC(toHwnd(h), dc)
