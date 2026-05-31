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

# ── Uninstall Script ──────────────────────────────────────────────────────────
uninstall_script() {
    clear
    echo -e "\033[5;31m"
    echo "  ██████████████████████████████████████████████████████"
    echo "  ██                                                  ██"
    echo "  ██   !!!  CRITICAL WARNING — IRREVERSIBLE ACTION  !!!  ██"
    echo "  ██                                                  ██"
    echo "  ██   This will PERMANENTLY DESTROY all data,       ██"
    echo "  ██   configurations, user accounts, certificates,  ██"
    echo "  ██   and every component installed by AutoScriptX. ██"
    echo "  ██                                                  ██"
    echo "  ██   The server will be REBOOTED when complete.    ██"
    echo "  ██                                                  ██"
    echo "  ██████████████████████████████████████████████████████"
    echo -e "\033[0m"
    echo -e "${red}  There is NO undo. ALL VPN users will be disconnected and erased.${nc}"
    echo ""
    echo -e "${yellow}  To confirm this destructive operation, type exactly:${nc}"
    echo -e "${red}  WIPE-SERVER${nc}"
    echo ""
    read -rp "  Confirmation: " confirm_input </dev/tty

    if [[ "$confirm_input" != "WIPE-SERVER" ]]; then
        clear
        echo -e "${yellow}  Uninstall aborted. Returning to main menu...${nc}"
        sleep 2
        return
    fi

    clear
    echo -e "${red}  ── Initiating Full Uninstall ─────────────────────────────────${nc}\n"

    # ── Step 1: Stop and disable all services ─────────────────────────────────
    echo -e "${yellow}  [1/5] Stopping and disabling services...${nc}"
    for svc in xray nginx squid dropbear stunnel4 fail2ban ws-proxy xray-limit-monitor badvpn-udpgw; do
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    echo -e "${green}       Done.${nc}"

    # ── Step 2: Purge installed packages ──────────────────────────────────────
    echo -e "${yellow}  [2/5] Purging installed packages...${nc}"
    apt-get purge -y \
        netfilter-persistent iptables-persistent screen curl jq bzip2 gzip vnstat \
        zip unzip net-tools nano lsof shc gnupg dos2unix dirmngr bc \
        stunnel4 nginx dropbear socat xz-utils fail2ban squid \
        2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    apt-get autoclean  -y 2>/dev/null || true
    echo -e "${green}       Done.${nc}"

    # ── Step 3: Remove all files and directories ──────────────────────────────
    echo -e "${yellow}  [3/5] Erasing all AutoScriptX files and artifacts...${nc}"

    # Xray core binaries and config
    rm -rf /usr/local/etc/xray                          2>/dev/null || true
    rm -f  /usr/local/bin/xray                          2>/dev/null || true
    rm -f  /usr/local/bin/xray-limit-monitor            2>/dev/null || true
    rm -f  /usr/local/bin/ws-proxy                      2>/dev/null || true
    rm -f  /usr/local/bin/gum                           2>/dev/null || true
    rm -f  /usr/local/bin/badvpn-udpgw                  2>/dev/null || true

    # AutoScriptX config directory and SSL certs
    rm -rf /etc/AutoScriptX                             2>/dev/null || true
    rm -rf /root/.acme.sh                               2>/dev/null || true

    # Nginx custom configs
    rm -f  /etc/nginx/xray-locations.conf               2>/dev/null || true
    rm -f  /etc/nginx/conf.d/xhttp-port80.conf          2>/dev/null || true
    rm -f  /etc/nginx/conf.d/reverse-proxy.conf         2>/dev/null || true

    # Systemd service units
    rm -f  /etc/systemd/system/xray.service             2>/dev/null || true
    rm -f  /etc/systemd/system/ws-proxy.service         2>/dev/null || true
    rm -f  /etc/systemd/system/xray-limit-monitor.service 2>/dev/null || true
    rm -f  /etc/systemd/system/badvpn-udpgw.service     2>/dev/null || true
    rm -f  /etc/systemd/system/stunnel4.service         2>/dev/null || true

    # Menu binaries and symlinks
    rm -f  /usr/bin/menu                                2>/dev/null || true
    rm -f  /usr/bin/autoscriptx                         2>/dev/null || true
    rm -f  /usr/bin/asx                                 2>/dev/null || true

    # Cron jobs
    rm -f  /etc/cron.d/auto-reboot                      2>/dev/null || true
    rm -f  /etc/cron.d/clean-expired-accounts           2>/dev/null || true

    # Optional helper scripts placed in /usr/bin
    for scr in create-account delete-account edit-banner edit-response \
               lock-unlock renew-account change-domain manage-services \
               system-info clean-expired-accounts setup-slowdns \
               slowdns-status slowdns-menu; do
        rm -f "/usr/bin/${scr}" 2>/dev/null || true
    done

    # VPS public html dir
    rm -rf /home/vps 2>/dev/null || true

    echo -e "${green}       Done.${nc}"

    # ── Step 4: Reload systemd to drop removed units ──────────────────────────
    echo -e "${yellow}  [4/5] Reloading systemd daemon...${nc}"
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed  2>/dev/null || true
    echo -e "${green}       Done.${nc}"

    # ── Step 5: Reboot to flush iptables/network state from memory ────────────
    echo -e "${yellow}  [5/5] Uninstall complete. Rebooting server in 5 seconds...${nc}"
    echo -e "${red}         All services have been removed. The server will now reboot.${nc}"
    sleep 5
    reboot
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
    echo -e "  ${red}X)${nc} !! UNINSTALL AutoScriptX !!"
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
        b|B) bandwidth_monitor  ;;
        u|U) do_update          ;;
        x|X) uninstall_script   ;;
        0) exit 0               ;;
        *) echo -e "${red}Invalid option.${nc}"; sleep 1 ;;
    esac
done
MAINMENU
    chmod +x /usr/bin/menu
}
