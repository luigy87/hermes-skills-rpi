# Forensics del ciclo de vida del gateway Hermes — sesion 29/30-ago-2026

Detalle de la sesion que origino la skill `process-state-forensics`. Tres
fallos encadenados, todos de la misma clase: **el estado reportado no era el
estado real**.

## Contexto

Tras una sesion de hardening el 29-ago, el sistema presentaba a la vez:
sudo inutilizable, el gateway muriendo por SIGKILL en cada reinicio, y turnos
de 10-12 minutos. Parecian tres problemas; eran tres capas del mismo error de
verificacion.

## Fallo 1 — sudo roto por `NoNewPrivileges` implicito

**Sintoma:** `sudo: The "no new privileges" flag is set, which prevents sudo
from running as root`. Caian `unified-health-monitor.py`,
`indexing-integrity-check.py` y `seo_chain.py` (todos recargan Caddy).

**Por que fallaron 3 intentos previos:** se retiro `NoNewPrivileges=true` del
drop-in y se verifico con `systemctl show` — que reportaba `no`. El proceso
vivo seguia con `NoNewPrivs: 1`.

**Medicion (probe `--user`, una directiva por vez):**

| Directiva | NoNewPrivs |
|---|---|
| baseline | 0 |
| `PrivateTmp=true` | 0 |
| `RestrictNamespaces=true` | 1 |
| `RestrictRealtime=true` | 1 |
| `LockPersonality=true` | 1 |
| `RestrictAddressFamilies=...` | 1 |

Probe adicional con las 4 restrict **mas** `NoNewPrivileges=no` explicito:
`systemctl show` -> `no`; `/proc/self/status` -> `NoNewPrivs: 1`;
`sudo -n systemctl is-active caddy` -> `SUDO_ROTO`.

**Fix:** drop-in reducido a `PYTHONSAFEPATH=1` + `PrivateTmp=true`. La
contencion de privilegios la aporta `/etc/sudoers.d/011_hermes-granular`
(6 comandos), que no rompe nada.

**Verificacion post-reinicio:** `NoNewPrivs=0`, `sudo -n` OK,
`sudo -n cat /etc/shadow` sigue denegado, `autonomy-guard.sh` en silencio.

## Fallo 2 — SIGKILL confundido con OOM

**Sintoma:** `exited UNCLEANLY (no exit path ran — SIGKILL / OOM / VM death)`
en `gateway.lifecycle_ledger`. La sesion se perdia: el usuario lo vivio como
"se te cayo".

**Descarte de OOM — el propio mensaje del ledger lo dice:**
```
suspected_oom=False
last_mem={'rss_kib': 254544, 'mem_available_kib': 4635040, ...}
```
254 MB de RSS y 4,6 GB disponibles. No era memoria.

**Senal decisiva:** el SIGKILL caia **exactamente a los 90 s** del `systemctl`,
dos veces el mismo dia (13:44 y 14:42). `TimeoutStopSec` era 90 s. Un numero
redondo repetido es un temporizador.

**Fix:** `TimeoutStopSec=180` en el drop-in (la unidad la regenera Hermes al
arrancar, asi que editarla no sirve).

**Verificacion:** el reinicio de las 00:37 del 30-ago fue el primero del dia
sin `status=9` ni `UNCLEANLY` en el journal.

**Ajuste derivado:** con SIGKILL resuelto seguia apareciendo
`Gateway drain timed out after 60.1s with 1 active agent(s)` — el turno en
curso se interrumpia. `agent.restart_drain_timeout` subido de 60 s a 120 s,
dentro de los 180 s de systemd, dejando 60 s de margen para browser + MCP +
crons.

## Fallo 3 — turnos de 10-12 minutos (compresion de hygiene)

**Sintoma:** 5 ocurrencias de
`made no progress for 0.0s (total wait 629.9s, ceiling 600.0s); continuing
without compression`, con respuestas de 700-750 s.

**Hallazgo estructural:** `gateway/run.py` resuelve
`_hyg_model = model.default`. El hygiene **pre-turno** corre contra el modelo
PRINCIPAL; `auxiliary.compression` (deepseek, sano) solo lo usa el compresor
interno del agente. El hygiene hereda los limites del proveedor principal.

**Contencion aplicada:**
```bash
hermes config set compression.hygiene_total_ceiling_seconds 120
hermes config set compression.hygiene_failure_cooldown_seconds 1800
```
El techo por defecto de 600 s bloqueaba el turno 10 minutos antes de rendirse.

## Dos diagnosticos propios que resultaron FALSOS

Se documentan porque el error de razonamiento es reutilizable:

### Falso 1 — "el limite es el contexto total"

Medido que un mensaje individual >~30k tokens contra `qwen.aikit.club` devuelve
stream vacio (`finish_reason:"stop"`, `delta:{}`, HTTP 200, 0 tokens). Se
concluyo que la ventana era 30k y se puso `model.context_length: 30000`.

**Refutado con la prueba correcta:** el mismo volumen REPARTIDO funciona.

```
~30k en 1 msg              -> 211 chars OK
~32k en 1 msg              -> 0 chars VACIO
~60k en 41 mensajes        -> 155 chars OK
~440k en 301 mensajes      -> 155 chars OK
```

El limite es **por mensaje individual**, no por contexto total. El override se
revirtio.

### Falso 2 — "`last progress 0.0s` significa stream vacio"

Al reves. `CompressionCommitFence.touch_progress()` resetea el contador con
**cada token**, asi que `0.0s` significa que los tokens SI estan fluyendo. Un
stream colgado daria un idle **creciente**.

Comprobacion independiente: DeepSeek resume un transcript real de 101k tokens
en 18,3 s (ttfb 1,3 s). El proveedor no estaba colgado.

### Falso 3 (secundario) — revertir con `set ""`

Al revertir el override se uso `hermes config set model.context_length ""`, que
deja `context_length: ''`. Resultado: `Invalid model.context_length in
config.yaml: '' — must be a plain integer` **en cada turno**. Correcto:
`hermes config unset model.context_length`, verificando que
`grep -c context_length config.yaml` da 0.

## Otros hallazgos de la auditoria

- **`articles-staleness`**: umbral de 30 dias sobre un sitio evergreen con 402
  articulos -> `rc=1` cada lunes -> escalada a LLM por nada. Subido a 180 dias;
  el check pasa en seco.
- **`GITHUB_TOKEN` PAT clasico (`ghp_*`)**: no soportado por la Copilot API,
  generaba 4 WARNING por arranque. Su unico consumidor estaba en
  `scripts/legacy/DELETED-2026-08-10/`. Comentado en `.env`.
- **Prueba negativa de watchdog**: `lfi-generator-integrity.sh` se valido
  inyectando el fichero retirado (`fix_sitemap_lastmod.py`) — detecta — y
  retirandolo — vuelve al silencio. Un watchdog callado no es un watchdog
  verificado.

## Estado final verificado

87 crons activos / 0 en error · 102 skills / 0 referencias rotas · 4 servicios
activos · sudo OK con root bloqueado · `autonomy-guard` en silencio · web 200 ·
mitigacion de Rehberger vigente (probada con y sin flag).

## Leccion de fondo

El hardening del 29-ago subio el score de `systemd-analyze` de 9.8 a 6.7 y a
cambio dejo sudo roto 10 horas y ~10 reinicios del gateway. **Una metrica de
seguridad que sube rompiendo el sistema es un fallo, no una mejora.** Cada
directiva se mide por lo que rompe, no por lo que puntua.
