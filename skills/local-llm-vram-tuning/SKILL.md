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

## Detalle en references/ (leer solo si aplica)

- [1. VRAM secuestrada (mirar esto primero, siempre)](references/1-vram-secuestrada.md)
- [2. Contexto que expulsa al modelo de la GPU](references/2-contexto-que-expulsa-al-modelo-de-la-gpu.md)
- [🔴 RPi 5 sin GPU: un LLM local NO puede servir crons de Hermes (22-sep-2026)](references/rpi-5-sin-gpu-un-llm-local-no-puede-servir-crons-d.md)

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

