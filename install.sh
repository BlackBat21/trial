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
BASE_URL="https://raw.githubusercontent.com/BlackBat21/trial/main"
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
      stunnel4 nginx dropbear socat xz-utils sshguard squid > /dev/null 2>&1
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
    echo "Username,ServiceType,Secret,ExpiryDate" > "$CSV_DB"
    echo "admin_vless,Xray,${uuid_vless},Never"   >> "$CSV_DB"
    echo "admin_vmess,Xray,${uuid_vmess},Never"   >> "$CSV_DB"
    chmod 600 "${XRAY_DIR}/credentials.env" "$CSV_DB"

    cat > "${XRAY_DIR}/config.json" << XRAY_JSON
{
  "log": { "loglevel": "warning" },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked" }
    ]
  },
  "inbounds": [
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
    { "tag": "direct",  "protocol": "freedom"   },
    { "tag": "blocked", "protocol": "blackhole"  }
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
# Generated by install.sh v4.1.0  |  DO NOT EDIT MANUALLY
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
configure_sshguard() {
    log_info "Configuring SSHGuard..."
    systemctl enable sshguard  > /dev/null 2>&1
    systemctl restart sshguard > /dev/null 2>&1 || log_warning "Failed to restart sshguard."
    log_success "SSHGuard configured."
}

# Apply firewall rules safely with pre-execution sanitization
apply_firewall_rules() {
    log_info "Applying firewall rules..."
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

    if [[ -f /usr/bin/menu ]]; then
        sed -i 's/xui-menu/xray-menu/g'       /usr/bin/menu
        sed -i 's/X-UI Manager/Xray Manager/g' /usr/bin/menu
    fi
    if [[ -f /usr/bin/manage-services ]]; then
        sed -i 's/x-ui\.service/xray.service/g' /usr/bin/manage-services
        sed -i 's/x-ui/xray/g'                  /usr/bin/manage-services
        sed -i 's/X-UI/Xray/g'                  /usr/bin/manage-services
        sed -i 's/XUI Watcher/Xray Watcher/g'   /usr/bin/manage-services
        sed -i 's/XUI/Xray/g'                   /usr/bin/manage-services
    fi

    log_info "Rebuilding /usr/bin/xray-menu..."
    _write_xray_menu
    log_success "xray-menu updated."

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
# Updated by update_script  |  DO NOT EDIT MANUALLY
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

    log_info "Reloading Xray and Nginx..."
    systemctl restart xray  > /dev/null 2>&1 && log_success "Xray restarted." || log_warning "Xray restart failed."
    nginx -t > /dev/null 2>&1 && systemctl reload nginx > /dev/null 2>&1 && log_success "Nginx reloaded." || log_warning "Nginx config test failed — nginx NOT reloaded."

    rm -rf "$snap_dir"
    log_success "═══════════════════════════════════════════════════"
    log_success " Update complete.  Version 4.1.0"
    log_success " Users, UUIDs, certs, and domain: UNTOUCHED."
    log_success "═══════════════════════════════════════════════════"
    read -p "Press Enter to return..."
}

# Shared helper writing /usr/bin/xray-menu
_write_xray_menu() {
    cat > /usr/bin/xray-menu << 'XRAYMENU'
#!/bin/bash
CSV_DB="/usr/local/etc/xray/users.csv"
XRAY_CONF="/usr/local/etc/xray/config.json"
DOMAIN=$(cat /etc/AutoScriptX/domain 2>/dev/null || echo "localhost")
green="\033[0;32m"
blue="\033[0;34m"
yellow="\033[1;33m"
red="\033[0;31m"
nc="\033[0m"

show_menu() {
    clear
    echo "============================================"
    echo "           XRAY MANAGER  v4.1.0            "
    echo "============================================"
    echo "  1) Create Xray Account"
    echo "  2) Delete Xray Account"
    echo "  3) List Xray Accounts"
    echo "  ─────────────────────────────────────────"
    echo "  9) UPDATE AutoScriptX (non-destructive)"
    echo "  0) Back to Main Menu"
    echo "============================================"
    read -rp "Select Option: " opt
}

show_menu
case $opt in
    1)
        read -rp "Username : " u_name
        read -rp "Expiry (days) : " days
        u_exp=$(date -d "+${days} days" +"%Y-%m-%d")
        u_uuid=$(cat /proc/sys/kernel/random/uuid)
        jq --arg user "$u_name" --arg uuid "$u_uuid" '
          .inbounds |= map(
            if   .protocol == "vless"  and .settings.clients
              then .settings.clients += [{"id": $uuid, "flow": "", "email": $user}]
            elif .protocol == "vmess"  and .settings.clients
              then .settings.clients += [{"id": $uuid, "alterId": 0, "email": $user}]
            elif .protocol == "trojan" and .settings.clients
              then .settings.clients += [{"password": $uuid, "email": $user}]
            else . end
          )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
        systemctl restart xray > /dev/null 2>&1
        echo "${u_name},Xray,${u_uuid},${u_exp}" >> "$CSV_DB"

        v_json="{\"v\":\"2\",\"ps\":\"${u_name}-VMESS-WS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${u_uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-ws\",\"tls\":\"tls\"}"
        v_b64=$(echo -n "$v_json" | base64 -w0)
        vx_json="{\"v\":\"2\",\"ps\":\"${u_name}-VMESS-XHTTP\",\"add\":\"${DOMAIN}\",\"port\":\"80\",\"id\":\"${u_uuid}\",\"aid\":\"0\",\"net\":\"xhttp\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-xhttp\",\"tls\":\"\"}"
        vx_b64=$(echo -n "$vx_json" | base64 -w0)

        echo -e "\n${green}╔══════════════════════════════════════════════╗"
        echo -e "║         Account Created Successfully!        ║"
        echo -e "╚══════════════════════════════════════════════╝${nc}"
        echo -e "\n${blue}── TLS Links (Port 443) ────────────────────────────────${nc}"
        echo -e "${yellow}VLESS-WS (TLS):${nc}"
        echo -e "vless://${u_uuid}@${DOMAIN}:443?encryption=none&flow=none&type=ws&host=${DOMAIN}&path=%2Fvless-ws&security=tls&sni=${DOMAIN}#${u_name}-VLESS-WS"
        echo ""
        echo -e "${yellow}VMESS-WS (TLS):${nc}"
        echo -e "vmess://${v_b64}"
        echo ""
        echo -e "${yellow}TROJAN-WS (TLS):${nc}"
        echo -e "trojan://${u_uuid}@${DOMAIN}:443?type=ws&host=${DOMAIN}&path=%2Ftrojan-ws&security=tls&sni=${DOMAIN}#${u_name}-TROJAN-WS"
        echo -e "\n${blue}── Non-TLS xHTTP Links (Port 80) ───────────────────────${nc}"
        echo -e "${yellow}VLESS-xHTTP (Plain, no TLS):${nc}"
        echo -e "vless://${u_uuid}@${DOMAIN}:80?encryption=none&type=xhttp&path=%2Fvless-xhttp&security=none&host=${DOMAIN}#${u_name}-VLESS-XHTTP"
        echo ""
        echo -e "${yellow}VMESS-xHTTP (Plain, no TLS):${nc}"
        echo -e "vmess://${vx_b64}"
        echo ""
        read -p "Press Enter to return..."
        ;;
    2)
        read -rp "Enter Username to delete: " u_name
        jq --arg user "$u_name" '
          .inbounds |= map(
            if .settings.clients
              then .settings.clients |= map(select(.email != $user))
            else . end
          )' "$XRAY_CONF" > /tmp/x.json && mv /tmp/x.json "$XRAY_CONF"
        systemctl restart xray > /dev/null 2>&1
        sed -i "/^${u_name},/d" "$CSV_DB"
        echo -e "${green}Account deleted.${nc}"
        read -p "Press Enter to return..."
        ;;
    3)
        echo -e "\n${blue}Current Xray Accounts:${nc}"
        if grep -q "Xray" "$CSV_DB" 2>/dev/null; then
            grep "Xray" "$CSV_DB" | awk -F',' '{printf "  User: %-20s | Expiry: %s\n", $1, $4}'
        else
            echo -e "  ${yellow}No accounts found.${nc}"
        fi
        read -p "Press Enter to return..."
        ;;
    9)
        echo -e "${blue}Fetching latest update engine...${nc}"
        # Fixed scoping declaration for standalone executing context
        menu_updater=$(mktemp /tmp/asx_updater_XXXXXX.sh)
        if curl -fsSL -H "User-Agent: AutoScriptX-Deployment" --max-time 30 \
               "https://raw.githubusercontent.com/BlackBat21/trial/main/install.sh" \
               -o "$menu_updater"; then
            chmod +x "$menu_updater"
            bash "$menu_updater" --update-only
            rm -f "$menu_updater"
        else
            echo -e "${red}Failed to fetch update. Check your internet connection.${nc}"
            read -p "Press Enter to return..."
        fi
        ;;
    0)
        exit 0
        ;;
    *)
        echo -e "${red}Invalid option.${nc}"
        read -p "Press Enter to return..."
        ;;
esac
XRAYMENU
    chmod +x /usr/bin/xray-menu
}

# Install FreeNetLabs scripts helper
install_scripts() {
    log_info "Installing scripts..."
    declare -A script_dirs=(
        [menu]="menu.sh slowdns-menu.sh"
        [ssh]="create-account.sh delete-account.sh edit-banner.sh edit-response.sh lock-unlock.sh renew-account.sh"
        [system]="change-domain.sh manage-services.sh system-info.sh clean-expired-accounts.sh setup-slowdns.sh slowdns-status.sh"
    )
    for dir in "${!script_dirs[@]}"; do
        for s in ${script_dirs[$dir]}; do
            local base="${s%.sh}"
            wget -qO "/usr/bin/${base}" "$BASE_URL/scripts/$dir/$s" > /dev/null 2>&1 || log_warning "Failed to download $s."
            chmod +x "/usr/bin/${base}"
        done
    done

    _write_xray_menu

    if [[ -f /usr/bin/menu ]]; then
        sed -i 's/xui-menu/xray-menu/g'       /usr/bin/menu
        sed -i 's/X-UI Manager/Xray Manager/g' /usr/bin/menu
    fi
    if [[ -f /usr/bin/manage-services ]]; then
        sed -i 's/x-ui\.service/xray.service/g' /usr/bin/manage-services
        sed -i 's/x-ui/xray/g'                  /usr/bin/manage-services
        sed -i 's/X-UI/Xray/g'                  /usr/bin/manage-services
        sed -i 's/XUI Watcher/Xray Watcher/g'   /usr/bin/manage-services
        sed -i 's/XUI/Xray/g'                   /usr/bin/manage-services
    fi
    wget -qO /etc/AutoScriptX/uninstall.sh "$BASE_URL/uninstall.sh" > /dev/null 2>&1 || log_warning "Failed to download uninstall.sh."
    chmod +x /etc/AutoScriptX/uninstall.sh
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
    configure_sshguard
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
