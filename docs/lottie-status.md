# Lottie status

## Phase 0 - Corpus y harness de comparación
- Estado: **completada**
- Harness C++: `tests/lottie/harness/dump_lottie.cpp` (build ThorVG C++ en `/tmp/opencode/thorvg-lottie-build`, `-Dloaders=lottie -Dextra=lottie_exp`).
- Goldens: `tests/lottie/golden/` (19 casos x 5 frames): RGBA, PPM, `*.props.json`, `manifest.json`.
- Comparador: `tests/lottie/harness/compare.nim`; `nimble testLottieHarness` = `ALL OK`.

## Phase 1 - Parser/modelo/evaluador keyframes (sin expresiones)
- Estado: **completada (core + gaps principales cerrados)**
- Spec: `migration/lottie/AGENTS.md`
- Módulos: `src/thorvg/lottie/model/{common,property,model}.nim`, `animation/interpolator.nim`, `parser/parser.nim`.
- Tests:
  - `tests/lottie/test_phase1_eval.nim` → **ALL OK** (19 casos x 5 frames, pos/scale/rot/opacity vs goldens C++, skippedExpr=35, tol pos/scale 0.5, rot 0.05, op 1.5).
  - `tests/lottie/test_phase1_parse_corpus.nim` → **parsed=20 shapes=1295** (todos los `.lot`/`.json` Lottie en `upstream/test/res`, shape tree poblado).
  - `tests/lottie/test_phase1_types.nim` → **ok** (vec3, color, path lerp/snap).

### Qué funciona
- Parseo JSON->modelo para comp/layers/transforms (p/a/s/r/o), separate coords (p.s/p.x/p.y).
- Shape tree básico en layer tree: `LottieObject` base + `Group/Path/Rect/Ellipse/Fill/Stroke/Trimpath/Transform`, `layer.children` y `layer.parentId` poblados; tipos no soportados reportados con warning.
- Corpus completo upstream parsea (20 archivos, 1295 shapes).
- Keyframes: scalar float, scalar point, vector point (espacial), opacity uint8, vec3, color, path; hold; easing Bézier temporal (Newton+bisección, port de tvgLottieInterpolator).
- Tangentes espaciales: bezier con `lengthApprox` alpha-max-beta-min y `atApprox` como ThorVG (`tvgMath.cpp`); usa `f.inTangent` (this.inTangent) según `tvgLottieProperty.h`.
- Opacidad JSON 0-100 -> 0-255 con `trunc(getFloat()*2.55)` (como C++).
- Diagnósticos: `LottieComposition.warnings` con contexto `layers[i]('name')...` y shape ctx; audio/expr transform y shape types no soportados.
- `jsony@1.1.6` integrado en parser (`jsony.fromJson` -> std/json JsonNode).
- Propiedades con `"x"` (expresión) detectadas y omitidas en comparación de Phase 1.

### Hallazgos / discrepancias
- **test11 pointer layers**: longitud espacial almacenada en C++ puede diferir de la recomputada con tangentes actuales; la evaluación C++ usa `length` almacenado y `this->inTangent` en el segmento. Reproducido y ajustado en Nim. Diffs residuales <0.5px por precisión float bisección.
- `audio_layer.json`: capa/asset audio fuera de alcance; se mantiene por `$bm_rt` (expresiones omitidas en Phase 1).
- Parser usa `std/json` actualmente; `jsony@1.1.6` disponible offline pero integración pendiente (D-L4-JSON).

### Gaps Phase 1/2
- Per-dimension easing: `interpolatorsD` modelado y parseado cuando i.x/o.x son arrays; evaluación usa interpolador colapsado (C++ getValue) para paridad. Evaluación per-dim explícita queda pendiente solo si se confirma semántica distinta a C++.
- Shape model: árbol básico presente; faltan tipos (rp/mm/pb/rd en paths, etc.), text/fonts/markers; masks/mattes/precomps/assets/slots/effects básicos parciales.
- Shape/path: hay tipo+lerp+parser+evaluator básico; falta interpolación avanzada y render (Phase 2/3).
- Diagnósticos: tienen ctx de layer/shape; falta ruta JSON/property completa y cobertura exhaustiva de unsupported.
- Golden props cubren transforms; ampliar dumps para color/path/otras props cuando existan. Tolerancia pos/scale 0.5px por precisión float.

## Phase 2 - Builder sobre ThorVG Nim (MVP)
- Estado: **en progreso**
- Módulo: `src/thorvg/lottie/builder/builder.nim`
- Test: `tests/lottie/test_phase2_builder.nim` → **3/19 pass, 16 fail** (tol canal 2, RGBA vs goldens C++ corregidos).
- Baseline actual: **3/19 pass** (`test14`, `embedded_font`, `segment`), 16 fail, 0 skip. Sin regresiones.
- Fix reciente: **trim exact length (C++ parity)** en `src/thorvg/renderer/trim.nim`. Nim usaba `length(a,b)` aproximada (alpha-max-beta-min) para segmentos LineTo/Close al acumular longitudes de trim, mientras C++ usa distancia exacta (`length(pt-pt)`). Eso producía puntos de corte erróneos; `test10` k=13 (`TrimPath - Simultaneous Mode`, f89.0) pasa de 135px maxDiff 255 a 0. `test10` mejora a **0/51/84/239/183** en f0/f22.5/f45/f67.5/f89.
- Fix previo: **uint8 lerp truncation (C++ parity)** en `src/thorvg/lottie/model/property.nim`. C++ `tvg::lerp(uint8_t)` trunca; Nim redondeaba +0.5. `test10` mejoró de 5/201/84/388/1362 a 5/51/84/239/227; layer 16 aislada @89 `diffPx 0`.
- Bisección `test10` (2026-11-22, alpha incluida): layer 17 aislada reproduce 5/180/153 px en f0/f67.5/f89 (maxDiff 35/35/9), alpha-only AA. Trim composition verificada correcta. **Layer 17: AA/stroke coverage renderer, no builder**. k=13 resuelto por trim exact length (no era bug stroke open-path). Candidatos reales restantes: k=2 `Mask Layer - Inverted Matte` (f67.5, 21px maxDiff 255), k=5 fill effect (f89.0, 60px maxDiff 3, AA-like).
- Fixes previos: viewport clip root a tamaño target; precomp render (remap st/sr/tm); `applyTransform` scaleR/translateR+skew(`sk/sa`)+3D básico(`rx/ry/rz/or`)+autoOrient(`ao`); opacidad de grupo aplicada; masks Lottie básicos con `expand` acotado; mattes básicos (`tt/tp/td`, `tp` por id, orden matte->wrap->masks); blend mode de capa (`bm`); efectos básicos de capa (`ef`: Tint/Fill/Tritone/GaussianBlur/DropShadow, Stroke ty22 con parseo mn + color-fill recursivo).
- Mejoras recientes: polystar polígono `2*PI/n`; Fill/Stroke effect opacity `int(255*opacity)&0xFF`; `trimSegment` C++ 0..1+offset en `applyStyle`; offset-path acotado mejora `test6`/`test9`. `test10`: 4032/6275/6161/6468/7574 -> 5/201/84/388/1362 -> 5/51/84/239/227 -> **0/51/84/239/183**.
- Hallazgo slot: `upstream/test/res/images/img_0.png` ausente; golden slot f0 sin contenido en área esperada de imagen; probar PNG no cambió diffs. Bloqueado por asset/golden.
- Hallazgo gradient stroke: `toColorStops` usa opacidad 0-100 (debería ser 0-255). Corregirlo expuso bug en Nim engine `rasterGradientStroke` en `test10` capa 16; revertido por regresión, queda TODO. Revalidar antes de cambiar escala.
- Cercanos: `test10` f0 0px/f22.5 51px/f45 84px/f67.5 239px/f89 183px, `audio_layer` f0 1px, `slot` f90-179 9px, `tween` f149 20px, `test11` f55.5 57px, `test4` f37.5 14px.
- Bloqueadores: divergencia residual test10 (k=2 matte invertida, k=17 AA renderer; k=5 fill effect AA-like), offset-path completo (dirección/joins/subpaths/casos degenerados), cadena RenderContext/modificadores C++ (rp/rd completo/pb/zz/mm/orden), Stroke effect ty22 validación/casos, image/text layers, slots completos (PathSet/TextDoc/Image/override), gf/gs fino.
- Implementado: lowering layer shape/null, group/path/rect/ellipse, fill/stroke solid, transform (pos/anchor/scale/rot), opacity, jerarquía parentId, rebuild por frame, scaling comp->target, polystar (sr), trimpath (tm), parse gf/gs/sr/tm/rd/zz/mm/op/rp/pb, rd rects, zz activo, gf/gs aplicados, solid layer básico, precomp render básico.
- Falta: cobertura completa slots/sids, gf/gs correcto, rd en paths, rp/mm/pb/op, masks/mattes, image/text layers, orden fill/stroke/RenderContext/propagator semantics C++, pooling.

## Plan inmediato
1. Diagnosticar fallos Phase 2 por feature; priorizar trimpath/repeater/polystar/gradients/masks/precomp.
2. Alinear semántica builder con C++ (RenderContext/propagator, merge/fragment, draw order).
3. Phase 3: raster/render pipeline completo y paridad visual corpus sin expresiones.
4. Phase 4: expresiones `$bm_rt`/common, sin motor JS completo.
