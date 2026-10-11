#!/bin/bash
# <swiftbar.title>Security Toggle</swiftbar.title>
# <swiftbar.version>2.0</swiftbar.version>
# <swiftbar.author>Will</swiftbar.author>
# <swiftbar.desc>WARP, AdGuard DNS, ProtonVPN toggles + WARP kill-switch / heal / status</swiftbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# security-toggle v3 (warp-killswitch)

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export TERM=dumb PAGER=cat
unset LESS LESS_TERMCAP_mb LESS_TERMCAP_md LESS_TERMCAP_me \
      LESS_TERMCAP_se LESS_TERMCAP_so LESS_TERMCAP_ue LESS_TERMCAP_us

WARP_CLI="/usr/local/bin/warp-cli"
[ -x "$WARP_CLI" ] || WARP_CLI="$(command -v warp-cli || echo /usr/local/bin/warp-cli)"
KILLSWITCH="/usr/local/bin/warp-killswitch"
KILL_MARKER="/var/db/warp-killswitch/killed"
# ProtonVPN's VPN service ID differs per install, and the service is only
# registered while the app is running — look it up rather than hardcoding it.
PROTON_ID="${SECURENET_PROTON_ID:-$(/usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/grep -i proton | /usr/bin/grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | /usr/bin/head -1)}"
ADGUARD_PRIMARY="94.140.14.140"
ADGUARD_SECONDARY="94.140.14.141"
FALLBACK1="9.9.9.9"
FALLBACK2="1.1.1.1"

# time-bounded warp-cli (no coreutils timeout on macOS); a wedged daemon must not freeze the menu
tmo() { local s="$1" pid i=0; shift; "$@" & pid=$!; while /bin/kill -0 "$pid" 2>/dev/null; do [ "$i" -ge $((s*10)) ] && { /bin/kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }; /bin/sleep 0.1; i=$((i+1)); done; wait "$pid"; }
flush_dns() { /usr/bin/dscacheutil -flushcache >/dev/null 2>&1; /usr/bin/sudo /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1; }
note() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

# ── Status checks (no warp-cli — avoids ANSI stdout bleed) ───────────────
warp_status() {
  # WARP tunnel_only mode always assigns 172.16.0.2 to its utun interface
  /sbin/ifconfig 2>/dev/null | /usr/bin/grep -q "172.16.0.2" && echo "connected" || echo "disconnected"
}
killed_status() { [[ -f "$KILL_MARKER" ]] && echo "yes" || echo "no"; }
adguard_status() {
  local dns
  dns=$(/usr/sbin/networksetup -getdnsservers Wi-Fi 2>/dev/null | /usr/bin/head -1)
  [[ "$dns" == "$ADGUARD_PRIMARY" ]] && echo "on" || echo "off"
}
proton_status() {
  /usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/grep -i proton | /usr/bin/grep -q "Connected" && echo "connected" || echo "disconnected"
}
watchdog_status() {
  /usr/bin/pgrep -f 'warp-killswitch watchdog' >/dev/null 2>&1 && echo "on" || echo "off"
}

# ── Actions ───────────────────────────────────────────────────────────────
case "${1:-}" in
  warp_on)
    if [[ "$(proton_status)" == "connected" ]]; then
      note "WARP blocked" "Disconnect ProtonVPN first."
    else
      tmo 20 "$WARP_CLI" --accept-tos connect >/dev/null 2>&1
      sleep 2; flush_dns
    fi
    ;;
  warp_off)
    tmo 20 "$WARP_CLI" --accept-tos disconnect >/dev/null 2>&1
    sleep 1; flush_dns
    ;;
  killswitch_down)
    note "WARP" "Tearing down the WARP stack…"
    /usr/bin/sudo "$KILLSWITCH" down >/dev/null 2>&1      # the helper notifies the verified result
    ;;
  killswitch_up)
    note "WARP" "Rebuilding WARP + restoring DNS…"
    /usr/bin/sudo "$KILLSWITCH" up >/dev/null 2>&1
    sleep 2
    ;;
  killswitch_heal)
    note "WARP" "Running heal — checking link, tunnel and DNS…"
    /usr/bin/sudo "$KILLSWITCH" heal manual >/dev/null 2>&1
    ;;
  killswitch_status)
    out=$(/usr/bin/sudo "$KILLSWITCH" status 2>&1 | /usr/bin/sed 's/"/'"'"'/g')
    /usr/bin/osascript -e "display dialog \"$out\" with title \"WARP status\" buttons {\"OK\"} default button 1" >/dev/null 2>&1
    ;;
  proton_on)
    if [[ "$(warp_status)" == "connected" ]]; then
      note "ProtonVPN blocked" "Disconnect WARP first."
    else
      if [[ -n "$PROTON_ID" ]]; then
        /usr/sbin/scutil --nc start "$PROTON_ID" >/dev/null 2>&1
      else
        /usr/bin/open -g -a ProtonVPN      # app not running yet: its service appears once it starts
      fi
      sleep 3
    fi
    ;;
  proton_off)
    [[ -n "$PROTON_ID" ]] && /usr/sbin/scutil --nc stop "$PROTON_ID" >/dev/null 2>&1
    sleep 1
    ;;
  dns_on)
    /usr/bin/sudo /usr/sbin/networksetup -setdnsservers Wi-Fi "$ADGUARD_PRIMARY" "$ADGUARD_SECONDARY" "$FALLBACK1" "$FALLBACK2" >/dev/null 2>&1
    /usr/bin/sudo /usr/sbin/networksetup -setdnsservers "iPhone USB" "$ADGUARD_PRIMARY" "$ADGUARD_SECONDARY" "$FALLBACK1" "$FALLBACK2" >/dev/null 2>&1
    flush_dns
    ;;
  dns_off)
    /usr/bin/sudo /usr/sbin/networksetup -setdnsservers Wi-Fi "$FALLBACK1" "$FALLBACK2" >/dev/null 2>&1
    /usr/bin/sudo /usr/sbin/networksetup -setdnsservers "iPhone USB" "$FALLBACK1" "$FALLBACK2" >/dev/null 2>&1
    flush_dns
    ;;
esac

# ── Gather state ──────────────────────────────────────────────────────────
W=$(warp_status); D=$(adguard_status); P=$(proton_status); K=$(killed_status); WD=$(watchdog_status)

# ── Menu bar title ────────────────────────────────────────────────────────
if   [[ "$K" == "yes"                        ]]; then echo "💀🔴"
elif [[ "$W" == "connected" && "$D" == "on"  ]]; then echo "🛡️🔵"
elif [[ "$W" == "connected" && "$D" == "off" ]]; then echo "🛡️⚫"
elif [[ "$P" == "connected" && "$D" == "on"  ]]; then echo "🟣🔵"
elif [[ "$P" == "connected"                  ]]; then echo "🟣⚫"
else [[ "$D" == "on" ]] && echo "🔓🔵" || echo "🔓⚫"
fi
echo "---"

if [[ "$K" == "yes" ]]; then
  echo "💀 WARP KILLED — stack torn down | color=red size=13"
  echo "DHCP DNS · captive-portal ready | color=gray"
  echo "🟢 Rebuild WARP + restore DNS | bash='$0' param1=killswitch_up terminal=false refresh=true color=green"
  echo "---"
fi
if [[ "$P" == "connected" ]]; then
  echo "⚠️ ProtonVPN active — disconnect before using WARP | color=orange"
  echo "---"
fi

echo "Cloudflare WARP | color=white size=13"
if [[ "$K" == "yes" ]]; then
  echo "💀 Killed (daemon stopped + disabled) | color=red"
  echo "🟢 Rebuild WARP + restore DNS | bash='$0' param1=killswitch_up terminal=false refresh=true"
else
  if [[ "$W" == "connected" ]]; then
    echo "✅ Connected (tunnel-only) | color=green"
    echo "⏹️ Disconnect | bash='$0' param1=warp_off terminal=false refresh=true"
  else
    echo "⭕ Disconnected | color=red"
    echo "▶️ Connect | bash='$0' param1=warp_on terminal=false refresh=true"
  fi
  echo "🔴 Last Resort: Tear Down (reset internet) | bash='$0' param1=killswitch_down terminal=false refresh=true color=red"
fi
echo "🩺 Heal now (auto-repair) | bash='$0' param1=killswitch_heal terminal=false refresh=true"
echo "ℹ️ Status | bash='$0' param1=killswitch_status terminal=false refresh=false"
[[ "$WD" == "on" ]] && echo "watchdog: active | color=gray size=11" || echo "watchdog: NOT running | color=orange size=11"
echo "---"

echo "AdGuard DNS | color=white size=13"
if [[ "$D" == "on" ]]; then
  echo "✅ Active — 94.140.14.140 (no-ECS) | color=green"
  echo "⏹️ Disable | bash='$0' param1=dns_off terminal=false refresh=true"
else
  echo "⭕ Inactive | color=gray"
  echo "▶️ Enable | bash='$0' param1=dns_on terminal=false refresh=true"
fi
echo "Fallback: 9.9.9.9 + 1.1.1.1 | color=gray"
echo "---"

echo "ProtonVPN | color=white size=13"
if [[ "$P" == "connected" ]]; then
  echo "🟣 Connected | color=purple"
  echo "⏹️ Disconnect | bash='$0' param1=proton_off terminal=false refresh=true"
elif [[ "$W" == "connected" ]]; then
  echo "⭕ Disconnected (disconnect WARP first) | color=gray"
  echo "▶️ Connect (will warn) | bash='$0' param1=proton_on terminal=false refresh=true"
else
  echo "⭕ Disconnected | color=gray"
  echo "▶️ Connect | bash='$0' param1=proton_on terminal=false refresh=true"
fi
echo "---"
echo "Refresh | refresh=true"
