#!/usr/bin/env bash
# =============================================================================
# AutoXray Installer & Manager — Ubuntu 24 VPS Edition
# Version : 3.0.0 (Elite TUI & Standardized URI Edition)
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS & COLOUR HELPERS
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="3.0.0"
readonly LOG_FILE="/var/log/autoxray-install.log"
readonly BACKUP_DIR="/var/backups/autoxray"
readonly XRAY_DIR="/usr/local/etc/xray"
readonly CSV_DB="${XRAY_DIR}/users.csv"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_SERVICE="/etc/systemd/system/xray.service"
readonly NGINX_CONF_DIR="/etc/nginx/conf.d"
readonly TLS_DIR="/etc/ssl/autoxray"
readonly WEBSOCKIFY_PORT=2082
readonly ACME_HOME="/root/.acme.sh"

readonly PORT_VLESS_WS=10001
readonly PORT_VMESS_WS=10002
readonly PORT_TROJAN_WS=10003
readonly PORT_VLESS_GRPC=10004
readonly PORT_VLESS_WS_NOTLS=10011
readonly PORT_VMESS_WS_NOTLS=10012

RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'; CYAN='\033[0;36m'

log()     { echo -e "${GREEN}[✔]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[✖]${NC} $*" | tee -a "$LOG_FILE" >&2; }
info()    { echo -e "${CYAN}[i]${NC} $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}\n" | tee -a "$LOG_FILE"; }
die()     { error "$*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
#  ARGUMENT PARSING & INTERACTIVE PROMPT
# ─────────────────────────────────────────────────────────────────────────────

DOMAIN=""
EMAIL=""
SKIP_BBR="false"
SKIP_HARDENING="false"
UNINSTALL="false"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)         DOMAIN="${2:-}";  shift 2 ;;
            --email)          EMAIL="${2:-}";   shift 2 ;;
            --skip-bbr)       SKIP_BBR="true";  shift   ;;
            --skip-hardening) SKIP_HARDENING="true"; shift ;;
            --uninstall)      UNINSTALL="true"; shift   ;;
            -h|--help)
                echo "Usage: sudo bash install.sh [--domain DOMAIN --email EMAIL] [--uninstall]"
                exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    # INTERACTIVE PROMPT (bypassing curl|bash pipe using /dev/tty)
    if [[ -z "$DOMAIN" && "$UNINSTALL" == "false" ]]; then
        echo -e "\n${BOLD}No domain specified. Launching interactive setup...${NC}"
        read -rp "Do you want to configure a custom domain with Let's Encrypt? [y/N] " configure_tls </dev/tty
        if [[ "$configure_tls" =~ ^[Yy]$ ]]; then
            read -rp "Enter Domain (e.g., vpn.example.com): " DOMAIN </dev/tty
            read -rp "Enter Email for Let's Encrypt (e.g., admin@example.com): " EMAIL </dev/tty
        fi
    fi

    if [[ -n "$DOMAIN" && -z "$EMAIL" ]]; then
        die "--email is required when a domain is specified."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  PRE-FLIGHT CHECKS & SYSTEM PREPARATION
# ─────────────────────────────────────────────────────────────────────────────

preflight_checks() {
    section "Pre-flight checks"
    [[ $EUID -ne 0 ]] && die "This script must be run as root."
    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
    touch "$LOG_FILE"
    log "Pre-flight checks passed."
}

prepare_system() {
    section "System preparation"
    export DEBIAN_FRONTEND=noninteractive
    info "Updating package lists..."
    apt-get update -qq
    info "Installing dependencies..."
    apt-get install -y -qq curl wget unzip jq socat coreutils nginx certbot \
        python3-certbot-nginx websockify ufw fail2ban ca-certificates openssl \
        net-tools iproute2 lsof logrotate cron 2>&1 | tee -a "$LOG_FILE"
    log "Base packages installed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  KERNEL & TLS PROVISIONING
# ─────────────────────────────────────────────────────────────────────────────

optimize_kernel() {
    section "Kernel / network optimisation"
    [[ "$SKIP_BBR" == "true" ]] && return
    
    cat > /etc/sysctl.d/99-autoxray.conf <<'SYSCTL'
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn              = 32768
net.ipv4.ip_forward             = 1
vm.swappiness                   = 10
SYSCTL
    sysctl -p /etc/sysctl.d/99-autoxray.conf >> "$LOG_FILE" 2>&1 || true
    log "Kernel parameters applied."
}

provision_tls() {
    section "TLS certificate provisioning"
    mkdir -p "$TLS_DIR"
    local server_ip
    server_ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

    if [[ -n "$DOMAIN" ]]; then
        info "Installing Let's Encrypt for ${DOMAIN}"
        [[ ! -f "${ACME_HOME}/acme.sh" ]] && curl -fsSL https://get.acme.sh | bash -s -- --install-online --email "$EMAIL" >> "$LOG_FILE" 2>&1
        systemctl stop nginx 2>/dev/null || true
        
        if "${ACME_HOME}/acme.sh" --issue --standalone --domain "$DOMAIN" --keylength ec-256 --server letsencrypt --force >> "$LOG_FILE" 2>&1; then
            "${ACME_HOME}/acme.sh" --install-cert --domain "$DOMAIN" --ecc \
                --cert-file "${TLS_DIR}/cert.pem" --key-file "${TLS_DIR}/key.pem" --fullchain-file "${TLS_DIR}/fullchain.pem" \
                --reloadcmd "systemctl reload nginx" >> "$LOG_FILE" 2>&1
            log "Let's Encrypt installed for ${DOMAIN}."
        else
            warn "ACME failed — falling back to self-signed."
            DOMAIN=""
        fi
    fi

    if [[ -z "$DOMAIN" ]] || [[ ! -f "${TLS_DIR}/fullchain.pem" ]]; then
        info "Generating self-signed certificate..."
        openssl req -x509 -newkey rsa:4096 -keyout "${TLS_DIR}/key.pem" -out "${TLS_DIR}/fullchain.pem" -days 3650 -nodes \
            -subj "/CN=autoxray/O=AutoXray/C=US" -addext "subjectAltName=IP:${server_ip}" >> "$LOG_FILE" 2>&1
        cp "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/cert.pem"
        DOMAIN="${server_ip}"
        log "Self-signed certificate generated."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  XRAY-CORE INSTALLATION & CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

install_xray() {
    section "Installing Xray-core"
    local latest_tag
    latest_tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name' 2>/dev/null) || latest_tag="v1.8.13"
    
    local arch; case "$(uname -m)" in x86_64) arch="64" ;; aarch64) arch="arm64-v8a" ;; *) die "Unsupported arch" ;; esac
    local tmp_dir; tmp_dir=$(mktemp -d)
    
    wget -q --show-progress -O "${tmp_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${arch}.zip"
    unzip -qo "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray"
    install -m 755 "${tmp_dir}/xray/xray" "$XRAY_BIN"
    rm -rf "$tmp_dir"
    mkdir -p "${XRAY_DIR}/conf"
    log "Xray-core ${latest_tag} installed."
}

configure_xray() {
    section "Configuring Xray-core"
    local uuid_vless uuid_vmess trojan_pass
    uuid_vless=$("$XRAY_BIN" uuid); uuid_vmess=$("$XRAY_BIN" uuid); trojan_pass=$(openssl rand -hex 20)

    cat > "${XRAY_DIR}/credentials.env" <<EOF
VLESS_UUID="${uuid_vless}"
VMESS_UUID="${uuid_vmess}"
TROJAN_PASS="${trojan_pass}"
DOMAIN="${DOMAIN}"
EOF

    # Initialize CSV database
    echo "Username,ServiceType,Secret,ExpiryDate" > "$CSV_DB"
    echo "admin_vless,Xray,${uuid_vless},Never" >> "$CSV_DB"
    echo "admin_vmess,Xray,${uuid_vmess},Never" >> "$CSV_DB"
    echo "admin_trojan,Xray,${trojan_pass},Never" >> "$CSV_DB"
    chmod 600 "${XRAY_DIR}/credentials.env" "$CSV_DB"

    cat > "${XRAY_DIR}/config.json" <<XRAY_JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-ws-tls", "listen": "127.0.0.1", "port": ${PORT_VLESS_WS}, "protocol": "vless",
      "settings": { "clients": [{ "id": "${uuid_vless}", "flow": "", "email": "admin_vless" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws" } }
    },
    {
      "tag": "vmess-ws-tls", "listen": "127.0.0.1", "port": ${PORT_VMESS_WS}, "protocol": "vmess",
      "settings": { "clients": [{ "id": "${uuid_vmess}", "alterId": 0, "email": "admin_vmess" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-ws" } }
    },
    {
      "tag": "trojan-ws-tls", "listen": "127.0.0.1", "port": ${PORT_TROJAN_WS}, "protocol": "trojan",
      "settings": { "clients": [{ "password": "${trojan_pass}", "email": "admin_trojan" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" } }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [ { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "blocked" } ]
  }
}
XRAY_JSON
    log "Xray base configuration written."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SERVICES, NGINX, SSH-WS & HARDENING
# ─────────────────────────────────────────────────────────────────────────────

install_services() {
    section "Configuring Services"
    
    # 1. Xray Systemd
    cat > "$XRAY_SERVICE" <<'SERVICE'
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload; systemctl enable xray

    # 2. SSH-WebSocket Systemd (Fixing dependency to ssh.service)
    apt-get install -y -qq websockify >/dev/null
    cat > /etc/systemd/system/ssh-websocket.service <<SERVICE
[Unit]
Description=SSH over WebSocket
After=network.target ssh.service
Requires=ssh.service
[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/websockify --web=/dev/null 127.0.0.1:${WEBSOCKIFY_PORT} 127.0.0.1:22
Restart=always
[Install]
WantedBy=multi-user.target
SERVICE
    systemctl enable ssh-websocket

    # 3. Nginx
    rm -f /etc/nginx/sites-enabled/default
    cat > "${NGINX_CONF_DIR}/autoxray-443.conf" <<NGINX_443
server {
    listen 443 ssl http2; server_name _;
    ssl_certificate ${TLS_DIR}/fullchain.pem; ssl_certificate_key ${TLS_DIR}/key.pem;
    location /vless-ws { proxy_pass http://127.0.0.1:${PORT_VLESS_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /vmess-ws { proxy_pass http://127.0.0.1:${PORT_VMESS_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /trojan-ws { proxy_pass http://127.0.0.1:${PORT_TROJAN_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /ssh-ws   { proxy_pass http://127.0.0.1:${WEBSOCKIFY_PORT}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location / { root /var/www/html; index index.html; }
}
NGINX_443
    mkdir -p /var/www/html; echo "<html><body><h1>Service Operating Normally</h1></body></html>" > /var/www/html/index.html
}

harden_system() {
    section "Security Hardening"
    [[ "$SKIP_HARDENING" == "true" ]] && return
    
    ufw --force reset; ufw default deny incoming; ufw default allow outgoing
    ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw --force enable
    
    # Harden SSH (Replacing sshd with ssh.service restart)
    sed -i 's/#PermitEmptyPasswords no/PermitEmptyPasswords no/' /etc/ssh/sshd_config
    systemctl restart ssh || systemctl restart sshd
    log "System Hardened."
}

# ─────────────────────────────────────────────────────────────────────────────
#  ADVANCED TUI MANAGER INJECTION
# ─────────────────────────────────────────────────────────────────────────────

install_manage_script() {
    section "Installing Advanced TUI Manager"

    cat > /usr/local/bin/autoxray <<'MANAGE'
#!/usr/bin/env bash
CRED_FILE="/usr/local/etc/xray/credentials.env"
CSV_DB="/usr/local/etc/xray/users.csv"
XRAY_CONF="/usr/local/etc/xray/config.json"
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

source "$CRED_FILE" 2>/dev/null || exit 1
IP=$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
OS=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')

draw_header() {
    clear
    local up; up=$(uptime -p)
    local ram; ram=$(free -m | awk 'NR==2{printf "%s/%sMB (%.1f%%)", $3,$2,$3*100/$2 }')
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║                AutoXray Elite Manager TUI                ║${NC}"
    echo -e "${CYAN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${BOLD}OS:${NC} $OS   |  ${BOLD}Uptime:${NC} $up"
    echo -e "  ${BOLD}IP:${NC} $IP |  ${BOLD}Domain:${NC} $DOMAIN"
    echo -e "  ${BOLD}RAM Usage:${NC} $ram"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}\n"
}

create_account() {
    echo -e "${BOLD}Select Service Type:${NC}\n 1) SSH-WS\n 2) Xray (VLESS/VMESS)"
    read -rp "Choice: " s_type
    read -rp "Username: " u_name
    read -rp "Expiry Date (YYYY-MM-DD): " u_exp

    if [[ "$s_type" == "1" ]]; then
        read -rp "Password: " u_pass
        useradd -m -s /bin/false "$u_name"
        echo "${u_name}:${u_pass}" | chpasswd
        chage -E "$u_exp" "$u_name"
        echo "${u_name},SSH,${u_pass},${u_exp}" >> "$CSV_DB"
        echo -e "${GREEN}SSH User $u_name created!${NC}"
    elif [[ "$s_type" == "2" ]]; then
        u_uuid=$(/usr/local/bin/xray uuid)
        # Safely inject user into JSON via jq for both VLESS and VMESS
        jq --arg user "$u_name" --arg uuid "$u_uuid" '
          .inbounds |= map(
            if .protocol == "vless" and .settings.clients then
              .settings.clients += [{"id": $uuid, "flow": "", "email": $user}]
            elif .protocol == "vmess" and .settings.clients then
              .settings.clients += [{"id": $uuid, "alterId": 0, "email": $user}]
            else . end
          )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
        
        systemctl restart xray
        echo "${u_name},Xray,${u_uuid},${u_exp}" >> "$CSV_DB"
        echo -e "${GREEN}Xray User $u_name created with UUID: $u_uuid${NC}"
    fi
    read -rp "Press Enter to return..."
}

delete_account() {
    echo -e "${BOLD}Active Users:${NC}"
    column -s, -t < "$CSV_DB" | nl
    echo ""
    read -rp "Enter Username to delete: " del_user
    if grep -q "^${del_user}," "$CSV_DB"; then
        svc=$(grep "^${del_user}," "$CSV_DB" | cut -d, -f2)
        if [[ "$svc" == "SSH" ]]; then
            userdel -r "$del_user" 2>/dev/null || true
        elif [[ "$svc" == "Xray" ]]; then
            jq --arg user "$del_user" '
              .inbounds |= map(
                if .settings.clients then
                  .settings.clients |= map(select(.email != $user))
                else . end
              )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
            systemctl restart xray
        fi
        sed -i "/^${del_user},/d" "$CSV_DB"
        echo -e "${GREEN}User $del_user deleted successfully.${NC}"
    else
        echo -e "${RED}User not found.${NC}"
    fi
    read -rp "Press Enter to return..."
}

renew_account() {
    read -rp "Enter Username to renew: " ren_user
    if grep -q "^${ren_user}," "$CSV_DB"; then
        read -rp "New Expiry Date (YYYY-MM-DD): " new_exp
        svc=$(grep "^${ren_user}," "$CSV_DB" | cut -d, -f2)
        # Update CSV
        sed -i "s/^${ren_user},${svc},.*,.*/${ren_user},${svc},$(grep "^${ren_user}," "$CSV_DB" | cut -d, -f3),${new_exp}/" "$CSV_DB"
        
        # System update for SSH
        [[ "$svc" == "SSH" ]] && chage -E "$new_exp" "$ren_user"
        echo -e "${GREEN}User $ren_user renewed to $new_exp.${NC}"
    else
        echo -e "${RED}User not found.${NC}"
    fi
    read -rp "Press Enter to return..."
}

show_links() {
    echo -e "${BOLD}--- Standardized URIs (Admin) ---${NC}"
    echo -e "${CYAN}VLESS:${NC} vless://${VLESS_UUID}@${DOMAIN}:443?type=ws&security=tls&path=%2Fvless-ws#Admin-VLESS"
    v_json="{\"v\":\"2\",\"ps\":\"Admin-VMESS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-ws\",\"tls\":\"tls\"}"
    v_b64=$(echo -n "$v_json" | base64 -w0)
    echo -e "${CYAN}VMESS:${NC} vmess://${v_b64}"
    echo -e "${CYAN}TROJAN:${NC} trojan://${TROJAN_PASS}@${DOMAIN}:443?type=ws&security=tls&path=%2Ftrojan-ws#Admin-TROJAN"
    echo ""
    read -rp "Press Enter to return..."
}

manage_services() {
    for svc in xray nginx ssh-websocket fail2ban; do
        if systemctl is-active --quiet "$svc"; then echo -e "  ${GREEN}●${NC} $svc: active"; else echo -e "  ${RED}●${NC} $svc: inactive"; fi
    done
    read -rp "Restart all services? [y/N]: " rst
    if [[ "$rst" =~ ^[Yy]$ ]]; then systemctl restart xray nginx ssh-websocket fail2ban; fi
}

while true; do
    draw_header
    echo "  1) Create Account"
    echo "  2) Delete Account"
    echo "  3) Renew Account"
    echo "  4) List Users Database"
    echo "  5) Show Admin Standard URIs"
    echo "  6) Manage Services"
    echo "  x) Exit Manager"
    echo ""
    read -rp "Select an option: " opt
    case $opt in
        1) create_account ;;
        2) delete_account ;;
        3) renew_account ;;
        4) column -s, -t < "$CSV_DB" | nl; read -rp "Press Enter to return..." ;;
        5) show_links ;;
        6) manage_services ;;
        x) clear; exit 0 ;;
        *) echo "Invalid option." ; sleep 1 ;;
    esac
done
MANAGE

    chmod +x /usr/local/bin/autoxray
    log "Management helper installed. Access via: autoxray"
}

# ─────────────────────────────────────────────────────────────────────────────
#  UNINSTALL & SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

do_uninstall() {
    section "Uninstalling AutoXray"
    for svc in xray ssh-websocket; do systemctl stop "$svc" 2>/dev/null; systemctl disable "$svc" 2>/dev/null; done
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/ssh-websocket.service
    rm -rf /usr/local/etc/xray /etc/ssl/autoxray
    rm -f /usr/local/bin/xray /usr/local/bin/autoxray /etc/nginx/conf.d/autoxray-*.conf
    systemctl daemon-reload; systemctl reload nginx 2>/dev/null || true
    log "Uninstall complete."
    exit 0
}

start_services() {
    for svc in nginx xray ssh-websocket fail2ban; do systemctl start "$svc"; done
    log "All services activated."
}

print_summary() {
    source "${XRAY_DIR}/credentials.env"
    local v_json="{\"v\":\"2\",\"ps\":\"AutoXray-VMess\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-ws\",\"tls\":\"tls\"}"
    local v_b64=$(echo -n "$v_json" | base64 -w0)
    
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║         AutoXray Elite Installation Complete ✔           ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n  ${BOLD}Standard Import URIs (Copy to Clipboard):${NC}"
    echo -e "  ${CYAN}VLESS :${NC} vless://${VLESS_UUID}@${DOMAIN}:443?type=ws&security=tls&path=%2Fvless-ws#Admin-VLESS"
    echo -e "  ${CYAN}VMESS :${NC} vmess://${v_b64}"
    echo -e "  ${CYAN}TROJAN:${NC} trojan://${TROJAN_PASS}@${DOMAIN}:443?type=ws&security=tls&path=%2Ftrojan-ws#Admin-TROJAN"
    echo -e "\n  ${BOLD}Management Console:${NC} Type ${YELLOW}autoxray${NC} to open the TUI."
    echo ""
}

main() {
    parse_args "$@"
    [[ "$UNINSTALL" == "true" ]] && do_uninstall
    
    preflight_checks
    prepare_system
    optimize_kernel
    provision_tls
    install_xray
    configure_xray
    install_services
    harden_system
    install_manage_script
    start_services
    print_summary
}

main "$@"
