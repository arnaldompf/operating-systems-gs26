#!/usr/bin/env bash
# =============================================================================
# teste_falha.sh - Simula falhas e mostra a infraestrutura reagindo
#
# Uso: sudo ./scripts/teste_falha.sh [cenario]
#   app      mata a aplicação com kill -9 -> systemd reinicia sozinho
#   monitor  mata o próprio monitor com kill -9 -> systemd reinicia sozinho
#   cpu      estressa a CPU -> monitor gera ALERTA de CPU e depois RECUPERADO
#   memoria  ocupa memória  -> ALERTA de MEMORIA
#   disco    enche o disco acima do limite -> ALERTA de DISCO (arquivo é apagado no fim)
#   todos    executa todos em sequência (padrão)
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/lib_log.sh"
require_root
start_script "$@"

ALERT_LOG="$LOG_DIR/alertas.log"
ARQ_DISCO="/var/tmp/citizentech_teste_disco.bin"
# shellcheck disable=SC2154
trap 'c=$?; rm -f "$ARQ_DISCO"; pkill -x stress-ng 2>/dev/null; (exit $c); _on_exit' EXIT

pid_de() { systemctl show -p MainPID --value "$1"; }

# Espera aparecer no alertas.log uma linha nova contendo o texto (máx. N segundos)
esperar_alerta() {
    local texto="$1" limite="$2" inicio_linhas="$3" t=0
    while (( t < limite )); do
        if tail -n +"$((inicio_linhas + 1))" "$ALERT_LOG" 2>/dev/null | grep -q "$texto"; then
            ok "Detectado no alertas.log:"
            tail -n +"$((inicio_linhas + 1))" "$ALERT_LOG" | grep "$texto" | tail -1 | tee -a "$SCRIPT_LOG"
            return 0
        fi
        sleep 2; t=$((t + 2))
    done
    erro "Não apareceu '$texto' em ${limite}s"
    return 1
}

linhas_alerta() { wc -l < "$ALERT_LOG" 2>/dev/null || echo 0; }

testar_reinicio() {
    local svc="$1"
    section "TESTE: kill -9 em $svc"
    local antes; antes=$(pid_de "$svc")
    local reinicios; reinicios=$(systemctl show -p NRestarts --value "$svc")
    info "Estado antes: $(systemctl is-active "$svc"), PID $antes, reinícios até agora: $reinicios"
    warn "Matando o processo $antes com SIGKILL..."
    kill -9 "$antes"
    local t0; t0=$(date +%s%N)
    for _ in {1..60}; do
        local agora; agora=$(pid_de "$svc")
        if [[ "$agora" != "0" && "$agora" != "$antes" ]] && systemctl is-active --quiet "$svc"; then
            local ms=$(( ($(date +%s%N) - t0) / 1000000 ))
            ok "$svc voltou sozinho em ${ms} ms - novo PID $agora (reinícios: $(systemctl show -p NRestarts --value "$svc"))"
            journalctl -u "$svc" -n 4 --no-pager | tee -a "$SCRIPT_LOG"
            return 0
        fi
        sleep 0.5
    done
    erro "$svc não voltou em 30s"
    return 1
}

teste_app() {
    testar_reinicio alerta-corrego
    sleep 2
    if curl -fsS -m 5 http://127.0.0.1/health >/dev/null; then ok "Painel respondendo de novo em http://127.0.0.1/"; fi
}

teste_monitor() { testar_reinicio citizentech-monitor; }

teste_cpu() {
    section "TESTE: sobrecarga de CPU (limite ${CPU_LIMIT}%)"
    local n; n=$(linhas_alerta)
    info "Iniciando stress-ng em $(nproc) núcleos por 60s"
    stress-ng --cpu "$(nproc)" --cpu-load 100 --timeout 60s \
        >/dev/null 2>&1 &
    esperar_alerta "ALERTA\] CPU" 50 "$n"
    info "Aguardando o fim da carga para registrar a recuperação..."
    wait
    esperar_alerta "RECUPERADO\] CPU" 40 "$n"
}

teste_memoria() {
    section "TESTE: consumo de memória (limite ${MEM_LIMIT}%)"
    local n; n=$(linhas_alerta)
    local total_kb usado_pct alvo_kb
    total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    usado_pct=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d", (t-a)*100/t}' /proc/meminfo)
    alvo_kb=$(( total_kb * (MEM_LIMIT + 8 - usado_pct) / 100 ))
    info "Memória em ${usado_pct}%. Alocando $((alvo_kb / 1024)) MB por 45s"
    stress-ng --vm 1 --vm-bytes "${alvo_kb}k" --vm-keep --timeout 45s >/dev/null 2>&1 &
    esperar_alerta "ALERTA\] MEMORIA" 40 "$n"
    wait
    esperar_alerta "RECUPERADO\] MEMORIA" 40 "$n"
}

teste_disco() {
    section "TESTE: disco cheio (limite ${DISK_LIMIT}%)"
    local n; n=$(linhas_alerta)
    local total_kb usado_kb livre_kb alvo_kb
    read -r total_kb usado_kb livre_kb < <(df -k --output=size,used,avail "$DISK_PATH" | tail -1)
    alvo_kb=$(( total_kb * (DISK_LIMIT + 3) / 100 - usado_kb ))
    if (( alvo_kb <= 0 )); then
        warn "Disco já está acima do limite"
    elif (( livre_kb - alvo_kb < 512000 )); then
        warn "Teste de disco pulado: deixaria menos de 500 MB livres"
        return 0
    else
        info "Disco em $(df --output=pcent "$DISK_PATH" | tail -1 | tr -d ' '). Criando arquivo de $((alvo_kb / 1024)) MB"
        fallocate -l "${alvo_kb}K" "$ARQ_DISCO"
        info "Disco agora em $(df --output=pcent "$DISK_PATH" | tail -1 | tr -d ' ')"
    fi
    esperar_alerta "ALERTA\] DISCO" 40 "$n"
    rm -f "$ARQ_DISCO"
    info "Arquivo removido, disco em $(df --output=pcent "$DISK_PATH" | tail -1 | tr -d ' ')"
    esperar_alerta "RECUPERADO\] DISCO" 40 "$n"
}

CENARIO="${1:-todos}"
case "$CENARIO" in
    app) teste_app ;;
    monitor) teste_monitor ;;
    cpu) teste_cpu ;;
    memoria) teste_memoria ;;
    disco) teste_disco ;;
    todos) teste_app; teste_monitor; teste_cpu; teste_memoria; teste_disco ;;
    *) echo "Cenário inválido: $CENARIO (use app|monitor|cpu|memoria|disco|todos)"; exit 2 ;;
esac

section "Últimos alertas registrados"
tail -n 12 "$ALERT_LOG" | tee -a "$SCRIPT_LOG"
ok "Teste de falha '$CENARIO' concluído. Trilha completa: sudo $INSTALL_DIR/bin/relatorio_auditoria.sh"
