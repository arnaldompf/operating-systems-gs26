#!/usr/bin/env bash
# =============================================================================
# 04_auditoria.sh - Auditoria do servidor com auditd
#
#   1. Instala e habilita o auditd
#   2. Aplica as regras CitizenTech (config/audit/citizentech.rules):
#      app, configs, rede/DNS, firewall, sudoers, kill -9, execução dos scripts
#   3. Gera o primeiro relatório de auditoria
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib_log.sh"
require_root
start_script "$@"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEBIAN_FRONTEND=noninteractive

section "1/3 auditd"
run apt-get install -y auditd
run systemctl enable --now auditd
ok "auditd ativo"

section "2/3 Regras de auditoria"
install -m 640 "$REPO_DIR/config/audit/citizentech.rules" /etc/audit/rules.d/citizentech.rules
run augenrules --load
ok "$(auditctl -l | grep -c citizentech) regras CitizenTech carregadas:"
auditctl -l | grep citizentech | tee -a "$SCRIPT_LOG"

section "3/3 Relatório inicial"
# Gera um evento de teste para comprovar que a auditoria está registrando
touch /etc/citizentech/.auditoria_teste && rm -f /etc/citizentech/.auditoria_teste
sleep 1
"$INSTALL_DIR/bin/relatorio_auditoria.sh" > /dev/null
ok "Relatório gerado em $LOG_DIR/relatorios/ (ver: sudo $INSTALL_DIR/bin/relatorio_auditoria.sh)"
