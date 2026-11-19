#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh - verifica se a aplicação responde (executado pelo timer a cada 1 min)
#
#   1. testa a app direto na rede interna (app.alertacorrego.local:8000/health)
#   2. testa pelo nginx (http://127.0.0.1/health)
#   3. se a app não responder, registra ALERTA e reinicia o serviço
# =============================================================================
set -uo pipefail
BIN_DIR="$(dirname "$(readlink -f "$0")")"
if [[ -f "$BIN_DIR/lib_log.sh" ]]; then source "$BIN_DIR/lib_log.sh"; else source "$BIN_DIR/../scripts/lib_log.sh"; fi
start_script

ALERT_LOG="$LOG_DIR/alertas.log"
URL_INTERNA="http://${APP_INTERNAL_HOST}:${APP_PORT}/health"
URL_NGINX="http://127.0.0.1/health"

testar() { curl -fsS -m 5 -o /dev/null -w '%{http_code} %{time_total}s' "$1" 2>/dev/null; }

if r=$(testar "$URL_INTERNA"); then
    ok "App OK em $URL_INTERNA ($r)"
else
    msg="App não respondeu em $URL_INTERNA - reiniciando alerta-corrego.service"
    echo "$(date '+%F %T') [ALERTA] [healthcheck] $msg" >> "$ALERT_LOG"
    log ALERTA "$msg"
    systemctl restart alerta-corrego.service
    sleep 5
    if r=$(testar "$URL_INTERNA"); then
        echo "$(date '+%F %T') [RECUPERADO] [healthcheck] App voltou a responder após reinício ($r)" >> "$ALERT_LOG"
        ok "App recuperada ($r)"
    else
        erro "App continua fora do ar após reinício"
        exit 1
    fi
fi

if r=$(testar "$URL_NGINX"); then
    ok "Nginx OK em $URL_NGINX ($r)"
else
    msg="Nginx não respondeu em $URL_NGINX - reiniciando nginx"
    echo "$(date '+%F %T') [ALERTA] [healthcheck] $msg" >> "$ALERT_LOG"
    log ALERTA "$msg"
    systemctl restart nginx
fi
