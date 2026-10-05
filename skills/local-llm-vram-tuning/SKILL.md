---
name: local-llm-vram-tuning
description: Use when un LLM local va lento o no cabe en la GPU.
category: devops
tags: [ollama, llm-local, gpu, vram, benchmark, moe, rendimiento]
---

# Ajustar un LLM local a una GPU con poca VRAM

Para cuando alguien dice **"los modelos locales van lentos"** o pide **"uno mas
inteligente que siga yendo fluido"**.

Metodologia validada el 17-sep-2026 sobre una RTX 4060 Laptop (8 GB) con Ollama
en Windows. Los numeros de ejemplo son de esa maquina; el **orden de diagnostico
y las reglas de decision** son generales.

Detalle completo y transcripcion de medidas:
`references/vram-tuning-playbook.md`.
Benchmark listo para ejecutar: `scripts/bench-ollama.ps1`.
Si el agente falla con **"Context length exceeded (N tokens)"** y N es absurdo:
`references/agente-no-responde-diagnostico.md` (arbol de diagnostico + los dos
descartes que costaron la sesion).
Si el stack local lo arranca un icono del escritorio (instancia unica, probar el
lanzador sin consola): `references/desktop-launcher-single-instance.md`.
Si el trabajo lo ejecuta el agente de la maquina destino y tu supervisas
(invocacion no interactiva, auditar su informe, ajustar su SOUL/MEMORY):
`references/delegar-encargos-a-otro-agente.md`.
Si la pregunta es **"que procesos me estan comiendo la VRAM"** y hay que dar un
desglose por proceso (nvidia-smi NO lo da en Windows):
`references/auditoria-vram-por-proceso.md` — sondas de solo lectura, ya
probadas, y la interpretacion de cada una.

---

## La regla que ordena todo

**Casi nunca es el modelo.** Antes de descargar nada o tocar quantizaciones,
descartar en este orden las dos causas que salen gratis:

1. VRAM secuestrada por un proceso huerfano
2. Contexto sobredimensionado que expulsa los pesos de la GPU
3. **Cache de prompt desbordado** (no cuesta VRAM, cuesta segundos: ver abajo)
4. (solo entonces) eleccion de modelo

En el caso real, 1 y 2 explicaban toda la lentitud. El modelo no tenia la culpa.
En la auditoria del **21-sep-2026** la VRAM estaba impecable — 0 huerfanos — y
la lentitud era **entera** del punto 3. Si 1 y 2 salen limpios, no concluir
"esta todo bien": queda una causa mas y es la menos conocida.

---

## 1. VRAM secuestrada (mirar esto primero, siempre)

**Sintoma delator: van lentos TODOS los modelos, incluso los pequenos que
siempre cupieron.** Si el de 4B tambien se arrastra, no es el modelo.

```powershell
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

Con VRAM ocupada "en reposo", comprobar si el proceso de inferencia tiene padre:

```powershell
Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" |
  Select-Object ProcessId, ParentProcessId
```

- **Padre vivo** = normal. Con `OLLAMA_MAX_LOADED_MODELS=2` es esperable ver
  **dos** procesos de inferencia: son dos modelos cargados a la vez.
- **Padre inexistente** = huerfano. Sobrevivio a un reinicio del servidor y
  retiene su VRAM indefinidamente. Matarlo.

Caso real: un `llama-server.exe` huerfano retenia **5.925 de 8.188 MiB**.
Quedaban ~2 GB, asi que todo se derramaba a CPU.

### 🔴 Matiz que casi cuesta caro: lanzado por el planificador = huerfano NORMAL

Un proceso arrancado con `schtasks /run` aparece **sin padre** porque el
lanzador ya termino. Eso **no** es una fuga. Medido el 21-sep-2026: el servidor
de inferencia principal figuraba huerfano y estaba perfectamente sano.

Lo que decide no es el padre, es **si responde**: `GET /v1/models` -> 200 y el
puerto escuchando. Matar por "huerfano" sin cruzar con el puerto tumba el
fallback del usuario.

### 🔴 En Windows `nvidia-smi` NO da los MiB por proceso: devuelve `[N/A]`

Medido el 21-sep-2026. Con el driver WDDM, esto **no sirve para el desglose**:

```
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
pid, process_name, used_gpu_memory [MiB]
3488, C:\bonsai\bin\llama-server.exe, [N/A]      <- inutil
```

Da los PIDs (util) pero **no cuanto consume cada uno**. Si te quedas aqui, no
puedes responder "de quien son mis 6,6 GB". Lo que SI funciona son los
contadores de rendimiento de Windows:

```powershell
(Get-Counter "\GPU Process Memory(*)\Dedicated Usage").CounterSamples |
  Where-Object { $_.CookedValue -gt 1MB } | Sort-Object CookedValue -Descending |
  ForEach-Object {
    $id = 0; if ($_.InstanceName -match "pid_(\d+)") { $id = [int]$matches[1] }
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    "{0,8:N0} MiB  {1} (pid {2})" -f ($_.CookedValue/1MB), $(if($p){$p.Name}else{"?"}), $id
  }
```

Salida real, y con esto ya se contesta la pregunta del usuario:

```
   7.193 MiB  llama-server (pid 3488)   <- el modelo grande
     571 MiB  llama-server (pid 7940)   <- los embeddings, dentro de Ollama
       4 MiB  System (pid 4)            <- el escritorio
```

**Dos contadores, no uno.** `Dedicated Usage` = VRAM fisica. `Shared Usage` =
RAM del sistema por PCIe, o sea **derrame**. Cualquier cifra en `Shared` de un
proceso de inferencia es una fuga de rendimiento que `ollama ps` no enseña.

**Filtrar por RUTA, nunca por nombre.** Ollama trae su propio
`llama-server.exe`; con dos stacks conviviendo hay procesos homonimos y
confundirlos lleva a matar el equivocado:
`Get-Process llama-server | Where-Object { $_.Path -like "C:\bonsai\*" }`.

### GPU al 100% no es una anomalia: mira QUE engine

Ver `utilization.gpu = 100 %` en reposo asusta y casi siempre tiene una
explicacion legitima. Antes de tocar nada, separar por engine y confirmar si
hay una peticion real en vuelo:

```powershell
(Get-Counter "\GPU Engine(*)\Utilization Percentage").CounterSamples |
  Where-Object { $_.CookedValue -gt 0.5 } | Sort-Object CookedValue -Descending
# engtype_3d      -> navegador / escritorio / overlay
# engtype_compute -> inferencia de verdad
```

Y preguntarle al servidor si esta trabajando (llama.cpp):
`GET /slots` -> `is_processing=True` + `n_prompt_tokens`.

El 21-sep-2026 el 100% era **el propio usuario preguntandole al agente** —
5.980 tokens generandose en ese instante. Diagnosticar "GPU saturada" sin
comprobarlo habria sido un falso positivo con recomendacion de apagar cosas.

**Cuidado al diagnosticar "esta duplicado":** varios procesos no implican varios
servidores. Contar cuantos escuchan el puerto (`Get-NetTCPConnection -LocalPort
11434`) y cuantos mecanismos de arranque hay (tarea programada + clave `Run` +
carpeta Inicio) antes de afirmarlo. En el caso real la sospecha de duplicado era
falsa; el huerfano si era real.

---

## 2. Contexto que expulsa al modelo de la GPU

El KV cache compite con los pesos por la misma VRAM:

```
bytes_KV = contexto x capas x kv_heads x head_dim x 2 x bytes_por_valor
```

Para un 8B tipico, pasar de **64K a 16K de contexto** libero ~1,8 GB y cambio
el reparto de 87% a 100% en GPU: generacion **+36%**, prompt eval **+74%**.

Un contexto de 64K "por si acaso" es caro. Dimensionar al uso real.

### 🔴 PERO hay un SUELO: el prompt del agente. Recortar de mas lo MATA

**Corregido el 17-sep-2026 tras una averia causada por esta misma seccion.**
La recomendacion de bajar a 16K era correcta para la VRAM y **catastrofica**
para el agente: el prompt de sistema de Hermes **no cabia**.

```
hermes prompt-size  ->  28 KB system + 59 KB de esquemas (45 tools) = 87 KB ~ 22K tokens
OLLAMA_CONTEXT_LENGTH=16384   ->  el prompt MINIMO ya desborda
```

Sintoma, y es engañoso de narices: **cualquier** consulta muere con

```
Context length exceeded (496 tokens). Cannot compress further.
```

Ese numero ridiculo (496, luego 514, luego 515) es el **mensaje del usuario**,
no la ventana. Comprimir no puede bajar del prompt de sistema, asi que falla
"sin poder comprimir mas" con un mensaje de dos lineas.

Lo peor es **cuando** se manifiesta: mientras el modelo remoto responda, nadie
lo nota. Solo al caer la cascada al local — justo el dia que hace falta — muere
el agente entero, CLI incluida.

**Regla dura:**

```
OLLAMA_CONTEXT_LENGTH  >=  2 x (prompt-size del agente en tokens)
```

Medir el suelo antes de elegir el numero, **no** poner el minimo que evite el
derrame:

```powershell
hermes prompt-size        # bytes totales / ~4 = tokens
```

En la maquina real: 32768. Y comprobar que **sigue cabiendo** despues de subirlo
(`ollama ps` debe seguir diciendo `100% GPU`). Si subir el contexto al suelo
minimo provoca derrame, el modelo es demasiado grande para esa GPU — se cambia
el modelo, no se baja el contexto por debajo del suelo.

> **Un fallback que no cabe no es una red de seguridad, es un fallo silencioso
> con fecha diferida.** Optimizar VRAM sin comprobar el suelo del consumidor es
> como ganar espacio quitando el airbag.

---

## 3. El cache de prompt: la palanca que NO cuesta VRAM

**Descubierto el 21-sep-2026 y es el hallazgo mas rentable de esa sesion.**
Aplica a `llama-server` (llama.cpp). El sintoma que lo delata: *"a veces tarda
una eternidad en empezar a responder y otras va rapido"*, con la VRAM perfecta
y 100% en GPU.

`llama-server` cachea los prompts ya procesados **en RAM del sistema**, no en
VRAM. El limite por defecto es `--cache-ram 8192` (MiB). Cuando se llena,
expulsa la entrada mas vieja, y ese aviso esta en su log:

```
W srv alloc: - making room for prompt cache entry, removing oldest entry (size = 1844.243 MiB)
```

Cada expulsion significa que la **siguiente vez que vuelvas a esa conversacion
hay que reprocesar el prompt entero**. Medido en la maquina real:

```
prompt eval time = 172.87 s / 43.344 tokens  (250 tok/s)   <- cache expulsado
prompt eval time =   3.86 s /    790 tokens                <- cache vivo
```

**173 segundos de espera antes de la primera palabra**, y no por falta de VRAM.

Diagnostico en una linea:

```powershell
(Get-Content "C:\ruta\server.err.log" | Select-String "making room for prompt cache").Count
```

- **0** = el cache aguanta, no tocar.
- **>0** = cada una de esas es un reprocesado futuro. Subir `--cache-ram`.

Dimensionarlo con la RAM **libre**, dejando margen holgado (medido: 16,2 GB
libres de 32 -> `--cache-ram 12288` deja ~4 GB de colchon). Coste en GPU: cero.

> Las entradas pesan mucho mas de lo que uno supone: de 455 a **1.844 MiB** por
> conversacion con 64K de contexto. Con 8 GB de cache caben muy pocas sesiones
> largas, y un agente con memoria y muchas tools las genera a diario.

**Contexto grande = entradas de cache grandes.** Subir `-c` no solo sube el KV
en VRAM: multiplica lo que ocupa cada conversacion cacheada en RAM. Las dos
palancas van juntas; ajustar una sin mirar la otra deja el trabajo a medias.

Otras opciones utiles de `llama-server` para esto (verificar con `--help` en la
version instalada, cambian entre builds): `--cache-reuse N` (reaprovecha trozos
via KV shifting), `--cache-idle-slots`, `--slot-save-path`.

---

## 4. Eleccion de modelo: MoE gana a denso en cuanto no cabes

Un MoE solo activa una fraccion de sus parametros por token, asi que **el tamano
en disco deja de predecir la velocidad**. Medido en 8 GB de VRAM:

| Modelo | Tipo | Disco | en GPU | gen t/s |
|---|---|---|---|---|
| `gemma4:12b` | **denso** 12B | 7,6 GB | 70% | **15,9** (inviable) |
| `gemma4:26b-a4b-it-qat` | **MoE** 26B/4B act. | 15 GB | 32% | **45,7** |
| `qwen3.6:35b-a3b` | **MoE** 35B/3B act. | 22 GB | 23% | **40,8** |

Un MoE de 26B que ocupa **el doble en disco corre 3x mas rapido** que un denso
de 12B. Un denso derramado paga RAM por *todos* sus pesos; un MoE derramado solo
paga por los expertos que toca.

**Regla: por encima de lo que quepa comodo en VRAM, elegir MoE antes que denso.**

### Matiz importante: eso vale para CABER, no para ELEGIR delegacion

Re-medido **en caliente** (2a pasada) el 17-sep-2026, el MoE perdio contra el
denso que cabe entero:

| Modelo | gen t/s | prompt t/s | Reparto |
|---|---|---|---|
| **9B denso Q4 (cabe)** | **42,9** | **1425** | **100% GPU** |
| 9B denso alternativo | 35,9 | 1210 | 14% CPU |
| MoE 26B-a4b (15 GB) | 38,8 | 175 | **68% CPU** |

Y en calidad, la prueba que de verdad separo no fue velocidad ni tool-calling
(los tres llamaron la herramienta correcta eligiendo entre 3 opciones), sino
**razonar sobre entrada larga**: un log de 60 lineas OK + 1 ERROR real.

```
9B denso ... detecto la causa real                  <- unico que acerto
MoE 26B .... invento "memory leak" (no era)
otro 9B .... invento "la latencia crece" (no era)
```

**Las medidas en frio mienten**: la tabla anterior daba el MoE a 45,7 t/s porque
incluia la carga y no miraba el derrame. Siempre 2 pasadas, y siempre junto a la
columna `PROCESSOR` de `ollama ps`.

> Con poca VRAM: **lo que cabe entero gana a lo que es mas grande.** El MoE solo
> gana cuando el denso equivalente TAMPOCO cabe.

### El precio del MoE: prompt eval

| | gen t/s | **prompt eval t/s** |
|---|---|---|
| 9B denso que cabe entero | 51,7 | **564** |
| MoE 26B al 32% en GPU | 45,7 | **75** |

Generar va parecido; **procesar la entrada es ~7x mas lento**. Por eso conviene
**conservar los dos**: el MoE para razonamiento, un denso pequeno para trabajo
de mucha entrada (resumir ficheros, comprimir conversacion).

---

## Contraintuitivo verificado: forzar `num_gpu` EMPEORA

"Sobra VRAM sin usar, meto mas capas a mano" es falso en Windows:

| `num_gpu` | en GPU | gen t/s |
|---|---|---|
| auto | 33% | **35,4** |
| 20 capas | ~60% | 16,0 |
| 34 capas | 100% | **5,9** |

**6x peor al "cargarlo entero".** Al superar la VRAM fisica Windows no falla:
desborda a *shared GPU memory*, que es RAM del sistema por PCIe, mas lenta que
ejecutar esas capas en CPU.

**No tocar `num_gpu` salvo que se mida una mejora**, y desconfiar de cualquier
guia que lo recomiende a ciegas. En Linux sin memoria compartida puede diferir:
medir, no extrapolar.

Tampoco sirvio recortar contexto en el MoE (33% en GPU con 16K, 8K y 4K por
igual): el limite eran los pesos, no el cache. **Si mover una palanca no mueve
el resultado, la causa esta en otro sitio** — identificar cual de los dos
consume antes de optimizar.

---

## Benchmark honesto (dos trampas que invalidan el resultado)

### Desactivar el "thinking" o el test miente

Los modelos de razonamiento gastan `num_predict` entero en su bloque de
pensamiento y devuelven **0 caracteres** visibles. Parece un modelo roto y es un
test roto. En Ollama: `"think": false` en el cuerpo de `/api/generate`.

### Medir el reparto GPU/CPU, que es lo que explica todo

`GET /api/ps` -> `size_vram / size` por modelo. Sin ese dato un resultado lento
no se sabe interpretar; con el, el diagnostico es inmediato.

Tokens/s desde la propia respuesta, no con cronometro:
`eval_count / (eval_duration / 1e9)`.

### Medir inteligencia, no solo velocidad

Un modelo rapido que razona mal no sirve. Preguntas con respuesta **verificable
programaticamente**, y **dificiles**: en la primera tanda 3 de 5 modelos sacaron
4/4 y no separo nada.

La que mejor discrimino fue de estado, no de conocimiento:

> "Tengo 3 manzanas. Ayer comi 2. Cuantas tengo hoy?" -> **3**

Un 9B respondio **1** (resto lo de ayer); los MoE de 26B y 35B acertaron. Ese
fallo no aparecia en ninguna metrica de velocidad.

---

## 🔴 RPi 5 sin GPU: un LLM local NO puede servir crons de Hermes (22-sep-2026)

Peticion recurrente del usuario: *"pongo un 3B en la RPi para los crons y me quito
DeepSeek"*. **Medido en su RPi 5 (8 GB, 4 nucleos, sin GPU): no es viable, y el
numero que lo zanja es uno solo.**

### El numero: 10 tok/s de prompt-eval

`ollama` en la RPi va **100% CPU** (columna `PROCESSOR` de `ollama ps`), y ahi
no manda la generacion, manda **leer el prompt**:

| Modelo | prompt-eval | generacion |
|---|---|---|
| `qwen2.5-coder:3b` | **10,0 tok/s** | 7,4 tok/s |
| `qwen3.5:4b` | **6,6 tok/s** | 1,6-2,9 tok/s |

Escalera medida con coder:3b (tres tamanos, para probar que es lineal y no un
artefacto de carga — `load_duration` fue 0,2 s en todas):

```
   63 tok ->   6,1 s
  899 tok ->  94,9 s
2.659 tok -> 261,9 s
```

### Por que eso mata el caso de uso

El suelo de Hermes es innegociable y se mide, no se estima:

```
hermes prompt-size  ->  26.660 B system + 43.197 B tool schemas = 69.857 B ~ 17.500 tok
```

**17.500 tok / 10 tok/s = 1.750 s = 29 minutos SOLO para leer el prompt**, antes
de generar el primer caracter y **en cada llamada al modelo**. Un cron agentico
hace 5-20 llamadas (una por tool call), asi que un job que hoy tarda 8 minutos
pasaria a **horas**. Con 25 crons LLM y 514 ejecuciones/mes, no cabe en el dia.

> **En CPU el cuello de botella es el prompt, no el modelo.** Elegir "un modelo
> mas pequeno" no arregla nada: el 4B fue *mas lento* que el 3B y ambos estan a
> ~1-2 ordenes de magnitud de lo necesario. No es un problema de afinado.

### Y hay un segundo motivo, independiente del tamano

La RPi esta **termicamente limitada**: durante la inferencia marco
`temp=81.8'C` y `vcgencmd get_throttled` -> **`0xe0000`** (throttling activo).
Los 10 tok/s son la cifra *ya recortada*, y la RPi ademas corre los otros 93
crons `no_agent`, Caddy, el sitio y el pipeline de trading: quemar los 4
nucleos al 100% durante horas degrada todo lo demas.

```bash
vcgencmd measure_temp      # >80 C durante inferencia
vcgencmd get_throttled     # 0x0 = sano; cualquier otro valor = recortando
uptime                     # load 4,3-5,6 sobre 4 nucleos = saturada
```

**Comprobar el throttling ANTES de medir velocidad en una RPi**, o se atribuye
al modelo una lentitud que es del hardware.

### Que si tiene sentido en la RPi

- **Embeddings**, que son una pasada unica y corta. En esta RPi los hace
  `ollama-embed.service` (unidad de usuario, solo `bge-m3`, 1024 dim) para la
  memoria mem0/Qdrant: **no se puede parar ni cambiar de modelo sin reindexar**.
  Los otros modelos de embeddings (`nomic-embed-text`, `all-minilm`) sobraban y
  se pueden borrar con `ollama rm`.
- Nada mas. Para chat/crons, la RPi es **cliente de API**, no servidor de
  inferencia.

### Ajustar la RAM del servicio de embeddings (RPi, sin GPU)

Lo que se regula es cuanto tiempo retiene el modelo cargado
(`OLLAMA_KEEP_ALIVE` en la unidad), no si existe. bge-m3 cargado ocupa ~1,3 GB
mas ~0,4 GB del servidor. Decidir el valor con datos, no a ojo:

1. Sacar las horas de `POST /api/embed` de `journalctl --user -u ollama-embed`
   (48 h) y calcular los huecos entre llamadas.
2. Para cada candidato K: `tiempo_cargado = sum(min(hueco, K))` y
   `cargas_en_frio = n.o de huecos > K`.
3. Medir latencia en frio vs caliente: `ollama stop <modelo>` y 3 llamadas
   seguidas (la primera paga la carga, ~3 s; las siguientes ~0,3-0,6 s).

Elegir el K que libera RAM la mayor parte del dia sin que la primera consulta
tras un hueco moleste (una memoria conversacional tolera 3 s). Pasar los
embeddings a una API externa saca el texto de los recuerdos de la maquina:
solo vale la pena si la RAM aprieta de verdad y el usuario acepta esa fuga.

### Higiene tras la prueba

Los modelos de prueba se borran (`ollama rm`). Si el servicio de Ollama no era
el permanente de embeddings (`ollama-embed.service`), **`ollama serve` se para
si no estaba corriendo antes**: dejarlo vivo retiene RAM sin dar nada. Verificar
con `pgrep -af "ollama serve"` y `du -sh ~/.ollama`; nunca parar el de embeddings.

### Pitfall propio: `pkill -f <script>` se suicida

`pkill -f bench.py` dentro del mismo comando que luego ejecuta el heredoc **mata
el propio shell** (la cadena casa con su propia linea de comando): el resultado
fue `exit_code -15` y cero salida, dos veces seguidas. Matar por **PID**
(`kill <pid>`) o separar en dos llamadas.

### Pitfall: forzar `num_ctx` alto en CPU multiplica el trabajo

La primera tanda con `num_ctx=16384` no completo **ni un prompt de 2 KB en 13
minutos**. Con el contexto por defecto del modelo, el mismo prompt salio en
95 s. En CPU, reservar contexto que no se usa se paga en cada pasada — no es
como en GPU, donde solo cuesta VRAM.

### El PC no va "fatal": Bonsai 27B responde en 2,1 s (medido el mismo dia)

el usuario dijo *"el bonsai 27 va fatal"* y propuso sustituirlo por un 9B. **La queja
es real pero la causa no es la velocidad.** Medido en su PC:

```
POST /v1/chat/completions "Di solo la palabra PONG", max_tokens=16
-> OK en 2,09 s | prompt=58 compl=16 | content: ""        <- VACIO
```

7.195 MiB de VRAM, 0 evictions de cache de prompt, prompt eval a 277,8 tok/s.
El problema es que **`--reasoning-budget 2048` gasta los `max_tokens` en el
bloque de pensamiento y devuelve 0 caracteres visibles** — el mismo artefacto
que documenta la seccion "Desactivar el thinking o el test miente", pero aqui
sucede **en produccion**, no solo en el benchmark.

> "Va fatal" + modelo que responde rapido = **mirar si devuelve contenido
> vacio** antes de proponer cambiar de modelo. Sustituir el 27B por un 9B no
> habria arreglado nada y habria perdido calidad.

---

## Variables de entorno que importan (Ollama)

En Windows, a nivel de **usuario** y **reiniciando el servidor** para que las lea.

| Variable | Valor | Por que |
|---|---|---|
| `OLLAMA_CONTEXT_LENGTH` | **`32768`** | ver el SUELO arriba: 16384 mata al agente |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | mejor calidad que q4_0 si el contexto es sano |
| `OLLAMA_FLASH_ATTENTION` | `1` | requisito para cuantizar el KV cache |
| `OLLAMA_MAX_LOADED_MODELS` | `2` | MoE + modelo rapido a la vez |
| `OLLAMA_KEEP_ALIVE` | `24h` | evita recargar en cada peticion |

`OLLAMA_CONTEXT_LENGTH` no es un numero libre: tiene **suelo** (el prompt del
agente) y **techo** (la VRAM). Si no hay hueco entre los dos, cambiar de modelo.

---

## Si el servidor deja de arrancar tras tocar variables

Una variable con un valor invalido no se ignora: **tumba el servidor al
arrancar**, antes de abrir el puerto. Pasa con `OLLAMA_ORIGINS`, que exige que
cada origen lleve esquema (`http://`, `file://`...). Un valor sin `://` — por
ejemplo `null` — produce `panic: bad origin` y crash-loop.

El sintoma **enganna**: el lanzador dice que todo fue bien (`schtasks` responde
"CORRECTO"), el ejecutable existe en su ruta, y el codigo de resultado apunta a
"fichero no encontrado". Nada de eso es la causa.

Diagnostico que si funciona — capturar stderr y **leer las PRIMERAS lineas**:

```powershell
Start-Process -FilePath $exe -ArgumentList "serve" -WindowStyle Hidden `
  -RedirectStandardError "$env:TEMP\ollama_err.log"
Start-Sleep 8
Get-Content "$env:TEMP\ollama_err.log" -TotalCount 25
```

**El stack trace de Go tapa la causa si solo miras el final.** La linea `panic:`
va arriba del todo; las 20 siguientes son ruido.

Revertir = **borrar** la variable, no "corregirla":
`[Environment]::SetEnvironmentVariable("NOMBRE", $null, "User")`.

**Antes de anadir una variable, comprobar si el valor por defecto ya cubre el
caso.** En el episodio real `file://*` ya venia permitido: la variable sobraba
*y* rompia. Anadir configuracion para arreglar un problema inexistente es como
se fabrican averias reales.

### Comprobar el problema como lo ve el consumidor real

El error que motivo aquel cambio era un artefacto del test: se probo la API con
una cabecera de origen que el navegador no usa. Un cliente HTTP de terminal
**ignora CORS por completo**, asi que da por buenas APIs que en navegador fallan
— y tambien al reves. Reproducir con las mismas cabeceras que mandaria el
consumidor de verdad antes de declarar nada roto.

**El caso concreto, porque el matiz es la trampa entera** (Ollama, 17-sep-2026):

| `Origin` enviado | Ollama | Quien lo manda de verdad |
|---|---|---|
| `null` | **403** | **Chrome al abrir un `file://`** |
| `file://` | 200 | nadie |
| `http://localhost:8765` | 200 | el navegador si sirves por HTTP |

Un panel HTML abierto con doble clic manda `null` y Ollama lo rechaza. Se
verifico con `file://`, dio 200, y se dio por bueno algo que el usuario abrio y
vio en rojo. **La cabecera plausible no es la cabecera real**: averiguar cual
manda el cliente, no cual parece razonable.

Corolario de diseno: un panel local que consulta APIs **se sirve por
`http://localhost`** (un `http.server` de la libreria estandar basta), no se
abre como fichero. Asi el origen es real y CORS deja de ser un problema.

> Y no se arregla ampliando la lista de origenes permitidos del servidor: eso
> fue lo que lo tumbo (ver seccion anterior). Se arregla dandole al navegador
> un origen legitimo.

---

## Cerrar bien: higiene tras los benchmarks

Probar modelos grandes deja decenas de GB. En la sesion real la limpieza libero
**47,1 GB**. Al terminar una tanda:

- `ollama rm` de cada modelo descartado, dejando constancia de **la razon medida**
  (velocidad, aciertos, o que no cabe).
- Borrar scripts subidos al host remoto y temporales locales.
- Reinicio limpio y comprobar **0 MiB de VRAM en reposo**: las pruebas de
  `num_gpu` dejan procesos con memoria tomada.
- Conservar backup del `config.yaml` anterior al cambio.

## Al cambiar el modelo en la config del agente

Respetar el rol de cada modelo. Si el usuario fijo un primario (p. ej. un modelo
web de suscripcion), **el modelo local nuevo va a delegacion o failover, nunca
desplaza al primario**. Verificar la config despues de escribirla y reportar los
tres roles (primario / delegacion / auxiliares) para que se vea que el primario
sigue intacto.

---

## Operar en caliente: NO cortar al usuario para "optimizar"

Casi todo lo de esta skill exige **reiniciar el servidor de inferencia**. Si el
usuario esta preguntandole al agente en ese momento, reiniciar le mata el turno
y pierde la respuesta. Un arreglo que rompe el trabajo en curso no es un
arreglo.

Comprobar SIEMPRE antes de reiniciar (llama.cpp):

```powershell
$s = Invoke-RestMethod "http://127.0.0.1:8080/slots" -TimeoutSec 8
foreach ($x in $s) { if ($x.is_processing) { "OCUPADO" } }
```

Patron que funciona, y hay que montarlo **dentro** del script de cambio:

1. Sondear el slot en bucle con un tope (p. ej. 5 min).
2. Si sigue ocupado -> **abortar con rc propio (9) sin tocar nada**. Abortar es
   el exito, no el fallo.
3. Si queda libre -> backup del launcher, reescribir, reiniciar, y **verificar
   los argumentos del proceso VIVO** (`Win32_Process.CommandLine`), no que el
   fichero contenga el flag.
4. Si no arranca -> restaurar el backup y relanzar, en el mismo script.

Y para la espera larga sin bloquear la conversacion: lanzar un proceso en
segundo plano en la maquina de control que espere el hueco y aplique el cambio
solo, con su propio log. Reportarle al usuario el diagnostico ya, y los numeros
del cambio cuando lleguen — no hacerle esperar 40 minutos a la respuesta.

> El paso 3 es el que separa un cambio real de uno imaginario: reescribir el
> launcher y reiniciar **no garantiza** que el proceso vivo tenga el flag
> (guard de idempotencia que aborta, tarea que no relanza, backup restaurado a
> medias). Leer el `CommandLine` del PID real cierra esa duda.

---

## Cuando la VRAM sale LIMPIA: que se responde

Pasa, y es un resultado valido. Si no hay huerfanos ni desperdicio, **decirlo
sin adornos** y seguir buscando la causa real — no inventar una optimizacion
para tener algo que entregar.

Antes de proponer borrar nada, comprobar que no se use:

- Modelo de embeddings: `ollama ps` da su VRAM, pero la prueba de uso esta en
  el vectorial (`GET :6333/collections/<n>` -> `points_count`). Con recuerdos
  guardados dentro, ese modelo **no se toca**.
- Modelos en disco: si sobran cientos de GB, borrarlos no es una optimizacion.
  Decir que no urge en vez de listarlo como tarea.

Y lo que de verdad sobra suele estar **fuera del stack de IA** (navegadores con
overlay comiendo `engtype_3d`, entradas de arranque cuyo proceso no existe).
Eso se **propone**, no se ejecuta: son cosas del usuario.

---

## Como reportarlo

el usuario no tiene formacion tecnica: la conclusion va en lenguaje llano y **el
numero medido al lado**. "Va un 36% mas rapido (32 -> 43,7 t/s)" comunica; "se
ha optimizado el pipeline de inferencia" no.

Orden que funciona: **cual era el problema real** -> que se cambio -> tabla
antes/despues -> que modelo queda en cada rol.

Y confesar los errores propios con su diagnostico. En esta sesion una variable
mal puesta tumbo Ollama; contarlo (que paso, como se encontro la causa, como se
revirtio) vale mas que ocultarlo, porque el usuario audita y compara con otras
IAs. Un informe que solo trae exitos es el que deja de creerse.

