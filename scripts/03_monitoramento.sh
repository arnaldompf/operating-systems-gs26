#!/usr/bin/env bash
# =============================================================================
# 03_monitoramento.sh - Instala o monitoramento como serviço tolerante a falhas
#
#   1. Ferramentas (sysstat, stress-ng para o teste de falha)
#   2. citizentech-monitor.service  - monitor contínuo (Restart=always + watchdog)
#   3. citizentech-healthcheck.timer - testa a app a cada minuto e reinicia se cair
#   4. Verificação
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib_log.sh"
require_root
start_script "$@"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEBIAN_FRONTEND=noninteractive

section "1/4 Ferramentas de monitoramento"
run apt-get install -y sysstat stress-ng procps
install -m 755 "$REPO_DIR"/bin/*.sh "$INSTALL_DIR/bin/"
install -m 644 "$REPO_DIR/scripts/lib_log.sh" "$INSTALL_DIR/bin/lib_log.sh"
install -m 644 "$REPO_DIR/config/citizentech.env" /etc/citizentech/citizentech.env
ok "Limites: CPU ${CPU_LIMIT}% | MEM ${MEM_LIMIT}% | DISCO ${DISK_LIMIT}% | intervalo ${MONITOR_INTERVAL}s"

section "2/4 Serviço de monitoramento"
for unit in citizentech-monitor.service citizentech-healthcheck.service citizentech-healthcheck.timer citizentech-falha@.service; do
    render "$REPO_DIR/config/systemd/$unit" "/etc/systemd/system/$unit"
done
run systemctl daemon-reload
run systemctl enable citizentech-monitor.service
run systemctl restart citizentech-monitor.service
ok "citizentech-monitor.service: Restart=always, WatchdogSec=60, OnFailure=registro de falha"

section "3/4 Healthcheck periódico"
run systemctl enable --now citizentech-healthcheck.timer
ok "citizentech-healthcheck.timer: a cada 1 minuto"

section "4/4 Verificação"
sleep $(( MONITOR_INTERVAL + 3 ))
if systemctl is-active --quiet citizentech-monitor; then
    ok "Monitor ativo (PID $(systemctl show -p MainPID --value citizentech-monitor)) - $(systemctl show -p StatusText --value citizentech-monitor)"
else
    erro "Monitor não está ativo"; exit 1
fi
systemctl is-active --quiet citizentech-healthcheck.timer && ok "Timer ativo - próxima execução: $(systemctl list-timers citizentech-healthcheck.timer --no-pager | awk 'NR==2{print $2, $3}')"
info "Últimas métricas ($LOG_DIR/metricas.log):"
tail -n 3 "$LOG_DIR/metricas.log" | tee -a "$SCRIPT_LOG"
