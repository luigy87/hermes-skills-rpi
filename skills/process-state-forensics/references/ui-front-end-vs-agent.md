# UI que dice hablar con el agente pero habla con el modelo

Caso resuelto el 17-sep-2026. Panel web local de un agente Hermes en Windows.
Se guarda por el patron, no por el producto: aplica a cualquier dashboard,
extension, bot o wrapper que ponga una caja de chat delante de un agente.

## El sintoma, y por que engana

El usuario cerro la ventana de chat, la reabrio y pregunto por el trabajo de
esa misma manana. Respuesta recibida:

> "Como soy una inteligencia artificial, no tengo memoria de nuestras
> conversaciones anteriores a menos que se mantengan en este mismo chat
> actual... Pega aqui el codigo que llevabamos."

Es exactamente lo que diria un agente con la persistencia rota, **y tambien**
lo que diria un modelo de lenguaje sin nada alrededor. Ese solapamiento es lo
que hace perder el tiempo.

## Secuencia de diagnostico (la que funciono, en orden)

1. **Descartar el motor probandolo por el otro canal.** Dos invocaciones
   independientes del CLI, con nombre de sesion fijo:

   ```
   hermes -c panel -z "Recuerda: mi mascota se llama PULPO-4417. Di solo OK."
   hermes -c panel -z "Como se llama mi mascota? Solo el nombre."
   -> PULPO-4417
   ```

   La memoria funcionaba. Con el sintoma vivo en la UI, el motor queda
   descartado: el bug esta entre la UI y el motor.

2. **Leer que invoca la UI.** Un grep de sus llamadas salientes basta:

   ```bash
   grep -n "fetch\|api/\|:[0-9]\{4,5\}" panel.html
   ```

   Hallazgo: `fetch('http://127.0.0.1:11434/api/chat')` con
   `{ model, messages, stream:false }`. Puerto 11434 = runtime de inferencia,
   no el agente. **El chat nunca paso por el agente.**

3. **Confirmar con el test discriminante** (ver tabla en el SKILL.md): pedir un
   dato de hardware. Un modelo pelado lo inventa; el agente ejecuta el comando.

## Senales de que una UI NO esta hablando con el agente

Cualquiera de estas, leida en su codigo, basta para sospechar:

- El `fetch` apunta al puerto del runtime de inferencia (11434 Ollama,
  8000 vLLM, 1234 LM Studio, `/v1/chat/completions` generico) en vez de a un
  endpoint propio.
- El cuerpo de la peticion lleva **`messages` construido en el navegador**: si
  el historial lo mantiene el cliente, no hay sesion en el servidor. Un agente
  guarda su propio hilo; solo necesita el mensaje nuevo.
- Hay un **selector de modelo** en la interfaz. Un agente con cascada de
  fallback decide el modelo el mismo; que la UI lo elija significa que esta
  puenteando esa logica.
- No hay ninguna ruta propia tipo `/api/agent` en el servidor que sirve la UI:
  solo sirve ficheros estaticos.

## Puente HTTP -> agente: lo que hay que acertar

Estructura minima del servidor local que sirve la UI *y* hace de puente.

```python
SESSION_NAME = "panel"     # MISMO nombre siempre -> hay hilo entre mensajes
AGENT_TIMEOUT = 600        # un turno con herramientas tarda; 30s no llega
_RUIDO = re.compile(r"<!--\s*qwen_metadata:.*?-->", re.DOTALL)

def preguntar_al_agente(mensaje):
    r = subprocess.run(
        [HERMES, "-c", SESSION_NAME, "-z", mensaje],
        capture_output=True, text=True,
        encoding="utf-8", errors="replace",
        timeout=AGENT_TIMEOUT, cwd=os.path.expanduser("~"),
    )
    salida = _RUIDO.sub("", r.stdout or "").strip()
    if not salida:
        err = (r.stderr or "").strip()
        return None, ("El agente no devolvio texto. " + err[-400:]) if err else \
                     "El agente no devolvio texto (codigo %d)." % r.returncode
    return salida, None

class Servidor(socketserver.ThreadingTCPServer):   # <- ThreadING, no TCPServer
    allow_reuse_address = True
    daemon_threads = True
```

Cinco decisiones, cada una por un fallo concreto:

| Decision | Que pasa si no |
|---|---|
| `ThreadingTCPServer` | la UI se congela mientras el agente piensa y el auto-refresh del estado muere: parece que el panel se ha colgado |
| `-c <nombre>` fijo | cada mensaje abre sesion nueva; el chat "no recuerda" (el bug original, reintroducido) |
| timeout ~600 s | un turno que usa herramientas se corta y el usuario ve un error donde habia trabajo en curso |
| limpiar la telemetria del proveedor | comentarios tipo `<!-- *_metadata: ... -->` salen impresos en la burbuja del chat |
| `subprocess.run([...])` con lista | pasar el prompt por shell lo parte por espacios y el CLI lee una palabra suelta como subcomando |

Y en el lado HTML:

- Sustituir el `fetch` al runtime por `fetch('/api/agent', {message: text})`.
- **Borrar el `chatHistory.push(...)`**: el hilo lo guarda el agente. Mandarlo
  desde el navegador duplica el contexto en cada turno.
- **Ocultar el selector de modelo** (`style="display:none"`, sin borrar el
  elemento para no romper el JS que lo rellena) y poner una etiqueta fija con
  el nombre del agente. Un selector que ya no selecciona nada es mentir en la
  interfaz.

## Verificacion (las 5 pruebas, ninguna opcional)

Contra el puente ya levantado, no contra el codigo:

```
T1  "Recuerda: mi mascota se llama PULPO-4417"  -> OK
T2  "Como se llama mi mascota?"                 -> PULPO-4417     (memoria)
T3  "Cuanta RAM tiene este equipo?"             -> 32             (herramientas)
T4  POST mensaje vacio                          -> HTTP 400       (rama de fallo)
T5  POST /api/nada                              -> HTTP 404       (rama de fallo)
```

Mas la reproduccion del sintoma original ("que hicimos antes, nos quedamos a
medias con X"): debe listar el trabajo real, no disculparse.

T3 es el que no se puede saltar: distingue agente de modelo. T4/T5 son la rama
de fallo — un puente solo esta probado cuando has visto que RECHAZA.

## Trampas de entorno al probar esto por SSH

- **Un proceso lanzado por SSH muere al cerrar la sesion.** Arrancar el
  servidor y probarlo en llamadas separadas da "no es posible conectar con el
  servidor remoto" aunque todo este bien. Hacer arranque + prueba en la MISMA
  invocacion, o registrar una tarea programada.
- **Capturar stdout/stderr del arranque a fichero** (`-u` para salida sin
  buffer) antes de concluir que el servidor no arranca. En el primer intento,
  "vivo: True" con stderr vacio y puerto sin escuchar era solo el efecto de la
  muerte por cierre de sesion.
- Al decodificar base64 en PowerShell, `[Convert]::FromBase64String($s -replace "\s","")`
  falla con *"no se encuentra ninguna sobrecarga... numero de argumentos 2"*:
  el `-replace` se parsea como segundo argumento. Separar en variables:
  `$s = $s -replace "\s",""` y luego `[Convert]::FromBase64String($s)`.

## Arreglo de fondo: el agente mentia sobre sus propias capacidades

El puente arregla el transporte, pero quedaba la conducta: un agente que ante
"¿que hicimos antes?" se disculpa en vez de **buscar en su historial**. Se
corrige en su prompt de sistema, con la prohibicion explicita:

> Si el usuario se refiere a algo anterior ("lo de esta manana", "seguimos
> con", "el fichero que hicimos"), la primera accion es buscar en las sesiones
> anteriores, no una disculpa. Prohibido responder "no tengo memoria" o
> "empezamos de cero" sin haber buscado: es mentira sobre las propias
> capacidades y obliga al usuario a repetir trabajo. Prohibido pedirle que
> pegue ficheros que estan en su disco. Si tras buscar de verdad no hay nada,
> ESO si se dice.

Verificado como se verifica una conducta, no un fichero: sesion nueva, la
pregunta original del usuario, y comprobar que **busca y responde** en vez de
disculparse. Un `grep` de que el texto esta en el fichero no prueba nada.
