#!/usr/bin/env bash
# =============================================================================
# AutoScriptX Hybrid — Hardened Release
# Version : 4.3.0-hardened (xHTTP + WS, integrity-checked, injection-safe)
# Trust model (option B / split):
#   REPO_RAW  (BlackBat21/trial)  -> install.sh self-update + SHA256SUMS
#   ASSET_URL (ayanrajpoot10)     -> configs, binaries, helper scripts
# To go fully self-hosted later: mirror the asset tree into your repo and set
#   BASE_URL="$REPO_RAW"  (one line) — nothing else changes.
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
green="\033[0;32m"; blue="\033[0;34m"; red="\033[0;31m"
yellow="\033[1;33m"; cyan="\033[0;36m"; nc="\033[0m"

# ---------------------------------------------------------------------------
# Configuration
#   REPO_RAW  : YOUR repo — hosts install.sh (self-update) and SHA256SUMS.
#   ASSET_URL : upstream — hosts config/, bin/, scripts/, service/, uninstall.sh.
#               Override either with env vars if you fork or self-host.
#   REQUIRE_INTEGRITY=1 aborts on any unverifiable binary (recommended prod).
# ---------------------------------------------------------------------------
REPO_RAW="${AUTOSCRIPTX_REPO:-https://raw.githubusercontent.com/BlackBat21/trial/main}"
ASSET_URL="${AUTOSCRIPTX_ASSETS:-https://raw.githubusercontent.com/ayanrajpoot10/AutoScriptX/master}"
BASE_URL="$ASSET_URL"                                    # configs / binaries / helper scripts
SELF_UPDATE_URL="${REPO_RAW}/install.sh"                 # self-update from YOUR repo
MANIFEST_URL="${AUTOSCRIPTX_MANIFEST:-${REPO_RAW}/SHA256SUMS}"
REQUIRE_INTEGRITY="${REQUIRE_INTEGRITY:-0}"
UA="AutoScriptX-Deployment"
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly XRAY_DIR="/usr/local/etc/xray"
readonly CSV_DB="${XRAY_DIR}/users.csv"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly ASX_DIR="/etc/AutoScriptX"
readonly CSV_LOCK="/run/lock/autoscriptx-csv.lock"
readonly CFG_LOCK="/run/lock/autoscriptx-cfg.lock"
readonly PORT_VLESS_WS=10001
readonly PORT_VMESS_WS=10002
readonly PORT_TROJAN_WS=10003
readonly PORT_VLESS_XHTTP=10004
readonly PORT_VMESS_XHTTP=10005
readonly PORT_XRAY_API=10085
# BitTorrent / DHT / public tracker port ranges (multiport limit: 15 slots)
readonly AT_PORTS="6881:6999,51413,6969,2710,1337"

localip="" ; public_ip="" ; hostname_v="" ; domain=""

# ---------------------------------------------------------------------------
# Logging + error trap
# ---------------------------------------------------------------------------
log_info()    { echo -e "${blue}[ Info    ]${nc} $1"; }
log_success() { echo -e "${green}[ Success ]${nc} $1"; }
log_error()   { echo -e "${red}[ Error   ]${nc} $1" >&2; }
log_warning() { echo -e "${yellow}[ Warning ]${nc} $1" >&2; }
die() { log_error "$1"; exit "${2:-1}"; }
on_err() { log_error "Failed at line ${1} (exit ${2}). Aborting."; }
trap 'on_err "$LINENO" "$?"' ERR

check_root() { [[ "$(id -u)" -eq 0 ]] || die "Run as root."; }

# ---------------------------------------------------------------------------
# Validation (allowlists — inputs are treated as data, never code)
# ---------------------------------------------------------------------------
validate_domain() {
    local d="$1"
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,253}[A-Za-z0-9])?$ ]] || return 1
    [[ "$d" != *".."* ]] || return 1
    return 0
}
validate_username() {
    # Linux-safe + parser-safe: no comma/regex/sed metacharacters.
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# ---------------------------------------------------------------------------
# Networking helpers (retry + integrity)
# ---------------------------------------------------------------------------
# fetch <url> <dest> [tries] : download to temp, verify non-empty, atomic move.
fetch() {
    local url="$1" dest="$2" tries="${3:-3}" tmp i
    tmp="$(mktemp "${dest}.dl.XXXXXX")"
    for ((i=1;i<=tries;i++)); do
        if curl -fsSL -H "User-Agent: ${UA}" --max-time 60 -o "$tmp" "$url"; then
            if [[ -s "$tmp" ]]; then mv -f "$tmp" "$dest"; return 0; fi
        fi
        sleep 2
    done
    rm -f "$tmp"
    return 1
}

# sha256 verification against the optional manifest.
_manifest=""
load_manifest() {
    _manifest="$(mktemp)"
    curl -fsSL -H "User-Agent: ${UA}" --max-time 30 "$MANIFEST_URL" -o "$_manifest" 2>/dev/null \
        || { rm -f "$_manifest"; _manifest=""; }
}
verify_file() {
    # verify_file <file> <manifest-key>
    local file="$1" key="$2" want got
    if [[ -z "$_manifest" ]]; then
        [[ "$REQUIRE_INTEGRITY" == "1" ]] && die "Integrity required but no manifest for $key."
        return 0
    fi
    want="$(awk -v k="$key" '$2==k || $2=="./"k {print $1; exit}' "$_manifest")"
    if [[ -z "$want" ]]; then
        [[ "$REQUIRE_INTEGRITY" == "1" ]] && die "No checksum entry for $key."
        log_warning "No checksum entry for $key (continuing, integrity not enforced)."
        return 0
    fi
    got="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$want" == "$got" ]] || die "Checksum mismatch for $key (expected $want got $got)."
    log_success "Integrity verified: $key"
}

# fetch_verified <url> <dest> <manifest-key>
fetch_verified() {
    fetch "$1" "$2" || die "Download failed: $1"
    verify_file "$2" "$3"
}

# ---------------------------------------------------------------------------
# Atomic + locked state mutation
# ---------------------------------------------------------------------------
# atomic_write <dest> : reads stdin, writes atomically in dest's dir.
atomic_write() {
    local dest="$1" tmp
    tmp="$(mktemp "$(dirname "$dest")/.tmp.XXXXXX")"
    cat > "$tmp"
    mv -f "$tmp" "$dest"
}
# json_edit <file> <lockfile> <jq-args...> : locked, atomic jq in-place.
json_edit() {
    local file="$1" lock="$2"; shift 2
    local tmp; tmp="$(mktemp "$(dirname "$file")/.jq.XXXXXX")"
    (
        flock 9
        if jq "$@" "$file" > "$tmp" && [[ -s "$tmp" ]] && jq empty "$tmp" >/dev/null 2>&1; then
            chmod 600 "$tmp"; mv -f "$tmp" "$file"
        else
            rm -f "$tmp"
            log_error "json_edit refused to write invalid/empty JSON to $file"
            return 1
        fi
    ) 9>"$lock"
}

# ---------------------------------------------------------------------------
# --verify-only : check that every artifact referenced by the manifest is
# reachable in the live repo and matches its published checksum. Pre-release,
# no root, no changes.
# ---------------------------------------------------------------------------
verify_release() {
    log_info "Verifying live repo against manifest: ${MANIFEST_URL}"
    load_manifest
    [[ -n "$_manifest" ]] || die "No manifest found at ${MANIFEST_URL}."
    local fail=0 sum key url tmp got
    while IFS=$' \t' read -r sum key; do
        [[ -z "$sum" || "$sum" == \#* ]] && continue
        for url in "${REPO_RAW}/${key}" "${ASSET_URL}/${key}" "${ASSET_URL}/bin/${key}"; do
            tmp="$(mktemp)"
            if curl -fsSL -H "User-Agent: ${UA}" --max-time 30 -o "$tmp" "$url" 2>/dev/null && [[ -s "$tmp" ]]; then
                got="$(sha256sum "$tmp" | awk '{print $1}')"
                if [[ "$got" == "$sum" ]]; then
                    log_success "OK   $key"; rm -f "$tmp"; url=""; break
                else
                    log_error "HASH $key (got $got want $sum) at $url"; fail=1; rm -f "$tmp"; url=""; break
                fi
            fi
            rm -f "$tmp"
        done
        [[ -n "$url" ]] && { log_error "MISS $key (not reachable)"; fail=1; }
    done < "$_manifest"
    rm -f "$_manifest"; _manifest=""
    [[ "$fail" -eq 0 ]] && log_success "Release verification PASSED." \
        || die "Release verification FAILED — do not publish."
}

# ===========================================================================
# INSTALL STEPS
# ===========================================================================
setup_hosts() {
    log_info "Setting up hostname and hosts file..."
    localip="$(hostname -I | awk '{print $1}')"
    public_ip="$(curl -fsSL -H "User-Agent: ${UA}" --max-time 5 https://api.ipify.org \
        || curl -fsSL -H "User-Agent: ${UA}" --max-time 5 https://ifconfig.me || true)"
    [[ -n "$public_ip" ]] || public_ip="$localip"
    hostname_v="$(hostname)"
    if ! grep -qE "[[:space:]]${hostname_v}(\$|[[:space:]])" /etc/hosts; then
        printf '%s %s\n' "$localip" "$hostname_v" >> /etc/hosts
    fi
    log_success "Hostname and hosts file configured."
}

setup_domain() {
    mkdir -p "$ASX_DIR"; clear
    echo "---------------------------"
    echo "      VPS DOMAIN SETUP     "
    echo "---------------------------"
    domain=""
    if [[ -t 0 ]]; then read -rp "Enter Your Domain (leave blank for IP): " domain
    else read -rp "Enter Your Domain (leave blank for IP): " domain </dev/tty || true; fi
    domain="$(printf '%s' "$domain" | tr -d '[:space:]')"
    clear
    if [[ -z "$domain" ]]; then
        domain="${public_ip:-$localip}"
        log_info "No domain entered. Using IP: $domain"
    elif ! validate_domain "$domain"; then
        die "Invalid domain '$domain' (allowed: letters, digits, dot, hyphen)."
    fi
    printf '%s\n' "$domain" | atomic_write "${ASX_DIR}/domain"
    log_success "Domain saved."
}

update_system() {
    log_info "Updating system..."
    apt-get update -y >/dev/null 2>&1 || die "apt update failed."
    apt-get dist-upgrade -y >/dev/null 2>&1 || die "dist-upgrade failed."
    apt-get purge -y ufw firewalld exim4 'samba*' 'apache2*' 'bind9*' 'sendmail*' unscd \
        >/dev/null 2>&1 || log_warning "Some packages could not be purged."
    apt-get autoremove -y >/dev/null 2>&1 || true
    apt-get autoclean -y  >/dev/null 2>&1 || true
    log_success "System updated."
}

install_packages() {
    log_info "Installing packages..."
    apt-get install -y \
        netfilter-persistent iptables-persistent screen curl jq bzip2 gzip vnstat coreutils rsyslog \
        zip unzip net-tools nano lsof shc gnupg dos2unix dirmngr bc \
        stunnel4 nginx dropbear socat xz-utils fail2ban squid ca-certificates \
        >/dev/null 2>&1 || die "Failed to install one or more packages."
    log_success "Packages installed."
}

configure_squid() {
    log_info "Setting up Squid proxy..."
    fetch "$BASE_URL/config/squid.conf" /etc/squid/squid.conf || die "Failed to download squid.conf."
    local esc; esc="$(printf '%s' "$public_ip" | sed 's/[&/\]/\\&/g')"
    sed -i "s|__PUBLIC_IP__|${esc}|g" /etc/squid/squid.conf
    # Only substitute the bare IP token on acl lines (upstream template style).
    sed -i "/^[[:space:]]*acl[[:space:]]/ s|\bIP\b|${esc}|g" /etc/squid/squid.conf
    chmod 644 /etc/squid/squid.conf
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable squid  >/dev/null 2>&1 || true
    systemctl restart squid >/dev/null 2>&1 || log_error "Failed to restart Squid."
    log_success "Squid proxy set up."
}

install_gum() {
    log_info "Installing gum..."
    local ver="0.16.2" tgz
    tgz="$(mktemp)"
    fetch "https://github.com/charmbracelet/gum/releases/download/v${ver}/gum_${ver}_Linux_x86_64.tar.gz" "$tgz" \
        || die "Failed to download gum."
    verify_file "$tgz" "gum_${ver}_Linux_x86_64.tar.gz"
    tar -xzf "$tgz" -C /usr/local/bin --strip-components=1 --wildcards '*/gum'
    rm -f "$tgz"
    [[ -f /usr/local/bin/gum ]] || die "Failed to install gum."
    chmod +x /usr/local/bin/gum
    log_success "gum installed."
}

disable_ipv6() {
    log_info "Disabling IPv6..."
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    sysctl --system >/dev/null 2>&1 || log_warning "Failed to reload sysctl."
    log_success "IPv6 disabled."
}

configure_dropbear() {
    log_info "Configuring Dropbear..."
    fetch "$BASE_URL/config/dropbear.conf" /etc/default/dropbear || die "Failed to download dropbear.conf."
    chmod 644 /etc/default/dropbear
    mkdir -p "$ASX_DIR"
    fetch "$BASE_URL/config/banner.conf" "${ASX_DIR}/banner" || log_warning "Failed to download banner."
    chmod 644 "${ASX_DIR}/banner" 2>/dev/null || true
    grep -qxF '/bin/false'        /etc/shells || echo '/bin/false'        >> /etc/shells
    grep -qxF '/usr/sbin/nologin' /etc/shells || echo '/usr/sbin/nologin' >> /etc/shells
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable dropbear  >/dev/null 2>&1 || true
    systemctl restart dropbear >/dev/null 2>&1 || log_warning "Failed to restart Dropbear."
    log_success "Dropbear configured."
}

setup_websocket_service() {
    log_info "Setting up SSH-WebSocket service..."
    systemctl stop ws-proxy.service >/dev/null 2>&1 || true
    rm -f /usr/local/bin/ws-proxy
    fetch_verified "$BASE_URL/bin/ws-proxy" /usr/local/bin/ws-proxy "ws-proxy"
    chmod 0755 /usr/local/bin/ws-proxy
    fetch "$BASE_URL/service/systemd/ws-proxy.service" /etc/systemd/system/ws-proxy.service \
        || log_warning "Failed to install ws-proxy service unit."
    chmod 644 /etc/systemd/system/ws-proxy.service 2>/dev/null || true
    mkdir -p "$ASX_DIR"
    if [[ ! -s "${ASX_DIR}/response" ]]; then
        printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n' \
            > "${ASX_DIR}/response"
        chmod 644 "${ASX_DIR}/response"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable ws-proxy.service  >/dev/null 2>&1 || true
    systemctl restart ws-proxy.service >/dev/null 2>&1 || log_warning "Failed to restart ws-proxy."
    log_success "SSH-WebSocket service set up."
}

setup_ssl_cert() {
    log_info "Requesting SSL cert..."
    systemctl stop nginx >/dev/null 2>&1 || true
    mkdir -p "$ASX_DIR" /root/.acme.sh
    if [[ -s "${ASX_DIR}/cert.crt" && -s "${ASX_DIR}/cert.key" ]]; then
        log_info "Existing certificate found — keeping it."
    else
        if fetch "https://get.acme.sh" /root/.acme.sh/acme.sh; then
            chmod +x /root/.acme.sh/acme.sh
            /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1 || true
            /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
            if validate_domain "$domain"; then
                /root/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 >/dev/null 2>&1 \
                    || log_warning "acme.sh issue failed (will fall back to self-signed)."
                /root/.acme.sh/acme.sh --installcert -d "$domain" \
                    --fullchainpath "${ASX_DIR}/cert.crt" --keypath "${ASX_DIR}/cert.key" --ecc \
                    >/dev/null 2>&1 || log_warning "acme.sh install failed."
            fi
        else
            log_warning "Could not fetch acme.sh — using self-signed."
        fi
    fi
    if [[ ! -s "${ASX_DIR}/cert.crt" || ! -s "${ASX_DIR}/cert.key" ]]; then
        log_warning "Falling back to SELF-SIGNED certificate (clients will see an untrusted cert)."
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${ASX_DIR}/cert.key" -out "${ASX_DIR}/cert.crt" \
            -subj "/CN=${domain}" >/dev/null 2>&1
    fi
    chmod 600 "${ASX_DIR}/cert.key"; chmod 644 "${ASX_DIR}/cert.crt"
    log_success "SSL cert installed."
}

install_xray() {
    log_info "Installing Xray-core..."
    local latest_tag arch tmp_dir
    latest_tag="$(curl -fsSL -H "User-Agent: ${UA}" --max-time 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | jq -r '.tag_name // empty' 2>/dev/null || true)"
    [[ -n "$latest_tag" ]] || latest_tag="v1.8.24"
    case "$(uname -m)" in
        x86_64)  arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        *)       die "Unsupported arch: $(uname -m)" ;;
    esac
    tmp_dir="$(mktemp -d)"
    fetch "https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${arch}.zip" \
        "${tmp_dir}/xray.zip" || die "Failed to download Xray."
    verify_file "${tmp_dir}/xray.zip" "Xray-linux-${arch}.zip"
    unzip -qo "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray"
    mkdir -p "${XRAY_DIR}/conf" /var/log/xray
    install -m 0755 "${tmp_dir}/xray/xray" "$XRAY_BIN"
    cp "${tmp_dir}/xray/"*.dat /usr/local/bin/ 2>/dev/null || true
    rm -rf "$tmp_dir"
    log_success "Xray-core ${latest_tag} installed."
}

configure_xray() {
    log_info "Configuring Xray-core..."
    local uuid_vless uuid_vmess trojan_pass
    uuid_vless="$(cat /proc/sys/kernel/random/uuid)"
    uuid_vmess="$(cat /proc/sys/kernel/random/uuid)"
    trojan_pass="$(openssl rand -hex 20)"

    umask 077
    jq -n --arg v "$uuid_vless" --arg m "$uuid_vmess" --arg t "$trojan_pass" --arg d "$domain" \
        '{VLESS_UUID:$v,VMESS_UUID:$m,TROJAN_PASS:$t,DOMAIN:$d}
         | to_entries | map("\(.key)=\"\(.value)\"") | .[]' -r \
        | atomic_write "${XRAY_DIR}/credentials.env"
    printf 'Username,SSHPassword,XrayUUID,TrojanPassword,ExpiryDate,LimitGB,UsedBytes\n' \
        | atomic_write "$CSV_DB"
    chmod 600 "${XRAY_DIR}/credentials.env" "$CSV_DB"

    jq -n \
      --arg vless "$uuid_vless" --arg vmess "$uuid_vmess" --arg trojan "$trojan_pass" \
      --arg domain "$domain" \
      --argjson p_api  "$PORT_XRAY_API" \
      --argjson p_vw   "$PORT_VLESS_WS"    --argjson p_mw "$PORT_VMESS_WS" \
      --argjson p_tw   "$PORT_TROJAN_WS" \
      --argjson p_vx   "$PORT_VLESS_XHTTP"  --argjson p_mx "$PORT_VMESS_XHTTP" '
    {
      log: { loglevel:"warning", access:"/var/log/xray/access.log", error:"/var/log/xray/error.log" },
      stats: {},
      api: { tag:"api", services:["StatsService"] },
      policy: {
        levels: { "0": { statsUserUplink:true, statsUserDownlink:true } },
        system: { statsInboundUplink:false, statsInboundDownlink:false }
      },
      routing: { domainStrategy:"AsIs", rules: [
        { type:"field", inboundTag:["api"], outboundTag:"direct" },
        { type:"field", protocol:["bittorrent"], outboundTag:"blocked" }
      ]},
      inbounds: [
        { tag:"api", listen:"127.0.0.1", port:$p_api, protocol:"dokodemo-door",
          settings:{ address:"127.0.0.1" } },
        { tag:"vless-ws", listen:"127.0.0.1", port:$p_vw, protocol:"vless",
          settings:{ clients:[{id:$vless,flow:"",email:"admin_vless"}], decryption:"none" },
          streamSettings:{ network:"ws", wsSettings:{ path:"/vless-ws" } } },
        { tag:"vmess-ws", listen:"127.0.0.1", port:$p_mw, protocol:"vmess",
          settings:{ clients:[{id:$vmess,alterId:0,email:"admin_vmess"}] },
          streamSettings:{ network:"ws", wsSettings:{ path:"/vmess-ws" } } },
        { tag:"trojan-ws", listen:"127.0.0.1", port:$p_tw, protocol:"trojan",
          settings:{ clients:[{password:$trojan,email:"admin_trojan"}] },
          streamSettings:{ network:"ws", wsSettings:{ path:"/trojan-ws" } } },
        { tag:"vless-xhttp", listen:"127.0.0.1", port:$p_vx, protocol:"vless",
          settings:{ clients:[{id:$vless,flow:"",email:"admin_vless"}], decryption:"none" },
          streamSettings:{ network:"xhttp", xhttpSettings:{ path:"/vless-xhttp", host:$domain } } },
        { tag:"vmess-xhttp", listen:"127.0.0.1", port:$p_mx, protocol:"vmess",
          settings:{ clients:[{id:$vmess,alterId:0,email:"admin_vmess"}] },
          streamSettings:{ network:"xhttp", xhttpSettings:{ path:"/vmess-xhttp", host:$domain } } }
      ],
      outbounds: [ { tag:"direct", protocol:"freedom" }, { tag:"blocked", protocol:"blackhole" } ]
    }' | atomic_write "${XRAY_DIR}/config.json"
    chmod 600 "${XRAY_DIR}/config.json"

    _migrate_xray_antitorrent "${XRAY_DIR}/config.json"
    jq empty "${XRAY_DIR}/config.json" >/dev/null 2>&1 || die "config.json failed JSON validation."
    log_success "config.json passed JSON validation."

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

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable xray   >/dev/null 2>&1 || true
    systemctl restart xray  >/dev/null 2>&1 || log_warning "Xray restart failed."
    log_success "Xray-core configured (WS + xHTTP inbounds active)."
}

_write_xray_locations() {
    cat > /etc/nginx/xray-locations.conf <<NGINXLOC
location /vless-ws {
    proxy_pass http://127.0.0.1:${PORT_VLESS_WS}; proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host; proxy_read_timeout 86400s;
}
location /vmess-ws {
    proxy_pass http://127.0.0.1:${PORT_VMESS_WS}; proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host; proxy_read_timeout 86400s;
}
location /trojan-ws {
    proxy_pass http://127.0.0.1:${PORT_TROJAN_WS}; proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host; proxy_read_timeout 86400s;
}
location /vless-xhttp {
    proxy_pass http://127.0.0.1:${PORT_VLESS_XHTTP}; proxy_http_version 1.1;
    proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_buffering off; proxy_cache off; proxy_request_buffering off;
    proxy_read_timeout 86400s; client_max_body_size 0;
}
location /vmess-xhttp {
    proxy_pass http://127.0.0.1:${PORT_VMESS_XHTTP}; proxy_http_version 1.1;
    proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_buffering off; proxy_cache off; proxy_request_buffering off;
    proxy_read_timeout 86400s; client_max_body_size 0;
}
NGINXLOC
}

_write_xhttp_port80() {
    local dom="$1"
    validate_domain "$dom" || dom="localhost"
    cat > /etc/nginx/conf.d/xhttp-port80.conf <<EOF
server {
    listen      80;
    server_name ${dom};
    location /vless-xhttp {
        proxy_pass                 http://127.0.0.1:${PORT_VLESS_XHTTP};
        proxy_http_version         1.1;
        proxy_set_header           Host              \$host;
        proxy_set_header           X-Real-IP         \$remote_addr;
        proxy_set_header           X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_buffering off; proxy_cache off; proxy_request_buffering off;
        proxy_read_timeout 86400s; client_max_body_size 0;
    }
    location /vmess-xhttp {
        proxy_pass                 http://127.0.0.1:${PORT_VMESS_XHTTP};
        proxy_http_version         1.1;
        proxy_set_header           Host              \$host;
        proxy_set_header           X-Real-IP         \$remote_addr;
        proxy_set_header           X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_buffering off; proxy_cache off; proxy_request_buffering off;
        proxy_read_timeout 86400s; client_max_body_size 0;
    }
    location / { return 444; }
}
EOF
}

configure_nginx() {
    log_info "Setting up Nginx..."
    rm -f /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default \
          /etc/nginx/conf.d/default.conf
    mkdir -p /home/vps/public_html /etc/systemd/system/nginx.service.d
    _write_xray_locations
    _write_xhttp_port80 "$domain"

    local f name path esc_dom
    esc_dom="$(printf '%s' "$domain" | sed 's/[&/\]/\\&/g')"
    # Split on spaces explicitly — global IFS=$'\n\t' would keep this as one token.
    local -a nginx_files=(
        "nginx.conf:/etc/nginx/nginx.conf"
        "reverse-proxy.conf:/etc/nginx/conf.d/reverse-proxy.conf"
        "real_ip_sources.conf:/etc/nginx/conf.d/real_ip_sources.conf"
    )
    for f in "${nginx_files[@]}"; do
        name="${f%%:*}"; path="${f##*:}"
        fetch "$BASE_URL/config/$name" "$path" || die "Failed to download $name."
        sed -i '/listen \[::\]/d' "$path"
        if [[ "$name" == "reverse-proxy.conf" ]]; then
            sed -i "s|server_name _;|server_name ${esc_dom};|" "$path"
            sed -i 's|location / {|include /etc/nginx/xray-locations.conf;\n    location / {|g' "$path"
        fi
    done

    if nginx -t >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable nginx  >/dev/null 2>&1 || true
        systemctl restart nginx >/dev/null 2>&1 || die "Failed to restart Nginx."
        log_success "Nginx set up (WS TLS-443 + xHTTP TLS-443 + xHTTP Plain-80)."
    else
        die "Nginx config test FAILED — not restarting. Inspect /etc/nginx/."
    fi
}

setup_badvpn() {
    log_info "Setting up BadVPN..."
    local port
    for port in 7200 7300; do systemctl stop "badvpn-udpgw@${port}.service" >/dev/null 2>&1 || true; done
    pkill -f badvpn-udpgw 2>/dev/null || true
    rm -f /usr/bin/badvpn-udpgw
    fetch_verified "$BASE_URL/bin/badvpn-udpgw" /usr/bin/badvpn-udpgw "badvpn-udpgw"
    chmod +x /usr/bin/badvpn-udpgw
    fetch "$BASE_URL/service/systemd/badvpn-udpgw@.service" /etc/systemd/system/badvpn-udpgw@.service \
        || die "Failed to download badvpn service unit."
    for port in 7200 7300; do
        systemctl enable --now "badvpn-udpgw@${port}.service" >/dev/null 2>&1 \
            || log_warning "Failed to start badvpn-udpgw@${port}."
    done
    log_success "BadVPN set up."
}

configure_stunnel() {
    log_info "Configuring Stunnel..."
    fetch "$BASE_URL/config/stunnel.conf" /etc/stunnel/stunnel.conf || die "Failed to download stunnel.conf."
    openssl req -x509 -nodes -days 1095 -newkey rsa:2048 \
        -keyout /etc/stunnel/key.pem -out /etc/stunnel/cert.pem \
        -subj "/C=IN/ST=NA/L=NA/O=none/OU=none/CN=none" >/dev/null 2>&1 \
        || die "Failed to generate stunnel certificate."
    cat /etc/stunnel/key.pem /etc/stunnel/cert.pem > /etc/stunnel/stunnel.pem
    chmod 600 /etc/stunnel/key.pem /etc/stunnel/stunnel.pem
    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4
    systemctl enable stunnel4  >/dev/null 2>&1 || true
    systemctl restart stunnel4 >/dev/null 2>&1 || log_warning "Failed to restart stunnel4."
    log_success "Stunnel configured."
}

configure_fail2ban() {
    log_info "Configuring fail2ban..."
    mkdir -p /var/log/xray
    : > /var/log/xray/access.log
    [[ -f /var/log/xray/error.log ]] || : > /var/log/xray/error.log
    [[ -f /var/log/kern.log ]]       || : > /var/log/kern.log
    [[ -f /var/log/syslog ]]         || : > /var/log/syslog

    # Server's own addresses are whitelisted so an outbound match can never
    # get the VPS banned by its own jail.
    cat > /etc/fail2ban/jail.local <<F2B_JAIL
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${localip} ${public_ip}
           103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 104.16.0.0/13
           104.24.0.0/14 108.162.192.0/18 131.0.72.0/22 141.101.64.0/18
           162.158.0.0/15 172.64.0.0/13 173.245.48.0/20 188.114.96.0/20
           190.93.240.0/20 197.234.240.0/22 198.41.128.0/17
           151.101.0.0/16 199.232.0.0/16 23.235.32.0/20 185.31.16.0/22
           13.32.0.0/15 13.35.0.0/16 52.84.0.0/15 54.182.0.0/16
           54.192.0.0/16 54.230.0.0/16 54.239.128.0/18 99.84.0.0/16
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
F2B_JAIL

    # FIX: the old regex was ".*rejected.*<HOST>.*", but Xray prints the peer
    # address BEFORE the verdict, so the jail never matched anything. Xray also
    # needs an explicit datepattern (yyyy/mm/dd) or every line is skipped.
    cat > /etc/fail2ban/filter.d/xray-auth.conf <<'F2B_XRAY'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex = ^.*from (?:tcp|udp):<HOST>:\d+ .*(?:rejected|invalid|failed|unauthorized).*$
            ^.*(?:rejected|invalid|failed|unauthorized).*(?:tcp|udp):<HOST>:\d+.*$
            ^.*<HOST>.*(?:rejected|invalid user|authentication failed).*$
ignoreregex =
F2B_XRAY

    # Bans remote peers that keep hammering the box with BitTorrent traffic.
    # Only the IN-direction kernel log is matched (see anti-torrent engine).
    cat > /etc/fail2ban/filter.d/asx-torrent.conf <<'F2B_TORRENT'
[Definition]
failregex = ^.*ASX-TORRENT-IN .*SRC=<HOST>\s.*$
ignoreregex =
F2B_TORRENT

    cat >> /etc/fail2ban/jail.local <<'F2B_EXTRA_JAILS'

[xray-auth]
enabled  = true
port     = 443,80
filter   = xray-auth
logpath  = /var/log/xray/error.log
           /var/log/xray/access.log
maxretry = 5
bantime  = 1h

[asx-torrent]
enabled  = true
filter   = asx-torrent
logpath  = /var/log/kern.log
           /var/log/syslog
maxretry = 25
findtime = 10m
bantime  = 24h
action   = iptables-allports[name=asx-torrent]
F2B_EXTRA_JAILS

    systemctl enable fail2ban  >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || log_warning "Failed to restart fail2ban."
    log_success "fail2ban configured (SSH + Nginx + Xray + anti-torrent jails, CDN whitelisted)."
}

# ---------------------------------------------------------------------------
# Anti-torrent engine (packet layer)
#
# Why it is built this way:
#  * The old rules lived only in FORWARD. A VPN/proxy box terminates the
#    tunnel locally and re-originates the traffic, so peer/tracker packets
#    traverse OUTPUT (and INPUT), never FORWARD. The old ruleset therefore
#    matched almost nothing. Now all three hooks are covered.
#  * Direction-specific chains: only inbound/forward drops are logged with the
#    "ASX-TORRENT-IN " prefix, so the fail2ban jail sees remote peers. Logging
#    OUTPUT drops under the same prefix would show the VPS's own address and
#    fail2ban would ban the server itself.
#  * Signatures are specific. The bare words "torrent" and "announce" were
#    removed: they occur in ordinary plaintext HTTP (news pages, search
#    queries, CDN paths) and silently killed legitimate connections.
#  * Scans are bounded with --from/--to so per-packet cost stays low.
# ---------------------------------------------------------------------------
_at_sig_string=(
    "BitTorrent protocol"  "peer_id="              "info_hash="
    "&info_hash"           "?info_hash"            "/announce?"
    "/announce.php"        "announce.php?passkey=" "/scrape?"
    "d1:ad2:id20:"         "d1:rd2:id20:"          "9:get_peers"
    "13:announce_peer"     "9:find_node"           "13:announce-peers"
    "application/x-bittorrent" "urn:btih:"         ".torrent"
    "BitComet"             "uTorrent"              "qBittorrent"
    "Transmission/"        "libtorrent"            "Deluge/"
    "Azureus"
)
_at_sig_hex=( "|13|BitTorrent protocol" )
_at_dns_keywords=(
    "openbittorrent" "opentrackr" "publicbt" "coppersurfer" "leechers-paradise"
    "exodus.desync" "torrent.eu.org" "demonii" "thepiratebay" "1337x"
    "rarbg" "nyaa.si" "yts.mx" "gbitt"
)

_at_load_modules() {
    local m
    for m in xt_string xt_multiport xt_conntrack xt_hashlimit xt_length; do
        modprobe "$m" >/dev/null 2>&1 || true
    done
}

# Remove the pre-4.3 FORWARD-only string rules so they cannot pile up.
_at_cleanup_legacy() {
    local s
    for s in get_peers announce_peer find_node BitTorrent "BitTorrent protocol" "peer_id=" \
             ".torrent" "announce.php?passkey=" torrent announce info_hash; do
        while iptables -D FORWARD -m string --string "$s" --algo bm -j DROP >/dev/null 2>&1; do :; done
    done
}

# _at_build <iptables|ip6tables> <IN|OUT>
_at_build() {
    local ipt="$1" dir="$2" s miss=0
    local scan="ASX-TORRENT-${dir}" drop="ASX-TORRENT-DROP-${dir}"
    "$ipt" -N "$drop" >/dev/null 2>&1 || true; "$ipt" -F "$drop" >/dev/null 2>&1 || true
    "$ipt" -N "$scan" >/dev/null 2>&1 || true; "$ipt" -F "$scan" >/dev/null 2>&1 || true

    # verdict chain: rate-limited log, then RST for TCP (fast client failure), DROP otherwise
    if [[ "$dir" == "IN" ]]; then
        "$ipt" -A "$drop" -m limit --limit 6/min --limit-burst 10 \
            -j LOG --log-prefix "ASX-TORRENT-IN " --log-level 4 >/dev/null 2>&1 || true
    else
        "$ipt" -A "$drop" -m limit --limit 2/min --limit-burst 4 \
            -j LOG --log-prefix "ASX-TORRENT-OUT " --log-level 4 >/dev/null 2>&1 || true
    fi
    "$ipt" -A "$drop" -p tcp -j REJECT --reject-with tcp-reset >/dev/null 2>&1 \
        || "$ipt" -A "$drop" -p tcp -j DROP >/dev/null 2>&1 || true
    "$ipt" -A "$drop" -j DROP >/dev/null 2>&1 || true

    # never inspect loopback or the admin SSH session
    "$ipt" -A "$scan" -o lo -j RETURN >/dev/null 2>&1 || true
    "$ipt" -A "$scan" -i lo -j RETURN >/dev/null 2>&1 || true
    "$ipt" -A "$scan" -p tcp --dport 22 -j RETURN >/dev/null 2>&1 || true
    "$ipt" -A "$scan" -p tcp --sport 22 -j RETURN >/dev/null 2>&1 || true

    # 1. peer wire handshake (exact byte 0x13 + protocol string)
    for s in "${_at_sig_hex[@]}"; do
        "$ipt" -A "$scan" -p tcp -m string --hex-string "$s" --algo bm --from 0 --to 96 \
            -j "$drop" >/dev/null 2>&1 || miss=1
    done
    # 2. tracker HTTP/UDP + DHT bencode + client fingerprints
    for s in "${_at_sig_string[@]}"; do
        "$ipt" -A "$scan" -m string --string "$s" --algo bm --from 0 --to 1500 \
            -j "$drop" >/dev/null 2>&1 || miss=1
    done
    # 3. DNS lookups of well-known trackers / indexers (kills them before connect)
    for s in "${_at_dns_keywords[@]}"; do
        "$ipt" -A "$scan" -p udp --dport 53 -m string --string "$s" --algo bm -j "$drop" >/dev/null 2>&1 || miss=1
        "$ipt" -A "$scan" -p tcp --dport 53 -m string --string "$s" --algo bm -j "$drop" >/dev/null 2>&1 || miss=1
    done
    # 4. classic BitTorrent / DHT / tracker port ranges
    "$ipt" -A "$scan" -p tcp -m multiport --dports "$AT_PORTS" -j "$drop" >/dev/null 2>&1 || miss=1
    "$ipt" -A "$scan" -p udp -m multiport --dports "$AT_PORTS" -j "$drop" >/dev/null 2>&1 || miss=1
    # 5. DHT storm heuristic: floods of tiny UDP datagrams from one source
    "$ipt" -A "$scan" -p udp -m length --length 0:128 \
        -m hashlimit --hashlimit-above 80/sec --hashlimit-burst 160 \
        --hashlimit-mode srcip --hashlimit-name "asx_dht_${dir}" -j "$drop" >/dev/null 2>&1 || miss=1

    [[ "$miss" -eq 0 ]] || log_warning "Some ${ipt} ${dir} match modules are unavailable on this kernel."
    return 0
}

_at_hook() {
    local ipt="$1" hook="$2" chain="$3"
    "$ipt" -C "$hook" -j "$chain" >/dev/null 2>&1 \
        || "$ipt" -I "$hook" 1 -j "$chain" >/dev/null 2>&1 || true
}

_at_apply_family() {
    local ipt="$1"
    command -v "$ipt" >/dev/null 2>&1 || return 0
    _at_build "$ipt" IN
    _at_build "$ipt" OUT
    _at_hook "$ipt" INPUT   ASX-TORRENT-IN
    _at_hook "$ipt" FORWARD ASX-TORRENT-IN
    _at_hook "$ipt" OUTPUT  ASX-TORRENT-OUT
    return 0
}

apply_firewall_rules() {
    log_info "Applying firewall + anti-torrent rules..."
    _at_load_modules
    _at_cleanup_legacy

    local port
    for port in 22 80 443 8080; do
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 \
            || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 \
            || log_warning "Could not open tcp/${port}."
    done
    for port in 7200 7300; do
        iptables -C INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 \
            || iptables -I INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 \
            || log_warning "Could not open udp/${port} (badvpn)."
    done

    # Hooked at position 1, i.e. evaluated BEFORE the accepts above.
    _at_apply_family iptables
    _at_apply_family ip6tables

    mkdir -p /etc/iptables
    iptables-save  > /etc/iptables/rules.v4 || log_warning "Could not persist IPv4 rules."
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    cp /etc/iptables/rules.v4 /etc/iptables.up.rules 2>/dev/null || true
    netfilter-persistent save   >/dev/null 2>&1 || true
    netfilter-persistent reload >/dev/null 2>&1 || true
    log_success "Anti-torrent filter active: ${#_at_sig_string[@]} wire signatures, ${#_at_dns_keywords[@]} tracker DNS blocks, ports ${AT_PORTS}, DHT rate guard (IN/OUT/FORWARD)."
}

# ===========================================================================
# NON-DESTRUCTIVE UPDATE
# ===========================================================================
update_script() {
    log_info "Starting non-destructive AutoScriptX update..."
    load_manifest
    local -a PROTECTED=(
        "${XRAY_DIR}/users.csv" "${XRAY_DIR}/config.json" "${XRAY_DIR}/credentials.env"
        "${ASX_DIR}/cert.crt" "${ASX_DIR}/cert.key" "${ASX_DIR}/domain"
    )
    local snap_dir; snap_dir="$(mktemp -d /root/.asx_snap.XXXXXX)"; chmod 700 "$snap_dir"
    log_info "Snapshotting protected files -> ${snap_dir}"
    local p
    for p in "${PROTECTED[@]}"; do
        if [[ -f "$p" ]]; then
            cp -p "$p" "${snap_dir}/$(basename "$p")" || die "Snapshot failed for $p - aborting update."
        else
            log_warning "  Not found (won't restore): $p"
        fi
    done

    log_info "Re-downloading helper scripts..."
    declare -A script_dirs=(
        [menu]="menu.sh slowdns-menu.sh"
        [ssh]="create-account.sh delete-account.sh edit-banner.sh edit-response.sh lock-unlock.sh renew-account.sh"
        [system]="change-domain.sh manage-services.sh system-info.sh clean-expired-accounts.sh setup-slowdns.sh slowdns-status.sh"
    )
    local dir sc base
    local -a _sc_list
    for dir in "${!script_dirs[@]}"; do
        # FIX: split on whitespace regardless of global IFS=$'\n\t'.
        read -r -a _sc_list <<< "${script_dirs[$dir]}"
        for sc in "${_sc_list[@]}"; do
            base="${sc%.sh}"
            fetch "$BASE_URL/scripts/$dir/$sc" "/usr/bin/${base}" \
                && chmod +x "/usr/bin/${base}" || log_warning "  Failed to update $sc."
        done
    done

    if [[ -s /usr/bin/manage-services ]]; then
        sed -i -e 's/x-ui\.service/xray.service/g' -e 's/x-ui/xray/g' \
               -e 's/X-UI/Xray/g' -e 's/XUI Watcher/Xray Watcher/g' -e 's/XUI/Xray/g' \
               /usr/bin/manage-services
    fi
    if [[ -s /usr/bin/create-account ]]; then
        sed -i \
            -e 's/\.protocol == "vless"/(.tag | test("vless"))/g' \
            -e 's/\.protocol == "vmess"/(.tag | test("vmess"))/g' \
            -e 's/\.protocol == "trojan"/(.tag | test("trojan"))/g' \
            /usr/bin/create-account
        log_success "create-account patched: xhttp tag-match fix applied."
    fi

    log_info "Rebuilding /usr/bin/menu..."; _write_main_menu; rm -f /usr/bin/xray-menu
    log_info "Rebuilding limit monitor...";  _write_limit_monitor
    log_info "Rebuilding torrent watchdog..."; _write_torrent_watchdog
    log_info "Refreshing nginx fragments..."; _write_xray_locations

    local cur_domain; cur_domain="$(cat "${ASX_DIR}/domain" 2>/dev/null || echo localhost)"
    _write_xhttp_port80 "$cur_domain"

    if [[ -f "${XRAY_DIR}/config.json" ]]; then
        local ex_vless ex_vmess
        ex_vless="$(jq -r '.inbounds[]|select(.tag=="vless-ws")|.settings.clients[0].id // empty' "${XRAY_DIR}/config.json" 2>/dev/null || true)"
        ex_vmess="$(jq -r '.inbounds[]|select(.tag=="vmess-ws")|.settings.clients[0].id // empty' "${XRAY_DIR}/config.json" 2>/dev/null || true)"
        if [[ -n "$ex_vless" ]] && ! jq -e '.inbounds[]|select(.tag=="vless-xhttp")' "${XRAY_DIR}/config.json" >/dev/null 2>&1; then
            json_edit "${XRAY_DIR}/config.json" "$CFG_LOCK" \
              --arg uuid "$ex_vless" --arg domain "$cur_domain" --argjson port "$PORT_VLESS_XHTTP" \
              '.inbounds += [{tag:"vless-xhttp",listen:"127.0.0.1",port:$port,protocol:"vless",
                settings:{clients:[{id:$uuid,flow:"",email:"admin_vless"}],decryption:"none"},
                streamSettings:{network:"xhttp",xhttpSettings:{path:"/vless-xhttp",host:$domain}}}]' \
              && log_success "  vless-xhttp inbound added."
        fi
        if [[ -n "$ex_vmess" ]] && ! jq -e '.inbounds[]|select(.tag=="vmess-xhttp")' "${XRAY_DIR}/config.json" >/dev/null 2>&1; then
            json_edit "${XRAY_DIR}/config.json" "$CFG_LOCK" \
              --arg uuid "$ex_vmess" --arg domain "$cur_domain" --argjson port "$PORT_VMESS_XHTTP" \
              '.inbounds += [{tag:"vmess-xhttp",listen:"127.0.0.1",port:$port,protocol:"vmess",
                settings:{clients:[{id:$uuid,alterId:0,email:"admin_vmess"}]},
                streamSettings:{network:"xhttp",xhttpSettings:{path:"/vmess-xhttp",host:$domain}}}]' \
              && log_success "  vmess-xhttp inbound added."
        fi
    fi

    log_info "Restoring protected files..."
    for p in "${PROTECTED[@]}"; do
        local fn; fn="$(basename "$p")"
        [[ -f "${snap_dir}/${fn}" ]] && { cp -p "${snap_dir}/${fn}" "$p"; log_success "  Restored: $p"; }
    done

    if [[ -f "${XRAY_DIR}/config.json" ]]; then
        local cfg="${XRAY_DIR}/config.json"
        jq -e '.stats'  "$cfg" >/dev/null 2>&1 || json_edit "$cfg" "$CFG_LOCK" '. + {stats:{}}'
        jq -e '.api'    "$cfg" >/dev/null 2>&1 || json_edit "$cfg" "$CFG_LOCK" '. + {api:{tag:"api",services:["StatsService"]}}'
        if jq -e '.policy' "$cfg" >/dev/null 2>&1; then
            json_edit "$cfg" "$CFG_LOCK" '.policy.system.statsInboundUplink=false | .policy.system.statsInboundDownlink=false'
        else
            json_edit "$cfg" "$CFG_LOCK" '. + {policy:{levels:{"0":{statsUserUplink:true,statsUserDownlink:true}},system:{statsInboundUplink:false,statsInboundDownlink:false}}}'
        fi
        jq -e '.inbounds[]|select(.tag=="api")' "$cfg" >/dev/null 2>&1 \
            || json_edit "$cfg" "$CFG_LOCK" '.inbounds = [{tag:"api",listen:"127.0.0.1",port:10085,protocol:"dokodemo-door",settings:{address:"127.0.0.1"}}] + .inbounds'
        jq -e '.routing.rules[]|select(.inboundTag and (.inboundTag|contains(["api"])))' "$cfg" >/dev/null 2>&1 \
            || json_edit "$cfg" "$CFG_LOCK" '.routing.rules = [{type:"field",inboundTag:["api"],outboundTag:"direct"}] + .routing.rules'
        jq -e '.log.access' "$cfg" >/dev/null 2>&1 \
            || json_edit "$cfg" "$CFG_LOCK" '.log = ((.log // {}) + {access:"/var/log/xray/access.log",error:"/var/log/xray/error.log",loglevel:"warning"})'
        log_success "  config.json migration complete."
    fi

    log_info "Re-applying anti-torrent policy..."
    _migrate_xray_antitorrent "${XRAY_DIR}/config.json"
    apply_firewall_rules

    log_info "Reloading Xray and Nginx..."
    systemctl restart xray >/dev/null 2>&1 && log_success "Xray restarted." || log_warning "Xray restart failed."
    if nginx -t >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1 && log_success "Nginx reloaded."
    else log_warning "Nginx config test failed — NOT reloaded."; fi

    rm -rf "$snap_dir"; [[ -n "$_manifest" ]] && rm -f "$_manifest"
    log_success "Update complete. Version 4.3.0-hardened. Users/UUIDs/certs/domain UNTOUCHED."
    read -rp "Press Enter to return..." _ || true
}

# ===========================================================================
# MAIN MENU (written to /usr/bin/menu)
# ===========================================================================
_write_main_menu() {
    cat > /usr/bin/menu <<'MAINMENU'
#!/usr/bin/env bash
set -uo pipefail
CSV_DB="/usr/local/etc/xray/users.csv"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_API="127.0.0.1:10085"
XRAY_BIN="/usr/local/bin/xray"
ASX_DIR="/etc/AutoScriptX"
CSV_LOCK="/run/lock/autoscriptx-csv.lock"
CFG_LOCK="/run/lock/autoscriptx-cfg.lock"

green="\033[0;32m"; blue="\033[0;34m"; yellow="\033[1;33m"
red="\033[0;31m"; cyan="\033[0;36m"; nc="\033[0m"

validate_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
validate_domain()   { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,253}[A-Za-z0-9])?$ && "$1" != *".."* ]]; }

json_edit() {
    local file="$1" lock="$2"; shift 2
    local tmp; tmp="$(mktemp "$(dirname "$file")/.jq.XXXXXX")"
    ( flock 9
      if jq "$@" "$file" > "$tmp" && [[ -s "$tmp" ]] && jq empty "$tmp" >/dev/null 2>&1; then
          chmod 600 "$tmp"; mv -f "$tmp" "$file"
      else rm -f "$tmp"; echo "json_edit: refused invalid JSON for $file" >&2; return 1; fi
    ) 9>"$lock"
}
csv_lock()   { exec 8>"$CSV_LOCK"; flock 8; }
csv_unlock() { flock -u 8 2>/dev/null || true; }

_XRAY_VER_CACHE=""
_get_xray_ver() {
    [[ -z "$_XRAY_VER_CACHE" ]] && \
        _XRAY_VER_CACHE="$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}' || echo '?')"
    echo "$_XRAY_VER_CACHE"
}
show_header() {
    clear
    local domain uptime_str
    domain="$(cat "${ASX_DIR}/domain" 2>/dev/null || echo 'not set')"
    uptime_str="$(uptime -p 2>/dev/null || echo '?')"
    echo -e "${cyan}================================================${nc}"
    echo -e "${cyan}       AutoScriptX  v4.3.0  |  Main Menu       ${nc}"
    echo -e "${cyan}------------------------------------------------${nc}"
    printf  "  Domain  : %s\n" "$domain"
    printf  "  Xray    : %s\n" "$(_get_xray_ver)"
    printf  "  Uptime  : %s\n" "$uptime_str"
    echo -e "${cyan}================================================${nc}"
}
fmt_bytes() {
    local b="${1:-0}"; b="$(echo "$b" | tr -dc '0-9')"; b="${b:-0}"
    if   [[ $b -ge 1073741824 ]]; then printf "%.2f GB" "$(echo "scale=2;$b/1073741824"|bc)"
    elif [[ $b -ge 1048576    ]]; then printf "%.2f MB" "$(echo "scale=2;$b/1048576"|bc)"
    elif [[ $b -ge 1024       ]]; then printf "%.2f KB" "$(echo "scale=2;$b/1024"|bc)"
    else echo "${b} B"; fi
}
migrate_csv() {
    csv_lock
    local tmp; tmp="$(mktemp "$(dirname "$CSV_DB")/.csv.XXXXXX")"
    while IFS=',' read -r f1 f2 f3 f4 f5 f6 f7; do
        if [[ "$f1" == "Username" ]]; then
            echo "Username,SSHPassword,XrayUUID,TrojanPassword,ExpiryDate,LimitGB,UsedBytes"
        else
            f6="${f6:-0}"; f7="${f7:-0}"
            echo "${f1},${f2},${f3},${f4},${f5},${f6},${f7}"
        fi
    done < "$CSV_DB" > "$tmp"
    mv -f "$tmp" "$CSV_DB"; chmod 600 "$CSV_DB"
    csv_unlock
}

_add_client_by_tag() {
    local user="$1" uuid="$2" tpw="$3"
    json_edit "$XRAY_CONF" "$CFG_LOCK" --arg user "$user" --arg uuid "$uuid" --arg tpw "$tpw" '
      .inbounds |= map(
        if   (.tag|test("vless"))  and .settings.clients then .settings.clients += [{id:$uuid,flow:"",email:$user}]
        elif (.tag|test("vmess"))  and .settings.clients then .settings.clients += [{id:$uuid,alterId:0,email:$user}]
        elif (.tag|test("trojan")) and .settings.clients then .settings.clients += [{password:$tpw,email:$user}]
        else . end )'
}
repair_xhttp_clients() {
    [[ -f "$XRAY_CONF" ]] || return 0
    jq -e '.inbounds[]|select(.tag=="vless-xhttp" or .tag=="vmess-xhttp")' \
        "$XRAY_CONF" >/dev/null 2>&1 || return 0
    json_edit "$XRAY_CONF" "$CFG_LOCK" '
      (first(.inbounds[]|select(.tag=="vless-ws")|.settings.clients) // []) as $v |
      (first(.inbounds[]|select(.tag=="vmess-ws")|.settings.clients) // []) as $m |
      .inbounds |= map(
        if   .tag=="vless-xhttp" and ($v|length)>0 then .settings.clients=$v
        elif .tag=="vmess-xhttp" and ($m|length)>0 then .settings.clients=$m
        else . end )'
}

create_account() {
    show_header
    local DOMAIN PUBLIC_IP
    DOMAIN="$(cat "${ASX_DIR}/domain" 2>/dev/null || echo localhost)"
    PUBLIC_IP="$(hostname -I | awk '{print $1}')"
    local u_name u_pass days limit_gb
    if command -v gum &>/dev/null; then
        u_name="$(gum input --placeholder username --prompt 'Username: ')"
        u_pass="$(gum input --placeholder password --prompt 'Password: ')"
        days="$(gum input --placeholder 30 --prompt 'Expired (days): ')"
        limit_gb="$(gum input --placeholder '0=unlimited' --prompt 'Limit (GB): ')"
    else
        read -rp "  Username          : " u_name
        read -rp "  Password          : " u_pass
        read -rp "  Expired (days)    : " days
        read -rp "  Limit GB (0=inf)  : " limit_gb
    fi
    if ! validate_username "$u_name"; then
        echo -e "${red}Invalid username (a-z,0-9,_,- ; must start a-z/_).${nc}"; sleep 2; return
    fi
    [[ -z "$u_pass" ]] && u_pass="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
    [[ "$days" =~ ^[0-9]+$ ]] || days=30
    limit_gb="$(echo "${limit_gb:-0}" | tr -dc '0-9')"; limit_gb="${limit_gb:-0}"

    if id "$u_name" &>/dev/null; then
        echo -e "${red}  User '$u_name' already exists.${nc}"; read -rp "  Enter..." _; return
    fi
    repair_xhttp_clients

    local u_exp u_exp_fmt u_uuid u_trojan
    u_exp="$(date -d "+${days} days" +%Y-%m-%d)"
    u_exp_fmt="$(date -d "+${days} days" +'%B %d, %Y')"
    u_uuid="$(cat /proc/sys/kernel/random/uuid)"
    u_trojan="$(openssl rand -hex 20)"

    useradd -M -s /bin/false -e "$u_exp" "$u_name"
    printf '%s:%s\n' "$u_name" "$u_pass" | chpasswd
    _add_client_by_tag "$u_name" "$u_uuid" "$u_trojan"
    systemctl restart xray >/dev/null 2>&1 || true

    migrate_csv
    csv_lock
    printf '%s,%s,%s,%s,%s,%s,0\n' "$u_name" "$u_pass" "$u_uuid" "$u_trojan" "$u_exp" "$limit_gb" >> "$CSV_DB"
    chmod 600 "$CSV_DB"
    csv_unlock

    local v_b64 vxt_b64 vx_b64
    v_b64="$(printf '{"v":"2","ps":"%s-VMESS-WS","add":"%s","port":"443","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"/vmess-ws","tls":"tls"}' "$u_name" "$DOMAIN" "$u_uuid" "$DOMAIN" | base64 -w0)"
    vxt_b64="$(printf '{"v":"2","ps":"%s-VMESS-XHTTP-TLS","add":"%s","port":"443","id":"%s","aid":"0","net":"xhttp","type":"none","host":"%s","path":"/vmess-xhttp","tls":"tls"}' "$u_name" "$DOMAIN" "$u_uuid" "$DOMAIN" | base64 -w0)"
    vx_b64="$(printf '{"v":"2","ps":"%s-VMESS-XHTTP","add":"%s","port":"80","id":"%s","aid":"0","net":"xhttp","type":"none","host":"%s","path":"/vmess-xhttp","tls":""}' "$u_name" "$DOMAIN" "$u_uuid" "$DOMAIN" | base64 -w0)"

    local limit_display; [[ "$limit_gb" -eq 0 ]] && limit_display="Unlimited" || limit_display="${limit_gb} GB"
    clear
    echo -e "# SSH Account Created\n"
    echo -e "Username   : ${green}${u_name}${nc}"
    echo -e "Password   : ${green}${u_pass}${nc}"
    echo -e "Expires On : ${green}${u_exp_fmt}${nc}"
    echo -e "Public IP  : ${green}${PUBLIC_IP}${nc}"
    echo -e "Host       : ${green}${DOMAIN}${nc}"
    echo -e "BW Limit   : ${green}${limit_display}${nc}"
    echo -e "\nPorts: SSH-WS 80 | SSL-WS/TLS 443 | Squid 8080 | UDPGW 7200,7300"
    echo -e "\n${blue}-- TLS WebSocket (443) --${nc}"
    echo "vless://${u_uuid}@${DOMAIN}:443?encryption=none&flow=none&type=ws&host=${DOMAIN}&path=%2Fvless-ws&security=tls&sni=${DOMAIN}#${u_name}-VLESS-WS"
    echo "vmess://${v_b64}"
    echo "trojan://${u_trojan}@${DOMAIN}:443?type=ws&host=${DOMAIN}&path=%2Ftrojan-ws&security=tls&sni=${DOMAIN}#${u_name}-TROJAN-WS"
    echo -e "\n${blue}-- TLS xHTTP (443) --${nc}"
    echo "vless://${u_uuid}@${DOMAIN}:443?encryption=none&type=xhttp&path=%2Fvless-xhttp&security=tls&sni=${DOMAIN}&host=${DOMAIN}#${u_name}-VLESS-XHTTP-TLS"
    echo "vmess://${vxt_b64}"
    echo -e "\n${blue}-- Plain xHTTP (80, NO TLS - traffic is cleartext) --${nc}"
    echo "vless://${u_uuid}@${DOMAIN}:80?encryption=none&type=xhttp&path=%2Fvless-xhttp&security=none&host=${DOMAIN}#${u_name}-VLESS-XHTTP"
    echo "vmess://${vx_b64}"
    echo ""
    read -rp "Press Enter to return..." _ || true
}

delete_account() {
    show_header; migrate_csv
    echo -e "${blue}-- Delete Account --${nc}\n"
    if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1{f=1;exit} END{exit !f}' "$CSV_DB"; then
        echo -e "  ${yellow}No accounts.${nc}"; read -rp "  Enter..." _; return
    fi
    printf "  %-20s %-12s %-10s %-10s\n" USERNAME EXPIRY LIMIT USED
    while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
        [[ "$name" == "Username" ]] && continue
        local lstr; [[ "${limit_gb:-0}" -eq 0 ]] && lstr="Unlimited" || lstr="${limit_gb}GB"
        printf "  %-20s %-12s %-10s %-10s\n" "$name" "$exp" "$lstr" "$(fmt_bytes "${used_bytes:-0}")"
    done < "$CSV_DB"
    echo ""; read -rp "  Username to delete (Enter to cancel): " u_name
    [[ -z "$u_name" ]] && return
    validate_username "$u_name" || { echo -e "${red}  Invalid username.${nc}"; sleep 2; return; }
    if ! grep -q "^${u_name}," "$CSV_DB"; then
        echo -e "${red}  Not found.${nc}"; read -rp "  Enter..." _; return
    fi
    json_edit "$XRAY_CONF" "$CFG_LOCK" --arg user "$u_name" \
      '.inbounds |= map(if .settings.clients then .settings.clients |= map(select(.email != $user)) else . end)'
    systemctl restart xray >/dev/null 2>&1 || true
    userdel -r "$u_name" 2>/dev/null || true
    csv_lock
    local tmp; tmp="$(mktemp "$(dirname "$CSV_DB")/.csv.XXXXXX")"
    grep -v "^${u_name}," "$CSV_DB" > "$tmp" || true
    mv -f "$tmp" "$CSV_DB"; chmod 600 "$CSV_DB"
    csv_unlock
    echo -e "${green}  Account '${u_name}' deleted.${nc}"; read -rp "  Enter..." _ || true
}

list_accounts() {
    show_header; migrate_csv
    echo -e "${blue}-- Active Accounts --${nc}\n"
    if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1{f=1;exit} END{exit !f}' "$CSV_DB"; then
        echo -e "  ${yellow}No accounts.${nc}"; read -rp "  Enter..." _; return
    fi
    local today; today="$(date +%Y-%m-%d)"
    printf "  %-16s %-12s %-10s %-10s %-5s %-8s\n" USERNAME EXPIRY USED LIMIT % STATUS
    while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
        [[ "$name" == "Username" ]] && continue
        limit_gb="${limit_gb:-0}"; used_bytes="$(echo "${used_bytes:-0}"|tr -dc '0-9')"; used_bytes="${used_bytes:-0}"
        local lstr pct status
        if [[ "$limit_gb" -eq 0 ]]; then lstr="Unlimited"; pct="-"
        else lstr="${limit_gb} GB"; local lb=$(( limit_gb*1024*1024*1024 ))
             [[ $lb -gt 0 ]] && pct="$(( used_bytes*100/lb ))%" || pct="-"; fi
        if [[ "$exp" < "$today" ]]; then status="${red}Expired${nc}"
        elif [[ "$limit_gb" -gt 0 && "$used_bytes" -ge $(( limit_gb*1024*1024*1024 )) ]]; then status="${red}CAPPED${nc}"
        else status="${green}Active${nc}"; fi
        printf "  %-16s %-12s %-10s %-10s %-5s " "$name" "$exp" "$(fmt_bytes "$used_bytes")" "$lstr" "$pct"
        echo -e "$status"
    done < "$CSV_DB"
    echo ""; read -rp "Press Enter to return..." _ || true
}

_bw_reset_user() {
    read -rp "  Username to reset: " ru; [[ -z "$ru" ]] && return
    validate_username "$ru" || { echo -e "${red}  Invalid.${nc}"; sleep 2; return; }
    grep -q "^${ru}," "$CSV_DB" || { echo -e "${red}  Not found.${nc}"; sleep 2; return; }
    csv_lock
    local tmp; tmp="$(mktemp "$(dirname "$CSV_DB")/.csv.XXXXXX")"
    awk -F',' -v u="$ru" 'BEGIN{OFS=","} NR>1&&$1==u{$7=0}{print}' "$CSV_DB" > "$tmp"
    mv -f "$tmp" "$CSV_DB"; chmod 600 "$CSV_DB"
    csv_unlock
    local r_uuid r_trojan active
    r_uuid="$(awk -F',' -v u="$ru" 'NR>1&&$1==u{print $3}' "$CSV_DB")"
    r_trojan="$(awk -F',' -v u="$ru" 'NR>1&&$1==u{print $4}' "$CSV_DB")"
    active="$(jq -r --arg u "$ru" '[.inbounds[].settings.clients[]?|select(.email==$u)]|length' "$XRAY_CONF" 2>/dev/null || echo 0)"
    if [[ "${active:-0}" -eq 0 ]]; then
        # FIX (D1): re-add by TAG (matches create_account), not by protocol.
        _add_client_by_tag "$ru" "$r_uuid" "$r_trojan"
        systemctl restart xray >/dev/null 2>&1 || true
        passwd -u "$ru" >/dev/null 2>&1 || true
    fi
    echo -e "${green}  Usage reset; '${ru}' reactivated.${nc}"; sleep 2
}
_bw_set_limit() {
    read -rp "  Username: " tu; [[ -z "$tu" ]] && return
    validate_username "$tu" || { echo -e "${red}  Invalid.${nc}"; sleep 2; return; }
    grep -q "^${tu}," "$CSV_DB" || { echo -e "${red}  Not found.${nc}"; sleep 2; return; }
    read -rp "  New limit GB (0=unlimited): " nl
    nl="$(echo "${nl:-0}"|tr -dc '0-9')"; nl="${nl:-0}"
    csv_lock
    local tmp; tmp="$(mktemp "$(dirname "$CSV_DB")/.csv.XXXXXX")"
    awk -F',' -v u="$tu" -v l="$nl" 'BEGIN{OFS=","} NR>1&&$1==u{$6=l}{print}' "$CSV_DB" > "$tmp"
    mv -f "$tmp" "$CSV_DB"; chmod 600 "$CSV_DB"
    csv_unlock
    echo -e "${green}  Limit for '${tu}' = ${nl} GB.${nc}"; sleep 2
}
bandwidth_monitor() {
    while true; do
        show_header; migrate_csv
        echo -e "${blue}-- Bandwidth Monitor --${nc}\n"
        if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1{f=1;exit} END{exit !f}' "$CSV_DB"; then
            echo -e "  ${yellow}No accounts.${nc}"; read -rp "  Enter..." _; return
        fi
        printf "  %-16s %-10s %-10s %-6s %-10s\n" USERNAME USED LIMIT % STATUS
        while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
            [[ "$name" == "Username" ]] && continue
            limit_gb="${limit_gb:-0}"; used_bytes="$(echo "${used_bytes:-0}"|tr -dc '0-9')"; used_bytes="${used_bytes:-0}"
            local lstr pct status
            if [[ "$limit_gb" -eq 0 ]]; then lstr="Unlimited"; pct="-"; status="${green}Active${nc}"
            else lstr="${limit_gb} GB"; local lb=$(( limit_gb*1024*1024*1024 )) p=0
                 [[ $lb -gt 0 ]] && p=$(( used_bytes*100/lb )); pct="${p}%"
                 if   [[ $used_bytes -ge $lb ]]; then status="${red}CAPPED${nc}"
                 elif [[ $p -ge 80 ]]; then status="${yellow}Warning${nc}"
                 else status="${green}Active${nc}"; fi; fi
            printf "  %-16s %-10s %-10s %-6s " "$name" "$(fmt_bytes "$used_bytes")" "$lstr" "$pct"
            echo -e "$status"
        done < "$CSV_DB"
        echo -e "\n  ${green}r)${nc} Reset  ${green}s)${nc} Set limit  ${green}0)${nc} Back\n"
        read -rp "  Select: " o
        case "$o" in r|R) _bw_reset_user;; s|S) _bw_set_limit;; 0) return;; *) sleep 1;; esac
    done
}

service_status() {
    show_header; echo -e "${blue}-- Service Status --${nc}\n"
    local svc
    for svc in xray nginx dropbear stunnel4 squid fail2ban ws-proxy xray-limit-monitor asx-torrent-watch; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then echo -e "  ${green}[on ]${nc} $svc"
        else echo -e "  ${red}[off]${nc} $svc"; fi
    done
    echo ""; read -rp "Press Enter to return..." _ || true
}
restart_services() {
    show_header; echo -e "${blue}Restarting services...${nc}\n"
    local svc
    for svc in xray nginx dropbear stunnel4 squid fail2ban xray-limit-monitor asx-torrent-watch; do
        systemctl restart "$svc" >/dev/null 2>&1 && echo -e "  ${green}[ok]${nc} $svc" \
            || echo -e "  ${yellow}[!!]${nc} $svc"
    done
    echo ""; read -rp "Press Enter to return..." _ || true
}
system_info() {
    show_header; echo -e "${blue}-- System Info --${nc}\n"
    echo -e "  OS     : $(grep PRETTY_NAME /etc/os-release 2>/dev/null|cut -d= -f2|tr -d '\"')"
    echo -e "  Kernel : $(uname -r)"
    echo -e "  CPU    : $(nproc) core(s)"
    echo -e "  RAM    : $(free -h|awk '/^Mem/{print $3" used / "$2" total"}')"
    echo -e "  Disk   : $(df -h /|awk 'NR==2{print $3" used / "$2" ("$5")"}')"
    local lip pip; lip="$(hostname -I|awk '{print $1}')"
    pip="$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || echo "$lip")"
    echo -e "  IP     : $pip"
    echo -e "  Domain : $(cat "${ASX_DIR}/domain" 2>/dev/null || echo 'not set')"
    echo -e "  Uptime : $(uptime -p 2>/dev/null)"
    echo ""; read -rp "Press Enter to return..." _ || true
}
change_domain() {
    show_header; echo -e "${blue}-- Change Domain --${nc}\n"
    echo -e "  Current: $(cat "${ASX_DIR}/domain" 2>/dev/null || echo 'not set')\n"
    read -rp "  New domain (Enter to cancel): " nd
    nd="$(printf '%s' "$nd" | tr -d '[:space:]')"
    [[ -z "$nd" ]] && { echo -e "  ${yellow}Cancelled.${nc}"; read -rp "  Enter..." _; return; }
    validate_domain "$nd" || { echo -e "${red}  Invalid domain.${nc}"; read -rp "  Enter..." _; return; }
    printf '%s\n' "$nd" > "${ASX_DIR}/domain"
    local esc; esc="$(printf '%s' "$nd" | sed 's/[&/\]/\\&/g')"
    sed -i "s|server_name .*;|server_name ${esc};|g" /etc/nginx/conf.d/reverse-proxy.conf 2>/dev/null || true
    sed -i "s|server_name .*;|server_name ${esc};|g" /etc/nginx/conf.d/xhttp-port80.conf  2>/dev/null || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    echo -e "\n  ${green}Domain updated to ${nd}.${nc}"; read -rp "  Enter..." _ || true
}
edit_banner() {
    show_header; local bf="${ASX_DIR}/banner"
    echo -e "${blue}-- Edit SSH Banner --${nc}\n"; cat "$bf" 2>/dev/null || echo "(empty)"
    echo -e "\n  ${green}1)${nc} Edit  ${green}2)${nc} Clear  ${green}0)${nc} Cancel"
    read -rp "  Select: " c
    case "$c" in
        1) nano "$bf"; systemctl restart dropbear >/dev/null 2>&1 || true; echo -e "${green}Updated.${nc}";;
        2) : > "$bf"; systemctl restart dropbear >/dev/null 2>&1 || true; echo -e "${green}Cleared.${nc}";;
        *) echo -e "${yellow}Cancelled.${nc}";;
    esac
    read -rp "  Enter..." _ || true
}
edit_response() {
    show_header; local rf="${ASX_DIR}/response"
    echo -e "${blue}-- Edit 101 WebSocket Response --${nc}\n"
    [[ -s "$rf" ]] || printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n' > "$rf"
    echo -e "  Current (^M = CRLF):"; cat -A "$rf" 2>/dev/null
    echo -e "\n  ${green}1)${nc} Edit  ${green}2)${nc} Reset default  ${green}3)${nc} ws-proxy status  ${green}0)${nc} Cancel"
    read -rp "  Select: " c
    case "$c" in
        1) local b a; b="$(md5sum "$rf")"; nano "$rf"; a="$(md5sum "$rf")"
           [[ "$b" != "$a" ]] && { systemctl restart ws-proxy.service 2>/dev/null && echo -e "${green}Saved.${nc}"; } || echo "No change.";;
        2) printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n' > "$rf"
           chmod 644 "$rf"; systemctl restart ws-proxy.service 2>/dev/null && echo -e "${green}Reset.${nc}";;
        3) systemctl status ws-proxy.service --no-pager -l 2>/dev/null | tail -12;;
        *) echo -e "${yellow}Cancelled.${nc}";;
    esac
    read -rp "  Enter..." _ || true
}
do_update() {
    show_header
    echo -e "${blue}Self-update from the SAME repository as this install.${nc}"
    echo -e "Source: ${yellow}__SELF_UPDATE_URL__${nc}\n"
    read -rp "Type UPDATE to proceed: " c
    [[ "$c" == "UPDATE" ]] || { echo "Cancelled."; read -rp "Enter..." _; return; }
    local up; up="$(mktemp /root/.asx_upd.XXXXXX.sh)"
    if curl -fsSL -H "User-Agent: AutoScriptX-Deployment" --max-time 30 "__SELF_UPDATE_URL__" -o "$up"; then
        chmod +x "$up"; bash "$up" --update-only; rm -f "$up"
    else echo -e "${red}Fetch failed.${nc}"; rm -f "$up"; fi
    read -rp "Press Enter to return..." _ || true
}
torrent_guard() {
    show_header; echo -e "${blue}-- Torrent Guard --${nc}\n"
    local conf="${ASX_DIR}/antitorrent.conf" autos
    autos="$(awk -F= '/^AUTOSUSPEND=/{print $2}' "$conf" 2>/dev/null | tail -1)"; autos="${autos:-0}"
    if systemctl is-active --quiet asx-torrent-watch 2>/dev/null; then
        echo -e "  Watchdog     : ${green}running${nc}"
    else
        echo -e "  Watchdog     : ${red}stopped${nc}"
    fi
    if iptables -nL ASX-TORRENT-IN >/dev/null 2>&1; then
        echo -e "  Packet filter: ${green}loaded${nc}"
    else
        echo -e "  Packet filter: ${red}missing${nc}  (run: install.sh --antitorrent-only)"
    fi
    if jq -e '[.routing.rules[]?|select((.protocol//[])|index("bittorrent"))]|length>0' "$XRAY_CONF" >/dev/null 2>&1 \
       && jq -e '[.inbounds[]?|select(.tag!="api" and (.sniffing.enabled//false))]|length>0' "$XRAY_CONF" >/dev/null 2>&1; then
        echo -e "  Xray policy  : ${green}active (sniffing on)${nc}"
    else
        echo -e "  Xray policy  : ${red}incomplete${nc}"
    fi
    echo -e "  Auto-suspend : ${autos} (1 = suspend offenders, 0 = log only)"

    echo -e "\n  ${blue}Kernel drops (non-zero counters):${nc}"
    { iptables -nvL ASX-TORRENT-IN  2>/dev/null | awk 'NR>2 && $1+0>0 {print "   IN  "$1" pkts  "$3" "$4}';
      iptables -nvL ASX-TORRENT-OUT 2>/dev/null | awk 'NR>2 && $1+0>0 {print "   OUT "$1" pkts  "$3" "$4}'; } | head -14
    echo -e "\n  ${blue}Xray P2P blocks per account (current window):${nc}"
    if [[ -s /var/lib/AutoScriptX/torrent-hits.csv ]]; then
        awk -F',' '{printf "   %-20s %s hits\n", $1, $3}' /var/lib/AutoScriptX/torrent-hits.csv | head -15
    else
        echo "   (none recorded)"
    fi
    echo -e "\n  ${green}1)${nc} Toggle auto-suspend  ${green}2)${nc} Zero kernel counters  ${green}3)${nc} Clear hit records  ${green}0)${nc} Back"
    read -rp "  Select: " c
    case "$c" in
        1) if [[ "$autos" == "1" ]]; then sed -i 's/^AUTOSUSPEND=.*/AUTOSUSPEND=0/' "$conf"
           else sed -i 's/^AUTOSUSPEND=.*/AUTOSUSPEND=1/' "$conf"; fi
           systemctl restart asx-torrent-watch >/dev/null 2>&1 || true
           echo -e "  ${green}Policy updated.${nc}";;
        2) iptables -Z ASX-TORRENT-IN >/dev/null 2>&1 || true
           iptables -Z ASX-TORRENT-OUT >/dev/null 2>&1 || true
           echo -e "  ${green}Counters zeroed.${nc}";;
        3) : > /var/lib/AutoScriptX/torrent-hits.csv 2>/dev/null || true
           echo -e "  ${green}Hit records cleared.${nc}";;
        *) ;;
    esac
    read -rp "  Enter..." _ || true
}
full_uninstall() {
    [[ -t 0 ]] || { echo "Uninstall requires an interactive TTY."; return 1; }
    clear
    echo -e "${red}=== AutoScriptX FULL UNINSTALL ===${nc}"
    echo -e "Removes Xray, all accounts, nginx/dropbear/squid/stunnel/fail2ban configs,"
    echo -e "badvpn, ws-proxy, gum, monitor, cron jobs, iptables rules, and script dirs."
    echo -e "Core OS tools, SSH host keys, and SSL certs are kept.\n"
    read -rp "  STEP 1/2 - type UNINSTALL to continue: " c1
    [[ "$c1" == "UNINSTALL" ]] || { echo -e "${green}Aborted.${nc}"; read -rp "Enter..." _; return 0; }
    read -rp "  STEP 2/2 - type YES to begin: " c2
    [[ "$c2" == "YES" ]] || { echo -e "${green}Aborted.${nc}"; read -rp "Enter..." _; return 0; }

    local svc
    for svc in xray xray-limit-monitor asx-torrent-watch ws-proxy nginx dropbear stunnel4 squid fail2ban \
               badvpn-udpgw@7200 badvpn-udpgw@7300 netfilter-persistent; do
        systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
    done
    rm -rf /etc/systemd/system/xray.service /etc/systemd/system/xray-limit-monitor.service \
           /etc/systemd/system/ws-proxy.service /etc/systemd/system/badvpn-udpgw@.service \
           /etc/systemd/system/nginx.service.d
    systemctl daemon-reload >/dev/null 2>&1 || true
    apt-get purge -y stunnel4 dropbear squid fail2ban nginx \
        netfilter-persistent iptables-persistent vnstat >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
    rm -f /usr/local/bin/xray /usr/local/bin/geoip.dat /usr/local/bin/geosite.dat
    rm -rf /usr/local/etc/xray /var/log/xray /etc/AutoScriptX /home/vps/public_html /root/.acme.sh
    rmdir /home/vps 2>/dev/null || true
    rm -f /etc/nginx/xray-locations.conf /etc/nginx/conf.d/xhttp-port80.conf \
          /etc/nginx/conf.d/reverse-proxy.conf /etc/nginx/conf.d/real_ip_sources.conf
    rm -f /usr/local/bin/ws-proxy /usr/local/bin/xray-limit-monitor /usr/local/bin/gum \
          /usr/bin/badvpn-udpgw /usr/local/bin/asx-torrent-watch
    rm -f /etc/systemd/system/asx-torrent-watch.service
    rm -rf /var/lib/AutoScriptX
    rm -f /usr/bin/menu /usr/bin/autoscriptx /usr/bin/asx /usr/bin/xray-menu /usr/bin/slowdns-menu \
          /usr/bin/create-account /usr/bin/delete-account /usr/bin/edit-banner /usr/bin/edit-response \
          /usr/bin/lock-unlock /usr/bin/renew-account /usr/bin/change-domain /usr/bin/manage-services \
          /usr/bin/system-info /usr/bin/clean-expired-accounts /usr/bin/setup-slowdns /usr/bin/slowdns-status
    rm -f /etc/cron.d/auto-reboot /etc/cron.d/clean-expired-accounts
    service cron restart >/dev/null 2>&1 || true
    local s
    for s in get_peers announce_peer find_node BitTorrent "BitTorrent protocol" "peer_id=" \
             ".torrent" "announce.php?passkey=" torrent announce info_hash; do
        while iptables -D FORWARD -m string --string "$s" --algo bm -j DROP >/dev/null 2>&1; do :; done
    done
    local ch hook
    for hook in INPUT FORWARD OUTPUT; do
        for ch in ASX-TORRENT-IN ASX-TORRENT-OUT; do
            while iptables -D "$hook" -j "$ch" >/dev/null 2>&1; do :; done
            while ip6tables -D "$hook" -j "$ch" >/dev/null 2>&1; do :; done
        done
    done
    for ch in ASX-TORRENT-IN ASX-TORRENT-OUT ASX-TORRENT-DROP-IN ASX-TORRENT-DROP-OUT; do
        iptables  -F "$ch" >/dev/null 2>&1 || true; iptables  -X "$ch" >/dev/null 2>&1 || true
        ip6tables -F "$ch" >/dev/null 2>&1 || true; ip6tables -X "$ch" >/dev/null 2>&1 || true
    done
    iptables -D INPUT -p tcp --dport 80  -j ACCEPT >/dev/null 2>&1 || true
    iptables -D INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || true
    rm -f /etc/iptables.up.rules
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    rm -f /etc/sysctl.d/99-disable-ipv6.conf; sysctl --system >/dev/null 2>&1 || true
    rm -f /etc/stunnel/key.pem /etc/stunnel/cert.pem /etc/stunnel/stunnel.pem
    rm -f /etc/fail2ban/filter.d/xray-auth.conf /etc/fail2ban/filter.d/asx-torrent.conf \
          /etc/fail2ban/jail.local
    echo -e "\n${red}Uninstall complete. Reboot recommended.${nc}"
    read -rp "  Reboot now? (y/N): " r
    [[ "$r" =~ ^[Yy]$ ]] && reboot || echo "Reboot skipped."
}

while true; do
    show_header
    echo -e "\n  ${green}1)${nc} Create Account   ${green}2)${nc} Delete Account   ${green}3)${nc} List Accounts"
    echo -e "  ${green}4)${nc} Service Status   ${green}5)${nc} Restart Services ${green}6)${nc} System Info"
    echo -e "  ${green}7)${nc} Change Domain    ${green}8)${nc} Edit Banner      ${green}9)${nc} Edit 101 Response"
    echo -e "  ${cyan}b)${nc} Bandwidth Monitor ${cyan}t)${nc} Torrent Guard"
    echo -e "  ${yellow}u)${nc} Update           ${red}x)${nc} Uninstall        ${red}0)${nc} Exit\n"
    read -rp "Select option: " opt
    case "$opt" in
        1) create_account;; 2) delete_account;; 3) list_accounts;;
        4) service_status;; 5) restart_services;; 6) system_info;;
        7) change_domain;; 8) edit_banner;; 9) edit_response;;
        b|B) bandwidth_monitor;; t|T) torrent_guard;;
        u|U) do_update;; x|X) full_uninstall;;
        0) exit 0;; *) echo -e "${red}Invalid.${nc}"; sleep 1;;
    esac
done
MAINMENU
    sed -i "s|__SELF_UPDATE_URL__|${SELF_UPDATE_URL//|/\\|}|g" /usr/bin/menu
    chmod 0755 /usr/bin/menu
}

# ===========================================================================
# LIMIT MONITOR DAEMON
# ===========================================================================
_write_limit_monitor() {
    cat > /usr/local/bin/xray-limit-monitor <<'MONITOR_SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
CSV_DB="/usr/local/etc/xray/users.csv"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_API="127.0.0.1:10085"
XRAY_BIN="/usr/local/bin/xray"
CSV_LOCK="/run/lock/autoscriptx-csv.lock"
CFG_LOCK="/run/lock/autoscriptx-cfg.lock"

query_user_bytes() {
    local u="$1" stats total
    stats="$("$XRAY_BIN" api statsquery --server="$XRAY_API" --reset \
        -pattern "user>>>${u}>>>traffic" 2>/dev/null || true)"
    total="$(echo "$stats" | jq -r '[.stat[]?|.value // "0"|tonumber]|add // 0' 2>/dev/null || echo 0)"
    echo "${total:-0}"
}
user_is_active() {
    jq -e --arg u "$1" '[.inbounds[].settings.clients[]?|select(.email==$u)]|length>0' \
        "$XRAY_CONF" >/dev/null 2>&1
}
suspend_user() {
    local u="$1" lim="$2" tmp
    tmp="$(mktemp "$(dirname "$XRAY_CONF")/.jq.XXXXXX")"
    ( flock 9
      if jq --arg user "$u" '.inbounds |= map(if .settings.clients then .settings.clients |= map(select(.email != $user)) else . end)' \
           "$XRAY_CONF" > "$tmp" && [[ -s "$tmp" ]] && jq empty "$tmp" >/dev/null 2>&1; then
          chmod 600 "$tmp"; mv -f "$tmp" "$XRAY_CONF"
      else rm -f "$tmp"; fi
    ) 9>"$CFG_LOCK"
    systemctl restart xray >/dev/null 2>&1 || true
    passwd -l "$u" >/dev/null 2>&1 || true
    logger "xray-limit-monitor: ${u} suspended - ${lim}GB reached."
}

while true; do
    [[ -f "$CSV_DB" ]] || { sleep 60; continue; }
    exec 8>"$CSV_LOCK"; flock 8
    tmp_csv="$(mktemp "$(dirname "$CSV_DB")/.csv.XXXXXX")"
    head -1 "$CSV_DB" > "$tmp_csv"
    while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
        [[ "$name" == "Username" ]] && continue
        limit_gb="${limit_gb:-0}"; used_bytes="${used_bytes:-0}"
        if [[ "$limit_gb" =~ ^[0-9]+$ && "$limit_gb" -gt 0 ]]; then
            fresh="$(query_user_bytes "$name")"
            [[ "$fresh" =~ ^[0-9]+$ && "$fresh" -gt 0 ]] && used_bytes=$(( used_bytes + fresh ))
            limit_bytes=$(( limit_gb*1024*1024*1024 ))
            if [[ "$used_bytes" -ge "$limit_bytes" ]] && user_is_active "$name"; then
                suspend_user "$name" "$limit_gb"
            fi
        fi
        echo "${name},${pass},${uuid},${trojan},${exp},${limit_gb},${used_bytes}" >> "$tmp_csv"
    done < "$CSV_DB"
    mv -f "$tmp_csv" "$CSV_DB"; chmod 600 "$CSV_DB"
    flock -u 8; exec 8>&-
    sleep 60
done
MONITOR_SCRIPT
    chmod 0755 /usr/local/bin/xray-limit-monitor

    cat > /etc/systemd/system/xray-limit-monitor.service <<'MONITOR_SVC'
[Unit]
Description=AutoScriptX Bandwidth Limit Monitor
After=xray.service
Requires=xray.service

[Service]
Type=simple
ExecStart=/usr/local/bin/xray-limit-monitor
Restart=always
RestartSec=10
CPUQuota=10%
MemoryMax=64M
Nice=10

[Install]
WantedBy=multi-user.target
MONITOR_SVC

    systemctl daemon-reload              >/dev/null 2>&1 || true
    systemctl enable xray-limit-monitor  >/dev/null 2>&1 || true
    systemctl restart xray-limit-monitor >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Anti-torrent policy inside Xray (application layer)
# ---------------------------------------------------------------------------
_at_routing_rules_json() {
    cat <<'ATRULES'
[
 {"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},
 {"type":"field","ip":["geoip:private"],"outboundTag":"blocked"},
 {"type":"field","port":"6881-6999,51413,6969,2710,1337","outboundTag":"blocked"},
 {"type":"field","outboundTag":"blocked","domain":[
   "keyword:torrent","keyword:tracker.","keyword:announce.","keyword:btih",
   "domain:thepiratebay.org","domain:1337x.to","domain:rarbg.to","domain:nyaa.si",
   "domain:yts.mx","domain:opentrackr.org","domain:openbittorrent.com",
   "domain:coppersurfer.tk","domain:leechers-paradise.org","domain:exodus.desync.com",
   "domain:demonii.si","domain:torrent.eu.org","domain:gbitt.info"]}
]
ATRULES
}

# Idempotent: safe to run on a fresh config or on an upgrade.
_migrate_xray_antitorrent() {
    local cfg="${1:-${XRAY_DIR}/config.json}" rules
    [[ -f "$cfg" ]] || return 0
    rules="$(_at_routing_rules_json)"
    if json_edit "$cfg" "$CFG_LOCK" --argjson atrules "$rules" '
        # 1. protocol:["bittorrent"] only ever matches when sniffing is ON.
        #    Without this the original block rule was dead configuration.
        .inbounds |= map(
            if (.tag // "") != "api"
            then .sniffing = {enabled:true,destOverride:["http","tls","quic"],
                              metadataOnly:false,routeOnly:false}
            else . end)
        # 2. domain rules need IPIfNonMatch to also catch raw-IP peers.
        | .routing = ((.routing // {}) + {domainStrategy:"IPIfNonMatch"})
        # 3. rebuild the blocked ruleset, preserve every other rule (api, etc).
        | .routing.rules = ([ (.routing.rules // [])[] | select(.outboundTag != "blocked") ] + $atrules)
        # 4. guarantee the blackhole outbound exists.
        | .outbounds = (if ([ (.outbounds // [])[] | select(.tag == "blocked") ] | length) == 0
                        then ((.outbounds // []) + [{tag:"blocked",protocol:"blackhole"}])
                        else .outbounds end)'; then
        log_success "Xray anti-torrent policy applied (sniffing + protocol/port/domain blocks)."
    else
        log_warning "Could not apply the Xray anti-torrent policy to ${cfg}."
    fi
}

# ---------------------------------------------------------------------------
# Anti-torrent watchdog: correlates Xray's own "blocked" verdicts per account.
# Log-only by default; set AUTOSUSPEND=1 in /etc/AutoScriptX/antitorrent.conf
# to cut off repeat offenders automatically.
# ---------------------------------------------------------------------------
_write_torrent_watchdog() {
    mkdir -p /var/lib/AutoScriptX "$ASX_DIR"
    if [[ ! -f "${ASX_DIR}/antitorrent.conf" ]]; then
        cat > "${ASX_DIR}/antitorrent.conf" <<'ATCONF'
# AutoScriptX anti-torrent policy
# AUTOSUSPEND=1 -> suspend an account after THRESHOLD blocked P2P attempts
#                 inside WINDOW seconds. 0 -> log only (default).
AUTOSUSPEND=0
THRESHOLD=200
WINDOW=3600
ATCONF
        chmod 600 "${ASX_DIR}/antitorrent.conf"
    fi

    cat > /usr/local/bin/asx-torrent-watch <<'TORRENTWATCH'
#!/usr/bin/env bash
set -uo pipefail
ASX_DIR="/etc/AutoScriptX"
CONF="${ASX_DIR}/antitorrent.conf"
ACCESS_LOG="/var/log/xray/access.log"
XRAY_CONF="/usr/local/etc/xray/config.json"
CFG_LOCK="/run/lock/autoscriptx-cfg.lock"
STATE_DIR="/var/lib/AutoScriptX"
OFFSET_FILE="${STATE_DIR}/torrent.offset"
HITS_FILE="${STATE_DIR}/torrent-hits.csv"   # email,window_start,count
AUTOSUSPEND=0; THRESHOLD=200; WINDOW=3600

mkdir -p "$STATE_DIR"; touch "$HITS_FILE"; chmod 600 "$HITS_FILE"

suspend_user() {
    local u="$1" tmp
    tmp="$(mktemp "$(dirname "$XRAY_CONF")/.jq.XXXXXX")"
    ( flock 9
      if jq --arg user "$u" '.inbounds |= map(if .settings.clients then .settings.clients |= map(select(.email != $user)) else . end)' \
           "$XRAY_CONF" > "$tmp" && [[ -s "$tmp" ]] && jq empty "$tmp" >/dev/null 2>&1; then
          chmod 600 "$tmp"; mv -f "$tmp" "$XRAY_CONF"
      else rm -f "$tmp"; return 1; fi
    ) 9>"$CFG_LOCK" || return 1
    passwd -l "$u" >/dev/null 2>&1 || true
    systemctl restart xray >/dev/null 2>&1 || true
}

while true; do
    [[ -r "$CONF" ]] && . "$CONF"
    if [[ -r "$ACCESS_LOG" ]]; then
        size="$(stat -c %s "$ACCESS_LOG" 2>/dev/null || echo 0)"
        offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
        [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
        (( offset > size )) && offset=0          # log was rotated
        if (( size > offset )); then
            now="$(date +%s)"
            printf '%s\n' "$size" > "$OFFSET_FILE"
            tail -c "+$((offset + 1))" "$ACCESS_LOG" 2>/dev/null | head -c "$((size - offset))" \
              | grep -F '>> blocked]' \
              | sed -n 's/.*email: *\([A-Za-z0-9_.-]\{1,32\}\).*/\1/p' \
              | sort | uniq -c \
              | while read -r cnt email; do
                    [[ -n "$email" && "$cnt" =~ ^[0-9]+$ ]] || continue
                    start="$(awk -F',' -v u="$email" '$1==u{print $2}' "$HITS_FILE" | tail -1)"
                    prev="$(awk -F',' -v u="$email" '$1==u{print $3}' "$HITS_FILE" | tail -1)"
                    [[ "$start" =~ ^[0-9]+$ ]] || start="$now"
                    [[ "$prev"  =~ ^[0-9]+$ ]] || prev=0
                    if (( now - start > WINDOW )); then start="$now"; prev=0; fi
                    total=$(( prev + cnt ))
                    grep -v "^${email}," "$HITS_FILE" > "${HITS_FILE}.tmp" 2>/dev/null || true
                    printf '%s,%s,%s\n' "$email" "$start" "$total" >> "${HITS_FILE}.tmp"
                    mv -f "${HITS_FILE}.tmp" "$HITS_FILE"; chmod 600 "$HITS_FILE"
                    if (( total >= THRESHOLD )); then
                        logger -t asx-torrent "account ${email}: ${total} blocked P2P attempts in window"
                        if [[ "${AUTOSUSPEND:-0}" == "1" ]]; then
                            if suspend_user "$email"; then
                                logger -t asx-torrent "account ${email} SUSPENDED by torrent policy"
                            fi
                            grep -v "^${email}," "$HITS_FILE" > "${HITS_FILE}.tmp" 2>/dev/null || true
                            mv -f "${HITS_FILE}.tmp" "$HITS_FILE"; chmod 600 "$HITS_FILE"
                        fi
                    fi
                done
        fi
    fi
    sleep 120
done
TORRENTWATCH
    chmod 0755 /usr/local/bin/asx-torrent-watch

    cat > /etc/systemd/system/asx-torrent-watch.service <<'ATSVC'
[Unit]
Description=AutoScriptX Anti-Torrent Watchdog
After=xray.service
Wants=xray.service

[Service]
Type=simple
ExecStart=/usr/local/bin/asx-torrent-watch
Restart=always
RestartSec=15
CPUQuota=5%
MemoryMax=48M
Nice=10

[Install]
WantedBy=multi-user.target
ATSVC

    systemctl daemon-reload             >/dev/null 2>&1 || true
    systemctl enable asx-torrent-watch  >/dev/null 2>&1 || true
    systemctl restart asx-torrent-watch >/dev/null 2>&1 || true
}

install_scripts() {
    log_info "Installing scripts..."
    load_manifest
    declare -A script_dirs=(
        [menu]="slowdns-menu.sh"
        [ssh]="create-account.sh delete-account.sh edit-banner.sh edit-response.sh lock-unlock.sh renew-account.sh"
        [system]="change-domain.sh manage-services.sh system-info.sh clean-expired-accounts.sh setup-slowdns.sh slowdns-status.sh"
    )
    local dir sc base
    local -a _sc_list
    for dir in "${!script_dirs[@]}"; do
        # FIX: split on whitespace regardless of global IFS=$'\n\t'.
        read -r -a _sc_list <<< "${script_dirs[$dir]}"
        for sc in "${_sc_list[@]}"; do
            base="${sc%.sh}"
            fetch "$BASE_URL/scripts/$dir/$sc" "/usr/bin/${base}" \
                && chmod +x "/usr/bin/${base}" || log_warning "Optional script unavailable: $sc"
        done
    done
    if [[ -s /usr/bin/manage-services ]]; then
        sed -i -e 's/x-ui\.service/xray.service/g' -e 's/x-ui/xray/g' \
               -e 's/X-UI/Xray/g' -e 's/XUI Watcher/Xray Watcher/g' -e 's/XUI/Xray/g' \
               /usr/bin/manage-services
    fi
    if [[ -s /usr/bin/create-account ]]; then
        sed -i -e 's/\.protocol == "vless"/(.tag | test("vless"))/g' \
               -e 's/\.protocol == "vmess"/(.tag | test("vmess"))/g' \
               -e 's/\.protocol == "trojan"/(.tag | test("trojan"))/g' \
               /usr/bin/create-account
        log_success "create-account patched: xhttp tag-match fix applied."
    fi
    _write_main_menu; rm -f /usr/bin/xray-menu
    _write_limit_monitor
    _write_torrent_watchdog
    fetch "$BASE_URL/uninstall.sh" "${ASX_DIR}/uninstall.sh" \
        && chmod +x "${ASX_DIR}/uninstall.sh" || log_warning "Optional uninstall.sh unavailable."
    [[ -n "$_manifest" ]] && rm -f "$_manifest" || true
    log_success "Scripts installed."
}

setup_cron_jobs() {
    log_info "Setting up cron jobs..."
    fetch "$BASE_URL/service/cron/auto-reboot"            /etc/cron.d/auto-reboot            || log_error "Failed: auto-reboot."
    fetch "$BASE_URL/service/cron/clean-expired-accounts" /etc/cron.d/clean-expired-accounts || log_error "Failed: clean-expired-accounts."
    chmod 644 /etc/cron.d/auto-reboot /etc/cron.d/clean-expired-accounts 2>/dev/null || true
    service cron restart >/dev/null 2>&1 || true
    log_success "Cron jobs set up."
}

final_cleanup() {
    log_info "Final cleanup..."
    chown -R www-data:www-data /home/vps/public_html 2>/dev/null || true
    grep -qxF 'unset HISTFILE' /etc/profile || echo 'unset HISTFILE' >> /etc/profile
    local link
    for link in autoscriptx asx; do ln -sf /usr/bin/menu "/usr/bin/$link"; done
    log_success "Final cleanup done."
}

# ===========================================================================
# ENTRY POINT
# ===========================================================================
usage() {
    cat <<USAGE
AutoScriptX installer (hardened)
  (no args)        Full install
  --update-only    Non-destructive update of scripts/config (preserves users)
  --verify-only    Check the live repo against SHA256SUMS (pre-release; no root)
  --antitorrent-only
                   Re-apply firewall + Xray anti-torrent enforcement only
  --help           This message
USAGE
}

main() {
    case "${1:-}" in
        --help|-h) usage; return 0 ;;
        --verify-only) verify_release; return 0 ;;
    esac

    check_root
    mkdir -p /run/lock

    case "${1:-}" in
        --update-only)
            log_info "Running in UPDATE-ONLY mode."
            update_script
            return 0 ;;
        --antitorrent-only)
            log_info "Re-applying anti-torrent enforcement only."
            apply_firewall_rules
            _migrate_xray_antitorrent "${XRAY_DIR}/config.json"
            _write_torrent_watchdog
            systemctl restart xray >/dev/null 2>&1 || log_warning "Xray restart failed."
            log_success "Anti-torrent enforcement refreshed."
            return 0 ;;
        "") ;;
        *) usage; die "Unknown option: ${1}" ;;
    esac

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
    log_success "Installation complete! AutoScriptX v4.3.0-hardened."
    log_success "Run 'autoscriptx' or 'asx' to start."
}

main "$@"
