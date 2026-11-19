#!/usr/bin/env bash
# status.sh - visão geral do servidor (rede, serviços, métricas e alertas)
set -uo pipefail
source "$(dirname "$0")/lib_log.sh"

echo "================ ALERTA CÓRREGO - $(hostname) - $(date '+%F %T') ================"
echo
echo "## Rede"
echo "Hostname:   $(hostname -f 2>/dev/null || hostname)"
ip -br -4 addr | grep -v '^lo' | sed 's/^/Interface:  /'
echo "Nome app:   $APP_INTERNAL_HOST -> $(getent hosts "$APP_INTERNAL_HOST" | awk '{print $1}')"
echo "DNS:        $(resolvectl dns 2>/dev/null | awk -F': ' '/Global/{print $2}')"
echo "Firewall:   $(ufw status 2>/dev/null | head -1)"
echo
echo "## Serviços"
for svc in alerta-corrego alerta-corrego-mqtt nginx citizentech-monitor citizentech-healthcheck.timer auditd; do
    printf "  %-32s %-10s reinícios: %s\n" "$svc" "$(systemctl is-active "$svc")" "$(systemctl show -p NRestarts --value "$svc" 2>/dev/null)"
done
echo
echo "## Últimas métricas (CPU;MEM;DISCO)"
tail -n 5 "$LOG_DIR/metricas.log" 2>/dev/null
echo
echo "## Últimos alertas"
tail -n 8 "$LOG_DIR/alertas.log" 2>/dev/null || echo "(nenhum)"
echo
echo "## Aplicação"
curl -fsS -m 5 http://127.0.0.1/api/status 2>/dev/null \
  | jq -r '"  Risco: \(.risco) | nível \(.atual.nivel_pct // "-")% | chuva \(.atual.chuva_mmh // "-") mm/h | origem \(.atual.origem // "-")"' \
  || echo "  App não respondeu"
echo "  Painel: http://$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')/"
