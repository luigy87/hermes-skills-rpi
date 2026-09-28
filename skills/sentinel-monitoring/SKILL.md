---
name: sentinel-monitoring
description: "Silent no_agent monitoring for Hermes ecosystems."
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [monitoring, sentinel, cloudflare, seo, bots, security, cron]
    model: none
---

# Sentinel Monitoring

Script `no_agent` (0 tokens) que verifica 10 categorías del ecosistema. Silencioso si OK. Entrega solo alertas accionables.

## Instalación

```bash
cronjob action=create name="Sentinel" schedule="0 8,15 * * *" \
  script="daily-sentinel.py" no_agent=true deliver=origin
```

## Categorías

| # | Verifica |
|---|---|
| 1 | Sistema: disco, RAM, CPU, locks, procesos |
| 2 | Red: DNS, nameservers CF, conectividad |
| 3 | Cloudflare: headers seguridad, ai_bots_protection |
| 4 | SSL: expiración, issuer |
| 5 | SEO: robots.txt, sitemap, GSC token, analytics |
| 6 | Contenido: gap data↔HTML, meta tags, JSON-LD, AdSense |
| 7 | Crons: errores, scripts rotos, fire_claim stale |
| 8 | Tokens: DeepSeek, GSC, Twitter, Token Plan 429 |
| 9 | Seguridad: SSH, hardcoded keys, UFW |
| 10 | Trading/Backups: estado desks, backup freshness |
| 11 | **Triaje de `errors.log`** (añadido 21-sep-2026) |

## Triaje semantico de errors.log

`daily-silent-check.py` gano `check_error_log()`, que delega en
`scripts/jev_triage.py`: clasifica cada EVENTO del log con un modelo de
decision (severidad + categoria + si necesita un humano) en vez de con grep.

Motivo: `errors.log` acumulaba >2.200 lineas que nadie leia. En su primera
pasada real encontro **3 averias vigentes** invisibles para cualquier regex,
entre ellas el sistema de checkpoints del agente llevando 2 dias roto.

Coste medido: ~$0.0007 por pasada (centimos al año). Sin cron nuevo — viaja
dentro del job que ya corria a las 8:20 y 15:20.

Tres invariantes que NO se pueden romper al tocarlo:

- **Fail-closed y aislado**: `triage()` devuelve `[]` ante cualquier fallo y
  jamas lanza. Es un extra; no puede tumbar los 11 checks que ya funcionaban.
- **Watermark de 24 h** en `state/jev-triage-seen.json`: se marca TODO lo
  evaluado, sea alerta o no. Sin esto la misma averia hablaria 2 veces al dia
  para siempre y volveria ignorable el canal.
- **Umbrales de dos ejes** (`SEV_SOLO`, `MIN_REPETICIONES`): calibrados contra
  el log real. Al tocarlos, correr el control negativo que exige que las
  averias ya verificadas sigan alertando.

Metodo, pitfalls y matriz de tests: skill `filtro-guard-diagnostico`,
Regla 19d + `references/triaje-semantico-system-one.md`.

## Resolver un informe del Sentinel ("soluciona esto")

1. **Agrupar por causa raíz, no por línea**: varias firmas suelen ser la misma avería
   (p.ej. 429 de visión + "no fallback_chain" = una sola). Contar apariciones por día
   (`grep ... | cut -c1-10 | sort | uniq -c`) para saber si crece, baja o ya pasó.
2. **Reproducir cada causa en vivo** (curl al endpoint, llamada real al LLM con el mismo
   `max_tokens`) antes de tocar nada; un log viejo no prueba que siga roto.
3. **Editar el código que CORRE**: sacar la ruta del proceso vivo (`ps aux | grep gateway`,
   `cat $(which hermes)`); puede haber otra copia en `~/.local/lib/.../site-packages` que no se usa.
4. `config.yaml` no se escribe con patch/write_file (lo bloquea el guard): usar
   `hermes config set clave 'valor-json'`. El aviso "not a recognized config key" puede ser falso:
   confirmar con `grep` que el código lee esa clave.
5. Credenciales de un proveedor que no se usa: `hermes auth remove <prov> <n>` (suprime fuentes)
   en vez de dejar que avise cada pocas horas.
6. Cambios en config/mem0.json requieren reinicio del gateway: programarlo con
   `systemd-run --user --on-active=180 ... gateway restart` (nunca reiniciar desde el propio turno).
7. Parche en el core de Hermes = se pierde al actualizar: hacer backup, probar rama feliz Y de
   fallo (HERMES_HOME temporal), y decirlo en el informe.
8. Cambiar el **modelo principal** es decisión del usuario: diagnosticar, recomendar 1 opción, preguntar.
   Todo lo demás (fallbacks, límites, supresiones) se arregla sin preguntar.

Causas ya vistas y su arreglo:
- `mem0 ... Error parsing extraction response` = respuesta JSON truncada por `max_tokens`
  bajo (el modelo razona y gasta tokens): subir `oss.llm.config.max_tokens` en `mem0.json`
  (12000 verificado con 60 hechos → JSON completo).
- `Auxiliary vision: ... no fallback_chain` tras 429 de modelos `:free`: añadir al final de
  `auxiliary.vision.fallback_chain` un modelo de pago barato (gemini-2.5-flash).
- 429 `captcha_required` del bridge qwen-web: el proveedor principal está caído; el fallback
  lo tapa pero cada turno paga el error → proponer cambio de principal.

## Cloudflare Bot Unblock

```bash
curl -s -X PUT -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/bot_management" \
  -H "Content-Type: application/json" \
  -d '{"enable_js":false,"fight_mode":false,"ai_bots_protection":"disabled","crawler_protection":"disabled"}'
```

Solo PUT (no PATCH). Requiere `enable_js` y `fight_mode` en el payload.

## Pitfalls

- NUNCA convertir a AGENT.
- Filtrar crons semanales del check ">24h sin ejecutar" (`_runs_daily()` verifica dom=`*` y dow=`*`).
- **Excluir jobs REACTIVOS del check >26h**: Post-Publication Chains, Post-Learning Verifier y similares son jobs que responden a eventos (publicaciones), no a horario fijo. El sentinel debe tener `_is_reactive()` que excluya por nombre (patrones: "post-publication", "post-learning", "chain"). Sin esto, generan falsos positivos cuando no hay publicación ese día.
- Sincronizar Post-Publication Chains 10 min DESPUÉS del publisher correspondiente (ej: Trend-to-Article 07:00 → Chain 07:15, EEAT Publisher 19:10 → Chain 19:15). Nunca antes.
- Excluir locks `kanban.db.dispatch.lock` y `.tick.lock`.
- Token Plan solo conversación, nunca crons (429 sliding window).
