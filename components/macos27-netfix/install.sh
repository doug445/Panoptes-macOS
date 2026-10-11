#!/bin/sh
# install.sh — install the macOS 27 ARP-cache workaround. Idempotent.
#
# Installs:
#   ~/.local/bin/arp-cache-dump
#   ~/Library/LaunchAgents/com.netwatch.arpcache.plist   (StartInterval 15)
#
# Does NOT edit your scripts — it cannot know what is on a given machine.
# It lists the ones that need patching; patch them with lib/arp_table.bash.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
LABEL="com.netwatch.arpcache"
BIN="$HOME/.local/bin"
HELPER="$BIN/arp-cache-dump"
CACHE_DIR="$HOME/.local/share/netwatch"
CACHE="$CACHE_DIR/arp.cache"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM=$(id -u)

echo "== installing macOS 27 ARP-cache workaround =="

# --- gate on detect.sh ----------------------------------------------------
# Installing on an unaffected machine leaves a pointless agent running and a
# cache that could go stale and mislead. Refuse unless actually needed.
if [ "${FORCE:-0}" != "1" ]; then
    set +e
    "$HERE/detect.sh" > /dev/null 2>&1
    rc=$?
    set -e
    case "$rc" in
        0) : ;;
        1) echo "  detect.sh: NOT AFFECTED — nothing to install."
           echo "  Re-run ./detect.sh to see the measurements. FORCE=1 overrides."
           exit 0 ;;
        *) echo "  detect.sh could not determine status (exit $rc)."
           echo "  Run ./detect.sh directly. FORCE=1 overrides."
           exit 1 ;;
    esac
fi

# --- helper ---------------------------------------------------------------
mkdir -p "$BIN" "$CACHE_DIR"
cp "$HERE/lib/arp-cache-dump" "$HELPER"
chmod 755 "$HELPER"
echo "  installed $HELPER"

# --- LaunchAgent ----------------------------------------------------------
# Paths are written from $HOME at install time, so this is not tied to one user.
# ProgramArguments MUST stay /bin/sh — see the comment in arp-cache-dump.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <!-- Must be an Apple-signed interpreter. Pointing this at Homebrew bash
         reintroduces the exact macOS 27 empty-ARP problem this works around. -->
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$HELPER</string>
        <string>$CACHE</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>StartInterval</key>
    <integer>15</integer>

    <key>StandardErrorPath</key>
    <string>$CACHE_DIR/arpcache.err.log</string>
</dict>
</plist>
PLIST_EOF
echo "  installed $PLIST"

# --- (re)load -------------------------------------------------------------
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
echo "  loaded $LABEL"

# --- confirm it actually produced data ------------------------------------
n=0
while [ "$n" -lt 10 ]; do
    [ -s "$CACHE" ] && break
    sleep 1
    n=$((n + 1))
done

if [ -s "$CACHE" ]; then
    echo "  cache populated: $(grep -c . "$CACHE") entries at $CACHE"
else
    echo "  WARNING: cache is still empty after ${n}s."
    echo "  Check $CACHE_DIR/arpcache.err.log and launchctl print gui/$UID_NUM/$LABEL"
    exit 1
fi

# --- report consumers needing a patch -------------------------------------
echo
echo "== scripts that read the ARP table and may need patching =="
found=0
for d in "$HOME/.local/bin" "$HOME/bin"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.bak*|"$HELPER") continue ;; esac
        grep -qE '(^|[^-[:alnum:]_])arp[[:space:]]+-' "$f" 2>/dev/null || continue
        grep -q 'arp_table' "$f" 2>/dev/null && { printf "  patched   %s\n" "$f"; continue; }
        printf "  NEEDS FIX %s\n" "$f"
        found=1
    done
done
[ "$found" -eq 0 ] && echo "  (none outstanding)"

echo
echo "Patch each 'NEEDS FIX' entry using lib/arp_table.bash, then run ./verify.sh"
