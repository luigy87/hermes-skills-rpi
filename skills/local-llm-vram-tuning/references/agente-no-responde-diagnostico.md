# "El agente no responde": arbol de diagnostico

Sesion real del 17-sep-2026. Dos hipotesis mias **descartadas por evidencia**
antes de acertar. Se documentan los descartes porque el valor esta en el metodo,
no en la respuesta final.

---

## Sintoma

```
Context length exceeded (496 tokens). Cannot compress further.
```

En **todas** las vias (panel web y CLI), con cualquier prompt, incluso de 5
palabras.

---

## Lo que NO era (y como se descarto)

### Hipotesis 1: "el parser confunde el 429 del proveedor con un overflow"

Plausible: el proveedor remoto estaba devolviendo 429 (CAPTCHA antibot) justo
cuando fallaba. Descartado **ejecutando el clasificador real** con el cuerpo
exacto del error:

```python
from agent.error_classifier import _CONTEXT_OVERFLOW_PATTERNS
from agent.model_metadata import get_context_length_from_provider_error

get_context_length_from_provider_error(captcha_429, 128000)   # -> None  ✓ correcto
classify_api_error(captcha_429)
# -> reason=rate_limit, should_compress=False, should_fallback=True  ✓ correcto
```

El framework clasificaba **bien**. Hipotesis muerta.

### Hipotesis 2: "lo rompio mi cambio de config de hace un rato"

Descartado restaurando el backup y reproduciendo:

```powershell
Copy-Item config.yaml.bak-<fecha> config.yaml -Force
hermes -z "Di solo LISTO"      # -> MISMO error
```

> Sospechar del propio cambio esta bien. **Probarlo restaurando el backup** esta
> mejor que razonar sobre si "deberia" haberlo roto.

---

## La pista que lo resolvio: el numero CAMBIABA

496 -> 514 -> 515 entre ejecuciones.

Una ventana de contexto es **fija**. Un numero que varia con cada intento es el
tamaño del **mensaje**, no del limite. Eso reencuadro todo el problema.

Confirmado en el log, que mostraba la cascada completa:

```
Fallback activated: remoto-1 -> remoto-2 -> remoto-3 -> local
ERROR agent.conversation_loop: Context length exceeded: 514 tokens.
```

La cascada **funcionaba**. El destino final era el roto.

Causa raiz: `OLLAMA_CONTEXT_LENGTH` por debajo del prompt de sistema del agente.
Ver la seccion del SUELO en `SKILL.md`.

---

## Arbol reutilizable

```
"Context length exceeded (N tokens)" con N absurdamente pequeño
 |
 +- ¿N cambia entre intentos?
 |   SI -> N es el MENSAJE. El limite esta por debajo del prompt de sistema.
 |         -> medir `hermes prompt-size` y comparar con la ventana del modelo
 |   NO  -> puede ser una ventana mal declarada en config
 |
 +- ¿Falla tambien forzando el modelo local? (`--provider ... -m ...`)
 |   SI -> no es el proveedor remoto: es el local o la config
 |   NO -> es el remoto
 |
 +- ¿Falla con el config.yaml de backup?
 |   SI -> no lo causo tu ultimo cambio
 |
 +- ¿Coincide con el remoto devolviendo 429/5xx?
     SI -> el bug esta en el DESTINO de la cascada, no en la cascada
```

---

## Comandos que dieron la evidencia

```powershell
hermes prompt-size                       # el suelo real en bytes
hermes --provider custom:ollama-local -m <modelo> -z "Di solo LISTO"
ollama ps                                # columna PROCESSOR: cualquier %CPU = derrame
Get-Content "$H\logs\agent.log" -Tail 600 |
  Where-Object { $_ -match "Fallback|rate_limit|Context length" }
```

El log fue decisivo: sin el, la correlacion "429 remoto -> muerte en el local"
no se veia.

---

## Meta-leccion

**Un bug latente solo aparece cuando su rama se ejecuta.** El fallback llevaba
tiempo roto y nadie lo noto porque el camino feliz (remoto) siempre respondia.
Probar SIEMPRE la rama de fallo a proposito:

```powershell
# forzar el uso del fallback sin esperar a que el remoto se caiga
hermes --provider custom:ollama-local -m <modelo-de-fallback> -z "Responde: PONG"
```
