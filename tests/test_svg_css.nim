import std/unittest
import thorvg/loaders/svg/[css, xml]

suite "css rules":
  test "tag, class and tag.class selectors":
    let rules = parseCss(" rect {fill:red} .c1{stroke:blue}  circle.c2 { r : 3 } ")
    check rules.len == 3
    check rules[0] == CssRule(tag: "rect", name: "", attrs: "fill:red")
    check rules[1] == CssRule(tag: "all", name: "c1", attrs: "stroke:blue")
    check rules[2] == CssRule(tag: "circle", name: "c2", attrs: " r : 3 ")

  test "declarations of a rule go through the W3C attribute parser":
    let rules = parseCss(".a { fill: #fff; stroke-width: 2 }")
    var got: seq[(string, string)]
    check xmlParseW3CAttribute(rules[0].attrs, proc(k, v: string): bool =
      got.add (k, v)
      true)
    check got == @[("fill", "#fff"), ("stroke-width", "2")]

  test "stops at the first unreadable rule":
    check parseCss("a {x:1} b. {y:2} c {z:3}").len == 1
    check parseCss("a {x:1").len == 0
    check parseCss("").len == 0
    check parseCss("   ").len == 0

  test "at-rules":
    let rules = parseCss("@font-face { font-family: X; src: url(a) } g {x:1}")
    check rules.len == 2
    check rules[0].fontFaceRule
    check not rules[1].fontFaceRule

suite "css names":
  test "selector lists":
    let rule = parseCss(".a, .b ,c {x:1}")[0]
    check rule.tag == "all"
    check rule.selectorNames == @["a", "b", "c"]

  test "splitNames trims and drops empty tokens":
    check splitNames(" a ,, b ,  ", {','}) == @["a", "b"]
    check splitNames("", {' '}).len == 0
    check splitNames("   ", {' '}).len == 0
    check splitNames("x", {' '}) == @["x"]

  test "class lists keep first occurrence only":
    check classNames("a  b a\tc") == @["a", "b", "a\tc"]
    check classNames("a  b a c") == @["a", "b", "c"]
    check classNames("").len == 0
