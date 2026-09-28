---
name: typesafe-jev
description: "Use when decides con regex fragil o LLM caro."
metadata:
  hermes:
    tags: [devops, ia, decisiones]
---

# Jev / TypeSafe System One en esta maquina

Modelo de **decision**, no de lenguaje. No genera texto: devuelve tipos con
probabilidad calibrada. Complementa a los LLM, no los sustituye.
Usar cuando una decision se toma hoy con keywords, un regex fragil o una
llamada cara a un LLM que solo tiene que clasificar, puntuar o enrutar.

## Credenciales y endpoint (verificado 21-sep-2026)

La key vive en `~/.hermes/.env` (chmod 600) como `TYPESAFE_API_KEY`.

```bash
curl -X POST https://api.typesafe.ai/v1/systemone \
  -H "Authorization: Bearer $TYPESAFE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"jev-latest","state":"...","questions":{...}}'
```

- Via OpenRouter seria `POST https://openrouter.ai/api/alpha/decisions` con
  modelo `~typesafe/jev-latest`, pero **el saldo esta agotado**. Usar la key propia.
- `POST /v1/chat/completions` **NO existe** para Jev: da 404/400.
- Precio: $0.042/Mtok de ENTRADA, **salida gratis**. Contexto 64k por peticion
  (32k para `state` + la pregunta mas larga). Limites: 250k tok/s, 1.200 req/min.

## Las 3 primitivas

| Tipo | Para que | Devuelve |
|---|---|---|
| `choice` | elegir 1 de una lista cerrada | `choice`, `probabilities`, `confidence` |
| `score` | posicion en una rubrica ORDENADA | `score` (decimal), `legend`, `confidence` |
| `noul` | si/no | `noul` 0-1. **NO trae `confidence`** |

```python
questions = {
  "seccion": {"type":"choice", "instructions":"...",
              "criteria": {"IA":"descripcion", "GADGETS":"descripcion"}},
  "urgencia": {"type":"score", "instructions":"...",
               "criteria": ["nivel 0", "nivel 1", "nivel 2"]},   # LISTA ordenada
  "es_spam":  {"type":"noul", "instructions":"afirmacion a juzgar"},
}
```

## Reglas de diseno que SI cambian el resultado

1. **Preguntas atomicas.** "Analiza esto y decide que hacer" da basura. Partir
   en juicios de un segundo y combinar EN CODIGO con pesos propios.
2. **Todas las preguntas en UNA peticion.** Se evaluan en paralelo, no se ven
   entre si y apenas suben la latencia. El cookbook oficial mide 13 preguntas
   juntas = 12,2x mas barato y 10x mas rapido que 13 llamadas sueltas.
3. **Preguntas especulativas casi gratis.** Preguntar de mas y que el codigo
   ignore lo que no aplica sale mejor que encadenar llamadas.
4. **`state` estructurado.** Objeto JSON con campos con nombre, y apuntar a
   ellos desde `instructions` con ruta entre backticks:
   `` `ticket.messages[0].text` ``
5. **Umbrales segun riesgo.** `confidence < 0.5` = no actuar. Para acciones
   destructivas exigir >0.9. Se calibran con datos propios, no se copian.

## PITFALLS pagados aqui

**El `state` debe ser un EVENTO COMPLETO, nunca un fragmento.** Primer intento
de triaje de logs: parti los tracebacks linea a linea y le pedi decidir sobre
`^^^^^^^^`. Resultado: 0 averias, 0 ruido, inservible. Agrupando por evento
(timestamp abre, continuaciones se pegan) acerto a la primera. La IDENTIDAD de
un traceback es su ULTIMA linea (la excepcion), no la primera.

**Un umbral sin control negativo es humo.** Al subir un umbral para callar
ruido, verificar que las averias REALES conocidas SIGUEN alertando. Probado
con las 3 verificadas a mano antes de dar el umbral por bueno.

**El idioma importa.** La doc oficial dice que el ingles es el idioma primario.
Escribir `instructions` y `criteria` en INGLES aunque el `state` sea espanol.

**`noul` no tiene `confidence`.** `a["x"]["confidence"]` sobre un noul revienta
con KeyError. Solo `choice` y `score` la traen.

**Un `except Exception: return` SILENCIOSO convierte un bug en "funciona".**
Al integrar en `trend-detector.py` faltaba `from pathlib import Path`: el except
se tragaba el NameError, Jev NO corria NUNCA y el script seguia dando rc=0.
Solo se vio contando cuantos items traian campos de Jev (1 de 43). En el
fallback, **loguear siempre el tipo de excepcion**, nunca callar.

**Colocar el refinado DONDE el resultado no se pise despues.** Primer intento:
lo puse dentro de `rank_trends()`, pero el social bonus recalculaba `hot_score`
mas tarde y borraba la penalizacion. Y la correccion de seccion debia ir ANTES
del reparto por secciones o no tenia efecto. Verificar el ORDEN del pipeline,
no solo que la funcion se llame.

**Verificar contando EFECTO, no rc=0.** `rc=0` con 1 item procesado de 43 es un
fallo. La metrica correcta: cuantos objetos de la salida traen campos de Jev.

## Donde NO usarlo

- Redaccion, resumenes, traduccion, digests -> no genera texto.
- **Trading / dinero real del usuario** -> clasificador general sin edge de
  mercado. Hay un caso publico de -$30.000 con un bot Jev.
- Sustituir al LLM de un agente de codigo -> la propia doc lo desaconseja en
  la pagina `coding-agents`: no es un modelo de chat ni de completado.

## Patron GATE: el unico ahorro real de tokens (100%)

El coste de un cron con agente NO son los datos que lee: son los TURNOS.
Medido aqui: una traza de 200 tool calls con solo 175 KB de datos facturo
2,3M tokens, porque cada turno reenvia el contexto acumulado. Recortar 10 KB
de datos no mueve la aguja; **evitar que el agente arranque, si**.

Hermes soporta `monitor` en un cron: un script que corre en cada tick y cuya
salida se hashea. Salida identica -> el agente NO arranca (0 tokens). Salida
distinta -> arranca con el diff inyectado.

Jev decide QUE entra en esa huella: solo lo accionable de verdad.

```python
# cronjob(action='update', job_id=..., monitor='jev-gate-X.py')
# OJO: el path debe ser RELATIVO a ~/.hermes/scripts/, solo el nombre.
```

### Reglas duras de un gate (las tres se pagaron con bugs)

1. **Determinismo o no ahorra nada — y un umbral UNICO nunca lo da.** Los noul
   de Jev oscilan +-0.03-0.06 entre ejecuciones del mismo input. Con un solo
   umbral, cualquier item que caiga en esa banda entra y sale en cada tick ->
   hash nuevo -> el gate no ahorra NADA. **Elegir otro umbral no arregla
   nada: solo mueve el problema de sitio**, porque en datos reales la
   distribucion es continua (medido en el gate de knowledge: 16 de 30 titulares
   entre 0.28 y 0.57, o sea encima de cualquiera de los umbrales probados).
   **La solucion es HISTERESIS de dos umbrales** (Schmitt):
   `ENTRA si s >= 0.50 | SIGUE si ya estaba y s > 0.30`.
   Un item en la zona gris no cambia la huella. Entrar cuesta una senal clara;
   salir cuesta que caiga de verdad. El estado previo se lee del MISMO fichero
   contra el que hashea el scheduler (`monitor_last_output.txt`), no de un
   estado propio que pueda divergir.
   Medir los dos margenes (entrada sobre el ruido, salida sobre la oscilacion)
   antes de fijarlos, y probar el invariante **por secuencia de pases**: con el
   mismo input y 3 conjuntos de puntuaciones reales congelados, la huella de la
   secuencia tiene que ser identica.
2. **La PREGUNTA importa mas que el umbral.** "is a CONCRETE improvement that
   would change a file" dio 0.28 a "Hermes 7901 commits por detras" (falso
   negativo sobre la unica propuesta real). Reformulada a "is worth spending
   engineering time on" -> 0.90. Comparar 3 redacciones contra casos
   etiquetados y quedarse con la del HUECO mayor entre senal y ruido:
   `hueco = min(accionables) - max(ruido)`. Aqui: +0.38 / +0.69 / **+0.85**.
3. **FAIL-OPEN, al reves que el resto.** Si Jev cae, emitir la huella cruda
   para que el agente ARRANQUE. Un gate que falla hacia el silencio deja el
   sistema ciego; eso es peor que gastar tokens. (En guards y filtros es al
   contrario: ahi fail-closed.)

### Verificacion obligatoria antes de enchufar un gate

```bash
# 1. determinismo: 4 runs, salida identica
for i in 1 2 3 4; do python3 gate.py > /tmp/g$i.txt; done; diff /tmp/g1.txt /tmp/g4.txt
# 2. control negativo: una novedad REAL conocida DEBE pasar el gate
# 3. fail-open: con API_URL invalida debe imprimir MODO=crudo, no callar
```
Saltarse el 2 es como tuve el gate de knowledge bloqueando cambios legitimos
de Search Console y AdSense con umbral 0.75.

**Y ademas, el unico veredicto que vale: cuantos TICKS ha suprimido.** Un gate
puede ser determinista en el laboratorio y no ahorrar nada en produccion (input
que cambia entre ticks, umbral en la banda). Contarlo asi:

```bash
grep -l "no_change (agent run suppressed)" ~/.hermes/cron/output/<job>/*.md | wc -l
ls -1 ~/.hermes/cron/output/<job>/*.md | wc -l     # -> suprimidos / ticks
```

**NO usar `executions.db` para esto.** Esa tabla solo registra los ticks que
ARRANCARON el agente (`completed`/`failed`: los unicos estados que existen); un
tick suprimido no genera fila. Una consulta ahi devuelve `suprimidos=0`
siempre — un contador estructuralmente incapaz de medir lo que promete. Paso
asi en `jev-ahorro-report.py`: reportaba **0 tokens de ahorro** mientras los
outputs decian 3/7 y 3/6 suprimidos (**9,44M tokens** reales en 4 dias).

> Regla: si un medidor propio da siempre el mismo veredicto, el bug es del
> medidor. Antes de creerlo, contar la misma magnitud por una via independiente
> (aqui: los ficheros de output) y comparar los dos numeros.

## En produccion en esta maquina

| Pieza | Que hace | Enganchado a |
|---|---|---|
| `scripts/jev_client.py` | cliente comun: key, reintentos, fail-closed | lo importan los de abajo |
| `scripts/jev_triage.py` | triaje semantico de errors.log | `check_error_log()` de `daily-silent-check.py` (cron <cron-id>, 8:20 y 15:20) |
| `improvement-triage.py::clasificar_con_jev()` | 2a opinion sobre el veredicto por keywords | `triage()`, rama arxiv-/gh-/hermes-commits |
| `trend-detector.py::refinar_con_jev()` | penaliza clickbait + corrige seccion | `main()`, tras el social bonus |
| `jev-gate-learning.py` | GATE: evita arrancar el cron mas caro | `monitor` del cron <cron-id> (2,3M tok/run) |
| `jev-gate-knowledge.py` | GATE: evita arrancar el knowledge feed. Umbrales con HISTERESIS (0.50/0.30) desde 25-sep-2026: con umbral unico de 0.40 suprimia 3 de 24 ticks | `monitor` del cron <cron-id> (866k tok/run) |
| `scripts/tests/suite_monitor_gates.py` | contract test de los 3 gates (34 checks): huella estable, histeresis con puntuaciones REALES congeladas, fail-open | `run-suite-canal.py` -> `invariant-guard.py` cada 6 h |
| `jev-gate-content.py` | GATE: cuota aritmetica + Jev filtra tendencias | `monitor` del cron <cron-id> (3,2M tok/run) |
| `jev-gate-nucleo.py` | GATE: NÚCLEO (Opus 5.5) solo arranca si cambia cola / incidente real (Jev noul>=0.6) / feed / inventario / freeze / estado AdSense. Reloj de seguridad: corre al menos cada 3 dias. Fail-open con hora | `monitor` del cron <cron-id> (25-sep-2026) |
| `jev-skill-router.py` | sugiere ≤1 skill del catálogo (2 llamadas: skim + verify) | a mano / integrable en el prompt |
| `jev_email.py` | rescata de la papelera lo accionable | `fetch_recent_emails()` de `email-pruner.py` (cron <cron-id>) |
| `jev-ahorro-report.py` | mide el ahorro REAL contra baseline congelado | a mano |

**Los crons usan deepseek, NO claude.** Claude es el chat interactivo. Los
500M tokens del log son de DeepSeek: el ahorro de los gates es de DeepSeek.

Resultados medidos (25-sep-2026, via corregida tras arreglar el medidor):
- Ahorro REAL acumulado: **9,44M tokens** en 4 dias (learning 3/8 ticks,
  knowledge 3/7). El informe previo decia 0 por el bug de `executions.db`.
- El gate de content suprime desde el 23-sep (cuota 0 congelada) sin fallar.
- El gate de learning suprime 1 de cada 2 ticks (patron estable 3 dias:
  05:00 suprimido, 16:00 arranca). Mecanismo medido: `run-improvement-loop.sh`
  (cron <cron-id>, 07:00) rellena `improvement-pending.json`, el tick de las
  16:00 ve propuestas nuevas y arranca, y al resolverlas la cola queda a 0
  (`propuestas: 0` a las 17:17 tras el run de las 16:06) -> el tick de las 05:00
  reemite la huella y suprime. Es un cambio de DATO legitimo, no de umbral: la
  histeresis no lo arregla y no hay que tocar el filtro por eso.
  Antes de mover un umbral, preguntar si el texto cambia porque cambio el
  PROBLEMA o porque cambio el DATO.

Resultados medidos (21-sep-2026):
- errors.log: 3 averias reales encontradas, una llevaba 2 dias rota en silencio.
- improvement-triage: keywords 5/7 -> keywords+Jev 7/7 en los casos historicos.
- trend-detector: 6/14 secciones corregidas, 3 clickbait penalizados.
- Coste: ~$0.02 por cada 1.000 items. Centimos al mes.

Diseno obligatorio para cualquier integracion nueva: **fail-closed en silencio**.
Si no hay key, no hay red o la API falla -> devolver vacio y NO tumbar al guard
anfitrion. Un extra que revienta su host cambia 3 bugs detectados por 1 guard
muerto.

Y **watermark siempre**: sin dedupe, la misma averia habla en cada ejecucion y
vuelve ignorable la alerta, y con ella las reales.

## Version fijada (25-sep-2026)

`jev_client.py` y `jev_triage.py` usan `MODEL = "jev-1.13.0"`, no `jev-latest`.
La doc oficial (`/models.md`) avisa de que el alias cambia de modelo sin aviso;
con umbrales calibrados (histeresis 0.50/0.30, confidence) hay que fijar version
y migrar a mano: re-ejecutar `tests/suite_monitor_gates.py` (34 checks) y los
controles negativos ANTES de subir de version. Backups `*.bak-20260925`.

## Siguiente integracion con mas valor (evaluada 25-sep-2026)

Cookbook oficial `citation_check`: verificar que las afirmaciones de un articulo
estan respaldadas por su fuente (string match en codigo + 1 Choice
supports/contradicts/unrelated, confidence >=0.8 o revision). Encaje: ultimo paso
antes de publicar en el pipeline editorial LFI. Pendiente de OK del usuario.
`jev-skill-router.py` existe pero NO esta enganchado al harness (solo a mano).

## Alternativa local Laya (evaluada 27-sep-2026): NO cabe hoy en la RPi

`pip install laya` (0.3.20) + torch 2.14 CPU en venv `~/.hermes/cache/scratch/laya-venv`;
checkpoints en `~/.cache/huggingface` (english 0,84 GB + multilingual = 1,5 GB).
Durante la precarga (english 421M + multilingual 322M, fp32) la RAM `available`
cayo de ~4.400 a 1.134 MB (swap ya en 3,3 GB) -> abortado por el limite de
1.200 MB antes de terminar de cargar; no se aislo cual de los dos la tumbo. En un
intento previo (preload=True) ya se vio 1.165 MB. No llego a medirse
precision ni latencia. Banco listo en `~/.hermes/cache/scratch/laya-bench/bench.py`
(email 6 casos, gate knowledge 30 titulares, errors.log 30 firmas, Laya vs Jev en vivo).
Pitfalls: el primer arranque descarga con timeout y deja blobs `*.incomplete`
huerfanos (borrarlos); pre-descargar con `snapshot_download(allow_patterns=...)` en
background y medir despues con `HF_HUB_OFFLINE=1`. El checkpoint trae temperaturas
invalidas (warning: confidence de choice sin calibrar).

## La doc viva manda

`https://docs.typesafe.ai/llms.txt` es el indice y la fuente de verdad.
Mintlify sirve markdown anadiendo `.md` a cualquier ruta:
`https://docs.typesafe.ai/concepts/how-to-build-with-system-one.md`.
Antes de disenar un flujo nuevo, leer el cookbook mas parecido: suele proponer
una descomposicion mejor que un clasificador generico.
