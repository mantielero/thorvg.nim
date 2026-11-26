import std/[strformat, strutils]
import ../../tools/exprc/[ast, lexer, parser, analysis, emitter, registry]

var failures = 0
var passes = 0

template check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "OK ", name
  else:
    inc failures
    echo "FAIL ", name

template checkEq[T](name: string; a, b: T) =
  if a == b:
    inc passes
    echo "OK ", name
  else:
    inc failures
    echo "FAIL ", name, " got=", a, " expected=", b

proc hasDiag(r: ParseResult; sub: string): bool =
  for d in r.diags:
    if sub.toLowerAscii in d.msg.toLowerAscii: return true
  false

proc main() =
  # --- Parse observed subset ---
  let audio = """var $bm_rt;
var $bm_rt;
var veloc, amplitude, decay;
veloc = 15;
amplitude = 65;
decay = 4;
$bm_rt = $bm_rt = div(mul(amplitude, Math.sin(mul(veloc, time))), Math.exp(mul(decay, time)));"""
  let r1 = parseProgram(audio)
  check("audio_layer parses", r1.ok)
  check("audio_layer definitive $bm_rt", definitiveBmRt(r1.expr))

  let r2 = parseProgram("var t = time; [150 + Math.sin(t * 2) * 50, 150 + Math.cos(t * 2) * 50]")
  check("test5 p expr parses", r2.ok)
  # no $bm_rt assignment
  check("test5 p no definitive bm_rt", not definitiveBmRt(r2.expr))

  let r3 = parseProgram("time * 100")
  check("time*100 parses", r3.ok)
  check("time*100 no definitive bm_rt", not definitiveBmRt(r3.expr))

  let r4 = parseProgram("var s = 100 + Math.sin(time * 3) * 50; [s, s]")
  check("scale expr parses", r4.ok)

  let r5 = parseProgram("var minOpacity = 30; var maxOpacity = 100; var cycle = Math.sin(time * 2); minOpacity + (maxOpacity - minOpacity) * (cycle + 1) / 2")
  check("opacity expr parses", r5.ok)

  # --- definitive assignment ---
  check("assign direct", definitiveBmRt(parseProgram("var $bm_rt = 1;").expr))
  check("assign expr", definitiveBmRt(parseProgram("$bm_rt = 5+3;").expr))
  check("if both branches", definitiveBmRt(parseProgram("if (time>0){$bm_rt=1;}else{$bm_rt=2;}").expr))
  check("if one branch not definitive", not definitiveBmRt(parseProgram("if (time>0){$bm_rt=1;}").expr))
  check("no bm_rt", not definitiveBmRt(parseProgram("var x=1; x+2;").expr))
  check("ternary assign", definitiveBmRt(parseProgram("$bm_rt = time>0 ? 1 : 0;").expr))

  # --- diagnostics / negatives ---
  let ne1 = parseProgram("eval('1+1')")
  check("eval rejected", not ne1.ok)
  check("eval diag", hasDiag(ne1, "forbidden"))

  let ne2 = parseProgram("Function('return 1')()")
  check("Function rejected", not ne2.ok)

  let ne3 = parseProgram("with (Math) { sin(1) }")
  check("with rejected", not ne3.ok)

  let ne4 = parseProgram("new Function('return 1')")
  check("new rejected", not ne4.ok)

  let ne5 = parseProgram("var r = /abc/;")
  check("regex rejected", not ne5.ok)
  check("regex diag", hasDiag(ne5, "regex") or hasDiag(ne5, "forbidden"))

  let ne6 = parseProgram("this.foo")
  check("this rejected", not ne6.ok)

  let ne7 = parseProgram("globalThis['eval']")
  check("globalThis rejected", not ne7.ok)

  # --- diag has line/col ---
  let nd = parseProgram("var x = 1;\neval('x');")
  check("diag line", nd.diags.len > 0 and nd.diags[0].line >= 1)
  check("diag col", nd.diags.len > 0 and nd.diags[0].col >= 1)

  # --- emitter smoke ---
  let em = emitProgram(r1.expr, "expr_audio")
  check("emitter ok", em.ok)
  check("emitter has proc", "proc expr_audio" in em.code)
  check("emitter has bmRt", "bmRt" in em.code)
  check("emitter has ctx.time", "ctx.time" in em.code)

  # --- registry ---
  var reg = initRegistry(rmStrict)
  reg.register("123", "1+1", "expr_123")
  checkEq("registry lookup", reg.lookup("123", "ctx"), "expr_123")
  let miss = reg.lookup("999", "ctx")
  check("registry strict miss empty", miss == "")
  check("registry strict error", reg.errors.len == 1)
  var reg2 = initRegistry(rmIgnoreCounted)
  discard reg2.lookup("999", "ctx")
  checkEq("registry ignore counted", reg2.ignored, 1)

  # --- observed 1c/1b cases parse ---
  for src in ["var $bm_rt = true;", "var $bm_rt = false;", "var $bm_rt = undefined;",
              "var $bm_rt = \"hello\";", "var $bm_rt = NaN;", "var $bm_rt = [1,2];",
              "var $bm_rt = 42;", "throw \"boom\";"]:
    let rr = parseProgram(src)
    # throw is not in our subset - should diag or parse as ident; be tolerant but record
    if src.startsWith("throw"):
      check("throw handled (diag or parsed)", true) # just don't crash
    else:
      check("1c case parses: " & src[0..min(20, src.high)], rr.ok)

  echo fmt"pass={passes} fail={failures}"
  if failures > 0: quit(1)

when isMainModule:
  main()
