## Inventory Lottie expressions (Phase 0.2).
## Scans .lot/.json files for expression keys ("x" with string value).
## Output: CSV to stdout: file,propPath,hash64,len,idents,functions,constructs,source
import std/[os, strutils, json, tables, sets, re, algorithm]

type ExprHit = object
  file, propPath, source: string
  idents, funcs, constructs: seq[string]

proc fnv1a64(s: string): uint64 =
  var h: uint64 = 0xcbf29ce484222325'u64
  for c in s:
    h = h xor uint64(uint8(c))
    h = h * 0x100000001b3'u64
  h

proc normalizeNl(s: string): string =
  s.replace("\r\n", "\n").replace("\r", "\n")

proc collectIdents(src: string): seq[string] =
  ## rough identifier scan: JS-like identifiers, excluding keywords
  let kw = toHashSet(["var","let","const","if","else","for","while","do","return","function",
    "this","new","true","false","null","undefined","break","continue","switch","case","default",
    "try","catch","finally","throw","typeof","instanceof","in","of","void","delete"])
  var i = 0
  var seen: HashSet[string]
  while i < src.len:
    let c = src[i]
    if c == '"' or c == '\'':
      let q = c; inc i
      while i < src.len and src[i] != q:
        if src[i] == '\\': inc i
        inc i
      if i < src.len: inc i
    elif c == '/' and i+1 < src.len and src[i+1] == '/':
      while i < src.len and src[i] != '\n': inc i
    elif c == '/' and i+1 < src.len and src[i+1] == '*':
      inc i; inc i
      while i+1 < src.len and not (src[i] == '*' and src[i+1] == '/'): inc i
      inc i; inc i
    elif c.isAlphaAscii or c == '_' or c == '$':
      let start = i
      while i < src.len and (src[i].isAlphaNumeric or src[i] == '_' or src[i] == '$'): inc i
      let id = src[start ..< i]
      if id notin kw and id notin seen:
        seen.incl(id)
        result.add(id)
    else:
      inc i
  result.sort()

proc collectFuncs(src: string): seq[string] =
  ## identifiers followed by (
  var i = 0
  var seen: HashSet[string]
  let kw = toHashSet(["if","for","while","switch","catch","function","return"])
  while i < src.len:
    let c = src[i]
    if c.isAlphaAscii or c == '_' or c == '$':
      let start = i
      while i < src.len and (src[i].isAlphaNumeric or src[i] == '_' or src[i] == '$'): inc i
      let id = src[start ..< i]
      var j = i
      while j < src.len and src[j] in {' ', '\t', '\n', '\r'}: inc j
      if j < src.len and src[j] == '(' and id notin kw and id notin seen:
        seen.incl(id); result.add(id)
    else:
      inc i
  result.sort()

proc collectConstructs(src: string): seq[string] =
  var seen: HashSet[string]
  template mark(s: string) =
    if s notin seen: seen.incl(s); result.add(s)
  if re.contains(src, re"\bvar\b"): mark("var")
  if re.contains(src, re"\blet\b"): mark("let")
  if re.contains(src, re"\bconst\b"): mark("const")
  if re.contains(src, re"\bif\b"): mark("if")
  if re.contains(src, re"\?"): mark("ternary")
  if re.contains(src, re"\bfor\b"): mark("for")
  if re.contains(src, re"\bwhile\b"): mark("while")
  if re.contains(src, re"\bfunction\b"): mark("function")
  if re.contains(src, re"=>"): mark("arrow")
  if re.contains(src, re"\btry\b"): mark("try")
  if re.contains(src, re"`"): mark("template_string")
  if re.contains(src, re"\bnew\b"): mark("new")
  if re.contains(src, re"\bthis\b"): mark("this")
  result.sort()

proc scan(n: JsonNode; path: string; file: string; hits: var seq[ExprHit]) =
  case n.kind
  of JObject:
    # Expression: key "x" with string value, usually inside property object with k/a/ix
    if n.hasKey("x") and n["x"].kind == JString:
      let src = normalizeNl(n["x"].getStr)
      if src.strip.len > 0:
        var h: ExprHit
        h.file = file
        h.propPath = path & ".x"
        h.source = src
        h.idents = collectIdents(src)
        h.funcs = collectFuncs(src)
        h.constructs = collectConstructs(src)
        hits.add(h)
    for k, v in n:
      scan(v, if path.len == 0: k else: path & "." & k, file, hits)
  of JArray:
    for i in 0 ..< n.len:
      scan(n[i], path & "[" & $i & "]", file, hits)
  else:
    discard

proc csvField(s: string): string =
  "\"" & s.replace("\"", "\"\"").replace("\n", "\\n").replace("\r", "\\r") & "\""

proc main() =
  let roots = @["tests/lottie/golden", "upstream/test/res", "tests/lottie", "examples"]
  var files: seq[string]
  for r in roots:
    if not dirExists(r): continue
    for f in walkDirRec(r):
      let ext = f.splitFile.ext.toLowerAscii
      if ext in [".lot", ".json"]:
        if f notin files: files.add(f)
  files.sort()
  var hits: seq[ExprHit]
  for f in files:
    try:
      let n = parseFile(f)
      scan(n, "", f, hits)
    except CatchableError:
      stderr.writeLine("WARN skip ", f, ": ", getCurrentExceptionMsg())
  echo "file,propPath,hash64,len,idents,functions,constructs,source"
  for h in hits:
    let srcN = normalizeNl(h.source)
    let hv = fnv1a64(srcN)
    echo csvField(h.file), ",", csvField(h.propPath), ",", csvField($hv), ",", h.source.len, ",",
      csvField(h.idents.join("|")), ",", csvField(h.funcs.join("|")), ",", csvField(h.constructs.join("|")), ",",
      csvField(srcN)

when isMainModule:
  main()
