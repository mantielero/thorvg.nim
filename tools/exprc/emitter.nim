## Nim code emitter for exprc AST. Emits Nim source using a runtime API (defined later).
## Runtime contract (Paso 3): ctx has time, frame, and helpers bmDiv/bmMul/bmSub/bmSum,
## bmSin/bmCos/bmExp etc. Values are ExprVal (num/vec/array/bool/undef).
import std/[strutils, strformat]
import ast

type EmitResult* = object
  ok*: bool
  code*: string
  err*: string

proc emitExpr(e: Expr; indent: int = 0): EmitResult
proc emitStmt(e: Expr; indent: int): EmitResult

proc ind(n: int): string = "  ".repeat(n)

proc emitIdent(name: string): string =
  case name
  of "$bm_rt": "bmRt"
  of "$bm_div", "div": "bmDiv"
  of "$bm_mul", "mul": "bmMul"
  of "$bm_sum", "sum", "add": "bmSum"
  of "$bm_sub", "sub": "bmSub"
  of "$bm_mod", "mod": "bmMod"
  of "time": "ctx.time"
  of "undefined": "evUndef()"
  of "NaN": "evNum(NaN)"
  of "Infinity": "evNum(Inf)"
  else:
    # sanitize $ and other chars
    var s = ""
    for c in name:
      if c.isAlphaNumeric or c == '_': s.add c
      elif c == '$': s.add "d_"
      else: s.add '_'
    if s.len == 0: s = "_v"
    if s[0].isDigit: s = "v_" & s
    s

proc emitExpr(e: Expr; indent: int = 0): EmitResult =
  if e == nil: return EmitResult(ok: true, code: "evUndef()")
  case e.kind
  of ekNum:
    if e.numVal != e.numVal: return EmitResult(ok: true, code: "evNum(NaN)") # NaN
    return EmitResult(ok: true, code: fmt"evNum({e.numVal})")
  of ekStr:
    return EmitResult(ok: true, code: fmt"evStr({escape(e.strVal)})")
  of ekBool:
    return EmitResult(ok: true, code: if e.boolVal: "evBool(true)" else: "evBool(false)")
  of ekNull:
    return EmitResult(ok: true, code: "evNull()")
  of ekUndefined:
    return EmitResult(ok: true, code: "evUndef()")
  of ekIdent:
    return EmitResult(ok: true, code: emitIdent(e.strVal))
  of ekUnary:
    let r = emitExpr(e.rhs, indent)
    if not r.ok: return r
    case e.op
    of "-": return EmitResult(ok: true, code: fmt"evNeg({r.code})")
    of "+": return EmitResult(ok: true, code: fmt"evPos({r.code})")
    of "!": return EmitResult(ok: true, code: fmt"evNot({r.code})")
    else: return EmitResult(ok: false, err: "unsupported unary op " & e.op)
  of ekBinary:
    let l = emitExpr(e.lhs, indent); if not l.ok: return l
    let r = emitExpr(e.brhs, indent); if not r.ok: return r
    case e.bop
    of "+": return EmitResult(ok: true, code: fmt"evAdd({l.code}, {r.code})")
    of "-": return EmitResult(ok: true, code: fmt"evSub({l.code}, {r.code})")
    of "*": return EmitResult(ok: true, code: fmt"evMul({l.code}, {r.code})")
    of "/": return EmitResult(ok: true, code: fmt"evDiv({l.code}, {r.code})")
    of "%": return EmitResult(ok: true, code: fmt"evMod({l.code}, {r.code})")
    of "<": return EmitResult(ok: true, code: fmt"evLt({l.code}, {r.code})")
    of "<=": return EmitResult(ok: true, code: fmt"evLtEq({l.code}, {r.code})")
    of ">": return EmitResult(ok: true, code: fmt"evGt({l.code}, {r.code})")
    of ">=": return EmitResult(ok: true, code: fmt"evGtEq({l.code}, {r.code})")
    of "==": return EmitResult(ok: true, code: fmt"evEq({l.code}, {r.code})")
    of "!=": return EmitResult(ok: true, code: fmt"evNeq({l.code}, {r.code})")
    of "&&": return EmitResult(ok: true, code: fmt"evAnd({l.code}, {r.code})")
    of "||": return EmitResult(ok: true, code: fmt"evOr({l.code}, {r.code})")
    else: return EmitResult(ok: false, err: "unsupported binary op " & e.bop)
  of ekAssign:
    let r = emitExpr(e.brhs, indent); if not r.ok: return r
    if e.lhs.kind == ekIdent:
      let name = emitIdent(e.lhs.strVal)
      case e.bop
      of "=": return EmitResult(ok: true, code: fmt"(block: {name} = {r.code}; {name})")
      of "+=": return EmitResult(ok: true, code: fmt"(block: {name} = evAdd({name}, {r.code}); {name})")
      of "-=": return EmitResult(ok: true, code: fmt"(block: {name} = evSub({name}, {r.code}); {name})")
      of "*=": return EmitResult(ok: true, code: fmt"(block: {name} = evMul({name}, {r.code}); {name})")
      of "/=": return EmitResult(ok: true, code: fmt"(block: {name} = evDiv({name}, {r.code}); {name})")
      else: return EmitResult(ok: false, err: "unsupported assign op " & e.bop)
    else:
      return EmitResult(ok: false, err: "unsupported assignment target")
  of ekMember:
    let o = emitExpr(e.mobj, indent); if not o.ok: return o
    # Math.sin/cos/exp etc
    if e.mobj.kind == ekIdent and e.mobj.strVal == "Math":
      case e.mprop
      of "sin": return EmitResult(ok: true, code: "evMathSin")
      of "cos": return EmitResult(ok: true, code: "evMathCos")
      of "exp": return EmitResult(ok: true, code: "evMathExp")
      of "abs": return EmitResult(ok: true, code: "evMathAbs")
      of "sqrt": return EmitResult(ok: true, code: "evMathSqrt")
      of "floor": return EmitResult(ok: true, code: "evMathFloor")
      of "ceil": return EmitResult(ok: true, code: "evMathCeil")
      of "round": return EmitResult(ok: true, code: "evMathRound")
      of "PI": return EmitResult(ok: true, code: "evNum(PI)")
      else: return EmitResult(ok: false, err: "unsupported Math." & e.mprop)
    return EmitResult(ok: true, code: "evMember(" & o.code & ", " & escape(e.mprop) & ")")
  of ekIndex:
    let o = emitExpr(e.iobj, indent); if not o.ok: return o
    let i = emitExpr(e.iidx, indent); if not i.ok: return i
    return EmitResult(ok: true, code: "evIndex(" & o.code & ", " & i.code & ")")
  of ekCall:
    let c = emitExpr(e.callee, indent); if not c.ok: return c
    var args: seq[string] = @[]
    for a in e.args:
      let ea = emitExpr(a, indent); if not ea.ok: return ea
      args.add ea.code
    return EmitResult(ok: true, code: c.code & "(" & args.join(", ") & ")")
  of ekArray:
    var items: seq[string] = @[]
    for it in e.items:
      let ei = emitExpr(it, indent); if not ei.ok: return ei
      items.add ei.code
    return EmitResult(ok: true, code: "evArray(@[" & items.join(", ") & "]")
  of ekCond:
    let c = emitExpr(e.cnd, indent); if not c.ok: return c
    let t = emitExpr(e.cthen, indent); if not t.ok: return t
    let el = emitExpr(e.cels, indent); if not el.ok: return el
    return EmitResult(ok: true, code: "(if evTruthy(" & c.code & "): " & t.code & " else: " & el.code & ")")
  of ekVarDecl:
    let name = emitIdent(e.vname)
    if e.vinit != nil:
      let v = emitExpr(e.vinit, indent); if not v.ok: return v
      if e.vname == "$bm_rt":
        return EmitResult(ok: true, code: "bmRt = " & v.code)
      return EmitResult(ok: true, code: "var " & name & " = " & v.code)
    else:
      if e.vname == "$bm_rt":
        return EmitResult(ok: true, code: "bmRt = evUndef()")
      return EmitResult(ok: true, code: "var " & name & " = evUndef()")
  of ekSeq, ekBlock, ekProgram:
    var lines: seq[string] = @[]
    for s in e.stmts:
      let es = emitStmt(s, indent + 1); if not es.ok: return es
      if es.code.len > 0: lines.add ind(indent+1) & es.code
    if e.kind == ekProgram:
      return EmitResult(ok: true, code: lines.join("\n"))
    return EmitResult(ok: true, code: "(block:\n" & lines.join("\n") & "\n" & ind(indent) & "evUndef())")
  of ekIf:
    let c = emitExpr(e.ifCond, indent); if not c.ok: return c
    let t = emitStmt(e.ifThen, indent+1); if not t.ok: return t
    var code = "if evTruthy(" & c.code & "):" & "\n" & ind(indent+1) & t.code
    if e.ifElse != nil:
      let el = emitStmt(e.ifElse, indent+1); if not el.ok: return el
      code.add "\n" & ind(indent) & "else:\n" & ind(indent+1) & el.code
    return EmitResult(ok: true, code: code)
  of ekReturn:
    if e.ret != nil:
      let r = emitExpr(e.ret, indent); if not r.ok: return r
      return EmitResult(ok: true, code: "return " & r.code)
    return EmitResult(ok: true, code: "return evUndef()")
  else:
    return EmitResult(ok: false, err: "unsupported node " & $e.kind)

proc emitStmt(e: Expr; indent: int): EmitResult =
  if e == nil: return EmitResult(ok: true, code: "discard")
  case e.kind
  of ekVarDecl, ekIf, ekReturn, ekBlock, ekProgram, ekSeq:
    return emitExpr(e, indent)
  else:
    let r = emitExpr(e, indent)
    if not r.ok: return r
    # expression statement - discard unless assignment already block
    if e.kind == ekAssign and e.lhs.kind == ekIdent:
      return EmitResult(ok: true, code: "discard " & r.code)
    return EmitResult(ok: true, code: "discard " & r.code)

proc emitProgram*(prog: Expr; procName = "exprFn"): EmitResult =
  ## Emit a Nim proc skeleton (runtime types provided in Paso 3).
  let body = emitExpr(prog, 0)
  if not body.ok: return body
  let code = fmt"""
proc {procName}*(ctx: ExprCtx): ExprVal =
  var bmRt = evUndef()
  {body.code.replace("\n", "\n  ")}
  bmRt
"""
  return EmitResult(ok: true, code: code)
