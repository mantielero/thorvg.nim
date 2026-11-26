## Lexer for Lottie expression subset (no regex literals, no template strings).
import std/[strutils]

type
  TokKind* = enum
    tkEof, tkNum, tkIdent, tkStr,
    tkLParen, tkRParen, tkLBracket, tkRBracket, tkLBrace, tkRBrace,
    tkComma, tkDot, tkSemi, tkColon, tkQMark,
    tkPlus, tkMinus, tkStar, tkSlash, tkPercent,
    tkEq, tkEqEq, tkBang, tkBangEq, tkLt, tkLtEq, tkGt, tkGtEq,
    tkAndAnd, tkOrOr,
    tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq,
    tkKwVar, tkKwLet, tkKwConst, tkKwIf, tkKwElse, tkKwReturn,
    tkKwTrue, tkKwFalse, tkKwNull, tkKwUndefined, tkKwFunction,
    tkKwThis, tkKwNew, tkForbidden

  Token* = object
    kind*: TokKind
    text*: string
    num*: float64
    line*, col*: int

type Lexer* = object
  src*: string
  i*, line*, col*: int
  prevKind*: TokKind

proc initLexer*(src: string): Lexer =
  Lexer(src: src, i: 0, line: 1, col: 1, prevKind: tkEof)

proc atEnd(l: Lexer): bool = l.i >= l.src.len
proc peek(l: Lexer; off = 0): char =
  let j = l.i + off
  if j < l.src.len: l.src[j] else: '\0'
proc advance(l: var Lexer): char =
  result = l.peek()
  if result == '\0': return
  inc l.i
  if result == '\n': inc l.line; l.col = 1 else: inc l.col

proc addTok(kind: TokKind; text: string; line, col: int; num = 0.0): Token =
  Token(kind: kind, text: text, num: num, line: line, col: col)

proc skipWsAndComments(l: var Lexer) =
  while true:
    while not l.atEnd() and l.peek() in {' ', '\t', '\r', '\n'}: discard l.advance()
    if l.peek() == '/' and l.peek(1) == '/':
      while not l.atEnd() and l.peek() != '\n': discard l.advance()
      continue
    if l.peek() == '/' and l.peek(1) == '*':
      discard l.advance(); discard l.advance()
      while not l.atEnd():
        if l.peek() == '*' and l.peek(1) == '/': discard l.advance(); discard l.advance(); break
        discard l.advance()
      continue
    break

proc isIdentStart(c: char): bool = c.isAlphaAscii or c == '_' or c == '$'
proc isIdentCont(c: char): bool = c.isAlphaNumeric or c == '_' or c == '$'

proc readIdent(l: var Lexer): Token =
  let line = l.line; let col = l.col
  var s = ""
  while isIdentCont(l.peek()): s.add l.advance()
  case s
  of "var": addTok(tkKwVar, s, line, col)
  of "let": addTok(tkKwLet, s, line, col)
  of "const": addTok(tkKwConst, s, line, col)
  of "if": addTok(tkKwIf, s, line, col)
  of "else": addTok(tkKwElse, s, line, col)
  of "return": addTok(tkKwReturn, s, line, col)
  of "true": addTok(tkKwTrue, s, line, col)
  of "false": addTok(tkKwFalse, s, line, col)
  of "null": addTok(tkKwNull, s, line, col)
  of "undefined": addTok(tkKwUndefined, s, line, col)
  of "function": addTok(tkKwFunction, s, line, col)
  of "this": addTok(tkKwThis, s, line, col)
  of "new": addTok(tkKwNew, s, line, col)
  else: addTok(tkIdent, s, line, col)

proc readNum(l: var Lexer): Token =
  let line = l.line; let col = l.col
  var s = ""
  while l.peek().isDigit: s.add l.advance()
  if l.peek() == '.' and l.peek(1).isDigit:
    s.add l.advance()
    while l.peek().isDigit: s.add l.advance()
  if l.peek() in {'e','E'}:
    s.add l.advance()
    if l.peek() in {'+','-'}: s.add l.advance()
    while l.peek().isDigit: s.add l.advance()
  try:
    addTok(tkNum, s, line, col, parseFloat(s))
  except CatchableError:
    addTok(tkNum, s, line, col, 0.0)

proc readStr(l: var Lexer): Token =
  let line = l.line; let col = l.col
  let q = l.advance()
  var s = ""
  while not l.atEnd() and l.peek() != q:
    let c = l.advance()
    if c == '\\' and not l.atEnd():
      let e = l.advance()
      case e
      of 'n': s.add '\n'
      of 'r': s.add '\r'
      of 't': s.add '\t'
      of '\\': s.add '\\'
      of '"': s.add '"'
      of '\'': s.add '\''
      else: s.add e
    else:
      s.add c
  if not l.atEnd(): discard l.advance()
  addTok(tkStr, s, line, col)

proc regexPossiblePrev(k: TokKind): bool =
  k in {tkEof, tkLParen, tkLBracket, tkLBrace, tkComma, tkSemi, tkColon, tkQMark,
        tkEq, tkEqEq, tkBang, tkBangEq, tkLt, tkLtEq, tkGt, tkGtEq,
        tkAndAnd, tkOrOr, tkPlus, tkMinus, tkStar, tkSlash, tkPercent,
        tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq, tkKwReturn, tkKwIf,
        tkKwElse, tkKwVar, tkKwLet, tkKwConst}

proc nextToken*(l: var Lexer): Token =
  l.skipWsAndComments()
  let line = l.line; let col = l.col
  if l.atEnd():
    result = addTok(tkEof, "", line, col); l.prevKind = result.kind; return
  let c = l.peek()
  if isIdentStart(c):
    result = l.readIdent(); l.prevKind = result.kind; return
  if c.isDigit or (c == '.' and l.peek(1).isDigit):
    result = l.readNum(); l.prevKind = result.kind; return
  if c == '"' or c == '\'':
    result = l.readStr(); l.prevKind = result.kind; return
  discard l.advance()
  case c
  of '(': result = addTok(tkLParen, "(", line, col)
  of ')': result = addTok(tkRParen, ")", line, col)
  of '[': result = addTok(tkLBracket, "[", line, col)
  of ']': result = addTok(tkRBracket, "]", line, col)
  of '{': result = addTok(tkLBrace, "{", line, col)
  of '}': result = addTok(tkRBrace, "}", line, col)
  of ',': result = addTok(tkComma, ",", line, col)
  of '.': result = addTok(tkDot, ".", line, col)
  of ';': result = addTok(tkSemi, ";", line, col)
  of ':': result = addTok(tkColon, ":", line, col)
  of '?': result = addTok(tkQMark, "?", line, col)
  of '+':
    if l.peek() == '=': discard l.advance(); result = addTok(tkPlusEq, "+=", line, col)
    else: result = addTok(tkPlus, "+", line, col)
  of '-':
    if l.peek() == '=': discard l.advance(); result = addTok(tkMinusEq, "-=", line, col)
    else: result = addTok(tkMinus, "-", line, col)
  of '*':
    if l.peek() == '=': discard l.advance(); result = addTok(tkStarEq, "*=", line, col)
    else: result = addTok(tkStar, "*", line, col)
  of '/':
    if l.peek() == '=':
      discard l.advance(); result = addTok(tkSlashEq, "/=", line, col)
    elif regexPossiblePrev(l.prevKind):
      # regex literal - forbidden
      var body = "/"
      while not l.atEnd() and l.peek() != '/':
        let rc = l.advance()
        body.add rc
        if rc == '\\' and not l.atEnd(): body.add l.advance()
      if not l.atEnd() and l.peek() == '/': body.add l.advance()
      while not l.atEnd() and l.peek().isAlphaAscii: body.add l.advance()
      result = addTok(tkForbidden, "regex literal: " & body, line, col)
    else:
      result = addTok(tkSlash, "/", line, col)
  of '%': result = addTok(tkPercent, "%", line, col)
  of '=':
    if l.peek() == '=': discard l.advance(); result = addTok(tkEqEq, "==", line, col)
    else: result = addTok(tkEq, "=", line, col)
  of '!':
    if l.peek() == '=': discard l.advance(); result = addTok(tkBangEq, "!=", line, col)
    else: result = addTok(tkBang, "!", line, col)
  of '<':
    if l.peek() == '=': discard l.advance(); result = addTok(tkLtEq, "<=", line, col)
    else: result = addTok(tkLt, "<", line, col)
  of '>':
    if l.peek() == '=': discard l.advance(); result = addTok(tkGtEq, ">=", line, col)
    else: result = addTok(tkGt, ">", line, col)
  of '&':
    if l.peek() == '&': discard l.advance(); result = addTok(tkAndAnd, "&&", line, col)
    else: result = addTok(tkForbidden, "unsupported operator: &", line, col)
  of '|':
    if l.peek() == '|': discard l.advance(); result = addTok(tkOrOr, "||", line, col)
    else: result = addTok(tkForbidden, "unsupported operator: |", line, col)
  else:
    result = addTok(tkForbidden, "unexpected char: " & $c, line, col)
  l.prevKind = result.kind

proc tokenize*(src: string): seq[Token] =
  var l = initLexer(src)
  while true:
    let t = l.nextToken()
    result.add t
    if t.kind == tkEof: break
