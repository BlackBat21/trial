# BEN10-TUNNEL — Anti-Torrent Hardening & Bug Fixes (`install.sh`)

> 🛡️ This doc explains a change to `install.sh` (AutoScriptX / BEN10-TUNNEL) that makes the
> anti-torrent enforcement actually work, extends it to the traffic path that matters, and fixes
> an ARM install bug. Read **Background** if you're new to Xray/iptables; skip to **Code** for the
> diff walkthrough.

## Background

BEN10-TUNNEL is a single-file installer that turns a fresh Ubuntu VPS into a tunnel server. Clients
connect with VLESS / VMESS / Trojan over WebSocket or xHTTP, the traffic is unwrapped by
**Xray-core** running on the box, and Xray then makes the real outbound connection to wherever the
client wanted to go. Nginx terminates TLS on 443 and reverse-proxies each path (`/vless-ws`,
`/vmess-ws`, …) to a loopback port that Xray listens on.

The operator does not want the server used for BitTorrent (it invites DMCA notices and can get the
VPS terminated). The script tries to prevent this **two ways**:

- **Layer 7 (Xray):** a routing rule `{ protocol: ["bittorrent"], outboundTag: "blocked" }` that
  sends any connection Xray identifies as BitTorrent into a `blackhole` outbound.
- **Layer 3/4 (iptables):** `-m string` rules that DROP packets whose payload contains torrent
  signatures like `BitTorrent protocol`, `info_hash`, `get_peers`, etc.

> 💡 **Key concept — sniffing.** Xray can only route on `protocol` if *content sniffing* is enabled
> on the inbound. Sniffing peeks at the first bytes of the unwrapped stream to classify it
> (http / tls / quic / bittorrent). **Without `sniffing.enabled = true`, the `protocol` attribute is
> never populated, so a `protocol:["bittorrent"]` rule can never match.** It fails open — silently.

> 💡 **Key concept — which iptables chain.** A packet the machine *routes on behalf of someone else*
> traverses `FORWARD`. A packet a *local process generates itself* traverses `OUTPUT`. Because Xray
> is a proxy — it terminates the client connection and opens its **own** upstream socket — the
> torrent packets are locally generated. They go through `OUTPUT`, not `FORWARD`.

## Intuition

Both defenses were installed but neither was actually on the path.

Imagine a client tunnels a torrent client through the VPS and starts downloading `ubuntu.iso`.

1. **Xray rule:** Xray unwraps the stream but, with sniffing off, tags the connection's protocol as
   empty. The router compares `"" == "bittorrent"` → no match → the torrent flows out through the
   normal `direct` outbound. The blackhole is never reached. *Dead rule.*
2. **iptables rule:** the BitTorrent handshake packet `\x13BitTorrent protocol…` is emitted by the
   local Xray process, so it hits `OUTPUT`. But the DROP signatures were only attached to `FORWARD`.
   *Dead rule.*

The fix flips both switches on:

- Turn **sniffing on** for every proxy inbound → the `bittorrent` protocol is now detected → the
  existing blackhole rule finally fires.
- Attach the signature DROPs to **`OUTPUT` as well as `FORWARD`** → the proxy's own torrent packets
  are now inspected and dropped.

> 🧪 Toy check: with sniffing on, a BitTorrent connection sniffs to `protocol = "bittorrent"`,
> matches the rule, and is routed to `outboundTag = "blocked"` (a `blackhole` that just closes the
> connection). A normal HTTPS request sniffs to `tls`, matches nothing, and takes the default
> `direct` outbound — unchanged.

## Code

**1) Enable sniffing on every proxy inbound (`configure_xray`).** Each of the five inbounds
(`vless-ws`, `vmess-ws`, `trojan-ws`, `vless-xhttp`, `vmess-xhttp`) gained a sniffing block. The
`api` dokodemo inbound is intentionally left alone.

```json
{ "tag":"vless-ws", "...":"...",
  "streamSettings":{ "network":"ws", "wsSettings":{ "path":"/vless-ws" } },
  "sniffing":{ "enabled":true, "destOverride":["http","tls","quic"], "routeOnly":true } }
```

> ⚠️ `routeOnly: true` means the sniffed result is used **only for routing decisions** — it does not
> rewrite the connection's destination address. That keeps normal traffic behaving exactly as before
> while still exposing `protocol` to the router. `bittorrent` is deliberately **not** added to
> `destOverride` (only `http`/`tls`/`quic`/`fakedns` are valid there); the bittorrent sniffer runs
> whenever sniffing is enabled regardless.

**2) Filter `OUTPUT` too, with a tighter signature set (`apply_firewall_rules`).**

```bash
local -a torrent_sigs=(
    "BitTorrent protocol" "get_peers" "announce_peer" "find_node"
    "d1:ad2:id20:" "info_hash" "peer_id=" "announce.php?passkey=" ".torrent"
)
for chain in FORWARD OUTPUT; do
    for s in "${torrent_sigs[@]}"; do
        iptables -C "$chain" -m string --string "$s" --algo bm -j DROP >/dev/null 2>&1 \
            || iptables -A "$chain" -m string --string "$s" --algo bm -j DROP
    done
done
```

The bare words `torrent` and `announce` (and the redundant `BitTorrent`) were dropped from the
active set because, now that we inspect `OUTPUT`, they would risk false-positives on the server's own
HTTP traffic. `d1:ad2:id20:` — the bencoded prefix of a DHT KRPC query — was added; it is extremely
specific and catches DHT over UDP (`-m string` with no `-p` inspects UDP payloads too).

**3) Carry the fix through upgrades (`update_script`).** `--update-only` preserves existing configs,
so already-deployed servers needed an idempotent migration: enable sniffing on existing proxy
inbounds, ensure a `blocked` blackhole outbound exists, and ensure the `bittorrent` routing rule
exists.

```bash
json_edit "$cfg" "$CFG_LOCK" '
  .inbounds |= map(
    if (.protocol=="vless" or .protocol=="vmess" or .protocol=="trojan")
    then .sniffing = {enabled:true,destOverride:["http","tls","quic"],routeOnly:true}
    else . end )'
```

**4) Keep the uninstaller honest (`full_uninstall`).** Since install now writes `OUTPUT` rules,
uninstall now deletes torrent signatures from **both** chains (union of legacy + current signatures)
and clears all four INPUT ACCEPT ports, so a full uninstall reverts firewall state cleanly.

**5) Unrelated bug fix (`install_gum`).** The installer hard-coded the `x86_64` gum asset even though
`install_xray` already supports `aarch64`. On an ARM VPS that silently pulled an unrunnable binary.
It now selects `x86_64` / `arm64` from `uname -m`.

```bash
case "$(uname -m)" in
    x86_64)  gum_arch="x86_64" ;;
    aarch64) gum_arch="arm64" ;;
    *)       die "Unsupported arch for gum: $(uname -m)" ;;
esac
```

## Verification

The change was validated in the sandbox without a live VPS:

- **`bash -n install.sh`** — passes (syntax valid).
- **`shellcheck`** — no new findings versus the original file.
- **Config generation** — ran the exact `jq -n` block from `configure_xray`; output passes
  `jq empty` (valid JSON). Confirmed all five proxy inbounds carry `sniffing.enabled=true` while the
  `api` inbound has none, and that the `bittorrent` rule's `outboundTag` resolves to a real
  `blackhole` outbound.
- **Migration** — ran the three `--update-only` jq snippets against a simulated *old* config
  (no sniffing, no blocked outbound, no rule). After one pass everything was present; a second pass
  kept every count at 1 (idempotent) and left the `api` inbound/rule untouched.
- **Firewall loop** — dry-printed the chain×signature expansion: 2 chains × 9 signatures = 18 DROP
  rules, as expected.

**Manual QA on a staging VPS**

1. Fresh install, then `xray -test -config /usr/local/etc/xray/config.json` → should print
   *Configuration OK*.
2. `jq '.inbounds[] | {tag, sniffing}' /usr/local/etc/xray/config.json` → sniffing present on all
   proxy inbounds.
3. `iptables -S OUTPUT | grep -i bittorrent` and `iptables -S FORWARD | grep -i bittorrent` →
   signatures present on both.
4. Tunnel a torrent client through the VPS and start a well-seeded torrent → peers should fail to
   connect; `journalctl -u xray` and `iptables -L OUTPUT -v` DROP counters should climb.
5. Confirm normal browsing / speed-test through the tunnel is unaffected.
6. On an existing box: run `--update-only` and repeat steps 2–3. Then run uninstall and confirm
   `iptables -S | grep -i torrent` returns nothing.

## Alternatives

| A) Xray sniffing + blackhole only (drop the iptables layer) | B) Sniffing + iptables on FORWARD & OUTPUT (this change) |
| --- | --- |
| **Pros**<br>• Protocol-aware; sees the decrypted stream so outer-tunnel encryption doesn't matter.<br>• No false-positive risk on the host's own traffic.<br>• Simplest config to reason about. | **Pros**<br>• Defense in depth: L7 classifier **and** L3/4 signatures.<br>• Covers DHT/uTP over UDP and cleartext tracker announces. |
| **Cons**<br>• Single layer — a sniffer miss (obfuscated handshake) leaks.<br>• No defense for non-Xray paths (badvpn/tun). | **Cons**<br>• `-m string` can't see inside encrypted payloads; catches handshakes/DHT, not encrypted swarms.<br>• Slightly more rules to keep in sync with uninstall. |

## Suggested people to talk to

> 👤 Every prior commit to `install.sh` was authored by **BlackBat21** (the repository owner) —
> including the original anti-torrent routing rule, the iptables block, and the `--update-only`
> migration framework. They are the person to talk to about the config-generation and migration
> design, and about why the `ayanrajpoot10/AutoScriptX` asset tree is trusted for binaries. There are
> no other recent contributors to this file.

## Quiz

<details>
<summary>1. Why was the <code>protocol:["bittorrent"]</code> routing rule a no-op before this change?</summary>

- **A.** The `blocked` outbound didn't exist. *Incorrect — it was defined as a blackhole.*
- **B.** Sniffing was disabled, so the `protocol` attribute was never set for the router to match. **Correct** — routing on `protocol` requires content sniffing to be enabled on the inbound.
- **C.** The rule was in the wrong order. *Incorrect — order didn't matter; the attribute was simply absent.*
- **D.** VMESS traffic can't be sniffed. *Incorrect — sniffing operates on the unwrapped stream regardless of the proxy protocol.*

</details>

<details>
<summary>2. Why add the iptables signatures to the OUTPUT chain instead of only FORWARD?</summary>

- **A.** OUTPUT is faster. *Incorrect.*
- **B.** Because the proxy terminates the client connection and opens its own upstream socket, so torrent packets are locally generated and traverse OUTPUT, not FORWARD. **Correct.**
- **C.** FORWARD only handles inbound packets. *Incorrect — FORWARD handles routed/transit packets.*
- **D.** OUTPUT is required for UDP. *Incorrect — chain choice is about packet origin, not L4 protocol.*

</details>

<details>
<summary>3. What does <code>routeOnly: true</code> in the sniffing block accomplish?</summary>

- **A.** It disables sniffing for non-HTTP traffic. *Incorrect.*
- **B.** It uses the sniffed result only for routing decisions without rewriting the connection's destination address. **Correct** — this keeps normal traffic behaving as before while still exposing `protocol` to the router.
- **C.** It forces all traffic through the blackhole. *Incorrect.*
- **D.** It is required for bittorrent detection. *Incorrect — detection happens whenever sniffing is enabled; routeOnly only affects destination override.*

</details>

<details>
<summary>4. Why were the bare strings <code>torrent</code> and <code>announce</code> removed from the active signature list?</summary>

- **A.** They no longer exist in the BitTorrent protocol. *Incorrect.*
- **B.** Now that OUTPUT (the host's own traffic) is inspected, those generic words risk false-positives on legitimate server HTTP; the specific signatures are safer. **Correct.**
- **C.** iptables can't match strings longer than 8 characters. *Incorrect.*
- **D.** They were duplicates of `info_hash`. *Incorrect.*

</details>

<details>
<summary>5. Why does the <code>--update-only</code> migration need to be idempotent, and how is that achieved?</summary>

- **A.** It isn't — update always rebuilds config from scratch. *Incorrect — update is explicitly non-destructive and preserves user configs.*
- **B.** Because operators may run update repeatedly; each step is guarded by a `jq -e` existence check (or a map that overwrites to the same value) so re-runs don't duplicate outbounds/rules. **Correct** — verified by the two-pass test keeping counts at 1.
- **C.** Idempotency is guaranteed by systemd. *Incorrect.*
- **D.** By deleting the config and recreating it. *Incorrect — that would wipe users/UUIDs.*

</details>
