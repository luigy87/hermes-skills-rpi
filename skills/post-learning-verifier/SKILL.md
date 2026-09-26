---
name: post-learning-verifier
description: "Mide si el aprendizaje cambio algo; no que existan ficheros."
version: 2.0.0
tags: [cognitive, learning, verification, telemetry]
trigger: Cuando se ejecuta el cron job Post-Learning Verifier tras las sesiones de aprendizaje.
---

# Post-Learning Verifier v2 — ¿cambio algo, o solo se escribieron ficheros?

## Por que cambio esta skill (29-ago-2026)

La v1 verificaba: memoria saludable, patrones cargados, contratos OK, ficheros
del dia presentes, indexacion FTS OK. Reportaba **"Todo verde"** todos los dias.

Pero el aprendizaje llevaba meses produciendo **136 ficheros de noticias y cero
cambios**. La v1 medía que el pipeline *corrio*, no que *sirviera*. Un test que
comprueba su propia existencia siempre pasa.

PAST-Bench (arXiv 2608.04003) es explicito: sin control de no-persistencia, la
ganancia atribuida a la memoria no se distingue de la varianza run-to-run.

## Regla unica

> Un aprendizaje sin cambio aplicado es un aprendizaje fallido, aunque todos
> los ficheros existan y esten indexados.

## Verificaciones

### 1. ¿Se aplico algo? (la que importa)
```bash
tail -20 ~/.hermes/logs/improvement-ledger.jsonl
```
Cuenta entradas con `aplicado` en los ultimos 7 dias.
- ≥1 → OK
- 0 aplicados pero con descartes registrados → OK (ciclo sano: nada relevante)
- 0 entradas de cualquier tipo → **FALLO: el loop esta muerto**, revisar feeds

### 1bis. ¿El auto-aprendizaje post-turno convierte, o solo quema tokens?

```bash
python3 ~/.hermes/scripts/background-review-telemetry.py --days 7
```

`background_review` forkea un AIAgent al final de cada turno para decidir si
guarda memoria o crea una skill. Es la unica celda "entre sesiones x ficheros
externos" que corre automaticamente aqui, y hasta el 05-sep-2026 **nadie la
media**: su unico rastro era una linea INFO en `agent.log`, que rota cada ~5 MB
y se pierde.

Linea base medida (22 reviews, 26-ago -> 05-sep):

```
result=none    14      conversion 36%
result=memory   8      result=skill 0   <-- nunca ha creado una skill
calls=0         5      forks que arrancan y no hacen NADA (23%)
tokens out 220.244 -> 27.530 out por resultado util
```

Silencio = todo en rango. Alerta si: conversion <20%, >40% de forks vacios,
>60k tokens out por resultado util, caida de conversion >20pp entre lecturas, o
**0 reviews** (que NO se aprueba: puede significar que esta apagado, no que
vaya bien).

**Trampa medida al calibrar los umbrales:** con muestras <8 reviews cualquier
ratio es ruido; el script no alerta por debajo de ese minimo. Un 0% sobre 5
reviews no es una regresion, es una semana tranquila.

**Y el dato que importa: `skill` = 0 en el 100% del historico.** El review
escribe memoria pero nunca destila una skill, asi que la libreria solo crece por
intervencion manual. Eso es la fila del harness vacia (matriz 3x3,
Xinming Tu 2026): se acumula experiencia sin compilarla en procedimiento.

### 2. ¿El sistema esta dentro de sus limites?
```bash
python3 ~/.hermes/scripts/skill-usage-audit.py 2>/dev/null | head -5
```
Cap: **100 skills activas** (arXiv 2605.24050: −21% de exito al inflar la
libreria; el cuello es la seleccion, no el contexto). Si se supera, podar
ANTES de permitir que se añada nada.

### 3. ¿Cuanto cuesta y cuanto falla?
```bash
DAYS=7 python3 ~/.hermes/scripts/cron-cost-telemetry.py 2>/dev/null | head -12
```
Alertar solo si: coste mensual sube >30% vs la semana previa, o algun job
supera 25% de runs con error.

### 4. Salud de memoria (heredado, sigue siendo valido)
```bash
python3 ~/.hermes/scripts/verify-memory-health.py 2>&1 | tail -3
```
FAIL solo al hard limit (2800 chars). La franja 2660-2800 es WARN, no fallo
— desalinear esto causo 8+ falsos FAIL (ver hermes-ops-pitfalls §1).

### 5. Contratos del sistema
```bash
python3 ~/.hermes/scripts/contract-verifier.py --json 2>&1 | tail -5
```

## Formato de salida

Si todo esta dentro de parametros: `[SILENT]`.

Si hay algo que requiera intervencion humana, maximo 6 lineas:
```
Aplicados 7d: N   (0 con descartes = sano; 0 sin nada = loop muerto)
Reviews 7d: N · conversion X% · vacios N   (alerta si <20% o >40% vacios)
Skills activas: N/100
Coste mensual: $X  (delta vs semana previa)
Jobs con >25% error: lista o ninguno
Memoria: OK / WARN / FAIL
```

## Antipatron que esta skill corrige

Verificar existencia en vez de impacto. Estos checks **no** son evidencia de
aprendizaje y por si solos no deben reportar verde:

- "los ficheros de hoy existen" → solo prueba que el cron corrio
- "estan indexados en FTS" → solo prueba que el sync funciona
- "hay N patrones cargados" → solo prueba que el JSON se lee

Ninguno responde a la pregunta real: **¿que hace el sistema hoy distinto de
ayer, y es mejor?**
