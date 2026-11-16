# Caso: MCP server instalado vía nvm, `hermes mcp test` en falso "✓ Connected" (15-sep-2026)

> Extraído de SKILL.md el 15-nov-2026 (pulido de skills).

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
