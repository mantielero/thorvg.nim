// PoC: hidden WGL window + GL context + FBO + clear + readback (C++ twin of poc_context.nim).
// Build: g++ tests/gl/poc_context.cpp -o build/gl/poc_context_cpp.exe -lopengl32 -lgdi32 -luser32
#include <windows.h>
#include <GL/gl.h>
#include <cstdio>
#include <cstring>

typedef char GLchar_;
#define GL_FRAMEBUFFER 0x8D40
#define GL_RENDERBUFFER 0x8D41
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_DEPTH_STENCIL_ATTACHMENT 0x821A
#define GL_DEPTH24_STENCIL8 0x88F0
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_MAJOR_VERSION 0x821B
#define GL_MINOR_VERSION 0x821C
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define WGL_CONTEXT_MAJOR_VERSION_ARB 0x2091
#define WGL_CONTEXT_MINOR_VERSION_ARB 0x2092
#define WGL_CONTEXT_PROFILE_MASK_ARB 0x9126
#define WGL_CONTEXT_CORE_PROFILE_BIT_ARB 1
#define WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB 2

typedef HGLRC (WINAPI* PFNCTXATTR)(HDC, HGLRC, const int*);
typedef void (APIENTRY* PFNGENFB)(GLsizei, GLuint*);
typedef void (APIENTRY* PFNBINDFB)(GLenum, GLuint);
typedef void (APIENTRY* PFNGENRB)(GLsizei, GLuint*);
typedef void (APIENTRY* PFNBINDRB)(GLenum, GLuint);
typedef void (APIENTRY* PFNRBSTORE)(GLenum, GLenum, GLsizei, GLsizei);
typedef void (APIENTRY* PFNFBRB)(GLenum, GLenum, GLenum, GLuint);
typedef GLenum (APIENTRY* PFNCHECK)(GLenum);
typedef GLuint (APIENTRY* PFNCREATESH)(GLenum);
typedef void (APIENTRY* PFNSHSRC)(GLuint, GLsizei, const char* const*, const GLint*);
typedef void (APIENTRY* PFNCOMPILE)(GLuint);
typedef void (APIENTRY* PFNGETSHIV)(GLuint, GLenum, GLint*);
typedef const GLubyte* (APIENTRY* PFNGETSTRI)(GLenum, GLuint);

static void* load(const char* n) {
    void* p = (void*)wglGetProcAddress(n);
    if (!p) p = (void*)GetProcAddress(GetModuleHandleA("opengl32.dll"), n);
    return p;
}

int main() {
    WNDCLASSA wc{}; wc.lpfnWndProc = DefWindowProcA; wc.hInstance = GetModuleHandleA(nullptr); wc.lpszClassName = "tvgpoc";
    RegisterClassA(&wc);
    HWND hw = CreateWindowA("tvgpoc", "poc", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64, nullptr, nullptr, wc.hInstance, nullptr); // never shown
    HDC dc = GetDC(hw);
    PIXELFORMATDESCRIPTOR pfd{}; pfd.nSize = sizeof(pfd); pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER; pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32; pfd.cDepthBits = 24; pfd.cStencilBits = 8;
    int pf = ChoosePixelFormat(dc, &pfd);
    printf("pixelformat=%d set=%d\n", pf, (int)SetPixelFormat(dc, pf, &pfd));
    HGLRC legacy = wglCreateContext(dc);
    wglMakeCurrent(dc, legacy);
    PFNCTXATTR create = (PFNCTXATTR)load("wglCreateContextAttribsARB");
    HGLRC ctx = nullptr; const char* mode = "legacy";
    if (create) {
        int core[] = {WGL_CONTEXT_MAJOR_VERSION_ARB, 3, WGL_CONTEXT_MINOR_VERSION_ARB, 3, WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_CORE_PROFILE_BIT_ARB, 0};
        ctx = create(dc, nullptr, core); mode = "3.3 core";
        if (!ctx) { int compat[] = {WGL_CONTEXT_MAJOR_VERSION_ARB, 3, WGL_CONTEXT_MINOR_VERSION_ARB, 3, WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB, 0};
            ctx = create(dc, nullptr, compat); mode = "3.3 compat"; }
    }
    if (ctx) { wglMakeCurrent(nullptr, nullptr); wglDeleteContext(legacy); wglMakeCurrent(dc, ctx); }
    else { ctx = legacy; mode = "legacy"; }
    printf("context mode=%s\n", mode);
    printf("GL_VERSION=%s\nGL_RENDERER=%s\nGL_VENDOR=%s\nGLSL=%s\n", glGetString(GL_VERSION), glGetString(GL_RENDERER), glGetString(GL_VENDOR), glGetString(GL_SHADING_LANGUAGE_VERSION));
    GLint mj = 0, mn = 0; glGetIntegerv(GL_MAJOR_VERSION, &mj); glGetIntegerv(GL_MINOR_VERSION, &mn); printf("major=%d minor=%d\n", mj, mn);

    auto glGenFramebuffers = (PFNGENFB)load("glGenFramebuffers");
    auto glBindFramebuffer = (PFNBINDFB)load("glBindFramebuffer");
    auto glGenRenderbuffers = (PFNGENRB)load("glGenRenderbuffers");
    auto glBindRenderbuffer = (PFNBINDRB)load("glBindRenderbuffer");
    auto glRenderbufferStorage = (PFNRBSTORE)load("glRenderbufferStorage");
    auto glFramebufferRenderbuffer = (PFNFBRB)load("glFramebufferRenderbuffer");
    auto glCheckFramebufferStatus = (PFNCHECK)load("glCheckFramebufferStatus");
    auto glCreateShader = (PFNCREATESH)load("glCreateShader");
    auto glShaderSource = (PFNSHSRC)load("glShaderSource");
    auto glCompileShader = (PFNCOMPILE)load("glCompileShader");
    auto glGetShaderiv = (PFNGETSHIV)load("glGetShaderiv");
    if (!glGenFramebuffers || !glCreateShader) { printf("FAIL: missing GL 3.x entry points\n"); return 2; }

    const int W = 64, H = 64;
    GLuint fbo, rbc, rbd;
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glGenRenderbuffers(1, &rbc); glBindRenderbuffer(GL_RENDERBUFFER, rbc);
    glRenderbufferStorage(GL_RENDERBUFFER, 0x8058 /*RGBA8*/, W, H);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rbc);
    glGenRenderbuffers(1, &rbd); glBindRenderbuffer(GL_RENDERBUFFER, rbd);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, W, H);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, rbd);
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    printf("fbo status=0x%X (%s)\n", st, st == GL_FRAMEBUFFER_COMPLETE ? "complete" : "INCOMPLETE");
    glViewport(0, 0, W, H);
    glClearColor(1.0f, 0.5f, 0.25f, 1.0f); glClear(GL_COLOR_BUFFER_BIT);
    unsigned char px[4] = {0};
    glReadPixels(10, 10, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    printf("pixel(10,10)=%u,%u,%u,%u\n", px[0], px[1], px[2], px[3]);

    // GLSL 330 core compile check (same preamble as tvgGlShaderSrc.cpp)
    const char* fs = "#version 330 core\nprecision highp float;\nprecision highp int;\nlayout(std140) uniform B { vec4 v[4]; };\nout vec4 o;\nvoid main(){ o = v[1]; }\n";
    GLuint s = glCreateShader(GL_FRAGMENT_SHADER); glShaderSource(s, 1, &fs, nullptr); glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok); printf("glsl330 compile=%d\n", ok);
    bool good = st == GL_FRAMEBUFFER_COMPLETE && px[0] == 255 && px[1] == 128 && px[2] == 64 && px[3] == 255 && ok;
    printf("RESULT %s\n", good ? "OK" : "FAIL");
    return good ? 0 : 1;
}
