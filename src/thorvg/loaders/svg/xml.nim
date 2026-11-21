## Minimal SAX-like XML tokenizer used by the SVG loader.
##
## Ported from `modules/svg/tvgXmlParser.cpp`. Callbacks receive the token text as a `string`
## (a copy of the slice; entities already decoded for `Data`). Differences with C++:
## the opened-tag state of `SvgParserContext` is read through the `textOpened` closure, the
## `THORVG_LOG_ENABLED` diagnostics are dropped, and `xmlParseCssAttribute` advances an index
## instead of returning pointers. Whitespace helpers live in `./util`.

import std/strutils
import ../../core/str
import ./util

type
  XmlType* {.pure.} = enum
    Open ## <tag attribute="value">
    OpenEmpty ## <tag attribute="value" />
    Close ## </tag>
    Data ## tag text data
    CData ## <![CDATA[something]]>
    Error
    Processing ## <?xml ... ?>
    Doctype ## <!DOCTYPE html
    Comment ## <!-- something -->
    Ignored ## whatever is ignored by the parser, like whitespace
    DoctypeChild ## <!doctype_child

  XmlCb* = proc(t: XmlType, content: string): bool
  XmlAttributeCb* = proc(key, value: string): bool

const XmlEntities = [
  ("&#10;", '\n'), ("&#035;", '#'), ("&#039;", '\''), ("&quot;", '"'), ("&nbsp;", ' '),
  ("&apos;", '\''), ("&amp;", '&'), ("&lt;", '<'), ("&gt;", '>')]

func decodeEntities(s: string, a, b: int): string =
  ## Text of `s[a ..< b]` with the known entities replaced (one pass, no recursion).
  var i = a
  while i < b:
    var matched = false
    if s[i] == '&':
      for (name, ch) in XmlEntities:
        if b - i >= name.len and s.continuesWith(name, i):
          result.add ch
          i += name.len
          matched = true
          break
    if not matched:
      result.add s[i]
      inc i

func findFrom(s: string, c: char, a, b: int): int =
  ## Index of `c` in `s[a ..< b]` or -1.
  for i in a ..< b:
    if s[i] == c: return i
  -1

func findEndTag(s: string, a, b: int): int =
  var inDouble, inSingle = false
  for i in a ..< b:
    if s[i] == '"' and not inSingle: inDouble = not inDouble
    if s[i] == '\'' and not inDouble: inSingle = not inSingle
    if not inDouble and not inSingle and s[i] in {'>', '<'}: return i
  -1

func findEndOf(s: string, c: char, a, b: int): int =
  ## Index of the `>` closing a `cc>` sequence (`--` or `]]`), or -1.
  for i in a ..< b:
    if s[i] == c and i + 1 < b and s[i + 1] == c and i + 2 < b and s[i + 2] == '>':
      return i + 2
  -1

func xmlType(s: string, i, b: int, toff: var int): XmlType =
  toff = 0
  case s[i + 1]
  of '/':
    toff = 1
    XmlType.Close
  of '?':
    toff = 1
    XmlType.Processing
  of '!':
    if i + 10 < b and s.continuesWith("DOCTYPE", i + 2) and
        (s[i + 9] == '>' or isCSpace(s[i + 9])):
      toff = 8
      XmlType.Doctype
    elif i + 12 < b and s.continuesWith("[CDATA[", i + 2):
      toff = 8
      XmlType.CData
    elif i + 7 < b and s.continuesWith("--", i + 2):
      toff = 3
      XmlType.Comment
    elif i + 3 < b:
      toff = 1
      XmlType.DoctypeChild
    else: XmlType.Open
  else: XmlType.Open

proc xmlParseAttributes*(buf: string, cb: XmlAttributeCb): bool =
  ## Calls `cb(key, value)` for each `key="value"` pair (quotes optional, entities decoded,
  ## surrounding blanks trimmed). Returns false on malformed input.
  let itrEnd = buf.len
  var itr = 0
  while itr < itrEnd:
    let key = skipWhiteSpace(buf, itr, itrEnd)
    if key == itrEnd: return true
    var keyEnd = key
    while keyEnd < itrEnd and buf[keyEnd] != '=' and not isCSpace(buf[keyEnd]): inc keyEnd
    if keyEnd == itrEnd: return false
    if keyEnd == key: # no key: invalid, but explores the following syntax
      itr = keyEnd + 1
    else:
      var value: int
      if buf[keyEnd] == '=': value = keyEnd + 1
      else:
        value = findFrom(buf, '=', keyEnd, itrEnd)
        if value < 0: return false
        inc value
      value = skipWhiteSpace(buf, value, itrEnd)
      if value == itrEnd: return false
      var valueEnd: int
      if buf[value] in {'"', '\''}:
        valueEnd = findFrom(buf, buf[value], value + 1, itrEnd)
        if valueEnd < 0: return false
        inc value
      else:
        valueEnd = value
        while valueEnd < itrEnd and not isCSpace(buf[valueEnd]): inc valueEnd
      itr = if valueEnd < itrEnd: valueEnd + 1 else: valueEnd
      value = skipWhiteSpace(buf, value, valueEnd)
      if value < valueEnd: valueEnd = unskipWhiteSpace(buf, valueEnd, value)
      var tval = decodeEntities(buf, value, valueEnd)
      if tval.len > 0:
        let decodedEnd = unskipWhiteSpace(tval, tval.len, 0)
        let first = skipWhiteSpace(tval, 0, decodedEnd)
        tval = tval[first ..< decodedEnd]
      discard cb(buf[key ..< keyEnd], tval)
  true

proc xmlParse*(buf: string, strip: bool, cb: XmlCb, textOpened: proc(): bool = nil): bool =
  ## Tokenizes `buf`, calling `cb(type, content)` for each token. With `strip`, blanks around
  ## markup and text become `Ignored` tokens unless `textOpened()` says a text element is open.
  ## Returns false on malformed markup or when `cb` returns false.
  let itrEnd = buf.len
  var itr = 0
  template stripping(): bool = strip and not (textOpened != nil and textOpened())
  while itr < itrEnd:
    if buf[itr] == '<':
      if itr + 1 >= itrEnd: return false
      var toff = 0
      var t = xmlType(buf, itr, itrEnd, toff)
      let a = itr + 1 + toff
      let p =
        case t
        of XmlType.CData: findEndOf(buf, ']', a, itrEnd)
        of XmlType.DoctypeChild: findFrom(buf, '>', a, itrEnd)
        of XmlType.Comment: findEndOf(buf, '-', a, itrEnd)
        else: findEndTag(buf, a, itrEnd)
      if p < 0 or (buf[p] == '<' and t != XmlType.Doctype): return false
      var start = a
      var finish = p
      case t
      of XmlType.Open:
        if buf[p - 1] == '/':
          t = XmlType.OpenEmpty
          dec finish
      of XmlType.CData:
        if buf.continuesWith("]]", p - 2): finish -= 2
      of XmlType.Processing:
        if buf[p - 1] == '?': dec finish
      of XmlType.Comment:
        if buf.continuesWith("--", p - 2): finish -= 2
      else: discard
      if strip and t != XmlType.CData:
        start = skipWhiteSpace(buf, start, finish)
        finish = unskipWhiteSpace(buf, finish, start)
      if not cb(t, buf[start ..< finish]): return false
      itr = p + 1
    else:
      if stripping():
        let q = skipWhiteSpace(buf, itr, itrEnd)
        if q != itr:
          if not cb(XmlType.Ignored, buf[itr ..< q]): return false
          itr = q
      var p = findFrom(buf, '<', itr, itrEnd)
      if p < 0: p = itrEnd
      var finish = p
      if stripping(): finish = unskipWhiteSpace(buf, finish, itr)
      if itr != finish:
        let hasEntity = findFrom(buf, '&', itr, finish) >= 0
        let text = if hasEntity: decodeEntities(buf, itr, finish) else: buf[itr ..< finish]
        if not cb(XmlType.Data, text): return false
      if strip and finish < p and not cb(XmlType.Ignored, buf[finish ..< p]):
        return false
      itr = p
  true

proc xmlParseW3CAttribute*(buf: string, cb: XmlAttributeCb): bool =
  ## Calls `cb(key, value)` for each `key: value;` declaration of a `style` attribute or
  ## CSS block. A `src:` value may contain an extra `;`, which is skipped.
  if buf.len == 0: return true
  let finish = buf.len
  var pos = 0
  while true:
    var sep = findFrom(buf, ':', pos, finish)
    var next = findFrom(buf, ';', pos, finish)
    if sep < 0: sep = finish
    if next < 0: next = finish
    var src = pos
    while sep - src >= 3 and not buf.continuesWith("src", src): inc src
    if sep - src < 3: src = sep
    if sep < finish and next < finish and src < sep: # `src` from css font-face
      if next + 1 < finish:
        next = findFrom(buf, ';', next + 1, finish)
        if next < 0: next = finish
      else: break
    var key, val = ""
    if sep < finish and next >= finish:
      key = buf[pos ..< sep]
      val = buf[sep + 1 ..< finish]
    elif sep < finish and sep < next:
      key = buf[pos ..< sep]
      val = buf[sep + 1 ..< next]
    elif next < finish:
      key = buf[pos ..< next]
    if key.len > 0:
      let k0 = skipWhiteSpace(key, 0)
      let k1 = unskipWhiteSpace(key, key.len, k0)
      let v0 = skipWhiteSpace(val, 0)
      let v1 = unskipWhiteSpace(val, val.len, v0)
      discard cb(key[k0 ..< k1], val[v0 ..< v1])
    if next >= finish: break
    pos = next + 1
  true

proc xmlParseCssAttribute*(buf: string, pos: var int, tag, name, attrs: var string): bool =
  ## Reads the next `tag {..}`, `.name {..}` or `tag.name {..}` rule at `pos` (supported
  ## forms of the original). `tag` is "all" for a bare `.name`; `name` is "" when absent;
  ## `attrs` is the text between the braces. Advances `pos` past the `}`; false at the end.
  tag = ""
  name = ""
  attrs = ""
  let itr = skipWhiteSpace(buf, pos, buf.len)
  var itrEnd = findFrom(buf, '{', pos, buf.len)
  if itrEnd < 0 or itr == itrEnd: return false
  let nextElement = findFrom(buf, '}', itrEnd, buf.len)
  if nextElement < 0: return false
  attrs = buf[itrEnd + 1 ..< nextElement]
  itrEnd = unskipWhiteSpace(buf, itrEnd, itr)
  if buf[itrEnd - 1] == '.': return false
  var p = itr
  while p < itrEnd and buf[p] != '.': inc p
  tag = if p == itr: "all" else: buf[itr ..< p]
  if p != itrEnd: name = buf[p + 1 ..< itrEnd]
  pos = nextElement + 1
  true

func xmlFindAttributesTag*(buf: string): int =
  ## Index where the attributes of an opening tag start: the first blank, or `buf.len`.
  ## Returns 0 when an `=` shows up before any blank (the tag name was skipped).
  for i in 0 ..< buf.len:
    if not isCSpace(buf[i]):
      if buf[i] == '=': return 0
    else: return i
  buf.len
