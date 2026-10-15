# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# ══ Network ═══════════════════════════════════════════════════════════════════
# Connectivity checks, port scanning, firewall, and DNS utilities.
# flushdns restarts mDNSResponder to clear both the DNS cache and LLMNR state.
# myip queries ipinfo.io directly. (Homebrew's `ipinfo` formula is an unrelated
# netmask calculator, and the real `ipinfo-cli` conflicts with it.)

alias myip='curl -s https://ipinfo.io/json; echo'        # public IP + ASN + geolocation
# private LAN IP: default-route interface if it is a real one (not a VPN utun), else Wi-Fi,
# else en0 — on 2012-2017 iMacs/minis en0 is Ethernet and Wi-Fi is en1
function localip {
    local i
    i=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
    [[ "$i" == en* ]] || i=$(networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')
    ipconfig getifaddr "${i:-en0}"
}
alias allips='ifconfig | grep "inet " | grep -v 127.0.0.1'   # all non-loopback local IPs
alias flushdns='sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder'
alias checknet='echo "--- DNS CONFIG ---" && scutil --dns | grep nameserver | head -n 5 && echo "\n--- WARP STATUS ---" && warp-cli status && echo "\n--- mDNS STATUS ---" && sudo launchctl list | grep mDNSResponder && echo "\n--- ADGUARD REACHABILITY ---" && ping -c 1 94.140.14.14 &> /dev/null && echo "AdGuard DNS: REACHABLE" || echo "AdGuard DNS: UNREACHABLE"'

alias ports='sudo lsof -iTCP -sTCP:LISTEN -n -P'         # all listening TCP ports + owning process
alias udports='lsof -iUDP -n -P'                         # listening UDP sockets
alias allports='lsof -i -n -P'                           # every open network connection

alias scan='nmap -sV'                                    # service version scan: scan 192.168.1.1
alias scanfast='nmap -T4 -F'                             # quick scan of common ports only
alias scanfull='nmap -T4 -p-'                            # full scan of all 65535 ports
alias scanping='nmap -sn'                                # ping sweep / host discovery: scanping 192.168.1.0/24

alias pingg='ping -c 5 8.8.8.8'                         # 5-packet ping to Google DNS
alias ping1='ping -c 1'                                  # single-packet reachability check
alias tracert='traceroute'                               # Windows-style alias for muscle memory
# speedtest-go (binary: speedtest). Homebrew deprecated speedtest-cli (disabled 2027-01-18).
# speed test: speedtest-go (Homebrew; binary `speedtest`) or speedtest-cli (MacPorts/pip)
function speedtest {
    if command speedtest --version 2>/dev/null | grep -qi 'speedtest-go'; then command speedtest --unix "$@"
    elif command -v speedtest-cli >/dev/null; then command speedtest-cli --simple "$@"
    else echo "install speedtest-go (Homebrew) or speedtest-cli (MacPorts)" >&2; return 1; fi
}

alias arp='arp -a'                                       # display ARP cache (all local network hosts seen)
alias route='netstat -rn'                                # routing table (numeric, no DNS lookup)
alias netstats='netstat -s'                              # per-protocol network statistics


# ══ Network ═══════════════════════════════════════════════════════════════════

# Print a consolidated network summary: interfaces, routing table, DNS servers.
netinfo() {
    echo -e "\e[1;36m── Interfaces ──────────────────────────────────────\e[0m"
    ifconfig | awk '/^[a-z]/{iface=$1} /inet /{print iface" "$2" "substr($0, index($0,$4))}'
    echo -e "\e[1;36m── Routing Table ───────────────────────────────────\e[0m"
    netstat -rn | grep -v "^Routing\|^Destination\|^$"
    echo -e "\e[1;36m── DNS Servers ─────────────────────────────────────\e[0m"
    scutil --dns | grep nameserver | sort -u
}

# Test whether a specific TCP port is open on a host (3-second timeout).
# Usage: port_check host port
port_check() {
    local host="$1" port="$2"
    [[ -z "$host" || -z "$port" ]] && echo "Usage: port_check <host> <port>" && return 1
    if /usr/bin/nc -z -w3 "$host" "$port" 2>/dev/null; then
        echo -e "\e[1;32m[OPEN]  \e[0m ${host}:${port}"
    else
        echo -e "\e[1;31m[CLOSED]\e[0m ${host}:${port}"
    fi
}

# Scan a sequential range of TCP ports on a host (1-second per-port timeout).
# Usage: port_range host start_port end_port
port_range() {
    local host="$1" start="$2" end="$3"
    [[ -z "$host" || -z "$start" || -z "$end" ]] && \
        echo "Usage: port_range <host> <start> <end>" && return 1
    for port in $(seq "$start" "$end"); do
        /usr/bin/nc -z -w1 "$host" "$port" 2>/dev/null && \
            echo -e "\e[1;32m[OPEN]  \e[0m ${host}:${port}"
    done
}

# Watch all ESTABLISHED connections, refreshing every 2 seconds.
# Requires GNU watch (Homebrew: brew install watch · MacPorts: sudo port install watch)
watch_conns() {
    watch -n2 "lsof -i -n -P | grep ESTABLISHED"
}

# Perform a forward DNS lookup (name → IP) and a reverse lookup (IP → name).
# Uses dscacheutil (macOS DNS cache) with host(1) as fallback.
resolve() {
    [[ -z "$1" ]] && echo "Usage: resolve <host_or_ip>" && return 1
    echo "Forward: $(dscacheutil -q host -a name "$1" 2>/dev/null | grep ip_address || \
                     host "$1" | head -1)"
    echo "Reverse: $(host "$1" 2>/dev/null | tail -1)"
}
