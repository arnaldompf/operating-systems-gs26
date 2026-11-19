#!/usr/bin/env bash
# =============================================================================
# lib_log.sh - funções comuns de log e auditoria (carregada por todos os scripts)
#
# Cada script que faz "source" desta biblioteca:
#   - grava suas mensagens em $LOG_DIR/<script>.log
#   - registra início e fim (com código de saída) em $LOG_DIR/audit.log
#   - envia uma cópia para o journald (tag citizentech)
# =============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$LIB_DIR/../config/citizentech.env}"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="/etc/citizentech/citizentech.env"
# shellcheck source=../config/citizentech.env
source "$CONFIG_FILE"

SCRIPT_NAME="$(basename "${0%.sh}")"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
EXEC_USER="${SUDO_USER:-$(id -un)}"

mkdir -p "$LOG_DIR" 2>/dev/null || true
SCRIPT_LOG="$LOG_DIR/${SCRIPT_NAME}.log"
AUDIT_LOG="$LOG_DIR/audit.log"

_C_RESET=$'\e[0m'; _C_INFO=$'\e[36m'; _C_OK=$'\e[32m'; _C_WARN=$'\e[33m'; _C_ERR=$'\e[31m'

# log NIVEL "mensagem"  ->  2026-11-19 10:00:00 [INFO] [01_infra] mensagem
log() {
    local level="$1"; shift
    local msg="$*"
    local line
    line="$(date '+%F %T') [$level] [$SCRIPT_NAME] $msg"
    local color="$_C_INFO"
    case "$level" in
        OK) color="$_C_OK" ;;
        WARN|ALERTA) color="$_C_WARN" ;;
        ERRO) color="$_C_ERR" ;;
    esac
    echo "${color}${line}${_C_RESET}"
    echo "$line" >> "$SCRIPT_LOG" 2>/dev/null || true
    logger -t "citizentech/$SCRIPT_NAME" -p "user.$( [[ $level == ERRO ]] && echo err || { [[ $level == WARN || $level == ALERTA ]] && echo warning || echo info; })" "$msg" 2>/dev/null || true
}

info()  { log INFO "$@"; }
ok()    { log OK "$@"; }
warn()  { log WARN "$@"; }
erro()  { log ERRO "$@"; }

# Linha de auditoria: quem executou, o quê, quando e com qual resultado
audit() {
    echo "$(date '+%F %T') run_id=$RUN_ID user=$EXEC_USER host=$(hostname) script=$SCRIPT_NAME $*" \
        >> "$AUDIT_LOG" 2>/dev/null || true
}

_on_exit() {
    local code=$?
    if [[ $code -eq 0 ]]; then
        audit "evento=FIM status=SUCESSO"
    else
        audit "evento=FIM status=FALHA exit_code=$code"
        erro "Script terminou com erro (código $code). Veja $SCRIPT_LOG"
    fi
}

# Chamar no início de cada script: inicia auditoria e trata erros
start_script() {
    audit "evento=INICIO args=\"$*\""
    trap _on_exit EXIT
    info "===== Iniciando $SCRIPT_NAME (usuário: $EXEC_USER, run_id: $RUN_ID) ====="
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Este script precisa ser executado como root: sudo $0" >&2
        exit 1
    fi
}

# Executa um comando registrando-o no log; para o script se falhar
run() {
    info "\$ $*"
    if ! "$@" >> "$SCRIPT_LOG" 2>&1; then
        erro "Falhou: $*"
        return 1
    fi
}

section() {
    echo
    info "---------- $* ----------"
}

# render <template> <destino>: troca ${VAR} pelos valores do citizentech.env.
# Só as variáveis listadas são trocadas, para não mexer em $host etc. do nginx.
render() {
    local vars='${APP_USER} ${APP_DIR} ${APP_DATA_DIR} ${APP_PORT} ${APP_WORKERS} ${INTERNAL_IP}
                ${APP_INTERNAL_HOST} ${LOG_DIR} ${INSTALL_DIR} ${SERVER_HOSTNAME} ${DOMAIN}'
    export APP_USER APP_DIR APP_DATA_DIR APP_PORT APP_WORKERS INTERNAL_IP APP_INTERNAL_HOST \
           LOG_DIR INSTALL_DIR SERVER_HOSTNAME DOMAIN
    envsubst "$vars" < "$1" > "$2"
    info "Arquivo gerado: $2"
}
