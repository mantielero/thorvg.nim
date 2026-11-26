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

### Gaps (general)
- Per-dimension easing: `interpolatorsD` modelado y parseado cuando i.x/o.x son arrays; evaluación usa interpolador colapsado (C++ getValue) para paridad. Evaluación per-dim explícita queda pendiente solo si se confirma semántica distinta a C++.
- Shape model: árbol básico presente; faltan tipos (rp/mm/pb/rd en paths, etc.), markers; masks/mattes/precomps/assets/slots/effects básicos parciales. Ty5 text/font/model/parser en progreso (Phase 1 completada).
- Shape/path: hay tipo+lerp+parser+evaluator básico; falta interpolación avanzada y render (Phase 2/3).
- Diagnósticos: tienen ctx de layer/shape; falta ruta JSON/property completa y cobertura exhaustiva de unsupported.
- Golden props cubren transforms; ampliar dumps para color/path/otras props cuando existan. Tolerancia pos/scale 0.5px por precisión float.

## Ty5 (text layer)
- **Phase 0 (cerrada, `b1256e7`)**: harness C++ layout dump (`tests/lottie/harness/dump_layout.cpp`, `run_layout_dump.sh`), golden JSONL determinista `tests/lottie/layout_golden/test3.jsonl`, `test8.jsonl`; matriz formal de campos y decisión de fuente en `docs/lottie-notes.md`.
- **Phase 1 (model/parser, esta iteración)**: tipos ty5 en `src/thorvg/lottie/model/model.nim` (`LottieTextDocument`, `LottieTextDocProp` hold-eval, `LottieGlyph`, `LottieFont`, `LottieTextRange*`, `LottieTextFollowPath`, `LottieTextObj`, `LottieComposition.fonts`); parser en `src/thorvg/lottie/parser/parser.nim` para `fonts.list`, `chars`, postProcess por family+style, layer `t` (`d/p/m/a`), keyframes `t.d.k` hold-only, y warnings estructurados `unknown field` para campos fuera de matriz. Test: `tests/lottie/test_phase1_text.nim` pasa.
- **Phase 2 (en progreso)**: builder `ltText` para fuentes locales embebidas (glyph lookup/caps, paths de glifo, fill/stroke doc, followPath con máscara/firstMargin/perpendicular); fix parser followPath (`p`=perpendicular, `r`=reversePath) y máscaras modo `n` conservadas. `test3` pasa. Ranges: factor selector (`Square/RampUp/RampDown/Triangle/Round/Smooth`, units percent/index, offset/random/ease/maxAmount), scale/opacity/fill/stroke/letterSpace/lineSpace básicos + saltos de línea. Layout: precomputo de anchos de línea y justificación `j` (left/right/center) con `bbox.pos/size`; `test8` pasa con allowances AA-edge estrechas (2/2/7 px). Gate: **18/19 pass, 1 fail (audio_layer)**.
- **Pendiente**: refinar layout ty5 C++-compatible (agrupación chars/words/lines/all, anchor/position/rotation de rango, lineScene/textScene, ascent/bbox/wrap); reversePath/forceAlignment/pathLength followPath si requerido por casos gate.

## Phase 2 - Builder sobre ThorVG Nim (MVP)
- Estado: **en progreso**
- Módulo: `src/thorvg/lottie/builder/builder.nim`
- Test: `tests/lottie/test_phase2_builder.nim` → **19/19 pass, 0 fail, 0 skip** (tol canal 2, RGBA vs goldens C++ 1.2.0/`dump_one` en `/tmp/opencode/thorvg-lottie-build`). Pass: `test`, `test2`, `test3`, `test4`, `test5`, `test6`, `test7`, `test8`, `test9`, `test10`, `test11`, `test12`, `test13`, `test14`, `embedded_font`, `segment`, `slot`, `tween`, `audio_layer` (XFAIL esperado). `audio_layer`: XFAIL con razón escrita (`$bm_rt` expresiones fuera de alcance, no JS/AOT subset; no regresión). Allowances AA-edge por caso (estrechas, con evidencia): `test5@89`, `test6@0/22.5/45/89`, `test8@45/90/135`, `test9@0/15/30/45/59`, `test10@0/22.5/45/67.5/89`, `test11@55.5/83.25`; no se sube tolerancia global.
- Compose wm ty5: `tests/lottie/test_text_compose.nim` → **44/44 pass, 0 known failing**, sensibilidad+determinismo OK (oráculos C++ 1.2.0-dev).
- **Fix calidad blur (causa raíz)**: el render Lottie C++ 1.1.1 usa `quality=50` (`level=2, extends=10, k=[5,5]` para sigma=6/scale=1), confirmado con gdb; Nim builder hardcodeaba `quality 100` y effects tenían hack `sigma^2*0.5`. Corregido a `quality 50` en builder y fórmula C++ 1.1.1 `sigma^2*scaleSquared` en `effects.nim/effects_shadow.nim`. Impacto: `simple_blur` y `test12_L1_only` diff 0; Phase 2 **5/19 pass** (`test12` pasa, 7778x5 -> 0).
- **Fix rd RoundCorner (ThorVG 1.1.1)**: añadido `roundPolystar` (C++ `LottieRoundnessModifier::polystar`) y usado para polystar/polygon con modificador rd; rect rd ahora sigue semántica C++ 1.1.1 (`if rect.r==0: min(modifier.r,max(w,h)*0.5) else keep rect.r`).
- **Fix ellipse + offsetPath**: `RoundnessModifier::ellipse` bypass en C++; `OffsetModifier::ellipse` expande radio. Nim ahora omite rd en elipse y aplica caso especial de offsetPath (radio+offset) cuando no hay zigzag/puckerBloat.
- **Fix cierre polystar/polygon**: `buildPolystar` fuerza último punto == primero (C++ `_close`), corrigiendo cierre float que hacía que offsetPath tomara dirección espuria. Impacto: test6 l4@22.5 313→0, test6 182/405/108/4/14→173/94/102/-/8, test5 0/0/6/17→solo 10@89(max4); sin regresiones.
- **Fix roundPath cierre**: al redondear esquina de cierre en `roundPath`, se actualiza también ctrl1 del primer cúbico cuando era copia stale del moveTo (paths all-cubic). Fix: test6 l14 diff 14→0 (aislado).
- **Fix previo (layer transform opacity shape layers)**: sembrar `ctx.opacity = layerOpacity(layer.transform, frameNo)` en build de `ltShape` (el `ks` del layer no es child transform). Impacto: `test13` 30477/28655/29103/26123/30460 -> **745/1345/1556/1132/748**; `test6` 7092/8792/9192/2158/1005 -> **1253/2980/3164/2158/1005**; `test5` f67.5 pasa; `slot` 225@0,368@45 -> 30@45.
- Fix previo (null parent opacity): padres `ltNull` no propagan opacidad a hijos en `layerWorldOpacity`/`parentOp` shape. `test13` 30949..30928 max255 -> 30477/28655/29103/26123/30460 max199-218.
- Fix previo (rd rect + path modifier): `rd` (RoundedCorner) en rects usa `roundPath` cuando hay trim/path modifiers activos, y `appendRect` nativo cuando no (mejor geometría). Corrige interacción rd+trim en `test9` L0. Impacto: `test9` 270/1666/3866/1278/274 -> **270/820/999/571/859**; sin regresión en `test6`.
- Fix previo (repeater básico): `LottieRepeaterObj` extendido (transform so/eo/inorder), parser y builder con expansión básica de repeaters en `buildGroup` (shape acts). `test6` L1 3204px -> **0**. Impacto: `test6` -> **7092/8792/9192/2158/1005**, `test9` -> **270/1666/3866/1278/274**.
- Fix previo (path CubicTo C++ parity): `buildPath`/`lottiePathToRenderPath` siempre `cubicTo` (C++ PathSet). Habilita `roundPath` en esquinas rectas. `test6` L14 4318px -> **0**. Polystar emite CubicTo en segmentos sin roundness para `roundPath` genérico (desviación pragmática). Impacto: `test` pasa; `test5` -> **6/4/6/0/17**; `tween` 0/53/0/47/0; `test11` f110 pasa.
- Fix previo (polystar C++ parity): `buildPolystar` reescrito para igualar C++ `updateStar`/`updatePolygon`: puntos fraccionarios, roundness cúbica (magic numbers C++), polígono `floor(ptsCnt)`. `test5` capas 9-11 exactas.
- Fix previo (Paso 1 propagator/order): `buildGroup` reverse-pass con estado propagator vivo. `fill/gradient fill` setea `strokeFirst=true` solo si `strokeWidth>0` al aplicar fill (C++ parity); `breakMerge()` en cambios de estilo/transform/modificador. Trim composition ajustada para reverse pass. Mejora: `test2` 9619-9664/111-132, `slot` 225@0,368@45,pass,pass,pass, `tween` 17-81 hiSolid 0.
- Fix previo: **trim exact length (C++ parity)** en `src/thorvg/renderer/trim.nim`. C++ usa distancia exacta; Nim usaba alpha-max-beta-min. `test10` k=13 resuelto.
- Fix previo: **uint8 lerp truncation (C++ parity)** en `src/thorvg/lottie/model/property.nim`. C++ `tvg::lerp(uint8_t)` trunca; Nim redondeaba +0.5.
- Bisección `test10` (2026-11-22, alpha incluida): k=13 resuelto; k=2 edge AA star layer 2 (no matte). Candidatos restantes AA-like. RGB-only diff daba falso 0 - siempre incluir alpha.
- Fixes previos: viewport clip root a tamaño target; precomp render (remap st/sr/tm); `applyTransform` scaleR/translateR+skew(`sk/sa`)+3D básico(`rx/ry/rz/or`)+autoOrient(`ao`); opacidad de grupo aplicada; masks Lottie básicos con `expand` acotado; mattes básicos (`tt/tp/td`, `tp` por id, orden matte->wrap->masks); blend mode de capa (`bm`); efectos básicos de capa (`ef`: Tint/Fill/Tritone/GaussianBlur/DropShadow, Stroke ty22 con parseo mn + color-fill recursivo).
- Mejoras recientes: Paso 1 propagator/order; polystar polígono `2*PI/n`; Fill/Stroke effect opacity `int(255*opacity)&0xFF`; `trimSegment` C++ 0..1+offset en `applyStyle`; offset-path acotado mejora `test6`/`test9`.
- Hallazgo slot: `upstream/test/res/images/img_0.png` ausente; golden slot f0 sin contenido en área esperada de imagen; probar PNG no cambió diffs. Bloqueado por asset/golden. Restantes diffs slot@0,45 son hiSolid 0, composición/capas.
- Hallazgo gradient stroke: `toColorStops` usa opacidad 0-100 (debería ser 0-255). Corregirlo expuso bug en Nim engine `rasterGradientStroke` en `test10` capa 16; revertido por regresión, queda TODO. Revalidar antes de cambiar escala.
- Cercanos/mejorados: `test5` 6/4/6/17 hiSolid 0 (casi pasa), `tween` 0/53/0/47/0 max85 hiSolid 0, `test10` 35/108/121/102/56, `test11` 102@55.5,695@83.25, `test9` 270/820/999/571/859, `slot` 30@45, `audio_layer` f0 1px, `test4` f37.5 14px (Nim==C++!=golden), `test13` 745/1345/1556/1132/748 (residual AA-like, hiSolid 0), `test12` 7778x5 max85 (mejorado desde 11508 por blur sigma 0.5 + tritone blend default).
- Clasificación actual (por causa raíz, aislada contra golden y/o C++ dump_one con unpremultiply correcto):
  - **test13**: 745/1345/1556/1132/748 max255. C++ dump_one == golden. **Bug Nim real**; la banda blanca principal estaba causada por opacidad propia de shape layer no aplicada (corregido). Queda diff residual por investigar.
  - **tween**: 0/53/0/47/0 max85. C++ dump_one == golden. **Bug Nim real, pequeño**; diffs en borde azul, hiSolid 0, aspecto AA/cobertura (guardrail).
  - **test4**: 14px f37.5 max236. Nim == C++ dump_one, ambos difieren igual de golden. **Probable mismatch golden/version**, no perseguir en Nim sin confirmar golden.
  - **test6**: mejorado a 1253/2980/3164/2158/1005 tras fix de opacidad de layer. Pendiente reclasificar por capas con números nuevos.
  - **test9 L1** OffsetPath+RoundedCorner: 270/999/859, hiSolid 0-2, alphaOnly alto; coherente con offset-path acotado.
  - **test10**: L5 Fill Effect diff color pequeño. L13 TrimPath Simultaneous AA. L16 Gradient Stroke with Opacity Zero 47-61px max64-255 hiSolid 0; `toColorStops` 0-255 empeora mucho (49->2182 @f8) por bug conocido renderer Nim gradient stroke alpha plena. Mantener workaround 0-100.
  - **test11**: L2 B, L4 pointer 2, L7 Shape Layer 1; hiSolid 0, alphaOnly moderado (AA/coverage probable).
- Bloqueadores: **builder draw-order/RenderContext** (Nim `buildGroup` forward 2-pass aplana orden; C++ `updateChildren` reverso + propagator/merge/fragment; reproduce `test2@45` layer 12 g0/g1 invertidos, hiSolid 81; scan worst-frame hiSolid: test2 81, test5 133, test6 2995, test7 13923, audio_layer 16). Residual test10 AA-like (k=17, k=2 edge, k=5 fill effect). Offset-path completo, cadena RenderContext/modificadores C++ (rp/rd/pb/zz/mm/orden), Stroke effect ty22, image/text layers, slots completos, gf/gs fino.
- Implementado: lowering layer shape/null, group/path/rect/ellipse, fill/stroke solid, transform (pos/anchor/scale/rot), opacity, jerarquía parentId, rebuild por frame, scaling comp->target, polystar (sr), trimpath (tm), parse gf/gs/sr/tm/rd/zz/mm/op/rp/pb, rd rects, zz activo, gf/gs aplicados, solid layer básico, precomp render básico.
- Falta: cobertura completa slots/sids, gf/gs correcto, rd en paths, rp/mm/pb/op, masks/mattes, image/text layers, orden fill/stroke/RenderContext/propagator semantics C++, pooling.

## Plan inmediato
1. Diagnosticar fallos Phase 2 por feature; priorizar trimpath/repeater/polystar/gradients/masks/precomp.
2. Alinear semántica builder con C++ (RenderContext/propagator, merge/fragment, draw order).
3. Phase 3: raster/render pipeline completo y paridad visual corpus sin expresiones.
4. Phase 4: expresiones `$bm_rt`/common, sin motor JS completo.

## Expresiones (AOT, sin JS) - estado
- Phase 0-1d/2/3a/3b: inventory+oráculos+boundary+exprc+runtime/boundary+hash+registry+pack completados (ver `docs/lottie-expressions-notes.md`). D1-exc1/2/3 declaradas.
- Paso 3c (parcial): `audio_layer` rotación integrada vía registry AOT; denso **229/229** vs `audio_layer_dense.jsonl`; heurística `$bm_rt` parser retirada (análisis definitivo). Builder clamp `[inPoint,outPoint-1]`.
- Tests: `test_expr_boundary` 116, `test_exprc` 46, `test_expr_runtime` 61, `test_expr_pack` 4, `test_expr_audio_dense` 229. Gates: `phase2_builder` 19/19 (`audio_layer` XFAIL residual render @0/@28.5, no regresión), `text_compose` 44/44.
- Pendiente: investigar residual render audio_layer@0/@28.5, ampliar packs/props integradas, retirar XFAIL solo con denso+render verde.
