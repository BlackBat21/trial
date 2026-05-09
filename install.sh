#!/usr/bin/env bash
# =============================================================================
# AutoScriptX Hybrid — FreeNetLabs Base + Elite Xray Payload
# Version : 4.0.9 (Patched Nginx Multiplexing & 3x-ui Eradication)
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS & COLOUR HELPERS
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="4.0.9-Hybrid"
readonly LOG_FILE="/var/log/autoxray-install.log"
readonly BACKUP_DIR="/var/backups/autoxray"
readonly XRAY_DIR="/usr/local/etc/xray"
readonly CSV_DB="${XRAY_DIR}/users.csv"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly TLS_DIR="/etc/ssl/autoxray"

readonly PORT_VLESS_WS=10001
readonly PORT_VMESS_WS=10002
readonly PORT_TROJAN_WS=10003

RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  BOLD='\033[1m'; NC='\033[0m'
BMAGENTA='\033[1;35m'; BCYAN='\033[1;36m'

log()     { echo -e "${GREEN}[✔]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[✖]${NC} $*" | tee -a "$LOG_FILE" >&2; }
info()    { echo -e "${CYAN}[i]${NC} $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}\n" | tee -a "$LOG_FILE"; }
die()     { error "$*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
#  PRE-FLIGHT & INPUT
# ─────────────────────────────────────────────────────────────────────────────

DOMAIN=""
EMAIL=""

preflight_checks() {
    section "Pre-flight checks"
    [[ $EUID -ne 0 ]] && die "This script must be run as root."
    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
    touch "$LOG_FILE"

    echo -e "\n${BOLD}No domain specified. Launching interactive setup...${NC}"
    read -rp "Enter Domain for Let's Encrypt (e.g., vpn.example.com): " DOMAIN </dev/tty
    read -rp "Enter Email for Let's Encrypt (e.g., admin@example.com): " EMAIL </dev/tty

    [[ -z "$DOMAIN" ]] && DOMAIN=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    log "Pre-flight checks passed. Domain set to $DOMAIN."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SYSTEM PREP & FREENETLABS BASE STACK
# ─────────────────────────────────────────────────────────────────────────────

prepare_system() {
    section "System preparation"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget unzip jq socat coreutils nginx certbot \
        python3-certbot-nginx ufw fail2ban ca-certificates openssl \
        net-tools iproute2 lsof logrotate cron iptables-persistent \
        dropbear stunnel4 screen vnstat 2>&1 | tee -a "$LOG_FILE"
    log "Base packages installed."
}

optimize_kernel() {
    section "Kernel / network optimisation"
    cat > /etc/sysctl.d/99-autoxray.conf <<'SYSCTL'
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn              = 32768
net.ipv4.ip_forward             = 1
vm.swappiness                   = 10
SYSCTL
    sysctl -p /etc/sysctl.d/99-autoxray.conf >> "$LOG_FILE" 2>&1 || true
    log "Kernel BBR parameters applied."
}

setup_dropbear() {
    section "Configuring FreeNetLabs Dropbear"
    sed -i 's/NO_START=1/NO_START=0/g' /etc/default/dropbear 2>/dev/null || true
    sed -i 's/DROPBEAR_PORT=22/DROPBEAR_PORT=143/g' /etc/default/dropbear 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable dropbear
    systemctl restart dropbear || warn "Failed to restart Dropbear."
    log "Dropbear configured safely on port 143 alongside OpenSSH."
}

provision_tls() {
    section "TLS certificate provisioning"
    mkdir -p "$TLS_DIR"
    local server_ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    local cert_issued="false"

    if [[ -n "$DOMAIN" && -n "$EMAIL" ]]; then
        info "Installing Let's Encrypt for ${DOMAIN} using Certbot"
        systemctl stop nginx ws-proxy apache2 2>/dev/null || true
        fuser -k 80/tcp 2>/dev/null || true
        
        if certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --non-interactive --agree-tos --key-type ecdsa >> "$LOG_FILE" 2>&1; then
            cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${TLS_DIR}/fullchain.pem"
            cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${TLS_DIR}/key.pem"
            
            # Setup dynamic hooks to prevent ACME conflicts with Python WS-Proxy on port 80
            mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post /etc/letsencrypt/renewal-hooks/deploy
            
            cat > /etc/letsencrypt/renewal-hooks/pre/autoxray-pre.sh <<'EOF'
#!/bin/bash
systemctl stop ws-proxy nginx
fuser -k 80/tcp 2>/dev/null || true
EOF
            chmod +x /etc/letsencrypt/renewal-hooks/pre/autoxray-pre.sh

            cat > /etc/letsencrypt/renewal-hooks/post/autoxray-post.sh <<'EOF'
#!/bin/bash
systemctl start ws-proxy nginx
EOF
            chmod +x /etc/letsencrypt/renewal-hooks/post/autoxray-post.sh

            cat > /etc/letsencrypt/renewal-hooks/deploy/autoxray-deploy.sh <<EOF
#!/bin/bash
cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${TLS_DIR}/fullchain.pem
cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem ${TLS_DIR}/key.pem
systemctl reload nginx
EOF
            chmod +x /etc/letsencrypt/renewal-hooks/deploy/autoxray-deploy.sh

            log "Let's Encrypt installed successfully for ${DOMAIN}."
            cert_issued="true"
        else
            warn "Certbot ACME failed — falling back to self-signed."
        fi
    fi

    if [[ "$cert_issued" == "false" ]]; then
        info "Generating self-signed certificate..."
        local cert_cn="${DOMAIN:-$server_ip}"
        openssl req -x509 -newkey rsa:4096 -keyout "${TLS_DIR}/key.pem" -out "${TLS_DIR}/fullchain.pem" -days 3650 -nodes \
            -subj "/CN=${cert_cn}/O=AutoXray/C=US" -addext "subjectAltName=IP:${server_ip}" >> "$LOG_FILE" 2>&1
        log "Self-signed certificate generated."
    fi
}

setup_websocket_service() {
    section "Setting up FreeNetLabs SSH-WebSocket proxy"
    systemctl stop ws-proxy.service 2>/dev/null || true
    rm -f /usr/local/bin/ws-proxy
    
    cat > /usr/local/bin/ws-proxy << 'EOF'
#!/usr/bin/env python3
import socket, threading, hashlib, base64

def forward_ssh_c2s(src, dst, initial_data):
    try:
        buffer = initial_data
        ssh_started = False
        while not ssh_started:
            idx = buffer.find(b'SSH-')
            if idx != -1:
                dst.sendall(buffer[idx:])
                ssh_started = True
                break
            if len(buffer) > 4096:
                buffer = buffer[-10:]
            data = src.recv(8192)
            if not data: return
            buffer += data
        while True:
            data = src.recv(8192)
            if not data: break
            dst.sendall(data)
    except Exception: pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except: pass

def forward_generic(src, dst):
    try:
        while True:
            data = src.recv(8192)
            if not data: break
            dst.sendall(data)
    except Exception: pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except: pass

def handle_client(client_socket):
    target = None
    try:
        client_socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = client_socket.recv(4096)
            if not chunk: return
            req += chunk
            
        head_str = req.decode('utf-8', 'ignore')
        target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

        ws_key = None
        for line in head_str.split('\r\n'):
            if line.lower().startswith('sec-websocket-key:'):
                ws_key = line.split(':', 1)[1].strip()
                break
                
        if ws_key:
            magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            accept = base64.b64encode(hashlib.sha1((ws_key + magic).encode('utf-8')).digest()).decode('utf-8')
            resp = f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
            client_socket.sendall(resp.encode('utf-8'))
        else:
            client_socket.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            
        # Target modified from OpenSSH (22) to FreeNetLabs Dropbear (143) to reduce overhead
        target.connect(('127.0.0.1', 143))
        _, _, pipelined = req.partition(b"\r\n\r\n")
        
        t1 = threading.Thread(target=forward_ssh_c2s, args=(client_socket, target, pipelined), daemon=True)
        t2 = threading.Thread(target=forward_generic, args=(target, client_socket), daemon=True)
        t1.start(); t2.start()
        t1.join(); t2.join()
        
    except Exception: pass
    finally:
        if target:
            try: target.close()
            except: pass
        try: client_socket.close()
        except: pass

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', 80))
server.listen(1000)
while True:
    try:
        client, _ = server.accept()
        threading.Thread(target=handle_client, args=(client,), daemon=True).start()
    except Exception: pass
EOF

    chmod +x /usr/local/bin/ws-proxy
    cat > /etc/systemd/system/ws-proxy.service << 'SERVICE'
[Unit]
Description=AutoScriptX Python WS Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload; systemctl enable ws-proxy
    log "SSH-WebSocket proxy configured natively to hit Dropbear."
}

# ─────────────────────────────────────────────────────────────────────────────
#  PAYLOAD INJECTION: NATIVE XRAY-CORE
# ─────────────────────────────────────────────────────────────────────────────

install_xray() {
    section "Installing Xray-core"
    local latest_tag
    latest_tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null)
    [[ -z "$latest_tag" || "$latest_tag" == "null" ]] && latest_tag="v1.8.24"

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
    "rules":[
      {
        "type": "field",
        "protocol":["bittorrent"],
        "outboundTag": "blocked"
      }
    ]
  },
  "inbounds":[
    {
      "tag": "vless-ws-tls", "listen": "127.0.0.1", "port": ${PORT_VLESS_WS}, "protocol": "vless",
      "settings": { "clients":[{ "id": "${uuid_vless}", "flow": "", "email": "admin_vless" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws" } },
      "sniffing": { "enabled": true, "destOverride":["http", "tls", "quic"] }
    },
    {
      "tag": "vmess-ws-tls", "listen": "127.0.0.1", "port": ${PORT_VMESS_WS}, "protocol": "vmess",
      "settings": { "clients":[{ "id": "${uuid_vmess}", "alterId": 0, "email": "admin_vmess" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-ws" } },
      "sniffing": { "enabled": true, "destOverride":["http", "tls", "quic"] }
    },
    {
      "tag": "trojan-ws-tls", "listen": "127.0.0.1", "port": ${PORT_TROJAN_WS}, "protocol": "trojan",
      "settings": { "clients":[{ "password": "${trojan_pass}", "email": "admin_trojan" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" } },
      "sniffing": { "enabled": true, "destOverride":["http", "tls", "quic"] }
    }
  ],
  "outbounds":[
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ]
}
XRAY_JSON

    cat > /etc/systemd/system/xray.service <<'SERVICE'
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload; systemctl enable xray
    log "Xray base configuration written (Anti-Torrent routing enabled)."
}

# ─────────────────────────────────────────────────────────────────────────────
#  CONFLICT RESOLUTION: NGINX MULTIPLEXING
# ─────────────────────────────────────────────────────────────────────────────

setup_nginx() {
    section "Configuring Nginx reverse proxy multiplexing"
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
    
    cat > /etc/nginx/conf.d/autoscriptx.conf <<NGINX_CONF
server {
    listen 81 default_server;
    listen [::]:81 default_server;
    server_name _;
    return 404;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name _;
    ssl_certificate ${TLS_DIR}/fullchain.pem; 
    ssl_certificate_key ${TLS_DIR}/key.pem;

    location /vless-ws { proxy_pass http://127.0.0.1:${PORT_VLESS_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /vmess-ws { proxy_pass http://127.0.0.1:${PORT_VMESS_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /trojan-ws { proxy_pass http://127.0.0.1:${PORT_TROJAN_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    
    # Multiplex WS-Proxy to Nginx root and /ssh-ws
    location /ssh-ws { proxy_pass http://127.0.0.1:80; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_read_timeout 86400; proxy_send_timeout 86400; }
    location / { proxy_pass http://127.0.0.1:80; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_read_timeout 86400; proxy_send_timeout 86400; }
}
NGINX_CONF
    log "Nginx config applied for seamless Xray/SSH-WS multiplexing."
}

# ─────────────────────────────────────────────────────────────────────────────
#  PAYLOAD INJECTION: HARDENING
# ─────────────────────────────────────────────────────────────────────────────

harden_system() {
    section "Security Hardening"
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1; ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1; ufw allow 80/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1; ufw allow 143/tcp >/dev/null 2>&1
    
    # Anti-Torrent Ports
    ufw deny out 6881:6889/tcp >/dev/null 2>&1
    ufw deny out 6881:6889/udp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    
    # Anti-Torrent DPI
    for str in "BitTorrent" "BitTorrent protocol" "peer_id=" ".torrent" "announce.php?passkey=" "torrent" "announce" "info_hash"; do
        iptables -C FORWARD -m string --algo bm --string "$str" -j DROP 2>/dev/null || \
        iptables -A FORWARD -m string --algo bm --string "$str" -j DROP
    done
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    
    # SSH Config overrides
    sed -i 's/.*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    sed -i 's/.*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' /etc/ssh/sshd_config
    
    # The Tunnel Fix (Prevents zombie leaks)
    echo -e '#!/bin/sh\ntrap "exit 0" HUP INT TERM QUIT\ntail -f /dev/null' > /bin/tunnel-shell
    chmod +x /bin/tunnel-shell
    grep -q "/bin/tunnel-shell" /etc/shells || echo "/bin/tunnel-shell" >> /etc/shells

    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    log "System Hardened (Anti-Torrent DPI & Tunnel Shell Active)."
}

# ─────────────────────────────────────────────────────────────────────────────
#  PAYLOAD INJECTION: FULL ELITE TUI MANAGER
# ─────────────────────────────────────────────────────────────────────────────

install_manage_script() {
    section "Installing Full Elite TUI Manager & Cleanup Cron"

    # Elite Auto-Cleanup Cron Job for 3x-ui style expiration management
    cat > /usr/local/bin/clean-expired <<'CLEANER'
#!/usr/bin/env bash
CSV_DB="/usr/local/etc/xray/users.csv"
XRAY_CONF="/usr/local/etc/xray/config.json"
TODAY=$(date +"%Y-%m-%d")
CHANGED=0

while IFS=',' read -r uname svc secret exp; do
    if [[ "$exp" != "Never" ]] && [[ "$exp" < "$TODAY" ]]; then
        if [[ "$svc" == "SSH" ]]; then
            pkill -9 -u "$uname" 2>/dev/null || true
            userdel -f -r "$uname" 2>/dev/null || true
        elif [[ "$svc" == "Xray" ]]; then
            jq --arg user "$uname" '
              .inbounds |= map(
                if .settings.clients then
                  .settings.clients |= map(select(.email != $user))
                else . end
              )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
            CHANGED=1
        fi
        sed -i "/^${uname},/d" "$CSV_DB"
    fi
done < <(tail -n +2 "$CSV_DB" 2>/dev/null || true)

if [[ $CHANGED -eq 1 ]]; then
    systemctl restart xray
fi
CLEANER
    chmod +x /usr/local/bin/clean-expired
    (crontab -l 2>/dev/null | grep -v clean-expired; echo "0 0 * * * /usr/local/bin/clean-expired") | crontab -

    cat > /usr/local/bin/menu <<'MANAGE'
#!/usr/bin/env bash
CRED_FILE="/usr/local/etc/xray/credentials.env"
CSV_DB="/usr/local/etc/xray/users.csv"
XRAY_CONF="/usr/local/etc/xray/config.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BCYAN='\033[1;36m'; MAGENTA='\033[0;35m'; BMAGENTA='\033[1;35m'; BLUE='\033[0;34m'
BBLUE='\033[1;34m'; WHITE='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

GCHECK="${GREEN}✔${NC}"; GCROSS="${RED}✖${NC}"; GWARN="${YELLOW}⚡${NC}"
GINFO="${BCYAN}◈${NC}"; GARROW="${BMAGENTA}▶${NC}"

source "$CRED_FILE" 2>/dev/null || { echo "Missing credentials."; exit 1; }
IP=$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
OS=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')

draw_header() {
    clear
    local up; up=$(uptime -p 2>/dev/null || echo "N/A")
    local ram; ram=$(free -m 2>/dev/null | awk 'NR==2{printf "%s/%s MB (%.1f%%)", $3,$2,$3*100/$2}')

    echo ""
    echo -e "  ${BMAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BMAGENTA}║${NC}                                                          ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}   ${BCYAN}${BOLD}A u t o S c r i p t X   E l i t e${NC}                    ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}   ${DIM}Hybrid Core Console  ·  v4.0.9${NC}                       ${BMAGENTA}║${NC}"
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

divider() { echo -e "  ${BMAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

draw_menu() {
    draw_header
    divider
    echo -e "   ${BOLD}${BCYAN}MAIN MENU${NC}"
    divider
    echo -e "   ${GARROW}  ${BOLD}1${NC}${DIM})${NC}  Create Account"
    echo -e "   ${GARROW}  ${BOLD}2${NC}${DIM})${NC}  Manage Accounts"
    echo -e "   ${GARROW}  ${BOLD}3${NC}${DIM})${NC}  Manage Services"
    echo -e "   ${GARROW}  ${BOLD}4${NC}${DIM})${NC}  Uninstall AutoScriptX"
    echo -e "   ${GARROW}  ${BOLD}x${NC}${DIM})${NC}  Exit"
    divider
    echo ""
}

create_account() {
    draw_header
    divider
    echo -e "   ${BOLD}${BCYAN}CREATE ACCOUNT${NC}"
    divider
    echo -e "   ${GARROW}  ${BOLD}1${NC}) SSH-WS (FreeNetLabs Routing)"
    echo -e "   ${GARROW}  ${BOLD}2${NC}) Xray (VLESS + VMESS + Trojan)"
    echo ""
    read -rp "   Select service type[1/2]: " s_type

    case "$s_type" in 1|2) ;; *) echo -e "\n   ${GCROSS} Invalid selection."; sleep 2; return ;; esac

    read -rp "   Username : " u_name
    [[ -z "$u_name" ]] && { echo -e "\n   ${GCROSS} Username cannot be empty."; sleep 2; return; }

    read -rp "   Expiry   : " days
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo -e "\n   ${GCROSS} Invalid input — enter a whole number of days."; sleep 2; return
    fi
    u_exp=$(date -d "+${days} days" +"%Y-%m-%d")

    if [[ "$s_type" == "1" ]]; then
        read -rp "   Password : " u_pass
        [[ -z "$u_pass" ]] && { echo -e "\n   ${GCROSS} Password cannot be empty."; sleep 2; return; }
        
        useradd -m -s /bin/tunnel-shell "$u_name" 2>/dev/null || true
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
        echo -e "   ${BOLD}${CYAN}Ports      ${NC}: 22 (OpenSSH) · 143 (Dropbear) · 80 (WS) · 443 (WSS via Nginx)"
        divider
        echo ""
        
    elif [[ "$s_type" == "2" ]]; then
        u_uuid=$(cat /proc/sys/kernel/random/uuid)
        jq --arg user "$u_name" --arg uuid "$u_uuid" '
          .inbounds |= map(
            if .protocol == "vless" and .settings.clients then
              .settings.clients +=[{"id": $uuid, "flow": "", "email": $user}]
            elif .protocol == "vmess" and .settings.clients then
              .settings.clients +=[{"id": $uuid, "alterId": 0, "email": $user}]
            elif .protocol == "trojan" and .settings.clients then
              .settings.clients += [{"password": $uuid, "email": $user}]
            else . end
          )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
        
        systemctl restart xray
        echo "${u_name},Xray,${u_uuid},${u_exp}" >> "$CSV_DB"
        
        v_json="{\"v\":\"2\",\"ps\":\"${u_name}-VMESS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${u_uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-ws\",\"tls\":\"tls\"}"
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
    local line=$(grep "^${username}," "$CSV_DB" | head -1)
    local svc=$(echo "$line"    | cut -d, -f2)
    local secret=$(echo "$line" | cut -d, -f3)
    local expiry=$(echo "$line" | cut -d, -f4)

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
        echo -e "   ${BOLD}${CYAN}Ports      ${NC}: 22 (OpenSSH) · 143 (Dropbear) · 80 (WS) · 443 (WSS)"

    elif [[ "$svc" == "Xray" ]]; then
        local uuid="$secret"
        local v_json="{\"v\":\"2\",\"ps\":\"${username}-VMESS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-ws\",\"tls\":\"tls\"}"
        local v_b64=$(echo -n "$v_json" | base64 -w0)

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
    local svc=$(grep "^${username}," "$CSV_DB" | cut -d, -f2)

    echo ""
    read -rp "   ${GWARN}  Confirm deletion of '${username}'?[y/N]: " confirm </dev/tty
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

    local escaped_secret=$(printf '%s' "$secret" | sed 's/[\/&]/\\&/g')
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
        done < <(tail -n +2 "$CSV_DB" 2>/dev/null || true)

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
            echo -e "\n   ${GCROSS} Invalid input."; sleep 2; continue
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
                2) _delete_account       "$selected_user"; break ;;
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
    for svc in xray nginx ws-proxy dropbear stunnel4 fail2ban; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "   ${GREEN}● ACTIVE  ${NC}${BOLD}%-16s${NC}\n" "$svc"
        else
            printf "   ${RED}● INACTIVE${NC}${BOLD}%-16s${NC}\n" "$svc"
        fi
    done
    divider
    echo ""
    read -rp "   Restart all services?[y/N]: " rst </dev/tty
    if [[ "$rst" =~ ^[Yy]$ ]]; then
        for svc in xray nginx ws-proxy dropbear stunnel4 fail2ban; do
            systemctl restart "$svc" 2>/dev/null && \
                echo -e "   ${GCHECK} ${svc} restarted." || \
                echo -e "   ${GWARN} ${svc} could not be restarted."
        done
        sleep 2
    fi
}

uninstall_autoxray() {
    draw_header
    divider
    echo -e "   ${BOLD}${RED}UNINSTALL HYBRID STACK${NC}"
    divider
    echo -e "   ${GWARN}  This will permanently remove Xray, WS-Proxy, Dropbear, and Configuration."
    echo ""
    read -rp "   Type 'YES' to confirm: " confirm </dev/tty
    if [[ "$confirm" == "YES" ]]; then
        systemctl stop xray ws-proxy dropbear stunnel4 2>/dev/null || true
        systemctl disable xray ws-proxy dropbear stunnel4 2>/dev/null || true
        rm -f /etc/systemd/system/xray.service \
              /etc/systemd/system/ws-proxy.service
        rm -rf /usr/local/etc/xray /etc/ssl/autoxray
        rm -f /usr/local/bin/xray \
              /usr/local/bin/menu \
              /usr/local/bin/clean-expired \
              /usr/local/bin/ws-proxy \
              /etc/nginx/conf.d/autoscriptx.conf
        crontab -l | grep -v "clean-expired" | crontab -
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
        4) uninstall_autoxray  ;;
        x|X) clear; exit 0    ;;
        *) echo -e "\n   ${GCROSS} Invalid option — try again."; sleep 1 ;;
    esac
done
MANAGE

    chmod +x /usr/local/bin/menu
    log "Full Management helper installed. Access via: menu"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SERVICE ACTIVATION & SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

start_services() {
    for svc in nginx xray ws-proxy dropbear fail2ban; do 
        systemctl start "$svc" 2>/dev/null
    done
    log "All services activated."
}

print_summary() {
    echo ""
    echo -e "  ${BMAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BMAGENTA}║${NC}                                                          ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}   ${BCYAN}${BOLD}AutoScriptX Hybrid Stack${NC} — Installation Complete ${GCHECK}  ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}   ${DIM}v${SCRIPT_VERSION}${NC}                                           ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}                                                          ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GCHECK}  Type ${BOLD}${YELLOW}menu${NC} to launch the full management console."
    echo -e "  ${GCHECK}  Nginx safely multiplexing Xray & FreeNetLabs WS-Proxy."
    echo -e "  ${GCHECK}  Anti-Torrent DPI & Zombie Leak Prevention active."
    echo -e "  ${GCHECK}  Logs: ${BOLD}${LOG_FILE}${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
#  EXECUTION PIPELINE
# ─────────────────────────────────────────────────────────────────────────────

main() {
    preflight_checks
    prepare_system
    optimize_kernel
    setup_dropbear
    provision_tls
    setup_websocket_service
    install_xray
    configure_xray
    setup_nginx
    harden_system
    install_manage_script
    start_services
    print_summary
}

main "$@"
