import std/unittest
import thorvg/loaders/svg/xml

proc attrs(buf: string): (bool, seq[(string, string)]) =
  var got: seq[(string, string)]
  let ok = xmlParseAttributes(buf, proc(k, v: string): bool =
    got.add (k, v)
    true)
  (ok, got)

proc w3c(buf: string): seq[(string, string)] =
  var got: seq[(string, string)]
  discard xmlParseW3CAttribute(buf, proc(k, v: string): bool =
    got.add (k, v)
    true)
  got

proc tokens(buf: string, strip: bool, textOpen = false): (bool, seq[(XmlType, string)]) =
  var got: seq[(XmlType, string)]
  let ok = xmlParse(buf, strip, proc(t: XmlType, c: string): bool =
    got.add (t, c)
    true, proc(): bool = textOpen)
  (ok, got)

suite "xml attributes":
  test "quotes, bare values and spacing":
    let (ok, got) = attrs("a=\"1\" b='two' c=3  d = \"x\"")
    check ok
    check got == @[("a", "1"), ("b", "two"), ("c", "3"), ("d", "x")]

  test "entities are decoded":
    let (ok, got) = attrs("t=\"a &amp; b &lt;c&gt; &quot;q&quot; &apos;s&apos;\" n='&#10;x'")
    check ok
    check got[0][1] == "a & b <c> \"q\" 's'"
    check got[1][1] == "x" # the decoded newline is trimmed like blanks
    check attrs("e=\"&unknown; &#10;\"")[1][0][1] == "&unknown;"

  test "values are trimmed, '>' allowed inside quotes":
    check attrs("p=\"  M0 0 L1 1  \"")[1] == @[("p", "M0 0 L1 1")]
    check attrs("t=\"a>b\"")[1] == @[("t", "a>b")]

  test "malformed input":
    check not attrs("a=\"1")[0]
    check not attrs("a")[0]
    check not attrs("a=")[0]
    check attrs("")[0]
    check attrs("   ")[0]
    check attrs("=x a=\"1\"")[1] == @[("x", "1")] # quirk: key and value pair up across blanks

suite "xml tokens":
  test "document with every markup kind":
    let src = "<?xml version=\"1.0\"?><!DOCTYPE svg><!-- hi --><svg a=\"b\"><g/>" &
      "<![CDATA[x<y]]>text &amp; more</svg>"
    let (ok, got) = tokens(src, true)
    check ok
    check got == @[
      (XmlType.Processing, "xml version=\"1.0\""), (XmlType.Doctype, "svg"),
      (XmlType.Comment, "hi"), (XmlType.Open, "svg a=\"b\""), (XmlType.OpenEmpty, "g"),
      (XmlType.CData, "x<y"), (XmlType.Data, "text & more"), (XmlType.Close, "svg")]

  test "doctype with internal subset":
    let (ok, got) = tokens("<!DOCTYPE svg [<!ENTITY a \"b\">]><svg/>", false)
    check ok
    check got[0][0] == XmlType.Doctype
    check got[^1] == (XmlType.OpenEmpty, "svg")

  test "no strip keeps blanks, strip reports them as Ignored":
    let (ok1, raw) = tokens("<a> <b/> </a>", false)
    check ok1
    check raw == @[(XmlType.Open, "a"), (XmlType.Data, " "), (XmlType.OpenEmpty, "b"),
                   (XmlType.Data, " "), (XmlType.Close, "a")]
    let (ok2, stripped) = tokens("<a> <b/> </a>", true)
    check ok2
    check stripped == @[(XmlType.Open, "a"), (XmlType.Ignored, " "),
                        (XmlType.OpenEmpty, "b"), (XmlType.Ignored, " "),
                        (XmlType.Close, "a")]

  test "text elements keep their blanks while open":
    let (ok, got) = tokens("  hi there  ", true, textOpen = true)
    check ok
    check got == @[(XmlType.Data, "  hi there  ")]
    let (_, trimmed) = tokens("  hi there  ", true)
    check trimmed == @[(XmlType.Ignored, "  "), (XmlType.Data, "hi there"),
                       (XmlType.Ignored, "  ")]

  test "quoted '>' does not end a tag":
    let (ok, got) = tokens("<a b=\"x>y\" c='<'/>", false)
    check ok
    check got == @[(XmlType.OpenEmpty, "a b=\"x>y\" c='<'")]

  test "comments and cdata may contain markup characters":
    let (ok, got) = tokens("<!-- <a> --><![CDATA[<b>]]>", false)
    check ok
    check got == @[(XmlType.Comment, " <a> "), (XmlType.CData, "<b>")]

  test "errors":
    check not tokens("<a", false)[0]
    check not tokens("<a <b>", false)[0]
    check not tokens("<", false)[0]
    check not tokens("<!-- never closed", false)[0]
    check not xmlParse("<a/>", false, proc(t: XmlType, c: string): bool = false)

suite "xml w3c attributes":
  test "declarations":
    check w3c("fill:red; stroke : blue ;opacity:.5") ==
      @[("fill", "red"), ("stroke", "blue"), ("opacity", ".5")]
    check w3c("a:b;") == @[("a", "b")]
    check w3c("") == newSeq[(string, string)]()

  test "font-face src with an embedded semicolon":
    check w3c("src: url(data:font/ttf;base64,AAA); fill:red") ==
      @[("src", "url(data:font/ttf;base64,AAA)"), ("fill", "red")]

  test "key without value":
    check w3c("hidden; a:b") == @[("hidden", ""), ("a", "b")]

suite "xml css and tag helpers":
  test "css rule forms":
    var pos = 0
    var tag, name, a: string
    let css = " rect {x:1} .c1{y:2}  circle.c2 { r : 3 } "
    check xmlParseCssAttribute(css, pos, tag, name, a)
    check (tag, name, a) == ("rect", "", "x:1")
    check xmlParseCssAttribute(css, pos, tag, name, a)
    check (tag, name, a) == ("all", "c1", "y:2")
    check xmlParseCssAttribute(css, pos, tag, name, a)
    check (tag, name, a) == ("circle", "c2", " r : 3 ")
    check not xmlParseCssAttribute(css, pos, tag, name, a)

  test "css invalid rules":
    var pos = 0
    var tag, name, a: string
    check not xmlParseCssAttribute("a. {x:1}", pos, tag, name, a)
    pos = 0
    check not xmlParseCssAttribute("a {x:1", pos, tag, name, a)
    pos = 0
    check not xmlParseCssAttribute("{x:1}", pos, tag, name, a)

  test "xmlFindAttributesTag":
    check xmlFindAttributesTag("rect x=\"1\"") == 4
    check xmlFindAttributesTag("rect") == 4
    check xmlFindAttributesTag("x=\"1\" y=\"2\"") == 0
    check xmlFindAttributesTag("") == 0
