## 🔴 RPi 5 sin GPU: un LLM local NO puede servir crons de Hermes (22-sep-2026)

## Contenido

- El numero: 10 tok/s de prompt-eval
- Por que eso mata el caso de uso
- Y hay un segundo motivo, independiente del tamano
- Que si tiene sentido en la RPi
- Ajustar la RAM del servicio de embeddings (RPi, sin GPU)
- Higiene tras la prueba
- Pitfall propio: `pkill -f <script>` se suicida
- Pitfall: forzar `num_ctx` alto en CPU multiplica el trabajo
- El PC no va "fatal": Bonsai 27B responde en 2,1 s (medido el mismo dia)


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
