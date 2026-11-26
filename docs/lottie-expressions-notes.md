# Lottie expressions - notas (Phase 0)

## Phase 0.1 - Medición (puerta obligatoria)

### Build C++ de referencia
- Build: `/tmp/opencode/thorvg-lottie-build` (ThorVG upstream 1.2.0-dev, copia en `upstream/`).
- Opción meson: `extra = ["lottie_exp"]` (`meson-info/intro-buildoptions.json`). **Expresiones habilitadas**.

### audio_layer (hito)
- Fichero: `upstream/test/res/audio_layer.json` (gate case `audio_layer`).
- Expresión encontrada (1): `layers[0].ks.r.x` (bell rotation).
  - Fuente:
    ```js
    var $bm_rt;
    var $bm_rt;
    var veloc, amplitude, decay;
    veloc = 15;
    amplitude = 65;
    decay = 4;
    $bm_rt = $bm_rt = div(mul(amplitude, Math.sin(mul(veloc, time))), Math.exp(mul(decay, time)));
    ```
  - Identificadores: `$bm_rt, Math, amplitude, decay, div, exp, mul, sin, time, veloc`
  - Construcciones: `var`
- Prueba de sensibilidad (mismo build C++ lottie_exp, 500x500, frames del golden):
  - `000.00`: golden_vs_orig dp=0 md=0 | orig_vs_noexpr dp=0 md=0 (time=0 => expr=0)
  - `028.50`: golden_vs_orig dp=0 md=0 | orig_vs_noexpr dp=10154 md=255
  - `057.00`: golden_vs_orig dp=0 md=0 | orig_vs_noexpr dp=3073 md=255
  - `085.50`: golden_vs_orig dp=0 md=0 | orig_vs_noexpr dp=1384 md=133
  - `113.00`: golden_vs_orig dp=0 md=0 | orig_vs_noexpr dp=122 md=1

**Decisión Phase 0.1**: Build con expresiones y resultado distinto. El golden **depende** de evaluar la expresión. **No** basta con `IgnoreCounted`; sigue el plan AOT completo para resolver `audio_layer`.

### test5 (sensibilidad observada)
- `upstream/test/res/test5.lot` contiene 4 expresiones (`layers[5].ks.p.x`, `layers[6].ks.r.x`, `layers[7].ks.s.x`, `layers[8].ks.o.x`).
- Sensibilidad en frames golden `0,22.5,45,67.5,89`: golden_vs_orig identico (0,0) y orig_vs_noexpr identico (0,0). Los goldens actuales **no dependen** de evaluarlas en esos frames muestreados. test5 pasa gate Nim sin eval de expresiones.
- Nota: no asumir que todas las frames son insensibles; solo las muestreadas.

## Phase 0.2 - Inventario del corpus

- Herramienta: `tools/lottie_expr_inventory.nim` (Nim, sin Node). CSV: `docs/lottie-expr-inventory.csv`.
- Raíces escaneadas: `tests/lottie/golden`, `upstream/test/res`, `tests/lottie`, `examples`.
- Total expresiones encontradas: **5** (1 en `audio_layer.json`, 4 en `test5.lot`).

| file | propPath | idents/funcs | constructs |
|---|---|---|---|
| upstream/test/res/audio_layer.json | layers[0].ks.r.x | $bm_rt,Math,amplitude,decay,div,exp,mul,sin,time,veloc / div,exp,mul,sin | var |
| upstream/test/res/test5.lot | layers[5].ks.p.x | Math,cos,sin,t,time / cos,sin | var |
| upstream/test/res/test5.lot | layers[6].ks.r.x | time | (none) |
| upstream/test/res/test5.lot | layers[7].ks.s.x | Math,s,sin,time / sin | var |
| upstream/test/res/test5.lot | layers[8].ks.o.x | Math,cycle,maxOpacity,minOpacity,sin,time / sin | var |

## Phase 0.3 - Matriz de características (borrador, verificar contra ThorVG)

Estado: `pendiente` | `en-alcance` | `fuera-alcance` | `hecho`

| Característica | Ejemplo | Frec. corpus | Fase | Estado | Notas |
|---|---|---:|---:|---|---|
| `$bm_rt` | `$bm_rt = ...` | 1 | 4 | en-alcance | Exportador bodymovin; alias de resultado. |
| `$bm_sum/sub/mul/div/mod` | `$bm_div(...)` | 1 (`div`) | 4 | en-alcance | Verificar set exacto en ThorVG. |
| `var` | `var t = time;` | 5 | 4 | en-alcance |  |
| asignación `=` | `veloc = 15` | 5 | 4 | en-alcance |  |
| literales numéricos | `15`, `65` | 5 | 4 | en-alcance |  |
| arrays literales | `[s, s]` | 2 | 4 | en-alcance |  |
| aritmética `+ - * /` | `(cycle+1)/2` | 4 | 4 | en-alcance |  |
| `time` | `time * 100` | 5 | 4 | en-alcance |  |
| `Math.sin/cos/exp` | `Math.sin(...)` | 4 | 4 | en-alcance | Subconjunto Math usado. |
| `value` | `value` | 0 | 4 | pendiente | No visto en corpus, común. |
| `thisComp/thisLayer/thisProperty` |  | 0 | 5 | pendiente |  |
| `linear/ease/clamp` |  | 0 | 2 | pendiente |  |
| `loopIn/loopOut` |  | 0 | 6 | pendiente |  |
| `wiggle/random/noise` |  | 0 | 6 | pendiente | D3 abierta. |
| referencias `layer/effect/content` |  | 0 | 5 | pendiente |  |
| `function`/closures |  | 0 | 4+ | pendiente | No visto; error estructurado si aparece. |
| `if/ternary/for/while` |  | 0 | 4 | pendiente |  |
| `eval/Function/with/regex` |  | 0 | - | fuera-alcance | Prohibidos por plan. |

## Decisiones
- **D1 (cerrada, confirmada por usuario 2026-05-19)**: referencia semántica = ThorVG C++ 1.2.0 con `lottie_exp`. Donde diverja de AE, seguir ThorVG y anotar.
- **D2 (cerrada, confirmada por usuario 2026-05-19)**: registro por hash; política `Strict` por defecto (expresión no compilada => error estructurado). `IgnoreCounted` solo si el llamante la pide.
- **D3 (abierta, Fase 6)**: `wiggle/random/noise/gaussRandom` - replicar algoritmo/semilla de ThorVG para paridad numérica o solo estadístico.

## Phase 1 - Oráculo de expresiones (en progreso)

### Harness
- `tests/lottie/harness/dump_expr.cpp`: parche/lectura sobre headers privados (define private public), carga .lot, renderiza por frame (draw+sync) y vuelca propiedades con `exp != null` como JSONL: `{layer,id,prop,frame,value:[...]}`.
- Compilación: enlaza contra objetos de `/tmp/opencode/thorvg-lottie-build/src/libthorvg-1.so.1.2.0.p` + simd `.a` (símbolos internos ocultos en .so). Script: `tests/lottie/harness/run_expr_dump.sh`.
- Build ref: `/tmp/opencode/thorvg-lottie-build`, `extra=[lottie_exp]`.

### Hallazgo semántico (crítico)
- `LottieExpressions::evaluate()` evalúa el código con jerryscript y devuelve `jerry_object_get_sz(context.global, "$bm_rt")`. **Ignora el valor de retorno del eval**. Por tanto, expresiones sin asignación a `$bm_rt` caen a undefined -> fallback al valor estático.
- Confirma por qué `test5.lot` (expresiones sin `$bm_rt`, solo valor final implícito) es insensible en frames golden muestreados y el dump devuelve estáticos. `audio_layer` asigna `$bm_rt` y sí evalúa.
- Implicación para AOT: el lowering/emisor debe asignar el resultado final a `$bm_rt` (o el runtime debe leerlo de forma equivalente). Para corpus, solo expresiones que establecen `$bm_rt`/semántica equivalente ThorVG son evaluadas por el motor C++.

### Oráculos sintéticos
- Generador: `tests/lottie/harness/gen_expr_cases.py` -> `tests/lottie/expr_cases/` (9 casos + 9 bases, manifiesto con frames `[0,7.5,15,22.5,30,45,60,89]`).
- Golden JSONL: `tests/lottie/expr_golden/*.jsonl`.
- Cobertura corpus: `time`, `var`+asignación, aritmética, `Math.sin/cos/exp`, `$bm_rt/$bm_div/$bm_mul`, array literal, opacidad escalar.
- Determinismo: dos ejecuciones idénticas (verificado para los 9 casos). Sensibilidad: todos difieren del valor estático base.

### Precisión numérica (frontera)
- Jerryscript ejecuta JS con semántica numérica **float64** (Number IEEE 754). ThorVG expone `toFloat`/operadores sobre double/float según propiedad.
- Opacidad: expresión devuelve 0-100 en estilo AE, ThorVG convierte `toFloat(bm_rt)*2.55f` y almacena como uint8 (0-255). Dump muestra valor uint8.
- Rotación/posición/escala: float en propiedades. Dump usa `%.9g`.
- Decisión pendiente de fijar formalmente en tests de oráculo: tolerancia de comparación (proponer abs 1e-5 para float props, exacto/±1 para uint8 opacity tras conversión).

## Phase 1b - Semántica $bm_rt / oráculo (datos C++ 1.2.0 lottie_exp)

Casos: `tests/lottie/harness/gen_expr_1b_cases.py` -> `tests/lottie/expr_1b_cases/`, oráculos `tests/lottie/expr_1b_golden/`. Audio layer denso: `tests/lottie/expr_golden/audio_layer_dense.jsonl` (0..114 paso 0.5).

### 1) Estado global / fuga $bm_rt (CRÍTICO)
- `leak_r_to_o`: r asigna `$bm_rt=50`, o tiene expr sin `$bm_rt` (`var x=1;`). Resultado: o devuelve 127 (=50*2.55). **Fuga entre propiedades** en la misma evaluación/contexto.
- `leak_layer_to_layer`: L1.r asigna 77, L2.r expr sin `$bm_rt`. Resultado: L2.r devuelve 77. **Fuga entre capas**.
- `leak_frame_to_frame`: **CORRECCIÓN** - el golden 1b (`dump_expr` crea un `Animation` nuevo por frame) ocultaba la fuga. Con la **misma animación** reutilizada (forward/seek-back), frames 0,0.5,1,2 y seek 0,1,2,1,0 devuelven todos 99. **También hay fuga entre frames** en el mismo objeto/ctx. La fuga es estado global mutable persistente del contexto JS mientras vive la animación.
- Implicación: `$bm_rt` es estado global mutable del motor JS; depende de orden de evaluación y persiste en la vida del contexto de animación. **No replicar** en AOT. AOT debe tratar "no asigna $bm_rt definitivo" como `None`/usar estático + warning contado.
- **D1-exc1 (excepción declarada a D1)**: en documentos mixtos (al menos una expr que asigna y otra que no asigna siempre), ThorVG puede propagar valor por fuga; Nim caerá a estático. Divergencia real y aceptada. Requiere `known_divergences.txt` (motivo + golden Nim esperado, no C++) y warning contado de exprc/inventario para cualquier .lot mixto expuesto. Hoy no hay ninguno en el corpus.

### 2) Asignación condicional
- `cond_both`: ambas ramas asignan -> valor esperado por rama (10 cuando time<=0.5s, 45 cuando >0.5s).
- `cond_missing_else`: rama sin asignación -> fallback a estático (0) en frames donde no se asigna; 45 cuando sí. Requiere análisis de asignación definitiva en compilador.

### 3) Tipos de salida / coerción observada
- `NaN/Infinity/-Infinity`: se devuelven como float (nan/inf/-inf).
- `undefined`: fallback estático (0).
- `bool true/false`: observado fallback estático (0) en prop escalar rotación (verificar con más casos; posible ruta toFloat/undefined).
- `string`: fallback estático (0).
- escalar en prop vectorial (position): fallback estático `[0,0]`.
- array en prop escalar (rotation, `[1,2]`): observado `[1]`. **No es coerción JS** (`Number([1,2])` es NaN, `Number([1])` es 1). Regla ThorVG: probablemente primer elemento. Añadir casos `[3]`, `[1,2,3]`, `[]` para confirmar. Oráculo manda.

### 4) Errores de ejecución
- identificador no definido y `throw`: `evaluate()` captura excepción, deshabilita expr (`exp->disabled=true`), retorna undefined -> fallback estático. En AOT, identificador desconocido será error de compilación (divergencia consciente, anotar).

### 5) Opacidad (0-100 expr -> uint8)
- Borde observado: 0->0, 0.4->1, 49.99->127, 50->127, 99.9->254, 100->255. Trunca (no redondea).
- **float32 requerido**: `100*2.55f` en float64 da 254.99999523 -> trunc 254; en float32 `100f32*2.55f32` da 255.0f32 -> 255. Implementar como `uint8(float32(v) * 2.55'f32)`. Reusar función de conversión de opacidad estática en Nim. Tolerancia opacidad: **exacta** (±1 escondería error float32/float64). Pendiente: barrido 0..100 paso 0.1.

### Tolerancia propuesta (formalizar en tests)
- Float props: `|a-b| <= 4e-7*|b| + 1e-9` (1-2 ulp float32) tras frontera; comparar valor de propiedad, no float64 interno. Documentar libm de jerryscript (propia vs sistema) y comparar tras frontera float32.
- Opacity uint8: **exacta**. Conversión en float32: `uint8(float32(v)*2.55'f32)`. Barrido 0..100 paso 0.1 pendiente.
- Errores/deshabilitado: `evaluate()` pone `exp->disabled=true` tras excepción (estado dependiente de orden frames). Anotado; si exprc acepta construcciones que puedan lanzar en runtime, reaparece.

### Cambio Nim (parser)
- Warning contado cuando expr no contiene `$bm_rt`: "expression but never assigns $bm_rt; ignored as in ThorVG 1.2.0" (heurística; análisis definitivo en compilador). Elimina silencio semántico en casos tipo test5.

## Riesgos/observaciones
- Inventario busca `x` string en cualquier objeto JSON; puede haber falsos positivos/negativos. Validar heurística con casos reales.
- `audio_layer` es el único caso del gate que depende de expresión en frames muestreados; test5 tiene expresiones sin `$bm_rt` (muertas por diseño en ThorVG 1.2.0) - Nim emite warning contado.
- Fuga `$bm_rt` entre props/capas/frames (mismo contexto animación) es comportamiento no determinista dependiente de orden; **D1-exc1**: no replicar en AOT. Usar `known_divergences.txt` (motivo + golden Nim esperado) separado de `known_failing`.
- Casos de tipos/errores deben usar estáticos distintivos (ej. 33.3 escalares, [7,9] vectores) para no confundir "fallback estático" con "coercionó a 0".
- C++ build de referencia ya tiene `lottie_exp`; se puede usar como oráculo.
