#!/bin/bash
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# macOS-SecureNetwork-Suite — uninstall.sh
#
# Removes what install.sh put in place. Run as your normal user.
#
# Removed: warp-killswitch (helper, watchdog, re-dispatch daemons, sudoers;
# rebuilds WARP first if it is killed; restores the pre-killswitch menu
# plugin), the macOS 27 ARP-cache agent, the netwatch LaunchAgent, netwatch /
# nettop / netcheck / probesource from ~/.local/bin, the suite's sudoers rules
# and the ~/.zshrc source block.
#
# Left alone, because removing them could cut you off or is yours to decide:
# DNS server settings, the Application Firewall, WARP itself, Homebrew and
# everything it installed, configuration profiles (remove them in System
# Settings › General › Device Management on macOS 14+; Privacy & Security › Profiles on 13;
# System Preferences › Profiles on 11–12), Firefox user.js, and all logs.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
C="$HERE/components"
[ "$(id -u)" -ne 0 ] || { echo "run as your normal user, not root." >&2; exit 1; }
sudo -v || exit 1

echo "== warp-killswitch"
sudo bash "$C/warp-killswitch/install.sh" --uninstall --user "$USER"

echo "== macOS 27 ARP-cache workaround"
[ -f "$HOME/Library/LaunchAgents/com.netwatch.arpcache.plist" ] && /bin/sh "$C/macos27-netfix/uninstall.sh"

echo "== netwatch / netcheck / probesource"
launchctl bootout "gui/$(id -u)/com.netwatch" 2>/dev/null
/bin/rm -f "$HOME/Library/LaunchAgents/com.netwatch.plist"
for b in netwatch nettop netcheck probesource; do /bin/rm -f "$HOME/.local/bin/$b"; done

echo "== sudoers"
sudo /bin/rm -f /etc/sudoers.d/securenet-dns /etc/sudoers.d/securenet-netcheck

echo "== zsh"
if grep -qF '# >>> macOS-SecureNetwork-Suite >>>' "$HOME/.zshrc" 2>/dev/null; then
    /bin/cp -p "$HOME/.zshrc" "$HOME/.zshrc.bak.$(date +%Y%m%d-%H%M%S)"
    /usr/bin/sed -i '' '/# >>> macOS-SecureNetwork-Suite >>>/,/# <<< macOS-SecureNetwork-Suite <<</d' "$HOME/.zshrc"
fi
/bin/rm -rf "$HOME/.config/macos-securenetwork-suite"

echo
echo "Done. Left in place: DNS settings, firewall, WARP, Homebrew packages,"
echo "configuration profiles, Firefox user.js, and logs under ~/.local/share and /var/log."
