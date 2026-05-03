#!/usr/bin/env bash
# =============================================================================
# AutoXray Installer — Ubuntu 24 VPS Edition
# Version : 2.1.0  (bug-fix release — safe for curl | bash)
# =============================================================================
#
# Root causes fixed vs v2.0.0:
#   1. BASH_SOURCE[0] unbound when piped → use ${BASH_SOURCE[0]:-$0}
#   2. Boolean vars used as commands ($SKIP_BBR, $UNINSTALL) → proper if blocks
#   3. [[ cond ]] && action at statement level exits on false under set -e
#      → all flow-control now uses explicit if/then/fi
#   4. [[ -n "$DOMAIN" && ... ]] && die()  same trap → if block
# =============================================================================

set -uo pipefail      # -u: unbound vars fatal  -o pipefail: pipe errors fatal
                      # -e deliberately omitted; we call die() on errors instead
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 0 — GLOBAL CONSTANTS & COLOUR HELPERS
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="2.1.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly LOG_FILE="/var/log/autoxray-install.log"
readonly BACKUP_DIR="/var/backups/autoxray"
readonly XRAY_DIR="/usr/local/etc/xray"
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
BLUE='\033[0;34m'; CYAN='\033[0;36m';  BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✔]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[✖]${NC} $*" | tee -a "$LOG_FILE" >&2; }
info()    { echo -e "${CYAN}[i]${NC} $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}\n" | tee -a "$LOG_FILE"; }
die()     { error "$*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 1 — ARGUMENT PARSING & HELP
# ─────────────────────────────────────────────────────────────────────────────

DOMAIN=""
EMAIL=""
SKIP_BBR="false"
SKIP_HARDENING="false"
UNINSTALL="false"

usage() {
cat <<EOF
${BOLD}AutoXray Installer v${SCRIPT_VERSION}${NC}

Usage:
  sudo bash install.sh [OPTIONS]

Options:
  --domain   <domain>   Domain for TLS (Let's Encrypt). Omit for self-signed.
  --email    <email>    ACME registration email (required with --domain).
  --skip-bbr            Skip TCP BBR / kernel tuning.
  --skip-hardening      Skip SSH / firewall hardening steps.
  --uninstall           Remove all installed components cleanly.
  -h, --help            Show this help message.

Examples:
  sudo bash install.sh --domain vpn.example.com --email ops@example.com
  sudo bash install.sh
  sudo bash install.sh --uninstall
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)         DOMAIN="${2:-}";  shift 2 ;;
            --email)          EMAIL="${2:-}";   shift 2 ;;
            --skip-bbr)       SKIP_BBR="true";  shift   ;;
            --skip-hardening) SKIP_HARDENING="true"; shift ;;
            --uninstall)      UNINSTALL="true"; shift   ;;
            -h|--help)        usage; exit 0             ;;
            *) die "Unknown option: $1  (use --help)" ;;
        esac
    done
    if [[ -n "$DOMAIN" && -z "$EMAIL" ]]; then
        die "--email is required when --domain is specified."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

preflight_checks() {
    section "Pre-flight checks"

    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root."
    fi

    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            die "Requires Ubuntu. Detected: ${ID}"
        fi
        if [[ "${VERSION_ID}" != "24."* ]]; then
            warn "Tested on Ubuntu 24.x — running on ${VERSION_ID}, proceed with caution."
        fi
    fi

    local ram_kb ram_mb
    ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    ram_mb=$(( ram_kb / 1024 ))
    if (( ram_mb < 1800 )); then
        warn "RAM is ${ram_mb} MB — below recommended 2 GB."
    else
        log "RAM: ${ram_mb} MB — OK"
    fi

    if ! curl -fsSL --max-time 10 https://github.com > /dev/null 2>&1; then
        die "No internet connectivity detected."
    fi

    for port in 80 443; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            warn "Port ${port} appears to be in use — installer will reconfigure."
        fi
    done

    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
    touch "$LOG_FILE"
    log "Pre-flight checks passed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 3 — SYSTEM PREPARATION
# ─────────────────────────────────────────────────────────────────────────────

prepare_system() {
    section "System preparation"
    export DEBIAN_FRONTEND=noninteractive

    info "Updating package lists..."
    apt-get update -qq

    info "Installing dependencies..."
    apt-get install -y -qq \
        curl wget unzip jq socat coreutils \
        nginx certbot python3-certbot-nginx \
        websockify ufw fail2ban \
        ca-certificates openssl \
        net-tools iproute2 lsof \
        logrotate cron 2>&1 | tee -a "$LOG_FILE"

    log "Base packages installed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 4 — KERNEL & NETWORK OPTIMISATION
# ─────────────────────────────────────────────────────────────────────────────

optimize_kernel() {
    section "Kernel / network optimisation"

    if [[ "$SKIP_BBR" == "true" ]]; then
        warn "BBR tuning skipped (--skip-bbr)."
        return
    fi

    local major minor
    major=$(uname -r | cut -d. -f1)
    minor=$(uname -r | cut -d. -f2)

    if (( major > 4 || (major == 4 && minor >= 9) )); then
        modprobe tcp_bbr 2>/dev/null || true
        if lsmod | grep -q tcp_bbr; then
            log "BBR module loaded."
        else
            warn "Could not load tcp_bbr — continuing without it."
        fi
    fi

    cat > /etc/sysctl.d/99-autoxray.conf <<'SYSCTL'
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max               = 67108864
net.core.wmem_max               = 67108864
net.core.rmem_default           = 1048576
net.core.wmem_default           = 1048576
net.ipv4.tcp_rmem               = 4096 1048576 67108864
net.ipv4.tcp_wmem               = 4096 1048576 67108864
net.core.somaxconn              = 32768
net.core.netdev_max_backlog     = 32768
net.ipv4.tcp_max_syn_backlog    = 32768
net.ipv4.tcp_fin_timeout        = 15
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_max_tw_buckets     = 5000
net.ipv4.ip_forward             = 1
net.ipv4.tcp_syncookies         = 1
vm.swappiness                   = 10
vm.dirty_ratio                  = 15
vm.dirty_background_ratio       = 5
SYSCTL

    sysctl -p /etc/sysctl.d/99-autoxray.conf >> "$LOG_FILE" 2>&1 || true
    log "Kernel parameters applied."

    if ! swapon --show | grep -q .; then
        if [[ ! -f /swapfile ]]; then
            info "Creating 1 GB swap file..."
            fallocate -l 1G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile >> "$LOG_FILE" 2>&1
            swapon /swapfile
            if ! grep -q '/swapfile' /etc/fstab; then
                echo "/swapfile none swap sw 0 0" >> /etc/fstab
            fi
            log "Swap enabled."
        fi
    else
        log "Swap already active — skipping."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 5 — TLS CERTIFICATE PROVISIONING
# ─────────────────────────────────────────────────────────────────────────────

provision_tls() {
    section "TLS certificate provisioning"
    mkdir -p "$TLS_DIR"

    if [[ -n "$DOMAIN" ]]; then
        info "Using Let's Encrypt for domain: ${DOMAIN}"

        if [[ ! -f "${ACME_HOME}/acme.sh" ]]; then
            info "Installing acme.sh..."
            curl -fsSL https://get.acme.sh | bash -s -- \
                --install-online --email "$EMAIL" >> "$LOG_FILE" 2>&1
        fi

        systemctl stop nginx 2>/dev/null || true

        if "${ACME_HOME}/acme.sh" \
            --issue --standalone \
            --domain "$DOMAIN" \
            --keylength ec-256 \
            --server letsencrypt \
            --force >> "$LOG_FILE" 2>&1; then

            "${ACME_HOME}/acme.sh" \
                --install-cert --domain "$DOMAIN" --ecc \
                --cert-file      "${TLS_DIR}/cert.pem" \
                --key-file       "${TLS_DIR}/key.pem" \
                --fullchain-file "${TLS_DIR}/fullchain.pem" \
                --reloadcmd "systemctl reload nginx" \
                >> "$LOG_FILE" 2>&1
            log "Let's Encrypt certificate installed for ${DOMAIN}."
        else
            warn "ACME issuance failed — falling back to self-signed."
            DOMAIN=""
        fi
    fi

    if [[ -z "$DOMAIN" ]] || [[ ! -f "${TLS_DIR}/fullchain.pem" ]]; then
        info "Generating self-signed certificate..."
        local server_ip
        server_ip=$(get_server_ip)
        openssl req -x509 -newkey rsa:4096 \
            -keyout "${TLS_DIR}/key.pem" \
            -out    "${TLS_DIR}/fullchain.pem" \
            -days 3650 -nodes \
            -subj "/CN=autoxray/O=AutoXray/C=US" \
            -addext "subjectAltName=IP:${server_ip}" \
            >> "$LOG_FILE" 2>&1
        cp "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/cert.pem"
        DOMAIN="${server_ip}"
        warn "Self-signed certificate generated. Using server IP: ${DOMAIN}"
    fi

    chmod 600 "${TLS_DIR}/key.pem"
    chmod 644 "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/cert.pem"
    log "TLS certificate ready."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 6 — XRAY-CORE INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

install_xray() {
    section "Installing Xray-core"

    local latest_tag
    latest_tag=$(curl -fsSL \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null) || latest_tag="v1.8.13"
    info "Latest Xray release: ${latest_tag}"

    local arch
    case "$(uname -m)" in
        x86_64)  arch="64"        ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l)  arch="arm32-v7a" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local dl_url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${arch}.zip"

    info "Downloading Xray ${latest_tag}..."
    if ! wget -q --show-progress -O "${tmp_dir}/xray.zip" "$dl_url" 2>&1 | tee -a "$LOG_FILE"; then
        rm -rf "$tmp_dir"
        die "Failed to download Xray-core from: ${dl_url}"
    fi

    unzip -qo "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray"
    install -m 755 "${tmp_dir}/xray/xray" "$XRAY_BIN"
    rm -rf "$tmp_dir"

    "$XRAY_BIN" version 2>&1 | tee -a "$LOG_FILE"
    mkdir -p "${XRAY_DIR}/conf"
    log "Xray-core ${latest_tag} installed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 7 — XRAY CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

configure_xray() {
    section "Configuring Xray-core"

    local uuid_vless uuid_vmess trojan_pass x25519 private_key public_key short_id
    uuid_vless=$("$XRAY_BIN" uuid)
    uuid_vmess=$("$XRAY_BIN" uuid)
    trojan_pass=$(openssl rand -hex 20)
    x25519=$("$XRAY_BIN" x25519)
    private_key=$(echo "$x25519" | grep "Private key" | awk '{print $NF}')
    public_key=$(echo  "$x25519" | grep "Public key"  | awk '{print $NF}')
    short_id=$(openssl rand -hex 8)

    cat > "${XRAY_DIR}/credentials.env" <<EOF
# AutoXray credentials — $(date -u '+%Y-%m-%d %H:%M UTC')
VLESS_UUID="${uuid_vless}"
VMESS_UUID="${uuid_vmess}"
TROJAN_PASS="${trojan_pass}"
REALITY_PRIVATE_KEY="${private_key}"
REALITY_PUBLIC_KEY="${public_key}"
REALITY_SHORT_ID="${short_id}"
DOMAIN="${DOMAIN}"
EOF
    chmod 600 "${XRAY_DIR}/credentials.env"

    # Xray-core supports // comments in JSON config
    cat > "${XRAY_DIR}/config.json" <<XRAY_JSON
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "bufferSize": 512
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "vless-ws-tls",
      "listen": "127.0.0.1",
      "port": ${PORT_VLESS_WS},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid_vless}", "flow": "" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/vless-ws" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    },
    {
      "tag": "vmess-ws-tls",
      "listen": "127.0.0.1",
      "port": ${PORT_VMESS_WS},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${uuid_vmess}", "alterId": 0 }]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/vmess-ws" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    },
    {
      "tag": "trojan-ws-tls",
      "listen": "127.0.0.1",
      "port": ${PORT_TROJAN_WS},
      "protocol": "trojan",
      "settings": {
        "clients": [{ "password": "${trojan_pass}" }]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/trojan-ws" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    },
    {
      "tag": "vless-grpc-tls",
      "listen": "127.0.0.1",
      "port": ${PORT_VLESS_GRPC},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid_vless}", "flow": "" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": { "serviceName": "GunService", "multiMode": false }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    },
    {
      "tag": "vless-ws-notls",
      "listen": "127.0.0.1",
      "port": ${PORT_VLESS_WS_NOTLS},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid_vless}", "flow": "" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/vless-ws-nt" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    },
    {
      "tag": "vmess-ws-notls",
      "listen": "127.0.0.1",
      "port": ${PORT_VMESS_WS_NOTLS},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${uuid_vmess}", "alterId": 0 }]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/vmess-ws-nt" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    },
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" }
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "blocked" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  },
  "dns": {
    "servers": ["8.8.8.8", "1.1.1.1"]
  }
}
XRAY_JSON

    mkdir -p /var/log/xray
    chown nobody:nogroup /var/log/xray 2>/dev/null || \
    chown www-data:www-data /var/log/xray 2>/dev/null || true

    log "Xray configuration written."
    info "VLESS UUID  : ${uuid_vless}"
    info "VMess UUID  : ${uuid_vmess}"
    info "Trojan Pass : ${trojan_pass}"
    info "Reality Pub : ${public_key}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 8 — XRAY SYSTEMD SERVICE
# ─────────────────────────────────────────────────────────────────────────────

install_xray_service() {
    section "Xray systemd service"

    cat > "$XRAY_SERVICE" <<'SERVICE'
[Unit]
Description=Xray Service (XTLS)
Documentation=https://xtls.github.io
After=network.target nss-lookup.target

[Service]
Type=simple
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=65535
LimitNPROC=65535
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable xray
    log "Xray systemd service installed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 9 — NGINX CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

configure_nginx() {
    section "Configuring Nginx"

    # Backup and remove defaults
    if [[ -f /etc/nginx/sites-enabled/default ]]; then
        cp /etc/nginx/sites-enabled/default "${BACKUP_DIR}/nginx-default.bak" 2>/dev/null || true
    fi
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

    cat > /etc/nginx/nginx.conf <<'NGINX_MAIN'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    use epoll;
    worker_connections 4096;
    multi_accept on;
}

http {
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    types_hash_max_size 4096;
    server_tokens       off;

    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent';
    access_log /var/log/nginx/access.log main buffer=32k flush=5m;
    error_log  /var/log/nginx/error.log  warn;

    keepalive_timeout         75s;
    keepalive_requests        1000;
    client_header_timeout     15s;
    client_body_timeout       30s;
    reset_timedout_connection on;
    send_timeout              30s;

    client_body_buffer_size      16k;
    client_max_body_size         64m;
    client_header_buffer_size    4k;
    large_client_header_buffers  4 16k;

    gzip              on;
    gzip_vary         on;
    gzip_proxied      any;
    gzip_comp_level   4;
    gzip_min_length   256;
    gzip_types        text/plain text/css application/json application/javascript
                      text/xml application/xml text/javascript;

    add_header X-Frame-Options        SAMEORIGIN  always;
    add_header X-Content-Type-Options nosniff     always;

    limit_req_zone  $binary_remote_addr zone=general:10m rate=30r/s;
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    include /etc/nginx/conf.d/*.conf;
}
NGINX_MAIN

    mkdir -p /etc/nginx/stream.d

    # ── :80 non-TLS virtual host ──────────────────────────────────────────
    cat > "${NGINX_CONF_DIR}/autoxray-80.conf" <<NGINX_80
server {
    listen 80;
    listen [::]:80;
    server_name _;

    location /.well-known/acme-challenge/ { root /var/www/html; }

    location /vless-ws-nt {
        proxy_pass         http://127.0.0.1:${PORT_VLESS_WS_NOTLS};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location /vmess-ws-nt {
        proxy_pass         http://127.0.0.1:${PORT_VMESS_WS_NOTLS};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location /ssh-ws {
        proxy_pass         http://127.0.0.1:${WEBSOCKIFY_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_read_timeout 7200s;
        proxy_send_timeout 7200s;
    }

    location / { return 301 https://\$host\$request_uri; }
}
NGINX_80

    # ── :443 TLS virtual host ─────────────────────────────────────────────
    cat > "${NGINX_CONF_DIR}/autoxray-443.conf" <<NGINX_443
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name _;

    ssl_certificate      ${TLS_DIR}/fullchain.pem;
    ssl_certificate_key  ${TLS_DIR}/key.pem;
    ssl_session_cache    shared:SSL:20m;
    ssl_session_timeout  1d;
    ssl_session_tickets  off;
    ssl_protocols        TLSv1.2 TLSv1.3;
    ssl_ciphers          ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    location /vless-ws {
        proxy_pass         http://127.0.0.1:${PORT_VLESS_WS};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_set_header   X-Real-IP  \$remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering    off;
    }

    location /vmess-ws {
        proxy_pass         http://127.0.0.1:${PORT_VMESS_WS};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_set_header   X-Real-IP  \$remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering    off;
    }

    location /trojan-ws {
        proxy_pass         http://127.0.0.1:${PORT_TROJAN_WS};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_set_header   X-Real-IP  \$remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering    off;
    }

    location /GunService {
        grpc_pass          grpc://127.0.0.1:${PORT_VLESS_GRPC};
        grpc_read_timeout  3600s;
        grpc_send_timeout  3600s;
        grpc_set_header    X-Real-IP \$remote_addr;
    }

    location /ssh-ws {
        proxy_pass         http://127.0.0.1:${WEBSOCKIFY_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_read_timeout 7200s;
        proxy_send_timeout 7200s;
        proxy_buffering    off;
    }

    location / {
        root  /var/www/html;
        index index.html;
        limit_req  zone=general burst=20 nodelay;
        limit_conn conn_limit 20;
    }
}
NGINX_443

    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'HTML'
<!DOCTYPE html><html lang="en">
<head><meta charset="UTF-8"><title>Welcome</title>
<style>body{font-family:sans-serif;text-align:center;padding:80px;background:#f5f5f5}</style>
</head>
<body><h1>Service Running</h1><p>This server is operating normally.</p></body>
</html>
HTML

    if nginx -t 2>&1 | tee -a "$LOG_FILE"; then
        log "Nginx configuration validated."
    else
        die "Nginx configuration test failed — check ${LOG_FILE}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 10 — SSH OVER WEBSOCKET
# ─────────────────────────────────────────────────────────────────────────────

configure_ssh_websocket() {
    section "SSH over WebSocket"

    if ! command -v websockify &>/dev/null; then
        apt-get install -y -qq websockify 2>&1 | tee -a "$LOG_FILE"
    fi

    cat > /etc/systemd/system/ssh-websocket.service <<SERVICE
[Unit]
Description=SSH over WebSocket (websockify)
After=network.target sshd.service
Requires=sshd.service

[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/websockify --web=/dev/null 127.0.0.1:${WEBSOCKIFY_PORT} 127.0.0.1:22
Restart=always
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
MemoryMax=64M

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable ssh-websocket
    log "SSH WebSocket service configured (websockify → :22 on 127.0.0.1:${WEBSOCKIFY_PORT})"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 11 — SECURITY HARDENING
# ─────────────────────────────────────────────────────────────────────────────

harden_system() {
    section "Security hardening"

    if [[ "$SKIP_HARDENING" == "true" ]]; then
        warn "Security hardening skipped (--skip-hardening)."
        return
    fi

    info "Configuring UFW firewall..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp   comment "SSH"
    ufw allow 80/tcp   comment "HTTP"
    ufw allow 443/tcp  comment "HTTPS"
    ufw --force enable
    log "UFW enabled: ports 22, 80, 443 open."

    info "Configuring Fail2ban..."
    cat > /etc/fail2ban/jail.d/autoxray.conf <<'FAIL2BAN'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = %(nginx_error_log)s
maxretry = 20
FAIL2BAN

    systemctl enable fail2ban
    systemctl restart fail2ban
    log "Fail2ban configured."

    info "Hardening SSH..."
    local sshd_conf="/etc/ssh/sshd_config"
    cp "$sshd_conf" "${BACKUP_DIR}/sshd_config.bak"
    cat >> "$sshd_conf" <<'SSH_HARDENING'

# AutoXray hardening
Protocol 2
LoginGraceTime 30
MaxAuthTries 4
MaxSessions 10
PermitEmptyPasswords no
X11Forwarding no
TCPKeepAlive yes
ClientAliveInterval 120
ClientAliveCountMax 3
AllowTcpForwarding yes
SSH_HARDENING

    systemctl restart sshd
    log "SSH hardened."

    cat > /etc/security/limits.d/99-autoxray.conf <<'LIMITS'
* soft nofile 65535
* hard nofile 65535
* soft nproc  65535
* hard nproc  65535
root soft nofile 65535
root hard nofile 65535
LIMITS

    log "Security hardening complete."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 12 — LOG ROTATION
# ─────────────────────────────────────────────────────────────────────────────

configure_logrotate() {
    section "Log rotation"
    cat > /etc/logrotate.d/autoxray <<'LOGROTATE'
/var/log/xray/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        systemctl kill -s USR1 xray 2>/dev/null || true
    endscript
}
LOGROTATE
    log "Log rotation configured."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 13 — START ALL SERVICES
# ─────────────────────────────────────────────────────────────────────────────

start_services() {
    section "Starting services"
    local failed=()

    for svc in nginx xray ssh-websocket fail2ban; do
        info "Starting ${svc}..."
        if systemctl start "$svc" 2>&1 | tee -a "$LOG_FILE"; then
            log "${svc} started."
        else
            error "${svc} FAILED — run: journalctl -u ${svc} -n 50"
            failed+=("$svc")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        warn "Failed services: ${failed[*]}"
    else
        log "All services started."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 14 — MANAGEMENT HELPER
# ─────────────────────────────────────────────────────────────────────────────

install_manage_script() {
    section "Installing management helper"

    cat > /usr/local/bin/autoxray <<'MANAGE'
#!/usr/bin/env bash
CRED_FILE="/usr/local/etc/xray/credentials.env"
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

case "${1:-status}" in
status)
    echo -e "\n${BOLD}── AutoXray Service Status ──${NC}"
    for svc in nginx xray ssh-websocket fail2ban; do
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        if [[ "$status" == "active" ]]; then
            echo -e "  ${GREEN}●${NC} ${svc}: active"
        else
            echo -e "  ${RED}●${NC} ${svc}: ${status}"
        fi
    done
    echo ""
    ;;
restart)
    for svc in xray nginx ssh-websocket; do
        if systemctl restart "$svc"; then echo "  ✔ $svc restarted"
        else echo "  ✖ $svc failed"; fi
    done
    ;;
credentials)
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE"
        SERVER_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
        echo -e "\n${BOLD}── AutoXray Credentials ──${NC}"
        echo -e "  ${CYAN}Server IP / Domain :${NC} ${SERVER_IP}"
        echo -e "  ${CYAN}VLESS UUID         :${NC} ${VLESS_UUID}"
        echo -e "  ${CYAN}VMess UUID         :${NC} ${VMESS_UUID}"
        echo -e "  ${CYAN}Trojan Password    :${NC} ${TROJAN_PASS}"
        echo -e "  ${CYAN}Reality Public Key :${NC} ${REALITY_PUBLIC_KEY}"
        echo -e "  ${CYAN}Reality Short ID   :${NC} ${REALITY_SHORT_ID}"
        echo ""
        echo -e "  ${BOLD}TLS :443 endpoints:${NC}"
        echo "    VLESS+WS    wss://${DOMAIN}/vless-ws"
        echo "    VMess+WS    wss://${DOMAIN}/vmess-ws"
        echo "    Trojan+WS   wss://${DOMAIN}/trojan-ws"
        echo "    VLESS+gRPC  ${DOMAIN}:443  service: GunService"
        echo "    SSH WS      wss://${DOMAIN}/ssh-ws"
        echo ""
        echo -e "  ${BOLD}Non-TLS :80 endpoints:${NC}"
        echo "    VLESS+WS    ws://${DOMAIN}/vless-ws-nt"
        echo "    VMess+WS    ws://${DOMAIN}/vmess-ws-nt"
        echo "    SSH WS      ws://${DOMAIN}/ssh-ws"
    else
        echo "Credentials not found: $CRED_FILE"
    fi
    ;;
logs)
    echo "=== Xray (last 50) ==="
    journalctl -u xray -n 50 --no-pager
    echo ""
    echo "=== Nginx errors (last 20) ==="
    tail -n 20 /var/log/nginx/error.log 2>/dev/null || echo "(empty)"
    ;;
update)
    latest=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep tag_name | cut -d'"' -f4)
    current=$(/usr/local/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
    echo "Installed: ${current}  Latest: ${latest}"
    if [[ "$latest" != "$current" ]]; then
        case "$(uname -m)" in
            x86_64)  arch="64"        ;;
            aarch64) arch="arm64-v8a" ;;
            armv7l)  arch="arm32-v7a" ;;
        esac
        tmp=$(mktemp -d)
        wget -q -O "${tmp}/xray.zip" \
            "https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${arch}.zip"
        unzip -qo "${tmp}/xray.zip" -d "${tmp}/xray_new"
        systemctl stop xray
        install -m 755 "${tmp}/xray_new/xray" /usr/local/bin/xray
        systemctl start xray
        rm -rf "$tmp"
        echo "✔ Updated to ${latest}"
    else
        echo "✔ Already up to date."
    fi
    ;;
uninstall)
    read -rp "Remove all AutoXray components? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "Aborted."; exit 0; fi
    for svc in xray ssh-websocket; do
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    rm -f  /etc/systemd/system/xray.service
    rm -f  /etc/systemd/system/ssh-websocket.service
    rm -rf /usr/local/etc/xray /etc/ssl/autoxray
    rm -f  /usr/local/bin/xray
    rm -f  /etc/nginx/conf.d/autoxray-*.conf
    rm -f  /etc/sysctl.d/99-autoxray.conf
    rm -f  /etc/logrotate.d/autoxray
    rm -f  /etc/fail2ban/jail.d/autoxray.conf
    rm -f  /etc/security/limits.d/99-autoxray.conf
    systemctl daemon-reload
    systemctl restart nginx   2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    rm -f /usr/local/bin/autoxray
    echo "AutoXray uninstalled."
    ;;
*)
    echo "Usage: autoxray {status|restart|credentials|logs|update|uninstall}"
    exit 1
    ;;
esac
MANAGE

    chmod +x /usr/local/bin/autoxray
    log "Management helper installed: /usr/local/bin/autoxray"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 15 — UNINSTALL MODE
# ─────────────────────────────────────────────────────────────────────────────

do_uninstall() {
    section "Uninstalling AutoXray"
    if command -v autoxray &>/dev/null; then
        autoxray uninstall
    else
        for svc in xray ssh-websocket; do
            systemctl stop    "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        done
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/ssh-websocket.service
        rm -rf /usr/local/etc/xray /etc/ssl/autoxray
        rm -f /usr/local/bin/xray /usr/local/bin/autoxray
        rm -f /etc/nginx/conf.d/autoxray-*.conf
        systemctl daemon-reload
        systemctl reload nginx 2>/dev/null || true
    fi
    log "Uninstall complete."
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  UTILITY
# ─────────────────────────────────────────────────────────────────────────────

get_server_ip() {
    curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
        || hostname -I | awk '{print $1}'
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 16 — SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    local server_ip
    server_ip=$(get_server_ip)
    source "${XRAY_DIR}/credentials.env" 2>/dev/null || true

    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║         AutoXray Installation Complete ✔                ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Server IP       :${NC} ${server_ip}"
    echo -e "  ${BOLD}Domain / Host   :${NC} ${DOMAIN}"
    echo ""
    echo -e "  ${BOLD}── TLS :443 ────────────────────────────────────────────${NC}"
    echo "  VLESS+WS     wss://${DOMAIN}/vless-ws    UUID: ${VLESS_UUID:-N/A}"
    echo "  VMess+WS     wss://${DOMAIN}/vmess-ws    UUID: ${VMESS_UUID:-N/A}"
    echo "  Trojan+WS    wss://${DOMAIN}/trojan-ws   Pass: ${TROJAN_PASS:-N/A}"
    echo "  VLESS+gRPC   ${DOMAIN}:443  svc: GunService"
    echo "  SSH WS       wss://${DOMAIN}/ssh-ws"
    echo ""
    echo -e "  ${BOLD}── Non-TLS :80 ─────────────────────────────────────────${NC}"
    echo "  VLESS+WS     ws://${DOMAIN}/vless-ws-nt"
    echo "  VMess+WS     ws://${DOMAIN}/vmess-ws-nt"
    echo "  SSH WS       ws://${DOMAIN}/ssh-ws"
    echo ""
    echo -e "  ${BOLD}── Reality Keys ────────────────────────────────────────${NC}"
    echo "  Public Key   ${REALITY_PUBLIC_KEY:-N/A}"
    echo "  Short ID     ${REALITY_SHORT_ID:-N/A}"
    echo ""
    echo -e "  ${BOLD}── Management ──────────────────────────────────────────${NC}"
    echo "  autoxray status | credentials | restart | logs | update | uninstall"
    echo ""
    echo -e "  ${BOLD}Log:${NC} ${LOG_FILE}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║  AutoXray Installer v${SCRIPT_VERSION}            ║"
    echo "  ║  Xray-core + SSH-WS for Ubuntu 24 VPS   ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    parse_args "$@"

    if [[ "$UNINSTALL" == "true" ]]; then
        do_uninstall
    fi

    preflight_checks
    prepare_system
    optimize_kernel
    provision_tls
    install_xray
    configure_xray
    install_xray_service
    configure_nginx
    configure_ssh_websocket
    harden_system
    configure_logrotate
    install_manage_script
    start_services
    print_summary
}

main "$@"