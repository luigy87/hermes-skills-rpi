# Barrer puertos sin tumbar el host

> Extraído de SKILL.md el 15-nov-2026 (pulido de skills).

Cuando hace falta demostrar que un servicio esta caido de verdad (y no
suponerlo desde un cache rancio), el barrido de puertos es legitimo. Lo que
tumba maquinas pequenas **no es el escaneo: son los forks.** Un
`nc` por puerto con `xargs -P64` lanza miles de procesos y en un host con poca
RAM o con un supervisor agresivo se lleva por delante al proceso padre.

Builtin de bash, cero forks:

```bash
found=""
for p in $(seq 1024 65535); do
  (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null && { found="$found $p"; exec 3<&- 2>/dev/null; }
done
echo "ABIERTOS:$found"
```

Desde otra maquina, el equivalente barato es un `ThreadPoolExecutor` con
`socket` y `settimeout` corto — hilos, no procesos. Verificado 10-sep-2026:
los 65.535 puertos en tandas, sin tumbar nada, y el resultado (un unico puerto
abierto) convirtio una hipotesis en un hecho.

**El valor no es encontrar el puerto: es poder afirmar la ausencia con
evidencia** en vez de repetir "parece que no responde".
