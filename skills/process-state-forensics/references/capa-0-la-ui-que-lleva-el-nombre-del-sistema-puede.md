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
