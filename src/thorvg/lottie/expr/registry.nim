## AOT expression registry (D2). Maps expr hash -> compiled proc.
import std/[tables, options, strformat]
import val, runtime, hash

type
  ExprProc* = proc(ctx: ExprCtx): Option[Val] {.gcsafe.}

  RegistryMode* = enum
    rmStrict        ## unknown/uncompiled hash => error (default)
    rmIgnoreCounted ## caller explicitly requested; skip + count

  ExprRegistry* = object
    entries*: Table[string, ExprProc]
    mode*: RegistryMode
    ignored*: int
    errors*: seq[string]

proc initExprRegistry*(mode = rmStrict): ExprRegistry =
  ExprRegistry(entries: initTable[string, ExprProc](), mode: mode)

proc register*(r: var ExprRegistry; hash: string; fn: ExprProc) =
  r.entries[hash] = fn

proc registerSource*(r: var ExprRegistry; source: string; fn: ExprProc) =
  r.register(exprHash(source), fn)

proc lookup*(r: var ExprRegistry; h: string; ctx: string = ""): ExprProc =
  if h in r.entries: return r.entries[h]
  let msg = (if ctx.len > 0: ctx & ": " else: "") & "expression hash " & h & " not in AOT registry"
  if r.mode == rmStrict:
    r.errors.add(msg)
  else:
    inc r.ignored
  return nil

proc lookupSource*(r: var ExprRegistry; source: string; ctx: string = ""): ExprProc =
  r.lookup(exprHash(source), ctx)

proc hasHash*(r: ExprRegistry; h: string): bool = h in r.entries

proc bindFrameEval*(fn: ExprProc; fr: float32): proc(frameNo: float32): Option[Val] {.gcsafe.} =
  ## Wrap ExprCtx proc with Lottie frame/time. fr must be > 0.
  let fr64 = float64(fr)
  result = proc(frameNo: float32): Option[Val] {.gcsafe.} =
    let f = float64(frameNo)
    let t = if fr64 > 0.0: f / fr64 else: 0.0
    fn(ExprCtx(time: t, frame: f))
