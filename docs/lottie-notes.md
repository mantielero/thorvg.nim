# Lottie notes

Notas de implementación y discrepancias encontradas durante la migración Lottie (ThorVG Nim).

## Regla
- Si algo contradice este documento o el AGENTS.md, manda el código fuente C++ y anotar la discrepancia aquí.

## Hallazgos iniciales (Phase 0 setup)
- Spec rectora: `migration/lottie/AGENTS.md` (validada por usuario).
- Upstream C++ referencia: `upstream/src/modules/lottie/`.
- Assets upstream: `upstream/test/res/*.lot` (18) + `audio_layer.json` (tiene `$bm_rt`).
- Expresiones upstream C++: `tvgLottieExpressions.cpp` usa JerryScript; spec Nim exige runtime Nim puro sin motor JS. Validar semántica contra salida ThorVG C++.
- JSON: `jsony@1.1.6` integrado en `parser/parser.nim` (`jsony.fromJson` devuelve std/json JsonNode). Validación semántica completa vs ThorVG parser sigue pendiente para edge cases.

## Phase 0 harness
- Build referencia: meson `/tmp/opencode/thorvg-lottie-build`, `loaders=lottie`, `extra=lottie_exp`, sin tests/bindings.
- Harness: `tests/lottie/harness/dump_lottie.cpp` genera PPM+RGBA raw (ARGB8888 SwCanvas, unpremultiply para PPM), `*.props.json` y `manifest.json`.
- Props: obtenidas vía headers internos (`LottieLoader.comp`, `LottieLayer.transform`) enlazando todos los `.o` de `/tmp/opencode/thorvg-lottie-build/src` (incluye simd). `#define private public` solo en harness de test.
- Comparador: `tests/lottie/harness/compare.nim`, compara RGBA por canal y props numéricas con tolerancia; `nimble testLottieHarness` pasa.
- `Animation::frame(0)` puede devolver `InsufficientCondition` en ThorVG C++; el harness lo trata como no-fatal.
- `audio_layer.json`: contiene `$bm_rt` y capa audio; audio no soportado, pero props de rotación sirven como golden de expresión.

## Phase 1 gaps cerrados / notas
- **Shape model en layer tree**: añadido `LottieObject` base, `LottieGroup/PathObj/RectObj/EllipseObj/FillObj/StrokeObj/TrimpathObj`, `LottieLayer.children` y `parentId`. Parser puebla shapes básicas (gr/sh/rc/el/fl/st/tm/tr); tipos no soportados se registran con warning y `otUnknown`. Corpus 20/20 parsea con 1295 shapes.
- **Diagnósticos con contexto**: warnings incluyen `layers[i]('name')...` y ruta de shape (`.shapes[i]...`).
- **Per-dimension easing**: Lottie permite `i.x/i.y/o.x/o.y` como arrays. C++ `getValue(float&)` colapsa al primer elemento; Nim almacena `interpolatorsD` en frames pero evalúa con interpolador colapsado para paridad C++. Confirmado en `test_phase1_eval` ALL OK.

## Discrepancias
- **Per-dim easing arrays**: si en el futuro se observa semántica distinta a C++ getValue, habilitar eval per-dim desde `interpolatorsD` con prueba dorada específica.

## Phase 2 builder (notas)
- **Scaling comp->target**: el harness/golden renderiza a `manifest.w/h` (p.ej. 500x500) aunque `comp.w/h` difiera (p.ej. 1080x1080). El builder debe escalar la escena de coords de composición a target; se añadió `update(frameNo, targetW, targetH)` y escala root.
- **dump_lottie reuse bug (corregido)**: el harness reusaba la misma `Picture` en múltiples canvases/frame loops; con ThorVG 1.x esto produce frames vacíos/corruptos. Corregido a animación fresca por frame y goldens regenerados.
- **Comparación golden (corregido)**: `.rgba` es raw ARGB8888 little-endian (bytes B,G,R,A) premultiplicado. El test debe swizzle + unpremultiply antes de comparar contra `rgbaAt` straight. Con esto: 2/19 pass (test14, embedded_font).
- **test11/test14**: con goldens corregidos ya no son transparentes. test11 tiene slots/sids embebidos; test14 tiene zigzag. Requieren semántica correcta, no workaround de golden vacío.
- **Trimpath**: Lottie start/end 0-100, offset 0-360; ThorVG trimpath 0..1. Normalizar con cuidado: 100% debe mapear a 1.0, no a 0.0 wrap.
- **Gradient fill/stroke**: parseados gf/gs en model/parser; aplicación en builder deshabilitada por regresión (coords/alpha stops/transform). Requiere validar espacio de coords y stops alpha antes de habilitar.

## Phase 2 - hallazgos adicionales
- **Precomp segment**: al habilitar precomp, `segment` difiere en frame 60 (3945px). Golden C++ es transparente en todos los frames muestreados. Diagnóstico: transform de grupo se aplica correctamente (no corrupción); la forma cae dentro del precomp 256x256 en frame 60, pero C++ sigue vacío. Causa probable: falta semántica de precomp/mask/matte/time-remap/visibilidad en C++ no modelada; no habilitar precomp hasta aislar con referencia C++.
- **Gradientes gf/gs**: activar fill/stroke gradiente en builder empeora test2/slot vs placeholder transparente. Pendiente depurar coords locales, alpha stops, transform de fill/stroke y orden con stroke.

- **Slots/sids embebidos (parcial)**: parser captura `slots` root, registra bindings por `sid` en props comunes (transform, fill/stroke, rect/ellipse/path, gf/gs, tm, rd) y aplica overrides post-parse. ColorStop sid/binding en gf/gs (g/g.k). `test11` mejora: f0 1058, f27.75 18023, f55.5 16129, f83.25 1107, f110 351. `slot.lot` mixto; override `lottie-icon-outline` confirmado. Faltan ColorStop/PathSet/TextDoc/Image completos y semántica `LottieObject::override`.
- **gf/gs habilitados**: builder aplica `fill(f:Fill)`/`strokeFill(f:Fill)`. Radial usa fórmula C++ (`r=w+0.375*h` o `h+0.375*w`, focal por height/angle). Parser añade `h`/`a`. Suite sin regresiones.
- **Layer children como grupo**: `buildLayer` envolvía children y los pasaba a `buildObject` por separado, ignorando styles top-level (gf/gs/fl/st) en layers. Fix: procesar layer children como `LottieGroup` via `buildGroup`. Mejora grande en test4/5/6/7/9/12/slot/tween; tween f149=20px.
- **Near-miss**: `audio_layer` f0 44px, f113 192px (resto mayor; expr rot/audio/AA).

- **test3**: ty 5 (text) layer 'ThorVG' - builder omite ltText; diffs son texto faltante. Requiere soporte de capas text/solid/image.
- **tween f149**: 20px diff, mayormente AA/coverage edge (alpha ±1-3, pocos px). No semántico.

- **Precomp (rehabilitado)**: render básico habilitado en `buildLayer` (asset lookup, remap st/sr/tm, build asset layers en precompScene con world). `segment` pasa 5/5. El bloqueo anterior era el viewport clip root roto, no el precomp.
- **Viewport clip root**: el clip debe estar en tamaño target (canvas/parent space). Ponerlo en `comp.w/h` con root escalado a target lo recorta mal (clip usa pm del parent, no transform propio del scene). Corregido a `tw,th`.
- **Solid layer**: parse `sc` + render rect `sw/sh` con color/transform/opacity. Sin golden ty1 actual; sin regresiones esperadas (nim check ok).
- **Slot image asset**: `slot.lot` referencia `image_0` (`u=images/`, `p=img_0.png`, `e=0`, 200x300) pero `upstream/test/res/images/img_0.png` no existe. Golden slot f0 tiene bbox no transparente 31,31-316,441 y cero en área esperada de imagen; crear un PNG de prueba no cambió diffs. Probable golden generado sin asset; queda bloqueado hasta obtener asset correcto/confirmar expectativa.
- **Group opacity**: `LottieBuildCtx.opacity` se acumulaba pero no se aplicaba. Fix: `applyStyle` aplica `shape.opacity(ctx.opacity)` cuando <255; shape layers usan scene opacity solo de padres para evitar doble aplicación con la opacity de transform del layer. `nim check` OK, phase2 sin regresiones (3/19 pass).
- **Sid bindings**: añadidos bindings de slot para polystar (p/or/ir/os/is/r/pt), rd(r), zz(s/r), op(a), rp(c/o), pb(a). Sin cambio en baseline phase2; mejora cobertura para overrides futuros.
- **Masks básicos**: añadido `LottieMask` en model, parseo `masksProperties` (mode/inv/pt/o/x), y `applyMasks` en builder para shape/precomp/solid/image. Sin expand (offset path). Mejora inicial: test10 34816->29434, audio_layer f0 44->1, test7 f67.5/f89 2930.
- **Mattes básicos**: añadido `matteType/matteTarget/matteSrc/mix` en `LottieLayer`, parser `tt/tp/td`, `resolveMatteTargets`, y aplicación vía `Paint.mask` en `finalizeLayerScene`; matte sources (`td`) se omiten en render normal. Fix: `tp` por `ind/id`, orden matte->wrap->masks. Mejora: test7 33930/43018/53650/2930/2930->21282/32765/32835/2930/2930, test10 18648/19925/16193/19747/21159. `test13` sin cambio (matted layers invisibles por parent opacity 0).
- **Blend mode de capa (`bm`)**: parseado en `LottieLayer.blendMode`, aplicado con `Paint.blend` en escena final. Mejora: test10 11815/16556/15993/16378/15253. Sin regresiones phase2.
- **Stroke dashes (`d`)**: parseados en st/gs (`n=="o"` offset, resto valores) y aplicados con `Shape.strokeDash`. Mejora pequeña test10: 11760/16452/15889/16269/15160. Sin regresiones.
- **Stroke lc/lj/ml**: parseados y aplicados en st/gs. Mejora: test10 10988/15423/15146/15260/14076; slot 225/368/pass/pass/pass. test11 sube levemente por cap/join/miter correctos.
- **Trimpath múltiple**: composición de trimpaths sucesivos en rango existente (C++ `updateTrimpath`). Mejora test10: 9612/14180/14134/14372/13351. Sin regresiones.
- **Efectos de capa (ef, parcial)**: parseo en model/parser y aplicación en builder para Tint/Fill/Tritone/GaussianBlur/DropShadow. Stroke y Custom no soportados. test10 mejora mucho (4032/8665/8552/8856/7773); test12 baja maxDiff 255->63 pero sube diffPx a 11508 (revisar semántica Fill opacity/rangos y efectos no soportados). test8 sin regresión. Pendiente: Stroke effect (mask+stroke+fill en C++), rangos/animación de direction/wrap blur, orden/calidad exacta C++.
- **Fix remap precomp**: `remapFrame` usaba `eval(frameNo) >= 0` con default 0, activando timeRemap en precomps sin `tm`. Corregido a condición C++: `frames.len > 0 or value >= 0.0` (default -1). Sin cambio en baseline actual, pero correcto.
- **Image layer faltante**: si el asset no carga, se devuelve escena vacía finalizada (no `nil`) para mantener estructura de capa; alineado con C++. Sin cambio en baseline.
- **Rounded corner (rd, parcial)**: redondeo de esquinas cúbicas portado de `LottieRoundnessModifier` y aplicado a path/ellipse/polystar en `buildGroup`; rect usa `rx/ry`. No maneja LineTo ni cadena completa de modificadores. Sin cambio en baseline; test2 sigue alto (otro problema dominante).
- **Pucker/Bloat (pb, básico)**: portado de C++ y aplicado en `flushAcc`; convierte LineTo a CubicTo. Sin cambio en baseline (test13 sigue alto por matte/otros).
- **Skew transform (sk/sa)**: parseado y aplicado en `applyTransform` con fórmula C++ (`_skew`). Mejora test4 y test5; sin regresiones.
- **3D transform básico (rx/ry/rz/or)**: parseado/modelado (orient z como prop escalar separada) y aplicado en `applyTransform` usando matriz C++ `_dimension3d`. Mejora test4 (22 -> 14 diffPx) y test10 frames animados; sin regresiones.
- **AutoOrient (`ao`)**: parseado en capa y aplicado sumando ángulo de tangente de posición (vector path) a rotación; sin cambio en baseline actual.
- **Stroke effect (`ty 22`)**: modelo/parser ampliados (mask/allMask/color/size/opacity/begin/end) con parseo por `mn` cuando existe; builder aplica máscara+stroke y color-fill recursivo sobre shapes de capa. Sin cambio en baseline (3/19), pero implementación más correcta.
- **Offset path (op/mask expand)**: implementación acotada estilo `LottieOffsetModifier` (line/cubic shift, intersecciones, joins round/miter/bevel) en builder; aplicada a `mask.expand` y a `LottieOffsetPathObj` en `buildGroup`. Sin regresiones; mejora test6/test9 (op no-cero). Aún no es paridad completa C++.
- **Trimpath segment**: `applyStyle` usa `trimSegment` (C++ `LottieTrimpath::segment`, 0..1+offset, puede ser >1) en vez de normalizar a 0..1 con wrap. Mejora `test10@89` 2453->1362; baseline phase2 3/19 sin regresiones.
- **Uint8 lerp truncation (C++ parity, fixed)**: `property.nim` `lerpValue(uint8)` usaba `+0.5` (round half-up); C++ `tvg::lerp(uint8_t)` trunca. Causaba 1 nivel de diferencia en opacidades animadas (ej. test10 capa 16 stroke opacity f89: 6 vs 5), cambiando cuantización de ctable en gradientes. Corregido a truncación; test10 5/201/84/388/1362 -> 5/51/84/239/227, capa 16 aislada @89 diffPx 0.
- **Gradient stroke opacity/engine**: `toColorStops` escala opacity Lottie 0-100 como 0-100 (debería 0-255). Corregirlo expuso bug en Nim engine `rasterGradientStroke` (color uniforme, no gradiente) en `test10` capa 16; se mantiene TODO y escala antigua para evitar regresión. Tras el fix de lerp uint8, revalidar el caso capa 16 antes de cambiar escala.
- **test10 bisección (2026-11-22, alpha incluida)**: k=17 AA/stroke renderer; k=13 resuelto (trim exact length); k=2 no es matte invertido, edge AA star layer 2 (idéntico con/sin matte). Candidatos restantes AA-like. RGB-only diff daba falso 0 - siempre incluir alpha.
- **Scan Nim vs C++ (mismo build, worst frame phase2)**: hiSolid reales en `test2`(81,@45), `test5`(133,@45), `test6`(2995,@22.5), `test7`(13923,@45), `audio_layer`(16,@28.5). `test2@45` layer 12 "Inner" (2 gr): Nim dibujaba g1 sobre g0, C++ g0 sobre g1; grupos aislados 0 diff. Causa: C++ `updateChildren` itera hijos en reverso y añade scenes al procesar; orden de dibujo observado C++ = primer elemento del array arriba. Fix en `buildGroup`: emitir acciones de dibujo en orden reverso (match C++ observado). `test2` mejora fuerte (9671-9734 diff, max 111-132) vs baseline (55775/223@89); pass=3/19 sin regresiones de pass count. Cambio global de orden de dibujo: vigilar regresiones.

## Phase 0 - ty5 (Text Layers) descubrimiento

### Hallazgos clave
- **Glyphs embebidos presentes**: `test3.lot` tiene `chars` (6) con `ch/size/style/w/data.shapes/fFamily`; `test8.lot` tiene `chars` (24). `fonts.list` no tiene `fPath/origin/data` embebida, pero los glyphs están en top-level `chars` y C++ los asocia a fonts por `family+style` (`postProcess`).
- **Ruta C++ esperada para estos casos**: `updateText` usa `updateLocalFont` cuando `font.origin==Local && !font.chars.empty()`. Para test3/test8, esto aplica; no depende de fuentes del sistema.
- **Font fallback C++ 1.2.0**: `Text::font(name)` busca fonts cargadas por nombre; `font(nullptr)` usa `anyfont()`. `updateURLFont` intenta resolver, luego `font->prepare()`, luego fallback a `anyfont()`. No hay fontconfig en upstream 1.2.0. Para casos sin chars embebidos, la disponibilidad de fuente será blocker.
- **Goldens**: `tests/lottie/golden/test3|test8/*.rgba` generados con `dump_one` (C++ 1.2.0-dev, `/tmp/opencode/thorvg-lottie-build`), coinciden exactamente con `dump_one` actual en esta máquina.
- **Nim actual**: `ltText` enum existe; no hay parser/builder/model ty5. `renderer/text.nim` + font loader existen, pero Lottie ty5 no está integrado.

### Matriz de campos ty5 (gate)

#### test3 "ThorVG" (1 capa ty5)
- `t.d.k[0].s`: `s=200, f="Helvetica", t="ThorVG", ca=0, j=0, tr=0, lh=240.000015258789, ls=0, fc=[0.991,0.407,0.016]`
- `t.p` (follow path): `m=0, f` animado (keyframes), `l=0, a=0, p=1, r=0`
- `t.m`: `g=1, a=[0,0]`
- `t.a`: `[]` (sin ranges)
- Fonts: `Helvetica Regular`, ascent 71.8994140625
- Chars: 6 glyphs embebidos (`data.shapes`)

#### test8 "Range selector (Shape) Triangle" (ty5)
- `t.d.k[0].s`: `s=19, f="AvertaStd-Black", t="Range\rselector\r(Shape)\rTriangle", j=2, tr=0, lh=20, ls=0, fc=[0.286,0.796,0.804]`
- `t.a[0]` "Animator 1": `s={t=0,xe=0,ne=0,a=100,b=1,rn=0,sh=4,e animado 0->100->0, r=1}`, `a={s=[40,40,100]}`
- `t.p`: `{}`; `t.m`: `{g:1,a:[0,0]}`
- Necesita: range selector shape Triangle, units/range, scale override por glyph, grouping/alignment.

#### test8 "text" (ty5)
- `t.d.k[0].s`: `s=29, f="AvertaStd-Black", t="84_Text_Range selector (Shape)", j=0, tr=0, lh=34.8, ls=0, fc=[1,1,1]`
- `t.a`: `[]`, `t.p`: `{}`, `t.m`: `{g:1,a:[0,0]}`
- Caso texto básico con glyphs embebidos.

### Matriz de cobertura requerida (plan revisado)
- Documento `t.d.k[].s`: `f,fc,sc,sw,fs,sz,ps,t,j,tr,lh,ls,ca,of` (cubrir presentes; validar defaults C++).
- Rangos `t.a[]`: selector `s` (`t,xe,ne,a,b,rn,sh,r,sm,s,e,o`) y props `a` (`p,s,a,r,o,fc,sc,sw,t`).
- Opciones `t.m` (`g,a`) y follow path `t.p` (`m,f,l,r,a` + campos observados `p`).
- Fuentes: `fonts.list` + `chars` embebidos; orígenes/path/data según aparezcan.
- Keyframes de documento de texto: hold (sin interpolación) - añadir test.

### Decisión de fuentes (Fase 0, obligatoria)
- **Decisión**: para `test3/test8` y cualquier caso de gate con glyphs embebidos, la ruta primaria es **local glyph/char path** (equivalente a `updateLocalFont`), usando shapes de `chars` embebidos en `.lot`. No se depende de fontconfig ni de fuentes del sistema para estos casos.
- **Fallback general ty5** (fuera de estos casos): soportar carga explícita de fuentes via ThorVG font loader (`loadFont`/datos embebidos/path) cuando el asset lo provea; si falta fuente requerida, reportar error/diagnóstico claro. No usar fallback silencioso que altere paridad.
- **Riesgo residual**: si futuros goldens ty5 requieren fuentes externas no embebidas, se debe fijar fixture de fuentes reproducible offline antes de habilitar el caso.
- **Estado**: decisión suficiente para pasar a Fase 1 solo para el alcance test3/test8 con chars embebidos. Cualquier caso que requiera fuente externa no resuelta debe parar y documentarse.

### Harness/oráculo C++ (pendiente de completar)
- Existe `tests/lottie/harness/dump_lottie.cpp` (props/PPM/RGBA) enlazado contra build C++ 1.2.0-dev.
- **Pendiente**: extender o crear harness que vuelque layout intermedio ty5 por capa/frame: líneas, posición de glifo, factor de range, transform por glifo. Requiere acceso a builder interno/RenderText o instrumentación equivalente. Hasta entonces, oráculo numérico primario = golden RGBA + propiedades de modelo; layout se validará con tests dirigidos y comparación C++ cuando el harness esté instrumentado.

### Siguientes pasos (Fase 1)
- Añadir modelo Nim para TextDocument/LottieTextDoc/LottieFont/LottieGlyph/LottieTextRange/LottieTextFollowPath.
- Parser ty5 (`t.d`, `t.a`, `t.p`, `t.m`), `fonts.list`, `chars`, postProcess font-glyph.
- Tests de parser primero (campos/defaults/hold doc keyframes); warning estructurado/contado para campos desconocidos.
