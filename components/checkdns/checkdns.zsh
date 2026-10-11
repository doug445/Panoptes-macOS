# ══ DNS / Privacy Stack ═══════════════════════════════════════════════════════
# checkdns — comprehensive DNS and privacy stack status report.
#
# Covers eight areas:
#   1. mDNSResponder / Bonjour   — is the local DNS cache + mDNS daemon healthy?
#   2. Active DNS servers         — what resolvers is the system actually using?
#   3. DNSSEC                     — does the upstream resolver validate signatures?
#   4. DNS over TLS (DoT :853)    — encrypted DNS via TCP
#   5. DNS over HTTPS (DoH :443)  — encrypted DNS over HTTPS
#   6. ECH                        — Encrypted Client Hello (SNI privacy in TLS)
#   7. VPN                        — active tunnel interfaces + DNS leak detection
#   8. Smoke test                 — live resolution of three well-known domains
#
# Helper functions (_hdr, _ok, _fail, _warn, _info, _unkn) are defined inside
# and cleaned up with `unset -f` at the end so they don't pollute the namespace.

checkdns() {
    local G='\e[1;32m' R='\e[1;31m' Y='\e[1;33m' C='\e[1;36m' D='\e[0;37m' N='\e[0m'
    _hdr()  { printf "\n${C}── %s $(printf '─%.0s' {1..44})${N}\n" "$1"; }
    _ok()   { printf "  ${G}[  OK  ]${N}  %s\n" "$*"; }
    _fail() { printf "  ${R}[ FAIL ]${N}  %s\n" "$*"; }
    _warn() { printf "  ${Y}[ WARN ]${N}  %s\n" "$*"; }
    _info() { printf "  ${C}[ INFO ]${N}  %s\n" "$*"; }
    _unkn() { printf "  ${D}[  ?   ]${N}  %s\n" "$*"; }

    printf "\n${C}╔══════════════════════════════════════════════════════╗${N}\n"
    printf   "${C}║  DNS / PRIVACY STATUS  ·  %-27s║${N}\n" "$(date '+%a %d %b %Y  %H:%M:%S')"
    printf   "${C}╚══════════════════════════════════════════════════════╝${N}\n"

    # ── 1. mDNSResponder ─────────────────────────────────────────────────────
    # mDNSResponder implements RFC 6762 (mDNS) and RFC 6763 (DNS-SD / Bonjour).
    # It handles *.local resolution, the system DNS cache, AirPlay, AirDrop, etc.
    _hdr "mDNSResponder / Bonjour  (macOS ≡ Avahi on Linux)"
    local mdns_pid
    mdns_pid=$(pgrep mDNSResponder 2>/dev/null | head -1)
    if [[ -n "$mdns_pid" ]]; then
        _ok  "mDNSResponder running  (PID ${mdns_pid})"
        local mdns_state
        mdns_state=$(launchctl list com.apple.mDNSResponder 2>/dev/null \
                     | awk -F'"' '/"PID"/{print $4}')
        [[ -n "$mdns_state" ]] && _info "launchctl PID: ${mdns_state}"
    else
        _fail "mDNSResponder NOT running — Bonjour/mDNS is down"
    fi
    pgrep -q mDNSResponderHelper 2>/dev/null \
        && _ok  "mDNSResponderHelper running" \
        || _info "mDNSResponderHelper absent (optional privileged helper)"
    local mlocal
    mlocal="$(scutil --get LocalHostName 2>/dev/null).local"
    local mlocal_ip
    mlocal_ip=$(timeout 2 dns-sd -Q "$mlocal" A 2>/dev/null \
                | awk '/Addr[[:space:]]+IN/{print $NF}' | head -1 || true)
    if [[ -n "$mlocal_ip" ]]; then
        _ok  "mDNS resolution OK  (${mlocal} → ${mlocal_ip})"
    else
        _warn "mDNS resolution inconclusive for ${mlocal}"
    fi
    local sd_count
    sd_count=$(timeout 2 dns-sd -B _services._dns-sd._udp local. 2>/dev/null \
               | grep -c "Add" || true)
    (( sd_count > 0 )) \
        && _ok  "DNS-SD active (${sd_count} service types seen)" \
        || _info "DNS-SD browse returned no results in 2 s (network may be quiet)"

    # ── 2. Active DNS Servers ─────────────────────────────────────────────────
    _hdr "Active DNS Servers"
    local all_ns
    all_ns=$(scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | sort -u)
    if [[ -n "$all_ns" ]]; then
        while IFS= read -r ns; do _info "Nameserver: ${ns}"; done <<< "$all_ns"
    else
        _warn "No nameservers found via scutil"
    fi
    if [[ -f /etc/resolv.conf ]]; then
        local rc
        rc=$(awk '/^nameserver/{print $2}' /etc/resolv.conf)
        [[ -n "$rc" ]] && while IFS= read -r ns; do
            _info "/etc/resolv.conf: ${ns}"
        done <<< "$rc"
    fi
    if [[ -d /etc/resolver ]]; then
        local rcount
        rcount=$(command ls /etc/resolver/ 2>/dev/null | wc -l | tr -d ' ')
        if (( rcount > 0 )); then
            _info "/etc/resolver/ overrides: ${rcount} domain(s)"
            command ls /etc/resolver/ | while IFS= read -r f; do _info "  /etc/resolver/${f}"; done
        fi
    fi

    # ── 3. DNSSEC ─────────────────────────────────────────────────────────────
    # The AD (Authenticated Data) flag in a DNS response means the upstream
    # resolver validated the DNSSEC chain of trust.  macOS itself does not
    # validate — this is done by the configured upstream resolver.
    _hdr "DNSSEC"
    if command -v dig &>/dev/null; then
        local ad_flag
        ad_flag=$(dig +dnssec +time=4 +tries=1 sigok.verteiltesysteme.net A 2>/dev/null \
                  | awk '/^;; flags:/{for(i=1;i<=NF;i++) if($i=="ad") print "yes"}')
        local fail_res
        fail_res=$(dig +short +time=4 +tries=1 dnssec-failed.org A 2>/dev/null)
        if [[ "$ad_flag" == "yes" ]]; then
            _ok  "Upstream resolver validates DNSSEC (AD flag set)"
        elif [[ -z "$fail_res" ]]; then
            _ok  "Upstream resolver blocks broken DNSSEC (dnssec-failed.org → SERVFAIL)"
        else
            _warn "Upstream resolver does NOT validate DNSSEC (AD absent, failed.org resolves)"
            _info "Consider: 1.1.1.1, 8.8.8.8, or a local validator (unbound)"
        fi
    else
        _unkn "dig not found — brew install bind"
    fi
    pgrep -q unbound        2>/dev/null && _ok  "unbound running (local DNSSEC validator)"
    pgrep -q dnscrypt-proxy 2>/dev/null && _ok  "dnscrypt-proxy running (supports DNSSEC)"
    pgrep -q stubby         2>/dev/null && _ok  "stubby running (DoT + DNSSEC stub resolver)"

    # ── 4. DNS over TLS (DoT — port 853) ─────────────────────────────────────
    # macOS Monterey+ supports encrypted DNS natively via a configuration profile
    # (System Settings → Network → DNS) or via third-party daemons (stubby).
    _hdr "DNS over TLS  (DoT  ·  port 853)"
    local dot_prof
    dot_prof=$(profiles list 2>/dev/null | grep -Ei "encrypted.dns|dns.over.tls|DoT" | head -5)
    [[ -n "$dot_prof" ]] \
        && _ok  "DoT configuration profile installed" \
        || _info "No DoT profile found via profiles(1)"
    local dot_scutil
    dot_scutil=$(scutil --dns 2>/dev/null | grep -i "options.*encrypt\|encrypt")
    [[ -n "$dot_scutil" ]] \
        && _ok  "scutil reports encrypted resolver" \
        || _info "scutil shows no 'encrypted' resolver option"
    local dot_conns
    dot_conns=$(lsof -iTCP:853 -sTCP:ESTABLISHED -n -P 2>/dev/null | tail -n +2)
    if [[ -n "$dot_conns" ]]; then
        _ok  "Active TCP:853 (DoT) connection(s):"
        while IFS= read -r l; do _info "  ${l}"; done <<< "$dot_conns"
    else
        _info "No active TCP:853 connections (DoT idle or not configured)"
    fi
    pgrep -q stubby 2>/dev/null && _ok "stubby running (dedicated DoT stub resolver)" || true

    # ── 5. DNS over HTTPS (DoH — port 443) ───────────────────────────────────
    # DoH wraps DNS in HTTPS, making it indistinguishable from web traffic.
    _hdr "DNS over HTTPS  (DoH  ·  port 443)"
    local doh_prof
    doh_prof=$(profiles list 2>/dev/null | grep -Ei "dns.over.https|DoH|encrypted.dns" | head -5)
    [[ -n "$doh_prof" ]] \
        && _ok  "DoH configuration profile installed" \
        || _info "No DoH profile found via profiles(1)"
    local doh_scutil
    doh_scutil=$(scutil --dns 2>/dev/null | grep -i "https\|doh")
    [[ -n "$doh_scutil" ]] \
        && _ok  "scutil reports HTTPS resolver" \
        || _info "scutil shows no HTTPS resolver"
    local doh_found=0
    for proc in dnscrypt-proxy cloudflared nextdns; do
        pgrep -q "$proc" 2>/dev/null && _ok "DoH daemon running: ${proc}" && (( doh_found++ )) || true
    done
    (( doh_found == 0 )) && _info "No local DoH daemons detected (dnscrypt-proxy / cloudflared / nextdns)"

    # ── 6. ECH — Encrypted Client Hello ──────────────────────────────────────
    # ECH encrypts the TLS ClientHello SNI field so observers can't see which
    # hostname is being connected to even when the IP is known.
    # Requires: macOS 13+ (libnetwork TLS stack) + resolver that passes TYPE65/HTTPS records.
    _hdr "ECH — Encrypted Client Hello  (TLS SNI privacy)"
    local macos_ver macos_maj
    macos_ver=$(sw_vers -productVersion 2>/dev/null)
    macos_maj="${macos_ver%%.*}"
    if (( macos_maj >= 13 )); then
        _ok  "macOS ${macos_ver} — ECH supported by libnetwork TLS stack"
    else
        _warn "macOS ${macos_ver} — ECH requires macOS 13 (Ventura) or later"
    fi
    if command -v dig &>/dev/null; then
        # Use TYPE65 (numeric) — dig 9.10.x does not recognise the "HTTPS" type name
        # and silently falls back to an A query, producing false results.
        local ech_rec
        ech_rec=$(dig +short +time=4 +tries=1 TYPE65 cloudflare.com 2>/dev/null)
        if echo "$ech_rec" | grep -qi "ech="; then
            _ok  "HTTPS/SVCB record for cloudflare.com contains ECH key (text)"
        elif [[ -n "$ech_rec" ]]; then
            # dig 9.10.x returns raw hex (\# NN HEXDATA); non-empty = record present + SVCB passes
            _ok  "Resolver passes HTTPS/SVCB (TYPE65) records  (ECH data present, encoded)"
        else
            _warn "No HTTPS/SVCB record for cloudflare.com — resolver may be stripping TYPE65"
        fi
    else
        _unkn "dig not found — brew install bind"
    fi
    if command -v curl &>/dev/null; then
        # Probe whether libcurl actually supports ECH at runtime (not just whether the
        # flag appears in --help, which can be present even in non-ECH builds).
        local ech_probe_err
        ech_probe_err=$(curl --ech grease --max-time 1 -s -o /dev/null \
                        https://cloudflare.com 2>&1 | grep -i "does not support" || true)
        if [[ -n "$ech_probe_err" ]]; then
            _info "Installed libcurl does not support ECH (flag present but not compiled in)"
            _info "Requires curl built against an ECH-patched OpenSSL (not yet in stock Homebrew)"
        else
            local ech_result
            ech_result=$(curl -s -o /dev/null -w "%{http_code}" \
                         --ech hard --max-time 5 https://cloudflare.com 2>/dev/null || true)
            if [[ "$ech_result" == "200" || "$ech_result" == "301" || "$ech_result" == "302" ]]; then
                _ok  "curl ECH hard mode succeeded against cloudflare.com (HTTP ${ech_result})"
            else
                _warn "curl ECH hard mode failed or timed out (HTTP ${ech_result:-no response})"
                _info "Try: curl --ech grease https://cloudflare.com"
            fi
        fi
    else
        _unkn "curl not found"
    fi

    # ── 7. VPN ────────────────────────────────────────────────────────────────
    # utun* interfaces are macOS native VPN tunnels (IPsec, IKEv2, WireGuard).
    # DNS leak detection checks whether public resolvers are still visible
    # while a VPN is active — if so, DNS queries may escape the tunnel.
    _hdr "VPN"
    # Collect all tunnel-style interfaces, then separate active (has IP) from idle.
    # utun0-N with no IP are macOS NetworkExtension system services — not VPN tunnels.
    local vpn_ifaces active_vpn_iface ip
    vpn_ifaces=$(ifconfig 2>/dev/null \
                 | awk '/^(utun|ppp|ipsec|tun|tap)[0-9]/{gsub(":",""); print $1}')
    active_vpn_iface=""
    if [[ -n "$vpn_ifaces" ]]; then
        while IFS= read -r iface; do
            ip=$(ipconfig getifaddr "$iface" 2>/dev/null \
                 || ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
            if [[ -n "$ip" ]]; then
                _ok  "Active VPN interface: ${iface}  (${ip})"
                active_vpn_iface="$iface"
            fi
        done <<< "$vpn_ifaces"
    fi
    [[ -z "$active_vpn_iface" ]] && _info "No active VPN tunnel (utun / ppp / ipsec with IP)"
    local nc_out dot
    nc_out=$(scutil --nc list 2>/dev/null | grep -v '^$')
    if [[ -n "$nc_out" ]]; then
        _info "Configured VPN connections:"
        while IFS= read -r line; do
            dot=""
            echo "$line" | grep -q Connected    && dot="${G}●${N}"
            echo "$line" | grep -q Disconnected && dot="${D}○${N}"
            [[ -z "$dot" ]]                      && dot="${Y}◐${N}"
            printf "    %b  %s\n" "$dot" "$line"
        done <<< "$nc_out"
    else
        _info "No VPN connections configured in Network Preferences"
    fi
    local def_iface
    def_iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    if [[ "$def_iface" =~ ^(utun|ppp|tun|tap|ipsec) ]]; then
        _ok  "Default route via VPN interface ${def_iface} (full-tunnel — all traffic in VPN)"
    elif [[ -n "$def_iface" ]]; then
        _info "Default route via ${def_iface} (not a VPN interface)"
    fi
    # DNS leak only matters when the default route goes through the VPN (full-tunnel).
    # Tunnel-only (e.g. WARP) and split-tunnel configs intentionally preserve system DNS.
    if [[ "$def_iface" =~ ^(utun|ppp|tun|tap|ipsec) ]]; then
        local pub_dns
        pub_dns=$(scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' \
                  | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|::1)' \
                  | sort -u)
        if [[ -n "$pub_dns" ]]; then
            _warn "Possible DNS leak — full-tunnel VPN active but public DNS servers visible:"
            while IFS= read -r ns; do _warn "  ${ns}"; done <<< "$pub_dns"
        else
            _ok  "No DNS leak detected (all resolvers are private/local)"
        fi
    elif [[ -n "$active_vpn_iface" ]]; then
        _info "Tunnel-only / split-tunnel — system DNS preserved by design (no leak check)"
    fi

    # ── 8. DNS Resolution Smoke Test ─────────────────────────────────────────
    _hdr "DNS Resolution Smoke Test"
    local res
    for domain in apple.com cloudflare.com one.one.one.one; do
        res=$(dscacheutil -q host -a name "$domain" 2>/dev/null \
              | awk '/ip_address/{print $2}' | head -1)
        [[ -n "$res" ]] \
            && _ok  "${domain}  →  ${res}" \
            || _fail "${domain}  →  resolution FAILED"
    done

    printf "\n${C}──────────────────────────────────────────────────────${N}\n\n"
    unset -f _hdr _ok _fail _warn _info _unkn
}
