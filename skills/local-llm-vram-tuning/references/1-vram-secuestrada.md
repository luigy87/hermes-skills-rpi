## 1. VRAM secuestrada (mirar esto primero, siempre)

## Contenido

- 🔴 Matiz que casi cuesta caro: lanzado por el planificador = huerfano NORMAL
- 🔴 En Windows `nvidia-smi` NO da los MiB por proceso: devuelve `[N/A]`
- GPU al 100% no es una anomalia: mira QUE engine


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
