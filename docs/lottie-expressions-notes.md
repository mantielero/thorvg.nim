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

## Decisiones abiertas (cerrar antes de Fase 2)
- **D1. Referencia semántica**: recomendado ThorVG C++ 1.2.0 con expresiones habilitadas (paridad con ThorVG). Donde diverja de AE, seguir ThorVG y anotar.
- **D2. Modelo de carga**: recomendado registro por hash (Lotties runtime funcionan si precompilados; si no, error estructurado). Alternativa build-time estático más simple pero no carga ficheros arbitrarios.
- **D3. Aleatoriedad**: `wiggle/random/noise/gaussRandom` requieren replicar algoritmo/semilla de ThorVG para paridad numérica. Decidir en Fase 6.

## Riesgos/observaciones
- Inventario busca `x` string en cualquier objeto JSON; puede haber falsos positivos/negativos. Validar heurística con casos reales.
- `audio_layer` es el único caso del gate que depende de expresión en frames muestreados; test5 tiene expresiones pero frames golden muestreados insensibles.
- C++ build de referencia ya tiene `lottie_exp`; se puede usar como oráculo de Fase 1.
