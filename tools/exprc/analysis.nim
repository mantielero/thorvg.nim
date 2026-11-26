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
