# Cron Architecture v5 — Consolidation (10 Aug 2026)

## Before → After

| Antes | Después | Razón |
|---|---|---|
| 70 crons, 69 activos | 66 activos | -4 duplicados +1 silent check |
| 27 AGENT deepseek-v4-pro | 22 AGENT deepseek-v4-flash | -75% coste tokens |
| 3 digests AGENT/día | 1 digest nocturno AGENT | Solo ruido accionable |
| Self-Healing AGENT hourly | Self-Healing v2 no_agent 30min | 66K→0 tokens/run |
| System Dream + Sunday Audit | Weekly System Audit unificado | Sin solapamiento |
| Session Keep-Alive AGENT | no_agent script curl | 0 tokens |
| alibaba-token-plan en crons | deepseek directo | 0 rate limits 429 |

## Reglas permanentes post-consolidación

1. **Token Plan solo conversación.** Límites sliding window (5h/7d) no diseñados para crons.
2. **Todo cron AGENT → deepseek-v4-flash.** Pro solo brain/estrategia/auditoría semanal.
3. **Único digest: nocturno.** Máx 15 líneas. Solo acción humana. Si OK: 1 línea.
4. **NUNCA listar en digest:** auto-reparaciones, mejoras, métricas normales, rate limits.
5. **Silent checks no_agent cubren el resto.** stdout vacío = no molestar.
