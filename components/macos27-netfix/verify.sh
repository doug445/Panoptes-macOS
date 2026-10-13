#!/bin/sh
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# verify.sh — end-to-end health check of the ARP-cache workaround, exercised
# through the tainted path that actually matters. Read-only.
#
# Exit 0 = healthy, 1 = problem found.

set -u

LABEL="com.netwatch.arpcache"
CACHE="$HOME/.local/share/netwatch/arp.cache"
MAX_AGE=120
UID_NUM=$(id -u)
rc=0

say_ok()   { printf "  ok    %s\n" "$1"; }
say_bad()  { printf "  FAIL  %s\n" "$1"; rc=1; }

echo "== verifying macOS 27 ARP-cache workaround =="

# --- agent ----------------------------------------------------------------
# NOTE: "state = not running" is CORRECT here. This is a StartInterval job that
# fires briefly and exits. Judge it by cache freshness, never by process state.
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    say_ok "$LABEL is loaded"
    ec=$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | awk '/last exit code/{print $NF; exit}')
    case "${ec:-}" in
        0|"(never exited)"|"") say_ok "last exit code: ${ec:-n/a}" ;;
        *) say_bad "last exit code: $ec" ;;
    esac
else
    say_bad "$LABEL is NOT loaded — run ./install.sh"
fi

# --- cache ----------------------------------------------------------------
if [ -s "$CACHE" ]; then
    entries=$(grep -c . "$CACHE")
    age=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
    say_ok "cache has $entries entries"
    if [ "$age" -le "$MAX_AGE" ]; then
        say_ok "cache is fresh (${age}s old)"
    else
        say_bad "cache is STALE (${age}s old, limit ${MAX_AGE}s) — consumers will refuse it"
    fi
else
    say_bad "cache missing or empty: $CACHE"
fi

# --- the real test: can a TAINTED process resolve a MAC? ------------------
HB=""
for c in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$c" ] && { HB="$c"; break; }
done

if [ -n "$HB" ]; then
    GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
    if [ -n "${GW:-}" ]; then
        echo
        echo "  -- through $HB (the path that was broken) --"
        TMP=$(mktemp) || exit 1
        cat > "$TMP" <<EOF
#!$HB
ARP_CACHE="$CACHE"
arp_table() {
    local direct
    direct=\$(arp -an 2>/dev/null || true)
    if [[ -n "\$direct" ]]; then printf '%s\n' "\$direct"
    elif [[ -r "\$ARP_CACHE" ]]; then cat "\$ARP_CACHE" 2>/dev/null || true; fi
}
printf '  direct arp -an : %s lines\n' "\$(arp -an 2>/dev/null | grep -c . )"
printf '  arp_table      : %s lines\n' "\$(arp_table | grep -c . )"
printf '  gateway MAC    : %s\n' "\$(arp_table | awk -v w='($GW)' '\$2==w{print \$4; exit}')"
EOF
        out=$("$HB" "$TMP" 2>/dev/null)
        rm -f "$TMP"
        echo "$out" | sed 's/^/  /'
        mac=$(echo "$out" | awk '/gateway MAC/{print $NF}')
        case "${mac:-}" in
            *:*:*:*:*:*) echo; say_ok "tainted process resolved the gateway MAC" ;;
            *) echo; say_bad "tainted process could NOT resolve the gateway MAC" ;;
        esac
    else
        echo "  (no default route — skipping gateway resolution test)"
    fi
else
    echo "  (no Homebrew bash — nothing tainted to test)"
fi

echo
[ "$rc" -eq 0 ] && echo "  RESULT: healthy" || echo "  RESULT: problems found"
exit "$rc"
