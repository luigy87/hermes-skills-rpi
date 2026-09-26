#!/bin/bash
# nnp-probe.sh — mide que directivas systemd IMPLICAN NoNewPrivileges
# en un servicio --user, SIN tocar el gateway real.
#
# Por que existe: `systemctl show` MIENTE (reporta NoNewPrivileges=no
# mientras el proceso arranca con NoNewPrivs=1). La unica verdad esta en
# /proc/PID/status. Este probe la lee desde dentro del propio servicio.
#
# Uso:   bash nnp-probe.sh
# Salida: RESULT_<NOMBRE>=0|1  (1 = esa directiva rompe sudo)
set -u
UNIT="$HOME/.config/systemd/user/nnp-probe.service"

probe() {
  local name="$1"; shift
  cat > "$UNIT" <<EOF
[Unit]
Description=probe $name
[Service]
Type=oneshot
$*
ExecStart=/bin/bash -c 'echo RESULT_$name=\$(grep NoNewPrivs /proc/self/status | awk "{print \\\$2}")'
StandardOutput=journal
EOF
  systemctl --user daemon-reload
  systemctl --user reset-failed nnp-probe.service 2>/dev/null
  systemctl --user start nnp-probe.service 2>&1 | head -2
  sleep 1
  journalctl --user -u nnp-probe.service --since "-15s" --no-pager 2>/dev/null \
    | grep -o "RESULT_[A-Za-z]*=[01]" | tail -1
}

probe BASELINE   ""
probe PRIVATETMP "PrivateTmp=true"
probe RESTRICTNS "RestrictNamespaces=true"
probe RESTRICTRT "RestrictRealtime=true"
probe LOCKPERS   "LockPersonality=true"
probe RESTRICTAF "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK"

# Prueba end-to-end: sudo desde el contexto endurecido
cat > "$UNIT" <<'EOF'
[Unit]
Description=probe sudo
[Service]
Type=oneshot
Environment="PYTHONSAFEPATH=1"
PrivateTmp=true
ExecStart=/bin/bash -c 'echo NNP=$(grep NoNewPrivs /proc/self/status | awk "{print \$2}"); sudo -n systemctl is-active caddy >/dev/null 2>&1 && echo SUDO=OK || echo SUDO=ROTO'
StandardOutput=journal
EOF
systemctl --user daemon-reload
systemctl --user reset-failed nnp-probe.service 2>/dev/null
systemctl --user start nnp-probe.service 2>&1 | head -2
sleep 2
echo "--- config final del gateway ---"
journalctl --user -u nnp-probe.service --since "-20s" --no-pager 2>/dev/null \
  | grep -oE "(NNP|SUDO)=[A-Za-z0-9]+"

rm -f "$UNIT"
systemctl --user daemon-reload
systemctl --user reset-failed nnp-probe.service 2>/dev/null
echo "probe limpiado"
