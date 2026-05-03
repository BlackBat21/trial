# AutoXray — Ubuntu 24 VPS Installer

> **Xray-core + SSH over WebSocket** — production-ready, single-command deployment.

---

## Architecture Overview

```
Client
  │
  ├─── :443 (TLS) ──────────────────────────────────────────────────────┐
  │    /vless-ws    → Nginx (TLS term.) → Xray VLESS+WS  :10001        │
  │    /vmess-ws    → Nginx (TLS term.) → Xray VMess+WS  :10002        │
  │    /trojan-ws   → Nginx (TLS term.) → Xray Trojan+WS :10003        │
  │    /GunService  → Nginx (gRPC)      → Xray VLESS+gRPC:10004        │
  │    /ssh-ws      → Nginx (TLS term.) → websockify     :2082 → sshd  │
  │                                                                      │
  └─── :80 (non-TLS) ────────────────────────────────────────────────── ┘
       /vless-ws-nt → Nginx → Xray VLESS+WS  :10011
       /vmess-ws-nt → Nginx → Xray VMess+WS  :10012
       /ssh-ws      → Nginx → websockify     :2082 → sshd
       /            → 301 → https://

Internet → UFW → Nginx (80/443) → Xray / websockify (localhost only)
```

All Xray and websockify processes bind exclusively to `127.0.0.1`.  
The only ports exposed to the internet are **80** and **443**.

---

## Quick Start

```bash
# Clone or download
git clone https://github.com/your-org/autoxray
cd autoxray

# Option A — With a real domain (Let's Encrypt TLS)
sudo bash install.sh --domain vpn.example.com --email ops@example.com

# Option B — Self-signed certificate (no domain required)
sudo bash install.sh

# After installation, show all credentials
autoxray credentials
```

**Requirements:**
- Ubuntu 24.04 LTS
- Root access (or sudo)
- Minimum 2 GB RAM, 1 vCPU
- Ports 80 and 443 reachable from the internet

---

## Script Sections

| Section | Function |
|---------|----------|
| 0 | Global constants, colour logging helpers |
| 1 | Argument parsing & `--help` |
| 2 | Pre-flight checks (root, OS version, RAM, ports) |
| 3 | `apt` package installation |
| 4 | Kernel/BBR tuning + swap creation |
| 5 | TLS provisioning (acme.sh Let's Encrypt or self-signed) |
| 6 | Xray-core binary download & install |
| 7 | Xray `config.json` generation (all protocols) |
| 8 | Xray `systemd` service with hardened unit file |
| 9 | Nginx virtual hosts for `:80` and `:443` |
| 10 | SSH WebSocket via `websockify` systemd service |
| 11 | UFW firewall + Fail2ban + SSH hardening |
| 12 | Log rotation |
| 13 | Service startup |
| 14 | `autoxray` management helper |
| 15 | `--uninstall` mode |
| 16 | Summary report |

---

## Supported Protocols

| Protocol | Transport | TLS | Path / Service Name |
|----------|-----------|-----|---------------------|
| VLESS    | WebSocket | ✔   | `/vless-ws` |
| VMess    | WebSocket | ✔   | `/vmess-ws` |
| Trojan   | WebSocket | ✔   | `/trojan-ws` |
| VLESS    | gRPC      | ✔   | `GunService` |
| VLESS    | WebSocket | ✗   | `/vless-ws-nt` |
| VMess    | WebSocket | ✗   | `/vmess-ws-nt` |
| SSH      | WebSocket | Both| `/ssh-ws` |

---

## Management CLI

```bash
autoxray status       # Service health check
autoxray credentials  # All UUIDs, passwords, endpoints
autoxray restart      # Restart nginx + xray + ssh-websocket
autoxray logs         # Tail logs
autoxray update       # Update Xray-core to latest release
autoxray uninstall    # Full removal
```

---

## Client Configuration Examples

### VLESS + WebSocket + TLS (v2rayN / v2rayNG)

```json
{
  "protocol": "vless",
  "address": "vpn.example.com",
  "port": 443,
  "uuid": "<VLESS_UUID>",
  "encryption": "none",
  "network": "ws",
  "wsPath": "/vless-ws",
  "tls": true,
  "serverName": "vpn.example.com"
}
```

### VMess + WebSocket + TLS

```json
{
  "protocol": "vmess",
  "address": "vpn.example.com",
  "port": 443,
  "uuid": "<VMESS_UUID>",
  "alterId": 0,
  "security": "auto",
  "network": "ws",
  "wsPath": "/vmess-ws",
  "tls": true
}
```

### SSH over WebSocket (OpenSSH ProxyCommand)

```bash
# ~/.ssh/config
Host myvps-ws
    HostName vpn.example.com
    User ubuntu
    ProxyCommand websocat --binary wss://%h/ssh-ws
    # or: ProxyCommand ncat --proxy-type http vpn.example.com:443 --proxy-auth ... 
```

Using **wscat** one-liner:
```bash
ssh -o ProxyCommand="websocat wss://vpn.example.com/ssh-ws" ubuntu@vpn.example.com
```

### SSH over WebSocket (Bitvise / MobaXterm)

- Host: `vpn.example.com`
- Port: `443`
- Proxy type: `WebSocket`
- Path: `/ssh-ws`
- TLS: Enabled

---

## Resource Usage (2 GB RAM baseline)

| Component       | Typical RSS |
|-----------------|-------------|
| Nginx (4 workers)| ~40 MB     |
| Xray-core        | ~20–60 MB  |
| websockify       | ~15 MB     |
| Fail2ban         | ~30 MB     |
| **Total**        | **~120 MB**|

Remaining ~1.8 GB is available for OS, connections, and buffer cache.  
The 1 GB swap file provides a safety net during traffic spikes.

---

## Security Notes

1. **Credentials file** is stored at `/usr/local/etc/xray/credentials.env` (mode 600, root-only).
2. **Xray** runs as `nobody` with a fully hardened systemd unit (`NoNewPrivileges`, `ProtectSystem=full`, etc.).
3. **Nginx** drops privileges to `www-data` and has no write access to system directories.
4. **UFW** blocks all ports except 22, 80, 443.
5. **Fail2ban** monitors SSH, Nginx auth failures, and rate-limit triggers.
6. **TLS 1.2/1.3 only** — TLS 1.0/1.1 are disabled in the Nginx config.
7. For production, **disable SSH password authentication** after adding your public key:
   ```bash
   sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
   systemctl restart sshd
   ```

---

## Troubleshooting

| Symptom | Command |
|---------|---------|
| Service won't start | `journalctl -u xray -n 100` |
| Nginx config error | `nginx -t` |
| Port conflict | `ss -tlnp` |
| TLS cert issue | `ls -la /etc/ssl/autoxray/` |
| UFW blocking | `ufw status verbose` |
| Xray version | `/usr/local/bin/xray version` |

Full installation log: `/var/log/autoxray-install.log`

---

## References

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [FreeNetLabs/AutoScriptX](https://github.com/FreeNetLabs/AutoScriptX)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- [Xray Config Reference](https://xtls.github.io/config/)
