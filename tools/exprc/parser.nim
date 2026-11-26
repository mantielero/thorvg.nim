## Pratt parser for Lottie expression subset.
## Supported: literals, ident, unary, binary, assign/compound-assign, member, index,
## call, array, ternary, comma/seq, var/let/const decl, if/else, block, return.
## Rejected (diagnostic): function decl/expr, with, eval, new, regex literal (not lexed), dynamic global access patterns.
import std/[strutils, tables]
import ast, lexer

type
  ParseDiag* = object
    line*, col*: int
    msg*: string

  ParseResult* = object
    ok*: bool
    expr*: Expr
    diags*: seq[ParseDiag]

  Parser = object
    toks: seq[Token]
    pos: int
    diags: seq[ParseDiag]

proc cur(p: Parser): Token =
  if p.pos < p.toks.len: p.toks[p.pos] else: p.toks[^1]

proc at(p: Parser; k: TokKind): bool = p.cur.kind == k
proc atEnd(p: Parser): bool = p.at(tkEof)

proc diag(p: var Parser; msg: string; t: Token = Token()) =
  let tok = if t.kind != tkEof or t.line != 0: t else: p.cur
  p.diags.add(ParseDiag(line: tok.line, col: tok.col, msg: msg))

proc advance(p: var Parser): Token =
  result = p.cur
  if p.pos < p.toks.len - 1: inc p.pos

proc expect(p: var Parser; k: TokKind; msg: string): Token =
  if p.at(k): return p.advance()
  p.diag(msg & " (got " & $p.cur.kind & ")")
  result = p.cur

proc parseExpr(p: var Parser; minPrec = 0): Expr
proc parseStmt(p: var Parser): Expr
proc parseBlock(p: var Parser): Expr

proc span(t: Token): Span = sp(t.line, t.col, t.text.len)

proc isForbiddenIdent(name: string): bool =
  name in ["eval", "Function", "with", "globalThis", "window", "self", "frames"]

proc parsePrimary(p: var Parser): Expr =
  let t = p.cur
  case t.kind
  of tkNum: discard p.advance(); return newNum(t.num, span(t))
  of tkStr: discard p.advance(); return newStr(t.text, span(t))
  of tkKwTrue: discard p.advance(); return Expr(kind: ekBool, boolVal: true, span: span(t))
  of tkKwFalse: discard p.advance(); return Expr(kind: ekBool, boolVal: false, span: span(t))
  of tkKwNull: discard p.advance(); return Expr(kind: ekNull, span: span(t))
  of tkKwUndefined: discard p.advance(); return Expr(kind: ekUndefined, span: span(t))
  of tkKwThis: discard p.advance(); return newIdent("this", span(t))
  of tkIdent:
    discard p.advance()
    if isForbiddenIdent(t.text):
      p.diag("forbidden construct: " & t.text, t)
    return newIdent(t.text, span(t))
  of tkKwFunction:
    p.diag("forbidden construct: function", t); discard p.advance()
    # best-effort consume
    if p.at(tkIdent): discard p.advance()
    if p.at(tkLParen):
      discard p.advance(); var depth=1
      while not p.atEnd() and depth>0:
        if p.at(tkLParen): inc depth
        elif p.at(tkRParen): dec depth
        discard p.advance()
    if p.at(tkLBrace): discard p.parseBlock()
    return newIdent("undefined", span(t))
  of tkLParen:
    discard p.advance()
    let e = p.parseExpr(0)
    discard p.expect(tkRParen, "expected ')'")
    return e
  of tkLBracket:
    discard p.advance()
    var items: seq[Expr] = @[]
    if not p.at(tkRBracket):
      while true:
        items.add p.parseExpr(0)
        if p.at(tkComma): discard p.advance() else: break
    discard p.expect(tkRBracket, "expected ']'")
    return newArray(items, span(t))
  of tkKwNew:
    p.diag("forbidden construct: new", t); discard p.advance()
    discard p.parseExpr(20) # consume callee
    return newIdent("undefined", span(t))
  of tkForbidden:
    p.diag("forbidden/unsupported: " & t.text, t); discard p.advance()
    return newIdent("undefined", span(t))
  else:
    p.diag("unexpected token in expression: " & $t.kind, t)
    discard p.advance()
    return newIdent("undefined", span(t))

proc parsePostfix(p: var Parser): Expr =
  result = p.parsePrimary()
  while true:
    if p.at(tkDot):
      let dt = p.advance()
      if p.at(tkIdent) or p.at(tkKwThis):
        let prop = p.cur.text
        discard p.advance()
        result = newMember(result, prop, span(dt))
      else:
        p.diag("expected property name after '.'", dt)
        break
    elif p.at(tkLBracket):
      let bt = p.advance()
      let idx = p.parseExpr(0)
      discard p.expect(tkRBracket, "expected ']'")
      # dynamic property access via computed string? treat as index
      result = newIndex(result, idx, span(bt))
    elif p.at(tkLParen):
      let ct = p.advance()
      var args: seq[Expr] = @[]
      if not p.at(tkRParen):
        while true:
          args.add p.parseExpr(0)
          if p.at(tkComma): discard p.advance() else: break
      discard p.expect(tkRParen, "expected ')'")
      # check forbidden calls
      if result.kind == ekIdent and isForbiddenIdent(result.strVal):
        p.diag("forbidden call: " & result.strVal, ct)
      result = newCall(result, args, span(ct))
    else:
      break

proc prefixPrec(k: TokKind): int =
  case k
  of tkBang, tkMinus, tkPlus: 17
  else: -1

proc infixPrec(k: TokKind): int =
  case k
  of tkStar, tkSlash, tkPercent: 15
  of tkPlus, tkMinus: 14
  of tkLt, tkLtEq, tkGt, tkGtEq: 12
  of tkEqEq, tkBangEq: 11
  of tkAndAnd: 6
  of tkOrOr: 5
  of tkQMark: 4
  of tkEq, tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq: 3
  of tkComma: 1
  else: -1

proc isRightAssoc(k: TokKind): bool =
  k in {tkEq, tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq, tkQMark}

proc parseExpr(p: var Parser; minPrec = 0): Expr =
  # prefix
  var left: Expr
  let t = p.cur
  let pp = prefixPrec(t.kind)
  if pp >= 0:
    discard p.advance()
    let rhs = p.parseExpr(pp)
    left = newUnary(t.text, rhs, span(t))
  else:
    left = p.parsePostfix()

  while true:
    let op = p.cur
    let prec = infixPrec(op.kind)
    if prec < minPrec: break
    if op.kind == tkQMark:
      discard p.advance()
      let thenE = p.parseExpr(0)
      discard p.expect(tkColon, "expected ':' in ternary")
      let elseE = p.parseExpr(prec - (if isRightAssoc(op.kind): 1 else: 0))
      left = newCond(left, thenE, elseE, span(op))
      continue
    discard p.advance()
    let nextPrec = if isRightAssoc(op.kind): prec else: prec + 1
    let right = p.parseExpr(nextPrec)
    if op.kind in {tkEq, tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq}:
      left = newAssign(op.text, left, right, span(op))
    elif op.kind == tkComma:
      # flatten comma seq
      if left.kind == ekSeq:
        left.stmts.add right
      else:
        left = newSeq(@[left, right], span(op))
    else:
      left = newBinary(op.text, left, right, span(op))
  return left

proc parseVarDecl(p: var Parser): Expr =
  let t = p.advance() # var/let/const
  let nameTok = p.cur
  if not p.at(tkIdent):
    p.diag("expected identifier in declaration", nameTok)
    return newVarDecl("_bad", nil, span(t))
  discard p.advance()
  var init: Expr = nil
  if p.at(tkEq):
    discard p.advance()
    init = p.parseExpr(0)
  # handle `var a=1, b=2;` as seq in caller by returning single; caller loops
  return newVarDecl(nameTok.text, init, span(t))

proc parseIf(p: var Parser): Expr =
  let t = p.advance()
  discard p.expect(tkLParen, "expected '(' after if")
  let cond = p.parseExpr(0)
  discard p.expect(tkRParen, "expected ')' after if condition")
  let thenS = p.parseStmt()
  var elseS: Expr = nil
  if p.at(tkKwElse):
    discard p.advance()
    elseS = p.parseStmt()
  return newIf(cond, thenS, elseS, span(t))

proc parseBlock(p: var Parser): Expr =
  let t = p.expect(tkLBrace, "expected '{'")
  var stmts: seq[Expr] = @[]
  while not p.at(tkRBrace) and not p.atEnd():
    stmts.add p.parseStmt()
  discard p.expect(tkRBrace, "expected '}'")
  return newSeq(stmts, span(t), ekBlock)

proc parseStmt(p: var Parser): Expr =
  if p.at(tkSemi): discard p.advance(); return newSeq(@[], sp(p.cur.line,p.cur.col), ekBlock)
  if p.at(tkKwVar) or p.at(tkKwLet) or p.at(tkKwConst):
    var decls: seq[Expr] = @[]
    decls.add p.parseVarDecl()
    while p.at(tkComma):
      discard p.advance()
      let nt = p.cur
      if not p.at(tkIdent): p.diag("expected identifier"); break
      discard p.advance()
      var init: Expr = nil
      if p.at(tkEq): discard p.advance(); init = p.parseExpr(0)
      decls.add newVarDecl(nt.text, init, span(nt))
    if p.at(tkSemi): discard p.advance()
    if decls.len == 1: return decls[0]
    return newSeq(decls, decls[0].span)
  if p.at(tkKwIf): return p.parseIf()
  if p.at(tkLBrace): return p.parseBlock()
  if p.at(tkKwReturn):
    let t = p.advance()
    var v: Expr = nil
    if not p.at(tkSemi) and not p.at(tkRBrace) and not p.atEnd():
      v = p.parseExpr(0)
    if p.at(tkSemi): discard p.advance()
    return Expr(kind: ekReturn, ret: v, span: span(t))
  if p.at(tkKwFunction):
    discard p.parsePrimary() # will diag
    return newSeq(@[], sp(p.cur.line,p.cur.col), ekBlock)
  let e = p.parseExpr(0)
  if p.at(tkSemi): discard p.advance()
  return e

proc parseProgram*(src: string): ParseResult =
  var p = Parser(toks: tokenize(src), pos: 0, diags: @[])
  var stmts: seq[Expr] = @[]
  while not p.atEnd():
    stmts.add p.parseStmt()
  let prog = newSeq(stmts, sp(1,1), ekProgram)
  # post-checks for forbidden constructs in AST (eval/Function as idents already diagged)
  proc walk(e: Expr; p: var Parser) =
    if e == nil: return
    case e.kind
    of ekIdent:
      if isForbiddenIdent(e.strVal): p.diag("forbidden construct: " & e.strVal, Token(line:e.span.line, col:e.span.col, kind:tkIdent))
      if e.strVal == "this": p.diag("forbidden/unsupported construct: this", Token(line:e.span.line, col:e.span.col, kind:tkIdent))
    of ekCall:
      if e.callee.kind == ekIdent and isForbiddenIdent(e.callee.strVal):
        p.diag("forbidden call: " & e.callee.strVal, Token(line:e.span.line, col:e.span.col, kind:tkIdent))
      # dynamic name access via computed member/index with string from unknown? conservative: flag ["name"] on global-like? no, too broad.
      walk(e.callee, p)
      for a in e.args: walk(a, p)
    of ekUnary: walk(e.rhs, p)
    of ekBinary, ekAssign: walk(e.lhs, p); walk(e.brhs, p)
    of ekMember: walk(e.mobj, p)
    of ekIndex: walk(e.iobj, p); walk(e.iidx, p)
    of ekArray:
      for it in e.items: walk(it, p)
    of ekCond: walk(e.cnd, p); walk(e.cthen, p); walk(e.cels, p)
    of ekSeq, ekBlock, ekProgram:
      for s in e.stmts: walk(s, p)
    of ekVarDecl: walk(e.vinit, p)
    of ekIf: walk(e.ifCond, p); walk(e.ifThen, p); walk(e.ifElse, p)
    of ekReturn: walk(e.ret, p)
    else: discard
  walk(prog, p)
  result.ok = p.diags.len == 0
  result.expr = prog
  result.diags = p.diags
