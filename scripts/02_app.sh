#!/usr/bin/env bash
# =============================================================================
# 02_app.sh - Provisionamento da aplicação web Alerta Córrego
#
#   1. Dependências (Python, nginx, SQLite)
#   2. Usuário de serviço e diretórios
#   3. Código, ambiente virtual Python e variáveis de ambiente
#   4. Utilitários CitizenTech (/opt/citizentech/bin)
#   5. Serviços systemd (app web + receptor MQTT do ESP32)
#   6. Nginx como proxy reverso (porta 80 -> rede interna)
#   7. Rotação de logs
#   8. Verificação de funcionamento
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib_log.sh"
require_root
start_script "$@"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEBIAN_FRONTEND=noninteractive

if ! ip -4 addr show "$INTERNAL_IFACE" 2>/dev/null | grep -q "$INTERNAL_IP"; then
    erro "Rede interna $INTERNAL_IFACE ($INTERNAL_IP) não existe. Rode antes: sudo ./scripts/01_infra.sh"
    exit 1
fi

# --- 1. Dependências ----------------------------------------------------------
section "1/8 Dependências"
run apt-get install -y python3 python3-venv python3-pip nginx sqlite3 gettext-base logrotate rsync curl
ok "Python $(python3 --version | cut -d' ' -f2), nginx $(nginx -v 2>&1 | cut -d/ -f2)"

# --- 2. Usuário e diretórios --------------------------------------------------
section "2/8 Usuário de serviço e diretórios"
if ! id "$APP_USER" &>/dev/null; then
    run useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$APP_USER"
    ok "Usuário de sistema $APP_USER criado (sem login)"
else
    ok "Usuário $APP_USER já existe"
fi
install -d -m 755 "$INSTALL_DIR" "$INSTALL_DIR/bin" "$APP_DIR" /etc/citizentech "$STATE_DIR"
install -d -m 755 "$LOG_DIR"
install -d -m 750 -o "$APP_USER" -g "$APP_USER" "$APP_DATA_DIR" "$LOG_DIR/app"
install -m 644 "$REPO_DIR/config/citizentech.env" /etc/citizentech/citizentech.env
ok "Diretórios: $APP_DIR, $APP_DATA_DIR, $LOG_DIR, /etc/citizentech"

# --- 3. Código e ambiente Python ----------------------------------------------
section "3/8 Código da aplicação e ambiente virtual"
run rsync -a --delete --exclude venv --exclude '__pycache__' --exclude '*.db*' "$REPO_DIR/app/" "$APP_DIR/"
[[ -x "$APP_DIR/venv/bin/python" ]] || run python3 -m venv "$APP_DIR/venv"
run "$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
run "$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"
ok "Dependências Python: $("$APP_DIR/venv/bin/pip" freeze | grep -iE '^(flask|gunicorn|paho)' | tr '\n' ' ')"

cat > /etc/citizentech/app.env <<EOF
# Variáveis de ambiente da aplicação (gerado por 02_app.sh)
ALERTA_DB=${APP_DATA_DIR}/alerta.db
INFRA_STATUS_FILE=${STATE_DIR}/infra_status.json
ESTACAO_PADRAO=corrego-01
MQTT_BROKER=${MQTT_BROKER}
MQTT_PORT=${MQTT_PORT}
MQTT_TOPIC=${MQTT_TOPIC}
EOF
chmod 640 /etc/citizentech/app.env
chgrp "$APP_USER" /etc/citizentech/app.env
ok "Variáveis de ambiente em /etc/citizentech/app.env"

# --- 4. Utilitários -----------------------------------------------------------
section "4/8 Utilitários CitizenTech"
install -m 755 "$REPO_DIR"/bin/*.sh "$INSTALL_DIR/bin/"
install -m 644 "$REPO_DIR/scripts/lib_log.sh" "$INSTALL_DIR/bin/lib_log.sh"
ok "Instalados em $INSTALL_DIR/bin: $(ls "$INSTALL_DIR/bin" | tr '\n' ' ')"

# --- 5. Serviços systemd ------------------------------------------------------
section "5/8 Serviços systemd"
for unit in alerta-corrego.service alerta-corrego-mqtt.service citizentech-falha@.service; do
    render "$REPO_DIR/config/systemd/$unit" "/etc/systemd/system/$unit"
done
run systemctl daemon-reload
run systemctl enable alerta-corrego.service alerta-corrego-mqtt.service
run systemctl restart alerta-corrego.service alerta-corrego-mqtt.service
ok "Serviços habilitados no boot e iniciados"

# --- 6. Nginx -----------------------------------------------------------------
section "6/8 Nginx (proxy reverso)"
render "$REPO_DIR/config/nginx/alerta-corrego.conf" /etc/nginx/sites-available/alerta-corrego
ln -sf /etc/nginx/sites-available/alerta-corrego /etc/nginx/sites-enabled/alerta-corrego
rm -f /etc/nginx/sites-enabled/default
run nginx -t
run systemctl enable nginx
run systemctl reload-or-restart nginx
ok "Nginx: porta 80 -> http://${APP_INTERNAL_HOST}:${APP_PORT}"

# --- 7. Rotação de logs -------------------------------------------------------
section "7/8 Rotação de logs"
render "$REPO_DIR/config/logrotate/citizentech" /etc/logrotate.d/citizentech
run logrotate --debug /etc/logrotate.d/citizentech
ok "Logs de $LOG_DIR rotacionados diariamente (14 dias)"

# --- 8. Verificação -----------------------------------------------------------
section "8/8 Verificação"
# Aguarda a app subir e o reload do nginx terminar
for _ in {1..20}; do
    curl -fsS -m 3 "http://${APP_INTERNAL_HOST}:${APP_PORT}/health" >/dev/null 2>&1 \
        && curl -fsS -m 3 "http://127.0.0.1/health" >/dev/null 2>&1 && break
    sleep 1
done
for svc in alerta-corrego alerta-corrego-mqtt nginx; do
    if systemctl is-active --quiet "$svc"; then ok "$svc: ativo"; else erro "$svc: $(systemctl is-active "$svc")"; exit 1; fi
done
curl -fsS -m 5 "http://${APP_INTERNAL_HOST}:${APP_PORT}/health" >/dev/null && ok "App responde na rede interna (${APP_INTERNAL_HOST}:${APP_PORT})"
curl -fsS -m 5 "http://127.0.0.1/health" >/dev/null && ok "App responde pelo nginx (porta 80)"
PUBLIC_IP="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
ok "Aplicação disponível em: http://${PUBLIC_IP}/"
