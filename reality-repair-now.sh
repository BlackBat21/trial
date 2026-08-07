#!/usr/bin/env bash
# One-shot Reality repair for AutoScriptX nodes that cannot connect on :8443
# Run as root on the VPS.
set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"
CREDS="${CREDS:-/usr/local/etc/xray/credentials.env}"
CFG_LOCK="${CFG_LOCK:-/run/lock/autoscriptx-cfg.lock}"
FALLBACK_DEST="www.cloudflare.com:443"
FALLBACK_SNI="www.cloudflare.com"

die() { echo "xx $1" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }

need jq; need ss; need systemctl
[[ -x "$XRAY_BIN" ]] || die "xray not found at $XRAY_BIN"
[[ -f "$XRAY_CONF" ]] || die "config not found: $XRAY_CONF"
mkdir -p /run/lock

json_edit() {
    local file="$1" lock="$2"; shift 2
    local tmp; tmp="$(mktemp "$(dirname "$file")/.jq.XXXXXX")"
    (
        flock 9
        if jq "$@" "$file" > "$tmp" && [[ -s "$tmp" ]] && jq empty "$tmp" >/dev/null 2>&1; then
            chmod 600 "$tmp"; mv -f "$tmp" "$file"
        else
            rm -f "$tmp"
            die "json_edit failed for $file"
        fi
    ) 9>"$lock"
}

echo ":: Reality repair starting"

# 0) basic status
systemctl is-active --quiet xray && echo "OK xray active" || echo "!! xray inactive"
ss -lntup | grep -E ':8443\b' || echo "!! nothing listening on 8443"

# 1) ensure Reality inbound exists
if ! jq -e '.inbounds[]|select(.tag=="vless-reality")' "$XRAY_CONF" >/dev/null 2>&1; then
    die "vless-reality inbound missing — re-run installer update first"
fi

# 2) sync ALL vless-ws clients onto Reality with vision flow
echo ":: syncing clients from vless-ws → vless-reality (flow=xtls-rprx-vision)"
json_edit "$XRAY_CONF" "$CFG_LOCK" --arg rflow "xtls-rprx-vision" '
  (first(.inbounds[]|select(.tag=="vless-ws")|.settings.clients)//[]) as $src
  | ($src|map({id:.id, email:(.email//.id), flow:$rflow})) as $rc
  | ($src|map({id:.id, email:(.email//.id), flow:""})) as $sc
  | .inbounds |= map(
      if .tag=="vless-reality" and ($rc|length)>0 then
        .settings.clients=$rc
        | .listen="0.0.0.0"
        | .streamSettings.network="tcp"
        | .streamSettings.security="reality"
        | .sniffing={enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:true}
      elif .tag=="vless-stls" and ($sc|length)>0 then
        .settings.clients=$sc
      else . end)'

echo "OK Reality clients:"
jq -r '.inbounds[]|select(.tag=="vless-reality")|.settings.clients[]?|"  - \(.email)  flow=\(.flow)  \(.id)"' "$XRAY_CONF"

# 3) refresh pbk from privateKey (do NOT use Hash32)
priv="$(jq -r '.inbounds[]|select(.tag=="vless-reality")|.streamSettings.realitySettings.privateKey//empty' "$XRAY_CONF")"
[[ -n "$priv" ]] || die "privateKey missing on vless-reality"
sid="$(jq -r '.inbounds[]|select(.tag=="vless-reality")|.streamSettings.realitySettings.shortIds[1]//.streamSettings.realitySettings.shortIds[0]//empty' "$XRAY_CONF")"
pb="$("$XRAY_BIN" x25519 -i "$priv" 2>/dev/null | awk -F: 'tolower($1) ~ /password|public/ {sub(/^[^:]*:[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; exit}')"
[[ -z "$pb" ]] && pb="$("$XRAY_BIN" x25519 -i "$priv" 2>/dev/null | grep -Eo '[A-Za-z0-9_\-]{40,60}' | head -1)"
[[ -n "$pb" ]] || die "could not derive public key from privateKey"

umask 077
touch "$CREDS"
grep -q '^REALITY_PUBLIC_KEY=' "$CREDS" 2>/dev/null \
  && sed -i "s|^REALITY_PUBLIC_KEY=.*|REALITY_PUBLIC_KEY=\"${pb}\"|" "$CREDS" \
  || printf 'REALITY_PUBLIC_KEY="%s"\n' "$pb" >> "$CREDS"
grep -q '^REALITY_PRIVATE_KEY=' "$CREDS" 2>/dev/null \
  && sed -i "s|^REALITY_PRIVATE_KEY=.*|REALITY_PRIVATE_KEY=\"${priv}\"|" "$CREDS" \
  || printf 'REALITY_PRIVATE_KEY="%s"\n' "$priv" >> "$CREDS"
if [[ -n "$sid" ]]; then
  grep -q '^REALITY_SHORT_ID=' "$CREDS" 2>/dev/null \
    && sed -i "s|^REALITY_SHORT_ID=.*|REALITY_SHORT_ID=\"${sid}\"|" "$CREDS" \
    || printf 'REALITY_SHORT_ID="%s"\n' "$sid" >> "$CREDS"
fi
chmod 600 "$CREDS"
echo "OK pbk=${pb}"
echo "OK sid=${sid}"

# 4) dest must be a real TLS 1.3 host reachable from this VPS
dest="$(jq -r '.inbounds[]|select(.tag=="vless-reality")|.streamSettings.realitySettings.dest//empty' "$XRAY_CONF")"
host="${dest%%:*}"
dest_ok=0
if [[ -n "$dest" ]] && command -v openssl >/dev/null 2>&1; then
  if timeout 5 openssl s_client -connect "$dest" -servername "$host" </dev/null >/dev/null 2>&1; then
    dest_ok=1
    echo "OK dest TLS reachable: $dest"
  fi
fi
if [[ "$dest_ok" -ne 1 ]]; then
  echo "!! dest TLS failed (${dest:-empty}) — switching to ${FALLBACK_DEST}"
  json_edit "$XRAY_CONF" "$CFG_LOCK" --arg dest "$FALLBACK_DEST" --arg sni "$FALLBACK_SNI" --arg sid "${sid}" '
    .inbounds |= map(if .tag=="vless-reality" then
      .streamSettings.realitySettings.dest=$dest
      | .streamSettings.realitySettings.serverNames=([((.streamSettings.realitySettings.serverNames//[])[]), $sni] | unique)
      | .streamSettings.realitySettings.shortIds=(["", $sid] | unique)
    else . end)'
  grep -q '^REALITY_DEST=' "$CREDS" 2>/dev/null \
    && sed -i "s|^REALITY_DEST=.*|REALITY_DEST=\"${FALLBACK_DEST}\"|" "$CREDS" \
    || printf 'REALITY_DEST="%s"\n' "$FALLBACK_DEST" >> "$CREDS"
  grep -q '^REALITY_SNI=' "$CREDS" 2>/dev/null \
    && sed -i "s|^REALITY_SNI=.*|REALITY_SNI=\"${FALLBACK_SNI}\"|" "$CREDS" \
    || printf 'REALITY_SNI="%s"\n' "$FALLBACK_SNI" >> "$CREDS"
  chmod 600 "$CREDS"
  dest="$FALLBACK_DEST"
fi

# 5) open local iptables if needed
iptables -C INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null \
  || iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
echo "OK local iptables tcp/8443"

# 6) validate + restart
"$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null \
  || { echo "xx xray config test failed:"; "$XRAY_BIN" run -test -config "$XRAY_CONF"; exit 1; }
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || die "xray failed to start"
ss -lntup | grep -E ':8443\b' || die "still not listening on 8443"

pub_ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
sni="$(awk -F= '/^REALITY_SNI=/{gsub(/"/,"",$2);print $2;exit}' "$CREDS")"
[[ -n "$sni" ]] || sni="$FALLBACK_SNI"

echo
echo "=============================="
echo " Reality repair complete"
echo "=============================="
echo " server   : ${pub_ip:-(run: curl -4 ifconfig.me)}"
echo " port     : 8443"
echo " sni      : ${sni}"
echo " dest     : ${dest}"
echo " pbk      : ${pb}"
echo " sid      : ${sid}"
echo " flow     : xtls-rprx-vision"
echo
echo "Pick a user UUID from:"
jq -r '.inbounds[]|select(.tag=="vless-reality")|.settings.clients[]?|"  \(.email)  \(.id)"' "$XRAY_CONF"
echo
echo "Client must use ALL of: public IP + 8443 + uuid + flow + sni + pbk + sid"
echo "Old links with www.iwanttfc.com / wrong pbk / private 10.x IP will fail."
