# Delegar un encargo al agente de otra maquina (y supervisarlo)

Para cuando el usuario pide **"que lo haga el agente, tu supervisa"**: el trabajo
lo ejecuta el agente del host destino y tu validas el resultado desde fuera.

Encaja en esta skill porque el caso tipico es el stack local: el agente de la
maquina con GPU construye un panel/herramienta que consulta sus propios
servicios de inferencia, y hay que comprobar que de verdad los alcanza.

Episodio de referencia: 17-sep-2026, Hermes en Windows.

---

## 1. Invocacion no interactiva

El modo chat se cuelga por SSH (espera teclado). El modo "un encargo y sale":

```bash
hermes.exe -z "<prompt>"
```

**Pasar el prompt desde Python, no desde PowerShell.** Con un texto largo y
multilinea, PowerShell lo re-divide por espacios/saltos y el CLI acaba leyendo
una palabra suelta como subcomando:

```
hermes: error: argument command: invalid choice: 'no'
```

Falla igual con `Get-Content -Raw` y con comillas embebidas. Lo que si funciona:

```python
import subprocess
prompt = open(ENCARGO, encoding="utf-8").read()
r = subprocess.run([HERMES, "-z", prompt], capture_output=True,
                   text=True, encoding="utf-8", errors="replace", timeout=1800)
```

`subprocess` pasa el argumento entero sin shell de por medio. Es el mismo
patron que el pitfall de `Start-Process -ArgumentList`: **un `rc` raro de un CLI
suele ser culpa del invocador, no del binario**.

---

## 2. Escribir el encargo

Lo que cambia la calidad del resultado, por orden de impacto:

1. **Dar la causa raiz ya diagnosticada**, no el sintoma. "Arregla que pone
   Ollama no responde" hace que el agente investigue de cero y repita tu error.
   Mejor: el sintoma, la causa medida, y la tabla de evidencia.
2. **Prohibir explicitamente los callejones sin salida ya pagados.** Si una via
   tumbo el servicio, decirlo con esas palabras: *"NO lo arregles con la
   variable X: ya se probo y deja el servicio en crash-loop"*. Sin eso, el
   agente encuentra esa misma "solucion" en su entrenamiento.
3. **Requisitos no negociables como lista corta.** Escuchar solo en `127.0.0.1`,
   sin dependencias externas, sin instalar nada.
4. **Decir COMO verificar**, con el comando exacto y la cabecera exacta. Si no,
   verificara con lo que tenga a mano — que suele ser lo que ignora el problema.
5. **Avisar del fallo de verificacion anterior.** Literalmente: *"la ultima vez
   diste por bueno X porque usaste Y, que no aplica CORS; no repitas eso"*.

Y pedir **handles auditables** en el informe: rutas, tamanos en bytes, y la
respuesta concreta de cada dependencia. Sirven para comprobar sin creerse el
resumen.

---

## 3. El informe del agente NO es evidencia

Regla dura: **su "verificado" es una auto-declaracion.** En el caso real el
agente reporto "APIs verificadas, dashboard funcionando" tras probarlas con un
cliente HTTP de terminal. En navegador una devolvia 403 y el panel se abria con
todo en rojo. El informe era sincero y aun asi falso.

Supervision minima, siempre desde fuera:

```python
# 1. existe y ha cambiado de verdad (guardar la version previa y comparar bytes)
# 2. contiene las piezas pedidas (buscar las llamadas/marcas concretas)
# 3. sintaxis valida sin ejecutar:  ast.parse(...) / PSParser::Tokenize
# 4. EJECUTARLO y probar el camino real del usuario
```

El paso 4 es el que atrapa lo que los demas no ven. En el caso real: arrancar
el servidor, pedir la pagina por `http://localhost`, y mandar una peticion real
al modelo comprobando que **devuelve texto no vacio**.

```python
# la prueba que de verdad cierra el asunto
with urllib.request.urlopen(req, data=cuerpo, timeout=300) as r:
    d = json.loads(r.read())
txt = d.get("message", {}).get("content", "").strip()
assert txt, "respuesta vacia"
```

Borrar el artefacto antes de relanzar el encargo: si no, un fichero de un
intento anterior da falso positivo.

---

## 4. Ajustar como trabaja el agente destino (SOUL / MEMORY)

Si el agente falla por **criterio**, no por capacidad, el arreglo no es repetir
el encargo: es su contexto permanente.

Revisar que traen de fabrica — suelen estar sin personalizar:

| Fichero | Sintoma tipico de fabrica |
|---|---|
| `SOUL.md` | generico, en ingles, sin nada del usuario ni de la maquina |
| `MEMORY.md` | teoria de agentes copiada, cero datos del usuario, acentos rotos (`20%â†‘`) |

Que meter en cada uno:

- **SOUL** = como debe comportarse. Idioma, tono, nivel tecnico del usuario, y
  las **reglas duras nacidas de fallos reales**. La que faltaba y causo el bug:
  *"verifica con la misma herramienta y el mismo contexto que usara el usuario"*.
  Incluir el episodio concreto en dos lineas: una regla con cicatriz se obedece
  mas que una abstracta.
- **MEMORY** = hechos duraderos. Quien es el usuario, hardware, que modelo ocupa
  cada rol, y las trampas ya pagadas de esa maquina.

Al escribirlos:

- Backup con fecha antes de sobrescribir (`.bak-YYYYMMDD`).
- **UTF-8 sin BOM**, o el fichero falla al leerse:
  `[System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($false)))`
- Verificar despues: bytes, ausencia de BOM, y que un acento se lea bien.
- Redactar en **declarativo** ("el usuario no es tecnico"), no en imperativo; y sin
  contradecir otra seccion del mismo fichero — cuando dos partes chocan, el
  modelo elige, y repetirlo mas fuerte al final no gana.

---

## 5. Antes de construir: mirar si ya viene hecho

Antes de encargar una herramienta a medida, comprobar si el propio programa ya
la trae (`<cli> --help`, subcomandos tipo `serve` / `dashboard` / `gui`).

En el caso real existia una UI web oficial con chat incluido. Se compilo y
funciono. **Y aun asi se descarto**: exigia una tarea programada extra y un
puerto mas para cubrir lo que el panel propio ya hacia.

> Que exista una alternativa oficial no la hace mejor. Se elige la que deja
> menos piezas vivas: cada servicio extra es una superficie mas donde fallar en
> silencio. Si se descarta, **retirar lo que se dejo a medias** (tarea,
> artefactos) en vez de dejarlo huerfano.
