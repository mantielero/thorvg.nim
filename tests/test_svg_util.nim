import std/unittest
import thorvg/core/[types, geom]
import thorvg/loaders/svg/[util, color]

proc near(a, b: float32, eps = 1e-3'f32): bool = abs(a - b) <= eps

proc transform(s: string): (bool, Matrix) =
  var m: Matrix
  let ok = parseTransform(s, m)
  (ok, m)

proc rgb(s: string): (bool, uint8, uint8, uint8) =
  var c = RGBA(a: 255)
  let ok = toColor(s, c)
  (ok, c.r, c.g, c.b)

suite "util whitespace and urls":
  test "skip and unskip":
    let s = "  ab  "
    check skipWhiteSpace(s, 0) == 2
    check skipWhiteSpace(s, 0, 1) == 1
    check skipWhiteSpace("   ", 0) == 3
    check unskipWhiteSpace(s, 6, 2) == 4
    check unskipWhiteSpace(s, 2, 2) == 2
    check unskipWhiteSpace("   ", 3, 0) == 1 # keeps one blank, like the original
    check skipWhiteSpaceAndComma(" , x", 0) == 2
    check skipWhiteSpaceAndComma(" x", 0) == 1

  test "url decode":
    check urlDecode("a%20b+c") == "a b c"
    check urlDecode("%41%2f") == "A/"
    check urlDecode("100%zz%4") == "100%zz%4"
    check urlDecode("") == ""

  test "id from url":
    check idFromUrl("(#grad)") == "grad"
    check idFromUrl("( '#a' )") == "a"
    check idFromUrl("(#id )") == "id"
    check idFromUrl("(#a b)") == ""
    check idFromUrl("(foo)") == ""
    check idFromUrl("#a)") == ""
    check idFromUrl(")#a(") == ""

suite "util hsl":
  test "primary colors":
    var r, g, b: uint8
    hslToRgb(0, 1, 0.5, r, g, b)
    check (r, g, b) == (255'u8, 0'u8, 0'u8)
    hslToRgb(120, 1, 0.5, r, g, b)
    check (r, g, b) == (0'u8, 255'u8, 0'u8)
    hslToRgb(240, 1, 0.5, r, g, b)
    check (r, g, b) == (0'u8, 0'u8, 255'u8)
    hslToRgb(360, 1, 0.5, r, g, b)
    check (r, g, b) == (255'u8, 0'u8, 0'u8)
    hslToRgb(-120, 1, 0.5, r, g, b)
    check (r, g, b) == (0'u8, 0'u8, 255'u8)

  test "gray when saturation is zero, ties to even":
    var r, g, b: uint8
    hslToRgb(10, 0, 0.5, r, g, b)
    check (r, g, b) == (128'u8, 128'u8, 128'u8)
    hslToRgb(10, 0, 1, r, g, b)
    check (r, g, b) == (255'u8, 255'u8, 255'u8)

suite "util numbers":
  test "numbers list":
    var pos = 0
    var pts: array[4, float32]
    check parseNumbersArray("10-5.5.5 7", pos, pts) == 4
    check pts == [10.0'f32, -5.5'f32, 0.5'f32, 7.0'f32]
    pos = 0
    check parseNumbersArray("1, 2 )", pos, pts) == 2
    check pos == 5
    pos = 0
    check parseNumbersArray("x", pos, pts) == 0

suite "util transform":
  test "single transforms":
    let (ok1, t) = transform("translate(10 20)")
    check ok1
    check (t.e11, t.e12, t.e13, t.e21, t.e22, t.e23) == (1.0'f32, 0.0'f32, 10.0'f32, 0.0'f32, 1.0'f32, 20.0'f32)
    check transform("translate(10)")[1].e23 == 0.0'f32
    let s = transform("scale(2)")[1]
    check (s.e11, s.e22) == (2.0'f32, 2.0'f32)
    let s2 = transform("scale(2, 3)")[1]
    check (s2.e11, s2.e22) == (2.0'f32, 3.0'f32)
    let m = transform("matrix(1 2 3 4 5 6)")[1]
    check (m.e11, m.e12, m.e13, m.e21, m.e22, m.e23) == (1.0'f32, 3.0'f32, 5.0'f32, 2.0'f32, 4.0'f32, 6.0'f32)

  test "rotate and skew":
    let r = transform("rotate(90)")[1]
    check near(r.e11, 0) and near(r.e12, -1) and near(r.e21, 1) and near(r.e22, 0)
    let c = transform("rotate(90 10 10)")[1]
    check pt(10, 10) * c == pt(10, 10)
    let q = pt(20, 10) * c
    check near(q.x, 10) and near(q.y, 20)
    check near(transform("skewX(45)")[1].e12, 1)
    check near(transform("skewY(45)")[1].e21, 1)
    let neg = transform("rotate(-90)")[1]
    check near(neg.e12, 1) and near(neg.e21, -1)

  test "list order and separators":
    let m = transform("translate(10,20) scale(2)")[1]
    let p = pt(1, 1) * m
    check near(p.x, 12) and near(p.y, 22)
    let n = transform("  translate(1 1),scale(3)rotate(0)")
    check n[0]
    check near(n[1].e11, 3) and near(n[1].e13, 1)
    check transform("")[0]
    check transform("")[1] == identity()

  test "errors":
    check not transform("foo(1)")[0]
    check not transform("translate(1")[0]
    check not transform("translate(1 2 3)")[0]
    check not transform("scale()")[0]
    check not transform("matrix(1 2 3)")[0]
    check not transform("rotate(1 2)")[0]
    check not transform("skewX(1 2)")[0]
    check not transform("translate 1")[0]

suite "util lengths":
  test "units":
    check toLength("10", LengthKind.Horizontal, 200, 100, 10) == 10.0'f32
    check toLength("10px", LengthKind.Horizontal, 200, 100, 10) == 10.0'f32
    check near(toLength("1in", LengthKind.Other, 0, 0, 10), 96)
    check near(toLength("2.54cm", LengthKind.Other, 0, 0, 10), 96, 0.01)
    check near(toLength("10mm", LengthKind.Other, 0, 0, 10), 37.79528, 0.01)
    check near(toLength("12pt", LengthKind.Other, 0, 0, 10), 16, 0.01)
    check near(toLength("1pc", LengthKind.Other, 0, 0, 10), 16)
    check near(toLength("2em", LengthKind.Other, 0, 0, 12), 24)
    check near(toLength("2ex", LengthKind.Other, 0, 0, 12), 12)
    check near(toLength("1e2", LengthKind.Other, 0, 0, 12), 100)
    check near(toLength("-1.5e1pt", LengthKind.Other, 0, 0, 12), -20, 0.01)

  test "percentages":
    check near(toLength("50%", LengthKind.Horizontal, 200, 100, 10), 100)
    check near(toLength("50%", LengthKind.Vertical, 200, 100, 10), 50)
    check near(toLength("50%", LengthKind.Other, 200, 100, 10), 100)
    check near(toLength("50%", LengthKind.Diagonal, 200, 100, 10), 79.0569, 0.01)
    check near(toLength("5 %", LengthKind.Horizontal, 200, 100, 10), 10)

  test "font size and gradient values":
    check toFontSize("-4", 10) == 0.0'f32
    check near(toFontSize("2em", 12), 24)
    check near(toFontSize("150%", 12), 18)
    var pct = false
    check near(gradientToFloat("25%", 10, pct), 0.25)
    check pct
    check near(gradientToFloat("3", 10, pct), 3)
    check not pct

  test "offset":
    check toOffset("0.5") == 0.5'f32
    check near(toOffset("50%"), 0.5)
    check near(toOffset("50 %"), 0.5)
    check toOffset("abc") == 0.0'f32
    check toOffset("1x") == 0.0'f32
    check toOffset("50%x") == 0.0'f32

  test "opacity":
    check toOpacity("0.5") == 128
    check toOpacity("50%") == 128
    check toOpacity("1") == 255
    check toOpacity("0") == 0
    check toOpacity("abc") == 255
    check toOpacity("0.5x") == 255

  test "dash array":
    var d: seq[float32]
    check parseDashArray("5,3 2", 100, 100, d)
    check d == @[5.0'f32, 3.0'f32, 2.0'f32]
    check parseDashArray("none", 100, 100, d)
    check d.len == 0
    check not parseDashArray("-1 2", 100, 100, d)
    check d.len == 0
    check not parseDashArray("abc", 100, 100, d)
    check parseDashArray("10%", 200, 100, d)
    check near(d[0], 15.8114, 0.01)

suite "color":
  test "hex":
    check rgb("#f00") == (true, 255'u8, 0'u8, 0'u8)
    check rgb("#0A1b2C") == (true, 10'u8, 27'u8, 44'u8)
    check not rgb("#12")[0]
    check not rgb("#12345g")[0]

  test "rgb and rgba":
    check rgb("rgb(10, 20, 30)") == (true, 10'u8, 20'u8, 30'u8)
    check rgb("RGB(1,2,3)") == (true, 1'u8, 2'u8, 3'u8)
    check rgb("rgb(100%, 0%, 50%)") == (true, 255'u8, 0'u8, 128'u8)
    check not rgb("rgb(300,0,0)")[0]
    check not rgb("rgb(1,2)")[0]
    check not rgb("rgb(1,2,3,4)")[0]
    var c = RGBA(a: 255)
    check toColor("rgba(1, 2, 3, 0.5)", c)
    check (c.r, c.g, c.b, c.a) == (1'u8, 2'u8, 3'u8, 128'u8)
    check not toColor("rgba(1, 2, 3, 2)", c)

  test "hsl":
    check rgb("hsl(120, 100%, 50%)") == (true, 0'u8, 255'u8, 0'u8)
    check rgb("hsl(0 100% 50%)") == (true, 255'u8, 0'u8, 0'u8)
    check not rgb("hsl(120, 100, 50%)")[0]
    check not rgb("hsl(120, 100%, 50%")[0]

  test "named colors, case-insensitive":
    check rgb("red") == (true, 255'u8, 0'u8, 0'u8)
    check rgb("RebeccaPurple")[0] == false
    check rgb("AliceBlue") == (true, 0xf0'u8, 0xf8'u8, 0xff'u8)
    check rgb("yellowgreen") == (true, 0x9a'u8, 0xcd'u8, 0x32'u8)
    check rgb("tan") == (true, 0xd2'u8, 0xb4'u8, 0x8c'u8)
    check rgb("white") == (true, 255'u8, 255'u8, 255'u8)
    check not rgb("notacolor")[0]
    check not rgb("")[0]

  test "every named color is found (table is sorted)":
    for name in ["aqua", "black", "crimson", "darkgrey", "gold", "grey", "lime", "navy",
                 "orange", "plum", "silver", "teal", "violet", "whitesmoke"]:
      check rgb(name)[0]

  test "url references":
    var c = RGBA(a: 255)
    var url = ""
    check toColor("url(#grad)", c, url)
    check url == "grad"
    check toColor("#fff", c, url)
    check not toColor("url(#grad)", c)
