#!/usr/bin/env bash
# =============================================================================
# relatorio_auditoria.sh - consolida a trilha de auditoria do servidor
#
#   - execuções dos scripts (quem, quando, resultado)  -> audit.log
#   - alertas e recuperações                           -> alertas.log
#   - eventos do auditd por chave (rede, config, kill)  -> ausearch/aureport
# Salva uma cópia em $LOG_DIR/relatorios/
# =============================================================================
set -uo pipefail
BIN_DIR="$(dirname "$(readlink -f "$0")")"
if [[ -f "$BIN_DIR/lib_log.sh" ]]; then source "$BIN_DIR/lib_log.sh"; else source "$BIN_DIR/../scripts/lib_log.sh"; fi
require_root
start_script "$@"

mkdir -p "$LOG_DIR/relatorios"
SAIDA="$LOG_DIR/relatorios/auditoria_$(date +%Y%m%d_%H%M%S).txt"

{
    echo "=================================================================="
    echo " RELATÓRIO DE AUDITORIA - $(hostname) - $(date '+%F %T')"
    echo "=================================================================="
    echo
    echo "### 1. Execuções de scripts (últimas 25) - $LOG_DIR/audit.log"
    tail -n 25 "$LOG_DIR/audit.log" 2>/dev/null || echo "(sem registros)"
    echo
    echo "### 2. Falhas de execução"
    grep "status=FALHA" "$LOG_DIR/audit.log" 2>/dev/null | tail -n 10 || echo "(nenhuma)"
    echo
    echo "### 3. Alertas de infraestrutura (últimos 20) - $LOG_DIR/alertas.log"
    tail -n 20 "$LOG_DIR/alertas.log" 2>/dev/null || echo "(sem alertas)"
    echo
    echo "### 4. Totais de alertas por tipo"
    grep -o '\[ALERTA\] [A-Za-z_]*' "$LOG_DIR/alertas.log" 2>/dev/null | sort | uniq -c | sort -rn || true
    echo
    if command -v aureport >/dev/null; then
        # --input-logs: sem ele o ausearch lê da entrada padrão quando roda fora de um terminal
        echo "### 5. auditd - eventos por chave"
        aureport --input-logs -k --summary -i 2>/dev/null | grep -E 'citizentech|total' || echo "(sem eventos)"
        echo
        echo "### 6. auditd - alterações de rede/DNS/hostname/firewall (últimas)"
        for k in citizentech_rede citizentech_firewall; do
            ausearch --input-logs -k "$k" --format text 2>/dev/null | grep -vE '(add|remove)_rule' | tail -n 5
        done
        echo
        echo "### 7. auditd - processos mortos com kill -9 (teste de falha)"
        ausearch --input-logs -k citizentech_kill --format text 2>/dev/null | grep -vE '(add|remove)_rule' | tail -n 10 || echo "(nenhum)"
    fi
    echo
    echo "### 8. Estado atual dos serviços"
    systemctl --no-pager --plain list-units 'alerta-corrego*' 'citizentech*' nginx.service auditd.service 2>/dev/null
} | tee "$SAIDA"

ok "Relatório salvo em $SAIDA"
