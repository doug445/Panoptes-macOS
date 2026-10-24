# Panoptes-macOS — https://github.com/doug445/Panoptes-macOS
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# arp_table() — paste into any bash script that reads the ARP table.
#
# Tries the direct read FIRST, so the script keeps working when run by hand from
# zsh (untainted) and on machines/OS versions where the restriction does not
# apply. Falls back to the cache published by com.netwatch.arpcache only when
# the direct read comes back empty. This helper can stay if Apple fixes this
# (the agent retires itself; the direct read then always wins).
#
# Requires (define near the top of the script, before first use):
#   ARP_CACHE="${HOME}/.local/share/netwatch/arp.cache"
#   ARP_CACHE_MAX_AGE=120
#   ARP_STALE_REPEAT=3600      # long-running monitors: re-notify at most this often
#   LOG_DIR="${HOME}/.local/share/netwatch"
#
# The "already warned" state is a FILE, not a shell variable: callers wrap this
# in `$(...)` and `| awk`, and a variable set in that subshell never reaches
# the main loop — netwatch re-notified on every poll until this was changed
# (2026-10-15). A one-shot tool can set ARP_STALE_REPEAT=0 to always report.
#
# Table rows look like:
#   ? (192.168.0.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
# so $2 is "(<ip>)" and $4 is the MAC.

arp_table() {
    local direct now mtime age last mark="${LOG_DIR}/arp_stale_notified"
    direct=$(arp -an 2>/dev/null || true)
    if [[ -n "$direct" ]]; then
        printf '%s\n' "$direct"
        return 0
    fi

    [[ -r "$ARP_CACHE" ]] || return 0

    # A stale cache is worse than none: it reports the PRE-ATTACK gateway MAC
    # and masks the exact ARP spoofing this is meant to catch. Refuse it, and
    # say so — degrading silently here defeats the purpose of the monitor.
    now=$(date +%s)
    mtime=$(stat -f %m "$ARP_CACHE" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if (( age > ARP_CACHE_MAX_AGE )); then
        last=$(cat "$mark" 2>/dev/null || true)
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if (( now - last >= ARP_STALE_REPEAT )); then
            echo "$now" > "$mark"
            log_event "WARN arp cache stale (${age}s) — ARP checks inert; is com.netwatch.arpcache loaded?"
            notify critical "Degraded" "ARP cache is ${age}s stale — spoofing detection is not running."
        fi
        return 0
    fi

    if [[ -e "$mark" ]]; then
        rm -f "$mark"
        log_event "INFO arp cache fresh again (${age}s old)"
    fi
    cat "$ARP_CACHE" 2>/dev/null || true
}

# --- usage -----------------------------------------------------------------
#
# Resolve one MAC (replaces `arp -n "$ip" | awk ...`):
#
#   get_mac_for_ip() {
#       local ip="$1"
#       arp_table | awk -v want="($ip)" '
#           $2 == want {
#               for (i = 1; i <= NF; i++)
#                   if ($i ~ /^[0-9a-f]{1,2}(:[0-9a-f]{1,2}){5}$/) { print $i; exit }
#           }
#       ' || true
#   }
#
# On-link test (replaces `arp -n "$ip" | grep -q ' at .* on '`):
#
#   arp_table | awk -v want="($ip)" '
#       $2 == want && $4 ~ /^[0-9a-f]{1,2}(:[0-9a-f]{1,2}){5}$/ { found = 1 }
#       END { exit found ? 0 : 1 }' && return 0
#
# Build a whole IP->MAC map in one pass (for loops; avoids re-reading per IP):
#
#   declare -A sys_mac
#   while IFS=$'\t' read -r sip smac; do
#       [[ -n "$sip" ]] && sys_mac[$sip]="$smac"
#   done < <(arp_table | awk '
#       $4 ~ /^[0-9a-f]{1,2}(:[0-9a-f]{1,2}){5}$/ {
#           addr = $2; gsub(/[()]/, "", addr); print addr "\t" $4
#       }')
#
# If the script has no log_event/notify, replace those two calls in the stale
# branch with whatever it uses. Do NOT delete them — silent staleness is the
# failure mode this guard exists to prevent.
