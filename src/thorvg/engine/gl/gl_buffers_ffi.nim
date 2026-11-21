## UNSAFE (exempt, DECISIONS.md E2): safe wrappers for buffers, vertex arrays,
## shaders, programs and uniforms. Exported signatures contain no pointer type:
## shader sources, names and logs are `string`, data is `openArray[T]`, byte
## offsets are `int`. Import `gl_ffi`, which re-exports this module.

import ./[gl_types, gl_raw_ffi]

# ---------------------------------------------------------------- buffers

proc genBuffers*(n: int): seq[GlId] =
  result = newSeq[GlId](n)
  if n > 0:
    fnGenBuffers(int32(n), addr result[0])
    trackGen(okBuffer, n)

proc genBuffer*(): GlId = genBuffers(1)[0]

proc deleteBuffers*(ids: openArray[GlId]) =
  if ids.len > 0:
    fnDeleteBuffers(int32(ids.len), unsafeAddr ids[0])
    for id in ids:
      if id != 0: trackDel(okBuffer, 1)

proc deleteBuffer*(id: GlId) = deleteBuffers([id])
proc bindBuffer*(target: GlEnum, id: GlId) = fnBindBuffer(target, id)

proc bufferData*[T](target: GlEnum, data: openArray[T], usage: GlEnum) =
  ## Uploads all of `data` (size = `data.len * sizeof(T)`).
  if data.len > 0:
    fnBufferData(target, data.len * sizeof(T), cast[pointer](unsafeAddr data[0]), usage)
  else:
    fnBufferData(target, 0, nil, usage)

proc bufferDataSize*(target: GlEnum, size: int, usage: GlEnum) =
  ## Allocates `size` bytes without uploading.
  fnBufferData(target, size, nil, usage)

proc bufferSubData*[T](target: GlEnum, offset: int, data: openArray[T]) =
  ## `offset` is in bytes.
  if data.len > 0:
    fnBufferSubData(target, offset, data.len * sizeof(T), cast[pointer](unsafeAddr data[0]))

func floatBits*(f: float32): uint32 =
  ## IEEE-754 bit pattern of `f` (stage buffers store 32-bit words).
  cast[uint32](f)

func int32Bits*(i: int32): uint32 = cast[uint32](i)

func bitsFloat*(u: uint32): float32 = cast[float32](u)

proc getBufferSubData*[T](target: GlEnum, offset: int, data: var openArray[T]) =
  ## Reads `data.len * sizeof(T)` bytes from byte `offset` of the bound buffer (tests).
  if data.len > 0:
    fnGetBufferSubData(target, offset, data.len * sizeof(T), cast[pointer](addr data[0]))

proc bindBufferRange*(target: GlEnum, index: uint32, id: GlId, offset, size: int) =
  fnBindBufferRange(target, index, id, offset, size)

# ---------------------------------------------------------------- vertex arrays

proc genVertexArrays*(n: int): seq[GlId] =
  result = newSeq[GlId](n)
  if n > 0:
    fnGenVertexArrays(int32(n), addr result[0])
    trackGen(okVertexArray, n)

proc genVertexArray*(): GlId = genVertexArrays(1)[0]

proc deleteVertexArrays*(ids: openArray[GlId]) =
  if ids.len > 0:
    fnDeleteVertexArrays(int32(ids.len), unsafeAddr ids[0])
    for id in ids:
      if id != 0: trackDel(okVertexArray, 1)

proc deleteVertexArray*(id: GlId) = deleteVertexArrays([id])
proc bindVertexArray*(id: GlId) = fnBindVertexArray(id)
proc enableVertexAttribArray*(index: uint32) = fnEnableVertexAttribArray(index)
proc disableVertexAttribArray*(index: uint32) = fnDisableVertexAttribArray(index)

proc vertexAttrib4f*(index: uint32, x, y, z, w: float32) = fnVertexAttrib4f(index, x, y, z, w)

proc vertexAttribPointer*(index: uint32, size: int32, ty: GlEnum, norm: bool,
    stride: int32, offset: int) =
  ## `offset` is a byte offset into the bound `GlArrayBuffer`.
  fnVertexAttribPointer(index, size, ty, uint8(norm), stride, cast[pointer](offset))

# ---------------------------------------------------------------- shaders

proc createShader*(ty: GlEnum): GlId =
  result = fnCreateShader(ty)
  if result != 0: trackGen(okShader, 1)

proc deleteShader*(id: GlId) =
  fnDeleteShader(id)
  if id != 0: trackDel(okShader, 1)

proc shaderSource*(shader: GlId, src: string) =
  var p = cstring(src)
  var n = int32(src.len)
  fnShaderSource(shader, 1, addr p, addr n)

proc compileShader*(shader: GlId) = fnCompileShader(shader)

proc getShaderiv*(shader: GlId, pname: GlEnum): int32 =
  result = 0
  fnGetShaderiv(shader, pname, addr result)

proc getShaderInfoLog*(shader: GlId): string =
  let n = int(getShaderiv(shader, GlInfoLogLength))
  result = ""
  if n > 1:
    result = newString(n)
    var got = 0'i32
    fnGetShaderInfoLog(shader, int32(n), addr got, cstring(result))
    result.setLen(max(int(got), 0))

# ---------------------------------------------------------------- programs

proc createProgram*(): GlId =
  result = fnCreateProgram()
  if result != 0: trackGen(okProgram, 1)

proc deleteProgram*(id: GlId) =
  fnDeleteProgram(id)
  if id != 0: trackDel(okProgram, 1)

proc attachShader*(prog, shader: GlId) = fnAttachShader(prog, shader)
proc linkProgram*(prog: GlId) = fnLinkProgram(prog)
proc useProgram*(prog: GlId) = fnUseProgram(prog)

proc getProgramiv*(prog: GlId, pname: GlEnum): int32 =
  result = 0
  fnGetProgramiv(prog, pname, addr result)

proc getProgramInfoLog*(prog: GlId): string =
  let n = int(getProgramiv(prog, GlInfoLogLength))
  result = ""
  if n > 1:
    result = newString(n)
    var got = 0'i32
    fnGetProgramInfoLog(prog, int32(n), addr got, cstring(result))
    result.setLen(max(int(got), 0))

proc getAttribLocation*(prog: GlId, name: string): int32 =
  fnGetAttribLocation(prog, cstring(name))

proc getUniformLocation*(prog: GlId, name: string): int32 =
  fnGetUniformLocation(prog, cstring(name))

proc getUniformfv*(prog: GlId, loc: int32, n: int): seq[float32] =
  ## `glGetUniformfv` of a uniform with `n` floats (tests / debugging).
  result = newSeq[float32](n)
  if n > 0: fnGetUniformfv(prog, loc, addr result[0])

proc getUniformBlockIndex*(prog: GlId, name: string): uint32 =
  ## `GlInvalidIndex` when the block does not exist.
  fnGetUniformBlockIndex(prog, cstring(name))

proc uniformBlockBinding*(prog: GlId, index, binding: uint32) =
  fnUniformBlockBinding(prog, index, binding)

# ---------------------------------------------------------------- uniforms

proc uniform1f*(loc: int32, v: float32) = fnUniform1f(loc, v)

proc uniform1fv*(loc: int32, v: openArray[float32]) =
  if v.len > 0: fnUniform1fv(loc, int32(v.len), unsafeAddr v[0])

proc uniform2fv*(loc: int32, v: openArray[float32]) =
  if v.len >= 2: fnUniform2fv(loc, int32(v.len div 2), unsafeAddr v[0])

proc uniform3fv*(loc: int32, v: openArray[float32]) =
  if v.len >= 3: fnUniform3fv(loc, int32(v.len div 3), unsafeAddr v[0])

proc uniform4fv*(loc: int32, v: openArray[float32]) =
  if v.len >= 4: fnUniform4fv(loc, int32(v.len div 4), unsafeAddr v[0])

proc uniform1iv*(loc: int32, v: openArray[int32]) =
  if v.len > 0: fnUniform1iv(loc, int32(v.len), unsafeAddr v[0])

proc uniform2iv*(loc: int32, v: openArray[int32]) =
  if v.len >= 2: fnUniform2iv(loc, int32(v.len div 2), unsafeAddr v[0])

proc uniform3iv*(loc: int32, v: openArray[int32]) =
  if v.len >= 3: fnUniform3iv(loc, int32(v.len div 3), unsafeAddr v[0])

proc uniform4iv*(loc: int32, v: openArray[int32]) =
  if v.len >= 4: fnUniform4iv(loc, int32(v.len div 4), unsafeAddr v[0])

proc uniform1i*(loc: int32, v: int32) =
  var x = v
  fnUniform1iv(loc, 1, addr x)

proc uniformMatrix3fv*(loc: int32, v: openArray[float32]) =
  ## Column-major, `transpose = GL_FALSE`; `v.len div 9` matrices.
  if v.len >= 9: fnUniformMatrix3fv(loc, int32(v.len div 9), 0, unsafeAddr v[0])
