#!/usr/bin/env bash
# Chamado por citizentech-falha@.service (OnFailure=) quando um serviço entra em falha.
set -uo pipefail
BIN_DIR="$(dirname "$(readlink -f "$0")")"
if [[ -f "$BIN_DIR/lib_log.sh" ]]; then source "$BIN_DIR/lib_log.sh"; else source "$BIN_DIR/../scripts/lib_log.sh"; fi

SERVICO="${1:-desconhecido}"
start_script "$SERVICO"
msg="Serviço $SERVICO entrou em estado de falha: $(systemctl show -p Result --value "$SERVICO" 2>/dev/null)"
echo "$(date '+%F %T') [ALERTA] [systemd] $msg" >> "$LOG_DIR/alertas.log"
log ALERTA "$msg"
journalctl -u "$SERVICO" -n 15 --no-pager >> "$SCRIPT_LOG" 2>&1
