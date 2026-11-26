## Minimal JS-subset AST for Lottie expressions (AOT). No eval/with/regex.
type
  Span* = object
    line*, col*, len*: int

  ExprKind* = enum
    ekNum, ekIdent, ekStr, ekBool, ekNull, ekUndefined,
    ekUnary, ekBinary, ekAssign, ekMember, ekIndex, ekCall,
    ekArray, ekObject, ekCond, ekSeq, ekVarDecl, ekIf, ekReturn,
    ekBlock, ekProgram

  Expr* = ref object
    span*: Span
    case kind*: ExprKind
    of ekNum: numVal*: float64
    of ekIdent, ekStr: strVal*: string
    of ekBool: boolVal*: bool
    of ekNull, ekUndefined: discard
    of ekUnary:
      op*: string
      rhs*: Expr
    of ekBinary, ekAssign:
      bop*: string
      lhs*, brhs*: Expr
    of ekMember:
      mobj*: Expr
      mprop*: string
      mcomputed*: bool
    of ekIndex:
      iobj*, iidx*: Expr
    of ekCall:
      callee*: Expr
      args*: seq[Expr]
    of ekArray:
      items*: seq[Expr]
    of ekObject:
      # not needed now
      discard
    of ekCond:
      cnd*, cthen*, cels*: Expr
    of ekSeq, ekBlock, ekProgram:
      stmts*: seq[Expr]
    of ekVarDecl:
      vname*: string
      vinit*: Expr # nil if none
    of ekIf:
      ifCond*: Expr
      ifThen*: Expr
      ifElse*: Expr # nil
    of ekReturn:
      ret*: Expr

proc sp*(line, col, len = 0): Span = Span(line: line, col: col, len: len)

proc newNum*(v: float64; s: Span): Expr = Expr(kind: ekNum, numVal: v, span: s)
proc newIdent*(v: string; s: Span): Expr = Expr(kind: ekIdent, strVal: v, span: s)
proc newStr*(v: string; s: Span): Expr = Expr(kind: ekStr, strVal: v, span: s)
proc newUnary*(op: string; rhs: Expr; s: Span): Expr = Expr(kind: ekUnary, op: op, rhs: rhs, span: s)
proc newBinary*(op: string; a,b: Expr; s: Span): Expr = Expr(kind: ekBinary, bop: op, lhs: a, brhs: b, span: s)
proc newAssign*(op: string; a,b: Expr; s: Span): Expr = Expr(kind: ekAssign, bop: op, lhs: a, brhs: b, span: s)
proc newMember*(obj: Expr; prop: string; s: Span): Expr = Expr(kind: ekMember, mobj: obj, mprop: prop, mcomputed: false, span: s)
proc newIndex*(obj, idx: Expr; s: Span): Expr = Expr(kind: ekIndex, iobj: obj, iidx: idx, span: s)
proc newCall*(callee: Expr; args: seq[Expr]; s: Span): Expr = Expr(kind: ekCall, callee: callee, args: args, span: s)
proc newArray*(items: seq[Expr]; s: Span): Expr = Expr(kind: ekArray, items: items, span: s)
proc newCond*(c,t,e: Expr; s: Span): Expr = Expr(kind: ekCond, cnd: c, cthen: t, cels: e, span: s)
proc newSeq*(stmts: seq[Expr]; s: Span; kind: ExprKind = ekSeq): Expr =
  case kind
  of ekProgram: Expr(kind: ekProgram, stmts: stmts, span: s)
  of ekBlock: Expr(kind: ekBlock, stmts: stmts, span: s)
  else: Expr(kind: ekSeq, stmts: stmts, span: s)
proc newVarDecl*(name: string; init: Expr; s: Span): Expr = Expr(kind: ekVarDecl, vname: name, vinit: init, span: s)
proc newIf*(c,t,e: Expr; s: Span): Expr = Expr(kind: ekIf, ifCond: c, ifThen: t, ifElse: e, span: s)
