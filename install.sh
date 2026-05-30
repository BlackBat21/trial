#!/bin/bash
# =============================================================================
# AutoScriptX Hybrid — FreeNetLabs Base + Elite Xray Payload
# Version : 4.1.0 (xHTTP Port-80 Non-TLS + Non-Destructive Update Engine)
# Fully Patched & Hardened Release
# =============================================================================

# Color definitions
green="\033[0;32m"
blue="\033[0;34m"
red="\033[0;31m"
yellow="\033[1;33m"
nc="\033[0m"

# Configuration
BASE_URL="https://raw.githubusercontent.com/ayanrajpoot10/AutoScriptX/master"
SELF_UPDATE_URL="https://raw.githubusercontent.com/BlackBat21/trial/main/install.sh"
export DEBIAN_FRONTEND=noninteractive

# Xray Payload Constants
readonly XRAY_DIR="/usr/local/etc/xray"
readonly CSV_DB="${XRAY_DIR}/users.csv"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly PORT_VLESS_WS=10001
readonly PORT_VMESS_WS=10002
readonly PORT_TROJAN_WS=10003
readonly PORT_VLESS_XHTTP=10004
readonly PORT_VMESS_XHTTP=10005
readonly PORT_XRAY_API=10085

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
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Run as root."
        exit 1
    fi
}

# Setup hostname and hosts file
setup_hosts() {
    log_info "Setting up hostname and hosts file..."
    localip=$(hostname -I | cut -d ' ' -f1)
    public_ip=$(curl -s -H "User-Agent: AutoScriptX-Deployment" --max-time 5 https://api.ipify.org || curl -s -H "User-Agent: AutoScriptX-Deployment" --max-time 5 ifconfig.me)
    hostname=$(hostname)
    domain_from_etc=$(grep -w "$hostname" /etc/hosts | awk '{print $2}')
    [ "$hostname" != "$domain_from_etc" ] && echo "$localip $hostname" >> /etc/hosts
    log_success "Hostname and hosts file configured."
}

# Setup domain configuration
setup_domain() {
    mkdir -p /etc/AutoScriptX
    clear
    echo "---------------------------"
    echo "      VPS DOMAIN SETUP     "
    echo "---------------------------"
    domain=""
    if [ -t 0 ]; then
        read -rp "Enter Your Domain (leave blank for IP): " domain
    else
        read -rp "Enter Your Domain (leave blank for IP): " domain </dev/tty || true
    fi
    domain=$(echo "$domain" | tr -d ' ')
    clear
    if [[ -z "$domain" ]]; then
        domain="${public_ip:-$localip}"
        log_info "No domain entered. Using IP: $domain"
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
    apt-get purge -y ufw firewalld exim4 samba* apache2* bind9* sendmail* unscd > /dev/null 2>&1 || log_warning "Some packages could not be purged."
    apt autoremove -y > /dev/null 2>&1 && apt autoclean -y > /dev/null 2>&1
    log_success "System updated."
}

# Install required packages
install_packages() {
    log_info "Installing packages..."
    apt install -y \
      netfilter-persistent iptables-persistent screen curl jq bzip2 gzip vnstat coreutils rsyslog \
      zip unzip net-tools nano lsof shc gnupg dos2unix dirmngr bc \
      stunnel4 nginx dropbear socat xz-utils fail2ban squid > /dev/null 2>&1
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
    echo "net.ipv6.conf.all.disable_ipv6 = 1"     >> /etc/sysctl.d/99-disable-ipv6.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.d/99-disable-ipv6.conf
    sysctl --system > /dev/null 2>&1 || log_warning "Failed to reload sysctl settings."
    log_success "IPv6 disabled."
}

# Configure Dropbear SSH
configure_dropbear() {
    log_info "Configuring Dropbear..."
    wget -qO /etc/default/dropbear "$BASE_URL/config/dropbear.conf" || log_error "Failed to download dropbear.conf."
    chmod 644 /etc/default/dropbear
    wget -qO /etc/AutoScriptX/banner "$BASE_URL/config/banner.conf" || log_warning "Failed to download Dropbear banner."
    chmod 644 /etc/AutoScriptX/banner
    echo -e "/bin/false\n/usr/sbin/nologin" >> /etc/shells
    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable dropbear > /dev/null 2>&1
    systemctl restart dropbear > /dev/null 2>&1 || log_warning "Failed to restart Dropbear."
    log_success "Dropbear configured."
}

# Setup WebSocket service
setup_websocket_service() {
    log_info "Setting up SSH-WebSocket service..."
    systemctl stop ws-proxy.service > /dev/null 2>&1 || true
    rm -f /usr/local/bin/ws-proxy
    wget -qO /usr/local/bin/ws-proxy "$BASE_URL/bin/ws-proxy" && chmod +x /usr/local/bin/ws-proxy || log_warning "Failed to install websocket proxy."
    wget -qO /etc/systemd/system/ws-proxy.service "$BASE_URL/service/systemd/ws-proxy.service" && chmod +x /etc/systemd/system/ws-proxy.service || log_warning "Failed to install websocket proxy service."
    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable ws-proxy.service > /dev/null 2>&1
    systemctl restart ws-proxy.service > /dev/null 2>&1 || log_warning "Failed to restart ws-proxy.service."
    log_success "SSH-WebSocket service set up."
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
    /root/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 > /dev/null 2>&1 || log_warning "acme.sh certificate issue failed."
    /root/.acme.sh/acme.sh --installcert -d "$domain" --fullchainpath /etc/AutoScriptX/cert.crt --keypath /etc/AutoScriptX/cert.key --ecc > /dev/null 2>&1 || log_warning "acme.sh certificate install failed."

    if [[ ! -s /etc/AutoScriptX/cert.crt || ! -s /etc/AutoScriptX/cert.key ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/AutoScriptX/cert.key \
            -out  /etc/AutoScriptX/cert.crt \
            -subj "/CN=${domain}" > /dev/null 2>&1
    fi
    log_success "SSL cert installed."
}

# Inject Native Xray-core with User-Agent hardened API checks
install_xray() {
    log_info "Installing Xray-core..."
    local latest_tag
    latest_tag=$(curl -fsSL -H "User-Agent: AutoScriptX-Deployment" --max-time 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | jq -r '.tag_name // empty' 2>/dev/null)
    [[ -z "$latest_tag" || "$latest_tag" == "null" ]] && latest_tag="v1.8.24"
    local arch
    case "$(uname -m)" in
        x86_64)  arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        *)       log_error "Unsupported arch"; exit 1 ;;
    esac
    local tmp_dir
    tmp_dir=$(mktemp -d)
    wget -q -O "${tmp_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${arch}.zip"
    unzip -qo "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray"
    mkdir -p "${XRAY_DIR}/conf"
    install -m 755 "${tmp_dir}/xray/xray" "$XRAY_BIN"
    cp "${tmp_dir}/xray/"*.dat "/usr/local/bin/" 2>/dev/null || true
    rm -rf "$tmp_dir"
    log_success "Xray-core ${latest_tag} installed."
}

# Configure Xray Config with aligned xHTTP Host fields
configure_xray() {
    log_info "Configuring Xray-core..."
    local uuid_vless uuid_vmess trojan_pass
    uuid_vless=$(cat /proc/sys/kernel/random/uuid)
    uuid_vmess=$(cat /proc/sys/kernel/random/uuid)
    trojan_pass=$(openssl rand -hex 20)
    cat > "${XRAY_DIR}/credentials.env" << EOF
VLESS_UUID="${uuid_vless}"
VMESS_UUID="${uuid_vmess}"
TROJAN_PASS="${trojan_pass}"
DOMAIN="${domain}"
EOF
    echo "Username,SSHPassword,XrayUUID,TrojanPassword,ExpiryDate,LimitGB,UsedBytes" > "$CSV_DB"
    chmod 600 "${XRAY_DIR}/credentials.env" "$CSV_DB"

    cat > "${XRAY_DIR}/config.json" << XRAY_JSON
{
  "log": { "loglevel": "warning" },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink":   true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink":   true,
      "statsInboundDownlink": true
    }
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["api"],           "outboundTag": "direct"  },
      { "type": "field", "protocol":  ["bittorrent"],     "outboundTag": "blocked" }
    ]
  },
  "inbounds": [
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": ${PORT_XRAY_API},
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": ${PORT_VLESS_WS},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid_vless}", "flow": "", "email": "admin_vless" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless-ws" }
      }
    },
    {
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "port": ${PORT_VMESS_WS},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${uuid_vmess}", "alterId": 0, "email": "admin_vmess" }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess-ws" }
      }
    },
    {
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "port": ${PORT_TROJAN_WS},
      "protocol": "trojan",
      "settings": {
        "clients": [{ "password": "${trojan_pass}", "email": "admin_trojan" }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/trojan-ws" }
      }
    },
    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": ${PORT_VLESS_XHTTP},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid_vless}", "flow": "", "email": "admin_vless" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/vless-xhttp",
          "host": "${domain}"
        }
      }
    },
    {
      "tag": "vmess-xhttp",
      "listen": "127.0.0.1",
      "port": ${PORT_VMESS_XHTTP},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${uuid_vmess}", "alterId": 0, "email": "admin_vmess" }]
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/vmess-xhttp",
          "host": "${domain}"
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct",  "protocol": "freedom"  },
    { "tag": "blocked", "protocol": "blackhole" }
  ]
}
XRAY_JSON

    if ! jq empty "${XRAY_DIR}/config.json" > /dev/null 2>&1; then
        log_error "config.json failed JSON validation — aborting Xray setup."
        exit 1
    fi
    log_success "config.json passed JSON validation."
    cat > /etc/systemd/system/xray.service << 'SERVICE'
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

    systemctl daemon-reload  > /dev/null 2>&1
    systemctl enable xray    > /dev/null 2>&1
    systemctl restart xray   > /dev/null 2>&1
    log_success "Xray-core configured (WS + xHTTP inbounds active)."
}

# Configure Nginx Locations
configure_nginx() {
    log_info "Setting up Nginx..."
    rm -f /etc/nginx/{sites-available/default,sites-enabled/default,conf.d/default.conf}
    mkdir -p /home/vps/public_html
    mkdir -p /etc/systemd/system/nginx.service.d

    cat > /etc/nginx/xray-locations.conf << 'NGINXLOC'
# ── WebSocket (TLS) ──────────────────────────────────────────────────────────
location /vless-ws {
    proxy_pass         http://127.0.0.1:10001;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection "upgrade";
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
}
location /vmess-ws {
    proxy_pass         http://127.0.0.1:10002;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection "upgrade";
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
}
location /trojan-ws {
    proxy_pass         http://127.0.0.1:10003;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection "upgrade";
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
}
# ── xHTTP (TLS + Plain) ──────────────────────────────────────────────────────
location /vless-xhttp {
    proxy_pass                 http://127.0.0.1:10004;
    proxy_http_version         1.1;
    proxy_set_header           Host              $host;
    proxy_set_header           X-Real-IP         $remote_addr;
    proxy_set_header           X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_buffering            off;
    proxy_cache                off;
    proxy_request_buffering    off;
    proxy_read_timeout         86400s;
    client_max_body_size       0;
}
location /vmess-xhttp {
    proxy_pass                 http://127.0.0.1:10005;
    proxy_http_version         1.1;
    proxy_set_header           Host              $host;
    proxy_set_header           X-Real-IP         $remote_addr;
    proxy_set_header           X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_buffering            off;
    proxy_cache                off;
    proxy_request_buffering    off;
    proxy_read_timeout         86400s;
    client_max_body_size       0;
}
NGINXLOC

    cat > /etc/nginx/conf.d/xhttp-port80.conf << EOF
# =============================================================================
# AutoScriptX — xHTTP Plain Transport (Port 80, Non-TLS)
# Generated by install.sh v4.1.0  |
DO NOT EDIT MANUALLY
# =============================================================================
server {
    listen      80;
    server_name ${domain};
# ── xHTTP VLESS (no TLS) ─────────────────────────────────────────────────
    location /vless-xhttp {
        proxy_pass                 http://127.0.0.1:${PORT_VLESS_XHTTP};
        proxy_http_version         1.1;
        proxy_set_header           Host              \$host;
        proxy_set_header           X-Real-IP         \$remote_addr;
        proxy_set_header           X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_buffering            off;
        proxy_cache                off;
        proxy_request_buffering    off;
        proxy_read_timeout         86400s;
        client_max_body_size       0;
    }
    # ── xHTTP VMESS (no TLS) ─────────────────────────────────────────────────
    location /vmess-xhttp {
        proxy_pass                 http://127.0.0.1:${PORT_VMESS_XHTTP};
        proxy_http_version         1.1;
        proxy_set_header           Host              \$host;
        proxy_set_header           X-Real-IP         \$remote_addr;
        proxy_set_header           X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_buffering            off;
        proxy_cache                off;
        proxy_request_buffering    off;
        proxy_read_timeout         86400s;
        client_max_body_size       0;
    }
    # Fallback: block all other plain-HTTP requests
    location / {
        return 444;
    }
}
EOF

    local files=(
        "nginx.conf:/etc/nginx/nginx.conf"
        "reverse-proxy.conf:/etc/nginx/conf.d/reverse-proxy.conf"
        "real_ip_sources.conf:/etc/nginx/conf.d/real_ip_sources.conf"
    )
    for f in "${files[@]}"; do
        local name path
        name="${f%%:*}"
        path="${f##*:}"
        wget -qO "$path" "$BASE_URL/config/$name" || log_error "Failed to download $name."
        sed -i '/listen \[::\]/d' "$path"
        if [[ "$name" == "reverse-proxy.conf" ]]; then
            sed -i "s/server_name _;/server_name ${domain};/" "$path"
            sed -i 's|location / {|include /etc/nginx/xray-locations.conf;\n    location / {|g' "$path"
        fi
    done

    nginx -t > /dev/null 2>&1 || log_warning "Nginx config test failed — check /etc/nginx/ manually."
    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable nginx  > /dev/null 2>&1
    systemctl restart nginx > /dev/null 2>&1 || log_error "Failed to restart Nginx."
    log_success "Nginx set up (WS TLS-443 + xHTTP TLS-443 + xHTTP Plain-80)."
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
    openssl req -x509 -nodes -days 1095 -newkey rsa:2048 \
        -keyout /etc/stunnel/key.pem \
        -out    /etc/stunnel/cert.pem \
        -subj "/C=IN/ST=Maharashtra/L=Mumbai/O=none/OU=none/CN=none/emailAddress=none" \
        > /dev/null 2>&1 || log_error "Failed to generate stunnel certificate."
    cat /etc/stunnel/{key.pem,cert.pem} > /etc/stunnel/stunnel.pem
    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4
    systemctl enable stunnel4 > /dev/null 2>&1
    systemctl restart stunnel4 > /dev/null 2>&1 || log_warning "Failed to restart stunnel4."
    log_success "Stunnel configured."
}

# Configure SSHGuard
configure_fail2ban() {
    log_info "Configuring fail2ban..."

    # ── Write jail.local ──────────────────────────────────────────────────────
    cat > /etc/fail2ban/jail.local << 'F2B_JAIL'
[DEFAULT]
# ── CDN / trusted range whitelist ────────────────────────────────────────────
# Prevents Cloudflare, CloudFront, and Fastly edge nodes from being banned
# when their probes or health-checks produce auth/log noise.
ignoreip = 127.0.0.1/8 ::1
           # Cloudflare
           103.21.244.0/22
           103.22.200.0/22
           103.31.4.0/22
           104.16.0.0/13
           104.24.0.0/14
           108.162.192.0/18
           131.0.72.0/22
           141.101.64.0/18
           162.158.0.0/15
           172.64.0.0/13
           173.245.48.0/20
           188.114.96.0/20
           190.93.240.0/20
           197.234.240.0/22
           198.41.128.0/17
           # Fastly
           151.101.0.0/16
           199.232.0.0/16
           23.235.32.0/20
           23.235.39.0/24
           185.31.16.0/22
           199.27.72.0/21
           # CloudFront (major ranges)
           13.32.0.0/15
           13.35.0.0/16
           52.84.0.0/15
           54.182.0.0/16
           54.192.0.0/16
           54.230.0.0/16
           54.239.128.0/18
           54.239.192.0/19
           99.84.0.0/16
           204.246.164.0/22
           204.246.168.0/22
           204.246.174.0/23
           204.246.176.0/20
           205.251.192.0/19

bantime   = 1h
findtime  = 10m
maxretry  = 5
backend   = auto
banaction = iptables-multiport

# ── SSH ───────────────────────────────────────────────────────────────────────
[sshd]
enabled  = true
port     = ssh,22,443
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 2h

# ── Nginx auth failures ───────────────────────────────────────────────────────
[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
maxretry = 5

# ── Nginx bot scanning ────────────────────────────────────────────────────────
[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 2
bantime  = 2h

# ── Nginx 4xx flood (too many bad requests) ───────────────────────────────────
[nginx-limit-req]
enabled  = true
port     = http,https
filter   = nginx-limit-req
logpath  = /var/log/nginx/error.log
maxretry = 10
bantime  = 30m
F2B_JAIL

    # ── Write custom Xray auth filter ────────────────────────────────────────
    cat > /etc/fail2ban/filter.d/xray-auth.conf << 'F2B_XRAY'
[Definition]
# Matches Xray rejection messages in its log (if loglevel = warning or info)
failregex = .*rejected.*<HOST>.*
            .*failed.*<HOST>.*
ignoreregex =
F2B_XRAY

    # ── Add Xray jail only if Xray log exists ────────────────────────────────
    if [[ -f /var/log/xray/access.log ]]; then
        cat >> /etc/fail2ban/jail.local << 'F2B_XRAY_JAIL'

# ── Xray auth failures ────────────────────────────────────────────────────────
[xray-auth]
enabled  = true
port     = 443,80
filter   = xray-auth
logpath  = /var/log/xray/access.log
maxretry = 5
bantime  = 1h
F2B_XRAY_JAIL
    fi

    systemctl enable fail2ban  > /dev/null 2>&1
    systemctl restart fail2ban > /dev/null 2>&1 || log_warning "Failed to restart fail2ban."
    log_success "fail2ban configured (SSH + Nginx jails active, CDN ranges whitelisted)."
}

# Apply firewall rules safely with pre-execution sanitization
apply_firewall_rules() {
    log_info "Applying firewall rules..."

    # --- HYBRID LIMITER: Initialize Global Accounting Chain ---
    iptables -N ACCT_OUT 2>/dev/null || true
    iptables -C OUTPUT -j ACCT_OUT 2>/dev/null || iptables -I OUTPUT 1 -j ACCT_OUT
    # ----------------------------------------------------------

    local iptables_rules=(
        "get_peers" "announce_peer" "find_node" "BitTorrent"
        "BitTorrent protocol" "peer_id=" ".torrent"
        "announce.php?passkey=" "torrent" "announce" "info_hash"
    )
    for s in "${iptables_rules[@]}"; do
        iptables -D FORWARD -m string --string "$s" --algo bm -j DROP >/dev/null 2>&1 || true
        iptables -A FORWARD -m string --string "$s" --algo bm -j DROP
    done
    iptables-save > /etc/iptables.up.rules
    netfilter-persistent save   > /dev/null 2>&1
    netfilter-persistent reload > /dev/null 2>&1

    iptables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 443 -j ACCEPT

    # Idempotent rules.v4 writes — each port checked before appending,
    # regardless of whether dport 22 was already present in the file.
    local -A rv4_ports=(
        [22]="22"
        [80]="80"
        [443]="443"
        [8080]="8080"
    )
    for port in 22 80 443 8080; do
        grep -qE "\-\-dport ${port}[^0-9]" /etc/iptables/rules.v4 2>/dev/null || \
            echo "-A INPUT -p tcp -m state --state NEW -m tcp --dport ${port} -j ACCEPT" \
            >> /etc/iptables/rules.v4
    done
    netfilter-persistent save > /dev/null 2>&1 || log_warning "Failed to save iptables rules."
    log_success "Firewall rules applied."
}

# Non-destructive update engine
update_script() {
    log_info "Starting non-destructive AutoScriptX update..."
    local -a PROTECTED=(
        "${XRAY_DIR}/users.csv"
        "${XRAY_DIR}/config.json"
        "${XRAY_DIR}/credentials.env"
        "/etc/AutoScriptX/cert.crt"
        "/etc/AutoScriptX/cert.key"
        "/etc/AutoScriptX/domain"
    )
    local snap_dir
    snap_dir=$(mktemp -d /tmp/autoscriptx_snap_XXXXXX)
    log_info "Snapshotting protected files → ${snap_dir}"
    for p in "${PROTECTED[@]}"; do
        if [[ -f "$p" ]]; then
            cp -p "$p" "${snap_dir}/$(basename "$p")"
            log_info "  Snapshotted: $p"
        else
            log_warning "  Protected file not found (will not be restored): $p"
        fi
    done

    log_info "Re-downloading helper scripts..."
    declare -A script_dirs=(
        [menu]="menu.sh slowdns-menu.sh"
        [ssh]="create-account.sh delete-account.sh edit-banner.sh edit-response.sh lock-unlock.sh renew-account.sh"
        [system]="change-domain.sh manage-services.sh system-info.sh clean-expired-accounts.sh setup-slowdns.sh slowdns-status.sh"
    )
    for dir in "${!script_dirs[@]}"; do
        for s in ${script_dirs[$dir]}; do
            local base="${s%.sh}"
            wget -qO "/usr/bin/${base}" "$BASE_URL/scripts/$dir/$s" > /dev/null 2>&1 || log_warning "  Failed to update $s."
            chmod +x "/usr/bin/${base}"
        done
    done

    # Patch manage-services if upstream download succeeded
    if [[ -s /usr/bin/manage-services ]]; then
        sed -i 's/x-ui\.service/xray.service/g' /usr/bin/manage-services
        sed -i 's/x-ui/xray/g'                  /usr/bin/manage-services
        sed -i 's/X-UI/Xray/g'                  /usr/bin/manage-services
        sed -i 's/XUI Watcher/Xray Watcher/g'   /usr/bin/manage-services
        sed -i 's/XUI/Xray/g'                   /usr/bin/manage-services
    fi

    log_info "Rebuilding /usr/bin/menu (unified main menu)..."
    _write_main_menu
    rm -f /usr/bin/xray-menu   # remove legacy binary if present
    log_success "Main menu updated."
    log_info "Rebuilding bandwidth limit monitor..."
    _write_limit_monitor
    log_success "Limit monitor updated."
    log_info "Refreshing nginx xray-locations.conf..."
    cat > /etc/nginx/xray-locations.conf << 'NGINXLOC'
# ── WebSocket (TLS) ──────────────────────────────────────────────────────────
location /vless-ws {
    proxy_pass         http://127.0.0.1:10001;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection "upgrade";
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
}
location /vmess-ws {
    proxy_pass         http://127.0.0.1:10002;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection "upgrade";
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
}
location /trojan-ws {
    proxy_pass         http://127.0.0.1:10003;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection "upgrade";
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
}
# ── xHTTP (TLS + Plain) ──────────────────────────────────────────────────────
location /vless-xhttp {
    proxy_pass                 http://127.0.0.1:10004;
    proxy_http_version         1.1;
    proxy_set_header           Host              $host;
    proxy_set_header           X-Real-IP         $remote_addr;
    proxy_set_header           X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_buffering            off;
    proxy_cache                off;
    proxy_request_buffering    off;
    proxy_read_timeout         86400s;
    client_max_body_size       0;
}
location /vmess-xhttp {
    proxy_pass                 http://127.0.0.1:10005;
    proxy_http_version         1.1;
    proxy_set_header           Host              $host;
    proxy_set_header           X-Real-IP         $remote_addr;
    proxy_set_header           X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_buffering            off;
    proxy_cache                off;
    proxy_request_buffering    off;
    proxy_read_timeout         86400s;
    client_max_body_size       0;
}
NGINXLOC

    local cur_domain
    cur_domain=$(cat /etc/AutoScriptX/domain 2>/dev/null || echo "localhost")
    log_info "Refreshing xhttp-port80.conf for domain: ${cur_domain}"
    cat > /etc/nginx/conf.d/xhttp-port80.conf << EOF
# =============================================================================
# AutoScriptX — xHTTP Plain Transport (Port 80, Non-TLS)
# Updated by update_script  |
DO NOT EDIT MANUALLY
# =============================================================================
server {
    listen      80;
    server_name ${cur_domain};
    location /vless-xhttp {
        proxy_pass                 http://127.0.0.1:${PORT_VLESS_XHTTP};
        proxy_http_version         1.1;
        proxy_set_header           Host              \$host;
        proxy_set_header           X-Real-IP         \$remote_addr;
        proxy_set_header           X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_buffering            off;
        proxy_cache                off;
        proxy_request_buffering    off;
        proxy_read_timeout         86400s;
        client_max_body_size       0;
    }
    location /vmess-xhttp {
        proxy_pass                 http://127.0.0.1:${PORT_VMESS_XHTTP};
        proxy_http_version         1.1;
        proxy_set_header           Host              \$host;
        proxy_set_header           X-Real-IP         \$remote_addr;
        proxy_set_header           X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_buffering            off;
        proxy_cache                off;
        proxy_request_buffering    off;
        proxy_read_timeout         86400s;
        client_max_body_size       0;
    }
    location / {
        return 444;
    }
}
EOF

    if [[ -f "${XRAY_DIR}/config.json" ]]; then
        local ex_vless_uuid ex_vmess_uuid
        ex_vless_uuid=$(jq -r '.inbounds[] | select(.tag == "vless-ws") | .settings.clients[0].id // empty' "${XRAY_DIR}/config.json" 2>/dev/null)
        ex_vmess_uuid=$(jq -r '.inbounds[] | select(.tag == "vmess-ws") | .settings.clients[0].id // empty' "${XRAY_DIR}/config.json" 2>/dev/null)

        if [[ -n "$ex_vless_uuid" ]] && ! jq -e '.inbounds[] | select(.tag == "vless-xhttp")' "${XRAY_DIR}/config.json" > /dev/null 2>&1; then
            log_info "Appending vless-xhttp inbound to config.json..."
            jq --arg uuid  "$ex_vless_uuid" \
               --arg domain "$cur_domain" \
               --argjson port "${PORT_VLESS_XHTTP}" \
               '.inbounds += [{
                 "tag": "vless-xhttp",
                 "listen": "127.0.0.1",
                 "port": $port,
                 "protocol": "vless",
                 "settings": {
                   "clients": [{"id": $uuid, "flow": "", "email": "admin_vless"}],
                   "decryption": "none"
                 },
                 "streamSettings": {
                   "network": "xhttp",
                   "xhttpSettings": {"path": "/vless-xhttp", "host": $domain}
                 }
               }]' "${XRAY_DIR}/config.json" > /tmp/xray_patch.json \
            && mv /tmp/xray_patch.json "${XRAY_DIR}/config.json" \
            && log_success "  vless-xhttp inbound added." || log_warning "  Failed to patch vless-xhttp inbound."
        else
            log_info "  vless-xhttp inbound already present — skipping."
        fi

        if [[ -n "$ex_vmess_uuid" ]] && ! jq -e '.inbounds[] | select(.tag == "vmess-xhttp")' "${XRAY_DIR}/config.json" > /dev/null 2>&1; then
            log_info "Appending vmess-xhttp inbound to config.json..."
            jq --arg uuid  "$ex_vmess_uuid" \
               --arg domain "$cur_domain" \
               --argjson port "${PORT_VMESS_XHTTP}" \
               '.inbounds += [{
                 "tag": "vmess-xhttp",
                 "listen": "127.0.0.1",
                 "port": $port,
                 "protocol": "vmess",
                 "settings": {
                   "clients": [{"id": $uuid, "alterId": 0, "email": "admin_vmess"}]
                 },
                 "streamSettings": {
                   "network": "xhttp",
                   "xhttpSettings": {"path": "/vmess-xhttp", "host": $domain}
                 }
               }]' "${XRAY_DIR}/config.json" > /tmp/xray_patch.json \
            && mv /tmp/xray_patch.json "${XRAY_DIR}/config.json" \
            && log_success "  vmess-xhttp inbound added." || log_warning "  Failed to patch vmess-xhttp inbound."
        else
            log_info "  vmess-xhttp inbound already present — skipping."
        fi
        chmod 600 "${XRAY_DIR}/config.json"
    else
        log_warning "config.json not found — skipping Xray inbound patch."
    fi

    log_info "Restoring all protected files from snapshot..."
    for p in "${PROTECTED[@]}"; do
        local fname
        fname=$(basename "$p")
        if [[ -f "${snap_dir}/${fname}" ]]; then
            cp -p "${snap_dir}/${fname}" "$p"
            log_success "  Restored: $p"
        fi
    done

    # ── Additive config.json migration (runs AFTER restore to preserve UUIDs) ─
    # Adds stats/api/policy blocks and API inbound if missing from existing config.
    # This is safe — it only adds new keys, never modifies existing client entries.
    if [[ -f "${XRAY_DIR}/config.json" ]]; then
        local cfg="${XRAY_DIR}/config.json"

        if ! jq -e '.stats' "$cfg" > /dev/null 2>&1; then
            log_info "  Migrating config.json: adding stats block..."
            jq '. + {"stats":{}}' "$cfg" > /tmp/xp.json && mv /tmp/xp.json "$cfg"
        fi

        if ! jq -e '.api' "$cfg" > /dev/null 2>&1; then
            log_info "  Migrating config.json: adding api block..."
            jq '. + {"api":{"tag":"api","services":["StatsService"]}}' \
                "$cfg" > /tmp/xp.json && mv /tmp/xp.json "$cfg"
        fi

        if ! jq -e '.policy' "$cfg" > /dev/null 2>&1; then
            log_info "  Migrating config.json: adding policy block..."
            jq '. + {"policy":{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}},"system":{"statsInboundUplink":true,"statsInboundDownlink":true}}}' \
                "$cfg" > /tmp/xp.json && mv /tmp/xp.json "$cfg"
        fi

        if ! jq -e '.inbounds[] | select(.tag == "api")' "$cfg" > /dev/null 2>&1; then
            log_info "  Migrating config.json: adding API inbound (port 10085)..."
            jq '.inbounds = [{"tag":"api","listen":"127.0.0.1","port":10085,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}}] + .inbounds' \
                "$cfg" > /tmp/xp.json && mv /tmp/xp.json "$cfg"
        fi

        if ! jq -e '.routing.rules[] | select(.inboundTag and (.inboundTag | contains(["api"])))' \
                "$cfg" > /dev/null 2>&1; then
            log_info "  Migrating config.json: adding API routing rule..."
            jq '.routing.rules = [{"type":"field","inboundTag":["api"],"outboundTag":"direct"}] + .routing.rules' \
                "$cfg" > /tmp/xp.json && mv /tmp/xp.json "$cfg"
        fi

        chmod 600 "$cfg"
        log_success "  config.json stats API migration complete."
    fi

    log_info "Reloading Xray and Nginx..."
    systemctl restart xray  > /dev/null 2>&1 && log_success "Xray restarted." || log_warning "Xray restart failed."
    nginx -t > /dev/null 2>&1 && systemctl reload nginx > /dev/null 2>&1 && log_success "Nginx reloaded." || log_warning "Nginx config test failed — nginx NOT reloaded."
    rm -rf "$snap_dir"
    log_success "═══════════════════════════════════════════════════"
    log_success " Update complete.  Version 4.2.0"
    log_success " Users, UUIDs, certs, and domain: UNTOUCHED."
    log_success "═══════════════════════════════════════════════════"
    read -p "Press Enter to return..."
}

# Shared helper writing /usr/bin/menu (unified main menu)
# ─── _write_main_menu ─────────────────────────────────────────────────────────
# Writes /usr/bin/menu as a single self-contained script covering account
# management (SSH + all Xray protocols), service control, and system tools.
# Called from both install_scripts (fresh install) and update_script (update).
# Single-quoted heredoc — variables expand at runtime when menu executes.
# ─────────────────────────────────────────────────────────────────────────────
_write_main_menu() {
    cat > /usr/bin/menu << 'MAINMENU'
#!/bin/bash
# =============================================================================
# AutoScriptX — Unified Main Menu  v4.2.0
# =============================================================================
CSV_DB="/usr/local/etc/xray/users.csv"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_API="127.0.0.1:10085"
XRAY_BIN="/usr/local/bin/xray"

green="\033[0;32m"
blue="\033[0;34m"
yellow="\033[1;33m"
red="\033[0;31m"
cyan="\033[0;36m"
nc="\033[0m"

# ── Header ────────────────────────────────────────────────────────────────────
show_header() {
    clear
    local domain xray_ver uptime_str
    domain=$(cat /etc/AutoScriptX/domain 2>/dev/null || echo "not set")
    xray_ver=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}' || echo "?")
    uptime_str=$(uptime -p 2>/dev/null || echo "?")
    echo -e "${cyan}╔══════════════════════════════════════════════╗${nc}"
    echo -e "${cyan}║       AutoScriptX  v4.2.0  —  Main Menu     ║${nc}"
    echo -e "${cyan}╠══════════════════════════════════════════════╣${nc}"
    printf  "${cyan}║${nc}  Domain  : %-33s${cyan}║${nc}\n" "$domain"
    printf  "${cyan}║${nc}  Xray    : %-33s${cyan}║${nc}\n" "$xray_ver"
    printf  "${cyan}║${nc}  Uptime  : %-33s${cyan}║${nc}\n" "$uptime_str"
    echo -e "${cyan}╚══════════════════════════════════════════════╝${nc}"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Format bytes into human-readable string
fmt_bytes() {
    local b="${1:-0}"
    b=$(echo "$b" | tr -dc '0-9'); b=${b:-0}
    if   [[ $b -ge 1073741824 ]]; then printf "%.2f GB" "$(echo "scale=2; $b/1073741824" | bc)"
    elif [[ $b -ge 1048576    ]]; then printf "%.2f MB" "$(echo "scale=2; $b/1048576"    | bc)"
    elif [[ $b -ge 1024       ]]; then printf "%.2f KB" "$(echo "scale=2; $b/1024"       | bc)"
    else echo "${b} B"
    fi
}

# Migrate old 5-column CSV rows to 7-column format in place
migrate_csv() {
    local tmp; tmp=$(mktemp)
    while IFS=',' read -r f1 f2 f3 f4 f5 f6 f7; do
        if [[ "$f1" == "Username" ]]; then
            echo "Username,SSHPassword,XrayUUID,TrojanPassword,ExpiryDate,LimitGB,UsedBytes"
        else
            # If columns 6 or 7 are missing, default to 0
            f6=${f6:-0}; f7=${f7:-0}
            echo "${f1},${f2},${f3},${f4},${f5},${f6},${f7}"
        fi
    done < "$CSV_DB" > "$tmp"
    mv "$tmp" "$CSV_DB"
    chmod 600 "$CSV_DB"
}

# ── Create Account ────────────────────────────────────────────────────────────
create_account() {
    show_header
    local DOMAIN PUBLIC_IP
    DOMAIN=$(cat /etc/AutoScriptX/domain 2>/dev/null || echo "localhost")
    PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

    if command -v gum &>/dev/null; then
        echo -e "\n# 🧑 Create SSH Account\n"
        u_name=$(gum input --placeholder "username"  --prompt "🔵 Username: ")
        u_pass=$(gum input --placeholder "password"  --prompt "🔑 Password: ")
        days=$(gum input   --placeholder "30"        --prompt "📅 Expired (days): ")
        limit_gb=$(gum input --placeholder "0 = unlimited" --prompt "🌐 Limit (GB): ")
    else
        echo -e "${blue}── Create Account ──────────────────────────────────────${nc}\n"
        read -rp "  🔵 Username          : " u_name
        read -rp "  🔑 Password          : " u_pass
        read -rp "  📅 Expired (days)    : " days
        read -rp "  🌐 Limit GB (0=∞)    : " limit_gb
    fi

    [[ -z "$u_name"   ]] && { echo -e "${red}Username cannot be empty.${nc}"; sleep 2; return; }
    [[ -z "$u_pass"   ]] && u_pass=$(openssl rand -base64 10 | tr -d '/+=')
    days=${days:-30}
    limit_gb=$(echo "${limit_gb:-0}" | tr -dc '0-9'); limit_gb=${limit_gb:-0}

    local u_exp u_exp_fmt u_uuid u_trojan
    u_exp=$(date -d "+${days} days" +"%Y-%m-%d")
    u_exp_fmt=$(date -d "+${days} days" +"%B %d, %Y")
    u_uuid=$(cat /proc/sys/kernel/random/uuid)
    u_trojan=$(openssl rand -hex 20)

    if id "$u_name" &>/dev/null; then
        echo -e "${red}  User '$u_name' already exists.${nc}"
        read -p "  Press Enter to return..."; return
    fi
    useradd -M -s /bin/false -e "$u_exp" "$u_name"
    echo "${u_name}:${u_pass}" | chpasswd

    # --- HYBRID LIMITER: Add UID to Accounting ---
    local sys_uid
    sys_uid=$(id -u "$u_name" 2>/dev/null)
    if [[ -n "$sys_uid" ]]; then
        iptables -C ACCT_OUT -m owner --uid-owner "$sys_uid" -j RETURN 2>/dev/null || \
        iptables -A ACCT_OUT -m owner --uid-owner "$sys_uid" -j RETURN
    fi
    # ---------------------------------------------

    jq --arg user "$u_name" --arg uuid "$u_uuid" --arg tpw "$u_trojan" '
      .inbounds |= map(
        if   .protocol == "vless"  and .settings.clients
          then .settings.clients += [{"id": $uuid, "flow": "", "email": $user}]
        elif .protocol == "vmess"  and .settings.clients
          then .settings.clients += [{"id": $uuid, "alterId": 0, "email": $user}]
        elif .protocol == "trojan" and .settings.clients
          then .settings.clients += [{"password": $tpw, "email": $user}]
        else . end
      )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
    systemctl restart xray > /dev/null 2>&1

    migrate_csv
    echo "${u_name},${u_pass},${u_uuid},${u_trojan},${u_exp},${limit_gb},0" >> "$CSV_DB"

    # Build vmess links
    local v_json v_b64 vxt_json vxt_b64 vx_json vx_b64
    v_json="{\"v\":\"2\",\"ps\":\"${u_name}-VMESS-WS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${u_uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-ws\",\"tls\":\"tls\"}"
    v_b64=$(echo -n "$v_json" | base64 -w0)
    vxt_json="{\"v\":\"2\",\"ps\":\"${u_name}-VMESS-XHTTP-TLS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${u_uuid}\",\"aid\":\"0\",\"net\":\"xhttp\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-xhttp\",\"tls\":\"tls\"}"
    vxt_b64=$(echo -n "$vxt_json" | base64 -w0)
    vx_json="{\"v\":\"2\",\"ps\":\"${u_name}-VMESS-XHTTP\",\"add\":\"${DOMAIN}\",\"port\":\"80\",\"id\":\"${u_uuid}\",\"aid\":\"0\",\"net\":\"xhttp\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-xhttp\",\"tls\":\"\"}"
    vx_b64=$(echo -n "$vx_json" | base64 -w0)

    local limit_display
    [[ "$limit_gb" -eq 0 ]] && limit_display="Unlimited" || limit_display="${limit_gb} GB"

    clear
    echo -e "# ✅ SSH Account Created\n"
    echo -e "🔵 ${yellow}Username${nc}    : ${green}${u_name}${nc}"
    echo -e "🔑 ${yellow}Password${nc}    : ${green}${u_pass}${nc}"
    echo -e "📅 ${yellow}Expires On${nc}  : ${green}${u_exp_fmt}${nc}"
    echo -e "🌐 ${yellow}Public IP${nc}   : ${green}${PUBLIC_IP}${nc}"
    echo -e "🐳 ${yellow}Host${nc}        : ${green}${DOMAIN}${nc}"
    echo -e "📊 ${yellow}BW Limit${nc}    : ${green}${limit_display}${nc}"

    echo -e "\n# 📦 Ports\n"
    echo -e "• SSH WS      : ${green}80${nc}"
    echo -e "• SSH SSL WS  : ${green}443${nc}"
    echo -e "• SSL/TLS     : ${green}443${nc}"
    echo -e "• SQUID       : ${green}8080${nc}"
    echo -e "• UDPGW       : ${green}7200,7300${nc}"

    echo -e "\n# ✏️  Payloads\n"
    echo -e "${yellow}WSS Payload${nc}\n"
    echo -e "   GET wss://example.com HTTP/1.1[crlf]"
    echo -e "   Host: ${DOMAIN}[crlf]"
    echo -e "   Upgrade: websocket[crlf][crlf]"
    echo -e "\n${yellow}WS Payload${nc}\n"
    echo -e "   GET / HTTP/1.1[crlf]"
    echo -e "   Host: ${DOMAIN}[crlf]"
    echo -e "   Upgrade: websocket[crlf][crlf]"

    echo -e "\n# 🔐 Xray Links\n"
    echo -e "${blue}── TLS WebSocket (Port 443) ─────────────────────────────${nc}"
    echo -e "${yellow}VLESS-WS:${nc}"
    echo "vless://${u_uuid}@${DOMAIN}:443?encryption=none&flow=none&type=ws&host=${DOMAIN}&path=%2Fvless-ws&security=tls&sni=${DOMAIN}#${u_name}-VLESS-WS"
    echo ""
    echo -e "${yellow}VMESS-WS:${nc}"
    echo "vmess://${v_b64}"
    echo ""
    echo -e "${yellow}TROJAN-WS:${nc}"
    echo "trojan://${u_trojan}@${DOMAIN}:443?type=ws&host=${DOMAIN}&path=%2Ftrojan-ws&security=tls&sni=${DOMAIN}#${u_name}-TROJAN-WS"
    echo -e "\n${blue}── TLS xHTTP (Port 443) ─────────────────────────────────${nc}"
    echo -e "${yellow}VLESS-xHTTP (TLS):${nc}"
    echo "vless://${u_uuid}@${DOMAIN}:443?encryption=none&type=xhttp&path=%2Fvless-xhttp&security=tls&sni=${DOMAIN}&host=${DOMAIN}#${u_name}-VLESS-XHTTP-TLS"
    echo ""
    echo -e "${yellow}VMESS-xHTTP (TLS):${nc}"
    echo "vmess://${vxt_b64}"
    echo -e "\n${blue}── Plain xHTTP (Port 80, no TLS) ────────────────────────${nc}"
    echo -e "${yellow}VLESS-xHTTP:${nc}"
    echo "vless://${u_uuid}@${DOMAIN}:80?encryption=none&type=xhttp&path=%2Fvless-xhttp&security=none&host=${DOMAIN}#${u_name}-VLESS-XHTTP"
    echo ""
    echo -e "${yellow}VMESS-xHTTP:${nc}"
    echo "vmess://${vx_b64}"
    echo ""

    if command -v gum &>/dev/null; then
        gum confirm "Return to menu?" && return || return
    else
        read -p "Press Enter to return..."
    fi
}

# ── Delete Account ────────────────────────────────────────────────────────────
delete_account() {
    show_header
    migrate_csv
    echo -e "${blue}── Delete Account ──────────────────────────────────────${nc}\n"
    if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1{found=1;exit} END{exit !found}' "$CSV_DB"; then
        echo -e "  ${yellow}No accounts found.${nc}"
        read -p "  Press Enter to return..."; return
    fi
    printf "  %-20s %-12s %-10s %-10s\n" "USERNAME" "EXPIRY" "LIMIT" "USED"
    printf "  %-20s %-12s %-10s %-10s\n" "────────────────────" "──────────" "──────────" "──────────"
    while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
        [[ "$name" == "Username" ]] && continue
        local lstr; [[ "${limit_gb:-0}" -eq 0 ]] && lstr="Unlimited" || lstr="${limit_gb}GB"
        printf "  %-20s %-12s %-10s %-10s\n" "$name" "$exp" "$lstr" "$(fmt_bytes "${used_bytes:-0}")"
    done < "$CSV_DB"
    echo ""
    read -rp "  Username to delete (Enter to cancel): " u_name
    [[ -z "$u_name" ]] && return
    if ! grep -q "^${u_name}," "$CSV_DB" 2>/dev/null; then
        echo -e "${red}  User '${u_name}' not found.${nc}"
        read -p "  Press Enter to return..."; return
    fi
    jq --arg user "$u_name" '
      .inbounds |= map(
        if .settings.clients
          then .settings.clients |= map(select(.email != $user))
        else . end
      )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
    systemctl restart xray > /dev/null 2>&1

    # --- HYBRID LIMITER: Remove UID from Accounting ---
    local sys_uid
    sys_uid=$(id -u "$u_name" 2>/dev/null)
    if [[ -n "$sys_uid" ]]; then
        iptables -D ACCT_OUT -m owner --uid-owner "$sys_uid" -j RETURN 2>/dev/null || true
    fi
    # --------------------------------------------------

    userdel -r "$u_name" 2>/dev/null || true
    sed -i "/^${u_name},/d" "$CSV_DB"
    echo -e "${green}  Account '${u_name}' deleted successfully.${nc}"
    read -p "  Press Enter to return..."
}

# ── List Accounts ─────────────────────────────────────────────────────────────
list_accounts() {
    show_header
    migrate_csv
    echo -e "${blue}── Active Accounts ─────────────────────────────────────${nc}\n"
    if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1{found=1;exit} END{exit !found}' "$CSV_DB"; then
        echo -e "  ${yellow}No accounts found.${nc}"
        read -p "  Press Enter to return..."; return
    fi
    local today; today=$(date +%Y-%m-%d)
    printf "  %-16s %-12s %-10s %-10s %-5s %-8s\n" "USERNAME" "EXPIRY" "USED" "LIMIT" "%" "STATUS"
    printf "  %-16s %-12s %-10s %-10s %-5s %-8s\n" "────────────────" "──────────" "──────────" "──────────" "─────" "──────────"
    while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
        [[ "$name" == "Username" ]] && continue
        limit_gb=${limit_gb:-0}; used_bytes=${used_bytes:-0}
        used_bytes=$(echo "$used_bytes" | tr -dc '0-9'); used_bytes=${used_bytes:-0}
        local lstr pct_str status_str
        if [[ "$limit_gb" -eq 0 ]]; then
            lstr="Unlimited"; pct_str="—"
        else
            lstr="${limit_gb} GB"
            local limit_bytes=$(( limit_gb * 1024 * 1024 * 1024 ))
            if [[ $limit_bytes -gt 0 ]]; then
                pct_str="$(( used_bytes * 100 / limit_bytes ))%"
            else
                pct_str="—"
            fi
        fi
        if [[ "$exp" < "$today" ]]; then
            status_str="${red}Expired${nc}"
        elif [[ "$limit_gb" -gt 0 ]] && [[ "$used_bytes" -ge $(( limit_gb * 1024 * 1024 * 1024 )) ]]; then
            status_str="${red}CAPPED${nc}"
        else
            status_str="${green}Active${nc}"
        fi
        printf "  %-16s %-12s %-10s %-10s %-5s " "$name" "$exp" "$(fmt_bytes "$used_bytes")" "$lstr" "$pct_str"
        echo -e "$status_str"
    done < "$CSV_DB"
    echo ""
    read -p "Press Enter to return..."
}

# ── Bandwidth Monitor ─────────────────────────────────────────────────────────
bandwidth_monitor() {
    while true; do
        show_header
        migrate_csv
        echo -e "${blue}── Bandwidth Monitor ───────────────────────────────────${nc}\n"

        if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1{found=1;exit} END{exit !found}' "$CSV_DB"; then
            echo -e "  ${yellow}No accounts found.${nc}"
            read -p "  Press Enter to return..."; return
        fi

        printf "  %-16s %-10s %-10s %-6s %-10s\n" "USERNAME" "USED" "LIMIT" "%" "STATUS"
        printf "  %-16s %-10s %-10s %-6s %-10s\n" "────────────────" "──────────" "──────────" "──────" "──────────"

        while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
            [[ "$name" == "Username" ]] && continue
            limit_gb=${limit_gb:-0}
            used_bytes=$(echo "${used_bytes:-0}" | tr -dc '0-9'); used_bytes=${used_bytes:-0}
            local lstr pct_str status_str
            if [[ "$limit_gb" -eq 0 ]]; then
                lstr="Unlimited"; pct_str="—"; status_str="${green}Active${nc}"
            else
                lstr="${limit_gb} GB"
                local lb=$(( limit_gb * 1024 * 1024 * 1024 ))
                local pct=0
                [[ $lb -gt 0 ]] && pct=$(( used_bytes * 100 / lb ))
                pct_str="${pct}%"
                if   [[ $used_bytes -ge $lb ]]; then status_str="${red}CAPPED${nc}"
                elif [[ $pct -ge 80            ]]; then status_str="${yellow}Warning${nc}"
                else                                    status_str="${green}Active${nc}"
                fi
            fi
            printf "  %-16s %-10s %-10s %-6s " "$name" "$(fmt_bytes "$used_bytes")" "$lstr" "$pct_str"
            echo -e "$status_str"
        done < "$CSV_DB"

        echo ""
        echo -e "  ${green}r)${nc} Reset usage for a user"
        echo -e "  ${green}s)${nc} Set/change limit for a user"
        echo -e "  ${green}0)${nc} Return to main menu"
        echo ""
        read -rp "  Select: " bw_opt
        case $bw_opt in
            r|R) _bw_reset_user     ;;
            s|S) _bw_set_limit      ;;
            0)   return             ;;
            *)   sleep 1            ;;
        esac
    done
}

_bw_reset_user() {
    read -rp "  Username to reset: " reset_user
    [[ -z "$reset_user" ]] && return
    if ! grep -q "^${reset_user}," "$CSV_DB" 2>/dev/null; then
        echo -e "${red}  User not found.${nc}"; sleep 2; return
    fi
    # Zero out UsedBytes in CSV
    local tmp; tmp=$(mktemp)
    awk -F',' -v u="$reset_user" 'BEGIN{OFS=","} NR>1&&$1==u{$7=0} {print}' "$CSV_DB" > "$tmp"
    mv "$tmp" "$CSV_DB"; chmod 600 "$CSV_DB"
    # Re-add user to Xray inbounds if they were capped
    local r_uuid r_trojan
    r_uuid=$(awk  -F',' -v u="$reset_user" 'NR>1&&$1==u{print $3}' "$CSV_DB")
    r_trojan=$(awk -F',' -v u="$reset_user" 'NR>1&&$1==u{print $4}' "$CSV_DB")
    local already_active
    already_active=$(jq -r --arg u "$reset_user" \
        '[.inbounds[].settings.clients[]? | select(.email==$u)] | length' \
        "$XRAY_CONF" 2>/dev/null)
    if [[ "${already_active:-0}" -eq 0 ]]; then
        jq --arg user "$reset_user" --arg uuid "$r_uuid" --arg tpw "$r_trojan" '
          .inbounds |= map(
            if   .protocol=="vless"  and .settings.clients
              then .settings.clients += [{"id":$uuid,"flow":"","email":$user}]
            elif .protocol=="vmess"  and .settings.clients
              then .settings.clients += [{"id":$uuid,"alterId":0,"email":$user}]
            elif .protocol=="trojan" and .settings.clients
              then .settings.clients += [{"password":$tpw,"email":$user}]
            else . end
          )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
        systemctl restart xray > /dev/null 2>&1
        passwd -u "$reset_user" > /dev/null 2>&1
    fi
    echo -e "${green}  Usage reset for '${reset_user}'. Account reactivated.${nc}"
    sleep 2
}

_bw_set_limit() {
    read -rp "  Username: " tgt_user
    [[ -z "$tgt_user" ]] && return
    if ! grep -q "^${tgt_user}," "$CSV_DB" 2>/dev/null; then
        echo -e "${red}  User not found.${nc}"; sleep 2; return
    fi
    read -rp "  New limit in GB (0 = unlimited): " new_limit
    new_limit=$(echo "${new_limit:-0}" | tr -dc '0-9'); new_limit=${new_limit:-0}
    local tmp; tmp=$(mktemp)
    awk -F',' -v u="$tgt_user" -v l="$new_limit" \
        'BEGIN{OFS=","} NR>1&&$1==u{$6=l} {print}' "$CSV_DB" > "$tmp"
    mv "$tmp" "$CSV_DB"; chmod 600 "$CSV_DB"
    echo -e "${green}  Limit for '${tgt_user}' set to ${new_limit} GB.${nc}"
    sleep 2
}

# ── Service Status ────────────────────────────────────────────────────────────
service_status() {
    show_header
    echo -e "${blue}── Service Status ──────────────────────────────────────${nc}\n"
    for svc in xray nginx dropbear stunnel4 squid fail2ban ws-proxy xray-limit-monitor; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${green}●${nc} $svc — running"
        else
            echo -e "  ${red}●${nc} $svc — stopped / not installed"
        fi
    done
    echo ""
    read -p "Press Enter to return..."
}

# ── Restart Services ──────────────────────────────────────────────────────────
restart_services() {
    show_header
    echo -e "${blue}Restarting services...${nc}\n"
    for svc in xray nginx dropbear stunnel4 squid fail2ban xray-limit-monitor; do
        systemctl restart "$svc" > /dev/null 2>&1 \
            && echo -e "  ${green}✔${nc} $svc restarted" \
            || echo -e "  ${yellow}✘${nc} $svc — could not restart"
    done
    echo ""
    read -p "Press Enter to return..."
}

# ── System Info ───────────────────────────────────────────────────────────────
system_info() {
    show_header
    echo -e "${blue}── System Info ─────────────────────────────────────────${nc}\n"
    echo -e "  OS      : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    echo -e "  Kernel  : $(uname -r)"
    echo -e "  CPU     : $(nproc) core(s)"
    echo -e "  RAM     : $(free -h | awk '/^Mem/{print $3 " used / " $2 " total"}')"
    echo -e "  Disk    : $(df -h / | awk 'NR==2{print $3 " used / " $2 " total (" $5 " full)"}')"
    echo -e "  IP      : $(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
    echo -e "  Domain  : $(cat /etc/AutoScriptX/domain 2>/dev/null || echo 'not set')"
    echo -e "  Uptime  : $(uptime -p 2>/dev/null)"
    echo ""
    read -p "Press Enter to return..."
}

# ── Change Domain ─────────────────────────────────────────────────────────────
change_domain() {
    show_header
    echo -e "${blue}── Change Domain ───────────────────────────────────────${nc}\n"
    echo -e "  ${yellow}Current:${nc} $(cat /etc/AutoScriptX/domain 2>/dev/null || echo 'not set')"
    echo ""
    read -rp "  New domain (Enter to cancel): " new_domain
    new_domain=$(echo "$new_domain" | tr -d ' ')
    if [[ -n "$new_domain" ]]; then
        echo "$new_domain" > /etc/AutoScriptX/domain
        sed -i "s/server_name .*;/server_name ${new_domain};/g" \
            /etc/nginx/conf.d/reverse-proxy.conf 2>/dev/null || true
        sed -i "s/server_name .*;/server_name ${new_domain};/g" \
            /etc/nginx/conf.d/xhttp-port80.conf  2>/dev/null || true
        systemctl reload nginx > /dev/null 2>&1 || true
        echo -e "\n  ${green}Domain updated to: ${new_domain}${nc}"
    else
        echo -e "  ${yellow}Cancelled.${nc}"
    fi
    read -p "  Press Enter to return..."
}

# ── Edit Banner ───────────────────────────────────────────────────────────────
edit_banner() {
    show_header
    local banner_file="/etc/AutoScriptX/banner"
    echo -e "${blue}── Edit SSH Banner ──────────────────────────────────────${nc}\n"
    echo -e "  ${yellow}Current banner:${nc}"
    echo -e "  ─────────────────────────────────────────────────────"
    cat "$banner_file" 2>/dev/null || echo -e "  ${yellow}(empty)${nc}"
    echo -e "  ─────────────────────────────────────────────────────\n"
    echo -e "  ${green}1)${nc} Edit with nano"
    echo -e "  ${green}2)${nc} Clear banner"
    echo -e "  ${green}0)${nc} Cancel"
    echo ""; read -rp "  Select: " choice
    case $choice in
        1) nano "$banner_file"
           systemctl restart dropbear > /dev/null 2>&1
           echo -e "\n  ${green}Banner updated.${nc}" ;;
        2) > "$banner_file"
           systemctl restart dropbear > /dev/null 2>&1
           echo -e "\n  ${green}Banner cleared.${nc}" ;;
        *) echo -e "  ${yellow}Cancelled.${nc}" ;;
    esac
    read -p "  Press Enter to return..."
}

# ── Edit 101 Response ─────────────────────────────────────────────────────────
edit_response() {
    show_header
    local response_file="/etc/AutoScriptX/response"
    echo -e "${blue}── Edit 101 WebSocket Response ─────────────────────────${nc}\n"
    echo -e "  ${yellow}Current response:${nc}"
    echo -e "  ─────────────────────────────────────────────────────"
    cat "$response_file" 2>/dev/null || echo -e "  ${yellow}(empty — using ws-proxy default)${nc}"
    echo -e "  ─────────────────────────────────────────────────────\n"
    echo -e "  ${green}1)${nc} Edit with nano"
    echo -e "  ${green}2)${nc} Reset to default"
    echo -e "  ${green}0)${nc} Cancel"
    echo ""; read -rp "  Select: " choice
    case $choice in
        1) nano "$response_file"
           systemctl restart ws-proxy.service > /dev/null 2>&1
           echo -e "\n  ${green}Response updated.${nc}" ;;
        2) printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n' \
               > "$response_file"
           systemctl restart ws-proxy.service > /dev/null 2>&1
           echo -e "\n  ${green}Response reset to default.${nc}" ;;
        *) echo -e "  ${yellow}Cancelled.${nc}" ;;
    esac
    read -p "  Press Enter to return..."
}

# ── Update ────────────────────────────────────────────────────────────────────
do_update() {
    show_header
    echo -e "${blue}Fetching latest update engine from repo...${nc}\n"
    local menu_updater
    menu_updater=$(mktemp /tmp/asx_updater_XXXXXX.sh)
    if curl -fsSL -H "User-Agent: AutoScriptX-Deployment" --max-time 30 \
           "https://raw.githubusercontent.com/BlackBat21/trial/main/install.sh" \
           -o "$menu_updater"; then
        chmod +x "$menu_updater"
        bash "$menu_updater" --update-only
        rm -f "$menu_updater"
    else
        echo -e "${red}Failed to fetch update. Check your internet connection.${nc}"
    fi
    read -p "Press Enter to return..."
}

# ── Main Loop ─────────────────────────────────────────────────────────────────
while true; do
    show_header
    echo ""
    echo -e "  ${green}1)${nc} Create Account"
    echo -e "  ${green}2)${nc} Delete Account"
    echo -e "  ${green}3)${nc} List Accounts"
    echo -e "  ${green}4)${nc} Service Status"
    echo -e "  ${green}5)${nc} Restart Services"
    echo -e "  ${green}6)${nc} System Info"
    echo -e "  ${green}7)${nc} Change Domain"
    echo -e "  ${green}8)${nc} Edit Banner"
    echo -e "  ${green}9)${nc} Edit 101 Response"
    echo -e "  ${cyan}b)${nc} Bandwidth Monitor"
    echo -e "  ${yellow}u)${nc} Update AutoScriptX"
    echo -e "  ${red}0)${nc} Exit"
    echo ""
    read -rp "Select option: " opt
    case $opt in
        1) create_account   ;;
        2) delete_account   ;;
        3) list_accounts    ;;
        4) service_status   ;;
        5) restart_services ;;
        6) system_info      ;;
        7) change_domain    ;;
        8) edit_banner      ;;
        9) edit_response    ;;
        b|B) bandwidth_monitor ;;
        u|U) do_update      ;;
        0) exit 0           ;;
        *) echo -e "${red}Invalid option.${nc}"; sleep 1 ;;
    esac
done
MAINMENU
    chmod +x /usr/bin/menu
}

# Install FreeNetLabs scripts helper
# ─── _write_limit_monitor ─────────────────────────────────────────────────────
# Writes the bandwidth enforcement daemon and its systemd unit.
# The daemon polls Xray's stats API AND iptables UID byte counters, updates UsedBytes in users.csv,
# and suspends any account globally that has exceeded its LimitGB quota.
# ─────────────────────────────────────────────────────────────────────────────
_write_limit_monitor() {
    # ── Daemon script ─────────────────────────────────────────────────────────
    cat > /usr/local/bin/xray-limit-monitor << 'MONITOR_SCRIPT'
#!/bin/bash
# =============================================================================
# AutoScriptX — Hybrid Bandwidth Limit Monitor Daemon
# Polls Xray API AND iptables UID byte counters. Suspends global OS accounts.
# =============================================================================
CSV_DB="/usr/local/etc/xray/users.csv"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_API="127.0.0.1:10085"
XRAY_BIN="/usr/local/bin/xray"

query_xray_bytes() {
    local username="$1"
    local stats uplink downlink
    stats=$("$XRAY_BIN" api statsquery --server="$XRAY_API" -pattern "user>>>${username}>>>traffic" 2>/dev/null)
    uplink=$(echo  "$stats" | jq -r '.stat[]? | select(.name | endswith("uplink"))   | .value // "0"' 2>/dev/null | head -1)
    downlink=$(echo "$stats" | jq -r '.stat[]? | select(.name | endswith("downlink")) | .value // "0"' 2>/dev/null | head -1)
    uplink=$(echo "$uplink" | tr -dc '0-9')
    downlink=$(echo "$downlink" | tr -dc '0-9')
    echo $(( ${uplink:-0} + ${downlink:-0} ))
}

suspend_global_user() {
    local username="$1" limit_gb="$2"
    
    # 1. OS-Level Lock (SSH/Dropbear/Squid)
    usermod -L -e 1 "$username" >/dev/null 2>&1
    pkill -u "$username" >/dev/null 2>&1

    # 2. Xray-Level Lock (UUID removal)
    jq --arg user "$username" '
      .inbounds |= map(
        if .settings.clients
          then .settings.clients |= map(select(.email != $user))
        else . end
      )' "$XRAY_CONF" > /tmp/xlm_suspend.json && mv /tmp/xlm_suspend.json "$XRAY_CONF"
    systemctl restart xray >/dev/null 2>&1
    logger "xray-limit-monitor: ${username} suspended globally — limit ${limit_gb}GB reached."
}

while true; do
    if [[ ! -f "$CSV_DB" ]]; then
        sleep 60; continue
    fi

    # Dump iptables bytes and zero the chain immediately to prevent double counting
    IPT_DUMP=$(iptables -xnvL ACCT_OUT 2>/dev/null)
    iptables -Z ACCT_OUT 2>/dev/null

    tmp_csv=$(mktemp /tmp/xlm_csv_XXXXXX)
    head -1 "$CSV_DB" > "$tmp_csv"

    while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
        [[ "$name" == "Username" ]] && continue
        limit_gb=${limit_gb:-0}
        used_bytes=${used_bytes:-0}

        if [[ "$limit_gb" -gt 0 ]] 2>/dev/null; then
            # A. Get Xray Traffic
            xray_bytes=$(query_xray_bytes "$name")
            if [[ "$xray_bytes" -gt 0 ]] 2>/dev/null; then
                used_bytes=$xray_bytes
            fi

            # B. Get OS System Traffic (SSH/Dropbear)
            uid=$(id -u "$name" 2>/dev/null)
            if [[ -n "$uid" ]]; then
                system_bytes=$(echo "$IPT_DUMP" | awk -v uid="$uid" '$0 ~ "owner UID match " uid {print $2}')
                system_bytes=${system_bytes:-0}
                if [[ "$system_bytes" -gt 0 ]]; then
                    # Multiply by 2 as a bidirectional estimate for proxy traffic
                    used_bytes=$(( used_bytes + (system_bytes * 2) ))
                fi
            fi

            # C. Enforcement Check
            limit_bytes=$(( limit_gb * 1024 * 1024 * 1024 ))
            if [[ "$used_bytes" -ge "$limit_bytes" ]]; then
                # Check local OS password status to ensure idempotency
                if passwd -S "$name" 2>/dev/null | grep -q " PS "; then
                    suspend_global_user "$name" "$limit_gb"
                fi
            fi
        fi

        echo "${name},${pass},${uuid},${trojan},${exp},${limit_gb},${used_bytes}" >> "$tmp_csv"
    done < "$CSV_DB"

    mv "$tmp_csv" "$CSV_DB"
    chmod 600 "$CSV_DB"
    sleep 60
done
MONITOR_SCRIPT
    chmod +x /usr/local/bin/xray-limit-monitor

    # ── Systemd unit ──────────────────────────────────────────────────────────
    cat > /etc/systemd/system/xray-limit-monitor.service << 'MONITOR_SVC'
[Unit]
Description=AutoScriptX Bandwidth Limit Monitor
After=xray.service
Requires=xray.service

[Service]
Type=simple
ExecStart=/usr/local/bin/xray-limit-monitor
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
MONITOR_SVC

    systemctl daemon-reload                    > /dev/null 2>&1
    systemctl enable xray-limit-monitor        > /dev/null 2>&1
    systemctl restart xray-limit-monitor       > /dev/null 2>&1
}

install_scripts() {
    log_info "Installing scripts..."

    # ── Attempt optional upstream downloads (best-effort, non-fatal) ─────────
    # These augment the inline scripts below. If the upstream paths change or
    # the repo is unavailable, every critical function still works because the
    # core scripts are written inline further down.
    declare -A script_dirs=(
        [menu]="slowdns-menu.sh"
        [ssh]="create-account.sh delete-account.sh edit-banner.sh edit-response.sh lock-unlock.sh renew-account.sh"
        [system]="change-domain.sh manage-services.sh system-info.sh clean-expired-accounts.sh setup-slowdns.sh slowdns-status.sh"
    )
    for dir in "${!script_dirs[@]}"; do
        for s in ${script_dirs[$dir]}; do
            local base="${s%.sh}"
            wget -qO "/usr/bin/${base}" "$BASE_URL/scripts/$dir/$s" > /dev/null 2>&1 \
                && chmod +x "/usr/bin/${base}" \
                || log_warning "Optional script unavailable (non-fatal): $s"
        done
    done

    # Patch manage-services if the upstream download succeeded
    if [[ -s /usr/bin/manage-services ]]; then
        sed -i 's/x-ui\.service/xray.service/g' /usr/bin/manage-services
        sed -i 's/x-ui/xray/g'                  /usr/bin/manage-services
        sed -i 's/X-UI/Xray/g'                  /usr/bin/manage-services
        sed -i 's/XUI Watcher/Xray Watcher/g'   /usr/bin/manage-services
        sed -i 's/XUI/Xray/g'                   /usr/bin/manage-services
    fi


    # ── Write unified main menu (always inline, never depends on downloads) ───
    _write_main_menu
    rm -f /usr/bin/xray-menu   # clean up legacy binary if present from old installs

    # ── Write bandwidth limit monitor daemon + systemd unit ───────────────────
    _write_limit_monitor


    # Optional: attempt uninstall.sh download (non-fatal)
    wget -qO /etc/AutoScriptX/uninstall.sh "$BASE_URL/uninstall.sh" > /dev/null 2>&1 \
        && chmod +x /etc/AutoScriptX/uninstall.sh \
        || log_warning "Optional script unavailable (non-fatal): uninstall.sh"

    log_success "Scripts installed."
}

# Setup cron jobs
setup_cron_jobs() {
    log_info "Setting up cron jobs..."
    wget -qO /etc/cron.d/auto-reboot            "$BASE_URL/service/cron/auto-reboot"            || log_error "Failed to download auto-reboot."
    wget -qO /etc/cron.d/clean-expired-accounts "$BASE_URL/service/cron/clean-expired-accounts" || log_error "Failed to download clean-expired-accounts."
    service cron restart > /dev/null 2>&1
    log_success "Cron jobs set up."
}

# Final cleanup and execution configuration
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

# Main Entry-point
main() {
    check_root
    if [[ "${1:-}" == "--update-only" ]]; then
        log_info "Running in UPDATE-ONLY mode."
        update_script
        return 0
    fi

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
    install_xray
    configure_xray
    configure_nginx
    setup_badvpn
    configure_stunnel
    configure_fail2ban
    apply_firewall_rules
    install_scripts
    setup_cron_jobs
    final_cleanup
    log_success "═══════════════════════════════════════════════════"
    log_success " Installation complete!  AutoScriptX v4.1.0"
    log_success " Run '${green}autoscriptx${nc}' or '${green}asx${nc}' to start."
    log_success "═══════════════════════════════════════════════════"
}

main "$@"
