# Skills de agentes que uso en una Raspberry Pi 5

Soy Luigy y llevo meses con un agente autonomo ([Hermes Agent](https://github.com/NousResearch/hermes-agent))
funcionando 24/7 en una Raspberry Pi 5: publica una web, vigila su propio sistema y se repara
solo. Estas son las **skills** (instrucciones reutilizables para el agente) que más me han servido.

Cada una salió de un fallo real, no de la teoría: por eso casi todas explican **por qué** existe
la regla. Están escritas para Hermes, pero la idea sirve para Claude Code, Codex u otros agentes.

📖 Lo que voy aprendiendo, con pruebas y números reales: **[lafronteraia.com](https://lafronteraia.com/herramientas/#skills-agentes)**

| Skill | Para qué sirve |
|---|---|
| [`systematic-debugging`](skills/systematic-debugging/SKILL.md) | Depurar por causa raíz en 4 fases |
| [`test-driven-development`](skills/test-driven-development/SKILL.md) | TDD para agentes: test antes que código |
| [`sentinel-monitoring`](skills/sentinel-monitoring/SKILL.md) | Vigilancia silenciosa sin gastar tokens |
| [`watchers`](skills/watchers/SKILL.md) | Vigilar RSS, APIs y GitHub sin repetir avisos |
| [`typesafe-jev`](skills/typesafe-jev/SKILL.md) | Jev: decisiones atómicas baratas en vez de regex frágil |
| [`process-state-forensics`](skills/process-state-forensics/SKILL.md) | Config correcta pero servicio roto: auditar el proceso vivo |
| [`autonomous-hardening`](skills/autonomous-hardening/SKILL.md) | Endurecer un agente que no tiene a un humano al lado |
| [`trajectory-log`](skills/trajectory-log/SKILL.md) | Depurar un turno de agente paso a paso |
| [`local-llm-vram-tuning`](skills/local-llm-vram-tuning/SKILL.md) | LLM local lento o que no cabe en memoria |
| [`post-learning-verifier`](skills/post-learning-verifier/SKILL.md) | Medir si el aprendizaje cambió algo de verdad |
| [`humanizer`](skills/humanizer/SKILL.md) | Quitar el tono de IA a un texto |

## Lo que NO hay aquí
Ni claves, ni mi configuración, ni nada de mis cuentas. Las rutas, IPs e identificadores se
sustituyen por marcadores (`<IP>`, `~/.hermes`...) y cada publicación pasa por dos escáneres
de secretos (gitleaks y uno propio) y un filtro de datos personales. Si alguno salta, no se publica.

## Cómo usarlas
Copia la carpeta de la skill que quieras en el directorio de skills de tu agente
(`~/.hermes/skills/` en Hermes, `.claude/skills/` en Claude Code) y adáptala a tu sistema.

Licencia MIT. Se actualiza sola cada semana desde mi Pi.
