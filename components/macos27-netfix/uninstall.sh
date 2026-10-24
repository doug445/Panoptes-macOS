#!/bin/sh
# Panoptes-macOS — https://github.com/doug445/Panoptes-macOS
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# uninstall.sh — remove the ARP-cache workaround.
#
# Normally you never run this: the agent re-runs detect.sh after every macOS
# or Homebrew update and runs this itself once the defect is confirmed fixed
# (see the self-check in lib/arp-cache-dump). Run it by hand only to remove the
# workaround early, or on a machine installed with AUTO_UNINSTALL=0.
#
# The arp_table() helpers inside consumer scripts can stay: they try the direct
# read first and only fall back to the cache. On an unaffected machine the
# direct read always wins, so they are inert.
#
# Files are removed BEFORE the job is booted out. When the agent runs this on
# itself, the bootout kills this very shell, so it has to be the last step.

set -u

LABEL="com.netwatch.arpcache"
HELPER="$HOME/.local/bin/arp-cache-dump"
DIR="$HOME/.local/share/netwatch"
CACHE="$DIR/arp.cache"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM=$(id -u)

echo "== removing macOS 27 ARP-cache workaround =="

[ -f "$PLIST" ]  && { rm -f "$PLIST";  echo "  removed $PLIST"; }
[ -f "$HELPER" ] && { rm -f "$HELPER"; echo "  removed $HELPER"; }

# Remove the cache too — a stale file left behind would be served by any
# consumer whose staleness guard is missing or misconfigured.
[ -f "$CACHE" ] && { rm -f "$CACHE"; echo "  removed $CACHE"; }

[ -d "$DIR/kit" ] && { rm -rf "$DIR/kit"; echo "  removed $DIR/kit"; }
rm -f "$DIR/selfcheck.state" "$DIR/selfcheck.state.tmp"
# selfcheck.log is kept deliberately: it records why the agent disappeared.

echo
echo "arp_table() helpers left in place in consumer scripts (harmless —"
echo "they prefer the direct read). Remove them by hand if you want them gone."

if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    echo "  unloading $LABEL"
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null \
        || launchctl remove "$LABEL" 2>/dev/null || true
else
    echo "  $LABEL was not loaded"
fi
