#!/usr/bin/env bash
# =============================================================================
# AutoScriptX Hybrid — Hardened Release
# Version : 4.4.3-hardened (xHTTP + WS + VLESS Reality + ShadowTLS, live-config generator, SNI gate)
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
# Capability-tiered theme. Collapses to plain text on dumb terminals, pipes,
# or when NO_COLOR is set, so install logs stay readable over bad SSH links.
_asx_theme_init() {
    local tiers=0
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        tiers="$(tput colors 2>/dev/null || echo 8)"
        [[ "$tiers" =~ ^[0-9]+$ ]] || tiers=8
    fi
    if (( tiers >= 8 )); then
        g0=$'\033[2;32m'; g1=$'\033[0;32m'; g2=$'\033[1;32m'
        gy=$'\033[1;33m'; gr=$'\033[1;31m'; gw=$'\033[1;37m'; nc=$'\033[0m'
        if (( tiers >= 256 )); then
            g0=$'\033[38;5;22m'; g1=$'\033[38;5;40m'; g2=$'\033[38;5;46m'
        fi
    else
        g0=""; g1=""; g2=""; gy=""; gr=""; gw=""; nc=""
    fi
}
g0=""; g1=""; g2=""; gy=""; gr=""; gw=""; nc=""
GL_OK="OK"; GL_INFO="::"; GL_WARN="!!"; GL_ERR="xx"; GL_STEP=">>"
_asx_theme_init

# Legacy aliases: every pre-existing echo in this script still resolves.
green="$g1"; blue="$g0"; red="$gr"; yellow="$gy"; cyan="$g2"

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
# VLESS Reality (public TCP) + ShadowTLS front + local VLESS backend
readonly PORT_VLESS_REALITY=8443
readonly PORT_SHADOWTLS=8444
readonly PORT_VLESS_STLS=10007
readonly SHADOWTLS_BIN="/usr/local/bin/shadow-tls"
readonly SHADOWTLS_ENV="${XRAY_DIR}/shadowtls.env"
# Primary camouflage / SNI destination for Reality + ShadowTLS handshakes
# Reality dest MUST be a real TLS 1.3 host reachable from the VPS whose TLS
# certificate record fits Reality's handshake copy buffer. www.microsoft.com
# FAILS on 2026-era Xray (oversized OCSP-stapled cert record → handshake reset).
# www.cloudflare.com is the proven-good default. Change via menu → r → option 5.
readonly REALITY_SNI="www.cloudflare.com"
readonly REALITY_DEST="www.cloudflare.com:443"
readonly REALITY_FLOW="xtls-rprx-vision"
# BitTorrent / DHT / public tracker port ranges (multiport limit: 15 slots)
readonly AT_PORTS="6881:6999,51413,6969,2710,1337"

localip="" ; public_ip="" ; hostname_v="" ; domain=""

# ---------------------------------------------------------------------------
# Logging + error trap
# ---------------------------------------------------------------------------
log_info()    { printf '%s\n' "${g0}[${GL_INFO}]${nc} $1"; }
log_success() { printf '%s\n' "${g2}[${GL_OK}]${nc} ${g1}$1${nc}"; }
log_error()   { printf '%s\n' "${gr}[${GL_ERR}]${nc} $1" >&2; }
log_warning() { printf '%s\n' "${gy}[${GL_WARN}]${nc} $1" >&2; }
log_step()    { printf '%s\n' "" "${g2}${GL_STEP}${nc} ${gw}$1${nc}"; }
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
# True public IPv4 of this VPS. Never return RFC1918/link-local/CGNAT as "public".
is_private_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 0
    case "$ip" in
        10.*|127.*|0.*|255.*) return 0 ;;
        192.168.*) return 0 ;;
        169.254.*) return 0 ;;
        100.64.*|100.65.*|100.66.*|100.67.*|100.68.*|100.69.*|100.7[0-9].*|100.8[0-9].*|100.9[0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;; # CGNAT 100.64/10 rough
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve the internet-facing IPv4. Order:
#   1) cached ${ASX_DIR}/public_ip (if still public)
#   2) multiple public echo services
#   3) first non-private address from hostname -I
#   4) last-resort: first hostname -I entry (logged as warning)
get_public_ip() {
    local ip="" cand cached svc
    local -a services=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
        "https://ipv4.icanhazip.com"
    )

    if [[ -f "${ASX_DIR}/public_ip" ]]; then
        cached="$(tr -d '[:space:]' < "${ASX_DIR}/public_ip" 2>/dev/null || true)"
        if [[ -n "$cached" ]] && ! is_private_ipv4 "$cached"; then
            printf '%s' "$cached"
            return 0
        fi
    fi

    for svc in "${services[@]}"; do
        ip="$(curl -4 -fsSL -H "User-Agent: ${UA:-AutoScriptX-Deployment}" --max-time 5 "$svc" 2>/dev/null \
            | tr -d '[:space:]' || true)"
        if [[ -n "$ip" ]] && ! is_private_ipv4 "$ip"; then
            mkdir -p "$ASX_DIR" 2>/dev/null || true
            printf '%s\n' "$ip" > "${ASX_DIR}/public_ip" 2>/dev/null || true
            chmod 644 "${ASX_DIR}/public_ip" 2>/dev/null || true
            printf '%s' "$ip"
            return 0
        fi
    done

    # Prefer any non-private interface address before falling back to eth0 private VPC IP.
    while read -r cand; do
        cand="$(printf '%s' "$cand" | tr -d '[:space:]')"
        [[ -z "$cand" ]] && continue
        if ! is_private_ipv4 "$cand"; then
            printf '%s' "$cand"
            return 0
        fi
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')

    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s' "${ip}"
    return 0
}

setup_hosts() {
    log_info "Setting up hostname and hosts file..."
    localip="$(hostname -I | awk '{print $1}')"
    public_ip="$(get_public_ip)"
    if is_private_ipv4 "$public_ip"; then
        log_warning "Could not detect a public IPv4 (got ${public_ip:-empty}). Reality/STLS links may be wrong until outbound DNS/HTTP works."
    else
        log_success "Public IPv4 detected: ${public_ip}"
    fi
    mkdir -p "$ASX_DIR"
    printf '%s\n' "$public_ip" > "${ASX_DIR}/public_ip"
    chmod 644 "${ASX_DIR}/public_ip"
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

# ---------------------------------------------------------------------------
# Themed SSH login banner (dropbear + OpenSSH). Generated locally so the node
# still gets a banner when the remote asset fetch fails.
# ---------------------------------------------------------------------------
_write_ssh_banner() {
    mkdir -p "$ASX_DIR"
    local host bf tmp
    host="${domain:-}"
    [[ -z "$host" ]] && host="$(cat "${ASX_DIR}/domain" 2>/dev/null || echo "")"
    [[ -z "$host" ]] && host="${public_ip:-unknown}"
    bf="${ASX_DIR}/banner"
    tmp="$(mktemp "${ASX_DIR}/.banner.XXXXXX")"
    # Quoted heredoc: no expansion, no backslash mangling. Host is injected after.
    cat > "$tmp" <<'BANNEREOF'
+==============================================================+
|            A U T O S C R I P T X   //   N O D E              |
|                 secure access gateway                        |
+==============================================================+
|  HOST    : __HOST__
|  LINK    : SECURE CHANNEL ESTABLISHED
+--------------------------------------------------------------+
|  >>  ALL SESSIONS ARE MONITORED AND LOGGED                   |
|  >>  UNAUTHORIZED ACCESS IS PROHIBITED                       |
|  >>  P2P / BITTORRENT TRAFFIC IS BLOCKED AND REPORTED        |
|  >>  ACCOUNT SHARING MAY RESULT IN SUSPENSION                |
+==============================================================+
BANNEREOF
    sed -i "s|__HOST__|${host}|" "$tmp"
    if [[ -s "$tmp" ]]; then
        chmod 644 "$tmp"; mv -f "$tmp" "$bf"
    else
        rm -f "$tmp"; log_warning "Failed to generate SSH banner."; return 1
    fi

    # Wire into dropbear without clobbering the rest of its config.
    if [[ -f /etc/default/dropbear ]]; then
        if grep -q '^DROPBEAR_BANNER=' /etc/default/dropbear; then
            sed -i "s|^DROPBEAR_BANNER=.*|DROPBEAR_BANNER=\"${bf}\"|" /etc/default/dropbear
        else
            printf 'DROPBEAR_BANNER="%s"\n' "$bf" >> /etc/default/dropbear
        fi
    fi

    # Wire into OpenSSH via issue.net, reverting if sshd rejects the config.
    cp -f "$bf" /etc/issue.net 2>/dev/null || true
    if [[ -f /etc/ssh/sshd_config ]]; then
        cp -f /etc/ssh/sshd_config /etc/ssh/sshd_config.asx.bak 2>/dev/null || true
        if grep -qE '^[[:space:]]*Banner[[:space:]]' /etc/ssh/sshd_config; then
            sed -i 's|^[[:space:]]*Banner[[:space:]].*|Banner /etc/issue.net|' /etc/ssh/sshd_config
        else
            echo 'Banner /etc/issue.net' >> /etc/ssh/sshd_config
        fi
        if sshd -t >/dev/null 2>&1; then
            systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
        else
            log_warning "sshd_config rejected the banner directive; reverting."
            mv -f /etc/ssh/sshd_config.asx.bak /etc/ssh/sshd_config 2>/dev/null || true
        fi
        rm -f /etc/ssh/sshd_config.asx.bak
    fi
    log_success "SSH login banner installed."
}

configure_dropbear() {
    log_info "Configuring Dropbear..."
    fetch "$BASE_URL/config/dropbear.conf" /etc/default/dropbear || die "Failed to download dropbear.conf."
    chmod 644 /etc/default/dropbear
    mkdir -p "$ASX_DIR"
    _write_ssh_banner || log_warning "Continuing without a custom banner."
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

# A bare IPv4 literal — a public CA can never issue for one, so it is the only
# case in which we accept a self-signed certificate. validate_domain() passes
# IPs (digits/dots satisfy its regex), so we must detect them explicitly here.
is_ip4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }

# Generate the local self-signed cert used only for IP-only installs.
_ssl_selfsigned() {
    log_warning "Generating SELF-SIGNED certificate — clients WILL see an untrusted cert."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${ASX_DIR}/cert.key" -out "${ASX_DIR}/cert.crt" \
        -subj "/CN=${domain}" >/dev/null 2>&1 \
        || die "Failed to generate self-signed certificate."
    chmod 600 "${ASX_DIR}/cert.key"; chmod 644 "${ASX_DIR}/cert.crt"
    log_success "Self-signed SSL cert installed (IP-only mode)."
}

setup_ssl_cert() {
    log_info "Requesting SSL cert..."
    systemctl stop nginx >/dev/null 2>&1 || true
    mkdir -p "$ASX_DIR" /root/.acme.sh

    # 1) Respect an existing certificate — keeps re-runs idempotent and avoids
    #    hitting Let's Encrypt rate limits on repeat installs.
    if [[ -s "${ASX_DIR}/cert.crt" && -s "${ASX_DIR}/cert.key" ]]; then
        log_info "Existing certificate found — keeping it."
        chmod 600 "${ASX_DIR}/cert.key"; chmod 644 "${ASX_DIR}/cert.crt"
        log_success "SSL cert installed."
        return 0
    fi

    # 2) IP-only install: no public CA can issue for a bare IP. This is the ONLY
    #    path that yields a self-signed cert.
    if is_ip4 "$domain" || ! validate_domain "$domain"; then
        log_warning "No valid domain ('$domain'): a public CA cannot issue a trusted"
        log_warning "certificate for an IP address. Point a real domain's A record at"
        log_warning "this server and re-run for browser-trusted TLS."
        _ssl_selfsigned
        return 0
    fi

    # 3) Domain install — commit to acme.sh. Any failure here aborts the install
    #    rather than silently degrading to an untrusted cert.
    # Download the REAL acme.sh script. NOTE: https://get.acme.sh returns an
    # installer WRAPPER, not acme.sh itself — executing that wrapper with
    # '--issue' can exit 0 without issuing anything, which produces exactly
    # the "acme.sh reported success but cert files are missing" failure.
    fetch "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" /root/.acme.sh/acme.sh \
        || die "Could not download acme.sh from GitHub — check outbound network."
    chmod +x /root/.acme.sh/acme.sh
    local acme="/root/.acme.sh/acme.sh"
    # Self-install so renewal cron + account config are set up, then enable auto-upgrade.
    "$acme" --install --home /root/.acme.sh >/dev/null 2>&1 || true
    "$acme" --upgrade --auto-upgrade >/dev/null 2>&1 || true

    # Preflight: standalone HTTP-01 needs :80 free (nginx already stopped above).
    if command -v ss >/dev/null 2>&1 && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
        log_warning "Port 80 appears to be in use — acme.sh --standalone may fail."
        log_warning "Holder: $(ss -ltnp 2>/dev/null | awk '/[:.]80 /{print $NF; exit}')"
    fi

    # Preflight: does the domain resolve to this box? Non-fatal (NAT/CDN/split
    # DNS are legitimate) but recorded to sharpen the failure diagnostic.
    local resolved_ip="" dns_note=""
    resolved_ip="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')"
    if [[ -n "$resolved_ip" && -n "${public_ip:-}" && "$resolved_ip" != "$public_ip" ]]; then
        dns_note="DNS: ${domain} -> ${resolved_ip}, but this host is ${public_ip}."
        log_warning "$dns_note"
    elif [[ -z "$resolved_ip" ]]; then
        dns_note="DNS: ${domain} did not resolve to any A record."
        log_warning "$dns_note"
    fi

    # Issue: try Let's Encrypt first, then ZeroSSL. Capture output so the abort
    # diagnostic can quote the real acme.sh error instead of hiding it.
    local ca issued=0 acme_log
    acme_log="$(mktemp)"
    for ca in letsencrypt zerossl; do
        log_info "Requesting certificate from ${ca}..."
        "$acme" --set-default-ca --server "$ca" >/dev/null 2>&1 || true
        if "$acme" --issue -d "$domain" --standalone -k ec-256 >"$acme_log" 2>&1; then
            issued=1; log_success "Certificate issued by ${ca}."; break
        fi
        log_warning "Issuance via ${ca} failed; trying next CA if available."
    done

    if [[ "$issued" -ne 1 ]]; then
        log_error "acme.sh could not obtain a certificate for '${domain}'."
        [[ -n "$dns_note" ]] && log_error "  ${dns_note}"
        log_error "  Likely causes: inbound TCP/80 not reachable from the internet,"
        log_error "  DNS A record not pointing at ${public_ip:-this host}, or CA rate limiting."
        log_error "  Last acme.sh output:"
        sed 's/^/    /' "$acme_log" >&2 || true
        log_error "  Full log: /root/.acme.sh/acme.sh.log"
        rm -f "$acme_log"
        die "TLS certificate issuance failed — refusing to fall back to self-signed."
    fi
    # Verify the issued cert actually landed on disk before trusting the exit
    # code — guards against anything that exits 0 without writing files.
    local issued_fullchain
    issued_fullchain="$(find /root/.acme.sh -maxdepth 2 -name 'fullchain.cer' -newermt '10 minutes ago' 2>/dev/null | head -n 1)"
    if [[ -z "$issued_fullchain" ]]; then
        log_error "acme.sh claimed success, but no certificate exists under /root/.acme.sh."
        log_error "  Last acme.sh output:"
        sed 's/^/    /' "$acme_log" >&2 || true
        rm -f "$acme_log"
        die "Issuance produced no files — see acme.sh output above."
    fi
    rm -f "$acme_log"

    # Install the issued cert into the paths nginx/xray consume.
    # '-k ec-256' issuance stores the cert under "${domain}_ecc"; the '--ecc'
    # flag is required so acme.sh installs from that ECC directory. Use the
    # current hyphenated flags: the deprecated '--installcert'/'--fullchainpath'/
    # '--keypath' aliases are silently ignored on newer builds, which yields
    # exit 0 with no files written. Capture output (not /dev/null) so any real
    # failure is diagnosable; a non-zero exit falls through to the copy below.
    local install_log
    install_log="$(mktemp)"
    if ! "$acme" --install-cert -d "$domain" --ecc \
        --fullchain-file "${ASX_DIR}/cert.crt" \
        --key-file "${ASX_DIR}/cert.key" >"$install_log" 2>&1; then
        log_warning "acme.sh --install-cert exited non-zero for '${domain}':"
        sed 's/^/    /' "$install_log" >&2 || true
        log_warning "Falling back to copying the issued files directly."
    fi
    rm -f "$install_log"

    # Backstop: if the targets are missing/empty for ANY reason (flag parsing,
    # ECC-dir mismatch, etc.), copy the issued files located above into place.
    if [[ ! -s "${ASX_DIR}/cert.crt" || ! -s "${ASX_DIR}/cert.key" ]]; then
        local src_dir src_key
        src_dir="$(dirname "$issued_fullchain")"
        src_key="${src_dir}/${domain}.key"
        log_warning "Copying cert directly from ${src_dir}."
        install -m 644 "$issued_fullchain" "${ASX_DIR}/cert.crt"
        install -m 600 "$src_key" "${ASX_DIR}/cert.key"
    fi

    if [[ ! -s "${ASX_DIR}/cert.crt" || ! -s "${ASX_DIR}/cert.key" ]]; then
        log_error "Cert files still missing/empty at ${ASX_DIR} after install + fallback."
        log_error "Contents of /root/.acme.sh (paste this for debugging):"
        find /root/.acme.sh -maxdepth 2 2>&1 | sed 's/^/    /' >&2 || true
        die "TLS cert install failed."
    fi

    # Sanity check: a CA-issued cert must not be self-signed (issuer != subject).
    local iss sub
    iss="$(openssl x509 -in "${ASX_DIR}/cert.crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
    sub="$(openssl x509 -in "${ASX_DIR}/cert.crt" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    if [[ -n "$iss" && "$iss" == "$sub" ]]; then
        die "Installed certificate is self-signed (issuer == subject) — refusing. Re-check DNS/port 80."
    fi

    chmod 600 "${ASX_DIR}/cert.key"; chmod 644 "${ASX_DIR}/cert.crt"
    log_success "SSL cert installed (issued by ${iss:-CA})."
}


# ---------------------------------------------------------------------------
# Reality key material + ShadowTLS binary/service helpers
# ---------------------------------------------------------------------------
# Parse `xray x25519` across historical + current output formats.
# Modern xray prints:
#   PrivateKey: ...
#   Password (PublicKey): ...   <-- client pbk (NOT Hash32)
#   Hash32: ...
_parse_x25519() {
    local raw priv pub line k v
    priv=""; pub=""
    raw="$1"
    while IFS= read -r line; do
        line="${line//$\r/}"
        [[ -z "$line" ]] && continue
        # Normalize label: lowercase, strip spaces and parentheses.
        k="$(printf '%s' "$line" | awk -F: '{print tolower($1)}' | sed 's/[[:space:]]//g; s/[()]//g')"
        v="$(printf '%s' "$line" | sed 's/^[^:]*:[[:space:]]*//')"
        case "$k" in
            privatekey|private) priv="$v" ;;
            # Match publickey, password, passwordpublickey
            publickey|public|password|passwordpublickey) pub="$v" ;;
            hash32) ;; # never use Hash32 as client pbk
        esac
    done <<< "$raw"
    if [[ -z "$priv" || -z "$pub" ]]; then
        # Prefer labeled extraction failed — take first two long tokens, skip if 3rd is hash-like.
        mapfile -t _keys < <(printf '%s\n' "$raw" | grep -Eo '[A-Za-z0-9_\-]{40,60}' | head -3)
        [[ -z "$priv" && ${#_keys[@]} -ge 1 ]] && priv="${_keys[0]}"
        [[ -z "$pub"  && ${#_keys[@]} -ge 2 ]] && pub="${_keys[1]}"
    fi
    [[ -n "$priv" && -n "$pub" ]] || return 1
    printf '%s\n%s\n' "$priv" "$pub"
}

# Derive the client public key (pbk) from a server private key. Most reliable path.
_reality_pubkey_from_private() {
    local priv="$1" out pub
    out="$("$XRAY_BIN" x25519 -i "$priv" 2>/dev/null || "$XRAY_BIN" x25519 -i="$priv" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
        pub="$(printf '%s\n' "$out" | awk -F: '
            tolower($1) ~ /password|public/ {
                sub(/^[^:]*:[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; exit
            }')"
        if [[ -z "$pub" ]]; then
            pub="$(printf '%s\n' "$out" | grep -Eo '[A-Za-z0-9_\-]{40,60}' | head -1)"
        fi
    fi
    printf '%s' "${pub:-}"
}

generate_reality_keys() {
    local out priv pub sid
    command -v "$XRAY_BIN" >/dev/null 2>&1 || die "xray binary missing; install_xray first."
    out="$("$XRAY_BIN" x25519 2>/dev/null)" || die "xray x25519 failed."
    mapfile -t _pair < <(_parse_x25519 "$out") || die "Could not parse xray x25519 output."
    priv="${_pair[0]:-}"; pub="${_pair[1]:-}"
    # Prefer derived public key from private — avoids Hash32 / label mixups on new xray.
    local derived
    derived="$(_reality_pubkey_from_private "$priv")"
    [[ -n "$derived" ]] && pub="$derived"
    [[ -n "$priv" && -n "$pub" ]] || die "Empty Reality key material."
    sid="$(openssl rand -hex 8)"
    REALITY_PRIVATE_KEY="$priv"
    REALITY_PUBLIC_KEY="$pub"
    REALITY_SHORT_ID="$sid"
}

_shadowtls_asset_name() {
    case "$(uname -m)" in
        x86_64)  printf '%s' "shadow-tls-x86_64-unknown-linux-musl" ;;
        aarch64) printf '%s' "shadow-tls-aarch64-unknown-linux-musl" ;;
        armv7l)  printf '%s' "shadow-tls-armv7-unknown-linux-musleabihf" ;;
        *)       die "Unsupported arch for ShadowTLS: $(uname -m)" ;;
    esac
}

install_shadowtls() {
    log_info "Installing ShadowTLS..."
    local asset tag url tmp
    asset="$(_shadowtls_asset_name)"
    tag="$(curl -fsSL -H "User-Agent: ${UA}" --max-time 10 \
        "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" \
        | jq -r '.tag_name // empty' 2>/dev/null || true)"
    [[ -n "$tag" ]] || tag="v0.2.25"
    url="https://github.com/ihciah/shadow-tls/releases/download/${tag}/${asset}"
    tmp="$(mktemp)"
    if ! fetch "$url" "$tmp"; then
        rm -f "$tmp"
        die "Failed to download ShadowTLS from ${url}."
    fi
    # Optional integrity when the key is present in SHA256SUMS.
    verify_file "$tmp" "$asset" || true
    install -m 0755 "$tmp" "$SHADOWTLS_BIN"
    rm -f "$tmp"
    log_success "ShadowTLS ${tag} installed -> ${SHADOWTLS_BIN}."
}

configure_shadowtls() {
    log_info "Configuring ShadowTLS service..."
    local stls_pass
    if [[ -f "${XRAY_DIR}/credentials.env" ]]; then
        stls_pass="$(awk -F= '/^SHADOWTLS_PASSWORD=/{gsub(/"/,"",$2); print $2; exit}' \
            "${XRAY_DIR}/credentials.env" 2>/dev/null || true)"
    fi
    if [[ -z "${stls_pass:-}" ]]; then
        stls_pass="$(openssl rand -hex 16)"
        if [[ -f "${XRAY_DIR}/credentials.env" ]]; then
            if grep -q '^SHADOWTLS_PASSWORD=' "${XRAY_DIR}/credentials.env" 2>/dev/null; then
                sed -i "s|^SHADOWTLS_PASSWORD=.*|SHADOWTLS_PASSWORD=\"${stls_pass}\"|" \
                    "${XRAY_DIR}/credentials.env"
            else
                printf 'SHADOWTLS_PASSWORD="%s"\n' "$stls_pass" >> "${XRAY_DIR}/credentials.env"
            fi
            chmod 600 "${XRAY_DIR}/credentials.env"
        fi
    fi

    umask 077
    cat > "$SHADOWTLS_ENV" <<EOF
SHADOWTLS_PASSWORD=${stls_pass}
SHADOWTLS_LISTEN=0.0.0.0:${PORT_SHADOWTLS}
SHADOWTLS_BACKEND=127.0.0.1:${PORT_VLESS_STLS}
SHADOWTLS_TLS=${REALITY_SNI}
EOF
    chmod 600 "$SHADOWTLS_ENV"

    # Thin wrapper: password stays in 0600 env file, not baked into the unit argv template.
    cat > /usr/local/bin/shadow-tls-run <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="/usr/local/etc/xray/shadowtls.env"
# shellcheck disable=SC1090
source "$ENV_FILE"
exec /usr/local/bin/shadow-tls --v3 server \
    --listen "${SHADOWTLS_LISTEN}" \
    --server "${SHADOWTLS_BACKEND}" \
    --tls "${SHADOWTLS_TLS}" \
    --password "${SHADOWTLS_PASSWORD}"
WRAP
    chmod 0755 /usr/local/bin/shadow-tls-run

    cat > /etc/systemd/system/shadow-tls.service <<'SERVICE'
[Unit]
Description=ShadowTLS stealth handshake wrapper (AutoScriptX)
Documentation=https://github.com/ihciah/shadow-tls
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/shadow-tls-run
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable shadow-tls >/dev/null 2>&1 || true
    systemctl restart shadow-tls >/dev/null 2>&1 \
        || log_warning "ShadowTLS restart failed (check journalctl -u shadow-tls)."
    log_success "ShadowTLS configured (listen ${PORT_SHADOWTLS} -> 127.0.0.1:${PORT_VLESS_STLS}, SNI ${REALITY_SNI})."
}

# Test that a Reality dest host:port accepts a TLS TCP connect from this VPS.
_reality_dest_ok() {
    local dest="$1" host port
    host="${dest%%:*}"
    port="${dest##*:}"
    [[ "$host" == "$port" ]] && port=443
    # bash /dev/tcp is enough; openssl s_client is better when present.
    if command -v timeout >/dev/null 2>&1; then
        if command -v openssl >/dev/null 2>&1; then
            timeout 5 openssl s_client -connect "${host}:${port}" -servername "$host" </dev/null >/dev/null 2>&1 && return 0
        fi
        timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    else
        bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    fi
    return 1
}

# Sync every VLESS-WS client onto Reality (flow=vision) and STLS backend (flow empty).
# Without this, accounts created before Reality existed cannot authenticate on :8443.
repair_reality_stls_clients() {
    local cfg="${1:-${XRAY_DIR}/config.json}"
    [[ -f "$cfg" ]] || return 0
    jq -e '.inbounds[]|select(.tag=="vless-reality" or .tag=="vless-stls")' "$cfg" >/dev/null 2>&1 || return 0
    json_edit "$cfg" "$CFG_LOCK" --arg rflow "xtls-rprx-vision" '
      (first(.inbounds[]|select(.tag=="vless-ws")|.settings.clients) // []) as $src |
      ($src | map({
          id: .id,
          email: (.email // .id),
          flow: $rflow
      })) as $rclients |
      ($src | map({
          id: .id,
          email: (.email // .id),
          flow: ""
      })) as $sclients |
      .inbounds |= map(
        if   .tag=="vless-reality" and ($rclients|length)>0 then .settings.clients=$rclients
        elif .tag=="vless-stls"    and ($sclients|length)>0 then .settings.clients=$sclients
        else . end )' \
      && log_success "  Reality/STLS clients synced from vless-ws." \
      || log_warning "  Could not sync Reality/STLS clients."
}

# If current Reality dest is dead, fall back to a known-good TLS1.3 host.
repair_reality_dest() {
    local cfg="${1:-${XRAY_DIR}/config.json}"
    local creds="${XRAY_DIR}/credentials.env"
    local dest host fallback="www.cloudflare.com:443" fb_host="www.cloudflare.com"
    [[ -f "$cfg" ]] || return 0
    jq -e '.inbounds[]|select(.tag=="vless-reality")' "$cfg" >/dev/null 2>&1 || return 0

    dest="$(jq -r '.inbounds[]|select(.tag=="vless-reality")|.streamSettings.realitySettings.dest//empty' "$cfg" 2>/dev/null || true)"
    [[ -n "$dest" ]] || dest="$fallback"
    host="${dest%%:*}"

    if _reality_dest_ok "$dest"; then
        log_success "  Reality dest reachable: ${dest}"
        return 0
    fi

    log_warning "  Reality dest not reachable via TLS (${dest}). Switching to ${fallback}."
    json_edit "$cfg" "$CFG_LOCK" --arg dest "$fallback" --arg sni "$fb_host" '
      .inbounds |= map(
        if .tag=="vless-reality" then
          .streamSettings.realitySettings.dest=$dest
          | .streamSettings.realitySettings.serverNames =
              ((.streamSettings.realitySettings.serverNames // []) + [$sni] | unique)
        else . end)' || return 1

    if [[ -f "$creds" ]]; then
        grep -q '^REALITY_DEST=' "$creds" 2>/dev/null \
            && sed -i "s|^REALITY_DEST=.*|REALITY_DEST=\"${fallback}\"|" "$creds" \
            || printf 'REALITY_DEST="%s"\n' "$fallback" >> "$creds"
        grep -q '^REALITY_SNI=' "$creds" 2>/dev/null \
            && sed -i "s|^REALITY_SNI=.*|REALITY_SNI=\"${fb_host}\"|" "$creds" \
            || printf 'REALITY_SNI="%s"\n' "$fb_host" >> "$creds"
        chmod 600 "$creds"
    fi
    log_success "  Reality dest repaired → ${fallback} (update client SNI to ${fb_host})."
}

# Re-derive pbk from privateKey in config and rewrite credentials.env (fixes wrong pbk).
repair_reality_pubkey() {
    local cfg="${1:-${XRAY_DIR}/config.json}"
    local creds="${XRAY_DIR}/credentials.env"
    local priv pub sid
    [[ -f "$cfg" ]] || return 0
    priv="$(jq -r '.inbounds[]|select(.tag=="vless-reality")|.streamSettings.realitySettings.privateKey//empty' "$cfg" 2>/dev/null || true)"
    [[ -n "$priv" ]] || return 0
    pub="$(_reality_pubkey_from_private "$priv")"
    [[ -n "$pub" ]] || return 0
    sid="$(jq -r '.inbounds[]|select(.tag=="vless-reality")|.streamSettings.realitySettings.shortIds[1]//.streamSettings.realitySettings.shortIds[0]//empty' "$cfg" 2>/dev/null || true)"
    [[ -n "$sid" ]] || sid="$(awk -F= '/^REALITY_SHORT_ID=/{gsub(/"/,"",$2); print $2; exit}' "$creds" 2>/dev/null || true)"

    if [[ -f "$creds" ]]; then
        grep -q '^REALITY_PUBLIC_KEY=' "$creds" 2>/dev/null \
            && sed -i "s|^REALITY_PUBLIC_KEY=.*|REALITY_PUBLIC_KEY=\"${pub}\"|" "$creds" \
            || printf 'REALITY_PUBLIC_KEY="%s"\n' "$pub" >> "$creds"
        grep -q '^REALITY_PRIVATE_KEY=' "$creds" 2>/dev/null \
            && sed -i "s|^REALITY_PRIVATE_KEY=.*|REALITY_PRIVATE_KEY=\"${priv}\"|" "$creds" \
            || printf 'REALITY_PRIVATE_KEY="%s"\n' "$priv" >> "$creds"
        if [[ -n "$sid" ]]; then
            grep -q '^REALITY_SHORT_ID=' "$creds" 2>/dev/null \
                && sed -i "s|^REALITY_SHORT_ID=.*|REALITY_SHORT_ID=\"${sid}\"|" "$creds" \
                || printf 'REALITY_SHORT_ID="%s"\n' "$sid" >> "$creds"
        fi
        chmod 600 "$creds"
    fi
    log_success "  Reality client pbk refreshed from server privateKey."
}

# Idempotent migration: ensure Reality + STLS backend inbounds exist on upgrades.
ensure_reality_stls_inbounds() {
    local cfg="${1:-${XRAY_DIR}/config.json}"
    local creds="${XRAY_DIR}/credentials.env"
    local priv pub sid stls_pass uuid_vless
    [[ -f "$cfg" ]] || return 0

    uuid_vless="$(jq -r '.inbounds[]|select(.tag=="vless-ws")|.settings.clients[0].id // empty' "$cfg" 2>/dev/null || true)"
    [[ -n "$uuid_vless" ]] || uuid_vless="$(cat /proc/sys/kernel/random/uuid)"

    priv=""; pub=""; sid=""; stls_pass=""
    if [[ -f "$creds" ]]; then
        priv="$(awk -F= '/^REALITY_PRIVATE_KEY=/{gsub(/"/,"",$2); print $2; exit}' "$creds" 2>/dev/null || true)"
        pub="$(awk -F=  '/^REALITY_PUBLIC_KEY=/{gsub(/"/,"",$2); print $2; exit}' "$creds" 2>/dev/null || true)"
        sid="$(awk -F=  '/^REALITY_SHORT_ID=/{gsub(/"/,"",$2); print $2; exit}' "$creds" 2>/dev/null || true)"
        stls_pass="$(awk -F= '/^SHADOWTLS_PASSWORD=/{gsub(/"/,"",$2); print $2; exit}' "$creds" 2>/dev/null || true)"
    fi

    # Prefer privateKey already embedded in config.json over credentials.
    local cfg_priv
    cfg_priv="$(jq -r '.inbounds[]|select(.tag=="vless-reality")|.streamSettings.realitySettings.privateKey//empty' "$cfg" 2>/dev/null || true)"
    [[ -n "$cfg_priv" ]] && priv="$cfg_priv"

    if [[ -z "${priv}" || -z "${sid}" ]]; then
        generate_reality_keys
        priv="$REALITY_PRIVATE_KEY"; pub="$REALITY_PUBLIC_KEY"; sid="$REALITY_SHORT_ID"
    else
        # Always re-derive pbk from private key (fixes wrong Password/Hash32 mixups).
        pub="$(_reality_pubkey_from_private "$priv")"
        [[ -n "$pub" ]] || pub="$(awk -F= '/^REALITY_PUBLIC_KEY=/{gsub(/"/,"",$2); print $2; exit}' "$creds" 2>/dev/null || true)"
        [[ -n "$pub" ]] || { generate_reality_keys; priv="$REALITY_PRIVATE_KEY"; pub="$REALITY_PUBLIC_KEY"; sid="$REALITY_SHORT_ID"; }
    fi
    [[ -n "${stls_pass}" ]] || stls_pass="$(openssl rand -hex 16)"

    # Pick a working dest: prefer configured REALITY_DEST if reachable, else microsoft.
    local use_dest use_sni
    use_dest="$REALITY_DEST"
    use_sni="$REALITY_SNI"
    if [[ -f "$creds" ]]; then
        local cdest csni
        cdest="$(awk -F= '/^REALITY_DEST=/{gsub(/"/,"",$2); print $2; exit}' "$creds" 2>/dev/null || true)"
        csni="$(awk -F= '/^REALITY_SNI=/{gsub(/"/,"",$2); print $2; exit}' "$creds" 2>/dev/null || true)"
        [[ -n "$cdest" ]] && use_dest="$cdest"
        [[ -n "$csni" ]] && use_sni="$csni"
    fi
    if ! _reality_dest_ok "$use_dest"; then
        log_warning "  Configured Reality dest ${use_dest} is not reachable; using www.cloudflare.com:443"
        use_dest="www.cloudflare.com:443"
        use_sni="www.cloudflare.com"
    fi

    umask 077
    local tmpc; tmpc="$(mktemp "${XRAY_DIR}/.creds.XXXXXX")"
    if [[ -f "$creds" ]]; then
        grep -Ev '^(REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|REALITY_SHORT_ID|REALITY_SNI|REALITY_DEST|REALITY_FLOW|SHADOWTLS_PASSWORD|PORT_VLESS_REALITY|PORT_SHADOWTLS)=' \
            "$creds" > "$tmpc" || true
    else
        : > "$tmpc"
    fi
    {
        printf 'REALITY_PRIVATE_KEY="%s"\n' "$priv"
        printf 'REALITY_PUBLIC_KEY="%s"\n' "$pub"
        printf 'REALITY_SHORT_ID="%s"\n' "$sid"
        printf 'REALITY_SNI="%s"\n' "$use_sni"
        printf 'REALITY_DEST="%s"\n' "$use_dest"
        printf 'REALITY_FLOW="%s"\n' "$REALITY_FLOW"
        printf 'SHADOWTLS_PASSWORD="%s"\n' "$stls_pass"
        printf 'PORT_VLESS_REALITY="%s"\n' "$PORT_VLESS_REALITY"
        printf 'PORT_SHADOWTLS="%s"\n' "$PORT_SHADOWTLS"
    } >> "$tmpc"
    mv -f "$tmpc" "$creds"
    chmod 600 "$creds"

    if ! jq -e '.inbounds[]|select(.tag=="vless-reality")' "$cfg" >/dev/null 2>&1; then
        json_edit "$cfg" "$CFG_LOCK" \
          --arg uuid "$uuid_vless" --arg priv "$priv" --arg sid "$sid" \
          --arg dest "$use_dest" --arg sni "$use_sni" --arg flow "$REALITY_FLOW" \
          --argjson port "$PORT_VLESS_REALITY" '
          .inbounds += [{
            tag:"vless-reality", listen:"0.0.0.0", port:$port, protocol:"vless",
            settings:{ clients:[{id:$uuid, flow:$flow, email:"admin_vless"}], decryption:"none" },
            streamSettings:{
              network:"tcp", security:"reality",
              realitySettings:{
                show:true, dest:$dest, xver:0,
                serverNames:[$sni], privateKey:$priv, shortIds:["", $sid]
              }
            },
            sniffing:{ enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:true }
          }]' && log_success "  vless-reality inbound added (port ${PORT_VLESS_REALITY})."
    else
        # Keep listen/port/keys; force working dest + ensure default SNI present.
        json_edit "$cfg" "$CFG_LOCK" \
          --arg dest "$use_dest" --arg sni "$use_sni" --arg priv "$priv" --arg sid "$sid" '
          .inbounds |= map(
            if .tag=="vless-reality" then
              .listen="0.0.0.0"
              | .streamSettings.security="reality"
              | .streamSettings.network="tcp"
              | .streamSettings.realitySettings.dest=$dest
              | .streamSettings.realitySettings.show=true
              | .streamSettings.realitySettings.privateKey=$priv
              | .streamSettings.realitySettings.shortIds=(["", $sid] | unique)
              | .streamSettings.realitySettings.serverNames=
                  ((.streamSettings.realitySettings.serverNames // []) + [$sni] | unique)
              | .sniffing={enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:true}
            else . end)
          | .log.loglevel="info"' \
          && log_success "  vless-reality inbound hardened (dest/SNI/keys/listen/logging)."
    fi

    if ! jq -e '.inbounds[]|select(.tag=="vless-stls")' "$cfg" >/dev/null 2>&1; then
        json_edit "$cfg" "$CFG_LOCK" \
          --arg uuid "$uuid_vless" --argjson port "$PORT_VLESS_STLS" '
          .inbounds += [{
            tag:"vless-stls", listen:"127.0.0.1", port:$port, protocol:"vless",
            settings:{ clients:[{id:$uuid, flow:"", email:"admin_vless"}], decryption:"none" },
            streamSettings:{ network:"tcp", security:"none" },
            sniffing:{ enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:true }
          }]' && log_success "  vless-stls backend inbound added (127.0.0.1:${PORT_VLESS_STLS})."
    fi

    repair_reality_stls_clients "$cfg"
    repair_reality_pubkey "$cfg"
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
    log_info "Configuring Xray-core (WS + xHTTP + Reality + ShadowTLS backend)..."
    local uuid_vless uuid_vmess trojan_pass stls_pass
    uuid_vless="$(cat /proc/sys/kernel/random/uuid)"
    uuid_vmess="$(cat /proc/sys/kernel/random/uuid)"
    trojan_pass="$(openssl rand -hex 20)"
    stls_pass="$(openssl rand -hex 16)"

    generate_reality_keys

    umask 077
    {
        printf 'VLESS_UUID="%s"\n' "$uuid_vless"
        printf 'VMESS_UUID="%s"\n' "$uuid_vmess"
        printf 'TROJAN_PASS="%s"\n' "$trojan_pass"
        printf 'DOMAIN="%s"\n' "$domain"
        printf 'REALITY_PRIVATE_KEY="%s"\n' "$REALITY_PRIVATE_KEY"
        printf 'REALITY_PUBLIC_KEY="%s"\n' "$REALITY_PUBLIC_KEY"
        printf 'REALITY_SHORT_ID="%s"\n' "$REALITY_SHORT_ID"
        printf 'REALITY_SNI="%s"\n' "$REALITY_SNI"
        printf 'REALITY_DEST="%s"\n' "$REALITY_DEST"
        printf 'REALITY_FLOW="%s"\n' "$REALITY_FLOW"
        printf 'SHADOWTLS_PASSWORD="%s"\n' "$stls_pass"
        printf 'PORT_VLESS_REALITY="%s"\n' "$PORT_VLESS_REALITY"
        printf 'PORT_SHADOWTLS="%s"\n' "$PORT_SHADOWTLS"
    } | atomic_write "${XRAY_DIR}/credentials.env"
    printf 'Username,SSHPassword,XrayUUID,TrojanPassword,ExpiryDate,LimitGB,UsedBytes\n' \
        | atomic_write "$CSV_DB"
    chmod 600 "${XRAY_DIR}/credentials.env" "$CSV_DB"

    jq -n \
      --arg vless "$uuid_vless" --arg vmess "$uuid_vmess" --arg trojan "$trojan_pass" \
      --arg domain "$domain" \
      --arg rpriv "$REALITY_PRIVATE_KEY" --arg rsid "$REALITY_SHORT_ID" \
      --arg rdest "$REALITY_DEST" --arg rsni "$REALITY_SNI" --arg rflow "$REALITY_FLOW" \
      --argjson p_api  "$PORT_XRAY_API" \
      --argjson p_vw   "$PORT_VLESS_WS"    --argjson p_mw "$PORT_VMESS_WS" \
      --argjson p_tw   "$PORT_TROJAN_WS" \
      --argjson p_vx   "$PORT_VLESS_XHTTP"  --argjson p_mx "$PORT_VMESS_XHTTP" \
      --argjson p_vr   "$PORT_VLESS_REALITY" --argjson p_st "$PORT_VLESS_STLS" '
    {
      log: { loglevel:"info", access:"/var/log/xray/access.log", error:"/var/log/xray/error.log" },
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
          streamSettings:{ network:"xhttp", xhttpSettings:{ path:"/vmess-xhttp", host:$domain } } },
        { tag:"vless-reality", listen:"0.0.0.0", port:$p_vr, protocol:"vless",
          settings:{ clients:[{id:$vless,flow:$rflow,email:"admin_vless"}], decryption:"none" },
          streamSettings:{
            network:"tcp", security:"reality",
            realitySettings:{
              show:true, dest:$rdest, xver:0,
              serverNames:[$rsni], privateKey:$rpriv, shortIds:["", $rsid]
            }
          },
          sniffing:{ enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:false }
        },
        { tag:"vless-stls", listen:"127.0.0.1", port:$p_st, protocol:"vless",
          settings:{ clients:[{id:$vless,flow:"",email:"admin_vless"}], decryption:"none" },
          streamSettings:{ network:"tcp", security:"none" },
          sniffing:{ enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:false }
        }
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
    log_success "Xray-core configured (WS + xHTTP + Reality :${PORT_VLESS_REALITY} + STLS backend :${PORT_VLESS_STLS})."
    log_info "Reality pbk=${REALITY_PUBLIC_KEY} sid=${REALITY_SHORT_ID} sni=${REALITY_SNI}"
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
    for port in 22 80 443 8080 "$PORT_VLESS_REALITY" "$PORT_SHADOWTLS"; do
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
        "${XRAY_DIR}/shadowtls.env"
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

    log_info "Ensuring Reality + ShadowTLS inbounds..."
    ensure_reality_stls_inbounds "${XRAY_DIR}/config.json"

    log_info "Re-applying anti-torrent policy..."
    _migrate_xray_antitorrent "${XRAY_DIR}/config.json"
    apply_firewall_rules

    if [[ ! -x "$SHADOWTLS_BIN" ]]; then
        install_shadowtls || log_warning "ShadowTLS install skipped/failed."
    fi
    configure_shadowtls || log_warning "ShadowTLS reconfigure failed."

    log_info "Refreshing cached public IPv4..."
    rm -f "${ASX_DIR}/public_ip" 2>/dev/null || true
    public_ip="$(get_public_ip)"
    if is_private_ipv4 "$public_ip"; then
        log_warning "Public IPv4 still looks private (${public_ip:-empty})."
    else
        log_success "Public IPv4: ${public_ip}"
    fi

    log_info "Reloading Xray, ShadowTLS, and Nginx..."
    systemctl restart xray >/dev/null 2>&1 && log_success "Xray restarted." || log_warning "Xray restart failed."
    systemctl restart shadow-tls >/dev/null 2>&1 && log_success "ShadowTLS restarted." || log_warning "ShadowTLS restart failed."
    if nginx -t >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1 && log_success "Nginx reloaded."
    else log_warning "Nginx config test failed — NOT reloaded."; fi

    rm -rf "$snap_dir"; [[ -n "$_manifest" ]] && rm -f "$_manifest"
    log_success "Update complete. Version 4.4.3-hardened. Users/UUIDs/certs/domain UNTOUCHED."
    # ui_pause lives only inside /usr/bin/menu. When --update-only is invoked
    # from the installer (or menu's do_update subprocess), calling it here
    # trips set -e with "command not found" (exit 127) after a successful update.
    if declare -F ui_pause >/dev/null 2>&1; then
        ui_pause
    elif [[ -t 0 ]]; then
        printf '%s' "  press ENTER to return "
        read -r _ || true
    fi
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
XRAY_DIR="/usr/local/etc/xray"
ASX_DIR="/etc/AutoScriptX"
CSV_LOCK="/run/lock/autoscriptx-csv.lock"
CFG_LOCK="/run/lock/autoscriptx-cfg.lock"
PORT_VLESS_REALITY=8443
PORT_SHADOWTLS=8444
REALITY_SNI="www.cloudflare.com"
REALITY_FLOW="xtls-rprx-vision"
CREDS_ENV="${XRAY_DIR}/credentials.env"

# Load Reality / ShadowTLS material written by configure_xray (0600).
_load_asx_cred() {
    local key="$1" file="${CREDS_ENV}"
    [[ -f "$file" ]] || { printf ''; return 0; }
    awk -F= -v k="$key" '$1==k {gsub(/^"|"$/,"",$2); print $2; exit}' "$file" 2>/dev/null || true
}
_asx_reality_pbk()  { _load_asx_cred REALITY_PUBLIC_KEY; }
_asx_reality_sid()  { _load_asx_cred REALITY_SHORT_ID; }
_asx_reality_sni()  { local v; v="$(_load_asx_cred REALITY_SNI)"; printf '%s' "${v:-www.cloudflare.com}"; }
_asx_stls_pass()    { _load_asx_cred SHADOWTLS_PASSWORD; }
_asx_port_reality() { local v; v="$(_load_asx_cred PORT_VLESS_REALITY)"; printf '%s' "${v:-$PORT_VLESS_REALITY}"; }
_asx_port_stls()    { local v; v="$(_load_asx_cred PORT_SHADOWTLS)"; printf '%s' "${v:-$PORT_SHADOWTLS}"; }

# True public IPv4 for share links / account cards. Rejects VPC/private addresses.
is_private_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 0
    case "$ip" in
        10.*|127.*|0.*|255.*) return 0 ;;
        192.168.*) return 0 ;;
        169.254.*) return 0 ;;
        100.64.*|100.65.*|100.66.*|100.67.*|100.68.*|100.69.*|100.7[0-9].*|100.8[0-9].*|100.9[0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        *) return 1 ;;
    esac
}

get_public_ip() {
    local ip="" cand cached svc
    local -a services=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
        "https://ipv4.icanhazip.com"
    )

    if [[ -f "${ASX_DIR}/public_ip" ]]; then
        cached="$(tr -d '[:space:]' < "${ASX_DIR}/public_ip" 2>/dev/null || true)"
        if [[ -n "$cached" ]] && ! is_private_ipv4 "$cached"; then
            printf '%s' "$cached"
            return 0
        fi
    fi

    for svc in "${services[@]}"; do
        ip="$(curl -4 -fsSL --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -n "$ip" ]] && ! is_private_ipv4 "$ip"; then
            mkdir -p "$ASX_DIR" 2>/dev/null || true
            printf '%s
' "$ip" > "${ASX_DIR}/public_ip" 2>/dev/null || true
            chmod 644 "${ASX_DIR}/public_ip" 2>/dev/null || true
            printf '%s' "$ip"
            return 0
        fi
    done

    while read -r cand; do
        cand="$(printf '%s' "$cand" | tr -d '[:space:]')"
        [[ -z "$cand" ]] && continue
        if ! is_private_ipv4 "$cand"; then
            printf '%s' "$cand"
            return 0
        fi
    done < <(hostname -I 2>/dev/null | tr ' ' '
')

    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s' "${ip}"
    return 0
}

# ---------------------------------------------------------------------------
# UI render layer. Presentation only - no business logic lives below.
# Degrades cleanly: no colour on dumb terminals / pipes / NO_COLOR, and ASCII
# frames when the locale cannot measure multibyte glyphs.
# ---------------------------------------------------------------------------
UI_W=64
_ui_init() {
    local tiers=0
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        tiers="$(tput colors 2>/dev/null || echo 8)"
        [[ "$tiers" =~ ^[0-9]+$ ]] || tiers=8
    fi
    if (( tiers >= 8 )); then
        g0=$'\033[2;32m'; g1=$'\033[0;32m'; g2=$'\033[1;32m'
        gy=$'\033[1;33m'; gr=$'\033[1;31m'; gw=$'\033[1;37m'
        gb=$'\033[7;32m'; nc=$'\033[0m'
        if (( tiers >= 256 )); then
            g0=$'\033[38;5;22m'; g1=$'\033[38;5;40m'; g2=$'\033[38;5;46m'
        fi
    else
        g0=""; g1=""; g2=""; gy=""; gr=""; gw=""; gb=""; nc=""
    fi
    # A box glyph must measure as exactly one character, otherwise ${#str}
    # counts bytes and every frame comes out ragged.
    local _probe=$'\u2500'
    if [[ "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" == *[Uu][Tt][Ff]* && ${#_probe} -eq 1 ]]; then
        BX_H=$'\u2500'; BX_V=$'\u2502'; BX_TL=$'\u250c'; BX_TR=$'\u2510'
        BX_BL=$'\u2514'; BX_BR=$'\u2518'; BX_ML=$'\u251c'; BX_MR=$'\u2524'
        GL_ARROW=$'\u25b8'; GL_DOT=$'\u2022'; GL_FULL=$'\u2588'; GL_EMPTY=$'\u2591'
    else
        BX_H="-"; BX_V="|"; BX_TL="+"; BX_TR="+"
        BX_BL="+"; BX_BR="+"; BX_ML="+"; BX_MR="+"
        GL_ARROW=">"; GL_DOT="*"; GL_FULL="#"; GL_EMPTY="."
    fi
    # Adapt to the real terminal, clamped so frames never wrap on mobile SSH.
    local cols; cols="$(tput cols 2>/dev/null || echo 80)"
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    UI_W=$(( cols - 6 )); (( UI_W > 72 )) && UI_W=72; (( UI_W < 56 )) && UI_W=56
}
g0=""; g1=""; g2=""; gy=""; gr=""; gw=""; gb=""; nc=""
BX_H="-"; BX_V="|"; BX_TL="+"; BX_TR="+"; BX_BL="+"; BX_BR="+"; BX_ML="+"; BX_MR="+"
GL_ARROW=">"; GL_DOT="*"; GL_FULL="#"; GL_EMPTY="."
_ui_init

# Legacy aliases so every pre-existing echo in this script still resolves.
green="$g1"; blue="$g0"; yellow="$gy"; red="$gr"; cyan="$g2"

# Visible length, ignoring ANSI escapes, so frames stay aligned even when the
# caller embeds colour mid-string. Quoting "${esc}[" keeps the bracket literal
# instead of starting a bracket expression.
ui_vlen() {
    local s="$1" out="" esc=$'\033'
    while [[ "$s" == *"${esc}["* ]]; do
        out+="${s%%"${esc}["*}"
        s="${s#*"${esc}["}"
        s="${s#*m}"
    done
    out+="$s"
    printf '%s' "${#out}"
}
ui_pad() { local n="${1:-0}"; (( n > 0 )) && printf '%*s' "$n" '' || true; }
ui_rule() {
    local w="${1:-$UI_W}" i out=""
    for (( i = 0; i < w; i++ )); do out+="$BX_H"; done
    printf '%s' "$out"
}
ui_top() { printf '%s\n' "${g1}${BX_TL}$(ui_rule "$(( UI_W + 2 ))")${BX_TR}${nc}"; }
ui_mid() { printf '%s\n' "${g1}${BX_ML}$(ui_rule "$(( UI_W + 2 ))")${BX_MR}${nc}"; }
ui_bot() { printf '%s\n' "${g1}${BX_BL}$(ui_rule "$(( UI_W + 2 ))")${BX_BR}${nc}"; }
ui_line() {
    local txt="${1:-}" vis pad
    vis="$(ui_vlen "$txt")"; pad=$(( UI_W - vis )); (( pad < 0 )) && pad=0
    printf '%s\n' "${g1}${BX_V}${nc} ${txt}$(ui_pad "$pad") ${g1}${BX_V}${nc}"
}
# Pad to an exact column width, truncating overlong values with a tilde so a
# 32-character username can never break the frame.
ui_fit() {
    local w="${1:-10}" s="${2:-}"
    if (( ${#s} > w )); then printf '%s~' "${s:0:$(( w - 1 ))}"
    else printf '%-*s' "$w" "$s"; fi
}
ui_kv() { ui_line "${g0}$(printf '%-9s' "${1}")${nc} ${g1}${GL_DOT}${nc} ${gw}${2}${nc}"; }
ui_item() {
    local a="${g2}${1}${nc}${g0})${nc} ${gw}$(printf '%-24s' "${2}")${nc}"
    if [[ -n "${3:-}" ]]; then
        ui_line "${a} ${g2}${3}${nc}${g0})${nc} ${gw}${4}${nc}"
    else
        ui_line "$a"
    fi
}
ui_sector() { ui_line "${g0}${GL_ARROW} ${1}${nc}"; }
ui_pill() {
    case "${1:-}" in
        on|ok|up)  printf '%s' "${g2}[ ONLINE  ]${nc}" ;;
        off|down)  printf '%s' "${gr}[ OFFLINE ]${nc}" ;;
        warn)      printf '%s' "${gy}[ DEGRADED]${nc}" ;;
        armed)     printf '%s' "${g2}[ ARMED   ]${nc}" ;;
        unarmed)   printf '%s' "${gr}[ UNARMED ]${nc}" ;;
        *)         printf '%s' "${g0}[ UNKNOWN ]${nc}" ;;
    esac
}
ui_bar() {
    local p="${1:-0}" w="${2:-20}" f i out=""
    [[ "$p" =~ ^[0-9]+$ ]] || p=0; (( p > 100 )) && p=100
    f=$(( p * w / 100 ))
    for (( i = 0; i < w; i++ )); do
        if (( i < f )); then out+="$GL_FULL"; else out+="$GL_EMPTY"; fi
    done
    if   (( p >= 90 )); then printf '%s' "${gr}${out}${nc}"
    elif (( p >= 70 )); then printf '%s' "${gy}${out}${nc}"
    else                     printf '%s' "${g2}${out}${nc}"; fi
}
ui_ok()   { printf '%s\n' "  ${g2}[OK]${nc} ${1}"; }
ui_warn() { printf '%s\n' "  ${gy}[!!]${nc} ${1}"; }
ui_err()  { printf '%s\n' "  ${gr}[xx]${nc} ${1}"; }
ui_info() { printf '%s\n' "  ${g0}[::]${nc} ${1}"; }
ui_title()  { ui_mid; ui_line "${gb} ${1} ${nc}"; ui_mid; }
ui_banner() { ui_top; ui_line "${gb} ${1} ${nc}"; ui_bot; }
ui_screen() { ui_top; ui_line "${gb} ${1} ${nc}"; ui_mid; }
ui_head()   { ui_line "${g0}${1}${nc}"; ui_line "${g0}$(ui_rule "$UI_W")${nc}"; }
ui_pause()  { printf '%s' "  ${g0}${GL_ARROW}${nc} press ${g2}ENTER${nc} to return "; read -r _ || true; }
ui_prompt() {
    local __l="$1" __v="$2" __r=""
    printf '%s' "  ${g2}${GL_ARROW}${nc} ${gw}${__l}${nc} "
    read -r __r || true
    printf -v "$__v" '%s' "$__r"
}

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
    # Data gathering is unchanged; only the rendering below is new.
    local domain uptime_str accounts core guard
    domain="$(cat "${ASX_DIR}/domain" 2>/dev/null || echo 'not set')"
    uptime_str="$(uptime -p 2>/dev/null || echo '?')"
    accounts="$(awk -F',' 'NR>1 && $1 != "" {c++} END{print c+0}' "$CSV_DB" 2>/dev/null || echo 0)"
    if systemctl is-active --quiet xray 2>/dev/null; then
        if systemctl is-active --quiet shadow-tls 2>/dev/null; then core="on"; else core="warn"; fi
    else core="off"; fi
    if iptables -nL ASX-TORRENT-IN >/dev/null 2>&1; then guard="armed"; else guard="unarmed"; fi

    ui_top
    ui_line "${g2}   A U T O S C R I P T X${nc}  ${g0}//${nc}  ${gw}CONTROL CONSOLE${nc}"
    ui_line "${g0}   secure access gateway ${GL_DOT} v4.4.3-hardened${nc}"
    ui_mid
    ui_kv "NODE"     "$domain"
    ui_kv "XRAY"     "$(_get_xray_ver)"
    ui_kv "UPTIME"   "$uptime_str"
    ui_kv "ACCOUNTS" "$accounts provisioned"
    ui_line "${g0}$(printf '%-9s' CORE)${nc} ${g1}${GL_DOT}${nc} $(ui_pill "$core")   ${g0}GUARD${nc} $(ui_pill "$guard")"
    ui_bot
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
    # Reality requires xtls-rprx-vision; all other VLESS tags keep flow empty.
    # Tag tests are exact-first so vless-reality is never given flow="".
    json_edit "$XRAY_CONF" "$CFG_LOCK"       --arg user "$user" --arg uuid "$uuid" --arg tpw "$tpw" --arg rflow "xtls-rprx-vision" '
      .inbounds |= map(
        if   .tag == "vless-reality" and .settings.clients
          then .settings.clients += [{id:$uuid, flow:$rflow, email:$user}]
        elif (.tag|test("vless")) and .settings.clients
          then .settings.clients += [{id:$uuid, flow:"", email:$user}]
        elif (.tag|test("vmess")) and .settings.clients
          then .settings.clients += [{id:$uuid, alterId:0, email:$user}]
        elif (.tag|test("trojan")) and .settings.clients
          then .settings.clients += [{password:$tpw, email:$user}]
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
    # Always the VPS internet IP — never the private VPC NIC (e.g. 10.x).
    PUBLIC_IP="$(get_public_ip)"
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
        echo -e "${red}  User '$u_name' already exists.${nc}"; ui_pause; return
    fi
    repair_xhttp_clients
    repair_reality_stls_clients "$XRAY_CONF" 2>/dev/null || true

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

    # --- VLESS Reality (xtls-rprx-vision) + ShadowTLS ---
    local r_pbk r_sid r_sni r_port st_pass st_port r_host
    r_pbk="$(_asx_reality_pbk)"
    r_sid="$(_asx_reality_sid)"
    r_sni="$(_asx_reality_sni)"
    r_port="$(_asx_port_reality)"
    st_pass="$(_asx_stls_pass)"
    st_port="$(_asx_port_stls)"
    # Reality/ShadowTLS must target the server public IP (SNI stays REALITY_SNI).
    r_host="${PUBLIC_IP}"
    if [[ -z "$r_host" ]] || is_private_ipv4 "$r_host"; then
        # Last attempt without cache in case the cached file was a private IP.
        rm -f "${ASX_DIR}/public_ip" 2>/dev/null || true
        r_host="$(get_public_ip)"
    fi
    if [[ -z "$r_host" ]] || is_private_ipv4 "$r_host"; then
        echo -e "${yellow}WARNING: could not resolve a public server IP (got '${r_host:-empty}').${nc}"
        echo -e "${yellow}Fix network egress or set ${ASX_DIR}/public_ip manually, then recreate links.${nc}"
    fi

    if [[ -n "$r_pbk" && -n "$r_sid" ]]; then
        echo -e "\n${blue}-- VLESS Reality (TCP ${r_port}, flow=xtls-rprx-vision, SNI ${r_sni}) --${nc}"
        echo "vless://${u_uuid}@${r_host}:${r_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${r_sni}&fp=chrome&pbk=${r_pbk}&sid=${r_sid}&type=tcp&headerType=none#${u_name}-VLESS-REALITY"
        echo -e "  pbk : ${green}${r_pbk}${nc}"
        echo -e "  sid : ${green}${r_sid}${nc}"
        echo -e "  dest: ${green}${r_sni}:443${nc}"
    else
        echo -e "\n${yellow}-- VLESS Reality: credentials.env missing pbk/sid (re-run configure / update) --${nc}"
    fi

    if [[ -n "$st_pass" ]]; then
        echo -e "\n${blue}-- ShadowTLS v3 + VLESS (public ${st_port} -> local Xray TCP) --${nc}"
        echo -e "  Server   : ${green}${r_host}${nc}"
        echo -e "  Port     : ${green}${st_port}${nc}"
        echo -e "  Password : ${green}${st_pass}${nc}"
        echo -e "  SNI/TLS  : ${green}${r_sni}${nc}"
        echo -e "  Backend  : VLESS TCP (encryption=none, flow=none)"
        # Composite share link used by several panels/clients (STLS wrapper + VLESS uuid).
        echo "shadowtls://v3:${st_pass}@${r_host}:${st_port}?sni=${r_sni}&peer=${r_sni}#${u_name}-ShadowTLS"
        echo "vless://${u_uuid}@${r_host}:${st_port}?encryption=none&flow=&security=none&type=tcp&headerType=none&sni=${r_sni}#${u_name}-VLESS-via-ShadowTLS"
        echo -e "  ${g0}Client note: enable ShadowTLS v3 plugin/outbound with password above, then chain VLESS UUID.${nc}"
    else
        echo -e "\n${yellow}-- ShadowTLS: password not found in credentials.env --${nc}"
    fi
    echo ""
    ui_pause
}

delete_account() {
    show_header; migrate_csv
    ui_banner "DELETE ACCOUNT"
    if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1{f=1;exit} END{exit !f}' "$CSV_DB"; then
        echo -e "  ${yellow}No accounts.${nc}"; ui_pause; return
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
        echo -e "${red}  Not found.${nc}"; ui_pause; return
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
    echo -e "${green}  Account '${u_name}' deleted.${nc}"; ui_pause
}

list_accounts() {
    show_header; migrate_csv
    ui_screen "ACTIVE ACCOUNTS"
    if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1{f=1;exit} END{exit !f}' "$CSV_DB"; then
        ui_line "${gy}no accounts provisioned${nc}"; ui_bot; ui_pause; return
    fi
    local today; today="$(date +%Y-%m-%d)"
    ui_head "$(printf '%-13s %-10s %-10s %-9s %-4s %s' USER EXPIRY USED LIMIT PCT STATE)"
    while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
        [[ "$name" == "Username" ]] && continue
        limit_gb="${limit_gb:-0}"; used_bytes="$(echo "${used_bytes:-0}"|tr -dc '0-9')"; used_bytes="${used_bytes:-0}"
        local lstr pct status
        if [[ "$limit_gb" -eq 0 ]]; then lstr="Unlimited"; pct="-"
        else lstr="${limit_gb} GB"; local lb=$(( limit_gb*1024*1024*1024 ))
             [[ $lb -gt 0 ]] && pct="$(( used_bytes*100/lb ))%" || pct="-"; fi
        if [[ "$exp" < "$today" ]]; then status="${gr}EXPIRED${nc}"
        elif [[ "$limit_gb" -gt 0 && "$used_bytes" -ge $(( limit_gb*1024*1024*1024 )) ]]; then status="${gr}CAPPED${nc}"
        else status="${g2}ACTIVE${nc}"; fi
        # Padding is applied to uncoloured text, then colour is wrapped around
        # it, so the frame stays aligned.
        ui_line "${gw}$(ui_fit 13 "$name")${nc} ${g0}$(ui_fit 10 "$exp")${nc} $(ui_fit 10 "$(fmt_bytes "$used_bytes")") $(printf '%-9s %-4s' "$lstr" "$pct") ${status}"
    done < "$CSV_DB"
    ui_bot; ui_pause
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
        ui_screen "BANDWIDTH TELEMETRY"
        if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1{f=1;exit} END{exit !f}' "$CSV_DB"; then
            ui_line "${gy}no accounts provisioned${nc}"; ui_bot; ui_pause; return
        fi
        local mw=20; (( UI_W < 68 )) && mw=10
        ui_head "$(printf '%-13s %-10s %-9s %-*s %s' USER USED LIMIT "$(( mw + 6 ))" METER STATE)"
        while IFS=',' read -r name pass uuid trojan exp limit_gb used_bytes; do
            [[ "$name" == "Username" ]] && continue
            limit_gb="${limit_gb:-0}"; used_bytes="$(echo "${used_bytes:-0}"|tr -dc '0-9')"; used_bytes="${used_bytes:-0}"
            local lstr pct status meter p=0
            if [[ "$limit_gb" -eq 0 ]]; then
                lstr="Unlimited"; pct="-"; status="${g2}ACTIVE${nc}"
                meter="${g0}$(ui_pad "$mw")${nc}"
            else
                lstr="${limit_gb} GB"; local lb=$(( limit_gb*1024*1024*1024 ))
                [[ $lb -gt 0 ]] && p=$(( used_bytes*100/lb )); pct="${p}%"
                meter="$(ui_bar "$p" "$mw")"
                if   [[ $used_bytes -ge $lb ]]; then status="${gr}CAPPED${nc}"
                elif [[ $p -ge 80 ]]; then status="${gy}WARNING${nc}"
                else status="${g2}ACTIVE${nc}"; fi
            fi
            ui_line "${gw}$(ui_fit 13 "$name")${nc} $(ui_fit 10 "$(fmt_bytes "$used_bytes")") $(printf '%-9s' "$lstr") ${meter} $(printf '%-5s' "$pct") ${status}"
        done < "$CSV_DB"
        ui_mid
        ui_line "${g2}r${nc}${g0})${nc} ${gw}Reset counter${nc}   ${g2}s${nc}${g0})${nc} ${gw}Set limit${nc}   ${gr}0${nc}${g0})${nc} ${gw}Back${nc}"
        ui_bot
        local o; ui_prompt "select" o
        case "$o" in r|R) _bw_reset_user;; s|S) _bw_set_limit;; 0) return;; *) sleep 1;; esac
    done
}

service_status() {
    show_header
    ui_screen "SERVICE MATRIX"
    local svc
    for svc in xray shadow-tls nginx dropbear stunnel4 squid fail2ban ws-proxy xray-limit-monitor asx-torrent-watch; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            ui_line "$(ui_pill on)  ${gw}${svc}${nc}"
        else
            ui_line "$(ui_pill off)  ${g0}${svc}${nc}"
        fi
    done
    ui_bot; ui_pause
}
restart_services() {
    show_header
    ui_screen "SERVICE RESTART SEQUENCE"
    local svc
    for svc in xray shadow-tls nginx dropbear stunnel4 squid fail2ban xray-limit-monitor asx-torrent-watch; do
        if systemctl restart "$svc" >/dev/null 2>&1; then
            ui_line "${g2}[ RESTARTED ]${nc}  ${gw}${svc}${nc}"
        else
            ui_line "${gy}[  FAILED   ]${nc}  ${g0}${svc}${nc}"
        fi
    done
    ui_bot; ui_pause
}
system_info() {
    show_header
    ui_screen "HOST DIAGNOSTICS"
    local lip pip
    ui_kv "OS"     "$(grep PRETTY_NAME /etc/os-release 2>/dev/null|cut -d= -f2|tr -d '\"')"
    ui_kv "KERNEL" "$(uname -r)"
    ui_kv "CPU"    "$(nproc) core(s)"
    ui_kv "RAM"    "$(free -h|awk '/^Mem/{print $3" used / "$2" total"}')"
    ui_kv "DISK"   "$(df -h /|awk 'NR==2{print $3" used / "$2" ("$5")"}')"
    lip="$(hostname -I|awk '{print $1}')"
    pip="$(get_public_ip)"
    ui_kv "IP"     "$pip"
    ui_kv "LOCAL"  "$lip"
    ui_kv "DOMAIN" "$(cat "${ASX_DIR}/domain" 2>/dev/null || echo 'not set')"
    ui_kv "UPTIME" "$(uptime -p 2>/dev/null)"
    ui_bot; ui_pause
}
change_domain() {
    show_header; ui_banner "CHANGE DOMAIN"
    echo -e "  Current: $(cat "${ASX_DIR}/domain" 2>/dev/null || echo 'not set')\n"
    read -rp "  New domain (Enter to cancel): " nd
    nd="$(printf '%s' "$nd" | tr -d '[:space:]')"
    [[ -z "$nd" ]] && { echo -e "  ${yellow}Cancelled.${nc}"; ui_pause; return; }
    validate_domain "$nd" || { echo -e "${red}  Invalid domain.${nc}"; ui_pause; return; }
    printf '%s\n' "$nd" > "${ASX_DIR}/domain"
    local esc; esc="$(printf '%s' "$nd" | sed 's/[&/\]/\\&/g')"
    sed -i "s|server_name .*;|server_name ${esc};|g" /etc/nginx/conf.d/reverse-proxy.conf 2>/dev/null || true
    sed -i "s|server_name .*;|server_name ${esc};|g" /etc/nginx/conf.d/xhttp-port80.conf  2>/dev/null || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    echo -e "\n  ${green}Domain updated to ${nd}.${nc}"; ui_pause
}
edit_banner() {
    show_header; local bf="${ASX_DIR}/banner"
    ui_banner "EDIT SSH BANNER"; cat "$bf" 2>/dev/null || echo "(empty)"
    echo -e "\n  ${green}1)${nc} Edit  ${green}2)${nc} Clear  ${green}0)${nc} Cancel"
    read -rp "  Select: " c
    case "$c" in
        1) nano "$bf"; systemctl restart dropbear >/dev/null 2>&1 || true; echo -e "${green}Updated.${nc}";;
        2) : > "$bf"; systemctl restart dropbear >/dev/null 2>&1 || true; echo -e "${green}Cleared.${nc}";;
        *) echo -e "${yellow}Cancelled.${nc}";;
    esac
    ui_pause
}
edit_response() {
    show_header; local rf="${ASX_DIR}/response"
    ui_banner "EDIT 101 WEBSOCKET RESPONSE"
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
    ui_pause
}
do_update() {
    show_header
    echo -e "${blue}Self-update from the SAME repository as this install.${nc}"
    echo -e "Source: ${yellow}__SELF_UPDATE_URL__${nc}\n"
    read -rp "Type UPDATE to proceed: " c
    [[ "$c" == "UPDATE" ]] || { echo "Cancelled."; ui_pause; return; }
    local up; up="$(mktemp /root/.asx_upd.XXXXXX.sh)"
    if curl -fsSL -H "User-Agent: AutoScriptX-Deployment" --max-time 30 "__SELF_UPDATE_URL__" -o "$up"; then
        chmod +x "$up"; bash "$up" --update-only; rm -f "$up"
    else echo -e "${red}Fetch failed.${nc}"; rm -f "$up"; fi
    ui_pause
}
torrent_guard() {
    show_header
    ui_screen "TORRENT GUARD // THREAT CONSOLE"
    local conf="${ASX_DIR}/antitorrent.conf" autos
    autos="$(awk -F= '/^AUTOSUSPEND=/{print $2}' "$conf" 2>/dev/null | tail -1)"; autos="${autos:-0}"

    if systemctl is-active --quiet asx-torrent-watch 2>/dev/null; then
        ui_line "${g0}$(printf '%-14s' WATCHDOG)${nc} $(ui_pill on)"
    else
        ui_line "${g0}$(printf '%-14s' WATCHDOG)${nc} $(ui_pill off)"
    fi
    if iptables -nL ASX-TORRENT-IN >/dev/null 2>&1; then
        ui_line "${g0}$(printf '%-14s' 'PACKET FILTER')${nc} $(ui_pill armed)"
    else
        ui_line "${g0}$(printf '%-14s' 'PACKET FILTER')${nc} $(ui_pill unarmed)"
        ui_line "${g0}   run: install.sh --antitorrent-only${nc}"
    fi
    if jq -e '[.routing.rules[]?|select((.protocol//[])|index("bittorrent"))]|length>0' "$XRAY_CONF" >/dev/null 2>&1 \
       && jq -e '[.inbounds[]?|select(.tag!="api" and (.sniffing.enabled//false))]|length>0' "$XRAY_CONF" >/dev/null 2>&1; then
        ui_line "${g0}$(printf '%-14s' 'XRAY POLICY')${nc} $(ui_pill armed)  ${g0}sniffing on${nc}"
    else
        ui_line "${g0}$(printf '%-14s' 'XRAY POLICY')${nc} $(ui_pill warn)  ${g0}incomplete${nc}"
    fi
    if [[ "$autos" == "1" ]]; then
        ui_line "${g0}$(printf '%-14s' 'AUTO-SUSPEND')${nc} ${g2}ENABLED${nc}  ${g0}offenders cut off${nc}"
    else
        ui_line "${g0}$(printf '%-14s' 'AUTO-SUSPEND')${nc} ${gy}LOG ONLY${nc}"
    fi

    ui_title "KERNEL INTERCEPTS"
    # Here-strings instead of process substitution: no /dev/fd dependency.
    local ln taps hits
    taps="$( { iptables -nvL ASX-TORRENT-IN  2>/dev/null | awk 'NR>2 && $1+0>0 {printf "  IN   %-10s pkts  %s %s\n", $1, $3, $4}';
               iptables -nvL ASX-TORRENT-OUT 2>/dev/null | awk 'NR>2 && $1+0>0 {printf "  OUT  %-10s pkts  %s %s\n", $1, $3, $4}'; } | head -12 )"
    if [[ -n "$taps" ]]; then
        while IFS= read -r ln; do
            [[ -z "$ln" ]] && continue
            ui_line "${g1}$(ui_fit "$(( UI_W - 1 ))" "$ln")${nc}"
        done <<< "$taps"
    else
        ui_line "${g0}no intercepts recorded${nc}"
    fi

    ui_title "P2P ATTEMPTS PER ACCOUNT"
    hits="$(awk -F',' 'NF>=3 {printf "  %-22s %s hits\n", $1, $3}' /var/lib/AutoScriptX/torrent-hits.csv 2>/dev/null | head -12)"
    if [[ -n "$hits" ]]; then
        while IFS= read -r ln; do
            [[ -z "$ln" ]] && continue
            ui_line "${gw}$(ui_fit "$(( UI_W - 1 ))" "$ln")${nc}"
        done <<< "$hits"
    else
        ui_line "${g0}no attempts recorded${nc}"
    fi

    ui_mid
    ui_line "${g2}1${nc}${g0})${nc} ${gw}Toggle auto-suspend${nc}   ${g2}2${nc}${g0})${nc} ${gw}Zero counters${nc}"
    ui_line "${g2}3${nc}${g0})${nc} ${gw}Clear hit records${nc}     ${gr}0${nc}${g0})${nc} ${gw}Back${nc}"
    ui_bot
    local c; ui_prompt "select" c
    case "$c" in
        1) if [[ "$autos" == "1" ]]; then sed -i 's/^AUTOSUSPEND=.*/AUTOSUSPEND=0/' "$conf"
           else sed -i 's/^AUTOSUSPEND=.*/AUTOSUSPEND=1/' "$conf"; fi
           systemctl restart asx-torrent-watch >/dev/null 2>&1 || true
           ui_ok "Policy updated.";;
        2) iptables -Z ASX-TORRENT-IN >/dev/null 2>&1 || true
           iptables -Z ASX-TORRENT-OUT >/dev/null 2>&1 || true
           ui_ok "Counters zeroed.";;
        3) : > /var/lib/AutoScriptX/torrent-hits.csv 2>/dev/null || true
           ui_ok "Hit records cleared.";;
        *) ;;
    esac
    ui_pause
}
full_uninstall() {
    [[ -t 0 ]] || { echo "Uninstall requires an interactive TTY."; return 1; }
    clear
    echo -e "${red}=== AutoScriptX FULL UNINSTALL ===${nc}"
    echo -e "Removes Xray, all accounts, nginx/dropbear/squid/stunnel/fail2ban configs,"
    echo -e "badvpn, ws-proxy, gum, monitor, cron jobs, iptables rules, and script dirs."
    echo -e "Core OS tools, SSH host keys, and SSL certs are kept.\n"
    read -rp "  STEP 1/2 - type UNINSTALL to continue: " c1
    [[ "$c1" == "UNINSTALL" ]] || { echo -e "${green}Aborted.${nc}"; ui_pause; return 0; }
    read -rp "  STEP 2/2 - type YES to begin: " c2
    [[ "$c2" == "YES" ]] || { echo -e "${green}Aborted.${nc}"; ui_pause; return 0; }

    local svc
    for svc in xray shadow-tls xray-limit-monitor asx-torrent-watch ws-proxy nginx dropbear stunnel4 squid fail2ban \
               badvpn-udpgw@7200 badvpn-udpgw@7300 netfilter-persistent; do
        systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
    done
    rm -rf /etc/systemd/system/xray.service /etc/systemd/system/shadow-tls.service \
           /etc/systemd/system/xray-limit-monitor.service \
           /etc/systemd/system/ws-proxy.service /etc/systemd/system/badvpn-udpgw@.service \
           /etc/systemd/system/nginx.service.d
    systemctl daemon-reload >/dev/null 2>&1 || true
    apt-get purge -y stunnel4 dropbear squid fail2ban nginx \
        netfilter-persistent iptables-persistent vnstat >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
    rm -f /usr/local/bin/xray /usr/local/bin/geoip.dat /usr/local/bin/geosite.dat           /usr/local/bin/shadow-tls /usr/local/bin/shadow-tls-run
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
    iptables -D INPUT -p tcp --dport 8443 -j ACCEPT >/dev/null 2>&1 || true
    iptables -D INPUT -p tcp --dport 8444 -j ACCEPT >/dev/null 2>&1 || true
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


# ---------------------------------------------------------------------------
# VLESS Reality config lab — generate client configs with alternate SNIs
# and optionally register those SNIs on the server Reality inbound.
# ---------------------------------------------------------------------------
_reality_server_names() {
    jq -r '.inbounds[]?|select(.tag=="vless-reality")|.streamSettings.realitySettings.serverNames//[]|.[]' \
        "$XRAY_CONF" 2>/dev/null || true
}

_reality_dest_current() {
    jq -r '.inbounds[]?|select(.tag=="vless-reality")|.streamSettings.realitySettings.dest//empty' \
        "$XRAY_CONF" 2>/dev/null || true
}

_sni_clean() {
    local h="$1"
    h="$(printf '%s' "$h" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    h="${h#https://}"; h="${h#http://}"; h="${h%%/*}"; h="${h%%:*}"
    printf '%s' "$h"
}

_dest_sans() {
    local host="$1" port="${2:-443}"
    command -v openssl >/dev/null 2>&1 || return 0
    timeout 8 openssl s_client -connect "${host}:${port}" -servername "$host" </dev/null 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | grep -o 'DNS:[^,]*' | sed 's/^DNS://' | tr -d ' ' | sed '/^$/d'
}

_san_match() {
    local sni="$1"; shift
    local san suffix prefix
    sni="$(printf '%s' "$sni" | tr '[:upper:]' '[:lower:]')"
    for san in "$@"; do
        [[ -z "$san" ]] && continue
        san="$(printf '%s' "$san" | tr '[:upper:]' '[:lower:]')"
        [[ "$san" == "$sni" ]] && return 0
        case "$san" in
            \*.*)
                suffix="${san#\*}"
                case "$sni" in
                    *"$suffix")
                        prefix="${sni%"$suffix"}"
                        if [[ -n "$prefix" && "$prefix" != *.* ]]; then return 0; fi
                        ;;
                esac
                ;;
        esac
    done
    return 1
}

_dest_chain_bytes() {
    local host="$1" port="${2:-443}" tmp total=0 f b
    command -v openssl >/dev/null 2>&1 || { printf '0'; return 0; }
    tmp="$(mktemp -d)"
    timeout 8 openssl s_client -connect "${host}:${port}" -servername "$host" -showcerts </dev/null 2>/dev/null \
        | awk -v d="$tmp" '/BEGIN CERTIFICATE/{n++} n{print > (d "/c" n ".pem")}' 2>/dev/null || true
    for f in "$tmp"/c*.pem; do
        [[ -f "$f" ]] || continue
        b="$(openssl x509 -in "$f" -outform DER 2>/dev/null | wc -c)"
        if [[ "$b" =~ ^[0-9]+$ ]]; then total=$(( total + b )); fi
    done
    rm -rf "$tmp"
    printf '%s' "$total"
}

_probe_site() {
    local host="$1" port="${2:-443}" ok=1 bytes
    echo ""
    echo -e "  ${g0}Probing ${host}:${port} ...${nc}"
    if ! getent hosts "$host" >/dev/null 2>&1; then
        echo -e "  ${gr}[FAIL]${nc} DNS does not resolve from this VPS"
        return 1
    fi
    echo -e "  ${g2}[OK]${nc}   DNS resolves"
    if timeout 8 openssl s_client -connect "${host}:${port}" -servername "$host" -tls1_3 </dev/null >/dev/null 2>&1; then
        echo -e "  ${g2}[OK]${nc}   TLS 1.3 supported"
    else
        echo -e "  ${gr}[FAIL]${nc} No TLS 1.3 - Reality requires it"
        ok=0
    fi
    bytes="$(_dest_chain_bytes "$host" "$port")"
    if [[ "${bytes:-0}" -gt 0 ]]; then
        if [[ "$bytes" -le 7000 ]]; then
            echo -e "  ${g2}[OK]${nc}   cert chain ${bytes} B (Reality buffer 8192 B)"
        elif [[ "$bytes" -le 8192 ]]; then
            echo -e "  ${gy}[WARN]${nc} cert chain ${bytes} B - near the 8192 B limit"
        else
            echo -e "  ${gr}[FAIL]${nc} cert chain ${bytes} B > 8192 B - handshakes WILL reset"
            ok=0
        fi
    fi
    local -a sans=()
    mapfile -t sans < <(_dest_sans "$host" "$port")
    if [[ ${#sans[@]} -gt 0 ]]; then
        echo -e "  ${g0}       SANs: ${sans[*]:0:6}${nc}"
        if _san_match "$host" "${sans[@]}"; then
            echo -e "  ${g2}[OK]${nc}   certificate covers ${host}"
        else
            echo -e "  ${gr}[FAIL]${nc} certificate does NOT cover ${host}"
            ok=0
        fi
    else
        echo -e "  ${gy}[WARN]${nc} could not read SANs"
    fi
    if [[ "$ok" -eq 1 ]]; then return 0; fi
    return 1
}

_reality_pick_user() {
    RE_USER=""; RE_UUID=""
    migrate_csv
    if [[ ! -s "$CSV_DB" ]] || ! awk -F',' 'NR>1 && $1 != "" {f=1;exit} END{exit !f}' "$CSV_DB"; then
        echo -e "  ${gy}No accounts in CSV. Enter UUID manually.${nc}"
        read -rp "  UUID: " RE_UUID
        RE_UUID="$(printf '%s' "$RE_UUID" | tr -d '[:space:]')"
        [[ -n "$RE_UUID" ]] || return 1
        RE_USER="test"
        return 0
    fi
    echo ""
    printf "  %-4s %-18s %-38s\n" "#" "USER" "UUID"
    local i=0 name pass uuid pick
    local -a _users=() _uuids=()
    while IFS=',' read -r name pass uuid _rest; do
        [[ "$name" == "Username" || -z "$name" ]] && continue
        i=$((i + 1))
        _users+=("$name"); _uuids+=("$uuid")
        printf "  %-4s %-18s %-38s\n" "$i" "$name" "$uuid"
    done < "$CSV_DB"
    echo ""
    read -rp "  Select # (or paste UUID): " pick
    pick="$(printf '%s' "$pick" | tr -d '[:space:]')"
    [[ -z "$pick" ]] && return 1
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#_users[@]} )); then
        RE_USER="${_users[$((pick - 1))]}"; RE_UUID="${_uuids[$((pick - 1))]}"
        return 0
    fi
    if [[ "$pick" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        RE_UUID="$pick"
        RE_USER="$(awk -F',' -v u="$pick" 'NR>1 && $3==u {print $1; exit}' "$CSV_DB" 2>/dev/null || echo test)"
        [[ -n "$RE_USER" ]] || RE_USER="test"
        return 0
    fi
    if grep -q "^${pick}," "$CSV_DB" 2>/dev/null; then
        RE_USER="$pick"
        RE_UUID="$(awk -F',' -v u="$pick" 'NR>1 && $1==u {print $3; exit}' "$CSV_DB")"
        [[ -n "$RE_UUID" ]] || return 1
        return 0
    fi
    echo -e "  ${gr}Invalid selection.${nc}"
    return 1
}

_reality_pick_active_sni() {
    RE_SNI=""
    local -a names=()
    mapfile -t names < <(_reality_server_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        echo -e "  ${gr}No serverNames on the Reality inbound.${nc}"
        return 1
    fi
    if [[ ${#names[@]} -eq 1 ]]; then
        RE_SNI="${names[0]}"
        return 0
    fi
    echo ""
    echo -e "  ${g0}Active SNIs accepted by this server:${nc}"
    local i=0 n pick
    for n in "${names[@]}"; do
        i=$((i + 1))
        printf "  ${g2}%d${nc}) %s\n" "$i" "$n"
    done
    echo ""
    read -rp "  Select SNI [1]: " pick
    pick="$(printf '%s' "${pick:-1}" | tr -d '[:space:]')"
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#names[@]} )); then
        RE_SNI="${names[$((pick - 1))]}"
        return 0
    fi
    echo -e "  ${gr}Invalid.${nc}"
    return 1
}

_reality_live_material() {
    LIVE_PORT=""; LIVE_PRIV=""; LIVE_PBK=""; LIVE_SID=""; LIVE_DEST=""
    local base='.inbounds[]?|select(.tag=="vless-reality")'
    LIVE_PORT="$(jq -r "${base}|.port // empty" "$XRAY_CONF" 2>/dev/null | head -1)"
    LIVE_PRIV="$(jq -r "${base}|.streamSettings.realitySettings.privateKey // empty" "$XRAY_CONF" 2>/dev/null | head -1)"
    LIVE_DEST="$(jq -r "${base}|.streamSettings.realitySettings.dest // empty" "$XRAY_CONF" 2>/dev/null | head -1)"
    LIVE_SID="$(jq -r "${base}|.streamSettings.realitySettings.shortIds//[]|map(select(.!=\"\"))|.[0]//\"\"" "$XRAY_CONF" 2>/dev/null | head -1)"
    if [[ -n "$LIVE_PRIV" ]]; then
        LIVE_PBK="$("$XRAY_BIN" x25519 -i "$LIVE_PRIV" 2>/dev/null | awk -F: 'tolower($1) ~ /password|public/ {sub(/^[^:]*:[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; exit}')"
        if [[ -z "$LIVE_PBK" ]]; then
            LIVE_PBK="$("$XRAY_BIN" x25519 -i "$LIVE_PRIV" 2>/dev/null | grep -Eo '[A-Za-z0-9_-]{40,60}' | head -1)"
        fi
    fi
    [[ -n "$LIVE_PBK"  ]] || LIVE_PBK="$(_asx_reality_pbk)"
    [[ -n "$LIVE_SID"  ]] || LIVE_SID="$(_asx_reality_sid)"
    [[ -n "$LIVE_PORT" ]] || LIVE_PORT="$(_asx_port_reality)"
}

_reality_print_configs() {
    local user="$1" uuid="$2" sni="$3" fp="${4:-chrome}"
    local host port pbk sid dest
    host="$(get_public_ip)"
    _reality_live_material
    port="$LIVE_PORT"; pbk="$LIVE_PBK"; sid="$LIVE_SID"; dest="$LIVE_DEST"

    if [[ -z "$pbk" || -z "$uuid" || -z "$host" ]]; then
        echo -e "  ${gr}Missing Reality material (pbk/uuid/public IP).${nc}"
        return 1
    fi

    local tag="${user}-REALITY"
    tag="${tag//[^A-Za-z0-9._-]/-}"
    local sid_q=""
    [[ -n "$sid" ]] && sid_q="&sid=${sid}"
    # Reality shortId is optional server-side (the inbound carries ["", <sid>]).
    # Emit the shortId key ONLY when a non-empty id exists, so clients never send
    # a blank shortId the server would reject. jq builds valid JSON either way.
    local sb_short xr_short
    if [[ -n "$sid" ]]; then
        sb_short="$(printf '"short_id": "%s"' "$sid")"
        xr_short="$(printf '"shortId": "%s",' "$sid")"
    else
        sb_short='"short_id": ""'
        xr_short=""
    fi

    echo ""
    echo -e "${g0}-- Connection summary --${nc}"
    echo -e "  Server     : ${g2}${host}${nc}"
    echo -e "  Port       : ${g2}${port}${nc}"
    echo -e "  UUID       : ${g2}${uuid}${nc}"
    echo -e "  Flow       : ${g2}xtls-rprx-vision${nc}"
    echo -e "  SNI        : ${g2}${sni}${nc}"
    echo -e "  Fingerprint: ${g2}${fp}${nc}"
    echo -e "  PublicKey  : ${g2}${pbk}${nc}"
    echo -e "  ShortId    : ${g2}${sid:-(empty)}${nc}"
    echo -e "  Dest (srv) : ${g2}${dest}${nc}"

    echo ""
    echo -e "${g0}-- vless:// share link --${nc}"
    echo "vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pbk}${sid_q}&type=tcp&headerType=none#${tag}"

    echo ""
    echo -e "${g0}-- sing-box outbound JSON --${nc}"
    cat <<REOF
{
  "type": "vless",
  "tag": "${tag}",
  "server": "${host}",
  "server_port": ${port},
  "uuid": "${uuid}",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "${sni}",
    "utls": { "enabled": true, "fingerprint": "${fp}" },
    "reality": { "enabled": true, "public_key": "${pbk}", ${sb_short} }
  },
  "packet_encoding": "xudp"
}
REOF

    echo ""
    echo -e "${g0}-- Xray outbound JSON --${nc}"
    cat <<REOF
{
  "protocol": "vless",
  "tag": "${tag}",
  "settings": {
    "vnext": [{
      "address": "${host}",
      "port": ${port},
      "users": [{ "id": "${uuid}", "encryption": "none", "flow": "xtls-rprx-vision" }]
    }]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "serverName": "${sni}",
      "fingerprint": "${fp}",
      "publicKey": "${pbk}",
      ${xr_short}
      "spiderX": "/"
    }
  }
}
REOF

    local ok_sni=0 ok_port=0 ok_uuid=0
    _reality_server_names | grep -qxF "$sni" && ok_sni=1
    ss -lnt 2>/dev/null | grep -q ":${port}[[:space:]]" && ok_port=1
    jq -e --arg u "$uuid" '.inbounds[]?|select(.tag=="vless-reality")|.settings.clients[]?|select(.id==$u)' \
        "$XRAY_CONF" >/dev/null 2>&1 && ok_uuid=1

    echo ""
    if [[ $ok_sni -eq 1 && $ok_port -eq 1 && $ok_uuid -eq 1 ]]; then
        echo -e "  ${g2}[VERIFIED]${nc} SNI accepted + port ${port} listening + UUID on Reality inbound."
    else
        [[ $ok_sni  -eq 1 ]] || echo -e "  ${gr}[BLOCKED]${nc} SNI ${sni} is not in serverNames - cannot authenticate."
        [[ $ok_port -eq 1 ]] || echo -e "  ${gr}[BLOCKED]${nc} xray is not listening on ${port}."
        [[ $ok_uuid -eq 1 ]] || echo -e "  ${gr}[BLOCKED]${nc} UUID not present on vless-reality."
        echo -e "  ${g0}Use option 7 (Diagnose + auto-repair).${nc}"
    fi
    return 0
}

_reality_switch_target() {
    local host="$1" port="${2:-443}"
    host="$(_sni_clean "$host")"
    validate_domain "$host" || { echo -e "  ${gr}Invalid hostname.${nc}"; return 1; }
    jq -e '.inbounds[]|select(.tag=="vless-reality")' "$XRAY_CONF" >/dev/null 2>&1 \
        || { echo -e "  ${gr}vless-reality inbound missing.${nc}"; return 1; }

    if ! _probe_site "$host" "$port"; then
        local go=""
        echo ""
        read -rp "  Probe failed. Switch anyway? [y/N]: " go
        [[ "$go" =~ ^[Yy]$ ]] || { echo -e "  ${gy}Cancelled.${nc}"; return 1; }
    fi

    local -a sans=() names=()
    mapfile -t sans < <(_dest_sans "$host" "$port")
    names+=("$host")
    local alt
    if [[ "$host" == www.* ]]; then alt="${host#www.}"; else alt="www.${host}"; fi
    if [[ ${#sans[@]} -gt 0 ]] && _san_match "$alt" "${sans[@]}"; then
        names+=("$alt")
    fi

    local backup; backup="${XRAY_CONF}.bak.$(date +%s)"
    cp -p "$XRAY_CONF" "$backup" 2>/dev/null || { echo -e "  ${gr}Backup failed.${nc}"; return 1; }

    local names_json
    names_json="$(printf '%s\n' "${names[@]}" | jq -R . | jq -s 'unique')"

    if ! json_edit "$XRAY_CONF" "$CFG_LOCK" --arg dest "${host}:${port}" --argjson names "$names_json" '
        .inbounds |= map(if .tag=="vless-reality" then
            .streamSettings.realitySettings.dest = $dest
            | .streamSettings.realitySettings.serverNames = $names
            | .streamSettings.realitySettings.show = true
          else . end)
        | .log.loglevel = "info"'; then
        cp -p "$backup" "$XRAY_CONF"
        rm -f "$backup"
        echo -e "  ${gr}Config edit failed; rolled back.${nc}"
        return 1
    fi

    if "$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null 2>&1; then
        systemctl restart xray >/dev/null 2>&1 || true
        sleep 1
        if systemctl is-active --quiet xray; then
            if [[ -f "$CREDS_ENV" ]]; then
                if grep -q '^REALITY_DEST=' "$CREDS_ENV"; then
                    sed -i "s|^REALITY_DEST=.*|REALITY_DEST=\"${host}:${port}\"|" "$CREDS_ENV"
                else
                    printf 'REALITY_DEST="%s"\n' "${host}:${port}" >> "$CREDS_ENV"
                fi
                if grep -q '^REALITY_SNI=' "$CREDS_ENV"; then
                    sed -i "s|^REALITY_SNI=.*|REALITY_SNI=\"${host}\"|" "$CREDS_ENV"
                else
                    printf 'REALITY_SNI="%s"\n' "$host" >> "$CREDS_ENV"
                fi
                chmod 600 "$CREDS_ENV"
            fi
            rm -f "$backup"
            echo ""
            echo -e "  ${g2}Target switched.${nc}"
            echo -e "  dest        : ${g2}${host}:${port}${nc}"
            echo -e "  serverNames : ${g2}${names[*]}${nc}"
            echo -e "  ${gy}All Reality clients must now use SNI ${host} (or an alias above).${nc}"
            return 0
        fi
    fi

    cp -p "$backup" "$XRAY_CONF"
    systemctl restart xray >/dev/null 2>&1 || true
    rm -f "$backup"
    echo -e "  ${gr}xray rejected the new target - rolled back to the previous working config.${nc}"
    return 1
}

_reality_add_alias() {
    local sni="$1" dest host port
    sni="$(_sni_clean "$sni")"
    validate_domain "$sni" || { echo -e "  ${gr}Invalid hostname.${nc}"; return 1; }
    dest="$(_reality_dest_current)"
    [[ -n "$dest" ]] || { echo -e "  ${gr}No dest configured.${nc}"; return 1; }
    host="${dest%%:*}"; port="${dest##*:}"
    [[ "$host" == "$port" ]] && port=443

    if _reality_server_names | grep -qxF "$sni"; then
        echo -e "  ${g0}Already registered: ${sni}${nc}"
        return 0
    fi

    local -a sans=()
    mapfile -t sans < <(_dest_sans "$host" "$port")
    if [[ ${#sans[@]} -eq 0 ]]; then
        echo -e "  ${gy}Could not read ${host} certificate SANs.${nc}"
    elif ! _san_match "$sni" "${sans[@]}"; then
        echo ""
        echo -e "  ${gr}${sni} is NOT covered by the ${host} certificate.${nc}"
        echo -e "  ${g0}SANs: ${sans[*]:0:8}${nc}"
        echo -e "  ${g0}Reality forwards the handshake to dest, so this SNI would always fail.${nc}"
        echo -e "  ${g0}To test ${sni}, use option 2 and switch the whole target to it.${nc}"
        return 1
    fi

    if json_edit "$XRAY_CONF" "$CFG_LOCK" --arg sni "$sni" '
        .inbounds |= map(if .tag=="vless-reality" then
            .streamSettings.realitySettings.serverNames =
              ((.streamSettings.realitySettings.serverNames // []) + [$sni] | unique)
          else . end)'; then
        if "$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null 2>&1; then
            systemctl restart xray >/dev/null 2>&1 || true
            echo -e "  ${g2}Alias SNI added: ${sni}${nc}"
            return 0
        fi
    fi
    echo -e "  ${gr}Failed to add alias.${nc}"
    return 1
}

_reality_remove_alias() {
    local sni="$1" dest host
    sni="$(_sni_clean "$sni")"
    dest="$(_reality_dest_current)"
    host="${dest%%:*}"
    if [[ "$sni" == "$host" ]]; then
        echo -e "  ${gr}Refusing to remove the primary SNI (matches dest ${host}).${nc}"
        return 1
    fi
    if json_edit "$XRAY_CONF" "$CFG_LOCK" --arg sni "$sni" '
        .inbounds |= map(if .tag=="vless-reality" then
            .streamSettings.realitySettings.serverNames =
              [ ((.streamSettings.realitySettings.serverNames // [])[]) | select(. != $sni) ]
          else . end)'; then
        systemctl restart xray >/dev/null 2>&1 || true
        echo -e "  ${g2}Removed: ${sni}${nc}"
        return 0
    fi
    return 1
}

_reality_diagnose() {
    local d port host
    _reality_live_material
    port="$LIVE_PORT"; d="$LIVE_DEST"
    echo -e "${g0}== Reality diagnostics ==${nc}"
    echo ""
    if systemctl is-active --quiet xray; then
        echo -e "  xray       : ${g2}active${nc}"
    else
        echo -e "  xray       : ${gr}inactive${nc}"
    fi
    if ss -lnt 2>/dev/null | grep -q ":${port}[[:space:]]"; then
        echo -e "  listen     : ${g2}${port} OK${nc}"
    else
        echo -e "  listen     : ${gr}${port} NOT listening${nc}"
    fi
    echo -e "  public IP  : $(get_public_ip)"
    echo -e "  pbk        : ${LIVE_PBK:-missing}"
    echo -e "  sid        : ${LIVE_SID:-(empty)}"
    echo -e "  dest       : ${d:-missing}"
    echo -e "  serverNames:"
    _reality_server_names | sed 's/^/    - /'
    echo ""
    echo -e "  Reality clients:"
    jq -r '.inbounds[]?|select(.tag=="vless-reality")|.settings.clients[]?|"    - \(.email // "?")  flow=\(.flow // "")  \(.id)"' \
        "$XRAY_CONF" 2>/dev/null || echo "    (none)"

    host="${d%%:*}"
    echo ""
    if [[ -n "$host" ]]; then
        local -a sans=() bad=()
        mapfile -t sans < <(_dest_sans "$host" 443)
        if [[ ${#sans[@]} -gt 0 ]]; then
            local n
            while IFS= read -r n; do
                [[ -z "$n" ]] && continue
                _san_match "$n" "${sans[@]}" || bad+=("$n")
            done < <(_reality_server_names)
            if [[ ${#bad[@]} -eq 0 ]]; then
                echo -e "  ${g2}[OK]${nc} every serverName is covered by the ${host} certificate"
            else
                echo -e "  ${gr}[PROBLEM]${nc} these serverNames are NOT served by ${host}:"
                printf '    - %s\n' "${bad[@]}"
                echo -e "  ${g0}Clients using them can never authenticate.${nc}"
            fi
        fi
        local bytes; bytes="$(_dest_chain_bytes "$host" 443)"
        if [[ "${bytes:-0}" -gt 8192 ]]; then
            echo -e "  ${gr}[PROBLEM]${nc} dest cert chain ${bytes} B > 8192 B - switch target (option 2)"
        fi
    fi

    echo ""
    echo -e "  Recent xray log:"
    journalctl -u xray -n 80 --no-pager 2>/dev/null \
        | grep -iE 'reality|invalid|handshake|failed' | tail -12 \
        || tail -20 /var/log/xray/error.log 2>/dev/null || echo "    (no hits)"
    echo ""
    echo -e "  ${g0}Live watch: journalctl -u xray -f   (then connect once)${nc}"
}

_reality_autorepair() {
    echo ""
    echo -e "  ${g0}Repairing...${nc}"

    json_edit "$XRAY_CONF" "$CFG_LOCK" --arg rflow "xtls-rprx-vision" '
      (first(.inbounds[]?|select(.tag=="vless-ws")|.settings.clients) // []) as $src
      | ($src|map({id:.id, email:(.email//.id), flow:$rflow})) as $rc
      | ($src|map({id:.id, email:(.email//.id), flow:""})) as $sc
      | .inbounds |= map(
          if .tag=="vless-reality" and ($rc|length)>0 then
            .settings.clients=$rc | .listen="0.0.0.0"
          elif .tag=="vless-stls" and ($sc|length)>0 then
            .settings.clients=$sc
          else . end)
      | .log.loglevel="info"' \
      && echo -e "  ${g2}[OK]${nc} clients synced from vless-ws"

    _reality_live_material
    if [[ -n "$LIVE_PBK" && -f "$CREDS_ENV" ]]; then
        if grep -q '^REALITY_PUBLIC_KEY=' "$CREDS_ENV"; then
            sed -i "s|^REALITY_PUBLIC_KEY=.*|REALITY_PUBLIC_KEY=\"${LIVE_PBK}\"|" "$CREDS_ENV"
        else
            printf 'REALITY_PUBLIC_KEY="%s"\n' "$LIVE_PBK" >> "$CREDS_ENV"
        fi
        chmod 600 "$CREDS_ENV"
        echo -e "  ${g2}[OK]${nc} pbk refreshed: ${LIVE_PBK}"
    fi

    local dest host
    dest="$(_reality_dest_current)"; host="${dest%%:*}"
    if [[ -n "$host" ]]; then
        local -a sans=() keep=()
        mapfile -t sans < <(_dest_sans "$host" 443)
        if [[ ${#sans[@]} -gt 0 ]]; then
            local n
            while IFS= read -r n; do
                [[ -z "$n" ]] && continue
                if _san_match "$n" "${sans[@]}"; then keep+=("$n"); fi
            done < <(_reality_server_names)
            if [[ ${#keep[@]} -eq 0 ]]; then keep=("$host"); fi
            local keep_json
            keep_json="$(printf '%s\n' "${keep[@]}" | jq -R . | jq -s 'unique')"
            json_edit "$XRAY_CONF" "$CFG_LOCK" --argjson names "$keep_json" '
              .inbounds |= map(if .tag=="vless-reality" then
                  .streamSettings.realitySettings.serverNames=$names
                else . end)' \
              && echo -e "  ${g2}[OK]${nc} serverNames pruned to: ${keep[*]}"
        fi

        local bytes bad=0
        bytes="$(_dest_chain_bytes "$host" 443)"
        timeout 6 openssl s_client -connect "${host}:443" -servername "$host" -tls1_3 </dev/null >/dev/null 2>&1 || bad=1
        [[ "${bytes:-0}" -gt 8192 ]] && bad=1
        if [[ "$bad" -eq 1 ]]; then
            echo -e "  ${gy}[!!]${nc} dest ${host} unusable - switching to www.cloudflare.com"
            _reality_switch_target "www.cloudflare.com" 443 >/dev/null 2>&1 \
                && echo -e "  ${g2}[OK]${nc} dest switched to www.cloudflare.com"
        fi
    fi

    if "$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null 2>&1; then
        systemctl restart xray >/dev/null 2>&1 || true
        echo -e "  ${g2}[OK]${nc} config valid, xray restarted"
    else
        echo -e "  ${gr}[FAIL]${nc} config test failed:"
        "$XRAY_BIN" run -test -config "$XRAY_CONF" 2>&1 | tail -15
    fi
}

reality_config_menu() {
    while true; do
        show_header
        ui_screen "VLESS REALITY // CONFIG LAB"
        local host port pbk sid dest
        host="$(get_public_ip)"
        _reality_live_material
        port="$LIVE_PORT"; pbk="$LIVE_PBK"; sid="$LIVE_SID"; dest="$LIVE_DEST"

        ui_kv "SERVER" "$host"
        ui_kv "PORT"   "$port"
        ui_kv "DEST"   "${dest:-missing}"
        ui_kv "PBK"    "${pbk:-missing}"
        ui_kv "SID"    "${sid:-(empty)}"
        ui_title "ACCEPTED SNI (serverNames)"
        local sn count=0
        while IFS= read -r sn; do
            [[ -z "$sn" ]] && continue
            count=$((count + 1))
            ui_line "  ${g1}${GL_DOT}${nc} ${gw}${sn}${nc}"
        done < <(_reality_server_names)
        (( count == 0 )) && ui_line "  ${gy}(none - Reality inbound missing?)${nc}"
        ui_line "${g0}  SNI must be served by dest. To test another site, use 2.${nc}"

        ui_mid
        ui_line "${g2}1${nc}${g0})${nc} ${gw}Generate client config${nc}"
        ui_line "${g2}2${nc}${g0})${nc} ${gw}Switch camouflage target (dest + SNI)${nc}"
        ui_line "${g2}3${nc}${g0})${nc} ${gw}Test a candidate site (no changes)${nc}"
        ui_line "${g2}4${nc}${g0})${nc} ${gw}Add alias SNI (same certificate)${nc}"
        ui_line "${g2}5${nc}${g0})${nc} ${gw}Remove alias SNI${nc}"
        ui_line "${g2}6${nc}${g0})${nc} ${gw}Show raw Reality inbound JSON${nc}"
        ui_line "${g2}7${nc}${g0})${nc} ${gw}Diagnose + auto-repair${nc}"
        ui_line "${gr}0${nc}${g0})${nc} ${gw}Back${nc}"
        ui_bot

        local c; ui_prompt "select" c
        case "$c" in
            1)
                local RE_USER="" RE_UUID="" RE_SNI="" fp=""
                _reality_pick_user || { ui_pause; continue; }
                _reality_pick_active_sni || { ui_pause; continue; }
                read -rp "  uTLS fingerprint [chrome]: " fp
                fp="$(printf '%s' "${fp:-chrome}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
                case "$fp" in
                    chrome|firefox|safari|ios|android|edge|360|qq|random|randomized) ;;
                    *) fp="chrome" ;;
                esac
                clear
                _reality_print_configs "$RE_USER" "$RE_UUID" "$RE_SNI" "$fp"
                ui_pause
                ;;
            2)
                clear
                ui_banner "SWITCH CAMOUFLAGE TARGET"
                echo -e "  ${g0}Reality relays the TLS handshake to dest, so dest and SNI move together.${nc}"
                echo -e "  ${g0}Current: ${dest}${nc}"
                echo ""
                echo -e "  ${g0}Known-good targets:${nc}"
                echo "    www.cloudflare.com   dl.google.com      www.bing.com"
                echo "    www.apple.com        www.amazon.com     www.samsung.com"
                echo -e "  ${gy}   avoid www.microsoft.com (cert chain exceeds the 8192 B buffer)${nc}"
                echo ""
                local nt=""
                read -rp "  New target host (Enter to cancel): " nt
                if [[ -z "$nt" ]]; then
                    echo -e "  ${gy}Cancelled.${nc}"; ui_pause; continue
                fi
                if _reality_switch_target "$nt" 443; then
                    echo ""
                    local gen=""
                    read -rp "  Generate a client config now? [Y/n]: " gen
                    if [[ -z "$gen" || "$gen" =~ ^[Yy]$ ]]; then
                        local RE_USER="" RE_UUID="" RE_SNI=""
                        if _reality_pick_user && _reality_pick_active_sni; then
                            clear
                            _reality_print_configs "$RE_USER" "$RE_UUID" "$RE_SNI" "chrome"
                        fi
                    fi
                fi
                ui_pause
                ;;
            3)
                clear
                ui_banner "TEST CANDIDATE SITE"
                local ct=""
                read -rp "  Host to test (Enter to cancel): " ct
                if [[ -z "$ct" ]]; then ui_pause; continue; fi
                ct="$(_sni_clean "$ct")"
                if _probe_site "$ct" 443; then
                    echo ""
                    echo -e "  ${g2}SUITABLE${nc} - use option 2 to switch to ${ct}."
                else
                    echo ""
                    echo -e "  ${gr}NOT SUITABLE${nc} as a Reality target."
                fi
                ui_pause
                ;;
            4)
                clear
                ui_banner "ADD ALIAS SNI"
                echo -e "  ${g0}Only names on the current dest certificate can be aliases.${nc}"
                echo -e "  ${g0}dest: ${dest}${nc}"
                echo ""
                local al=""
                read -rp "  Alias SNI (Enter to cancel): " al
                [[ -n "$al" ]] && _reality_add_alias "$al"
                ui_pause
                ;;
            5)
                clear
                echo "  Registered SNIs:"
                _reality_server_names | nl -w2 -s') '
                echo ""
                local rs=""
                read -rp "  SNI to remove (Enter to cancel): " rs
                [[ -n "$rs" ]] && _reality_remove_alias "$rs"
                ui_pause
                ;;
            6)
                clear
                jq '.inbounds[]?|select(.tag=="vless-reality")' "$XRAY_CONF" 2>/dev/null \
                    || echo "(vless-reality inbound not found)"
                ui_pause
                ;;
            7)
                clear
                _reality_diagnose
                echo ""
                local fix=""
                read -rp "  Run auto-repair now? [y/N]: " fix
                [[ "$fix" =~ ^[Yy]$ ]] && _reality_autorepair
                ui_pause
                ;;
            0) return ;;
            *) sleep 1 ;;
        esac
    done
}

while true; do
    show_header
    ui_top
    ui_sector "IDENTITY"
    ui_item "1" "Create Account"     "2" "Delete Account"
    ui_item "3" "List Accounts"
    ui_mid
    ui_sector "INFRASTRUCTURE"
    ui_item "4" "Service Status"     "5" "Restart Services"
    ui_item "6" "System Info"
    ui_mid
    ui_sector "CONFIGURATION"
    ui_item "7" "Change Domain"      "8" "Edit SSH Banner"
    ui_item "9" "Edit 101 Response"
    ui_mid
    ui_sector "PROXY LAB"
    ui_item "r" "VLESS Reality Config"
    ui_mid
    ui_sector "DEFENSE"
    ui_item "b" "Bandwidth Monitor"  "t" "Torrent Guard"
    ui_mid
    ui_sector "MAINTENANCE"
    ui_line "${gy}u${nc}${g0})${nc} ${gw}$(printf '%-24s' 'Update')${nc} ${gr}x${nc}${g0})${nc} ${gw}Uninstall${nc}"
    ui_line "${gr}0${nc}${g0})${nc} ${gw}Exit${nc}"
    ui_bot
    printf '%s' "  ${g2}${GL_ARROW}${nc} ${gw}select${nc} ${g0}[1-9/r/b/t/u/x/0]${nc} "
    read -r opt || true
    case "$opt" in
        1) create_account;; 2) delete_account;; 3) list_accounts;;
        4) service_status;; 5) restart_services;; 6) system_info;;
        7) change_domain;; 8) edit_banner;; 9) edit_response;;
        r|R) reality_config_menu;;
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
    install_shadowtls
    configure_shadowtls
    configure_nginx
    setup_badvpn
    configure_stunnel
    configure_fail2ban
    apply_firewall_rules
    install_scripts
    setup_cron_jobs
    final_cleanup
    log_success "Installation complete! AutoScriptX v4.4.3-hardened (Reality + ShadowTLS)."
    log_success "Reality :${PORT_VLESS_REALITY} (SNI ${REALITY_SNI}) | ShadowTLS :${PORT_SHADOWTLS}"
    log_success "Run 'autoscriptx' or 'asx' to start."
}

main "$@"
