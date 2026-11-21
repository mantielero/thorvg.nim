## UNSAFE (exempt, DECISIONS.md E2): facade of the OpenGL binding used by the Nim
## port of the ThorVG GL engine. Import this one module:
##
## - `gl_types`: `GlEnum`, `GlId` and the constants (`GlTriangles`, ...).
## - `glInit()` / `glTerm()` / `glReady()` / `glInitError()`: loader of tvgGl.cpp
##   (GL >= 3.3 check included; a context must be current).
## - Safe wrappers named like the GL functions without the prefix (`bindBuffer`,
##   `texImage2D`, `readPixels`, ...); no pointer type in any signature.
## - `glCheck(stmt)`: `GL_CHECK`, active with `-d:glDebug`.
## - `glLiveObjects()`: generated minus deleted GL objects (leak counter).

import ./[gl_types, gl_raw_ffi, gl_core_ffi, gl_buffers_ffi]

export gl_types, gl_core_ffi, gl_buffers_ffi
export glInit, glTerm, glReady, glInitError, glLiveObjects, GlObjKind
