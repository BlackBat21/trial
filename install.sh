#!/bin/bash
# =============================================================================
# AutoScriptX Hybrid — FreeNetLabs Base + Elite Xray Payload
# Version : 4.1.1 (xHTTP Port-80 Non-TLS + Hybrid Bandwidth Limiter)
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

# Inject Native Xray-core
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

# Configure Xray Config
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
    log_success "Xray-core configured."
}

# Configure Nginx Locations
configure_nginx() {
    log_info "Setting up Nginx..."
    rm -f /etc/nginx/{sites-available/default,sites-enabled/default,conf.d/default.conf}
    mkdir -p /home/vps/public_html
    mkdir -p /etc/systemd/system/nginx.service.d

    cat > /etc/nginx/xray-locations.conf << 'NGINXLOC'
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
server {
    listen      80;
    server_name ${domain};
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
    log_success "Nginx set up."
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

# Configure fail2ban
configure_fail2ban() {
    log_info "Configuring fail2ban..."
    cat > /etc/fail2ban/jail.local << 'F2B_JAIL'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 104.16.0.0/13 104.24.0.0/14 108.162.192.0/18 131.0.72.0/22 141.101.64.0/18 162.158.0.0/15 172.64.0.0/13 173.245.48.0/20 188.114.96.0/20 190.93.240.0/20 197.234.240.0/22 198.41.128.0/17 151.101.0.0/16 199.232.0.0/16 23.235.32.0/20 23.235.39.0/24 185.31.16.0/22 199.27.72.0/21 13.32.0.0/15 13.35.0.0/16 52.84.0.0/15 54.182.0.0/16 54.192.0.0/16 54.230.0.0/16 54.239.128.0/18 54.239.192.0/19 99.84.0.0/16 204.246.164.0/22 204.246.168.0/22 204.246.174.0/23 204.246.176.0/20 205.251.192.0/19
bantime   = 1h
findtime  = 10m
maxretry  = 5
backend   = auto
banaction = iptables-multiport

[sshd]
enabled  = true
port     = ssh,22,443
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 2h

[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
maxretry = 5

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 2
bantime  = 2h

[nginx-limit-req]
enabled  = true
port     = http,https
filter   = nginx-limit-req
logpath  = /var/log/nginx/error.log
maxretry = 10
bantime  = 30m
F2B_JAIL

    cat > /etc/fail2ban/filter.d/xray-auth.conf << 'F2B_XRAY'
[Definition]
failregex = .*rejected.*<HOST>.*
            .*failed.*<HOST>.*
ignoreregex =
F2B_XRAY

    if [[ -f /var/log/xray/access.log ]]; then
        cat >> /etc/fail2ban/jail.local << 'F2B_XRAY_JAIL'
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
    log_success "fail2ban configured."
}

# Apply firewall rules and init global bandwidth chains
apply_firewall_rules() {
    log_info "Applying firewall rules..."
    
    # Initialize Accounting Chain
    iptables -N ACCT_OUT 2>/dev/null || true
    iptables -C OUTPUT -j ACCT_OUT 2>/dev/null || iptables -I OUTPUT 1 -j ACCT_OUT

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

    for port in 22 80 443 8080; do
        grep -qE "\-\-dport ${port}[^0-9]" /etc/iptables/rules.v4 2>/dev/null || \
            echo "-A INPUT -p tcp -m state --state NEW -m tcp --dport ${port} -j ACCEPT" \
            >> /etc/iptables/rules.v4
    done
    netfilter-persistent save > /dev/null 2>&1 || log_warning "Failed to save iptables rules."
    log_success "Firewall rules applied."
}

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

fmt_bytes() {
    local b="${1:-0}"
    b=$(echo "$b" | tr -dc '0-9'); b=${b:-0}
    if   [[ $b -ge 1073741824 ]]; then printf "%.2f GB" "$(echo "scale=2; $b/1073741824" | bc)"
    elif [[ $b -ge 1048576    ]]; then printf "%.2f MB" "$(echo "scale=2; $b/1048576"    | bc)"
    elif [[ $b -ge 1024       ]]; then printf "%.2f KB" "$(echo "scale=2; $b/1024"       | bc)"
    else echo "${b} B"
    fi
}

migrate_csv() {
    local tmp; tmp=$(mktemp)
    while IFS=',' read -r f1 f2 f3 f4 f5 f6 f7; do
        if [[ "$f1" == "Username" ]]; then
            echo "Username,SSHPassword,XrayUUID,TrojanPassword,ExpiryDate,LimitGB,UsedBytes"
        else
            f6=${f6:-0}; f7=${f7:-0}
            echo "${f1},${f2},${f3},${f4},${f5},${f6},${f7}"
        fi
    done < "$CSV_DB" > "$tmp"
    mv "$tmp" "$CSV_DB"
    chmod 600 "$CSV_DB"
}

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

    # Hook into ACCT_OUT chain for system traffic accounting
    local uid
    uid=$(id -u "$u_name" 2>/dev/null)
    if [[ -n "$uid" ]]; then
        iptables -C ACCT_OUT -m owner --uid-owner "$uid" -j RETURN 2>/dev/null || \
        iptables -A ACCT_OUT -m owner --uid-owner "$uid" -j RETURN
    fi

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
    read -p "Press Enter to return..."
}

delete_account() {
    show_header
    migrate_csv
    echo -e "${blue}── Delete Account ──────────────────────────────────────${nc}\n"
    if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1{found=1;exit} END{exit !found}' "$CSV_DB"; then
        echo -e "  ${yellow}No accounts found.${nc}"
        read -p "  Press Enter to return..."; return
    fi
    printf "  %-20s %-12s %-10s %-10s\n" "USERNAME" "EXPIRY" "LIMIT" "USED"
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
    
    # Remove from firewall accounting chain
    local uid
    uid=$(id -u "$u_name" 2>/dev/null)
    if [[ -n "$uid" ]]; then
        iptables -D ACCT_OUT -m owner --uid-owner "$uid" -j RETURN 2>/dev/null || true
    fi

    jq --arg user "$u_name" '
      .inbounds |= map(
        if .settings.clients
          then .settings.clients |= map(select(.email != $user))
        else . end
      )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
    systemctl restart xray > /dev/null 2>&1
    userdel -r "$u_name" 2>/dev/null || true
    sed -i "/^${u_name},/d" "$CSV_DB"
    echo -e "${green}  Account '${u_name}' deleted successfully.${nc}"
    read -p "  Press Enter to return..."
}

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
    while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
        [[ "$name" == "Username" ]] && continue
        limit_gb=${limit_gb:-0}; used_bytes=${used_bytes:-0}
        local lstr pct_str status_str
        if [[ "$limit_gb" -eq 0 ]]; then
            lstr="Unlimited"; pct_str="—"
        else
            lstr="${limit_gb} GB"
            local limit_bytes=$(( limit_gb * 1024 * 1024 * 1024 ))
            if [[ $limit_bytes -gt 0 ]]; then pct_str="$(( used_bytes * 100 / limit_bytes ))%"
            else pct_str="—"; fi
        fi
        if [[ "$exp" < "$today" ]]; then status_str="${red}Expired${nc}"
        elif [[ "$limit_gb" -gt 0 ]] && [[ "$used_bytes" -ge $(( limit_gb * 1024 * 1024 * 1024 )) ]]; then
            status_str="${red}CAPPED${nc}"
        else status_str="${green}Active${nc}"; fi
        printf "  %-16s %-12s %-10s %-10s %-5s " "$name" "$exp" "$(fmt_bytes "$used_bytes")" "$lstr" "$pct_str"
        echo -e "$status_str"
    done < "$CSV_DB"
    echo ""
    read -p "Press Enter to return..."
}

while true; do
    show_header
    echo ""
    echo -e "  ${green}1)${nc} Create Account"
    echo -e "  ${green}2)${nc} Delete Account"
    echo -e "  ${green}3)${nc} List Accounts"
    echo -e "  ${red}0)${nc} Exit"
    echo ""
    read -rp "Select option: " opt
    case $opt in
        1) create_account   ;;
        2) delete_account   ;;
        3) list_accounts    ;;
        0) exit 0           ;;
        *) echo -e "${red}Invalid option.${nc}"; sleep 1 ;;
    esac
done
MAINMENU
    chmod +x /usr/bin/menu
}

# ── Write Hybrid Bandwidth Limiter (Xray API + iptables owner) ──
_write_limit_monitor() {
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
    
    usermod -L -e 1 "$username" >/dev/null 2>&1
    pkill -u "$username" >/dev/null 2>&1

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

    IPT_DUMP=$(iptables -xnvL ACCT_OUT 2>/dev/null)
    iptables -Z ACCT_OUT 2>/dev/null

    tmp_csv=$(mktemp /tmp/xlm_csv_XXXXXX)
    head -1 "$CSV_DB" > "$tmp_csv"

    while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
        [[ "$name" == "Username" ]] && continue
        limit_gb=${limit_gb:-0}
        used_bytes=${used_bytes:-0}

        if [[ "$limit_gb" -gt 0 ]] 2>/dev/null; then
            # 1. Get Xray Traffic
            xray_bytes=$(query_xray_bytes "$name")
            if [[ "$xray_bytes" -gt 0 ]] 2>/dev/null; then
                used_bytes=$xray_bytes
            fi

            # 2. Get OS System Traffic (SSH/Dropbear)
            uid=$(id -u "$name" 2>/dev/null)
            if [[ -n "$uid" ]]; then
                system_bytes=$(echo "$IPT_DUMP" | awk -v uid="$uid" '$0 ~ "owner UID match " uid {print $2}')
                system_bytes=${system_bytes:-0}
                if [[ "$system_bytes" -gt 0 ]]; then
                    used_bytes=$(( used_bytes + (system_bytes * 2) ))
                fi
            fi

            # 3. Enforcement Check
            limit_bytes=$(( limit_gb * 1024 * 1024 * 1024 ))
            if [[ "$used_bytes" -ge "$limit_bytes" ]]; then
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

    cat > /etc/systemd/system/xray-limit-monitor.service << 'MONITOR_SVC'
[Unit]
Description=AutoScriptX Hybrid Bandwidth Monitor
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
    _write_main_menu
    _write_limit_monitor
    log_success "Scripts installed."
}

# Setup cron jobs
setup_cron_jobs() {
    log_info "Setting up cron jobs..."
    wget -qO /etc/cron.d/auto-reboot            "$BASE_URL/service/cron/auto-reboot"            || true
    wget -qO /etc/cron.d/clean-expired-accounts "$BASE_URL/service/cron/clean-expired-accounts" || true
    service cron restart > /dev/null 2>&1
    log_success "Cron jobs set up."
}

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
    log_success " Installation complete!  AutoScriptX Hybrid Limiter"
    log_success " Run '${green}autoscriptx${nc}' or '${green}asx${nc}' to start."
    log_success "═══════════════════════════════════════════════════"
}

main "$@"
