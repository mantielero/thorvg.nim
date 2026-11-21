## Pure CSS helpers of the SVG loader: style sheet rules, selector lists and class lists.
##
## Ported from the string-level parts of `modules/svg/tvgSvgLoader.cpp`
## (`_svgLoaderParserXmlCssStyle`, `_parseName`, `_cssApplyClass`) on top of
## `xmlParseCssAttribute`. The node-level part of `tvgSvgCssStyle.cpp`
## (`cssCopyStyleAttr`, `cssFindStyleNode`, `cssUpdateStyle`) works on `SvgNode`/
## `SvgStyleProperty`, which belong to T17, so it is ported there (see DECISIONS.md D9).

import ./[util, xml]

type CssRule* = object
  ## One `selector { declarations }` rule.
  tag*: string ## element name, or "all" for a bare `.class` selector
  name*: string ## class name(s) after the dot, "" when absent (may hold a `,` list)
  attrs*: string ## raw declarations between the braces (feed to `xmlParseW3CAttribute`)

func splitNames*(s: string, delims: set[char]): seq[string] =
  ## `strtok`-style split on any of `delims`, each token trimmed of blanks; empty tokens
  ## are dropped (the `_parseName` loop of the original).
  var i = 0
  while i < s.len:
    var j = i
    while j < s.len and s[j] notin delims: inc j
    let a = skipWhiteSpace(s, i, j)
    let b = unskipWhiteSpace(s, j, a)
    if a < j and b > a: result.add s[a ..< b]
    i = j + 1

func parseCss*(content: string): seq[CssRule] =
  ## Rules of an internal style sheet, in source order. Parsing stops at the first rule
  ## the tokenizer cannot read (like the original loop).
  var pos = 0
  var tag, name, attrs: string
  while xmlParseCssAttribute(content, pos, tag, name, attrs):
    result.add CssRule(tag: tag, name: name, attrs: attrs)

func selectorNames*(rule: CssRule): seq[string] =
  ## Class names of a `.a, .b` selector list (leading dot removed), as used for
  ## `tag == "all"` rules.
  for id in splitNames(rule.name, {','}):
    result.add (if id[0] == '.': id[1 .. ^1] else: id)

func classNames*(classString: string): seq[string] =
  ## Distinct class names of a `class="a b a"` attribute, in first-seen order.
  for n in splitNames(classString, {' '}):
    if n notin result: result.add n

func fontFaceRule*(rule: CssRule): bool = rule.tag == "@font-face"
