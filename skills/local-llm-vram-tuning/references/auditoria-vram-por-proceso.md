# Auditar "de que son mis N GB de VRAM" — sondas de solo lectura

Caso de origen: **21-sep-2026**, RTX 4060 Laptop 8 GB (Windows 11, PC remoto de
el usuario). Pregunta literal: *"tengo 6,6 GB de VRAM ocupados y no se de que
procesos son"*. Todo lo de aqui es **solo lectura** y seguro de ejecutar con el
agente trabajando.

## Orden de sondas

### 1. Cuanto hay ocupado en total

```powershell
nvidia-smi --query-gpu=memory.used,memory.free,memory.total --format=csv,noheader
# 7764 MiB, 193 MiB, 8188 MiB
```

### 2. Quien lo ocupa — **el paso que casi todo el mundo hace mal**

```powershell
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

En Windows/WDDM la columna de memoria sale **`[N/A]`**. Sirve para obtener los
PIDs y las rutas, no para el desglose. El desglose real:

```powershell
$ded = (Get-Counter "\GPU Process Memory(*)\Dedicated Usage").CounterSamples |
        Where-Object { $_.CookedValue -gt 1MB } | Sort-Object CookedValue -Descending
foreach ($s in $ded) {
  $id = 0; if ($s.InstanceName -match "pid_(\d+)") { $id = [int]$matches[1] }
  $p = Get-Process -Id $id -ErrorAction SilentlyContinue
  "{0,8:N0} MiB  {1} (pid {2})" -f ($s.CookedValue/1MB), $(if($p){$p.Name}else{"?"}), $id
}
```

Cambiar `Dedicated Usage` por `Shared Usage` da el **derrame a RAM por PCIe**.
Medido en el caso real: el modelo grande tenia 222 MiB ahi. No es critico, pero
es la prueba de que va justo de VRAM.

### 3. Distinguir proceso legitimo de huerfano

```powershell
$p = Get-CimInstance Win32_Process -Filter "ProcessId=3488"
Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)"
$p.CommandLine   # <- imprescindible: dice QUE modelo y con que flags
```

⚠️ **Trampa:** un proceso lanzado por `schtasks` aparece como **huerfano**
(padre inexistente) y es perfectamente normal — el padre fue el lanzador, que
ya termino. Huerfano **no** implica fuga. Lo que decide es: ¿escucha su puerto y
responde? Si `GET /v1/models` da 200, esta vivo y en uso.

En esta auditoria el `llama-server.exe` del modelo principal figuraba sin padre
y estaba **perfecto**. Concluir "huerfano, matalo" habria tumbado el fallback
del usuario. Cruzar siempre con el puerto antes de acusar.

### 4. Separar procesos con el mismo nombre

Ollama trae **su propio `llama-server.exe`**. Con dos stacks conviviendo hay dos
procesos homonimos. Filtrar por **ruta**, nunca por nombre:

```powershell
Get-Process llama-server | Where-Object { $_.Path -like "C:\bonsai\*" }
```

### 5. Quien escucha cada puerto

```powershell
foreach ($port in 8080,11434,6333,9119) {
  $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($c) { $op = Get-Process -Id $c[0].OwningProcess; "puerto $port -> $($op.Name) (pid $($op.Id))" }
  else { "puerto $port -> LIBRE" }
}
```

### 6. ¿Esta trabajando la GPU o es un falso positivo?

```powershell
(Get-Counter "\GPU Engine(*)\Utilization Percentage").CounterSamples |
  Where-Object { $_.CookedValue -gt 0.5 } | Sort-Object CookedValue -Descending
```

`engtype_3d` = navegador/escritorio. `engtype_compute` = inferencia. Y la
confirmacion definitiva en llama.cpp: `GET /slots` ->
`is_processing=True, n_prompt_tokens=59456`.

En el caso real el 100% de GPU era el usuario preguntandole al agente en ese
mismo momento. Sin esta sonda, el informe habria dicho "GPU saturada" y habria
recomendado apagar cosas que no sobraban.

### 7. Antes de proponer borrar nada: comprobar si se usa

- Embeddings: `ollama ps` da la VRAM, pero **la prueba de uso es el vectorial**:
  `GET http://127.0.0.1:6333/collections/<nombre>` -> `points_count`. Con 118
  puntos guardados, ese modelo de 571 MiB **no se toca**.
- Modelos en disco: `ollama list` + espacio libre. Si sobran cientos de GB,
  borrar modelos viejos no es una optimizacion, es ruido.
- Un modelo **declarado** en `custom_providers` no esta en uso: hay que mirar
  que rol lo referencia (`model.default`, `fallback_providers`, `delegation`,
  `auxiliary`). Declarado sin rol = 0 MiB de VRAM.

### 8. Lo que sobra de verdad suele estar FUERA del stack de IA

```powershell
Get-CimInstance Win32_StartupCommand | Select-Object Name, Command
Get-ScheduledTask | Where-Object { $_.TaskPath -notmatch "Microsoft" -and $_.State -ne "Disabled" }
```

Hallazgos reales del 21-sep-2026:

- Un navegador con **19 procesos, 2,1 GB de RAM y 14,6% de GPU (`engtype_3d`)
  constante** sin usarse — el unico competidor real de la GPU.
- Un `.bat` en la carpeta Inicio cuyo proceso **no existia**: arranque roto que
  no hacia nada. Detectado comparando la lista de arranque con los procesos
  vivos, no leyendo la lista sola.

## Como cerrar el informe

El usuario pregunto "de que son mis GB". La respuesta es **la tabla de MiB por
proceso con el nombre en llano de para que sirve cada uno**, y decir
explicitamente cual NO hay que tocar y por que ("los embeddings guardan tus 118
recuerdos"). Si la VRAM esta limpia, decirlo sin adornos — y entonces buscar la
causa real de la lentitud en el cache de prompt, que es lo que paso aqui.

Lo que se propone apagar (navegador, arranques rotos) se **propone**, no se
ejecuta: son cosas del usuario, no del stack.
