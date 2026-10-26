## 2. Contexto que expulsa al modelo de la GPU


El KV cache compite con los pesos por la misma VRAM:

```
bytes_KV = contexto x capas x kv_heads x head_dim x 2 x bytes_por_valor
```

Para un 8B tipico, pasar de **64K a 16K de contexto** libero ~1,8 GB y cambio
el reparto de 87% a 100% en GPU: generacion **+36%**, prompt eval **+74%**.

Un contexto de 64K "por si acaso" es caro. Dimensionar al uso real.

### 🔴 PERO hay un SUELO: el prompt del agente. Recortar de mas lo MATA

**Corregido el 17-sep-2026 tras una averia causada por esta misma seccion.**
La recomendacion de bajar a 16K era correcta para la VRAM y **catastrofica**
para el agente: el prompt de sistema de Hermes **no cabia**.

```
hermes prompt-size  ->  28 KB system + 59 KB de esquemas (45 tools) = 87 KB ~ 22K tokens
OLLAMA_CONTEXT_LENGTH=16384   ->  el prompt MINIMO ya desborda
```

Sintoma, y es engañoso de narices: **cualquier** consulta muere con

```
Context length exceeded (496 tokens). Cannot compress further.
```

Ese numero ridiculo (496, luego 514, luego 515) es el **mensaje del usuario**,
no la ventana. Comprimir no puede bajar del prompt de sistema, asi que falla
"sin poder comprimir mas" con un mensaje de dos lineas.

Lo peor es **cuando** se manifiesta: mientras el modelo remoto responda, nadie
lo nota. Solo al caer la cascada al local — justo el dia que hace falta — muere
el agente entero, CLI incluida.

**Regla dura:**

```
OLLAMA_CONTEXT_LENGTH  >=  2 x (prompt-size del agente en tokens)
```

Medir el suelo antes de elegir el numero, **no** poner el minimo que evite el
derrame:

```powershell
hermes prompt-size        # bytes totales / ~4 = tokens
```

En la maquina real: 32768. Y comprobar que **sigue cabiendo** despues de subirlo
(`ollama ps` debe seguir diciendo `100% GPU`). Si subir el contexto al suelo
minimo provoca derrame, el modelo es demasiado grande para esa GPU — se cambia
el modelo, no se baja el contexto por debajo del suelo.

> **Un fallback que no cabe no es una red de seguridad, es un fallo silencioso
> con fecha diferida.** Optimizar VRAM sin comprobar el suelo del consumidor es
> como ganar espacio quitando el airbag.

---
