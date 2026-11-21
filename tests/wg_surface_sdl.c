#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <webgpu/webgpu.h>
#include <stdint.h>
#include <string.h>

typedef struct { void* display; uint64_t window; int is_x11; } WgNativeWindow;

int wg_sdl_init(WgNativeWindow* out, uint32_t w, uint32_t h) {
  if (SDL_Init(SDL_INIT_VIDEO) != 0) return -1;
  SDL_Window* win = SDL_CreateWindow("wg_smoke", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, (int)w, (int)h, SDL_WINDOW_SHOWN);
  if (!win) return -2;
  SDL_SysWMinfo info;
  SDL_VERSION(&info.version);
  if (!SDL_GetWindowWMInfo(win, &info)) { SDL_DestroyWindow(win); return -3; }
  out->window = 0; out->display = NULL; out->is_x11 = 0;
#if defined(SDL_VIDEO_DRIVER_X11)
  if (info.subsystem == SDL_SYSWM_X11) {
    out->display = info.info.x11.display;
    out->window = (uint64_t)info.info.x11.window;
    out->is_x11 = 1;
    return 0;
  }
#endif
#if defined(SDL_VIDEO_DRIVER_WAYLAND)
  if (info.subsystem == SDL_SYSWM_WAYLAND) {
    out->display = info.info.wl.display;
    out->window = (uint64_t)(uintptr_t)info.info.wl.surface;
    out->is_x11 = 0;
    return 0;
  }
#endif
  SDL_DestroyWindow(win);
  return -4;
}

WGPUSurface wg_create_surface_sdl(WGPUInstance instance, WgNativeWindow* nw) {
  if (nw->is_x11) {
    WGPUSurfaceSourceXlibWindow x11;
    memset(&x11, 0, sizeof(x11));
    x11.chain.sType = WGPUSType_SurfaceSourceXlibWindow;
    x11.display = nw->display;
    x11.window = nw->window;
    WGPUSurfaceDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    desc.nextInChain = (WGPUChainedStruct*)&x11;
    return wgpuInstanceCreateSurface(instance, &desc);
  } else {
    WGPUSurfaceSourceWaylandSurface wl;
    memset(&wl, 0, sizeof(wl));
    wl.chain.sType = WGPUSType_SurfaceSourceWaylandSurface;
    wl.display = nw->display;
    wl.surface = (void*)(uintptr_t)nw->window;
    WGPUSurfaceDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    desc.nextInChain = (WGPUChainedStruct*)&wl;
    return wgpuInstanceCreateSurface(instance, &desc);
  }
}

void wg_sdl_pump(void) { SDL_Event e; while (SDL_PollEvent(&e)) {} }
void wg_sdl_quit(void) { SDL_Quit(); }
