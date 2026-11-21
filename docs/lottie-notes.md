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
- **Masks básicos**: añadido `LottieMask` en model, parseo `masksProperties` (mode/inv/pt/o/x), y `applyMasks` en builder para shape/precomp/solid/image. Sin expand (offset path) ni matte/track matte. Mejora: test10 34816->29434, audio_layer f0 44->1, test7 f67.5/f89 2930. Sin regresiones phase2.
