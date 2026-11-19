#!/usr/bin/env bash
# =============================================================================
# monitor.sh - monitor contínuo de infraestrutura (roda como serviço systemd)
#
# A cada $MONITOR_INTERVAL segundos:
#   - mede CPU, memória e disco e grava em metricas.log
#   - se passar do limite, gera ALERTA em alertas.log + journald (com o processo
#     que mais consome) e, quando normalizar, registra RECUPERADO
#   - verifica se os serviços da aplicação estão ativos
#   - publica o estado em infra_status.json (lido pelo painel web)
#   - avisa o watchdog do systemd que está vivo
# =============================================================================
set -uo pipefail
BIN_DIR="$(dirname "$(readlink -f "$0")")"
if [[ -f "$BIN_DIR/lib_log.sh" ]]; then source "$BIN_DIR/lib_log.sh"; else source "$BIN_DIR/../scripts/lib_log.sh"; fi

ALERT_LOG="$LOG_DIR/alertas.log"
METRICS_LOG="$LOG_DIR/metricas.log"
STATUS_FILE="$STATE_DIR/infra_status.json"
SERVICOS="alerta-corrego alerta-corrego-mqtt nginx"
mkdir -p "$STATE_DIR"

declare -A ultimo_alerta=()
declare -A em_alerta=()

notificar_systemd() {
    [[ -n "${NOTIFY_SOCKET:-}" ]] && systemd-notify --pid=$$ "$@" 2>/dev/null
    return 0
}

cpu_uso() {
    local u1 n1 s1 i1 w1 q1 sq1 st1 u2 n2 s2 i2 w2 q2 sq2 st2
    read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
    sleep 1
    read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
    local total=$(( (u2+n2+s2+i2+w2+q2+sq2+st2) - (u1+n1+s1+i1+w1+q1+sq1+st1) ))
    local ocioso=$(( (i2+w2) - (i1+w1) ))
    (( total > 0 )) && echo $(( 100 * (total - ocioso) / total )) || echo 0
}

mem_uso() {
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d", (t-a)*100/t}' /proc/meminfo
}

disco_uso() {
    df --output=pcent "$DISK_PATH" | tail -1 | tr -dc '0-9'
}

maior_consumidor() {
    # $1 = coluna de ordenação (%cpu ou %mem)
    ps -eo pid=,comm=,"$1"= --sort=-"$1" | awk 'NR==1{printf "%s (pid %s, %s%%)", $2, $1, $3}'
}

registrar_alerta() {
    local chave="$1" mensagem="$2" agora
    agora=$(date +%s)
    if [[ -z "${em_alerta[$chave]:-}" ]] || (( agora - ${ultimo_alerta[$chave]:-0} >= ALERT_COOLDOWN )); then
        echo "$(date '+%F %T') [ALERTA] $mensagem" >> "$ALERT_LOG"
        log ALERTA "$mensagem"
        ultimo_alerta[$chave]=$agora
    fi
    em_alerta[$chave]=1
}

registrar_normal() {
    local chave="$1" mensagem="$2"
    if [[ -n "${em_alerta[$chave]:-}" ]]; then
        echo "$(date '+%F %T') [RECUPERADO] $mensagem" >> "$ALERT_LOG"
        ok "RECUPERADO: $mensagem"
        unset "em_alerta[$chave]"
    fi
}

verificar() {
    local recurso="$1" valor="$2" limite="$3" detalhe="$4"
    if (( valor >= limite )); then
        registrar_alerta "$recurso" "$recurso em ${valor}% (limite ${limite}%) - $detalhe"
        return 0
    fi
    registrar_normal "$recurso" "$recurso voltou ao normal: ${valor}% (limite ${limite}%)"
    return 1
}

start_script
info "Monitor iniciado: intervalo ${MONITOR_INTERVAL}s, limites CPU ${CPU_LIMIT}% / MEM ${MEM_LIMIT}% / DISCO ${DISK_LIMIT}%"
[[ -f "$METRICS_LOG" ]] || echo "data_hora;cpu_pct;mem_pct;disco_pct;servicos_inativos" > "$METRICS_LOG"
notificar_systemd --ready --status="Monitorando CPU, memória, disco e serviços"

while true; do
    cpu=$(cpu_uso); mem=$(mem_uso); disco=$(disco_uso)

    cpu_a=false; mem_a=false; disco_a=false
    verificar CPU "$cpu" "$CPU_LIMIT" "maior consumo: $(maior_consumidor %cpu)" && cpu_a=true
    verificar MEMORIA "$mem" "$MEM_LIMIT" "maior consumo: $(maior_consumidor %mem)" && mem_a=true
    verificar DISCO "$disco" "$DISK_LIMIT" "partição $DISK_PATH, livre: $(df -h --output=avail "$DISK_PATH" | tail -1 | tr -d ' ')" && disco_a=true

    inativos=""
    for svc in $SERVICOS; do
        if systemctl is-active --quiet "$svc"; then
            registrar_normal "servico_$svc" "Serviço $svc voltou a ficar ativo"
        else
            inativos+="$svc "
            registrar_alerta "servico_$svc" "Serviço $svc está $(systemctl is-active "$svc" 2>/dev/null)"
        fi
    done

    agora="$(date '+%F %T')"
    echo "$agora;$cpu;$mem;$disco;${inativos% }" >> "$METRICS_LOG"
    printf '{"hostname":"%s","coletado":"%s","cpu":%d,"mem":%d,"disco":%d,"cpu_alerta":%s,"mem_alerta":%s,"disco_alerta":%s,"servicos_inativos":"%s"}\n' \
        "$(hostname)" "$agora" "$cpu" "$mem" "$disco" "$cpu_a" "$mem_a" "$disco_a" "${inativos% }" > "$STATUS_FILE.tmp" \
        && chmod 644 "$STATUS_FILE.tmp" && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"

    notificar_systemd WATCHDOG=1 --status="CPU ${cpu}% | MEM ${mem}% | DISCO ${disco}%"
    sleep "$MONITOR_INTERVAL"
done
