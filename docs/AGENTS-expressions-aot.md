# AGENTS.md: expresiones Lottie AOT a Nim puro

## Objetivo
Evaluar expresiones Lottie **sin JavaScript**, ni en ejecución ni en la cadena de herramientas. Cada expresión se traduce antes de ejecutar a código Nim tipado; no hay intérprete en runtime.

Primer hito medible: `audio_layer` (hoy XFAIL por `$bm_rt`) pasa a PASS, o se demuestra con datos que no hace falta evaluar nada para igualar el golden.

## Reglas globales
1. **Cero JS.** Ni motor embebido ni Node en el toolchain. El compilador de expresiones (`exprc`) está escrito en Nim.
2. **AOT.** No existe intérprete. Consecuencia explícita: una expresión que no fue precompilada no se puede evaluar. Se trata con una política declarada (ver "Política de expresión no compilada"), nunca en silencio.
3. **Sin estado global mutable.** Todo lo que una expresión necesita llega por un `ExprCtx` explícito.
4. **Sin degradación silenciosa.** Una construcción no soportada produce un error de `exprc` con archivo, propiedad, línea y columna. No hay modo "parcial" por defecto.
5. **Oráculo numérico, no solo píxeles.** Se compara el valor de cada propiedad con expresión por frame contra C++ (lección del layout de texto).
6. **Una fase por iteración**, gate verde antes y después, tests primero (en rojo), y **parar y reportar** ante cualquier decisión no escrita en `docs/lottie-expressions-notes.md`.
7. No implementar jamás `eval`, `Function`, `with`, regex literales ni acceso dinámico a globales por nombre.

## Decisiones previas (cerrar antes de la Fase 2)
- **D1. Referencia semántica.** Recomendado: ThorVG C++ 1.2.0 compilado con expresiones habilitadas, porque el objetivo es paridad con ThorVG, no con After Effects. Donde ThorVG se aparte de AE, se sigue a ThorVG y se anota.
- **D2. Modelo de carga.** Recomendado: registro por hash. Lotties cargados en runtime funcionan si sus expresiones fueron precompiladas; si no, error estructurado. La alternativa (solo build-time estático) es más simple pero impide cargar ficheros arbitrarios.
- **D3. Aleatoriedad.** `wiggle`, `random`, `noise` y `gaussRandom` solo darán paridad numérica si se replican los algoritmos y la semilla de ThorVG. Decidir en Fase 6 si se replican exactamente o si se prueban solo estadísticamente.

## Arquitectura

```
.lot ─► extractor ─► ExprUnit{hash, source, propPath, tipo}
                        │
                        ▼
             lexer/parser (subconjunto ES5, en Nim)
                        │ AST
                        ▼
        análisis: identificadores (builtins, $bm_*, locales, refs)
                        │
                        ▼
              IR tipado simple ─► emisor Nim ─► expr_pack_<nombre>.nim
                                                     │
 runtime: ExprCtx + biblioteca (Val, vec, interp, loop, random) ◄┘
          registro hash ─► proc, inyectado al loader (sin global)
```

- Herramienta: `tools/exprc/` (lexer, parser, ast, check, lower, emit).
- Runtime: `src/thorvg/lottie/expr/` (`value.nim`, `vec.nim`, `interp.nim`, `loop.nim`, `random.nim`, `ctx.nim`, `registry.nim`).
- Cada expresión genera `proc expr_<hash>(ctx: ExprCtx; value: Val): Val`, pura.
- Valores: tipo variante `Val` (escalar, vec2/3/4, color, bool, texto, array). La inferencia de tipos para eliminar el boxing es una optimización posterior (Fase 8), no un requisito.
- Aritmética en `float64` (como JS) y conversión a `float32` solo en la frontera de la propiedad, **si el oráculo lo confirma**. Verificar en Fase 1; no asumir.
- Hash: FNV-1a de 64 bits más longitud, sobre la fuente con saltos de línea normalizados. El registro generado guarda también la fuente completa para que un test detecte colisiones.
- Integración de build: tarea `nimble exprc` que regenera `src/generated/expr_pack_*.nim`; CI regenera y falla si hay diff. Un macro `compileExpressionsFrom(path)` sobre el mismo frontend queda como opcional posterior.

### Política de expresión no compilada
- `Strict` (por defecto): error estructurado `ExpressionNotCompiled{layer, propiedad, hash, extracto}`.
- `IgnoreCounted`: la propiedad usa su valor sin expresión y se emite un warning contado. Equivale al comportamiento de un ThorVG compilado sin expresiones. Se activa solo si el llamante lo pide.

### Resolución de referencias
`thisComp.layer("Nombre")`, `effect("Slider")("Slider")`, etc. dependen del documento, no del texto de la expresión (el mismo texto puede apuntar a capas distintas en ficheros distintos). Por eso las referencias por nombre se resuelven **al cargar** el documento a manejadores, una vez, nunca por frame, y el hash de la expresión no incluye el documento. Dependencias circulares: detección y error estructurado.

## Fase 0: medición y descubrimiento (puerta obligatoria)

### 0.1 Qué hacen realmente los goldens con `audio_layer`
1. Comprobar si el build de C++ en `/tmp/opencode/thorvg-lottie-build` se compiló **con** expresiones (opción de meson que habilita el motor de expresiones de ThorVG; verificar el nombre exacto en el árbol).
2. Localizar la(s) expresión(es) de `audio_layer.lot`: ruta de propiedad, texto completo, tipo de propiedad. Script que recorra el JSON buscando claves `"x"` con cadenas.
3. Prueba de sensibilidad: copia del `.lot` sin esas expresiones, `dump_one` de ambos, comparar píxeles.
4. Decisión:
   - Build sin expresiones, o resultado idéntico sin la expresión: el golden no depende de evaluarla. Nim pasa con `IgnoreCounted` más warning contado, sin AOT. Documentar y cerrar el hito.
   - Build con expresiones y resultado distinto: sigue el plan completo.

### 0.2 Inventario del corpus
`tools/lottie_expr_inventory.nim`: recorre todos los `.lot` del repo (gate, upstream/test/res y cualquier corpus real que se quiera soportar) y emite CSV con, por expresión: fichero, propiedad, texto normalizado, identificadores globales usados, funciones llamadas y construcciones sintácticas (`var`, `if`, `for`, `while`, ternario, `function`, arrow, template string, regex, etc.).

### 0.3 Matriz de características
En `docs/lottie-expressions-notes.md`: una fila por característica, con ejemplo, frecuencia en el corpus, fase que la implementa y estado. Punto de partida (a verificar contra el corpus y contra ThorVG, no asumir):
- Operadores del exportador: `$bm_rt`, `$bm_sum`, `$bm_sub`, `$bm_mul`, `$bm_div`, `$bm_mod` (el exportador de bodymovin reescribe `a + b` sobre vectores como llamadas a estas funciones y deja el resultado en `$bm_rt`).
- Entorno: `time`, `value`, `thisComp`, `thisLayer`, `thisProperty`, `index`, `frameDuration`.
- Interpolación: `linear`, `ease`, `easeIn`, `easeOut`, `clamp`.
- Vectores: `add`, `sub`, `mul`, `div`, `length`, `normalize`, `dot`, `cross`.
- Tiempo: `valueAtTime`, `velocity`, `speed`, `key`, `numKeys`, `nearestKey`, `loopIn`, `loopOut`, `posterizeTime`.
- Aleatoriedad: `wiggle`, `random`, `gaussRandom`, `noise`, `seedRandom`.
- Referencias: `layer(...)`, `comp(...)`, `effect(...)`, `content(...)`, `toComp`, `fromComp`.
- Matemáticas y conversiones: `Math.*`, `degreesToRadians`, `radiansToDegrees`, color (`rgbToHsl`, `hslToRgb`).
- Rutas y texto: `createPath`, `sourceText`, `sourceRectAtTime`.
- Construcciones de lenguaje: `var`/`let`, `if`, ternario, `for`, `while`, funciones y closures, arrays, `try`.

**Hecho cuando:** hay decisión escrita sobre `audio_layer`, inventario commiteado (como CSV o resumen), matriz completa y D1/D2 cerradas.
**Para y reporta si:** el build de referencia no puede compilarse con expresiones y hace falta una referencia distinta (eso reabre D1).

## Fase 1: oráculo de expresiones
- Harness C++ `dump_expr`: por cada propiedad con expresión y frame, volcar `{layer, propPath, frame, value:[...]}` en JSONL. Si el parche necesita acceder a estructuras internas, hacerlo sobre una copia del árbol bajo `#ifdef EXPR_DUMP`.
- Generador `gen_expr_cases.py` (análogo a `gen_compose_cases.py`): `.lot` mínimos con una capa nula y una expresión sobre `position` u `opacity`, un caso por característica, más un caso base sin expresión para la prueba de sensibilidad.
- Con ello se fija también si el cálculo intermedio es `float64` o `float32`.
**Hecho cuando:** dos ejecuciones dan JSONL idéntico, ningún caso es insensible (valor distinto de su base) y la precisión numérica está documentada.
**Para y reporta si:** el volcado no es determinista o una característica de la matriz no puede aislarse en un caso mínimo.

## Fase 2: biblioteca de runtime
- `Val` y operaciones (escalares, vec2/3/4, color, arrays) con las reglas de coerción de JS que la matriz declare soportadas.
- Funciones de interpolación, vectores, `Math`, conversiones.
- Tests: tabla de casos del oráculo de la Fase 1 evaluados llamando directamente a la biblioteca, con tolerancia explícita.
**Hecho cuando:** todos los casos de biblioteca coinciden con el oráculo.

## Fase 3: frontend (lexer y parser)
- Lexer y parser de Pratt para el subconjunto ES5 que la matriz exija. Inserción automática de `;` y literales numéricos incluidos.
- Diagnósticos con línea y columna. Construcciones fuera del subconjunto: error explícito con nombre de la construcción.
- Tests: AST de referencia por expresión del corpus, más casos negativos (`with`, `eval`, regex, clases, `async`).
**Hecho cuando:** el 100 % de las expresiones del corpus en alcance parsea y el resto falla con diagnóstico claro y registrado en la matriz.

## Fase 4: lowering y emisor (núcleo)
- Subconjunto: `$bm_*`, `time`, `value`, `Math`, `linear/ease*`, `clamp`, ternario, `var`, `if`, funciones simples, vectores.
- `exprc` genera `expr_pack_*.nim` y el registro por hash; el loader lo consulta y aplica la política de expresión no compilada.
- Guarda de iteraciones en `while`/`for` generados (límite configurable, error estructurado si se supera).
**Hecho cuando:** los casos sintéticos del núcleo pasan contra el oráculo y `audio_layer` pasa (si la Fase 0 mostró que la evaluación es necesaria). El gate no regresa y el XFAIL sale de la lista.

## Fase 5: referencias y contexto
- `thisComp.layer(...)`, `thisLayer`, `thisProperty`, `effect(...)`, `content(...)`, `index`, `valueAtTime`, `key`, `numKeys`, `nearestKey`.
- Resolución al cargar, grafo de dependencias, detección de ciclos.
**Hecho cuando:** casos sintéticos de referencias pasan, incluido un ciclo que debe fallar con error estructurado.

## Fase 6: tiempo y aleatoriedad
- `loopIn/loopOut` (cycle, pingpong, offset, continue), `posterizeTime`, `velocity`, `speed`.
- `wiggle`, `random`, `noise`, `gaussRandom`, `seedRandom` según D3.
**Hecho cuando:** pasan contra el oráculo, o la paridad estadística queda definida y documentada si D3 eligió no replicar el generador.

## Fase 7: rutas y texto (solo si el corpus lo pide)
`createPath`, `sourceText`, `sourceRectAtTime`. Si ninguna expresión del corpus en alcance las usa, esta fase se marca "fuera de alcance, error estructurado".

## Fase 8: rendimiento
Inferencia de tipos para eliminar el boxing de `Val`, elevación de constantes, medición contra la línea base. Sin cambios de comportamiento: el oráculo debe seguir pasando.

## Fase 9: cierre
Documentación (`docs/lottie-expressions-notes.md`, `migration/STATUS.md`), CI que regenera los packs y falla si hay diff, y tabla final de características soportadas, rechazadas y fuera de alcance.

## Riesgos
- **AOT frente a carga dinámica:** un Lottie nuevo con expresiones necesita un paso de compilación antes de usarse. Es la consecuencia directa de eliminar el intérprete; D2 la hace explícita.
- **Semántica de JS:** igualdad con coerción, `undefined`, concatenación de cadenas frente a suma, redondeo de `Math.round` y números como `float64`. Cada una se cubre con un caso del oráculo antes de implementarla.
- **Divergencia ThorVG frente a After Effects:** se sigue a ThorVG (D1) y se anota en la matriz.
- **Alcance:** el lenguaje de expresiones es amplio. El inventario del corpus es lo único que decide qué entra; sin evidencia de uso, no se implementa.

## Criterio de aceptación global
- `audio_layer` resuelto según la Fase 0 (PASS con o sin evaluación, o XFAIL con motivo actualizado).
- Cada característica en alcance pasa contra el oráculo de C++ con tolerancia explícita.
- Cero dependencias de JS en runtime y en toolchain.
- Sin regresiones en el gate ni en `test_text_compose`.
