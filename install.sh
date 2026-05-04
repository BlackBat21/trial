#!/usr/bin/env bash
# =============================================================================
# AutoXray Installer & Manager — Cyberpunk Elite Edition
# Version : 4.0.0
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="4.0.0"
readonly SCRIPT_URL="https://raw.githubusercontent.com/BlackBat21/trial/main/install.sh"
readonly LOG_FILE="/var/log/autoxray-install.log"
readonly BACKUP_DIR="/var/backups/autoxray"
readonly XRAY_DIR="/usr/local/etc/xray"
readonly CSV_DB="${XRAY_DIR}/users.csv"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_SERVICE="/etc/systemd/system/xray.service"
readonly NGINX_CONF_DIR="/etc/nginx/conf.d"
readonly TLS_DIR="/etc/ssl/autoxray"
readonly ACME_HOME="/root/.acme.sh"

readonly PORT_VLESS_WS=10001
readonly PORT_VMESS_WS=10002
readonly PORT_TROJAN_WS=10003
readonly PORT_VLESS_WS_NOTLS=10011
readonly PORT_VMESS_WS_NOTLS=10012

# ─────────────────────────────────────────────────────────────────────────────
#  COLOUR PALETTE — CYBERPUNK THEME
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BCYAN='\033[1;36m'
MAGENTA='\033[0;35m'
BMAGENTA='\033[1;35m'
BLUE='\033[0;34m'
BBLUE='\033[1;34m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

GCHECK="${GREEN}✔${NC}"
GCROSS="${RED}✖${NC}"
GWARN="${YELLOW}⚡${NC}"
GINFO="${CYAN}◈${NC}"
GARROW="${BMAGENTA}▶${NC}"

log()     { echo -e "${GCHECK} $*"   | tee -a "$LOG_FILE"; }
warn()    { echo -e "${GWARN} $*"    | tee -a "$LOG_FILE"; }
error()   { echo -e "${GCROSS} $*"   | tee -a "$LOG_FILE" >&2; }
info()    { echo -e "${GINFO} $*"    | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BBLUE}┌─── ${BOLD}$*${NC}${BBLUE} ───┐${NC}\n" | tee -a "$LOG_FILE"; }
die()     { error "$*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
#  ARGUMENT PARSING & PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

DOMAIN=""
EMAIL=""
SKIP_BBR="false"
SKIP_HARDENING="false"
UNINSTALL="false"

parse_args() {
    local is_installed="false"
    [[ -f "$CSV_DB" && -f "${XRAY_DIR}/config.json" ]] && is_installed="true"

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

    # Bypass interactive prompts and trigger backups if updating
    if [[ "$is_installed" == "true" && "$UNINSTALL" == "false" ]]; then
        info "Existing installation detected. Bypassing setup and backing up data..."
        cp "$CSV_DB" "${BACKUP_DIR}/users_$(date +%F_%H%M%S).csv" 2>/dev/null || true
        cp "${XRAY_DIR}/config.json" "${BACKUP_DIR}/config_$(date +%F_%H%M%S).json" 2>/dev/null || true
        [[ -f "${XRAY_DIR}/credentials.env" ]] && source "${XRAY_DIR}/credentials.env"
        return
    fi

    if [[ -z "$DOMAIN" && "$UNINSTALL" == "false" ]]; then
        echo -e "\n${BOLD}No domain specified. Launching interactive setup...${NC}"
        read -rp "Do you want to configure a custom domain with Let's Encrypt? [y/N] " configure_tls </dev/tty
        if [[ "$configure_tls" =~ ^[Yy]$ ]]; then
            read -rp "Enter Domain (e.g., vpn.example.com): " DOMAIN </dev/tty
            read -rp "Enter Email for Let's Encrypt (e.g., admin@example.com): " EMAIL </dev/tty
        fi
    fi

    if [[ -n "$DOMAIN" && -z "$EMAIL" ]]; then
        die "--email is required when --domain is specified."
    fi
}

preflight_checks() {
    section "Pre-flight Checks"
    [[ $EUID -ne 0 ]] && die "This script must be run as root."
    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
    touch "$LOG_FILE"
    log "Pre-flight checks passed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SYSTEM PREP & KERNEL TUNING
# ─────────────────────────────────────────────────────────────────────────────

prepare_system() {
    section "System Preparation"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget unzip jq socat coreutils nginx certbot \
        python3-certbot-nginx ufw fail2ban ca-certificates openssl \
        net-tools iproute2 lsof logrotate cron iptables-persistent 2>&1 | tee -a "$LOG_FILE"
    log "Base packages installed."
}

optimize_kernel() {
    section "Kernel / Network Optimisation"
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

# ─────────────────────────────────────────────────────────────────────────────
#  TLS PROVISIONING & XRAY INSTALL
# ─────────────────────────────────────────────────────────────────────────────

provision_tls() {
    section "TLS Certificate Provisioning"
    
    if [[ -f "${TLS_DIR}/fullchain.pem" && -f "$CSV_DB" ]]; then
        log "TLS certificates already exist. Skipping provisioning."
        return
    fi

    mkdir -p "$TLS_DIR"
    local server_ip
    server_ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

    local cert_issued="false"

    if [[ -n "$DOMAIN" ]]; then
        info "Installing Let's Encrypt for ${DOMAIN} using Certbot"
        systemctl stop nginx apache2 ws-proxy 2>/dev/null || true
        fuser -k 80/tcp 2>/dev/null || true

        if certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" \
            --non-interactive --agree-tos --key-type ecdsa >> "$LOG_FILE" 2>&1; then

            cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${TLS_DIR}/cert.pem"
            cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${TLS_DIR}/fullchain.pem"
            cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"  "${TLS_DIR}/key.pem"
            
            mkdir -p /etc/letsencrypt/renewal-hooks/deploy/
            cat > /etc/letsencrypt/renewal-hooks/deploy/autoxray-hook.sh <<EOF
#!/bin/bash
cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${TLS_DIR}/fullchain.pem
cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem ${TLS_DIR}/key.pem
systemctl reload nginx
EOF
            chmod +x /etc/letsencrypt/renewal-hooks/deploy/autoxray-hook.sh

            log "Let's Encrypt installed successfully for ${DOMAIN}."
            cert_issued="true"
        else
            warn "Certbot ACME failed — falling back to a self-signed certificate."
        fi
    fi

    if [[ "$cert_issued" == "false" ]]; then
        info "Generating self-signed certificate..."
        local cert_cn="${DOMAIN:-$server_ip}"

        openssl req -x509 -newkey rsa:4096 \
            -keyout "${TLS_DIR}/key.pem" -out "${TLS_DIR}/fullchain.pem" \
            -days 3650 -nodes \
            -subj "/CN=${cert_cn}/O=AutoXray/C=US" \
            -addext "subjectAltName=IP:${server_ip}" >> "$LOG_FILE" 2>&1
        
        cp "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/cert.pem"
        
        if [[ -z "$DOMAIN" ]]; then
            DOMAIN="${server_ip}"
        fi
        
        log "Self-signed certificate generated."
    fi
}

install_xray() {
    section "Installing Xray-core"
    local latest_tag
    latest_tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null) || latest_tag="v1.8.13"
    local arch
    case "$(uname -m)" in
        x86_64)  arch="64"        ;;
        aarch64) arch="arm64-v8a" ;;
        *)       die "Unsupported architecture" ;;
    esac

    local tmp_dir
    tmp_dir=$(mktemp -d)
    wget -q -O "${tmp_dir}/xray.zip" \
        "https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${arch}.zip"
    unzip -qo "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray"

    install -m 755 "${tmp_dir}/xray/xray" "$XRAY_BIN"
    cp "${tmp_dir}/xray/"*.dat "/usr/local/bin/" 2>/dev/null || true
    rm -rf "$tmp_dir"
    mkdir -p "${XRAY_DIR}/conf"
    log "Xray-core ${latest_tag} installed."
}

configure_xray() {
    section "Configuring Xray-core"

    if [[ -f "$CSV_DB" && -f "${XRAY_DIR}/config.json" ]]; then
        log "Existing Xray configuration and database detected. Skipping regeneration."
        return
    fi

    local uuid_vless
    uuid_vless=$("$XRAY_BIN" uuid)
    local uuid_vmess
    uuid_vmess=$("$XRAY_BIN" uuid)
    local trojan_pass
    trojan_pass=$(openssl rand -hex 20)

    cat > "${XRAY_DIR}/credentials.env" <<EOF
VLESS_UUID="${uuid_vless}"
VMESS_UUID="${uuid_vmess}"
TROJAN_PASS="${trojan_pass}"
DOMAIN="${DOMAIN}"
EOF

    echo "Username,ServiceType,Secret,ExpiryDate" > "$CSV_DB"
    echo "admin_vless,Xray,${uuid_vless},Never"   >> "$CSV_DB"
    echo "admin_vmess,Xray,${uuid_vmess},Never"   >> "$CSV_DB"
    chmod 600 "${XRAY_DIR}/credentials.env" "$CSV_DB"

    cat > "${XRAY_DIR}/config.json" <<XRAY_JSON
{
  "log": { "loglevel": "warning" },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-ws-tls", "listen": "127.0.0.1", "port": ${PORT_VLESS_WS},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid_vless}", "flow": "", "email": "admin_vless" }],
        "decryption": "none"
      },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "vmess-ws-tls", "listen": "127.0.0.1", "port": ${PORT_VMESS_WS},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${uuid_vmess}", "alterId": 0, "email": "admin_vmess" }]
      },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-ws" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "trojan-ws-tls", "listen": "127.0.0.1", "port": ${PORT_TROJAN_WS},
      "protocol": "trojan",
      "settings": {
        "clients": [{ "password": "${trojan_pass}", "email": "admin_trojan" }]
      },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "vless-ws-notls", "listen": "127.0.0.1", "port": ${PORT_VLESS_WS_NOTLS},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid_vless}", "flow": "" }],
        "decryption": "none"
      },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws-nt" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "vmess-ws-notls", "listen": "127.0.0.1", "port": ${PORT_VMESS_WS_NOTLS},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${uuid_vmess}", "alterId": 0 }]
      },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-ws-nt" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct",  "protocol": "freedom"   },
    { "tag": "blocked", "protocol": "blackhole" }
  ]
}
XRAY_JSON
    log "Xray base configuration written."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SERVICES: XRAY, NGINX & PYTHON WS PROXY
# ─────────────────────────────────────────────────────────────────────────────

install_services() {
    section "Configuring Services"

    cat > "$XRAY_SERVICE" <<'SERVICE'
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload
    systemctl enable xray

    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
    cat > "${NGINX_CONF_DIR}/autoxray-443.conf" <<NGINX_CONF
server {
    listen 81 default_server;
    listen [::]:81 default_server;
    server_name _;

    location /vless-ws-nt  { proxy_pass http://127.0.0.1:${PORT_VLESS_WS_NOTLS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /vmess-ws-nt  { proxy_pass http://127.0.0.1:${PORT_VMESS_WS_NOTLS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name _;
    ssl_certificate     ${TLS_DIR}/fullchain.pem;
    ssl_certificate_key ${TLS_DIR}/key.pem;

    location /vless-ws  { proxy_pass http://127.0.0.1:${PORT_VLESS_WS};       proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /vmess-ws  { proxy_pass http://127.0.0.1:${PORT_VMESS_WS};       proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /trojan-ws { proxy_pass http://127.0.0.1:${PORT_TROJAN_WS};      proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /ssh-ws    { proxy_pass http://127.0.0.1:80;                     proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
}
NGINX_CONF

    cat > /usr/local/bin/ws-proxy.py <<'PYTHON_SCRIPT'
#!/usr/bin/env python3
import socket, threading

def handle_client(client_socket):
    try:
        header = client_socket.recv(8192)
        if not header:
            client_socket.close()
            return
        header_str = header.decode('utf-8', 'ignore')
        if '/vless' in header_str or '/vmess' in header_str or '/trojan' in header_str:
            target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            target.connect(('127.0.0.1', 81))
            target.sendall(header)
        else:
            client_socket.sendall(b"HTTP/1.1 101 Lanzvps\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            target.connect(('127.0.0.1', 22))
        threading.Thread(target=forward, args=(client_socket, target)).start()
        threading.Thread(target=forward, args=(target, client_socket)).start()
    except Exception:
        client_socket.close()

def forward(src, dst):
    try:
        while True:
            data = src.recv(8192)
            if not data: break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        src.close()
        dst.close()

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', 80))
server.listen(1000)
while True:
    client, _ = server.accept()
    threading.Thread(target=handle_client, args=(client,)).start()
PYTHON_SCRIPT

    chmod +x /usr/local/bin/ws-proxy.py

    cat > /etc/systemd/system/ws-proxy.service <<'SERVICE'
[Unit]
Description=AutoScriptX Python WS Proxy
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload
    systemctl enable ws-proxy
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECURITY HARDENING
# ─────────────────────────────────────────────────────────────────────────────

harden_system() {
    section "Security Hardening"
    [[ "$SKIP_HARDENING" == "true" ]] && return

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp

    ufw deny out 6881:6889/tcp
    ufw deny out 6881:6889/udp
    ufw --force enable

    # Anti-Torrent Rules: Checking first prevents duplicate appends on updates
    for str in "BitTorrent" "BitTorrent protocol" "peer_id=" ".torrent" "announce.php?passkey=" "torrent" "announce" "info_hash"; do
        iptables -C FORWARD -m string --algo bm --string "$str" -j DROP 2>/dev/null || \
        iptables -A FORWARD -m string --algo bm --string "$str" -j DROP
    done
    
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf         2>/dev/null || true
    rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf  2>/dev/null || true

    sed -i 's/.*PasswordAuthentication.*/PasswordAuthentication yes/g'             /etc/ssh/sshd_config
    sed -i 's/.*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' /etc/ssh/sshd_config

    sed -i '/^Banner/d' /etc/ssh/sshd_config

    printf '%s\n' \
        "PasswordAuthentication yes" \
        "KbdInteractiveAuthentication yes" \
        "Banner /etc/issue.net" \
        > /etc/ssh/sshd_config.d/99-force-pass.conf

    grep -q "/bin/false" /etc/shells || echo "/bin/false" >> /etc/shells

    cat > /etc/issue.net <<'BANNER'

  ┌─────────────────────────────────────────────┐
  │         PHC-Lanz ScriptX                    │
  │         Authorized Access Only              │
  │         All activity is monitored & logged  │
  └─────────────────────────────────────────────┘

BANNER

    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    log "System hardened. SSH banner written and Anti-Torrent protections applied."
}

# ─────────────────────────────────────────────────────────────────────────────
#  ELITE TUI MANAGER  (/usr/local/bin/menu)
# ─────────────────────────────────────────────────────────────────────────────

install_manage_script() {
    section "Installing Elite Cyberpunk TUI Manager"

    cat > /usr/local/bin/menu <<'MANAGE'
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# AutoXray Cyberpunk TUI Manager  v4.0.0
# ─────────────────────────────────────────────────────────────────

CRED_FILE="/usr/local/etc/xray/credentials.env"
CSV_DB="/usr/local/etc/xray/users.csv"
XRAY_CONF="/usr/local/etc/xray/config.json"
SCRIPT_URL="https://raw.githubusercontent.com/BlackBat21/trial/main/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BCYAN='\033[1;36m'
MAGENTA='\033[0;35m'
BMAGENTA='\033[1;35m'
BLUE='\033[0;34m'
BBLUE='\033[1;34m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

GCHECK="${GREEN}✔${NC}"
GCROSS="${RED}✖${NC}"
GWARN="${YELLOW}⚡${NC}"
GINFO="${BCYAN}◈${NC}"
GARROW="${BMAGENTA}▶${NC}"

source "$CRED_FILE" 2>/dev/null || { echo "Missing credentials. Was AutoXray installed correctly?"; exit 1; }

IP=$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
OS=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')

draw_header() {
    clear
    local up ram
    up=$(uptime -p 2>/dev/null || echo "N/A")
    ram=$(free -m 2>/dev/null | awk 'NR==2{printf "%s/%s MB (%.1f%%)", $3,$2,$3*100/$2}')

    echo ""
    echo -e "  ${BMAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BMAGENTA}║${NC}                                                          ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}   ${BCYAN}${BOLD}P H C - L a n z   S c r i p t X${NC}                      ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}   ${DIM}VPN & SSH Management Console  ·  v4.0.0${NC}              ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}                                                          ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BBLUE}┌──────────────────────────────────────────────────────────────────────┐${NC}"
    printf "  ${BBLUE}│${NC}  ${BOLD}${CYAN}OS   ${NC}${DIM}%-28s${NC}  ${BOLD}${CYAN}UPTIME  ${NC}${DIM}%-18s${NC}${BBLUE}│${NC}\n" "$OS" "$up"
    printf "  ${BBLUE}│${NC}  ${BOLD}${MAGENTA}IP   ${NC}${DIM}%-28s${NC}  ${BOLD}${MAGENTA}DOMAIN  ${NC}${DIM}%-18s${NC}${BBLUE}│${NC}\n" "$IP" "$DOMAIN"
    printf "  ${BBLUE}│${NC}  ${BOLD}${BMAGENTA}RAM  ${NC}${DIM}%-56s${NC}  ${BBLUE}│${NC}\n" "$ram"
    echo -e "  ${BBLUE}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

divider() {
    echo -e "  ${BMAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

draw_menu() {
    draw_header
    divider
    echo -e "   ${BOLD}${BCYAN}MAIN MENU${NC}"
    divider
    echo -e "   ${GARROW}  ${BOLD}1${NC}${DIM})${NC}  Create Account"
    echo -e "   ${GARROW}  ${BOLD}2${NC}${DIM})${NC}  Manage Accounts"
    echo -e "   ${GARROW}  ${BOLD}3${NC}${DIM})${NC}  Manage Services"
    echo -e "   ${GARROW}  ${BOLD}4${NC}${DIM})${NC}  Update Script & Core"
    echo -e "   ${GARROW}  ${BOLD}5${NC}${DIM})${NC}  Uninstall AutoXray"
    echo -e "   ${GARROW}  ${BOLD}x${NC}${DIM})${NC}  Exit"
    divider
    echo ""
}

create_account() {
    draw_header
    divider
    echo -e "   ${BOLD}${BCYAN}CREATE ACCOUNT${NC}"
    divider
    echo -e "   ${GARROW}  ${BOLD}1${NC}) SSH-WS"
    echo -e "   ${GARROW}  ${BOLD}2${NC}) Xray (VLESS + VMESS + Trojan)"
    echo ""
    read -rp "   Select service type [1/2]: " s_type

    case "$s_type" in
        1|2) ;;
        *) echo -e "\n   ${GCROSS} Invalid selection."; sleep 2; return ;;
    esac

    read -rp "   Username : " u_name
    if [[ -z "$u_name" ]]; then
        echo -e "\n   ${GCROSS} Username cannot be empty."; sleep 2; return
    fi

    read -rp "   Expiry   : " days
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo -e "\n   ${GCROSS} Invalid input — enter a whole number of days."; sleep 2; return
    fi

    local u_exp
    u_exp=$(date -d "+${days} days" +"%Y-%m-%d")

    if [[ "$s_type" == "1" ]]; then
        read -rp "   Password : " u_pass
        if [[ -z "$u_pass" ]]; then
            echo -e "\n   ${GCROSS} Password cannot be empty."; sleep 2; return
        fi
        useradd -m -s /bin/false "$u_name" 2>/dev/null || true
        echo "${u_name}:${u_pass}" | chpasswd
        chage -E "$u_exp" "$u_name"
        echo "${u_name},SSH,${u_pass},${u_exp}" >> "$CSV_DB"

        echo ""
        divider
        echo -e "   ${GCHECK}  ${BOLD}${GREEN}SSH Account Created${NC}"
        divider
        echo -e "   ${BOLD}${CYAN}Username   ${NC}: $u_name"
        echo -e "   ${BOLD}${CYAN}Password   ${NC}: $u_pass"
        echo -e "   ${BOLD}${CYAN}Expiry     ${NC}: $u_exp"
        echo -e "   ${BOLD}${CYAN}Ports      ${NC}: 22 (SSH) · 80 (WS) · 443 (WSS)"
        divider
        echo ""

    elif [[ "$s_type" == "2" ]]; then
        local u_uuid
        u_uuid=$(/usr/local/bin/xray uuid)

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

        local v_json v_b64
        v_json="{\"v\":\"2\",\"ps\":\"${u_name}-VMESS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\
\"id\":\"${u_uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\
\"path\":\"/vmess-ws\",\"tls\":\"tls\"}"
        v_b64=$(echo -n "$v_json" | base64 -w0)

        echo ""
        divider
        echo -e "   ${GCHECK}  ${BOLD}${GREEN}Xray Account Created${NC}"
        divider
        echo -e "   ${BOLD}${CYAN}Username   ${NC}: $u_name"
        echo -e "   ${BOLD}${CYAN}UUID       ${NC}: $u_uuid"
        echo -e "   ${BOLD}${CYAN}Expiry     ${NC}: $u_exp"
        echo ""
        echo -e "   ${BMAGENTA}VLESS URI:${NC}"
        echo -e "   ${DIM}vless://${u_uuid}@${DOMAIN}:443?encryption=none&flow=none&type=ws&host=${DOMAIN}&headerType=none&path=%2Fvless-ws&security=tls&sni=${DOMAIN}#${u_name}-VLESS${NC}"
        echo ""
        echo -e "   ${BMAGENTA}VMESS URI:${NC}"
        echo -e "   ${DIM}vmess://${v_b64}${NC}"
        echo ""
        echo -e "   ${BMAGENTA}TROJAN URI:${NC}"
        echo -e "   ${DIM}trojan://${u_uuid}@${DOMAIN}:443?type=ws&host=${DOMAIN}&path=%2Ftrojan-ws&security=tls&sni=${DOMAIN}#${u_name}-TROJAN${NC}"
        divider
        echo ""
    fi
    read -rp "   Press Enter to return..." </dev/tty
}

show_account_details() {
    local username="$1"
    local line
    line=$(grep "^${username}," "$CSV_DB" | head -1)
    local svc secret expiry
    svc=$(echo "$line"    | cut -d, -f2)
    secret=$(echo "$line" | cut -d, -f3)
    expiry=$(echo "$line" | cut -d, -f4)

    echo ""
    divider
    echo -e "   ${GINFO}  ${BOLD}${BCYAN}Account Details — ${username}${NC}"
    divider
    echo -e "   ${BOLD}${CYAN}Username   ${NC}: $username"
    echo -e "   ${BOLD}${CYAN}Service    ${NC}: $svc"
    echo -e "   ${BOLD}${CYAN}Expiry     ${NC}: $expiry"
    echo ""

    if [[ "$svc" == "SSH" ]]; then
        echo -e "   ${BOLD}${CYAN}Password   ${NC}: $secret"
        echo -e "   ${BOLD}${CYAN}Host       ${NC}: $IP"
        echo -e "   ${BOLD}${CYAN}Ports      ${NC}: 22 (SSH) · 80 (WS) · 443 (WSS)"

    elif [[ "$svc" == "Xray" ]]; then
        local uuid="$secret"
        local v_json v_b64
        v_json="{\"v\":\"2\",\"ps\":\"${username}-VMESS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\
\"id\":\"${uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\
\"path\":\"/vmess-ws\",\"tls\":\"tls\"}"
        v_b64=$(echo -n "$v_json" | base64 -w0)

        echo -e "   ${BMAGENTA}VLESS URI:${NC}"
        echo -e "   ${DIM}vless://${uuid}@${DOMAIN}:443?encryption=none&flow=none&type=ws&host=${DOMAIN}&headerType=none&path=%2Fvless-ws&security=tls&sni=${DOMAIN}#${username}-VLESS${NC}"
        echo ""
        echo -e "   ${BMAGENTA}VMESS URI:${NC}"
        echo -e "   ${DIM}vmess://${v_b64}${NC}"
        echo ""
        echo -e "   ${BMAGENTA}TROJAN URI:${NC}"
        echo -e "   ${DIM}trojan://${uuid}@${DOMAIN}:443?type=ws&host=${DOMAIN}&path=%2Ftrojan-ws&security=tls&sni=${DOMAIN}#${username}-TROJAN${NC}"
    fi

    divider
    echo ""
    read -rp "   Press Enter to return..." </dev/tty
}

_delete_account() {
    local username="$1"
    local svc
    svc=$(grep "^${username}," "$CSV_DB" | cut -d, -f2)

    echo ""
    read -rp "   ${GWARN}  Confirm deletion of '${username}'? [y/N]: " confirm </dev/tty
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "   ${GINFO} Deletion cancelled."; sleep 1; return
    fi

    if [[ "$svc" == "SSH" ]]; then
        pkill -9 -u "$username" 2>/dev/null || true
        userdel -f -r "$username" 2>/dev/null || true
    elif [[ "$svc" == "Xray" ]]; then
        jq --arg user "$username" '
          .inbounds |= map(
            if .settings.clients then
              .settings.clients |= map(select(.email != $user))
            else . end
          )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
        systemctl restart xray
    fi

    sed -i "/^${username},/d" "$CSV_DB"
    echo -e "   ${GCHECK} ${GREEN}User ${BOLD}${username}${NC}${GREEN} deleted successfully.${NC}"
    sleep 2
}

_extend_account() {
    local username="$1"
    local current_exp svc secret days new_exp

    svc=$(grep "^${username},"    "$CSV_DB" | cut -d, -f2)
    secret=$(grep "^${username}," "$CSV_DB" | cut -d, -f3)
    current_exp=$(grep "^${username}," "$CSV_DB" | cut -d, -f4)

    echo ""
    echo -e "   ${GINFO}  Current expiry: ${BOLD}${current_exp}${NC}"
    read -rp "   Days to add: " days </dev/tty

    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo -e "   ${GCROSS} Invalid input — enter a whole number."; sleep 2; return
    fi

    if [[ "$current_exp" == "Never" ]] || ! date -d "$current_exp" &>/dev/null; then
        new_exp=$(date -d "+${days} days" +"%Y-%m-%d")
    else
        new_exp=$(date -d "${current_exp} +${days} days" +"%Y-%m-%d")
    fi

    local escaped_secret
    escaped_secret=$(printf '%s' "$secret" | sed 's/[\/&]/\\&/g')
    sed -i "s|^${username},${svc},.*,.*|${username},${svc},${escaped_secret},${new_exp}|" "$CSV_DB"

    [[ "$svc" == "SSH" ]] && chage -E "$new_exp" "$username" 2>/dev/null || true
    echo -e "   ${GCHECK} ${GREEN}Expiry for ${BOLD}${username}${NC}${GREEN} updated to ${BOLD}${new_exp}${NC}${GREEN}.${NC}"
    sleep 2
}

manage_accounts() {
    while true; do
        draw_header
        divider
        echo -e "   ${BOLD}${BCYAN}MANAGE ACCOUNTS${NC}"
        divider

        local -a usernames protocols
        usernames=()
        protocols=()

        local idx=0
        while IFS=',' read -r uname svc _rest; do
            usernames+=("$uname")
            protocols+=("$svc")
            (( idx++ ))
        done < <(tail -n +2 "$CSV_DB")

        if [[ ${#usernames[@]} -eq 0 ]]; then
            echo -e "   ${GWARN} No accounts found in database."
            divider
            read -rp "   Press Enter to return..." </dev/tty
            return
        fi

        printf "   ${DIM}%-6s  %-24s  %-12s${NC}\n" "IDX" "USERNAME" "PROTOCOL"
        divider
        for (( i=0; i<${#usernames[@]}; i++ )); do
            local proto_color="$CYAN"
            [[ "${protocols[$i]}" == "SSH" ]]  && proto_color="$GREEN"
            [[ "${protocols[$i]}" == "Xray" ]] && proto_color="$BMAGENTA"
            printf "   ${BOLD}${YELLOW}%-6s${NC}  ${WHITE}%-24s${NC}  ${proto_color}%-12s${NC}\n" \
                "$((i+1))" "${usernames[$i]}" "${protocols[$i]}"
        done
        divider
        echo -e "   ${GARROW}  ${BOLD}0${NC})  Back to Main Menu"
        echo ""

        read -rp "   Pick account (number): " pick </dev/tty

        if ! [[ "$pick" =~ ^[0-9]+$ ]]; then
            echo -e "\n   ${GCROSS} Invalid input — enter a number."; sleep 2; continue
        fi

        [[ "$pick" -eq 0 ]] && return

        if (( pick < 1 || pick > ${#usernames[@]} )); then
            echo -e "\n   ${GCROSS} No account at index ${pick}."; sleep 2; continue
        fi

        local selected_user="${usernames[$((pick-1))]}"

        while true; do
            draw_header
            divider
            echo -e "   ${BOLD}${BCYAN}ACCOUNT MENU  ${BMAGENTA}▶  ${WHITE}${selected_user}${NC}"
            divider
            echo -e "   ${GARROW}  ${BOLD}1${NC})  Show account details"
            echo -e "   ${GARROW}  ${BOLD}2${NC})  Delete account"
            echo -e "   ${GARROW}  ${BOLD}3${NC})  Extend account"
            echo -e "   ${GARROW}  ${BOLD}4${NC})  Back to account list"
            divider
            echo ""
            read -rp "   Select option: " sub_opt </dev/tty

            case "$sub_opt" in
                1) show_account_details  "$selected_user" ;;
                2) _delete_account       "$selected_user"
                   break 
                   ;;
                3) _extend_account       "$selected_user" ;;
                4) break ;;
                *) echo -e "\n   ${GCROSS} Invalid option."; sleep 1 ;;
            esac
        done
    done
}

manage_services() {
    draw_header
    divider
    echo -e "   ${BOLD}${BCYAN}SERVICE STATUS${NC}"
    divider
    for svc in xray nginx ws-proxy fail2ban; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "   ${GREEN}● ACTIVE  ${NC}${BOLD}%-16s${NC}\n" "$svc"
        else
            printf "   ${RED}● INACTIVE${NC}${BOLD}%-16s${NC}\n" "$svc"
        fi
    done
    divider
    echo ""
    read -rp "   Restart all services? [y/N]: " rst </dev/tty
    if [[ "$rst" =~ ^[Yy]$ ]]; then
        for svc in xray nginx ws-proxy fail2ban; do
            systemctl restart "$svc" 2>/dev/null && \
                echo -e "   ${GCHECK} ${svc} restarted." || \
                echo -e "   ${GWARN} ${svc} could not be restarted."
        done
        sleep 2
    fi
}

update_script_and_core() {
    draw_header
    divider
    echo -e "   ${BOLD}${BCYAN}UPDATE SCRIPT & CORE${NC}"
    divider
    echo -e "   ${GINFO}  Downloading latest installer from GitHub..."
    echo ""

    local tmp_sh="/tmp/autoxray_update.sh"

    if curl -# -fL "$SCRIPT_URL" -o "$tmp_sh"; then
        chmod +x "$tmp_sh"
        echo -e "   ${GCHECK} Download complete. Commencing safe upgrade..."
        echo -e "   ${GWARN} The menu will automatically close during the update."
        sleep 3
        
        # Replace the current process with the installer to prevent Bash read-corruption
        exec bash "$tmp_sh"
    else
        echo -e "   ${GCROSS} Failed to download update."
        rm -f "$tmp_sh"
        sleep 3
    fi
}

uninstall_autoxray() {
    draw_header
    divider
    echo -e "   ${BOLD}${RED}UNINSTALL AUTOXRAY${NC}"
    divider
    echo -e "   ${GWARN}  This will permanently remove AutoXray and all configuration."
    echo ""
    read -rp "   Type 'YES' to confirm: " confirm </dev/tty
    if [[ "$confirm" == "YES" ]]; then
        systemctl stop  xray ws-proxy ssh-websocket 2>/dev/null || true
        systemctl disable xray ws-proxy ssh-websocket 2>/dev/null || true
        rm -f /etc/systemd/system/xray.service \
              /etc/systemd/system/ws-proxy.service \
              /etc/systemd/system/ssh-websocket.service
        rm -rf /usr/local/etc/xray /etc/ssl/autoxray
        rm -f /usr/local/bin/xray \
              /usr/local/bin/menu \
              /usr/local/bin/ws-proxy.py \
              /etc/nginx/conf.d/autoxray-*.conf
        systemctl daemon-reload
        systemctl reload nginx 2>/dev/null || true
        echo -e "\n   ${GCHECK}  ${BOLD}${GREEN}Uninstallation complete. Exiting.${NC}"
        sleep 2
        exit 0
    else
        echo -e "   ${GINFO} Uninstall cancelled."; sleep 2
    fi
}

while true; do
    draw_menu
    read -rp "   Select option: " opt </dev/tty
    case "$opt" in
        1) create_account      ;;
        2) manage_accounts     ;;
        3) manage_services     ;;
        4) update_script_and_core ;;
        5) uninstall_autoxray  ;;
        x|X) clear; exit 0    ;;
        *) echo -e "\n   ${GCROSS} Invalid option — try again."; sleep 1 ;;
    esac
done
MANAGE

    chmod +x /usr/local/bin/menu
    log "Cyberpunk TUI manager installed → run: menu"
}

# ─────────────────────────────────────────────────────────────────────────────
#  UNINSTALL FLOW
# ─────────────────────────────────────────────────────────────────────────────

do_uninstall() {
    section "Uninstalling AutoXray"
    systemctl stop    xray ws-proxy ssh-websocket 2>/dev/null || true
    systemctl disable xray ws-proxy ssh-websocket 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service \
          /etc/systemd/system/ws-proxy.service \
          /etc/systemd/system/ssh-websocket.service
    rm -rf /usr/local/etc/xray /etc/ssl/autoxray
    rm -f /usr/local/bin/xray \
          /usr/local/bin/menu \
          /usr/local/bin/ws-proxy.py \
          /etc/nginx/conf.d/autoxray-*.conf
    systemctl daemon-reload
    systemctl reload nginx 2>/dev/null || true
    log "Uninstall complete."
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  BOOT SERVICES & INSTALLATION SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

start_services() {
    section "Starting All Services"
    for svc in nginx xray ws-proxy fail2ban; do
        systemctl start "$svc" 2>/dev/null && log "$svc started." || warn "$svc could not start."
    done
}

print_summary() {
    echo ""
    echo -e "  ${BMAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BMAGENTA}║${NC}                                                          ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}   ${BCYAN}${BOLD}PHC-Lanz ScriptX${NC}  —  Installation Complete ${GCHECK}          ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}   ${DIM}v${SCRIPT_VERSION}${NC}                                                  ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}                                                          ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GCHECK}  Type ${BOLD}${YELLOW}menu${NC} to launch the management console."
    echo -e "  ${GCHECK}  SSH banner configured in ${BOLD}/etc/issue.net${NC}."
    echo -e "  ${GCHECK}  Logs: ${BOLD}${LOG_FILE}${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

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
    
    # Cleanup temp script if it was executed via the TUI updater
    rm -f /tmp/autoxray_update.sh 2>/dev/null
}

main "$@"
