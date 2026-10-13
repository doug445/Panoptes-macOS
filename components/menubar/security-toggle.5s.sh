#!/bin/bash
# <xbar.title>Security Toggle</xbar.title>
# <xbar.version>3.1</xbar.version>
# <xbar.author>William MacKinnon</xbar.author>
# <xbar.desc>WARP, AdGuard DNS and ProtonVPN toggles + WARP kill-switch / heal / status</xbar.desc>
# <xbar.abouturl>https://github.com/doug445/macOS-SecureNetwork-Suite</xbar.abouturl>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# security-toggle v3 (warp-killswitch)
#
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Source of truth for the menu. components/warp-killswitch/install.sh copies
# this file to both xbar locations; edit it here, then re-run the installer.
#
# HOW THE THREE SWITCHES RELATE
#   Cloudflare WARP and ProtonVPN cannot share the machine: when ProtonVPN's
#   WireGuard system extension takes the network, WARP's daemon wedges with its
#   lockdown firewall still up and the box goes dark (seen 2026-10-13). So the
#   ProtonVPN "Connect" item PARKS the WARP stack first (warp-killswitch down
#   --keep-dns: daemon stopped and disabled, DNS left alone), and "Disconnect"
#   rebuilds WARP afterwards. The watchdog never acts while WARP is parked.
#
#   ProtonVPN 6.x only connects when its own app drives the connection —
#   `scutil --nc start` on its service returns 0 and does nothing — so the menu
#   clicks the app's "Quick Connect" / "Disconnect" button through System
#   Events. That needs xbar in System Settings › Privacy & Security ›
#   Accessibility; without it the menu brings the app to the front and says so.
#
#   Rebuild (after a Tear Down) re-applies the AdGuard DNS policy on top of the
#   helper's verbatim DNS restore, so the stack comes back as "WARP + AdGuard"
#   even if AdGuard had been toggled off before the teardown.
#
# Every action ends by asking xbar to re-run this plugin, so the icons reflect
# the verified end state rather than the moment the click happened.

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export TERM=dumb PAGER=cat
unset LESS LESS_TERMCAP_mb LESS_TERMCAP_md LESS_TERMCAP_me \
      LESS_TERMCAP_se LESS_TERMCAP_so LESS_TERMCAP_ue LESS_TERMCAP_us

WARP_CLI="/usr/local/bin/warp-cli"
[ -x "$WARP_CLI" ] || WARP_CLI="$(command -v warp-cli || echo /usr/local/bin/warp-cli)"
KILLSWITCH="/usr/local/bin/warp-killswitch"
KILL_MARKER="/var/db/warp-killswitch/killed"
STATE_DIR="$HOME/.local/state/macos-securenetwork-suite"
PARK_MARKER="$STATE_DIR/warp-parked-for-protonvpn"   # WARP was parked BY the menu for ProtonVPN
AX_MARKER="$STATE_DIR/accessibility-missing"          # last ProtonVPN click failed for lack of Accessibility
PROTON_APP="ProtonVPN"                                # app bundle name and System Events process name
# ProtonVPN's VPN service ID differs per install, and the service is only
# registered while the app is running — look it up rather than hardcoding it.
PROTON_ID="${SECURENET_PROTON_ID:-$(/usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/grep -i proton | /usr/bin/grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | /usr/bin/head -1)}"
ADGUARD_PRIMARY="94.140.14.140"
ADGUARD_SECONDARY="94.140.14.141"
FALLBACK1="9.9.9.9"
FALLBACK2="1.1.1.1"
DNS_SERVICES=("Wi-Fi" "iPhone USB")                   # the services the AdGuard toggle manages
ACCESSIBILITY_PANE="x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"

# ── Helpers ───────────────────────────────────────────────────────────────
# time-bounded command (no coreutils timeout on macOS); a wedged daemon must not freeze the menu
tmo() { local s="$1" pid i=0; shift; "$@" & pid=$!; while /bin/kill -0 "$pid" 2>/dev/null; do [ "$i" -ge $((s*10)) ] && { /bin/kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }; /bin/sleep 0.1; i=$((i+1)); done; wait "$pid"; }
# wait_for SECONDS FUNC EXPECTED — poll a status function until it reports the expected word
wait_for() { local s="$1" fn="$2" want="$3" i=0; while [ "$i" -lt "$s" ]; do [ "$($fn)" = "$want" ] && return 0; /bin/sleep 1; i=$((i+1)); done; [ "$($fn)" = "$want" ]; }
flush_dns() { /usr/bin/dscacheutil -flushcache >/dev/null 2>&1; /usr/bin/sudo -n /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1; }
note() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }
refresh_menu() { /usr/bin/open -g "xbar://app/refreshPlugin?path=$(basename "$0")" >/dev/null 2>&1; }
set_dns() {   # set_dns SERVER... — on every managed service
  local svc
  for svc in "${DNS_SERVICES[@]}"; do
    /usr/bin/sudo -n /usr/sbin/networksetup -setdnsservers "$svc" "$@" >/dev/null 2>&1
  done
  flush_dns
}
hide_app() { /usr/bin/osascript -e "tell application \"System Events\" to set visible of process \"$PROTON_APP\" to false" >/dev/null 2>&1; }

# proton_click LABEL — press a button in the ProtonVPN main window ("Quick Connect" / "Disconnect").
# Returns 0 clicked, 1 button not found, 2 no Accessibility permission.
proton_click() {
  local label="$1" out
  /usr/bin/open -g -a "$PROTON_APP"            # start the app, or re-open its window, without stealing focus
  out=$(/usr/bin/osascript - "$label" "$PROTON_APP" <<'AS' 2>&1
on run argv
  set wanted to item 1 of argv
  set procName to item 2 of argv
  tell application "System Events"
    tell process procName
      repeat 40 times
        if (count of windows) > 0 then exit repeat
        delay 0.25
      end repeat
      if (count of windows) = 0 then return "no-window"
      try
        click (first button of window 1 whose name is "Done")
        delay 0.5
      end try
      repeat 20 times
        try
          click (first button of window 1 whose name is wanted)
          return "clicked"
        end try
        delay 0.5
      end repeat
      return "not-found"
    end tell
  end tell
end run
AS
)
  case "$out" in
    clicked)               /bin/rm -f "$AX_MARKER"; return 0 ;;
    *"assistive access"*)  /bin/mkdir -p "$STATE_DIR"; : > "$AX_MARKER"; return 2 ;;
    *)                     return 1 ;;
  esac
}
# When the click could not be made, hand the user the app itself and say why.
proton_manual() {   # proton_manual RC LABEL
  /usr/bin/open -a "$PROTON_APP"
  if [ "$1" -eq 2 ]; then
    note "ProtonVPN needs Accessibility" "System Settings › Privacy & Security › Accessibility: turn on xbar. For now, click $2 in the app."
    /usr/bin/open -g "$ACCESSIBILITY_PANE" >/dev/null 2>&1
  else
    note "ProtonVPN" "Could not find the $2 button — click it in the app."
  fi
}

# ── Status checks (no warp-cli — avoids ANSI stdout bleed) ───────────────
warp_status() {
  # WARP tunnel_only mode always assigns 172.16.0.2 to its utun interface
  /sbin/ifconfig 2>/dev/null | /usr/bin/grep -qE 'inet 172\.16\.0\.2( |$)' && echo "connected" || echo "disconnected"
}
killed_status() { [[ -f "$KILL_MARKER" ]] && echo "yes" || echo "no"; }
parked_status() { [[ -f "$PARK_MARKER" ]] && echo "yes" || echo "no"; }
adguard_status() {
  local dns
  dns=$(/usr/sbin/networksetup -getdnsservers Wi-Fi 2>/dev/null | /usr/bin/head -1)
  [[ "$dns" == "$ADGUARD_PRIMARY" ]] && echo "on" || echo "off"
}
proton_status() {
  if [[ -n "$PROTON_ID" ]]; then
    [[ "$(/usr/sbin/scutil --nc status "$PROTON_ID" 2>/dev/null | /usr/bin/head -1)" == "Connected" ]] && echo "connected" || echo "disconnected"
  else
    echo "disconnected"                        # no service registered = app not running = not connected
  fi
}
watchdog_status() {
  /usr/bin/pgrep -f 'warp-killswitch watchdog' >/dev/null 2>&1 && echo "on" || echo "off"
}

# ── Actions ───────────────────────────────────────────────────────────────
# Each action does its work, waits for the verified end state, asks xbar to
# re-run the plugin and exits: xbar ignores an action's stdout anyway.
case "${1:-}" in
  warp_on)
    if [[ "$(proton_status)" == "connected" ]]; then
      note "WARP blocked" "Disconnect ProtonVPN first."
    else
      tmo 20 "$WARP_CLI" --accept-tos connect >/dev/null 2>&1
      wait_for 15 warp_status connected && flush_dns || note "WARP" "Connect issued but no tunnel after 15 s — try Heal now."
    fi
    refresh_menu; exit 0 ;;
  warp_off)
    tmo 20 "$WARP_CLI" --accept-tos disconnect >/dev/null 2>&1
    wait_for 10 warp_status disconnected; flush_dns
    refresh_menu; exit 0 ;;
  killswitch_down)
    note "WARP" "Tearing down the WARP stack…"
    /bin/rm -f "$PARK_MARKER"                  # a deliberate teardown is not a park
    /usr/bin/sudo -n "$KILLSWITCH" down >/dev/null 2>&1      # the helper notifies the verified result
    refresh_menu; exit 0 ;;
  killswitch_up)
    if [[ "$(proton_status)" == "connected" ]]; then
      note "WARP blocked" "Disconnect ProtonVPN first — the two cannot run together."
    else
      note "WARP" "Rebuilding WARP + restoring DNS…"
      /bin/rm -f "$PARK_MARKER"
      if /usr/bin/sudo -n "$KILLSWITCH" up >/dev/null 2>&1; then
        set_dns "$ADGUARD_PRIMARY" "$ADGUARD_SECONDARY" "$FALLBACK1" "$FALLBACK2"   # the suite's DNS policy, not merely the pre-teardown state
      fi
    fi
    refresh_menu; exit 0 ;;
  killswitch_heal)
    note "WARP" "Running heal — checking link, tunnel and DNS…"
    /usr/bin/sudo -n "$KILLSWITCH" heal manual >/dev/null 2>&1
    refresh_menu; exit 0 ;;
  killswitch_status)
    out=$(/usr/bin/sudo -n "$KILLSWITCH" status 2>&1 | /usr/bin/sed 's/\\/\\\\/g; s/"/'"'"'/g')
    /usr/bin/osascript -e "display dialog \"$out\" with title \"WARP status\" buttons {\"OK\"} default button 1" >/dev/null 2>&1
    exit 0 ;;
  proton_on)
    if [[ "$(killed_status)" == "no" ]]; then
      # Park the whole WARP stack, not just the tunnel: a merely-disconnected
      # daemon wedges when ProtonVPN's extension takes over, and blackholes the Mac.
      note "ProtonVPN" "Parking WARP first (daemon stopped, DNS kept)…"
      /bin/mkdir -p "$STATE_DIR"; : > "$PARK_MARKER"
      /usr/bin/sudo -n "$KILLSWITCH" down --keep-dns >/dev/null 2>&1
    fi
    if proton_click "Quick Connect"; then
      if wait_for 25 proton_status connected; then hide_app; note "ProtonVPN" "Connected. WARP is parked until you disconnect."
      else note "ProtonVPN" "Quick Connect pressed but no tunnel after 25 s — check the app."; /usr/bin/open -a "$PROTON_APP"; fi
    else
      proton_manual $? "Quick Connect"
    fi
    refresh_menu; exit 0 ;;
  proton_off)
    if proton_click "Disconnect"; then
      wait_for 15 proton_status disconnected; hide_app
    else
      rc=$?
      [[ -n "$PROTON_ID" ]] && /usr/sbin/scutil --nc stop "$PROTON_ID" >/dev/null 2>&1   # harmless if the app ignores it
      wait_for 5 proton_status disconnected || proton_manual "$rc" "Disconnect"
    fi
    if [[ "$(proton_status)" == "disconnected" && "$(parked_status)" == "yes" ]]; then
      /bin/rm -f "$PARK_MARKER"
      note "WARP" "ProtonVPN is off — rebuilding WARP…"
      /usr/bin/sudo -n "$KILLSWITCH" up >/dev/null 2>&1    # DNS was kept, so nothing to re-apply
    fi
    refresh_menu; exit 0 ;;
  dns_on)
    set_dns "$ADGUARD_PRIMARY" "$ADGUARD_SECONDARY" "$FALLBACK1" "$FALLBACK2"
    wait_for 5 adguard_status on
    refresh_menu; exit 0 ;;
  dns_off)
    set_dns "$FALLBACK1" "$FALLBACK2"
    wait_for 5 adguard_status off
    refresh_menu; exit 0 ;;
  open_accessibility)
    /usr/bin/open "$ACCESSIBILITY_PANE"; exit 0 ;;
esac

# ── Gather state ──────────────────────────────────────────────────────────
W=$(warp_status); D=$(adguard_status); P=$(proton_status); K=$(killed_status); PK=$(parked_status); WD=$(watchdog_status)
SELF="bash='$0' terminal=false"

# ── Menu bar title ────────────────────────────────────────────────────────
# Left glyph = tunnel (🛡️ WARP, 🟣 ProtonVPN, 💀 torn down, 🔓 none); right = DNS (🔵 AdGuard, ⚫ fallback/DHCP).
if   [[ "$P" == "connected" && "$D" == "on"  ]]; then echo "🟣🔵"
elif [[ "$P" == "connected"                  ]]; then echo "🟣⚫"
elif [[ "$K" == "yes"                        ]]; then echo "💀🔴"
elif [[ "$W" == "connected" && "$D" == "on"  ]]; then echo "🛡️🔵"
elif [[ "$W" == "connected"                  ]]; then echo "🛡️⚫"
elif [[ "$D" == "on"                         ]]; then echo "🔓🔵"
else echo "🔓⚫"
fi
echo "---"

if [[ "$K" == "yes" && "$P" != "connected" ]]; then
  if [[ "$PK" == "yes" ]]; then
    echo "⏸️ WARP PARKED for ProtonVPN (not connected) | color=orange size=13"
    echo "🟢 Rebuild WARP now | $SELF param1=killswitch_up refresh=true color=green"
  else
    echo "💀 WARP KILLED — stack torn down | color=red size=13"
    echo "DHCP DNS · captive-portal ready | color=gray"
    echo "🟢 Rebuild WARP + AdGuard DNS | $SELF param1=killswitch_up refresh=true color=green"
  fi
  echo "---"
fi
if [[ "$P" == "connected" ]]; then
  echo "🟣 ProtonVPN active — WARP is parked until you disconnect | color=orange"
  echo "---"
fi

echo "Cloudflare WARP | color=white size=13"
if [[ "$K" == "yes" ]]; then
  if [[ "$P" == "connected" ]]; then echo "⏸️ Parked for ProtonVPN (daemon stopped) | color=orange"
  else echo "💀 Killed (daemon stopped + disabled) | color=red"
       echo "🟢 Rebuild WARP + AdGuard DNS | $SELF param1=killswitch_up refresh=true"; fi
else
  if [[ "$W" == "connected" ]]; then
    echo "✅ Connected (tunnel-only) | color=green"
    echo "⏹️ Disconnect | $SELF param1=warp_off refresh=true"
  else
    echo "⭕ Disconnected | color=red"
    echo "▶️ Connect | $SELF param1=warp_on refresh=true"
  fi
  echo "🔴 Last Resort: Tear Down (reset internet) | $SELF param1=killswitch_down refresh=true color=red"
fi
echo "🩺 Heal now (auto-repair) | $SELF param1=killswitch_heal refresh=true"
echo "ℹ️ Status | $SELF param1=killswitch_status refresh=false"
if   [[ "$K" == "yes" ]]; then echo "watchdog: standing by (WARP is down) | color=gray size=11"
elif [[ "$WD" == "on" ]]; then echo "watchdog: active | color=gray size=11"
else echo "watchdog: NOT running | color=orange size=11"; fi
echo "---"

echo "AdGuard DNS | color=white size=13"
if [[ "$D" == "on" ]]; then
  echo "✅ Active — $ADGUARD_PRIMARY (no-log, no-ECS) | color=green"
  echo "⏹️ Disable | $SELF param1=dns_off refresh=true"
else
  echo "⭕ Inactive | color=gray"
  echo "▶️ Enable | $SELF param1=dns_on refresh=true"
fi
echo "Fallback: $FALLBACK1 + $FALLBACK2 | color=gray"
echo "---"

echo "ProtonVPN | color=white size=13"
if [[ "$P" == "connected" ]]; then
  echo "🟣 Connected | color=purple"
  if [[ "$PK" == "yes" ]]; then echo "⏹️ Disconnect → rebuild WARP | $SELF param1=proton_off refresh=true"
  else echo "⏹️ Disconnect | $SELF param1=proton_off refresh=true"; fi
elif [[ "$W" == "connected" || "$K" == "no" ]]; then
  echo "⭕ Disconnected | color=gray"
  echo "▶️ Connect (parks WARP first) | $SELF param1=proton_on refresh=true"
else
  echo "⭕ Disconnected | color=gray"
  echo "▶️ Connect | $SELF param1=proton_on refresh=true"
fi
if [[ -f "$AX_MARKER" ]]; then
  echo "⚠️ xbar needs Accessibility to drive the app — open settings | $SELF param1=open_accessibility refresh=false color=orange size=11"
fi
echo "---"
echo "Refresh | refresh=true"
