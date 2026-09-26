# Gate de contenido (`jev-gate-content.py`) — 22-sep-2026

Cron `<cron-id>` (Trend-to-Article): **3.207.009 tok/run x 28 runs**, el mas
caro que quedaba sin gate.

## El patron que lo hace valioso: el guard que corre DEMASIADO TARDE

El prompt del cron ya empezaba con un guard duro:

    PASO 0 OBLIGATORIO: python3 article-limit-guard.py --enforce
    Si EXIT:1 -> limite semanal alcanzado, PARAR.

Pero ese guard corria **dentro del agente**. Cuando decia "no publiques", el
agente ya habia arrancado y facturado los 3,2M tokens para enterarse de que no
habia nada que hacer. Moviendo la MISMA decision al `monitor`, el agente no
arranca: 0 tokens.

**Buscar este patron en otros crons:** cualquier prompt que empiece con "ejecuta
X; si falla, para" es un gate esperando a que lo muevan delante.

## Aqui Jev apenas pinta, y eso es lo correcto

La decision "¿hay cuota?" es ARITMETICA (`count >= max`). Un modelo no la mejora
y solo anadiria una dependencia de red a un camino determinista. Jev entra SOLO
en la segunda mitad: cuando SI hay cuota, filtra que tendencias merecen articulo.
Medido: **12 titulares -> 2** que lo justifican.

No meter el modelo donde la aritmetica ya decide.

## Dos bugs propios que el banco de pruebas atrapo

**1. El detector imprime a STDOUT, no escribe fichero.** Lei un
`data/trends-detected.json` que no existe -> `[]` siempre -> el gate concluia
"nada merece articulo" con total naturalidad. Un falso negativo MUDO que habria
congelado la publicacion para siempre. Fix: `subprocess` al detector.

**2. Las claves del JSON no eran las que asumi.** Busque `trends`/`items`;
la estructura real es `top_overall` (UN objeto, no una lista) + `section_trends`
(`{seccion: [items]}`). Otra vez 0 titulares sin error visible.

**Leccion:** un gate que devuelve "no hay nada" es INDISTINGUIBLE de un gate
roto. Antes de enchufarlo, contar cuantos items extrae de verdad; si el numero
es 0, asumir que esta roto hasta demostrar lo contrario.

## `rc` leido por un pipe NO es el `rc` del script

    python3 article-limit-guard.py --enforce | head -12; echo $?   # -> 0 (el de head)
    python3 article-limit-guard.py --enforce > /tmp/g.txt; echo $?  # -> 1 (el real)

Casi acuso al guard de decorativo por esto. `$?` tras un pipe es el codigo del
ULTIMO comando. Redirigir a fichero antes de leer el rc.

## Hallazgo colateral: el descongelador no lo llamaba nadie

`content-strategy.json` tiene `max_articles_per_week: 0` desde el 20-sep
(decision A del usuario: 19/20 articulos con `lastCrawlTime` vacio, Google no
rastreaba). La nota prometia: *"DESCONGELACION AUTOMATICA: crawl-freeze-guard.py
mide el rastreo a diario y restaura 4 en cuanto Google vuelva. No requiere accion
manual."*

**Ese script no estaba en ningun cron (0 referencias).** La web llevaba 7 dias
sin publicar (ultimo articulo 15-sep) y habria seguido asi indefinidamente.
Enganchado como cron `<cron-id>` (no_agent, 08:30 diario).

Al ejecutarlo midio de verdad contra la URL Inspection API: **0/12 rastreados**
desde el 20-sep. La congelacion sigue siendo correcta; ahora al menos se mide
sola y descongelara cuando toque.

**Una promesa escrita en un fichero de estado no es un mecanismo.** Verificar
SIEMPRE que exista el cron que la cumple.
