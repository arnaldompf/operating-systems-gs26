#!/usr/bin/env bash
# =============================================================================
# 01_infra.sh - Provisionamento da infraestrutura de rede do servidor
#
#   1. Pacotes base
#   2. Hostname e fuso horário
#   3. Rede interna da aplicação (interface dummy com IP estático)
#   4. Resolução de nomes: /etc/hosts (nome interno da app) e DNS (systemd-resolved)
#   5. Firewall (ufw)
#
# Idempotente: pode ser executado várias vezes sem efeitos colaterais.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib_log.sh"
require_root
start_script "$@"

export DEBIAN_FRONTEND=noninteractive

# --- 1. Pacotes base ----------------------------------------------------------
section "1/5 Pacotes base"
run apt-get update -y
run apt-get install -y curl jq dnsutils ufw iproute2 ca-certificates
ok "Pacotes base instalados"

# --- 2. Hostname e fuso horário -----------------------------------------------
section "2/5 Hostname e fuso horário"
FQDN="${SERVER_HOSTNAME}.${DOMAIN}"
if [[ "$(hostnamectl --static)" != "$SERVER_HOSTNAME" ]]; then
    run hostnamectl set-hostname "$SERVER_HOSTNAME"
    ok "Hostname alterado para $SERVER_HOSTNAME"
else
    ok "Hostname já é $SERVER_HOSTNAME"
fi
# Evita que o cloud-init devolva o hostname antigo no próximo boot
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-citizentech-hostname.cfg
fi
run timedatectl set-timezone "$TIMEZONE"
ok "Fuso horário: $(timedatectl show -p Timezone --value)"

# --- 3. Rede interna da aplicação ---------------------------------------------
section "3/5 Rede interna (${INTERNAL_IFACE} = ${INTERNAL_IP}/${INTERNAL_CIDR})"
if [[ -z "$PRIMARY_IFACE" ]]; then
    PRIMARY_IFACE="$(ip route show default | awk '{print $5; exit}')"
fi
PUBLIC_IP="$(ip -4 -o addr show "$PRIMARY_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)"
info "Interface principal: $PRIMARY_IFACE ($PUBLIC_IP) - mantida em DHCP para não perder o SSH"

# A interface dummy é configurada pelo systemd-networkd, sem tocar na interface
# principal. Assim a aplicação ganha um IP fixo próprio, que não muda com a nuvem.
cat > /etc/systemd/network/10-${INTERNAL_IFACE}.netdev <<EOF
# Gerado por 01_infra.sh (CitizenTech)
[NetDev]
Name=${INTERNAL_IFACE}
Kind=dummy
EOF
cat > /etc/systemd/network/10-${INTERNAL_IFACE}.network <<EOF
# Gerado por 01_infra.sh (CitizenTech)
[Match]
Name=${INTERNAL_IFACE}

[Network]
Address=${INTERNAL_IP}/${INTERNAL_CIDR}
EOF

if systemctl is-active --quiet systemd-networkd; then
    run networkctl reload
    sleep 2
    networkctl reconfigure "$INTERNAL_IFACE" >> "$SCRIPT_LOG" 2>&1 || true
else
    warn "systemd-networkd inativo; criando a interface com ip (não persiste no boot)"
    ip link show "$INTERNAL_IFACE" &>/dev/null || ip link add "$INTERNAL_IFACE" type dummy
    ip addr replace "${INTERNAL_IP}/${INTERNAL_CIDR}" dev "$INTERNAL_IFACE"
    ip link set "$INTERNAL_IFACE" up
fi

for _ in {1..10}; do
    ip -4 addr show "$INTERNAL_IFACE" 2>/dev/null | grep -q "$INTERNAL_IP" && break
    sleep 1
done
if ip -4 addr show "$INTERNAL_IFACE" | grep -q "$INTERNAL_IP"; then
    ok "Interface $INTERNAL_IFACE ativa com IP $INTERNAL_IP"
else
    erro "Interface $INTERNAL_IFACE sem o IP $INTERNAL_IP"
    exit 1
fi

# --- 4. Resolução de nomes ----------------------------------------------------
section "4/5 Resolução de nomes (/etc/hosts e DNS)"
# /etc/hosts: bloco gerenciado, reescrito a cada execução
sed -i '/# BEGIN CITIZENTECH/,/# END CITIZENTECH/d' /etc/hosts
sed -i "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts
cat >> /etc/hosts <<EOF
# BEGIN CITIZENTECH
127.0.1.1     ${FQDN} ${SERVER_HOSTNAME}
${INTERNAL_IP}    ${APP_INTERNAL_HOST} app
# END CITIZENTECH
EOF
ok "/etc/hosts: ${APP_INTERNAL_HOST} -> ${INTERNAL_IP}"

# DNS: servidores definidos no citizentech.env, com rollback se não resolver
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/10-citizentech.conf"
mkdir -p "$(dirname "$RESOLVED_DROPIN")"
BACKUP=""
[[ -f "$RESOLVED_DROPIN" ]] && BACKUP="$(cat "$RESOLVED_DROPIN")"
cat > "$RESOLVED_DROPIN" <<EOF
# Gerado por 01_infra.sh (CitizenTech)
[Resolve]
DNS=${DNS_SERVERS}
FallbackDNS=${DNS_FALLBACK}
Domains=~.
DNSSEC=no
Cache=yes
EOF
run systemctl restart systemd-resolved
sleep 2
if getent hosts "$MQTT_BROKER" >/dev/null && getent hosts archive.ubuntu.com >/dev/null; then
    ok "DNS funcionando com servidores: $DNS_SERVERS"
else
    warn "DNS não resolveu com a nova configuração - revertendo"
    if [[ -n "$BACKUP" ]]; then echo "$BACKUP" > "$RESOLVED_DROPIN"; else rm -f "$RESOLVED_DROPIN"; fi
    systemctl restart systemd-resolved
fi
if getent hosts "$APP_INTERNAL_HOST" | grep -q "$INTERNAL_IP"; then
    ok "Nome interno ${APP_INTERNAL_HOST} resolve para ${INTERNAL_IP}"
else
    erro "Nome interno ${APP_INTERNAL_HOST} não resolve"
    exit 1
fi

# --- 5. Firewall --------------------------------------------------------------
section "5/5 Firewall (ufw)"
run ufw default deny incoming
run ufw default allow outgoing
for port in $FIREWALL_ALLOW_PORTS; do
    run ufw allow "$port"
done
# A porta da app só aceita conexões vindas da própria máquina (nginx)
run ufw deny in on "$PRIMARY_IFACE" to any port "$APP_PORT" proto tcp
run ufw --force enable
ok "Firewall ativo: liberadas $FIREWALL_ALLOW_PORTS"

section "Resumo da rede"
{
    echo "Hostname:        $(hostname) ($FQDN)"
    echo "IP público:      $PUBLIC_IP ($PRIMARY_IFACE)"
    echo "IP interno app:  $INTERNAL_IP ($INTERNAL_IFACE) -> $APP_INTERNAL_HOST"
    echo "DNS:             $(resolvectl dns 2>/dev/null | awk -F': ' '/Global/{print $2}')"
    echo "Rota default:    $(ip route show default)"
} | tee -a "$SCRIPT_LOG"
ok "Infraestrutura de rede provisionada"
