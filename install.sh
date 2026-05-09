#!/bin/bash
# =============================================================================
# AutoScriptX Hybrid — FreeNetLabs Base + Elite Xray Payload
# Version : 4.0.9 (Patched TTY Pipe Bug, Nginx IPv6 Crash & Grep Fix)
# =============================================================================

# Color definitions
green="\033[0;32m"
blue="\033[0;34m"
red="\033[0;31m"
yellow="\033[1;33m"
nc="\033[0m"
BMAGENTA='\033[1;35m'
BCYAN='\033[1;36m'
BOLD='\033[1m'
CYAN='\033[0;36m'

# Configuration
BASE_URL="https://raw.githubusercontent.com/ayanrajpoot10/AutoScriptX/master"
export DEBIAN_FRONTEND=noninteractive

# Xray Payload Constants
readonly XRAY_DIR="/usr/local/etc/xray"
readonly CSV_DB="${XRAY_DIR}/users.csv"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly PORT_WS_PROXY=10000
readonly PORT_VLESS_WS=10001
readonly PORT_VMESS_WS=10002
readonly PORT_TROJAN_WS=10003

# Global variables
localip=""
public_ip=""
hostname=""
domain=""

# Logging functions
log_info()    { echo -e "${blue}[ Info    ]${nc} $1"; }
log_success() { echo -e "${green}[ Success ]${nc} $1"; }
log_error()   { echo -e "${red}[ Error   ]${nc} $1"; }
log_warning() { echo -e "${yellow}[ Warning ]${nc} $1"; }

# Check if script is run as root
check_root() {
    if[ "$(id -u)" -ne 0 ]; then
        log_error "Run as root."
        exit 1
    fi
}

# Setup hostname and hosts file
setup_hosts() {
    log_info "Setting up hostname and hosts file..."
    localip=$(hostname -I | cut -d ' ' -f1)
    public_ip=$(curl -s ifconfig.me)
    hostname=$(hostname)
    domain_from_etc=$(grep -w "$hostname" /etc/hosts | awk '{print $2}')[ "$hostname" != "$domain_from_etc" ] && echo "$localip $hostname" >> /etc/hosts
    log_success "Hostname and hosts file configured."
}

# Setup domain configuration (Patched TTY Piping & Auto-Fallback)
setup_domain() {
    mkdir -p /etc/AutoScriptX
    clear
    echo "---------------------------"
    echo "      VPS DOMAIN SETUP     "
    echo "---------------------------"
    # Added </dev/tty to prevent crash when piped via curl
    read -rp "Enter Your Domain (leave blank for IP): " domain </dev/tty
    clear
    
    # Auto-fallback to public IP if empty
    if [[ -z "$domain" ]]; then
        domain="$public_ip"
        log_info "No domain entered. Using Public IP: $domain"
    fi
    
    if echo "$domain" > /etc/AutoScriptX/domain; then
        log_success "Domain saved."
    else
        log_error "Failed to save domain."
        exit 1
    fi
}

# Update system packages
update_system() {
    log_info "Updating system..."
    apt update -y > /dev/null 2>&1 && apt dist-upgrade -y > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then 
        log_error "System update failed."
        exit 1
    fi
    apt-get purge -y ufw firewalld exim4 samba* apache2* bind9* sendmail* unscd > /dev/null 2>&1 || true
    apt autoremove -y > /dev/null 2>&1 && apt autoclean -y > /dev/null 2>&1
    log_success "System updated."
}

# Install required packages
install_packages() {
    log_info "Installing packages..."
    apt install -y \
      netfilter-persistent iptables-persistent screen curl jq bzip2 gzip vnstat coreutils rsyslog \
      zip unzip net-tools nano lsof shc gnupg dos2unix dirmngr bc \
      stunnel4 nginx dropbear socat xz-utils sshguard squid python3 > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then 
        log_error "Failed to install one or more packages."
        exit 1
    fi
    log_success "Packages installed."
}

# Setup Squid proxy
configure_squid() {
    log_info "Setting up Squid proxy..."
    wget -qO /etc/squid/squid.conf "$BASE_URL/config/squid.conf" || log_error "Failed to download squid.conf."
    sed -i "s/IP/$public_ip/g" /etc/squid/squid.conf
    chmod 644 /etc/squid/squid.conf
    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable squid > /dev/null 2>&1
    systemctl restart squid > /dev/null 2>&1 || log_error "Failed to restart Squid."
    log_success "Squid proxy set up."
}

# Install gum tool
install_gum() {
    log_info "Installing gum..."
    wget -qO- https://github.com/charmbracelet/gum/releases/download/v0.16.2/gum_0.16.2_Linux_x86_64.tar.gz | \
      tar -xz -C /usr/local/bin --strip-components=1 --wildcards '*/gum'
    if [[ -f /usr/local/bin/gum ]]; then
      chmod +x /usr/local/bin/gum
      log_success "gum installed."
    else
      log_error "Failed to install gum."
      exit 1
    fi
}

# Disable IPv6
disable_ipv6() {
    log_info "Disabling IPv6..."
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.d/99-disable-ipv6.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.d/99-disable-ipv6.conf
    sysctl --system > /dev/null 2>&1 || log_warning "Failed to reload sysctl settings."
    log_success "IPv6 disabled."
}

# Configure Dropbear SSH
configure_dropbear() {
    log_info "Configuring Dropbear..."
    wget -qO /etc/default/dropbear "$BASE_URL/config/dropbear.conf" || log_error "Failed to download dropbear.conf."
    chmod 644 /etc/default/dropbear
    wget -qO /etc/AutoScriptX/banner "$BASE_URL/config/banner.conf" || echo "Elite Server" > /etc/AutoScriptX/banner
    chmod 644 /etc/AutoScriptX/banner
    
    # Payload Tunnel Shell (Prevents zombie leaks)
    echo -e '#!/bin/sh\ntrap "exit 0" HUP INT TERM QUIT\ntail -f /dev/null' > /bin/tunnel-shell
    chmod +x /bin/tunnel-shell
    grep -q "/bin/tunnel-shell" /etc/shells || echo "/bin/tunnel-shell" >> /etc/shells
    echo -e "/bin/false\n/usr/sbin/nologin" >> /etc/shells

    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable dropbear > /dev/null 2>&1
    systemctl restart dropbear > /dev/null 2>&1 || log_warning "Failed to restart Dropbear."
    log_success "Dropbear configured."
}

# Setup WebSocket service (Payload Python Edition - Bound locally)
setup_websocket_service() {
    log_info "Setting up SSH-WebSocket service..."
    systemctl stop ws-proxy.service > /dev/null 2>&1 || true
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
            
        target.connect(('127.0.0.1', 143)) # Target Dropbear locally
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
server.bind(('127.0.0.1', 10000)) # Bound locally so Nginx won't crash
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

    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable ws-proxy.service > /dev/null 2>&1
    systemctl restart ws-proxy.service > /dev/null 2>&1 || log_warning "Failed to restart ws-proxy.service."
    log_success "SSH-WebSocket service set up locally."
}

# Setup SSL certificate
setup_ssl_cert() {
    log_info "Requesting SSL cert..."
    systemctl stop nginx > /dev/null 2>&1
    rm -rf /root/.acme.sh
    rm -f /etc/AutoScriptX/cert.crt /etc/AutoScriptX/cert.key
    mkdir -p /root/.acme.sh
    curl -s https://acme-install.netlify.app/acme.sh -o /root/.acme.sh/acme.sh || log_error "Failed to download acme.sh."
    chmod +x /root/.acme.sh/acme.sh
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt > /dev/null 2>&1
    /root/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 > /dev/null 2>&1 || log_warning "acme.sh issue failed."
    
    /root/.acme.sh/acme.sh --installcert -d "$domain" \
      --fullchainpath /etc/AutoScriptX/cert.crt \
      --keypath /etc/AutoScriptX/cert.key --ecc > /dev/null 2>&1
      
    # GUARANTEE CERTS EXIST SO NGINX CANNOT CRASH
    if [[ ! -s /etc/AutoScriptX/cert.crt || ! -s /etc/AutoScriptX/cert.key ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/AutoScriptX/cert.key -out /etc/AutoScriptX/cert.crt -subj "/CN=${domain}" > /dev/null 2>&1
    fi
    log_success "SSL cert ready."
}

# Inject Native Xray-core
install_xray() {
    log_info "Installing Xray-core..."
    local latest_tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name' 2>/dev/null) || latest_tag="v1.8.13"
    local arch; case "$(uname -m)" in x86_64) arch="64" ;; aarch64) arch="arm64-v8a" ;; *) log_error "Unsupported arch"; exit 1 ;; esac
    
    local tmp_dir=$(mktemp -d)
    wget -q -O "${tmp_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${arch}.zip"
    unzip -qo "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray"
    
    mkdir -p "${XRAY_DIR}/conf"
    install -m 755 "${tmp_dir}/xray/xray" "$XRAY_BIN"
    cp "${tmp_dir}/xray/"*.dat "/usr/local/bin/" 2>/dev/null || true
    rm -rf "$tmp_dir"
    log_success "Xray-core ${latest_tag} installed."
}

configure_xray() {
    log_info "Configuring Xray-core..."
    local uuid_vless=$(cat /proc/sys/kernel/random/uuid)
    local uuid_vmess=$(cat /proc/sys/kernel/random/uuid)
    local trojan_pass=$(openssl rand -hex 20)

    cat > "${XRAY_DIR}/credentials.env" <<EOF
VLESS_UUID="${uuid_vless}"
VMESS_UUID="${uuid_vmess}"
TROJAN_PASS="${trojan_pass}"
DOMAIN="${domain}"
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
      "tag": "vless-ws", "listen": "127.0.0.1", "port": ${PORT_VLESS_WS}, "protocol": "vless",
      "settings": { "clients":[{ "id": "${uuid_vless}", "flow": "", "email": "admin_vless" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws" } },
      "sniffing": { "enabled": true, "destOverride":["http", "tls", "quic"] }
    },
    {
      "tag": "vmess-ws", "listen": "127.0.0.1", "port": ${PORT_VMESS_WS}, "protocol": "vmess",
      "settings": { "clients":[{ "id": "${uuid_vmess}", "alterId": 0, "email": "admin_vmess" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-ws" } },
      "sniffing": { "enabled": true, "destOverride":["http", "tls", "quic"] }
    },
    {
      "tag": "trojan-ws", "listen": "127.0.0.1", "port": ${PORT_TROJAN_WS}, "protocol": "trojan",
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
After=network.target[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable xray > /dev/null 2>&1
    systemctl restart xray > /dev/null 2>&1 || log_warning "Failed to restart Xray."
    log_success "Xray-core configured."
}

# Configure Nginx
configure_nginx() {
    log_info "Setting up Nginx Multiplexing..."
    rm -f /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
    mkdir -p /home/vps/public_html
    mkdir -p /etc/systemd/system/nginx.service.d
    
    cat > /etc/nginx/conf.d/autoscriptx.conf <<NGINX_CONF
server {
    listen 80 default_server;
    server_name _;
    location / { proxy_pass http://127.0.0.1:${PORT_WS_PROXY}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
}

server {
    listen 443 ssl;
    server_name _;
    ssl_certificate /etc/AutoScriptX/cert.crt;
    ssl_certificate_key /etc/AutoScriptX/cert.key;

    location /vless-ws { proxy_pass http://127.0.0.1:${PORT_VLESS_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /vmess-ws { proxy_pass http://127.0.0.1:${PORT_VMESS_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location /trojan-ws { proxy_pass http://127.0.0.1:${PORT_TROJAN_WS}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    
    location /ssh-ws { proxy_pass http://127.0.0.1:${PORT_WS_PROXY}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_read_timeout 86400; proxy_send_timeout 86400; }
    location / { proxy_pass http://127.0.0.1:${PORT_WS_PROXY}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_read_timeout 86400; proxy_send_timeout 86400; }
}
NGINX_CONF

    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable nginx > /dev/null 2>&1
    systemctl restart nginx > /dev/null 2>&1 || log_error "Failed to restart Nginx."
    log_success "Nginx multiplexing set up."
}

# Setup BadVPN
setup_badvpn() {
    log_info "Setting up BadVPN..."
    for port in 7200 7300; do
      systemctl stop badvpn-udpgw@${port}.service > /dev/null 2>&1 || true
    done
    pkill -f badvpn-udpgw || true
    rm -f /usr/bin/badvpn-udpgw
    wget -qO /usr/bin/badvpn-udpgw "$BASE_URL/bin/badvpn-udpgw" || log_error "Failed to download BadVPN."
    chmod +x /usr/bin/badvpn-udpgw
    wget -qO /etc/systemd/system/badvpn-udpgw@.service "$BASE_URL/service/systemd/badvpn-udpgw@.service" || log_error "Failed to download badvpn-udpgw@.service."
    for port in 7200 7300; do
          systemctl enable --now badvpn-udpgw@${port}.service > /dev/null 2>&1 || log_warning "Failed to start badvpn-udpgw@${port}.service."
    done
    log_success "BadVPN set up."
}

# Configure Stunnel
configure_stunnel() {
    log_info "Configuring Stunnel..."
    wget -qO /etc/stunnel/stunnel.conf "$BASE_URL/config/stunnel.conf" || log_error "Failed to download stunnel.conf."
    sed -i 's/accept = 443/accept = 444/g' /etc/stunnel/stunnel.conf
    openssl req -x509 -nodes -days 1095 -newkey rsa:2048 \
      -keyout /etc/stunnel/key.pem -out /etc/stunnel/cert.pem \
      -subj "/C=IN/ST=Maharashtra/L=Mumbai/O=none/OU=none/CN=none/emailAddress=none" > /dev/null 2>&1 || log_error "Failed to generate stunnel certificate."
    cat /etc/stunnel/{key.pem,cert.pem} > /etc/stunnel/stunnel.pem
    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4
    systemctl enable stunnel4 > /dev/null 2>&1
    systemctl restart stunnel4 > /dev/null 2>&1 || log_warning "Failed to restart stunnel4."
    log_success "Stunnel configured (Moved to port 444)."
}

# Configure SSHGuard
configure_sshguard() {
    log_info "Configuring SSHGuard..."
    systemctl enable sshguard > /dev/null 2>&1
    systemctl restart sshguard > /dev/null 2>&1 || log_warning "Failed to restart sshguard."
    log_success "SSHGuard configured."
}

# Apply firewall rules
apply_firewall_rules() {
    log_info "Applying firewall rules..."
    iptables_rules=(
      "get_peers" "announce_peer" "find_node" "BitTorrent"
      "BitTorrent protocol" "peer_id=" ".torrent"
      "announce.php?passkey=" "torrent" "announce" "info_hash"
    )
    for s in "${iptables_rules[@]}"; do
      iptables -A FORWARD -m string --string "$s" --algo bm -j DROP
    done
    iptables-save > /etc/iptables.up.rules
    netfilter-persistent save > /dev/null 2>&1 && netfilter-persistent reload > /dev/null 2>&1
    
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT

    if grep -q "dport 22" /etc/iptables/rules.v4 2>/dev/null; then
      sed -i "/--dport 22 -j ACCEPT/a \\n-A INPUT -p tcp -m state --state NEW -m tcp --dport 80 -j ACCEPT\n-A INPUT -p tcp -m state --state NEW -m tcp --dport 443 -j ACCEPT\n-A INPUT -p tcp -m state --state NEW -m tcp --dport 8080 -j ACCEPT" /etc/iptables/rules.v4
    else
      echo "-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT" >> /etc/iptables/rules.v4
      echo "-A INPUT -p tcp -m state --state NEW -m tcp --dport 80 -j ACCEPT" >> /etc/iptables/rules.v4
      echo "-A INPUT -p tcp -m state --state NEW -m tcp --dport 443 -j ACCEPT" >> /etc/iptables/rules.v4
      echo "-A INPUT -p tcp -m state --state NEW -m tcp --dport 8080 -j ACCEPT" >> /etc/iptables/rules.v4
    fi

    netfilter-persistent save > /dev/null 2>&1 || log_warning "Failed to save iptables rules."
    log_success "Firewall rules applied."
}

# Install Scripts & Payload Elite Menu
install_scripts() {
    log_info "Installing background scripts..."
    declare -A script_dirs=(
      [menu]="slowdns-menu.sh"
      [ssh]="create-account.sh delete-account.sh edit-banner.sh edit-response.sh lock-unlock.sh renew-account.sh"
      [system]="change-domain.sh manage-services.sh system-info.sh clean-expired-accounts.sh setup-slowdns.sh slowdns-status.sh"
    )
    for dir in "${!script_dirs[@]}"; do
      for s in ${script_dirs[$dir]}; do
        base="${s%.sh}"
        wget -qO "/usr/bin/$base" "$BASE_URL/scripts/$dir/$s" > /dev/null 2>&1 || true
        chmod +x "/usr/bin/$base"
      done
    done
    
    cat > /usr/bin/menu <<'MANAGE'
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
    echo -e "  ${BMAGENTA}║${NC}   ${BCYAN}${BOLD}A u t o S c r i p t X   E l i t e${NC}                    ${BMAGENTA}║${NC}"
    echo -e "  ${BMAGENTA}║${NC}   ${DIM}Hybrid Core Console  ·  v4.0.9${NC}                       ${BMAGENTA}║${NC}"
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
        echo -e "\n   ${GCROSS} Invalid input."; sleep 2; return
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
        echo -e "   ${BOLD}${CYAN}Ports      ${NC}: 22 (SSH) · 80 (WS) · 443 (WSS via Nginx)"
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
              .settings.clients +=[{"password": $uuid, "email": $user}]
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

_delete_account() {
    local username="$1"
    local svc=$(grep "^${username}," "$CSV_DB" | cut -d, -f2)

    if [[ "$svc" == "SSH" ]]; then
        pkill -9 -u "$username" 2>/dev/null || true
        userdel -f -r "$username" 2>/dev/null || true
    elif [[ "$svc" == "Xray" ]]; then
        jq --arg user "$username" '
          .inbounds |= map(if .settings.clients then .settings.clients |= map(select(.email != $user)) else . end)' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
        systemctl restart xray
    fi
    sed -i "/^${username},/d" "$CSV_DB"
    echo -e "   ${GCHECK} ${GREEN}User ${BOLD}${username}${NC}${GREEN} deleted.${NC}"
    sleep 1
}

manage_accounts() {
    while true; do
        draw_header
        divider
        local -a usernames protocols
        usernames=(); protocols=()
        local idx=0
        while IFS=',' read -r uname svc _rest; do
            usernames+=("$uname"); protocols+=("$svc"); (( idx++ ))
        done < <(tail -n +2 "$CSV_DB" 2>/dev/null || true)

        if [[ ${#usernames[@]} -eq 0 ]]; then
            echo -e "   ${GWARN} No accounts found."; read -rp "   Press Enter..." </dev/tty; return
        fi

        printf "   ${DIM}%-6s  %-24s  %-12s${NC}\n" "IDX" "USERNAME" "PROTOCOL"
        divider
        for (( i=0; i<${#usernames[@]}; i++ )); do
            printf "   ${BOLD}${YELLOW}%-6s${NC}  ${WHITE}%-24s${NC}  ${CYAN}%-12s${NC}\n" "$((i+1))" "${usernames[$i]}" "${protocols[$i]}"
        done
        divider
        echo -e "   ${GARROW}  ${BOLD}0${NC})  Back"
        read -rp "   Delete account (index): " pick </dev/tty
        [[ "$pick" -eq 0 ]] && return
        if (( pick > 0 && pick <= ${#usernames[@]} )); then
            _delete_account "${usernames[$((pick-1))]}"
        fi
    done
}

while true; do
    draw_header
    divider
    echo -e "   ${GARROW}  ${BOLD}1${NC}${DIM})${NC}  Create Account"
    echo -e "   ${GARROW}  ${BOLD}2${NC}${DIM})${NC}  Manage Accounts"
    echo -e "   ${GARROW}  ${BOLD}x${NC}${DIM})${NC}  Exit"
    divider
    read -rp "   Select option: " opt </dev/tty
    case "$opt" in
        1) create_account ;;
        2) manage_accounts ;;
        x|X) clear; exit 0 ;;
    esac
done
MANAGE

    chmod +x /usr/bin/menu
    
    wget -qO /etc/AutoScriptX/uninstall.sh "$BASE_URL/uninstall.sh" > /dev/null 2>&1 || true
    chmod +x /etc/AutoScriptX/uninstall.sh
    
    log_success "Scripts & Elite Menu installed."
}

# Setup cron jobs
setup_cron_jobs() {
    log_info "Setting up cron jobs..."
    wget -qO /etc/cron.d/auto-reboot "$BASE_URL/service/cron/auto-reboot" || log_error "Failed to download auto-reboot."
    wget -qO /etc/cron.d/clean-expired-accounts "$BASE_URL/service/cron/clean-expired-accounts" || log_error "Failed to download clean-expired-accounts."
    service cron restart > /dev/null 2>&1
    log_success "Cron jobs set up."
}

# Final cleanup and setup
final_cleanup() {
    log_info "Final cleanup..."
    chown -R www-data:www-data /home/vps/public_html
    history -c && echo "unset HISTFILE" >> /etc/profile
    
    for link in autoscriptx asx; do
      ln -sf /usr/bin/menu /usr/bin/$link
      chmod +x /usr/bin/$link
    done
    log_success "Final cleanup done."
}

# Orchestrator
main() {
    check_root
    setup_hosts
    setup_domain
    update_system
    install_packages
    configure_squid
    install_gum
    disable_ipv6
    configure_dropbear
    setup_websocket_service
    setup_ssl_cert
    
    install_xray      # PAYLOAD INJECTION
    configure_xray    # PAYLOAD INJECTION
    
    configure_nginx   # Patched IPv6 bind crash
    setup_badvpn
    configure_stunnel
    configure_sshguard
    apply_firewall_rules
    install_scripts
    setup_cron_jobs
    final_cleanup
    
    log_success "Installation complete. Hybrid Base established."
    log_success "Run '${green}autoscriptx${nc}' or '${green}asx${nc}' to manage SSH & Xray."
}

main "$@"
