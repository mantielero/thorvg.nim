import std/[json, strutils, sets]
import thorvg/lottie/parser/parser
import thorvg/lottie/model/[model, common, property]

proc fail(msg: string) =
  stderr.writeLine("FAIL: " & msg)
  quit(1)

proc assertEq[T](a, b: T; msg: string) =
  if a != b: fail(msg & " expected=" & $b & " got=" & $a)

proc assertTrue(v: bool; msg: string) =
  if not v: fail(msg)

# --- parse test3 ---
let t3 = parseLottieFile(readFile("upstream/test/res/test3.lot"))
assertEq(t3.fonts.len, 1, "test3 fonts")
assertEq(t3.fonts[0].name, "Helvetica", "test3 font name")
assertEq(t3.fonts[0].family, "Helvetica", "test3 font family")
assertEq(t3.fonts[0].style, "Regular", "test3 font style")
assertTrue(abs(t3.fonts[0].ascent - 71.8994140625'f32) < 0.001'f32, "test3 font ascent")
assertEq(t3.fonts[0].chars.len, 6, "test3 font chars associated by family+style")

# text layer
var t3text: LottieTextObj = nil
for l in t3.layers:
  if l.layerType == ltText and l.children.len > 0 and l.children[0].objType == otText:
    t3text = LottieTextObj(l.children[0])
if t3text == nil: fail("test3 text object not found")
let doc = t3text.doc.eval(0.0'f32)
assertEq(doc.name, "Helvetica", "test3 doc.f")
assertEq(doc.text, "ThorVG", "test3 doc.t")
assertTrue(abs(doc.size - 200.0'f32) < 0.001'f32, "test3 doc.s")
assertTrue(abs(doc.justify - 0.0'f32) < 0.001'f32, "test3 doc.j")
assertEq(doc.caps, uint8(0), "test3 doc.ca")
assertTrue(abs(doc.tracking - 0.0'f32) < 0.001'f32, "test3 doc.tr")
assertTrue(abs(doc.height - 240.000015258789'f32) < 0.01'f32, "test3 doc.lh")
assertTrue(abs(doc.shift - 0.0'f32) < 0.001'f32, "test3 doc.ls")
assertTrue(abs(doc.color.r - 0.991'f32) < 0.001'f32, "test3 doc.fc.r")
assertTrue(abs(doc.color.g - 0.407'f32) < 0.001'f32, "test3 doc.fc.g")
assertTrue(abs(doc.color.b - 0.016'f32) < 0.001'f32, "test3 doc.fc.b")
# t.d keyframes are hold - static/single keyframe is acceptable
assertTrue(t3text.doc.hasFrames or t3text.doc.frames.len == 0, "test3 doc parsed")
# follow path
assertTrue(t3text.followPath != nil, "test3 followPath")
assertEq(t3text.followPath.mask, 0, "test3 p.m")
assertTrue(t3text.followPath.firstMargin.hasFrames, "test3 p.f animated")
assertEq(t3text.followPath.pathLength, 0.0'f32, "test3 p.l")
assertEq(t3text.followPath.forceAlignment, false, "test3 p.a")
assertEq(t3text.followPath.perpendicular, true, "test3 p.p perpendicular")
assertEq(t3text.followPath.reversePath, false, "test3 p.r reverse")
# align/grouping
assertEq(t3text.alignGroup, 1, "test3 m.g")
assertEq(t3text.ranges.len, 0, "test3 ranges")

# hold keyframe test: create synthetic animated t.d with 2 keyframes, ensure no interpolation
block:
  let j = parseJson("""{"v":"5.5.2","fr":30,"ip":0,"op":10,"w":10,"h":10,"fonts":{"list":[{"fName":"F","fFamily":"F","fStyle":"R","ascent":70}]},"chars":[],"layers":[{"ty":5,"nm":"t","ip":0,"op":10,"st":0,"ks":{},"t":{"d":{"k":[{"t":0,"s":{"s":10,"f":"F","t":"A","j":0,"tr":0,"lh":12,"ls":0,"fc":[1,0,0]}},{"t":5,"s":{"s":10,"f":"F","t":"B","j":0,"tr":0,"lh":12,"ls":0,"fc":[0,1,0]}}]},"p":{},"m":{"g":1,"a":{"a":0,"k":[0,0]}},"a":[]}}]}""")
  let c = parseComposition(j)
  var txt: LottieTextObj = nil
  for l in c.layers:
    if l.layerType == ltText and l.children.len > 0: txt = LottieTextObj(l.children[0])
  assertTrue(txt != nil, "hold text obj")
  assertTrue(txt.doc.hasFrames, "hold hasFrames")
  # at frame 2.5 (between 0 and 5) must stay at first keyframe value, not interpolate to "B"
  let dmid = txt.doc.eval(2.5'f32)
  assertEq(dmid.text, "A", "hold t.d no interpolation")
  let d5 = txt.doc.eval(5.0'f32)
  assertEq(d5.text, "B", "hold t.d at keyframe")

# --- parse test8 ---
let t8 = parseLottieFile(readFile("upstream/test/res/test8.lot"))
assertEq(t8.fonts.len, 1, "test8 fonts")
assertEq(t8.fonts[0].chars.len, 24, "test8 chars associated")
var t8tri: LottieTextObj = nil
var t8plain: LottieTextObj = nil
for l in t8.layers:
  if l.layerType == ltText and l.children.len > 0 and l.children[0].objType == otText:
    let to = LottieTextObj(l.children[0])
    if to.ranges.len > 0: t8tri = to else: t8plain = to
assertTrue(t8tri != nil, "test8 range layer")
assertTrue(t8plain != nil, "test8 plain layer")
assertEq(t8tri.ranges.len, 1, "test8 range count")
let r = t8tri.ranges[0]
assertEq(r.selector.shape, 4, "test8 range shape triangle")
assertEq(r.selector.based, 1, "test8 range based chars")
assertTrue(abs(r.selector.start.eval(0.0'f32) - 0.0'f32) < 0.001'f32, "test8 range start")
assertTrue(r.selector.endProp.hasFrames, "test8 range end animated")
let rs = r.style.scaleProp.eval(0.0'f32)
assertTrue(abs(rs.x - 40.0'f32) < 0.001'f32, "test8 range scale x")
assertTrue(abs(rs.y - 40.0'f32) < 0.001'f32, "test8 range scale y")

# unknown field warning counted (structured, not silent)
block:
  let j = parseJson("""{"v":"5.5.2","fr":30,"ip":0,"op":10,"w":10,"h":10,"fonts":{"list":[{"fName":"F","fFamily":"F","fStyle":"R","ascent":70,"mysteryFont":1}]},"chars":[],"layers":[{"ty":5,"nm":"t","ip":0,"op":10,"st":0,"ks":{},"t":{"d":{"k":[{"t":0,"s":{"s":10,"f":"F","t":"A","j":0,"tr":0,"lh":12,"ls":0,"fc":[1,0,0],"mysteryDoc":1}}]},"p":{"mysteryP":1},"m":{"g":1,"a":{"a":0,"k":[0,0]},"mysteryM":1},"a":[{"nm":"r","s":{"t":0,"xe":{"a":0,"k":0},"ne":{"a":0,"k":0},"a":{"a":0,"k":100},"b":1,"rn":0,"sh":1,"e":{"a":0,"k":100},"r":1,"mysterySel":1},"a":{"mysteryA":1}}],"mysteryT":1}}]}""")
  let c = parseComposition(j)
  var unknownCount = 0
  for w in c.warnings:
    if w.contains("unknown field"):
      inc unknownCount
  assertTrue(unknownCount >= 6, "unknown fields produce structured warnings")

# followPath r/a/l: parsed but not applied in C++ 1.2.0 -> counted warning, not silent
block:
  let j = parseJson("""{"v":"5.5.2","fr":30,"ip":0,"op":10,"w":10,"h":10,"fonts":{"list":[{"fName":"F","fFamily":"F","fStyle":"R","ascent":70}]},"chars":[],"layers":[{"ty":5,"nm":"t","ip":0,"op":10,"st":0,"ks":{},"t":{"d":{"k":[{"t":0,"s":{"s":10,"f":"F","t":"A","j":0,"tr":0,"lh":12,"ls":0,"fc":[1,0,0]}}]},"p":{"m":0,"f":{"a":0,"k":0},"l":{"a":0,"k":0},"a":{"a":0,"k":1},"p":{"a":0,"k":1},"r":{"a":0,"k":1}},"m":{"g":1,"a":{"a":0,"k":[0,0]}},"a":[]}}]}""")
  let c = parseComposition(j)
  var gotR, gotA, gotL = false
  for w in c.warnings:
    if w.contains("field 'r'") and w.contains("WARNING_CONTADO"): gotR = true
    if w.contains("field 'a'") and w.contains("WARNING_CONTADO"): gotA = true
    if w.contains("field 'l'") and w.contains("WARNING_CONTADO"): gotL = true
  assertTrue(gotR, "followPath r warning contado")
  assertTrue(gotA, "followPath a warning contado")
  assertTrue(gotL, "followPath l warning contado")

# test3 also contains r/a/l in followPath; warnings must be present, not silent
block:
  let c = parseLottieFile(readFile("upstream/test/res/test3.lot"))
  var gotRAL = 0
  for w in c.warnings:
    if w.contains("WARNING_CONTADO") and (w.contains("field 'r'") or w.contains("field 'a'") or w.contains("field 'l'")):
      inc gotRAL
  assertTrue(gotRAL >= 3, "test3 followPath r/a/l warnings contados")

# coverage: no unknown-field warning in test3/test8 text/font/char paths
for name in ["test3", "test8"]:
  let c = parseLottieFile(readFile("upstream/test/res/" & name & ".lot"))
  for w in c.warnings:
    if w.contains("unknown field"):
      fail(name & " unexpected unknown: " & w)

echo "ok"
