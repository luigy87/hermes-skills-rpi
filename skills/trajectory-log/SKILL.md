---
name: trajectory-log
description: "Depurar un turno, cron o loop paso a paso con traj.py."
version: 1.0.0
author: "el usuario (via Hermes)"
metadata:
  hermes:
    tags: [devops, observability, debugging]
---

# Trajectory Log — el "Trajectory" de DeepSeek Harness, en Hermes

Usar cuando: un cron/loop falló o tardó de más, quieres ver qué hizo el agente
paso a paso, o auditar tokens/cache de una sesión.

Plugin propio (`~/.hermes/plugins/trajectory-log/`) que graba un log
append-only por sesión con todo lo observable de cada turno. Nació el
01-sep-2026 tras analizar DeepSeek Harness: su única ventaja real sobre
Hermes era la vista Trajectory. Esto la replica sin migrar nada.

## Uso (lo que vas a querer el 95% de las veces)

```bash
V=~/.hermes/hermes-agent/venv/bin/python3
$V ~/.hermes/scripts/traj.py                    # resumen de hoy por sesión
$V ~/.hermes/scripts/traj.py --days 3           # últimos 3 días
$V ~/.hermes/scripts/traj.py --errors --days 7  # SOLO tool calls que fallaron
$V ~/.hermes/scripts/traj.py --slow 10          # tools que tardaron > 10s
$V ~/.hermes/scripts/traj.py --cost             # tokens + % cache hit por sesión
$V ~/.hermes/scripts/traj.py --grep "texto"     # busca en args y resultados
$V ~/.hermes/scripts/traj.py --session <slug>   # timeline completo, paso a paso
```

Flujo de depuración: `--errors` para localizar → `--session <slug>` para ver el
timeline y entender qué pasó ANTES del fallo.

## Qué registra

`turn_start` / `turn_end` (modelo, provider, tokens, cache_hit, finish_reason,
duración) · `tool_start` / `tool_end` (args recortados, resultado, segundos,
ok/error) · `subagent_start` / `subagent_stop` · `session_end`.

Ficheros: `~/.hermes/trajectory/YYYY-MM-DD__<session>.jsonl`.

## Invariantes de diseño (NO romper)

1. **Solo observa.** Todos los callbacks devuelven `None`. En `pre_tool_call`,
   `None` = no bloquear ni modificar args. Devolver otra cosa convertiría el
   plugin en un guard y podría tumbar tools.
2. **Nunca lanza.** Cada hook va envuelto en `try/except Exception`. La
   observabilidad jamás rompe producción.
3. **`MAX_LINE_BYTES = 3500` debe quedar por debajo de PIPE_BUF (4096).** Ahí
   está la clave de la concurrencia: gateway, crons y subagentes son procesos
   distintos escribiendo el MISMO fichero. POSIX garantiza atomicidad de los
   `write()` en `O_APPEND` por debajo de PIPE_BUF, así que no hacen falta locks
   (`flock` habría serializado y añadido latencia al path de cada tool).
   Verificado con 6 procesos × 60 escrituras: 360 líneas, 0 corruptas.
   **Subir esa constante por encima de 4096 reintroduce líneas entremezcladas.**
4. **Acotado en disco**: recorte de args/result, tope de 25 MB por fichero,
   retención 14 días (limpieza oportunista, 1 vez por proceso).
5. **Redacta secretos** (`sk-…`, `Bearer …`, `api_key=…`) antes de escribir.

## Pitfalls verificados

- **El plugin solo carga al arrancar el gateway.** Tras activarlo, el
  directorio `trajectory/` sigue vacío hasta el restart. No es un fallo.
  Restart: `touch /tmp/hermes-gw-restart.flag` (el crontab lo recoge en ≤2 min).
- **Las firmas de los hooks vienen de `plugins/observability/langfuse/__init__.py`**
  del repo upstream — es el plugin de referencia que usa estos mismos hooks.
  Si un update cambia un kwarg, mirar ahí primero. Todos los callbacks aceptan
  `**_`, así que un kwarg nuevo no rompe nada.
- **Los hooks válidos están en `hermes_cli/plugins.py::VALID_HOOKS`.** Un hook
  mal escrito en `plugin.yaml` no da error: se ignora en silencio. El test
  compara `plugin.yaml` contra `register()` contra `VALID_HOOKS`.
- **`hermes plugins enable` pregunta por tool-override**: responder que NO.
  Este plugin no debe sustituir tools built-in.
- **🔴 Clasificar ok/error por TEXTO da falsos positivos (corregido 01-sep-2026)**:
  la v1 marcaba `ok=False` si el resultado contenía la subcadena `"error":`.
  Pero el tool `terminal` devuelve **siempre**
  `{"output":..., "exit_code":0, "error":null}` cuando va bien → **7 de 26
  llamadas sanas se marcaron como fallo** y `health-scan.py` alertó de una
  "tasa de error del 27%" que no existía. Fix: comprobar primero las señales
  **estructuradas** (`exit_code` y `error` parseando el JSON) y caer al
  heurístico textual solo si el resultado no es JSON. **Regla general: si el
  payload trae estado estructurado, se usa ese; el matching de subcadenas es
  el último recurso, no el primero.** Un detector con falsos positivos se
  acaba ignorando, que es justo lo que viene a evitar.

## Test

```bash
~/.hermes/hermes-agent/venv/bin/python3 ~/.hermes/scripts/test-trajectory-log.py
```

17 comprobaciones reales (sin mocks de filesystem), incluida la de concurrencia
multi-proceso y la de "nunca lanza con entradas basura". Debe dar `TODO OK`.
**Ejecutarlo después de cada `hermes update`** para confirmar que los hooks
siguen existiendo en la versión nueva.
