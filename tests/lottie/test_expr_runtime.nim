import std/[math, options]
import ../../src/thorvg/lottie/expr/[val, boundary, runtime]

var pass = 0
var fail = 0

template check(name: string; cond: bool) =
  if cond: inc pass
  else:
    inc fail
    echo "FAIL ", name

proc nearly(a,b: float64): bool =
  if a != a and b != b: return true
  abs(a-b) <= 1e-9 + 4e-7*abs(b)

proc checkNum(name: string; v: Val; e: float64) =
  check(name & " isNum", v.kind == vkNum)
  if v.kind == vkNum: check(name & " val", nearly(v.num, e))

proc checkVec2(name: string; v: Val; x,y: float64) =
  check(name & " isArr", v.kind == vkArray and v.items.len == 2)
  if v.kind == vkArray and v.items.len == 2:
    check(name & ".x.kind", v.items[0].kind == vkNum)
    check(name & ".y.kind", v.items[1].kind == vkNum)
    if v.items[0].kind == vkNum: check(name & ".x", nearly(v.items[0].num, x))
    if v.items[1].kind == vkNum: check(name & ".y", nearly(v.items[1].num, y))

# Oracle-confirmed $bm_* semantics (ThorVG _addsub/_muldiv/_mod)
checkVec2("sum_vv", bmSum(vArray(@[vNum(1), vNum(2)]), vArray(@[vNum(3), vNum(4)])), 4, 6)
checkVec2("sum_vs_scalar_to_x", bmSum(vArray(@[vNum(1), vNum(2)]), vNum(5)), 6, 2)
checkVec2("sum_sv_scalar_to_x", bmSum(vNum(5), vArray(@[vNum(1), vNum(2)])), 6, 2)
checkVec2("sum_mismatch_no_reuse", bmSum(vArray(@[vNum(1), vNum(2)]), vArray(@[vNum(1)])), 2, 2)
checkNum("sum_1d1d", bmSum(vNum(3), vNum(4)), 7)

checkVec2("sub_vv", bmSub(vArray(@[vNum(5), vNum(6)]), vArray(@[vNum(1), vNum(2)])), 4, 4)
checkVec2("sub_vs", bmSub(vArray(@[vNum(5), vNum(6)]), vNum(1)), 4, 6)
checkVec2("sub_sv", bmSub(vNum(10), vArray(@[vNum(1), vNum(2)])), 9, 2)

checkVec2("mul_vv_scalar2nd", bmMul(vArray(@[vNum(1), vNum(2)]), vArray(@[vNum(3), vNum(4)])), 3, 6)
checkVec2("mul_vs", bmMul(vArray(@[vNum(1), vNum(2)]), vNum(3)), 3, 6)

checkVec2("div_vs", bmDiv(vArray(@[vNum(10), vNum(20)]), vNum(2)), 5, 10)
checkNum("div_sv_scalar", bmDiv(vNum(10), vArray(@[vNum(2), vNum(5)])), 5) # 2nd arg scalar index0

checkNum("mod_ss", bmMod(vNum(10), vNum(3)), 1)
checkNum("mod_vs", bmMod(vArray(@[vNum(10), vNum(20)]), vNum(3)), 1)

# boundary interaction: scalar result on vec2 prop -> zeros (observed)
let divSvOnVec = toPropVec(bmDiv(vNum(10), vArray(@[vNum(2), vNum(5)])), 2)
check("div_sv_on_vec2 some", divSvOnVec.isSome)
if divSvOnVec.isSome:
  check("div_sv_on_vec2 x", nearly(divSvOnVec.get()[0], 0.0))
  check("div_sv_on_vec2 y", nearly(divSvOnVec.get()[1], 0.0))

echo "pass=", pass, " fail=", fail
if fail > 0: quit(1)
