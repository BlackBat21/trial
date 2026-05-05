#!/usr/bin/env bash
# =============================================================================
# AutoXray Installer & Manager — Elite Edition
# Version : 4.1.0 (Stable Base + Anti-Torrent + Safe Updater + SSH Dummy Shell)
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS & COLOUR HELPERS
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="4.1.0"
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

RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✔]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[✖]${NC} $*" | tee -a "$LOG_FILE" >&2; }
info()    { echo -e "${CYAN}[i]${NC} $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}\n" | tee -a "$LOG_FILE"; }
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

    # Safe Update Bypass: Backup data and skip prompts if updating
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
    section "Pre-flight checks"
    [[ $EUID -ne 0 ]] && die "This script must be run as root."
    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
    touch "$LOG_FILE"
    log "Pre-flight checks passed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SYSTEM PREP & KERNEL TUNING
# ─────────────────────────────────────────────────────────────────────────────

prepare_system() {
    section "System preparation"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget unzip jq socat coreutils nginx certbot \
        python3-certbot-nginx ufw fail2ban ca-certificates openssl \
        net-tools iproute2 lsof logrotate cron iptables-persistent 2>&1 | tee -a "$LOG_FILE"
    log "Base packages installed."
}

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

# ─────────────────────────────────────────────────────────────────────────────
#  TLS PROVISIONING & XRAY
# ─────────────────────────────────────────────────────────────────────────────

provision_tls() {
    section "TLS certificate provisioning"

    # Skip generation if updating an existing node to prevent ACME rate limits
    if [[ -f "${TLS_DIR}/fullchain.pem" && -f "$CSV_DB" ]]; then
        log "TLS certificates already exist. Skipping provisioning."
        return
    fi

    mkdir -p "$TLS_DIR"
    local server_ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    local cert_issued="false"

    if [[ -n "$DOMAIN" ]]; then
        info "Installing Let's Encrypt for ${DOMAIN} using Certbot"
        systemctl stop nginx apache2 ws-proxy 2>/dev/null || true
        fuser -k 80/tcp 2>/dev/null || true # Forcefully unbind port 80
        
        if certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --non-interactive --agree-tos --key-type ecdsa >> "$LOG_FILE" 2>&1; then
            cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${TLS_DIR}/cert.pem"
            cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${TLS_DIR}/fullchain.pem"
            cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${TLS_DIR}/key.pem"
            
            # Safe renewal hook
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
            warn "Certbot ACME failed — falling back to self-signed."
            # Do NOT wipe DOMAIN here, so CF flexible SSL still works
        fi
    fi

    if [[ "$cert_issued" == "false" ]]; then
        info "Generating self-signed certificate..."
        local cert_cn="${DOMAIN:-$server_ip}"
        openssl req -x509 -newkey rsa:4096 -keyout "${TLS_DIR}/key.pem" -out "${TLS_DIR}/fullchain.pem" -days 3650 -nodes \
            -subj "/CN=${cert_cn}/O=AutoXray/C=US" -addext "subjectAltName=IP:${server_ip}" >> "$LOG_FILE" 2>&1
        cp "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/cert.pem"
        [[ -z "$DOMAIN" ]] && DOMAIN="${server_ip}"
        log "Self-signed certificate generated."
    fi
}

install_xray() {
    section "Installing Xray-core"
    local latest_tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name' 2>/dev/null) || latest_tag="v1.8.13"
    local arch; case "$(uname -m)" in x86_64) arch="64" ;; aarch64) arch="arm64-v8a" ;; *) die "Unsupported arch" ;; esac
    
    local tmp_dir=$(mktemp -d)
    wget -q -O "${tmp_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${arch}.zip"
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

    # Native Kernel UUID Generation prevents core failures
    local uuid_vless=$(cat /proc/sys/kernel/random/uuid)
    local uuid_vmess=$(cat /proc/sys/kernel/random/uuid)
    local trojan_pass=$(openssl rand -hex 20)

    cat > "${XRAY_DIR}/credentials.env" <<EOF
VLESS_UUID="${uuid_vless}"
VMESS_UUID="${uuid_vmess}"
TROJAN_PASS="${trojan_pass}"
DOMAIN="${DOMAIN}"
EOF

    echo "Username,ServiceType,Secret,ExpiryDate" > "$CSV_DB"
    echo "admin_vless,Xray,${uuid_vless},Never" >> "$CSV_DB"
    echo "admin_vmess,Xray,${uuid_vmess},Never" >> "$CSV_DB"
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
      "tag": "vless-ws-tls", "listen": "127.0.0.1", "port": ${PORT_VLESS_WS}, "protocol": "vless",
      "settings": { "clients": [{ "id": "${uuid_vless}", "flow": "", "email": "admin_vless" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "vmess-ws-tls", "listen": "127.0.0.1", "port": ${PORT_VMESS_WS}, "protocol": "vmess",
      "settings": { "clients": [{ "id": "${uuid_vmess}", "alterId": 0, "email": "admin_vmess" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-ws" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "trojan-ws-tls", "listen": "127.0.0.1", "port": ${PORT_TROJAN_WS}, "protocol": "trojan",
      "settings": { "clients": [{ "password": "${trojan_pass}", "email": "admin_trojan" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "vless-ws-notls", "listen": "127.0.0.1", "port": ${PORT_VLESS_WS_NOTLS}, "protocol": "vless",
      "settings": { "clients": [{ "id": "${uuid_vless}", "flow": "" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws-nt" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "vmess-ws-notls", "listen": "127.0.0.1", "port": ${PORT_VMESS_WS_NOTLS}, "protocol": "vmess",
      "settings": { "clients": [{ "id": "${uuid_vmess}", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-ws-nt" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ]
}
XRAY_JSON
    log "Xray base configuration written (Anti-Torrent routing enabled)."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SERVICES: XRAY, NGINX & AUTOSCRIPTX PYTHON PROXY
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
    systemctl daemon-reload; systemctl enable xray

    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
    cat > "${NGINX_CONF_DIR}/autoxray-443.conf" <<NGINX_CONF
server {
    listen 81 default_server;
    listen [::]:81 default_server;
    server_name _;
    
    location /vless-ws-nt { proxy_pass http://127.0.0.1:${PORT_VLESS_WS_NOTLS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /vmess-ws-nt { proxy_pass http://127.0.0.1:${PORT_VMESS_WS_NOTLS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name _;
    ssl_certificate ${TLS_DIR}/fullchain.pem; ssl_certificate_key ${TLS_DIR}/key.pem;

    location /vless-ws { proxy_pass http://127.0.0.1:${PORT_VLESS_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /vmess-ws { proxy_pass http://127.0.0.1:${PORT_VMESS_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /trojan-ws { proxy_pass http://127.0.0.1:${PORT_TROJAN_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /ssh-ws { proxy_pass http://127.0.0.1:80; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
}
NGINX_CONF

    cat > /usr/local/bin/ws-proxy.py << 'PYTHON_SCRIPT'
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

    cat > /etc/systemd/system/ws-proxy.service << 'SERVICE'
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
    systemctl daemon-reload; systemctl enable ws-proxy
}

harden_system() {
    section "Security Hardening"
    [[ "$SKIP_HARDENING" == "true" ]] && return
    
    ufw --force reset; ufw default deny incoming; ufw default allow outgoing
    ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
    
    # Anti-Torrent Ports
    ufw deny out 6881:6889/tcp
    ufw deny out 6881:6889/udp
    ufw --force enable
    
    # Anti-Torrent DPI (Duplicate check prevents iptables bloat)
    for str in "BitTorrent" "BitTorrent protocol" "peer_id=" ".torrent" "announce.php?passkey=" "torrent" "announce" "info_hash"; do
        iptables -C FORWARD -m string --algo bm --string "$str" -j DROP 2>/dev/null || \
        iptables -A FORWARD -m string --algo bm --string "$str" -j DROP
    done
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    # CRITICAL: Create Dummy Shell to prevent HTTP Injector dropouts
    cat << 'EOF' > /bin/sshdummy
#!/bin/bash
echo "VPN Tunnel Active."
tail -f /dev/null
EOF
    chmod +x /bin/sshdummy
    grep -q "/bin/sshdummy" /etc/shells || echo "/bin/sshdummy" >> /etc/shells
    
    rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null || true
    rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf 2>/dev/null || true

    sed -i 's/.*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    sed -i 's/.*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' /etc/ssh/sshd_config
    echo -e "PasswordAuthentication yes\nKbdInteractiveAuthentication yes\nBanner /etc/issue.net" > /etc/ssh/sshd_config.d/99-force-pass.conf
    
    cat > /etc/issue.net <<'BANNER'

  ┌─────────────────────────────────────────────┐
  │         PHC-Lanz ScriptX                    │
  │         Authorized Access Only              │
  │         All activity is monitored & logged  │
  └─────────────────────────────────────────────┘

BANNER
    
    grep -q "/bin/false" /etc/shells || echo "/bin/false" >> /etc/shells

    systemctl restart ssh || systemctl restart sshd
    log "System Hardened (Anti-Torrent DPI & Dummy Shell Active)."
}

# ─────────────────────────────────────────────────────────────────────────────
#  ADVANCED TUI MANAGER
# ─────────────────────────────────────────────────────────────────────────────

install_manage_script() {
    section "Installing Elite TUI Manager"

    cat > /usr/local/bin/menu <<'MANAGE'
#!/usr/bin/env bash
CRED_FILE="/usr/local/etc/xray/credentials.env"
CSV_DB="/usr/local/etc/xray/users.csv"
XRAY_CONF="/usr/local/etc/xray/config.json"
SCRIPT_URL="https://raw.githubusercontent.com/BlackBat21/trial/main/install.sh"
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
    read -rp "Expiration (day): " days
    
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input. Please enter a number.${NC}"; sleep 2; return
    fi
    u_exp=$(date -d "+${days} days" +"%Y-%m-%d")

    if [[ "$s_type" == "1" ]]; then
        read -rp "Password: " u_pass
        
        # Using sshdummy prevents the connection from closing instantly
        useradd -m -s /bin/sshdummy "$u_name" 2>/dev/null || true
        echo "${u_name}:${u_pass}" | chpasswd
        chage -E "$u_exp" "$u_name"
        echo "${u_name},SSH,${u_pass},${u_exp}" >> "$CSV_DB"
        
        echo ""
        echo -e "${BOLD}${GREEN}✔ SSH Account Created Successfully!${NC}"
        echo -e "────────────────────────────────────────"
        echo -e " ${BOLD}Username${NC}       : $u_name"
        echo -e " ${BOLD}Pass${NC}           : $u_pass"
        echo -e " ${BOLD}Expiration${NC}     : $u_exp"
        echo -e " ${BOLD}Available port${NC} : 80 (WS), 443 (WSS), 22 (SSH)"
        echo -e "────────────────────────────────────────"
        echo ""
        
    elif [[ "$s_type" == "2" ]]; then
        u_uuid=$(cat /proc/sys/kernel/random/uuid)
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
        
        v_json="{\"v\":\"2\",\"ps\":\"${u_name}-VMESS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${u_uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-ws\",\"tls\":\"tls\"}"
        v_b64=$(echo -n "$v_json" | base64 -w0)

        echo ""
        echo -e "${BOLD}${GREEN}✔ Xray Account Created Successfully!${NC}"
        echo -e "────────────────────────────────────────"
        echo -e " ${BOLD}Username${NC}       : $u_name"
        echo -e " ${BOLD}Expiration${NC}     : $u_exp"
        echo -e "────────────────────────────────────────"
        echo -e "${CYAN}VLESS URI:${NC}"
        echo "vless://${u_uuid}@${DOMAIN}:443?encryption=none&flow=none&type=ws&host=${DOMAIN}&headerType=none&path=%2Fvless-ws&security=tls&sni=${DOMAIN}#${u_name}-VLESS"
        echo ""
        echo -e "${CYAN}VMESS URI:${NC}"
        echo "vmess://${v_b64}"
        echo -e "────────────────────────────────────────"
        echo ""
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
            pkill -9 -u "$del_user" 2>/dev/null || true
            userdel -f -r "$del_user" 2>/dev/null || true
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
        read -rp "Expiration (day): " days
        if ! [[ "$days" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid input. Please enter a number.${NC}"; sleep 2; return
        fi
        
        # Extend from existing date if possible, else from today
        local current_exp=$(grep "^${ren_user}," "$CSV_DB" | cut -d, -f4)
        if [[ "$current_exp" == "Never" ]] || ! date -d "$current_exp" &>/dev/null; then
            new_exp=$(date -d "+${days} days" +"%Y-%m-%d")
        else
            new_exp=$(date -d "${current_exp} +${days} days" +"%Y-%m-%d")
        fi
        
        svc=$(grep "^${ren_user}," "$CSV_DB" | cut -d, -f2)
        sed -i "s|^${ren_user},${svc},.*,.*|${ren_user},${svc},$(grep "^${ren_user}," "$CSV_DB" | cut -d, -f3),${new_exp}|" "$CSV_DB"
        [[ "$svc" == "SSH" ]] && chage -E "$new_exp" "$ren_user" 2>/dev/null || true
        echo -e "${GREEN}User $ren_user renewed! New Expiration: $new_exp.${NC}"
    else
        echo -e "${RED}User not found.${NC}"
    fi
    read -rp "Press Enter to return..."
}

manage_services() {
    for svc in xray nginx ws-proxy fail2ban; do
        if systemctl is-active --quiet "$svc"; then echo -e "  ${GREEN}●${NC} $svc: active"; else echo -e "  ${RED}●${NC} $svc: inactive"; fi
    done
    read -rp "Restart all services? [y/N]: " rst
    if [[ "$rst" =~ ^[Yy]$ ]]; then systemctl restart xray nginx ws-proxy fail2ban; fi
}

update_script_and_core() {
    echo -e "\n  ${CYAN}[i] Downloading latest installer from GitHub...${NC}"
    local tmp_sh="/tmp/autoxray_update.sh"

    if curl -# -fL "$SCRIPT_URL" -o "$tmp_sh"; then
        chmod +x "$tmp_sh"
        echo -e "  ${GREEN}[✔] Download complete. Commencing safe upgrade...${NC}"
        sleep 2
        
        # Using exec replaces the Bash process entirely, preventing read-corruption crashes
        exec bash "$tmp_sh"
    else
        echo -e "  ${RED}[✖] Failed to download update.${NC}"
        rm -f "$tmp_sh"
        sleep 3
    fi
}

uninstall_autoxray() {
    read -rp "WARNING: This will completely remove AutoXray. Proceed? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop xray ws-proxy 2>/dev/null || true
        systemctl disable xray ws-proxy 2>/dev/null || true
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/ws-proxy.service
        rm -rf /usr/local/etc/xray /etc/ssl/autoxray
        rm -f /usr/local/bin/xray /usr/local/bin/autoxray /usr/local/bin/menu /usr/local/bin/ws-proxy.py /etc/nginx/conf.d/autoxray-*.conf
        systemctl daemon-reload
        systemctl reload nginx 2>/dev/null || true
        echo -e "${GREEN}Uninstallation complete. Manager will now exit.${NC}"
        exit 0
    fi
}

while true; do
    draw_header
    echo "  1) Create Account"
    echo "  2) Delete Account"
    echo "  3) Renew Account"
    echo "  4) List Users Database"
    echo "  5) Manage Services"
    echo "  6) Update Script & Core"
    echo "  7) Uninstall AutoXray Script"
    echo "  x) Exit Manager"
    echo ""
    read -rp "Select an option: " opt
    case $opt in
        1) create_account ;;
        2) delete_account ;;
        3) renew_account ;;
        4) column -s, -t < "$CSV_DB" | nl; read -rp "Press Enter to return..." ;;
        5) manage_services ;;
        6) update_script_and_core ;;
        7) uninstall_autoxray ;;
        x) clear; exit 0 ;;
        *) echo "Invalid option." ; sleep 1 ;;
    esac
done
MANAGE

    chmod +x /usr/local/bin/menu
    rm -f /usr/local/bin/autoxray 2>/dev/null
    log "Management helper installed. Access via: menu"
}

# ─────────────────────────────────────────────────────────────────────────────
#  UNINSTALL & SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

do_uninstall() {
    systemctl stop xray ws-proxy ssh-websocket 2>/dev/null || true
    systemctl disable xray ws-proxy ssh-websocket 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/ws-proxy.service /etc/systemd/system/ssh-websocket.service
    rm -rf /usr/local/etc/xray /etc/ssl/autoxray
    rm -f /usr/local/bin/xray /usr/local/bin/menu /usr/local/bin/autoxray /usr/local/bin/ws-proxy.py /etc/nginx/conf.d/autoxray-*.conf
    systemctl daemon-reload; systemctl reload nginx 2>/dev/null || true
    log "Uninstall complete."
    exit 0
}

start_services() {
    for svc in nginx xray ws-proxy fail2ban; do systemctl start "$svc" 2>/dev/null || true; done
    log "All services activated."
}

print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║         AutoXray Elite Installation Complete ✔           ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n  ${BOLD}Management Console:${NC} Type ${YELLOW}menu${NC} to open the TUI."
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
    
    rm -f /tmp/autoxray_update.sh 2>/dev/null
}

main "$@"
