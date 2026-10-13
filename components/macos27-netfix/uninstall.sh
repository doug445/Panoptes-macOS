#!/bin/sh
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# uninstall.sh — remove the ARP-cache workaround.
#
# Use this when ./detect.sh reports NOT AFFECTED (Apple or Homebrew fixed the
# underlying issue). Leaving the agent installed on a healthy machine is not
# harmful but it is dead weight, and a cache nobody refreshes is a trap.
#
# The arp_table() helpers inside consumer scripts can stay: they try the direct
# read first and only fall back to the cache. On an unaffected machine the
# direct read always wins, so they are inert.

set -eu

LABEL="com.netwatch.arpcache"
HELPER="$HOME/.local/bin/arp-cache-dump"
CACHE="$HOME/.local/share/netwatch/arp.cache"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM=$(id -u)

echo "== removing macOS 27 ARP-cache workaround =="

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null && echo "  unloaded $LABEL" \
    || echo "  $LABEL was not loaded"

[ -f "$PLIST" ]  && { rm -f "$PLIST";  echo "  removed $PLIST"; }  || true
[ -f "$HELPER" ] && { rm -f "$HELPER"; echo "  removed $HELPER"; } || true

# Remove the cache too — a stale file left behind would be served by any
# consumer whose staleness guard is missing or misconfigured.
[ -f "$CACHE" ] && { rm -f "$CACHE"; echo "  removed $CACHE"; } || true

echo
echo "Done. arp_table() helpers left in place in consumer scripts (harmless —"
echo "they prefer the direct read). Remove them by hand if you want them gone."
