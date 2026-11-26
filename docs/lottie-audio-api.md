# API de metadatos de audio para Lottie (nota de diseño)

Destino sugerido: `docs/lottie-audio-api.md`.

## Decisión
La reproducción de audio queda **fuera del núcleo**. ThorVG-Nim es un motor de render. No se añade SDL ni ningún backend de audio. Sí se expone una API pequeña, pura y opcional con los metadatos que un host necesita para sincronizar sonido con la animación.

## No objetivos
- Decodificar audio (mp3, wav, ogg).
- Mezclar o abrir dispositivos de audio.
- Gestionar el ciclo de vida del sonido.

## Qué debe garantizar el núcleo (obligatorio, incluso sin la API)
- El parser **no falla** con capas de audio ni con assets de audio.
- Las capas de audio quedan en el modelo (no se descartan en silencio).
- Verificar y documentar qué hace C++ 1.2.0 con ellas (si las parsea, las salta o las trata como capas nulas), para que Nim no sea ni más estricto ni más laxo.
- Las expresiones sobre el nivel de audio siguen la política de expresiones (ver `AGENTS-expressions-aot.md`).

## Estructuras (propuesta)

```nim
type
  AudioSourceKind* = enum
    askPath      # ruta o URL relativa al documento
    askEmbedded  # bytes embebidos (data URL en el asset)

  AudioSource* = object
    kind*: AudioSourceKind
    path*: string          # askPath
    data*: seq[byte]       # askEmbedded (ya decodificado de base64)
    mime*: string          # si el asset lo indica; vacío si no

  AudioCue* = object
    layerIndex*: int
    name*: string
    source*: AudioSource
    startFrame*: float     # ip de la capa, en frames de la composición
    endFrame*: float       # op
    mediaOffsetFrames*: float   # st: desplazamiento del medio respecto a la composición
    stretch*: float        # sr: factor de velocidad (1.0 = normal)
    hasLevelAnimation*: bool
```

## Funciones (puras, sin estado global)

```nim
proc audioCues*(anim: LottieAnimation): seq[AudioCue]

proc cueActiveAt*(cue: AudioCue; frame: float): bool
  ## true si frame está en [startFrame, endFrame).

proc mediaPositionSec*(cue: AudioCue; frame: float; fps: float): float
  ## Posición dentro del medio, en segundos, aplicando mediaOffsetFrames y stretch.

proc audioLevel*(anim: LottieAnimation; cue: AudioCue; frame: float): tuple[left, right: float]
  ## Ganancia lineal por canal evaluada en `frame` (incluye animación y, si aplica,
  ## expresiones). Conversión de dB a lineal documentada en una sola función.
```

Los campos de Lottie en que se apoya (nivel `au.lv`, assets de audio con ruta o dato embebido) **deben verificarse contra `tvgLottieParser.cpp` y contra un `.lot` real** antes de fijar las estructuras. Esta nota los asume por la especificación, no por el código.

## Modelo de sincronización
- El reloj maestro lo lleva el host, idealmente el del audio. El host calcula `frame = timeSec * fps` y llama al render con ese frame; consulta los cues para saber qué reproducir y desde qué posición.
- **Seek:** el host recalcula la posición de cada cue activo con `mediaPositionSec`.
- **Loop:** al reiniciar la animación, el host reinicia los cues. La API no guarda estado.
- **Velocidad:** el host aplica su propio factor de velocidad; `stretch` de la capa se combina con él en `mediaPositionSec`.

## Empaquetado
- `src/thorvg/lottie/audio.nim`: sin dependencias externas.
- `examples/sdl_audio_sync.nim`: ejemplo opcional y fuera del build por defecto, que usa SDL_mixer o miniaudio. Documenta el uso, no forma parte del núcleo.

## Tests
- Parseo de `audio_layer.lot`: número de cues, tiempos, fuente y nivel en frames conocidos.
- `cueActiveAt` en los bordes (`startFrame`, `endFrame - ε`, `endFrame`).
- `mediaPositionSec` con `mediaOffsetFrames` distinto de cero y con `stretch` distinto de 1.
- Documento sin audio: `audioCues` devuelve una secuencia vacía.

## Cuándo implementarlo
Solo cuando exista un consumidor real. Hasta entonces: tres tareas baratas (verificar C++, garantizar que el parser no falla, anotar esta decisión). La API completa se escribe cuando alguien la use.
