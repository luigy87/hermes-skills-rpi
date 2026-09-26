# Health-check verde sobre un puente muerto (10-sep-2026)

Transcripcion condensada del caso que motivo la seccion "Health-check verde
con cobertura parcial". Sistema: puente RPi -> movil Android (SSH sobre
Tailscale + ADB self-connect). Tarea: enviar un mensaje desde el movil.

## Lo que reporto el health-check

```
[OK  ] peer en tailnet
[OK  ] peer online
[OK  ] puerto 8022 abierto
[OK  ] comando remoto - PONG
[OK  ] termux-api - {battery json}
[OK  ] hook de boot

fallos: 0
```

rc=0. Los seis checks eran **ciertos**. Y la tarea era imposible.

## Por que era imposible

El sistema tiene dos capas independientes:

| capa | transporte | privilegio | los 6 checks la cubren? |
|---|---|---|---|
| shell remoto | sshd:8022 | uid normal (app) | **si, las 6** |
| control real | ADB local al dispositivo | uid shell (2000) | **ninguno** |

Todo lo que la tarea necesitaba — escribir en pantalla, leer contactos — vive
en la segunda capa. El check no la tocaba.

Sonda que lo habria detectado en 3 segundos, al principio:

```bash
<transporte_remoto> 'adb shell id -u 2>/dev/null | tr -d "\r"'
# "2000" -> capa privilegiada viva
# ""     -> caida (todo tap/captura/provider fallara)
```

## Cadena de sintomas, en el orden real en que aparecieron

1. `--check` rc=0, 0 fallos. **Falsa confianza.**
2. El comando de contactos devuelve un aviso en texto y **rc=0**. Segundo rc
   mentiroso: el CLI estaba instalado (`dpkg -l` -> `ii 0.59.1`) pero la app
   companion que lo implementa, no. *CLI instalado != capacidad disponible.*
3. `content query` sobre el provider de contactos ->
   `SecurityException: ... requires ACCESS_CONTENT_PROVIDERS_EXTERNALLY`.
   **Primera senal honesta.** Aqui se identifico la capa que faltaba.
4. El listado de paquetes dice 272 paquetes, 0 coincidencias para la app
   objetivo. **Conclusion falsa evitada por poco** con un control negativo:
   lanzar un componente inventado da `Error type 3 ... does not exist`;
   lanzar el real arranca en silencio. La app estaba instalada; la lista
   estaba filtrada por visibilidad de paquetes.
5. Reconexion por el puerto cacheado -> `Connection refused`. El cache era
   valido *ayer*.
6. Descubrimiento por mDNS -> `unknown host service 'mdns:services'` incluso
   forzando la variable de entorno. No implementado en esa build.
7. Barrido completo de los 65.535 puertos con el builtin `/dev/tcp`
   (cero forks): **solo el 8022 abierto**. Ausencia demostrada, no supuesta.

## Lecciones transferibles

- **rc=0 aparecio tres veces sobre operaciones fallidas** (check agregado,
  CLI sin backend, aviso en texto). En un sistema con capas, el codigo de
  salida es la peor senal disponible: mide el transporte, no el efecto.
- **La primera senal honesta fue una excepcion de permisos.** Cuando algo
  falla con un `SecurityException`/`Permission Denial` explicito, eso es
  informacion de calidad: nombra la capa que falta. Vale mas que cinco checks
  en verde.
- **Un cache de conectividad rancio se comporta como una config correcta.**
  El puerto guardado era sintacticamente valido y semanticamente muerto.
  Releerlo no lo valida; solo conectarse lo valida.
- **El control negativo desambigua el silencio.** "Arranco sin decir nada" y
  "fallo sin decir nada" son indistinguibles hasta que ejecutas el caso que
  sabes que debe fallar.

## Cierre honesto

La sesion termino **sin** reactivar la capa privilegiada: requeria una accion
fisica en el dispositivo. Lo correcto fue decirlo con la evidencia al lado
(barrido completo: 1 puerto abierto) en vez de seguir reintentando o de
fabricar un resultado. El escaneo exhaustivo no arreglo nada, pero convirtio
"creo que esta caido" en "esta caido, y aqui esta la prueba" — que es lo que
permite pedir la accion correcta a la primera.
