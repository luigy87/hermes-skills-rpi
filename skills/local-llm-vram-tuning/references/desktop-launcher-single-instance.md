# Lanzadores de escritorio: instancia unica y verificacion sin consola

Para cuando un icono del escritorio arranca un agente/servicio local y hay que
garantizar que **un doble clic no duplica nada** y que el lanzador **se puede
verificar desde una sesion remota sin consola**.

Encaja aqui porque el lanzador arranca el stack de LLM local (servidor de
inferencia + base vectorial) antes del chat: los mismos servicios que se
auditan al perseguir VRAM.

Episodio de referencia: 17-sep-2026, launcher de Hermes en Windows.

---

## 1. Que se duplica y que no (no asumir: medir)

Un lanzador tipico arranca varias piezas. Cada una tiene su propia proteccion
— o ninguna. Auditar **pieza por pieza**, no el lanzador entero:

| Pieza | Protegida por | Duplica? |
|---|---|---|
| Servicio via `schtasks /Run` | el propio planificador | **No**: responde "la tarea ya se esta ejecutando" |
| Servicio que escucha un puerto | el SO | **No**: un puerto = un listener |
| Proceso interactivo lanzado a pelo | nada | **Si** |

En el caso real los servicios estaban cubiertos por accidente y **solo el chat
interactivo se duplicaba**. La conclusion "todo esta protegido" habria sido tan
falsa como "nada lo esta".

Comprobacion empirica del planificador (lanzar dos veces a la vez y contar):

```powershell
$j1 = Start-Job { schtasks /Run /TN "MiTarea" 2>&1 | Out-String }
$j2 = Start-Job { schtasks /Run /TN "MiTarea" 2>&1 | Out-String }
Wait-Job $j1,$j2 -Timeout 30 | Out-Null
Receive-Job $j1; Receive-Job $j2
@(Get-Process -Name "miservicio" -ErrorAction SilentlyContinue).Count   # debe seguir en 1
```

Quien escucha cada puerto (garantia fisica de no duplicado):

```powershell
Get-NetTCPConnection -LocalPort 11434 -State Listen | Select-Object OwningProcess
```

**Ojo al diagnosticar "esta duplicado"**: varios procesos de inferencia no
implican varios servidores. Con `OLLAMA_MAX_LOADED_MODELS=2` es normal ver dos
`llama-server` con el mismo padre. Lo anomalo es uno **sin padre** (huerfano
reteniendo VRAM) — ver SKILL.md, seccion 1.

---

## 2. Mutex global: el candado para lo que si duplica

No un fichero de lock (queda huerfano si el proceso muere de golpe). Un **mutex
global**: Windows lo libera solo cuando el proceso desaparece.

```powershell
$global:MiMutex = New-Object System.Threading.Mutex($false, "Global\MiAppSingleInstance")
$tengoElCandado = $false
try { $tengoElCandado = $global:MiMutex.WaitOne(0, $false) } catch { $tengoElCandado = $true }

if (-not $tengoElCandado) {
    Write-Host "  Ya esta abierto en otra ventana." -ForegroundColor Yellow
    Start-Sleep -Seconds 4
    exit 0
}
```

Y liberarlo al final del script:

```powershell
try {
    if ($global:MiMutex) { $global:MiMutex.ReleaseMutex(); $global:MiMutex.Dispose() }
} catch {}
```

Detalles que importan:

- **`WaitOne(0, ...)`**, no `WaitOne()` sin argumentos: hay que devolver el
  control al instante, no esperar a que el otro cierre.
- **`try/catch` alrededor del `WaitOne`**: si otro usuario tiene el mutex salta
  `AbandonedMutexException`; tratarlo como "puedo entrar" es mejor que reventar.
- **Liberar solo el mutex, no los servicios.** El usuario cierra el chat, pero
  el servidor de inferencia, la base vectorial y los crons siguen. Matar
  servicios al salir rompe lo que corre en segundo plano — y ademas obliga a
  recargar modelos en la siguiente sesion.

---

## 3. Probar un candado = probar que RECHAZA

Verificar solo la rama feliz ("la primera instancia entro") **no prueba nada**:
un candado roto tambien deja entrar a la primera. Las tres ramas:

```powershell
# RAMA 1: la primera coge el candado
$m1  = New-Object System.Threading.Mutex($false, "Global\MiAppSingleInstance")
$ok1 = $m1.WaitOne(0, $false)          # debe ser True

# RAMA 2: la segunda, en OTRO proceso, debe ser rechazada
$job = Start-Job {
    $m2 = New-Object System.Threading.Mutex($false, "Global\MiAppSingleInstance")
    if ($m2.WaitOne(0, $false)) { $m2.ReleaseMutex(); "ENTRO (mal)" } else { "RECHAZADA (bien)" }
}
Wait-Job $job -Timeout 20 | Out-Null; Receive-Job $job

# RAMA 3: tras liberar, otra puede entrar (que no se quede pegado)
if ($ok1) { $m1.ReleaseMutex() }
# ...repetir el Start-Job: ahora debe decir ENTRO
```

La rama 2 **tiene que ir en otro proceso** (`Start-Job`): dentro del mismo
proceso el mutex es reentrante y siempre te deja pasar. Probarlo en el mismo
hilo da un falso OK.

La rama 3 detecta el fallo opuesto y peor: un candado que no se libera deja al
usuario sin poder abrir **nunca mas**.

---

## 4. Verificar un lanzador desde SSH (sin consola)

Una app interactiva de terminal **no puede arrancar entera** por SSH. En Python
con `prompt_toolkit` termina en:

```
prompt_toolkit.output.win32.NoConsoleScreenBufferError: No Windows console found
```

**Eso es esperado y no es un bug del lanzador**: SSH no da buffer de consola.
No intentar "arreglarlo".

Lo que si se verifica asi — y es casi todo — es **cuanto imprimio antes de
morir**: arranque de servicios, comprobaciones, artefactos abiertos. Ejecutar
en un job y cortarlo antes del prompt:

```powershell
$job = Start-Job {
    & powershell.exe -ExecutionPolicy Bypass -File "C:\ruta\launcher.ps1" 2>&1 | Out-String
}
Start-Sleep -Seconds 35
Stop-Job $job -ErrorAction SilentlyContinue
(Receive-Job $job) -join "`n"
```

En la salida se busca la **huella** de cada paso (`[OK] Servicio`, `Panel
abierto`...). Si aparecen todas y luego cae el error de consola, el lanzador
esta bien.

Comprobar tambien que el job **no dejo el mutex pegado** al matarlo, y que los
servicios siguen vivos despues de la prueba.

---

## 5. Detectar si se abrio un artefacto externo (navegador, visor)

Contar procesos antes/despues **falla si ya habia uno abierto**: el navegador
reusa la instancia existente y el contador no se mueve. Combinar dos senales:

```powershell
$antes = @(Get-Process | Where-Object { $_.ProcessName -match "chrome|msedge|firefox|brave" }).Count
# ...ejecutar el lanzador...
$despues = @(Get-Process | Where-Object { $_.ProcessName -match "chrome|msedge|firefox|brave" }).Count

if ($despues -gt $antes)                  { "OK: abrio proceso nuevo" }
elseif ($salida -match "Panel abierto")   { "OK: lo confirma el propio launcher" }
else                                      { "AVISO: no se detecto apertura" }
```

Por eso el lanzador debe **imprimir una linea al abrir el artefacto**: es la
unica senal fiable cuando el proceso se reusa.

---

## 6. Enganchar algo nuevo a un lanzador existente

**Leer como arranca de verdad antes de elegir ancla.** Adivinar patrones
(`& $exe chat`, `Start-Process $app`...) falla: en el caso real el arranque era
`& $hermes` a secas, sin subcomando, y cuatro patrones candidatos fallaron.

```powershell
$c = Get-Content $launcher
$i = ($c | Select-String -Pattern "Lanzar el chat").LineNumber
$c[($i-1)..($i+12)]
```

Mejor ancla: una **linea de texto literal que se imprime** justo antes
(`Write-Host "  Escribe tu pregunta..."`). Es estable y unica; las lineas de
codigo cambian de forma entre versiones.

El bloque nuevo, siempre **no bloqueante**: si falla el extra, el trabajo
principal debe seguir.

```powershell
if (Test-Path $artefacto) {
    try   { Start-Process $artefacto -ErrorAction Stop; Write-Host "  Panel abierto" }
    catch { Write-Host "  (no se pudo abrir, sigo)" -ForegroundColor DarkYellow }
}
```

Y tras cada patch, **antes** de probar nada: backup, comprobar sintaxis sin
ejecutar, y confirmar que sigue sin BOM.

```powershell
$err = $null
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $f -Raw), [ref]$err)
if ($err.Count -gt 0) { $err | ForEach-Object { "linea $($_.Token.StartLine): $($_.Message)" } }
```

Hacer el patch **idempotente**: si la marca ya esta, salir sin tocar nada.

---

## 7. Cuando el trabajo lo hace otro agente

Si el encargo se delega al agente de la maquina destino (`hermes.exe -z
"<prompt>"` ejecuta y sale; el modo interactivo se cuelga por SSH), su informe
final es **una auto-declaracion, no un hecho**.

En el caso real el agente dijo "verificado" tras probar unas APIs con un cliente
HTTP de terminal — que ignora CORS. En navegador una devolvia 403: el panel se
habria abierto con todo en rojo.

**Verificar siempre por fuera**, y con el mismo canal que usara el consumidor
real. En el encargo, pedir explicitamente handles comprobables (ruta, tamano,
respuesta de cada dependencia) para poder auditarlos sin creerse el resumen.

---

## 8. Verificar una UI web de verdad (no que "parezca" que va)

Cuando el artefacto es un panel web con chat/formulario, comprobar que sirve
HTTP 200 **no prueba nada del flujo**. Receta que si funciona, en orden de coste.

### a) El 401 de un `curl` pelado puede ser NORMAL

Muchos paneles locales inyectan el token en el HTML para que lo lea el JS:

```
__HERMES_SESSION_TOKEN__="..."     __HERMES_DASHBOARD_EMBEDDED_CHAT__=true
```

Un cliente de terminal no ejecuta JS, asi que recibe 401 en las rutas
protegidas. **No es un fallo**: el navegador entra solo. Para auditar la API hay
que extraer el token del HTML y mandarlo:

```powershell
$r   = Invoke-WebRequest -Uri $base -UseBasicParsing
$tok = [regex]::Match($r.Content, '__HERMES_SESSION_TOKEN__="([^"]+)"').Groups[1].Value
$h   = @{ Authorization = ("Bearer " + $tok) }
Invoke-WebRequest -Uri ($base + "/api/sessions") -Headers $h -UseBasicParsing
```

Antes de declarar roto un 401/403, **averiguar donde vive la credencial**.

### b) Eventos sinteticos NO envian formularios de React

La trampa mas cara de la sesion. Esto **parece** funcionar — el textarea incluso
se vacia — y no envia nada:

```javascript
ta.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true}))  // NO
```

Lo que si funciona es **teclado real** por CDP contra un Chrome headless:

```python
cmd("Input.dispatchMouseEvent", {"type":"mousePressed",  "x":x, "y":y,
                                 "button":"left", "clickCount":1})
cmd("Input.dispatchMouseEvent", {"type":"mouseReleased", "x":x, "y":y,
                                 "button":"left", "clickCount":1})
cmd("Input.insertText", {"text": "mi mensaje"})
cmd("Input.dispatchKeyEvent", {"type":"keyDown", "windowsVirtualKeyCode":13,
                               "key":"Enter", "code":"Enter", "text":"\r"})
cmd("Input.dispatchKeyEvent", {"type":"keyUp",   "windowsVirtualKeyCode":13,
                               "key":"Enter", "code":"Enter"})
```

Coordenadas del campo con `getBoundingClientRect()` y clic real para enfocarlo:
los frameworks modernos ignoran el foco puesto por JS.

### c) Confirmar contra el BACKEND, nunca contra el DOM

Buscar la respuesta en `document.body.innerText` da falsos negativos (scroll,
virtualizacion, render diferido). La prueba real es el estado del servidor:

```powershell
Invoke-RestMethod -Uri ($base + "/api/sessions/" + $id + "/messages") -Headers $h
# -> [user] ...MARCA...   [assistant] MARCA
```

> **Heuristica que lo destapo:** si el campo se vacia PERO no se crea sesion en
> el backend, el envio no ocurrio. Vaciarse solo prueba que React limpio el
> formulario, no que llegara al servidor.

Usar una **marca unica sin guiones** (`PANELOK9931`) para poder buscarla exacta,
y contar apariciones: 1 = solo tu mensaje, >=2 = hubo respuesta.

### d) Chrome lanzado por SSH tambien muere con la sesion

Mismo pitfall que los demonios: arrancar Chrome y sondearlo en **llamadas
separadas** falla con "no es posible conectar". Todo el flujo (lanzar, conectar
CDP, teclear, esperar) va en **una sola ejecucion**.

Y al terminar: cerrar los Chrome de prueba y borrar el perfil temporal
(`--user-data-dir`), o se acumulan.
