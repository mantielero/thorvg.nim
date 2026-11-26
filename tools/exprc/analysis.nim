## Definitive $bm_rt assignment analysis.
## Conservative: daYes only when all paths assign $bm_rt; daMaybe when some do; daNo when none.
import ast

type DefAssign* = enum
  daNo, daMaybe, daYes

proc isBmRt*(e: Expr): bool =
  e != nil and e.kind == ekIdent and e.strVal == "$bm_rt"

proc assignsBmRtExpr(e: Expr): DefAssign =
  ## Check if expression itself definitely assigns $bm_rt (e.g. $bm_rt = x, ($bm_rt=x, ...))
  if e == nil: return daNo
  case e.kind
  of ekAssign:
    if isBmRt(e.lhs): return daYes
    # rhs may assign, lhs may be complex - conservative
    let r = assignsBmRtExpr(e.brhs)
    let l = assignsBmRtExpr(e.lhs)
    if r == daYes or l == daYes: return daYes
    if r == daMaybe or l == daMaybe: return daMaybe
    return daNo
  of ekSeq:
    # comma/seq: last value? but as stmt seq, any definitive stmt counts if reached.
    # For expression sequence, assignment anywhere? No - definitive means guaranteed.
    var anyMaybe = false
    var anyYes = false
    for s in e.stmts:
      let a = assignsBmRtExpr(s)
      if a == daYes: anyYes = true
      elif a == daMaybe: anyMaybe = true
    if anyYes: return daYes # at least one definitely assigns - but in seq all execute; yes
    if anyMaybe: return daMaybe
    return daNo
  of ekCond:
    let t = assignsBmRtExpr(e.cthen)
    let el = assignsBmRtExpr(e.cels)
    if t == daYes and el == daYes: return daYes
    if t == daNo and el == daNo: return daNo
    return daMaybe
  of ekCall:
    var anyMaybe = false
    for a in e.args:
      let r = assignsBmRtExpr(a)
      if r == daYes: return daYes # arg evaluated
      if r == daMaybe: anyMaybe = true
    let c = assignsBmRtExpr(e.callee)
    if c == daYes: return daYes
    if c == daMaybe or anyMaybe: return daMaybe
    return daNo
  of ekBinary:
    let l = assignsBmRtExpr(e.lhs)
    let r = assignsBmRtExpr(e.brhs)
    if l == daYes or r == daYes: return daYes # both evaluated in normal case
    if l == daMaybe or r == daMaybe: return daMaybe
    return daNo
  of ekUnary:
    return assignsBmRtExpr(e.rhs)
  of ekMember:
    return assignsBmRtExpr(e.mobj)
  of ekIndex:
    let o = assignsBmRtExpr(e.iobj); let i = assignsBmRtExpr(e.iidx)
    if o == daYes or i == daYes: return daYes
    if o == daMaybe or i == daMaybe: return daMaybe
    return daNo
  of ekArray:
    var anyMaybe = false
    for it in e.items:
      let r = assignsBmRtExpr(it)
      if r == daYes: return daYes
      if r == daMaybe: anyMaybe = true
    return if anyMaybe: daMaybe else: daNo
  else:
    return daNo

proc stmtAssigns*(e: Expr): DefAssign =
  ## Definitive assignment across statement/control flow.
  if e == nil: return daNo
  case e.kind
  of ekProgram, ekBlock, ekSeq:
    # Sequential: if any stmt definitively assigns and is always executed before end -> Yes.
    # Conservative: if we see daYes at any point, and no early return/throw we model, Yes.
    var sawYes = false
    var sawMaybe = false
    for s in e.stmts:
      let a = stmtAssigns(s)
      if a == daYes: sawYes = true
      elif a == daMaybe: sawMaybe = true
    if sawYes: return daYes
    if sawMaybe: return daMaybe
    return daNo
  of ekIf:
    let t = stmtAssigns(e.ifThen)
    let el = if e.ifElse != nil: stmtAssigns(e.ifElse) else: daNo
    if t == daYes and el == daYes: return daYes
    if t == daNo and el == daNo: return daNo
    return daMaybe
  of ekVarDecl:
    # var $bm_rt = ... counts as assignment to $bm_rt result
    if e.vname == "$bm_rt" and e.vinit != nil: return daYes
    if e.vinit != nil: return assignsBmRtExpr(e.vinit)
    return daNo
  of ekReturn:
    if e.ret != nil: return assignsBmRtExpr(e.ret)
    return daNo
  else:
    # expression statement
    return assignsBmRtExpr(e)

proc definitiveBmRt*(prog: Expr): bool =
  stmtAssigns(prog) == daYes

type ReadDiag* = object
  line*, col*: int
  msg*: string

proc collectReadsBmRt(e: Expr; assigned: var bool; diags: var seq[ReadDiag]) =
  ## Flow-sensitive: flag reads of $bm_rt before definitive assignment.
  if e == nil: return
  case e.kind
  of ekIdent:
    if e.strVal == "$bm_rt" and not assigned:
      diags.add(ReadDiag(line: e.span.line, col: e.span.col,
        msg: "read_before_assign: lectura de $bm_rt antes de asignación definitiva (dependiente de orden/fuga ThorVG); no replicable"))
  of ekAssign:
    if isBmRt(e.lhs):
      # rhs evaluated before assignment takes effect
      collectReadsBmRt(e.brhs, assigned, diags)
      assigned = true
      # compound assign means read+write: $bm_rt += 1
      if e.bop != "=":
        diags.add(ReadDiag(line: e.span.line, col: e.span.col,
          msg: "read_before_assign: asignación compuesta sobre $bm_rt lee valor previo (dependiente de orden/fuga ThorVG); no replicable"))
    else:
      collectReadsBmRt(e.lhs, assigned, diags)
      collectReadsBmRt(e.brhs, assigned, diags)
  of ekVarDecl:
    if e.vname == "$bm_rt":
      if e.vinit != nil:
        collectReadsBmRt(e.vinit, assigned, diags)
        assigned = true
      # var $bm_rt; without init - not assigned, but also not a read
    else:
      collectReadsBmRt(e.vinit, assigned, diags)
  of ekSeq, ekBlock, ekProgram:
    for s in e.stmts:
      collectReadsBmRt(s, assigned, diags)
  of ekIf:
    collectReadsBmRt(e.ifCond, assigned, diags)
    var aThen = assigned
    var aElse = assigned
    var dThen: seq[ReadDiag] = @[]
    var dElse: seq[ReadDiag] = @[]
    collectReadsBmRt(e.ifThen, aThen, dThen)
    if e.ifElse != nil: collectReadsBmRt(e.ifElse, aElse, dElse)
    diags.add(dThen); diags.add(dElse)
    assigned = assigned or (aThen and aElse)
  of ekCond:
    collectReadsBmRt(e.cnd, assigned, diags)
    var aT = assigned; var aE = assigned
    var dT: seq[ReadDiag] = @[]; var dE: seq[ReadDiag] = @[]
    collectReadsBmRt(e.cthen, aT, dT)
    collectReadsBmRt(e.cels, aE, dE)
    diags.add(dT); diags.add(dE)
    assigned = assigned or (aT and aE)
  of ekUnary: collectReadsBmRt(e.rhs, assigned, diags)
  of ekBinary:
    collectReadsBmRt(e.lhs, assigned, diags)
    collectReadsBmRt(e.brhs, assigned, diags)
  of ekMember: collectReadsBmRt(e.mobj, assigned, diags)
  of ekIndex:
    collectReadsBmRt(e.iobj, assigned, diags)
    collectReadsBmRt(e.iidx, assigned, diags)
  of ekCall:
    collectReadsBmRt(e.callee, assigned, diags)
    for a in e.args: collectReadsBmRt(a, assigned, diags)
  of ekArray:
    for it in e.items: collectReadsBmRt(it, assigned, diags)
  of ekReturn: collectReadsBmRt(e.ret, assigned, diags)
  else: discard

proc readBeforeAssignBmRt*(prog: Expr): seq[ReadDiag] =
  var assigned = false
  result = @[]
  collectReadsBmRt(prog, assigned, result)
