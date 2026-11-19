#!/usr/bin/env bash
# =============================================================================
# provision.sh - Provisiona o servidor do Alerta Córrego do zero, de forma automática
#
# Uso:  sudo ./provision.sh            # executa todas as etapas
#       sudo ./provision.sh 2 3        # executa só as etapas 2 e 3
#
#   1 - Infraestrutura: hostname, rede interna, DNS, /etc/hosts, firewall
#   2 - Aplicação: dependências, código, venv, systemd, nginx
#   3 - Monitoramento: serviço tolerante a falhas + healthcheck
#   4 - Auditoria: auditd + relatório
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source scripts/lib_log.sh
require_root
start_script "$@"

ETAPAS=("$@")
[[ ${#ETAPAS[@]} -eq 0 ]] && ETAPAS=(1 2 3 4)
declare -A SCRIPT=([1]=01_infra.sh [2]=02_app.sh [3]=03_monitoramento.sh [4]=04_auditoria.sh)

chmod +x scripts/*.sh bin/*.sh
INICIO=$(date +%s)
for etapa in "${ETAPAS[@]}"; do
    s="${SCRIPT[$etapa]:-}"
    [[ -n "$s" ]] || { erro "Etapa inválida: $etapa"; exit 2; }
    echo
    info "################ ETAPA $etapa/4: $s ################"
    t0=$(date +%s)
    ./scripts/"$s"
    ok "Etapa $etapa concluída em $(( $(date +%s) - t0 ))s"
done

echo
ok "Provisionamento concluído em $(( $(date +%s) - INICIO ))s"
echo
./scripts/status.sh
