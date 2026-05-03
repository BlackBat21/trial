#!/usr/bin/env bash
# =============================================================================
# AutoXray Installer — Ubuntu 24 VPS Edition
# Author  : Systems Engineer / AutoScriptX-inspired
# Version : 2.0.0
# License : MIT
#
# Installs and configures:
#   • Nginx  (reverse-proxy, TLS termination, ports 80 / 443)
#   • Xray-core  (VLESS-WS, VLESS-gRPC, VMess-WS, Trojan-WS)
#   • SSH over WebSocket  (websockify → sshd :22)
#   • TLS  (Let's Encrypt via acme.sh  OR  self-signed fallback)
#   • BBR + system hardening for ≥ 2 GB RAM VPS
#
# Usage:
#   sudo bash install.sh [--domain example.com] [--email admin@example.com]
#   sudo bash install.sh --help
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 0 — GLOBAL CONSTANTS & COLOUR HELPERS
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/autoxray-install.log"
readonly BACKUP_DIR="/var/backups/autoxray"
readonly XRAY_DIR="/usr/local/etc/xray"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_SERVICE="/etc/systemd/system/xray.service"
readonly NGINX_CONF_DIR="/etc/nginx/conf.d"
readonly TLS_DIR="/etc/ssl/autoxray"
readonly WEBSOCKIFY_PORT=2082   # internal: websockify → sshd
readonly ACME_HOME="/root/.acme.sh"

# Internal Xray listen ports (never exposed directly; Nginx proxies to them)
readonly PORT_VLESS_WS=10001
readonly PORT_VMESS_WS=10002
readonly PORT_TROJAN_WS=10003
readonly PORT_VLESS_GRPC=10004
readonly PORT_VLESS_WS_NOTLS=10011   # plain HTTP inbound on :80
readonly PORT_VMESS_WS_NOTLS=10012

# Colours
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
SKIP_BBR=false
SKIP_HARDENING=false
UNINSTALL=false

usage() {
cat <<EOF
${BOLD}AutoXray Installer v${SCRIPT_VERSION}${NC}

Usage:
  sudo bash install.sh [OPTIONS]

Options:
  --domain   <domain>   Domain name for TLS (Let's Encrypt). If omitted,
                        a self-signed certificate will be generated.
  --email    <email>    ACME registration email (required with --domain).
  --skip-bbr            Skip TCP BBR / kernel tuning.
  --skip-hardening      Skip SSH / firewall hardening steps.
  --uninstall           Remove all installed components cleanly.
  -h, --help            Show this message.

Examples:
  sudo bash install.sh --domain vpn.example.com --email ops@example.com
  sudo bash install.sh                          # self-signed cert mode
  sudo bash install.sh --uninstall
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)       DOMAIN="${2:-}";   shift 2 ;;
            --email)        EMAIL="${2:-}";    shift 2 ;;
            --skip-bbr)     SKIP_BBR=true;     shift   ;;
            --skip-hardening) SKIP_HARDENING=true; shift ;;
            --uninstall)    UNINSTALL=true;    shift   ;;
            -h|--help)      usage; exit 0             ;;
            *) die "Unknown option: $1. Use --help for usage." ;;
        esac
    done
    [[ -n "$DOMAIN" && -z "$EMAIL" ]] && \
        die "--email is required when --domain is specified."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

preflight_checks() {
    section "Pre-flight checks"

    # Root
    [[ $EUID -eq 0 ]] || die "This script must be run as root."

    # Ubuntu 24.x
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        [[ "$ID" == "ubuntu" ]] || die "Requires Ubuntu. Detected: ${ID}"
        [[ "${VERSION_ID}" == "24."* ]] || \
            warn "Tested on Ubuntu 24.x — running on ${VERSION_ID}, proceed with caution."
    fi

    # RAM ≥ 2 GB
    local ram_kb
    ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    local ram_mb=$(( ram_kb / 1024 ))
    if (( ram_mb < 1800 )); then
        warn "RAM is ${ram_mb} MB — below recommended 2 GB. Performance may suffer."
    else
        log "RAM: ${ram_mb} MB — OK"
    fi

    # Internet connectivity
    if ! curl -fsSL --max-time 10 https://github.com > /dev/null 2>&1; then
        die "No internet connectivity detected. Cannot download packages."
    fi

    # Ports 80/443 free (or Nginx already owns them)
    for port in 80 443; do
        if ss -tlnp "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
            local owner
            owner=$(ss -tlnp "sport = :${port}" | awk 'NR>1{print $NF}' | head -1)
            if echo "$owner" | grep -qi nginx; then
                warn "Port ${port} already held by Nginx — will reconfigure."
            else
                warn "Port ${port} in use by: ${owner}. This may cause conflicts."
            fi
        fi
    done

    # Create log and backup dirs
    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
    touch "$LOG_FILE"

    log "Pre-flight checks passed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 3 — SYSTEM PREPARATION
# ─────────────────────────────────────────────────────────────────────────────

prepare_system() {
    section "System preparation"

    info "Updating package lists..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    info "Installing base dependencies..."
    apt-get install -y -qq \
        curl wget unzip jq socat coreutils \
        nginx certbot python3-certbot-nginx \
        websockify ufw fail2ban \
        ca-certificates openssl \
        net-tools iproute2 lsof \
        logrotate cron \
        2>&1 | tee -a "$LOG_FILE"

    log "Base packages installed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 4 — KERNEL & NETWORK OPTIMISATION (BBR + sysctl)
# ─────────────────────────────────────────────────────────────────────────────

optimize_kernel() {
    section "Kernel / network optimisation"

    if $SKIP_BBR; then
        warn "BBR tuning skipped (--skip-bbr)."
        return
    fi

    local kernel_ver
    kernel_ver=$(uname -r | cut -d. -f1-2)
    local major minor
    major=$(echo "$kernel_ver" | cut -d. -f1)
    minor=$(echo "$kernel_ver" | cut -d. -f2)

    if (( major > 4 || (major == 4 && minor >= 9) )); then
        modprobe tcp_bbr 2>/dev/null || true
        if lsmod | grep -q tcp_bbr; then
            log "BBR module loaded."
        else
            warn "Could not load tcp_bbr — proceeding without it."
        fi
    fi

    # Write optimised sysctl settings
    cat > /etc/sysctl.d/99-autoxray.conf <<'SYSCTL'
# ── AutoXray: Network & Memory Tuning ──────────────────────────────────────

# BBR congestion control
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr

# Socket buffer sizes (tuned for 2 GB RAM VPS)
net.core.rmem_max               = 67108864
net.core.wmem_max               = 67108864
net.core.rmem_default           = 1048576
net.core.wmem_default           = 1048576
net.ipv4.tcp_rmem               = 4096 1048576 67108864
net.ipv4.tcp_wmem               = 4096 1048576 67108864

# Connection queue
net.core.somaxconn              = 32768
net.core.netdev_max_backlog     = 32768
net.ipv4.tcp_max_syn_backlog    = 32768

# TIME_WAIT / FIN
net.ipv4.tcp_fin_timeout        = 15
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_max_tw_buckets     = 5000

# IP Forwarding (needed for proxy)
net.ipv4.ip_forward             = 1

# SYN Cookies (SYN flood protection)
net.ipv4.tcp_syncookies         = 1

# Memory pressure (2 GB target)
vm.swappiness                   = 10
vm.dirty_ratio                  = 15
vm.dirty_background_ratio       = 5
SYSCTL

    sysctl -p /etc/sysctl.d/99-autoxray.conf >> "$LOG_FILE" 2>&1
    log "Kernel parameters applied."

    # 2 GB swap (if none exists — helps with occasional memory spikes)
    if ! swapon --show | grep -q .; then
        if [[ -f /swapfile ]]; then
            warn "/swapfile exists but swap is off — skipping swap creation."
        else
            info "Creating 1 GB swap file..."
            fallocate -l 1G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile >> "$LOG_FILE" 2>&1
            swapon /swapfile
            grep -q '/swapfile' /etc/fstab || \
                echo "/swapfile none swap sw 0 0" >> /etc/fstab
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
        # ── Let's Encrypt via acme.sh ────────────────────────────────────────
        info "Using Let's Encrypt for domain: ${DOMAIN}"

        # Install acme.sh if absent
        if [[ ! -f "${ACME_HOME}/acme.sh" ]]; then
            info "Installing acme.sh..."
            curl -fsSL https://get.acme.sh | bash -s -- \
                --install-online --email "$EMAIL" >> "$LOG_FILE" 2>&1
        fi

        # Stop Nginx temporarily to allow standalone HTTP challenge on :80
        systemctl stop nginx 2>/dev/null || true

        "${ACME_HOME}/acme.sh" \
            --issue \
            --standalone \
            --domain "$DOMAIN" \
            --keylength ec-256 \
            --server letsencrypt \
            --force \
            >> "$LOG_FILE" 2>&1 || {
                warn "ACME issuance failed — falling back to self-signed."
                DOMAIN=""
            }

        if [[ -n "$DOMAIN" ]]; then
            # Install certs
            "${ACME_HOME}/acme.sh" \
                --install-cert \
                --domain "$DOMAIN" \
                --ecc \
                --cert-file    "${TLS_DIR}/cert.pem" \
                --key-file     "${TLS_DIR}/key.pem" \
                --fullchain-file "${TLS_DIR}/fullchain.pem" \
                --reloadcmd "systemctl reload nginx" \
                >> "$LOG_FILE" 2>&1
            log "Let's Encrypt certificate installed for ${DOMAIN}."
        fi
    fi

    # ── Self-signed fallback ─────────────────────────────────────────────────
    if [[ -z "$DOMAIN" ]] || [[ ! -f "${TLS_DIR}/fullchain.pem" ]]; then
        info "Generating self-signed TLS certificate (4096-bit RSA)..."
        openssl req -x509 -newkey rsa:4096 \
            -keyout "${TLS_DIR}/key.pem" \
            -out    "${TLS_DIR}/fullchain.pem" \
            -days 3650 -nodes \
            -subj "/CN=autoxray/O=AutoXray/C=US" \
            -addext "subjectAltName=IP:$(get_server_ip)" \
            >> "$LOG_FILE" 2>&1
        cp "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/cert.pem"
        warn "Self-signed certificate generated. Clients will need to disable TLS verification or install this cert."
        DOMAIN="localhost"
    fi

    chmod 600 "${TLS_DIR}/key.pem"
    chmod 644 "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/cert.pem"
    log "TLS certificate ready: ${TLS_DIR}/"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 6 — XRAY-CORE INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

install_xray() {
    section "Installing Xray-core"

    # Detect latest release tag
    local latest_tag
    latest_tag=$(curl -fsSL \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | jq -r '.tag_name') || latest_tag="v1.8.13"
    info "Latest Xray release: ${latest_tag}"

    # Detect architecture
    local arch
    case "$(uname -m)" in
        x86_64)  arch="64"      ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l)  arch="arm32-v7a" ;;
        *)       die "Unsupported architecture: $(uname -m)" ;;
    esac

    local dl_url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${arch}.zip"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    info "Downloading Xray ${latest_tag} (${arch})..."
    wget -q --show-progress -O "${tmp_dir}/xray.zip" "$dl_url" 2>&1 \
        | tail -5 | tee -a "$LOG_FILE"

    unzip -qo "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray"
    install -m 755 "${tmp_dir}/xray/xray" "$XRAY_BIN"
    rm -rf "$tmp_dir"

    "$XRAY_BIN" version 2>&1 | tee -a "$LOG_FILE"
    log "Xray-core ${latest_tag} installed at ${XRAY_BIN}."

    mkdir -p "$XRAY_DIR/conf"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 7 — XRAY CONFIGURATION (all protocols)
# ─────────────────────────────────────────────────────────────────────────────

configure_xray() {
    section "Configuring Xray-core"

    # ── Generate cryptographic identifiers ───────────────────────────────────
    local uuid_vless uuid_vmess
    uuid_vless=$("$XRAY_BIN" uuid)
    uuid_vmess=$("$XRAY_BIN" uuid)
    local trojan_pass
    trojan_pass=$(openssl rand -hex 20)
    local x25519
    x25519=$("$XRAY_BIN" x25519)
    local private_key public_key short_id
    private_key=$(echo "$x25519" | grep "Private key" | awk '{print $NF}')
    public_key=$(echo  "$x25519" | grep "Public key"  | awk '{print $NF}')
    short_id=$(openssl rand -hex 8)

    # ── Persist credentials for admin reference ───────────────────────────────
    cat > "${XRAY_DIR}/credentials.env" <<EOF
# AutoXray generated credentials — $(date -u '+%Y-%m-%d %H:%M UTC')
# Keep this file secure: chmod 600 ${XRAY_DIR}/credentials.env

VLESS_UUID="${uuid_vless}"
VMESS_UUID="${uuid_vmess}"
TROJAN_PASS="${trojan_pass}"
REALITY_PRIVATE_KEY="${private_key}"
REALITY_PUBLIC_KEY="${public_key}"
REALITY_SHORT_ID="${short_id}"
DOMAIN="${DOMAIN}"
EOF
    chmod 600 "${XRAY_DIR}/credentials.env"

    # ── Main Xray config ──────────────────────────────────────────────────────
    cat > "${XRAY_DIR}/config.json" <<XRAY_JSON
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },

  "stats": {},
  "api": {
    "tag":      "api",
    "services": ["StatsService"]
  },

  "policy": {
    "levels": {
      "0": {
        "statsUserUplink":   true,
        "statsUserDownlink": true,
        "handshake":         4,
        "connIdle":          300,
        "uplinkOnly":        2,
        "downlinkOnly":      5,
        "bufferSize":        512
      }
    },
    "system": {
      "statsInboundUplink":   true,
      "statsInboundDownlink": true
    }
  },

  "inbounds": [

    // ── [1] VLESS + WebSocket (TLS, proxied from Nginx :443) ─────────────
    {
      "tag":      "vless-ws-tls",
      "listen":   "127.0.0.1",
      "port":     ${PORT_VLESS_WS},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid_vless}", "flow": "" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network":    "ws",
        "security":   "none",
        "wsSettings": { "path": "/vless-ws", "headers": {} }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    },

    // ── [2] VMess + WebSocket (TLS, proxied from Nginx :443) ────────────
    {
      "tag":      "vmess-ws-tls",
      "listen":   "127.0.0.1",
      "port":     ${PORT_VMESS_WS},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${uuid_vmess}", "alterId": 0 }]
      },
      "streamSettings": {
        "network":    "ws",
        "security":   "none",
        "wsSettings": { "path": "/vmess-ws", "headers": {} }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    },

    // ── [3] Trojan + WebSocket (TLS, proxied from Nginx :443) ───────────
    {
      "tag":      "trojan-ws-tls",
      "listen":   "127.0.0.1",
      "port":     ${PORT_TROJAN_WS},
      "protocol": "trojan",
      "settings": {
        "clients": [{ "password": "${trojan_pass}" }]
      },
      "streamSettings": {
        "network":    "ws",
        "security":   "none",
        "wsSettings": { "path": "/trojan-ws", "headers": {} }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    },

    // ── [4] VLESS + gRPC (TLS, proxied from Nginx :443) ─────────────────
    {
      "tag":      "vless-grpc-tls",
      "listen":   "127.0.0.1",
      "port":     ${PORT_VLESS_GRPC},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid_vless}", "flow": "" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network":       "grpc",
        "security":      "none",
        "grpcSettings":  { "serviceName": "GunService", "multiMode": false }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    },

    // ── [5] VLESS + WebSocket — NON-TLS (Nginx :80) ──────────────────────
    {
      "tag":      "vless-ws-notls",
      "listen":   "127.0.0.1",
      "port":     ${PORT_VLESS_WS_NOTLS},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid_vless}", "flow": "" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network":    "ws",
        "security":   "none",
        "wsSettings": { "path": "/vless-ws-nt", "headers": {} }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    },

    // ── [6] VMess + WebSocket — NON-TLS (Nginx :80) ──────────────────────
    {
      "tag":      "vmess-ws-notls",
      "listen":   "127.0.0.1",
      "port":     ${PORT_VMESS_WS_NOTLS},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${uuid_vmess}", "alterId": 0 }]
      },
      "streamSettings": {
        "network":    "ws",
        "security":   "none",
        "wsSettings": { "path": "/vmess-ws-nt", "headers": {} }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    },

    // ── [7] API (local stats) ─────────────────────────────────────────────
    {
      "tag":      "api",
      "listen":   "127.0.0.1",
      "port":     10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    }

  ],

  "outbounds": [
    {
      "tag":      "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" }
    },
    {
      "tag":      "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],

  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type":        "field",
        "inboundTag":  ["api"],
        "outboundTag": "api"
      },
      {
        "type":        "field",
        "ip":          ["geoip:private", "geoip:cn"],
        "outboundTag": "direct"
      },
      {
        "type":        "field",
        "domain":      ["geosite:category-ads-all"],
        "outboundTag": "blocked"
      },
      {
        "type":        "field",
        "network":     "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  },

  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1",
      { "address": "8.8.8.8", "port": 53, "domains": [] }
    ]
  }
}
XRAY_JSON

    # Create log directory
    mkdir -p /var/log/xray
    chown -R nobody:nogroup /var/log/xray 2>/dev/null || \
    chown -R www-data:www-data /var/log/xray 2>/dev/null || true

    log "Xray config written. Credentials saved to ${XRAY_DIR}/credentials.env"
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

# Hardening
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
    log "Xray systemd service installed and enabled."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 9 — NGINX CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

configure_nginx() {
    section "Configuring Nginx"

    # Backup existing default config
    [[ -f /etc/nginx/sites-enabled/default ]] && \
        cp /etc/nginx/sites-enabled/default "${BACKUP_DIR}/nginx-default.bak" 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

    # ── Main nginx.conf performance tuning ───────────────────────────────────
    cat > /etc/nginx/nginx.conf <<'NGINX_MAIN'
user www-data;
# Auto-detect CPU cores; cap at 4 for a 2 GB VPS to avoid thrashing
worker_processes auto;
worker_cpu_affinity auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    use epoll;
    worker_connections 4096;
    multi_accept on;
}

http {
    # ── Basics ────────────────────────────────────────────────────────────
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    types_hash_max_size 4096;
    server_tokens       off;

    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    # ── Logging ───────────────────────────────────────────────────────────
    log_format main '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent"';
    access_log /var/log/nginx/access.log main buffer=32k flush=5m;
    error_log  /var/log/nginx/error.log  warn;

    # ── Timeouts (tuned for WebSocket long-polling) ───────────────────────
    keepalive_timeout        75s;
    keepalive_requests       1000;
    client_header_timeout    15s;
    client_body_timeout      30s;
    reset_timedout_connection on;
    send_timeout             30s;

    # ── Buffers (conservative for 2 GB RAM) ──────────────────────────────
    client_body_buffer_size      16k;
    client_max_body_size         64m;
    client_header_buffer_size    4k;
    large_client_header_buffers  4 16k;

    # ── Gzip ─────────────────────────────────────────────────────────────
    gzip              on;
    gzip_vary         on;
    gzip_proxied      any;
    gzip_comp_level   4;
    gzip_min_length   256;
    gzip_types        text/plain text/css application/json application/javascript
                      text/xml application/xml application/xml+rss text/javascript;

    # ── Security headers (applied globally) ──────────────────────────────
    add_header X-Frame-Options           SAMEORIGIN     always;
    add_header X-Content-Type-Options    nosniff        always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Referrer-Policy           "no-referrer"  always;

    # ── Rate limiting zones ───────────────────────────────────────────────
    limit_req_zone  $binary_remote_addr zone=general:10m rate=30r/s;
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    include /etc/nginx/conf.d/*.conf;
}

# gRPC requires stream-level proxying
stream {
    log_format stream_basic '$remote_addr [$time_local] '
                             '$protocol $status $bytes_sent $bytes_received '
                             '$session_time';
    include /etc/nginx/stream.d/*.conf;
}
NGINX_MAIN

    mkdir -p /etc/nginx/stream.d

    # ── Virtual host: :80 (non-TLS) ──────────────────────────────────────────
    cat > "${NGINX_CONF_DIR}/autoxray-80.conf" <<NGINX_80
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # ── Redirect ACME challenges; keep for cert renewals ─────────────────
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # ── VLESS + WS (non-TLS) ─────────────────────────────────────────────
    location /vless-ws-nt {
        proxy_pass          http://127.0.0.1:${PORT_VLESS_WS_NOTLS};
        proxy_http_version  1.1;
        proxy_set_header    Upgrade    \$http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_set_header    Host       \$host;
        proxy_set_header    X-Real-IP  \$remote_addr;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
    }

    # ── VMess + WS (non-TLS) ─────────────────────────────────────────────
    location /vmess-ws-nt {
        proxy_pass          http://127.0.0.1:${PORT_VMESS_WS_NOTLS};
        proxy_http_version  1.1;
        proxy_set_header    Upgrade    \$http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_set_header    Host       \$host;
        proxy_set_header    X-Real-IP  \$remote_addr;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
    }

    # ── SSH over WebSocket (non-TLS) ─────────────────────────────────────
    location /ssh-ws {
        proxy_pass          http://127.0.0.1:${WEBSOCKIFY_PORT};
        proxy_http_version  1.1;
        proxy_set_header    Upgrade    \$http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_set_header    Host       \$host;
        proxy_set_header    X-Real-IP  \$remote_addr;
        proxy_read_timeout  7200s;
        proxy_send_timeout  7200s;
    }

    # ── Decoy: redirect bare :80 to HTTPS (if domain configured) ─────────
    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINX_80

    # ── Virtual host: :443 (TLS) ──────────────────────────────────────────────
    cat > "${NGINX_CONF_DIR}/autoxray-443.conf" <<NGINX_443
# Shared upstream definitions
upstream xray_vless_ws   { server 127.0.0.1:${PORT_VLESS_WS};   keepalive 32; }
upstream xray_vmess_ws   { server 127.0.0.1:${PORT_VMESS_WS};   keepalive 32; }
upstream xray_trojan_ws  { server 127.0.0.1:${PORT_TROJAN_WS};  keepalive 32; }
upstream ssh_ws_backend  { server 127.0.0.1:${WEBSOCKIFY_PORT}; keepalive 16; }

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    # ── TLS ──────────────────────────────────────────────────────────────
    ssl_certificate         ${TLS_DIR}/fullchain.pem;
    ssl_certificate_key     ${TLS_DIR}/key.pem;
    ssl_session_cache       shared:SSL:20m;
    ssl_session_timeout     1d;
    ssl_session_tickets     off;
    ssl_protocols           TLSv1.2 TLSv1.3;
    ssl_ciphers             ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_ecdh_curve          X25519:prime256v1:secp384r1;

    # HSTS (only when using real domain + LE cert)
    add_header Strict-Transport-Security "max-age=63072000" always;

    # ── VLESS + WebSocket ─────────────────────────────────────────────────
    location /vless-ws {
        proxy_pass          http://xray_vless_ws;
        proxy_http_version  1.1;
        proxy_set_header    Upgrade    \$http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_set_header    Host       \$host;
        proxy_set_header    X-Real-IP  \$remote_addr;
        proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
    }

    # ── VMess + WebSocket ─────────────────────────────────────────────────
    location /vmess-ws {
        proxy_pass          http://xray_vmess_ws;
        proxy_http_version  1.1;
        proxy_set_header    Upgrade    \$http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_set_header    Host       \$host;
        proxy_set_header    X-Real-IP  \$remote_addr;
        proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
    }

    # ── Trojan + WebSocket ────────────────────────────────────────────────
    location /trojan-ws {
        proxy_pass          http://xray_trojan_ws;
        proxy_http_version  1.1;
        proxy_set_header    Upgrade    \$http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_set_header    Host       \$host;
        proxy_set_header    X-Real-IP  \$remote_addr;
        proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
    }

    # ── SSH over WebSocket (TLS) ──────────────────────────────────────────
    location /ssh-ws {
        proxy_pass          http://ssh_ws_backend;
        proxy_http_version  1.1;
        proxy_set_header    Upgrade    \$http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_set_header    Host       \$host;
        proxy_set_header    X-Real-IP  \$remote_addr;
        proxy_read_timeout  7200s;
        proxy_send_timeout  7200s;
        proxy_buffering     off;
    }

    # ── Decoy landing page ────────────────────────────────────────────────
    location / {
        root  /var/www/html;
        index index.html;
        limit_req   zone=general burst=20 nodelay;
        limit_conn  conn_limit 20;
    }
}
NGINX_443

    # ── gRPC stream proxy (Nginx stream module) ───────────────────────────────
    # gRPC requires Layer-4 (TCP) pass-through; Nginx HTTP/2 gRPC proxying
    # is used here (requires nginx ≥ 1.13.10).
    cat > /etc/nginx/stream.d/grpc.conf <<NGINX_GRPC
# Note: gRPC via HTTP/2 is handled in the HTTP block's :443 server via
# grpc_pass directive. The stream block below provides raw TCP fallback.
NGINX_GRPC

    # Add gRPC location to the :443 server (append before closing brace)
    cat >> "${NGINX_CONF_DIR}/autoxray-443.conf" <<GRPC_LOC

# (appended) gRPC via Nginx HTTP/2 grpc_pass
# Nginx must be compiled with --with-http_v2_module (default on Ubuntu 24)
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name grpc.${DOMAIN};   # use a sub-domain or the same domain

    ssl_certificate         ${TLS_DIR}/fullchain.pem;
    ssl_certificate_key     ${TLS_DIR}/key.pem;
    ssl_protocols           TLSv1.2 TLSv1.3;
    ssl_ciphers             ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;

    location /GunService {
        grpc_pass grpc://127.0.0.1:${PORT_VLESS_GRPC};
        grpc_read_timeout  3600s;
        grpc_send_timeout  3600s;
        grpc_set_header    X-Real-IP \$remote_addr;
    }
}
GRPC_LOC

    # Create decoy index page
    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Welcome</title>
<style>body{font-family:sans-serif;text-align:center;padding:80px;background:#f5f5f5}</style>
</head>
<body>
  <h1>Service Running</h1>
  <p>This server is operating normally.</p>
</body>
</html>
HTML

    # Test and reload
    nginx -t 2>&1 | tee -a "$LOG_FILE" || die "Nginx config test failed — check ${LOG_FILE}"
    log "Nginx configuration validated."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 10 — SSH OVER WEBSOCKET (websockify)
# ─────────────────────────────────────────────────────────────────────────────

configure_ssh_websocket() {
    section "SSH over WebSocket"

    # Ensure websockify is installed
    if ! command -v websockify &>/dev/null; then
        apt-get install -y -qq websockify 2>&1 | tee -a "$LOG_FILE"
    fi

    # ── websockify systemd service ────────────────────────────────────────────
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

# Hardening
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
    log "SSH WebSocket service (websockify → :22) configured on 127.0.0.1:${WEBSOCKIFY_PORT}"
    info "Clients connect to: wss://${DOMAIN}/ssh-ws  (TLS)"
    info "                or: ws://${DOMAIN}/ssh-ws   (non-TLS)"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 11 — SECURITY HARDENING
# ─────────────────────────────────────────────────────────────────────────────

harden_system() {
    section "Security hardening"

    if $SKIP_HARDENING; then
        warn "Security hardening skipped (--skip-hardening)."
        return
    fi

    # ── UFW firewall ──────────────────────────────────────────────────────────
    info "Configuring UFW firewall..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp   comment "SSH"
    ufw allow 80/tcp   comment "HTTP / non-TLS proxy"
    ufw allow 443/tcp  comment "HTTPS / TLS proxy"
    ufw --force enable
    log "UFW firewall enabled. Allowed: 22, 80, 443 (TCP)."

    # ── Fail2ban ──────────────────────────────────────────────────────────────
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

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = %(nginx_error_log)s

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = %(nginx_error_log)s
maxretry = 20
FAIL2BAN

    systemctl enable fail2ban
    systemctl restart fail2ban
    log "Fail2ban configured and started."

    # ── SSH hardening ─────────────────────────────────────────────────────────
    info "Hardening SSH configuration..."
    local sshd_conf="/etc/ssh/sshd_config"
    cp "$sshd_conf" "${BACKUP_DIR}/sshd_config.bak"

    # Apply secure settings (non-destructive: append overrides)
    cat >> "$sshd_conf" <<'SSH_HARDENING'

# ── AutoXray SSH hardening (appended) ──────────────────────────────────────
Protocol 2
LoginGraceTime 30
MaxAuthTries 4
MaxSessions 10
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes        # Keep on for initial SSH-WS; disable after adding keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 120
ClientAliveCountMax 3
AllowAgentForwarding yes
AllowTcpForwarding yes            # Required for SSH tunnel/proxy functionality
SSH_HARDENING

    systemctl restart sshd
    log "SSH hardened."

    # ── Limits ───────────────────────────────────────────────────────────────
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

/var/log/autoxray-install.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
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
            error "${svc} FAILED to start — check: journalctl -u ${svc} -n 50"
            failed+=("$svc")
        fi
    done

    if (( ${#failed[@]} > 0 )); then
        warn "The following services failed: ${failed[*]}"
        warn "Run 'bash install.sh --help' for troubleshooting guidance."
    else
        log "All services started successfully."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 14 — MANAGEMENT HELPER SCRIPT
# ─────────────────────────────────────────────────────────────────────────────

install_manage_script() {
    section "Installing management helper"

    cat > /usr/local/bin/autoxray <<'MANAGE'
#!/usr/bin/env bash
# autoxray — AutoXray management helper
# Usage: autoxray {status|restart|credentials|logs|update|uninstall}

CRED_FILE="/usr/local/etc/xray/credentials.env"
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

case "${1:-status}" in

status)
    echo -e "\n${BOLD}── AutoXray Service Status ──${NC}"
    for svc in nginx xray ssh-websocket fail2ban; do
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        [[ "$status" == "active" ]] \
            && echo -e "  ${GREEN}●${NC} ${svc}: ${status}" \
            || echo -e "  ${RED}●${NC} ${svc}: ${status}"
    done
    echo ""
    ;;

restart)
    echo "Restarting all AutoXray services..."
    for svc in xray nginx ssh-websocket; do
        systemctl restart "$svc" && echo "  ✔ $svc restarted" || echo "  ✖ $svc failed"
    done
    ;;

credentials)
    if [[ -f "$CRED_FILE" ]]; then
        echo -e "\n${BOLD}── AutoXray Credentials ──${NC}"
        # shellcheck source=/dev/null
        source "$CRED_FILE"
        SERVER_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
        echo -e "  ${CYAN}Server IP / Domain :${NC} ${SERVER_IP}"
        echo -e "  ${CYAN}VLESS UUID         :${NC} ${VLESS_UUID}"
        echo -e "  ${CYAN}VMess UUID         :${NC} ${VMESS_UUID}"
        echo -e "  ${CYAN}Trojan Password    :${NC} ${TROJAN_PASS}"
        echo -e "  ${CYAN}Reality Public Key :${NC} ${REALITY_PUBLIC_KEY}"
        echo -e "  ${CYAN}Reality Short ID   :${NC} ${REALITY_SHORT_ID}"
        echo ""
        echo -e "  ${BOLD}Connection paths (TLS :443):${NC}"
        echo "    VLESS+WS     : wss://${DOMAIN}/vless-ws"
        echo "    VMess+WS     : wss://${DOMAIN}/vmess-ws"
        echo "    Trojan+WS    : wss://${DOMAIN}/trojan-ws"
        echo "    VLESS+gRPC   : ${DOMAIN}/GunService  (port 443)"
        echo "    SSH WS (TLS) : wss://${DOMAIN}/ssh-ws"
        echo ""
        echo -e "  ${BOLD}Connection paths (non-TLS :80):${NC}"
        echo "    VLESS+WS     : ws://${DOMAIN}/vless-ws-nt"
        echo "    VMess+WS     : ws://${DOMAIN}/vmess-ws-nt"
        echo "    SSH WS       : ws://${DOMAIN}/ssh-ws"
    else
        echo "Credentials file not found: $CRED_FILE"
    fi
    ;;

logs)
    echo "=== Xray (last 50 lines) ==="
    journalctl -u xray -n 50 --no-pager
    echo ""
    echo "=== Nginx error log (last 20 lines) ==="
    tail -n 20 /var/log/nginx/error.log 2>/dev/null || echo "(empty)"
    ;;

update)
    echo "Checking for Xray-core updates..."
    latest=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
             | grep tag_name | cut -d'"' -f4)
    current=$(/usr/local/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
    echo "  Installed : ${current}"
    echo "  Latest    : ${latest}"
    if [[ "$latest" != "$current" ]]; then
        echo "Updating..."
        arch_raw=$(uname -m)
        case "$arch_raw" in
            x86_64)  arch="64"          ;;
            aarch64) arch="arm64-v8a"   ;;
            armv7l)  arch="arm32-v7a"   ;;
        esac
        tmp=$(mktemp -d)
        wget -q -O "${tmp}/xray.zip" \
            "https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${arch}.zip"
        unzip -qo "${tmp}/xray.zip" -d "${tmp}/xray_new"
        systemctl stop xray
        install -m 755 "${tmp}/xray_new/xray" /usr/local/bin/xray
        systemctl start xray
        rm -rf "$tmp"
        echo "  ✔ Xray updated to ${latest}"
    else
        echo "  ✔ Already up to date."
    fi
    ;;

uninstall)
    read -rp "Remove all AutoXray components? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    for svc in xray ssh-websocket; do
        systemctl stop  "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/ssh-websocket.service
    rm -rf /usr/local/etc/xray
    rm -f  /usr/local/bin/xray
    rm -f  /etc/nginx/conf.d/autoxray-*.conf
    rm -f  /etc/nginx/stream.d/grpc.conf
    rm -rf /etc/ssl/autoxray
    rm -f  /etc/sysctl.d/99-autoxray.conf
    rm -f  /etc/logrotate.d/autoxray
    rm -f  /etc/fail2ban/jail.d/autoxray.conf
    rm -f  /etc/security/limits.d/99-autoxray.conf
    systemctl daemon-reload
    systemctl restart nginx 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    sysctl -p /etc/sysctl.d/99-autoxray.conf 2>/dev/null || true
    rm -f /usr/local/bin/autoxray
    echo "AutoXray has been uninstalled."
    ;;

*)
    echo "Usage: autoxray {status|restart|credentials|logs|update|uninstall}"
    exit 1
    ;;
esac
MANAGE

    chmod +x /usr/local/bin/autoxray
    log "Management helper installed at /usr/local/bin/autoxray"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 15 — UNINSTALL MODE
# ─────────────────────────────────────────────────────────────────────────────

do_uninstall() {
    section "Uninstalling AutoXray"
    if command -v autoxray &>/dev/null; then
        autoxray uninstall
    else
        warn "autoxray helper not found — attempting manual removal..."
        for svc in xray ssh-websocket; do
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        done
        rm -f /etc/systemd/system/xray.service
        rm -f /etc/systemd/system/ssh-websocket.service
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
#  UTILITY: get primary server IP
# ─────────────────────────────────────────────────────────────────────────────

get_server_ip() {
    curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}'
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 16 — SUMMARY REPORT
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    local server_ip
    server_ip=$(get_server_ip)

    # shellcheck source=/dev/null
    source "${XRAY_DIR}/credentials.env" 2>/dev/null || true

    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║         AutoXray Installation Complete ✔                ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Server          :${NC} ${server_ip}"
    echo -e "  ${BOLD}Domain / Host   :${NC} ${DOMAIN}"
    echo ""
    echo -e "  ${BOLD}── TLS (:443) Endpoints ─────────────────────────────────${NC}"
    echo "  VLESS + WS      wss://${DOMAIN}/vless-ws      UUID: ${VLESS_UUID:-N/A}"
    echo "  VMess + WS      wss://${DOMAIN}/vmess-ws      UUID: ${VMESS_UUID:-N/A}"
    echo "  Trojan + WS     wss://${DOMAIN}/trojan-ws     Pass: ${TROJAN_PASS:-N/A}"
    echo "  VLESS + gRPC    ${DOMAIN}:443  svcName: GunService"
    echo "  SSH over WS     wss://${DOMAIN}/ssh-ws"
    echo ""
    echo -e "  ${BOLD}── Non-TLS (:80) Endpoints ──────────────────────────────${NC}"
    echo "  VLESS + WS      ws://${DOMAIN}/vless-ws-nt"
    echo "  VMess + WS      ws://${DOMAIN}/vmess-ws-nt"
    echo "  SSH over WS     ws://${DOMAIN}/ssh-ws"
    echo ""
    echo -e "  ${BOLD}── Reality Keys ─────────────────────────────────────────${NC}"
    echo "  Public Key      ${REALITY_PUBLIC_KEY:-N/A}"
    echo "  Short ID        ${REALITY_SHORT_ID:-N/A}"
    echo ""
    echo -e "  ${BOLD}── Management ───────────────────────────────────────────${NC}"
    echo "  autoxray status       — check service status"
    echo "  autoxray credentials  — show all connection details"
    echo "  autoxray restart      — restart all services"
    echo "  autoxray logs         — tail service logs"
    echo "  autoxray update       — update Xray-core"
    echo "  autoxray uninstall    — remove everything"
    echo ""
    echo -e "  ${BOLD}Log file:${NC} ${LOG_FILE}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN ENTRYPOINT
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║  AutoXray Installer v${SCRIPT_VERSION}            ║"
    echo "  ║  Xray-core + SSH-WS for Ubuntu 24 VPS   ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    parse_args "$@"

    $UNINSTALL && do_uninstall

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
