---
name: process-state-forensics
description: "Config correcta pero servicio roto: auditar el proceso vivo."
version: 1.0.0
tags: [systemd, debugging, forensics, linux, process, config]
trigger: Cuando un servicio se comporta mal pero su configuracion parece correcta; cuando un fix "aplicado" no surte efecto; cuando un proceso muere al reiniciar; o al revertir un cambio de configuracion.
metadata:
  hermes:
    tags: [systemd, debugging, forensics, linux, process, config]
    related_skills: [autonomous-hardening, hermes-ops-pitfalls, systematic-debugging]
---

# Forensics de estado: lo que se REPORTA vs lo que el proceso TIENE

Clase de bug mas cara de diagnosticar: **la configuracion es correcta, la
herramienta de inspeccion lo confirma, y aun asi el sistema falla.** Se pierden
horas porque se verifica en la capa equivocada.

## Regla capital

> `instalado != cargado != aplicado`. La unica fuente de verdad es el
> **proceso vivo** (`/proc/<pid>/`), nunca el fichero de config ni el comando
> que lo resume.

Jerarquia de fiabilidad, de menos a mas:

| Capa | Comando tipico | Fiabilidad |
|---|---|---|
| Fichero en disco | `cat unit.conf` | baja — puede no estar cargado |
| Config resuelta | `systemctl show`, `hermes config` | media — **puede mentir** |
| Proceso vivo | `/proc/<pid>/status`, `/proc/<pid>/environ` | **alta — la verdad** |
| Comportamiento real | ejecutar la accion afectada | **definitiva** |

Si las capas 2 y 3 discrepan, gana la 3. Y si tienes dudas, sube a la 4:
ejecuta lo que deberia funcionar y mira si funciona.

## Procedimiento

```bash
PID=$(systemctl --user show <servicio> -p MainPID --value)

# 1. flags de seguridad del proceso (no del fichero)
grep -E "NoNewPrivs|Seccomp|CapEff" /proc/$PID/status

# 2. entorno REAL heredado
tr '\0' '\n' < /proc/$PID/environ | sort

# 3. cadena de padres (un flag heredado viene de arriba)
for p in $PID $(grep PPid /proc/$PID/status | awk '{print $2}'); do
  echo "$p $(grep -E '^(Name|NoNewPrivs):' /proc/$p/status | tr '\n' ' ')"
done

# 4. que drop-ins ve realmente systemd
systemctl --user show <servicio> -p DropInPaths --value
systemctl --user show <servicio> -p NeedDaemonReload --value   # 'yes' = tu edicion NO esta cargada
```

**`NeedDaemonReload=yes` es la causa numero uno de "edite el fichero y no paso
nada".** Un `daemon-reload` olvidado hace que sigas depurando la config vieja.

## Aislar la causa: probe de una variable por vez

Cuando varias directivas podrian causar el sintoma, **no razones: mide**. Crea
un servicio desechable, activa UNA directiva, lee el resultado desde dentro del
propio servicio, repite.

Plantilla generica: `templates/one-shot-probe.service`.
Caso ya resuelto con esta tecnica: `scripts/nnp-probe.sh` en la skill
`autonomous-hardening` (que directiva systemd implica `NoNewPrivileges`).

Sesion completa con las tres cadenas causales, las mediciones y **los tres
diagnosticos propios que resultaron falsos**:
`references/gateway-lifecycle-forensics.md`.

Caso de un health-check en verde sobre un puente muerto, con los tres `rc=0`
mentirosos y la sonda que lo habria detectado al principio:
`references/layered-bridge-health-checks.md`.

Caso de una UI que decia hablar con el agente y hablaba con el modelo crudo
(diagnostico, test discriminante y receta del puente HTTP -> agente):
`references/ui-front-end-vs-agent.md`.

El patron:

```bash
probe() {                       # $1 = etiqueta, $2... = directivas
  cat > ~/.config/systemd/user/probe.service <<EOF
[Service]
Type=oneshot
$*
ExecStart=/bin/bash -c 'echo RESULT_$1=\$(<lectura desde /proc/self/>)'
StandardOutput=journal
EOF
  systemctl --user daemon-reload
  systemctl --user start probe.service
  journalctl --user -u probe.service --since "-15s" --no-pager | grep -o "RESULT_.*"
}
probe BASELINE ""
probe OPCION_A "DirectivaA=true"
# ... y limpiar el probe al terminar
```

Dos hallazgos reales que solo aparecen midiendo asi:

1. **Efectos implicitos.** Una directiva puede activar otra sin declararla.
   `RestrictNamespaces` / `RestrictRealtime` / `LockPersonality` /
   `RestrictAddressFamilies` implican todas `NoNewPrivileges=1`.
2. **La negacion explicita puede no ganar.** Poner `NoNewPrivileges=no`
   *despues* de esas directivas NO revierte la implicacion: `systemctl show`
   dice `no` y el proceso arranca con `NoNewPrivs: 1`.

Corolario general: **si retiras la causa aparente y el sintoma sigue, la causa
real es otra directiva del mismo bloque.** No repitas el mismo fix esperando
otro resultado.

## Muerte al reiniciar: leer el diagnostico antes de teorizar

`SIGKILL` / `status=9` al parar un servicio casi nunca es OOM. Antes de culpar
a la RAM, **leer los campos que el propio sistema ya publica**:

```bash
journalctl --user -u <servicio> --since "<hora>" --no-pager \
  | grep -iE "status=9|UNCLEANLY|timeout|oom"
```

Hermes publica en `gateway.lifecycle_ledger` un mensaje con `suspected_oom`,
`mem_available_kib` y `last_heartbeat_at`. Si dice `suspected_oom=False` con
GB libres, **no era memoria**.

Senal decisiva: si el SIGKILL cae **exactamente** al valor de `TimeoutStopSec`
(90 s, 90 s, 90 s...), es el timeout, no el kernel. Un numero redondo y
repetido es un temporizador, no una casualidad.

Jerarquia de timeouts de apagado — el interno debe caber HOLGADO en el externo:

```
drain de la aplicacion  <  TimeoutStopSec de systemd
        120s                      180s
```

- drain demasiado corto -> el trabajo en curso se interrumpe sin SIGKILL.
- drain >= TimeoutStopSec -> no queda margen para cerrar subsistemas y vuelve
  el SIGKILL.

**Verificar en el reinicio SIGUIENTE, no en la config**: la ausencia de
`UNCLEANLY` en el journal es la prueba; el fichero no prueba nada (capa 1).

## Revertir config: la clave debe DESAPARECER, no quedar vacia

Al deshacer un override, `set <clave> ""` deja `clave: ''` — que **no es lo
mismo que ausente**. Un valor vacio donde se espera un entero genera un
warning de validacion en cada turno/arranque.

```bash
hermes config unset <clave>              # correcto
hermes config set <clave> ""             # deja basura que ensucia logs
grep -c "<clave>" ~/.hermes/config.yaml  # verificar: debe dar 0
```

Generaliza a cualquier gestor de config: **revertir se verifica por ausencia
de la clave**, no por que su valor parezca inocuo. Y tras revertir, mirar los
logs una vez mas: un revert mal hecho es una fuente nueva de ruido.

## Health-check verde con cobertura parcial

Variante del mismo bug, y de las mas caras: **el health-check pasa porque solo
mide una de las capas del sistema.** No miente sobre lo que mide; miente por
omision sobre lo que no mide.

Caso real (10-sep-2026, puente a un movil Android): `--check` devolvio
**6 checks OK, fallos: 0** mientras la capa privilegiada del puente estaba
completamente muerta. Los 6 checks cubrian el transporte (SSH, puerto,
ping); ninguno tocaba la capa que da los permisos reales. Se prometio una
accion que era imposible desde el primer segundo.

Procedimiento cuando un sistema tiene **varias capas de privilegio o de
transporte**:

1. **Enumerar las capas explicitamente** y, por cada una, cual es su sonda
   propia. Escribirlo en una tabla — capa / como entra / que privilegio da /
   cuando se cae.
2. **Mapear cada capacidad que vas a usar a la capa que la exige.** Si vas a
   escribir en pantalla, leer contactos o conceder permisos, esas son capas
   distintas de "me responde el shell".
3. **Sondear la capa CONCRETA justo antes de prometer nada**, no el check
   agregado. Una linea que devuelve el identificador de privilegio real vale
   mas que un resumen de N checks:

   ```bash
   # ejemplo: la sonda distingue uid privilegiado de uid normal
   <transporte> 'id -u'      # valor esperado -> capa viva; vacio -> capa caida
   ```

4. Si el health-check agregado no cubre una capa, **eso es un bug del
   health-check**, no un detalle. Un check en verde que no cubre la capa que
   importa es peor que no tenerlo: convierte una averia en una promesa.

> Generalizacion: **un check agregado solo es fiable si sabes que capas
> cubre.** Antes de fiarte de un `rc=0` global, exige la lista de lo que
> comprueba y contrastala con lo que vas a hacer.

## APIs de consulta que MIENTEN por diseno (no por bug)

Algunas APIs filtran su respuesta **segun quien pregunta**, sin decirlo y sin
error. Una lista incompleta se lee identica a una lista completa.

Caso real (10-sep-2026): `pm list packages` desde un uid no privilegiado
devolvio 272 paquetes y **cero** coincidencias para una app que estaba
instalada y funcionando. No es un fallo: Android 11+ filtra la visibilidad de
paquetes por consultante. Con el uid privilegiado aparecia sin problema.
Llevo a la conclusion falsa "esa app no esta instalada".

**Regla: nunca concluir AUSENCIA a partir de una lista, sin control
negativo.** Una lista prueba lo que contiene, jamas lo que no contiene.

Patron de control negativo — pedir el recurso concreto y comparar la respuesta
con la de uno que seguro no existe:

```bash
<accion> <recurso_inventado>   # -> error explicito de "no existe"
<accion> <recurso_dudoso>      # -> mismo error = no existe
                               # -> exito/silencio  = SI existe (la lista mentia)
```

Sin el control negativo, un "exito" silencioso no se distingue de un fallo
silencioso. Aplica igual a listados de paquetes, de tablas, de ficheros con
permisos parciales, de recursos cloud filtrados por IAM, o de endpoints que
paginan sin avisar.

Senal de sospecha barata: **si un listado da un total alto pero cero
coincidencias para algo que crees que esta ahi, sospecha del filtro antes que
de tu creencia.**

## Barrer puertos sin tumbar el host

Cuando hace falta demostrar que un servicio esta caido de verdad (y no
suponerlo desde un cache rancio), el barrido de puertos es legitimo. Lo que
tumba maquinas pequenas **no es el escaneo: son los forks.** Un
`nc` por puerto con `xargs -P64` lanza miles de procesos y en un host con poca
RAM o con un supervisor agresivo se lleva por delante al proceso padre.

Builtin de bash, cero forks:

```bash
found=""
for p in $(seq 1024 65535); do
  (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null && { found="$found $p"; exec 3<&- 2>/dev/null; }
done
echo "ABIERTOS:$found"
```

Desde otra maquina, el equivalente barato es un `ThreadPoolExecutor` con
`socket` y `settimeout` corto — hilos, no procesos. Verificado 10-sep-2026:
los 65.535 puertos en tandas, sin tumbar nada, y el resultado (un unico puerto
abierto) convirtio una hipotesis en un hecho.

**El valor no es encontrar el puerto: es poder afirmar la ausencia con
evidencia** en vez de repetir "parece que no responde".

## Higiene de diagnostico

- **El entorno del proceso contamina tus pruebas.** Una variable heredada
  (`PYTHONSAFEPATH`, `PATH`, `VIRTUAL_ENV`) hace que el caso "sin proteccion"
  y el caso "con proteccion" den lo mismo. Usar `env -u VAR` para la prueba
  negativa.
- **Un contador de inactividad a `0.0s` significa actividad, no silencio.**
  `last progress 0.0s ago` = acaba de progresar. Un componente colgado daria
  un idle CRECIENTE. Leer al reves este campo lleva a culpar al proveedor
  equivocado.
- **Reproducir el payload real antes de culpar a un servicio externo.** Un
  script minimo con `curl`/`urllib` que mande exactamente lo que manda la
  aplicacion distingue "el proveedor falla" de "nosotros mandamos algo raro".
- **Limpiar los probes.** Borrar la unidad desechable + `daemon-reload` +
  `reset-failed` al terminar; si no, queda un servicio fantasma en `failed`
  que ensucia la siguiente auditoria.

## Caso: MCP server instalado vía nvm, `hermes mcp test` en falso "✓ Connected" (15-sep-2026)

Instancia directa de la regla capital de este skill, con un giro: la
herramienta de verificación oficial (`hermes mcp test <name>`) **corre en la
capa equivocada** — tu shell de terminal, no el proceso gateway real — y por
eso da capa 2 (config resuelta) cuando hace falta capa 3 (proceso vivo).

**Síntoma**: tras instalar un MCP server (`npm install -g` bajo nvm) y
configurarlo en `config.yaml`, `hermes mcp test context_mode` da `✓ Connected`
y lista las 11 tools. El gateway real (el que atiende Telegram) sigue sin
poder lanzarlo: `~/.hermes/logs/mcp-stderr.log` repite
`FileNotFoundError: [Errno 2] No such file or directory: 'context-mode'`.

**Por qué el test miente**: `hermes mcp test` hereda TU PATH de sesión
(incluye `~/.nvm/versions/node/<v>/bin`). El gateway arranca desde el unit
systemd `hermes-gateway.service`, con un `PATH` fijo de la plantilla interna
de Hermes — sin el bin de nvm. El binario del MCP es invisible para el
proceso que de verdad importa.

```bash
# Capa 2 (miente aquí): hermes mcp test context_mode -> ✓ Connected

# Capa 3 (la verdad): PATH del proceso gateway VIVO, no el tuyo
PID=$(systemctl --user show hermes-gateway.service -p MainPID --value)
tr '\0' '\n' < /proc/$PID/environ | grep '^PATH='

# confirmacion cruzada en el log de error real del MCP
tail -30 ~/.hermes/logs/mcp-stderr.log
```

**Fix**: el unit `~/.config/systemd/user/hermes-gateway.service` lo REGENERA
Hermes en cada arranque desde plantilla interna — editarlo directamente se
pierde. Añadir el PATH completo (con el bin de nvm) como
`Environment="PATH=..."` en el drop-in
`~/.config/systemd/user/hermes-gateway.service.d/10-hardening.conf`, que sí
sobrevive a la regeneración. Reiniciar con el mecanismo externo
(`touch /tmp/hermes-gw-restart.flag`, recogido por el crontab del sistema —
NUNCA `systemctl restart` desde dentro del gateway, lo bloquea el lifecycle
guard). Cierre obligatorio (paso 2 del "anti-patron: dar por bueno un fix sin
ejercitarlo" de arriba): tras el restart, repetir la lectura de
`/proc/<PID_NUEVO>/environ` — el PID cambia, comparar contra el PID viejo da
un falso "sigue roto" — y confirmar que no hay `FileNotFoundError` NUEVOS en
`mcp-stderr.log` después de la hora del restart.

**Trampa del cron de verificación**: si programas un cron one-shot para
comprobar el resultado del restart, puede morir a mitad si coincide con el
propio apagado del gateway ("gateway is shutting down and killed the run").
No es señal de que el fix falló — es el mismo tipo de falso negativo que
"probe una vez y no vi el efecto": verificar a mano contra el PID nuevo en
vez de fiarte del cron, y borrarlo después de usarlo.

## Capa 0: la UI que lleva el nombre del sistema puede NO hablar con el sistema

Todas las capas de arriba miran hacia abajo (config -> proceso -> comportamiento).
Esta mira hacia ARRIBA, y por eso se salta: **antes de depurar el motor,
verificar que el front-end que reporta el sintoma esta conectado al motor.**

Caso real (17-sep-2026, panel web de un agente). Sintoma: el usuario cierra la
ventana del chat, la reabre, pregunta por el trabajo de esa misma mañana y
recibe la respuesta clasica de un LLM pelado:

> *"Como soy una inteligencia artificial, no tengo memoria de conversaciones
> anteriores... pegame el codigo que llevabamos"*

Diagnostico inicial (mio, **equivocado**): asumi que fallaba la persistencia de
sesion del agente y fui camino de tocar su launcher. Verifique la memoria por
el canal de terminal y **funcionaba**: dato guardado en una invocacion,
recuperado en la siguiente. Tenia dos hechos contradictorios y elegi dudar del
motor.

Lo desatasco una frase del usuario: *"a lo mejor es porque en el panel no
funciona todo igual de bien que en la terminal"*. Al leer el codigo del panel:

```js
fetch('http://127.0.0.1:11434/api/chat', ...)   // <- habla con el MODELO CRUDO
```

El chat titulado "Chat con el Agente" nunca paso por el agente. Llamaba
directamente al runtime de inferencia: sin memoria, sin herramientas, sin
skills, sin cascada de modelos. Su "no tengo memoria" era **literalmente cierto
para el**. El motor estuvo sano todo el tiempo.

> **Regla: cuando un sintoma aparece en una interfaz y NO en otra, el bug esta
> en la diferencia entre las interfaces, no en el motor compartido.** Dos
> front-ends que discrepan sobre el mismo backend son la prueba de que al menos
> uno no esta hablando con ese backend.

Procedimiento, antes de tocar nada del motor:

1. **Reproducir por los DOS canales.** Si uno falla y otro no, el motor esta
   descartado como causa. Si fallan los dos, entonces si baja a las capas 1-4.
2. **Leer que invoca realmente el front-end.** En una UI web, grepear sus
   llamadas salientes (`fetch`, `XMLHttpRequest`, URL base, puerto de destino).
   Un puerto de runtime de inferencia (11434, 8000, 1234...) donde esperabas el
   endpoint del agente es el hallazgo.
3. **No fiarse del titulo ni del nombre del fichero.** `dashboard-<producto>.html`
   y un `<h2>Chat con el Agente</h2>` no son evidencia de nada.

### El test que separa "agente" de "modelo pelado"

Un LLM crudo responde de forma plausible a casi todo, asi que hace falta una
pregunta cuya respuesta correcta **solo se obtiene ejecutando**:

| Prueba | Modelo pelado | Agente real |
|---|---|---|
| dato dado en el turno anterior, sesion nueva | lo ha perdido | lo recupera |
| **"¿cuanta RAM tiene esta maquina?"** | **inventa** un numero plausible | ejecuta y da el real |
| "¿que hicimos ayer?" | se disculpa por no tener memoria | busca en su historial |

La pregunta de hardware es la mas barata y la mas discriminante: un dato de
maquina equivocado **no es mala memoria, es sintoma de transporte roto**. En
esta misma familia de fallos ya se habia visto antes un agente contestando
"16 GB" en una maquina de 32 GB porque la cascada habia caido a un modelo local
que no ejecutaba herramientas.

### Reconectar la UI: sesion con nombre fijo

Si el CLI del agente abre una sesion nueva por invocacion, una UI sin estado
nunca tendra hilo. La pieza es fijar el nombre de sesion en cada llamada
(`-c <nombre>` / equivalente), de modo que procesos distintos compartan
conversacion. Verificado con dos invocaciones independientes: dato guardado en
la primera, recuperado en la segunda, y una tercera ejecutando una herramienta
real.

Detalles de implementacion del puente HTTP -> agente (servidor con hilos para
que la UI no se congele mientras el agente piensa, timeout amplio porque un
turno con herramientas tarda, limpieza de la telemetria que algunos proveedores
pegan a la respuesta, y por que el selector de modelo debe OCULTARSE cuando la
cascada ya decide): `references/ui-front-end-vs-agent.md`.

## La pista del usuario vale mas que mi hipotesis (dos veces en una sesion)

Patron repetido el 17-sep-2026, y el de mayor retorno de toda la sesion.

| Yo iba a... | el usuario dijo... | Realidad |
|---|---|---|
| tocar el launcher del chat | *"a lo mejor en el panel no funciona igual que en la terminal"* | el panel no hablaba con el agente (Capa 0) |
| mantener un panel propio | *"¿no seria mejor el dashboard oficial?"* | si: menos piezas y lo mantiene upstream |

**el usuario no es tecnico, pero USA el sistema.** Observa sintomas que yo no veo
porque yo miro logs y el mira la pantalla. Cuando describe una diferencia de
comportamiento entre dos sitios ("aqui si, alli no"), eso es **evidencia
experimental gratis**, no una opinion a evaluar.

> Regla operativa: si el usuario senala una diferencia entre canales/entornos,
> **verificarla ANTES de seguir con mi linea de investigacion**. Cuesta un
> comando y reencuadra el problema entero.

### Corolario: descartar las hipotesis propias EJECUTANDO, no razonando

En la misma sesion tuve dos hipotesis plausibles y **las dos eran falsas**. Lo
util no fue acertar a la tercera, fue como cayeron las dos primeras:

```
H1 "el parser confunde el 429 con overflow"
   -> ejecutar el clasificador con el cuerpo real del error
   -> devolvia la clasificacion CORRECTA. Muerta.

H2 "lo rompio mi cambio de config de hace un rato"
   -> restaurar el backup y reproducir
   -> fallaba IGUAL. Muerta.
```

Sospechar del propio cambio esta bien; **probarlo restaurando el backup** es
mejor que razonar sobre si "deberia" haberlo roto. Una hipotesis descartada con
un comando vale mas que tres descartadas de cabeza.

Y la senal que resolvio el caso no fue una teoria, fue un detalle numerico: **el
numero del error CAMBIABA** entre intentos (496 -> 514 -> 515). Un limite es
fijo; lo que varia es una medida. Ver
`local-llm-vram-tuning/references/agente-no-responde-diagnostico.md`.

### Un bug en la rama de fallback solo existe el dia que se usa

El fallo de esta sesion llevaba tiempo latente: el modelo de respaldo estaba mal
dimensionado y **nadie lo noto mientras el principal respondia**. Al caer el
principal, murio el agente entero.

No basta con que el camino feliz funcione. Ejercitar la rama de fallo **a
proposito** y de forma periodica:

```bash
# forzar el fallback sin esperar a que el principal se caiga
hermes --provider <proveedor-de-respaldo> -m <modelo-de-respaldo> -z "Responde: PONG"
```

Si esa linea no esta en algun guardian, el respaldo es decorativo.

## Anti-patron: dar por bueno un fix sin ejercitarlo

Un fix de configuracion no esta verificado hasta que **la accion que fallaba
funciona**. Secuencia minima de cierre:

1. Capa 3: `/proc/<pid>/` muestra el estado esperado.
2. Capa 4: ejecutar lo que estaba roto (p. ej. `sudo -n <comando permitido>`).
3. Prueba negativa: inyectar el fallo a proposito y comprobar que el watchdog
   lo detecta; retirarlo y comprobar que vuelve a callar.

Sin el paso 3 no sabes si el watchdog vigila o solo esta callado.

## Quinta capa: `registrado/conectado` != `usado de verdad` (15-sep-2026)

La jerarquia de arriba (fichero -> config resuelta -> proceso vivo ->
comportamiento real) tiene un techo: incluso con las 4 capas en verde, un
componente puede estar perfectamente vivo y **cero veces invocado**. "Conecta"
no es lo mismo que "se usa", y la diferencia solo la da el log de uso real.

Caso real: tras arreglar un MCP server (`context-mode`, PATH del gateway) y
confirmar las 4 capas — `hermes mcp test` OK, proceso hijo vivo del gateway
real, tools registradas en el log de arranque —, la pregunta del usuario fue
"¿esto ya me ahorra tokens?". Las 4 capas dicen que la herramienta ESTA
disponible; ninguna dice si alguna conversacion la ha llamado:

```bash
# capa 5: adopcion real, no disponibilidad
grep -c "nombre_de_la_tool_real" ~/.hermes/logs/agent.log
# 1 resultado y es la linea de "registered N tool(s)" al arrancar -> 0 usos reales
```

Un grep que devuelve 1 coincidencia y esa coincidencia es la propia linea de
registro de arranque **no es evidencia de uso**, es evidencia de que la
herramienta existe. Antes de afirmar un beneficio que depende de USO (ahorro
de tokens, reduccion de llamadas, adopcion de un flujo nuevo), separar:

| Pregunta | Como se verifica | Que NO prueba nada |
|---|---|---|
| ¿Esta disponible? | capas 1-4 de arriba | — |
| ¿Se ha usado alguna vez? | grep del nombre de la tool/funcion en logs de ejecucion real, excluyendo la linea de registro/arranque | que aparezca en el catalogo de tools, en un skill, o en la config |
| ¿El beneficio prometido ocurrio? | metrica propia de la herramienta si existe (ej. `ctx_stats` para consumo de contexto), medida ANTES/DESPUES | la existencia de la integracion en si misma |

**Regla**: cuando el beneficio de una integracion es "esto va a ahorrar X", la
respuesta correcta el mismo dia que se instala es "disponible, uso aun no
medido" — nunca "si" ni "no". Afirmar el ahorro sin una sola invocacion real
registrada es la misma familia de error que `rc==0` no es reparacion: se
confirma que el mecanismo EXISTE, no que hizo lo que se le pidio.
