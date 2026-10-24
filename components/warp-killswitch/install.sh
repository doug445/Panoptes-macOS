#!/bin/bash
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# warp-killswitch-macos install.sh — installer for the Cloudflare WARP
# kill-switch, self-healer and watchdog on macOS. Part of macOS-SecureNetwork-Suite;
# the suite's top-level install.sh runs this for you. The root helper is the file
# ./warp-killswitch next to this script (installed verbatim); the xbar menu is copied
# from ../menubar/security-toggle.5s.sh. Shared helpers come from ../../lib/common.sh.
#
# WHAT IT INSTALLS (all idempotent; re-run to update)
#   /Library/PrivilegedHelperTools/warp-killswitch      root helper
#                                                       (down/up/heal/watchdog/purge/status/...)
#   /usr/local/bin/warp-killswitch                      convenience symlink to the helper (CLI only;
#                                                       sudoers and launchd never reference it)
#   /etc/sudoers.d/warp-killswitch                      NOPASSWD for the menu owner, pinned to the
#                                                       exact helper invocations the menu makes
#   /Library/LaunchDaemons/local.warp-killswitch.watchdog.plist
#                                                       always-on blackhole watchdog (root)
#   /Library/LaunchDaemons/local.warp-killswitch.do-{down,up,heal}.plist
#                                                       on-demand, launchd-rooted re-dispatch
#                                                       targets (macOS 27 enumeration blank)
#   /Library/LaunchDaemons/local.warp-killswitch.sleepwatcher.plist
#                                                       clean disconnect before sleep, reconnect
#                                                       after wake. OPTIONAL legacy path: only wired up
#                                                       if sleepwatcher already exists. Not required —
#                                                       the watchdog detects wake natively.
#   ~/Library/Application Support/xbar/plugins/security-toggle.5s.sh
#   ~/Documents/SwiftBar/security-toggle.5s.sh          the menu (copied from components/menubar/)
#   /var/db/warp-killswitch/                            state (killed marker, DNS backups)
#   /var/log/warp-killswitch.log                        everything the helper does
#
# WHY v3 (2026-09-09) — "never blackhole again", ported from the Linux v3
#   v1 was a manual last resort: `down` returned 0 without checking anything,
#   `up` fired `connect` and hoped, nothing was time-bounded, nothing watched.
#   What actually blackholes these machines is WARP's own lockdown firewall
#   (pf anchor com.cloudflare.warp_svc) staying up while the tunnel is dead —
#   stuck Connecting after sleep, after a Wi-Fi change, at a captive portal, or
#   after the daemon wedges. v3:
#     1. `up` waits for Connected AND a real raw-IP check, and rolls back to a
#        clean disconnected state if the tunnel never comes up.
#     2. `down` PROVES plain internet works and escalates until it does
#        (re-flush anchor -> flush utun routes -> bounce the network service).
#     3. `heal` + a watchdog LaunchDaemon: link up but internet dead for ~45 s
#        => decide from evidence (not-WARP / stale artifacts / soft reset /
#        hard teardown / captive portal) and notify. Never acts while killed.
#     4. every warp-cli call is time-bounded (pure bash — macOS has no
#        `timeout`, and perl may go away); a wedged daemon gets `launchctl kill`
#        after bootout stalls.
#     9. macOS 27: a process forked from a non-Apple-signed binary (xbar,
#        Homebrew bash, iTerm) reads an EMPTY ARP table. The link test detects
#        that, uses the netwatch ARP cache (macos27-netfix LaunchAgent) when it
#        is fresh, and otherwise judges the link by interface state — so a
#        menu-launched `heal` can never wrongly conclude "link down, not WARP".
#        Plugin backups are kept OUTSIDE the xbar plugin folder (xbar loads any
#        executable there as a second icon set).
#     5. wake handling: the watchdog notices a wall-clock jump > 120 s and
#        reconnects — the most common way the Mac tunnel goes stale. Needs no
#        third-party sleep hook; sleepwatcher is wired up only if already present.
#     6. EVERY route on WARP's utun is discovered and deleted (v4 AND v6, the
#        ~170 split-tunnel prefixes), not just 0/1 and 128/1; utun is discovered
#        before anything is torn down.
#     7. DNS backup/restore covers every network service, not just Wi-Fi and
#        iPhone USB; `down --keep-dns` leaves DNS alone (the watchdog uses it).
#     8. mDNSResponder cache flushed on every transition, including the menu's
#        own connect/disconnect; a mutex so menu and watchdog cannot overlap;
#        timestamped log; notifications report the VERIFIED outcome.
#
# REQUIREMENTS (stock unless noted): cloudflare-warp (warp-cli + the
#   com.cloudflare.1dot1dot1dot1.macos.warp.daemon LaunchDaemon), launchctl,
#   pfctl, route, netstat, networksetup, scutil, nc, curl, osascript;
#   xbar with the security-toggle plugin (menu). No package manager required.
#
# USAGE
#   sudo bash ./install.sh [--user NAME] [--no-menu] [--no-watchdog] [--no-sleep-hook]
#   sudo bash ./install.sh --uninstall
#   Always invoke via `bash` (copies on exFAT media have no exec bit).
set -u
export LC_ALL=C
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# Interactive rc files shadow commands (cat->bat, cp/mv/rm -i, ls->eza, grep
# options...). Absolute paths for everything shadowed, no exceptions.
CAT=/bin/cat; CP=/bin/cp; MV=/bin/mv; RM=/bin/rm; GREP=/usr/bin/grep
_bin() { local c; for c in "$@"; do [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done; printf '%s' "$1"; }
CHOWN=$(_bin /usr/sbin/chown /usr/bin/chown)
SELF_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../../lib/common.sh
. "$SELF_DIR/../../lib/common.sh" || { echo "lib/common.sh not found — run this from the suite checkout" >&2; exit 1; }

# Every absolute binary path a generated script hardcodes must actually exist on
# THIS machine. Directories move between macOS releases and between arm64/x86_64
# layouts, and each call site redirects to /dev/null, so a stale path is an
# invisible no-op rather than an error. This catches that at install time.
audit_paths() {
    local f="$1" label="$2" bad=0 pth
    # Skip _bin() candidate lists: those deliberately name alternates for other
    # macOS layouts, so an absent one is expected, not a bug.
    for pth in $(/usr/bin/grep -v '_bin ' "$f" | /usr/bin/grep -oE '/(usr/(local/)?(s?bin)|s?bin)/[A-Za-z0-9_.-]+' | /usr/bin/sort -u); do
        case "$pth" in
            */sleepwatcher|/usr/local/bin/warp-cli|/usr/local/bin/warp-killswitch|/Library/PrivilegedHelperTools/warp-killswitch) continue ;;  # optional / installed by us
        esac
        [ -x "$pth" ] || { c_red "  MISSING binary referenced by $label: $pth"; bad=$((bad + 1)); }
    done
    if [ "$bad" -gt 0 ]; then
        c_red "  $label references $bad path(s) that do not exist here — fix before relying on it."
        return 1
    fi
    c_grn "  path audit clean: $label"
    return 0
}

# The helper runs as root (NOPASSWD sudoers rule + LaunchDaemons), so neither the file nor
# ANY directory above it may be writable by anyone but root: a user who can write the
# directory can replace the root-owned file and then run their own code as root.
# Until 4.1 the helper lived in /usr/local/bin whenever that directory was root-owned at
# install time. That is a judgement about a moment: an Intel Homebrew installed later (or
# migrated over from an older Mac) chowns /usr/local/bin to the user, and the NOPASSWD rule
# would then point into a user-writable directory. The 4.1 security audit (Claude Fable 5.1) moved the helper
# to Apple's purpose-built, always root-only /Library/PrivilegedHelperTools; /usr/local/bin
# only ever gets a convenience symlink that nothing privileged references.
HELPER_LINK=/usr/local/bin/warp-killswitch
HELPER=/Library/PrivilegedHelperTools/warp-killswitch
HELPER_SRC="$SELF_DIR/warp-killswitch"
# root_only_chain (lib/common.sh) is the test the helper directory must pass.
# Anything written into the menu owner's home is written AS that user. Root copying a file
# to a path the user controls follows a planted symlink (cp/mv/install dereference the
# destination) and would overwrite whatever it points at — a classic path to root.
as_user() { /usr/bin/sudo -n -u "$TARGET_USER" "$@"; }
SUDOERS=/etc/sudoers.d/warp-killswitch
WARP_PLIST=/Library/LaunchDaemons/com.cloudflare.1dot1dot1dot1.macos.warp.daemon.plist
STATE_DIR=/var/db/warp-killswitch
WATCHDOG_PLIST=/Library/LaunchDaemons/local.warp-killswitch.watchdog.plist
SLEEP_PLIST=/Library/LaunchDaemons/local.warp-killswitch.sleepwatcher.plist
PLUGIN_MARK='# security-toggle v3 (warp-killswitch)'

[ "$(id -u)" -eq 0 ] || die "run with sudo/root."

# ---- args -------------------------------------------------------------------
TARGET_USER="${SUDO_USER:-}"
[ -n "$TARGET_USER" ] || TARGET_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)"
UNINSTALL=0; DO_MENU=1; DO_WATCHDOG=1; DO_SLEEP=1
while [ $# -gt 0 ]; do
    case "$1" in
        --user)          TARGET_USER="${2:-}"; shift ;;
        --uninstall)     UNINSTALL=1 ;;
        --no-menu)       DO_MENU=0 ;;
        --no-watchdog)   DO_WATCHDOG=0 ;;
        --no-sleep-hook) DO_SLEEP=0 ;;
        -h|--help)       /usr/bin/sed -n '2,/^set -u/p' "$0" | /usr/bin/sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *)               die "unknown arg: $1" ;;
    esac
    shift
done
[ -n "$TARGET_USER" ] || die "cannot determine target user; pass --user NAME."
id "$TARGET_USER" >/dev/null 2>&1 || die "user '$TARGET_USER' does not exist."
USER_HOME=$(/usr/bin/dscl . -read /Users/"$TARGET_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
[ -n "$USER_HOME" ] || USER_HOME="/Users/$TARGET_USER"
[ -d "$USER_HOME" ] || die "cannot resolve home for $TARGET_USER."

# The menu plugin is maintained ONCE, in components/menubar/, and copied to both
# xbar locations (the active plugin and the ~/Documents/SwiftBar reference copy).
PLUGIN_SRC="$SELF_DIR/../menubar/security-toggle.5s.sh"
# The xbar plugin lives in two synced copies (active + source-of-truth backup).
PLUGIN_ACTIVE="$USER_HOME/Library/Application Support/xbar/plugins/security-toggle.5s.sh"
PLUGIN_SOURCE="$USER_HOME/Documents/SwiftBar/security-toggle.5s.sh"

SLEEPWATCHER=""
for c in /opt/homebrew/sbin/sleepwatcher /usr/local/sbin/sleepwatcher /opt/local/sbin/sleepwatcher /opt/homebrew/bin/sleepwatcher /usr/local/bin/sleepwatcher /opt/local/bin/sleepwatcher; do
    [ -x "$c" ] && { SLEEPWATCHER="$c"; break; }
done

# ---- uninstall --------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    c_ylw "Uninstalling warp-killswitch (rebuilding WARP first if killed)..."
    if [ -x "$HELPER" ] && [ "$("$HELPER" state 2>/dev/null)" = killed ]; then "$HELPER" up || true; fi
    for p in "$WATCHDOG_PLIST" "$SLEEP_PLIST" /Library/LaunchDaemons/local.warp-killswitch.do-*.plist; do
        [ -f "$p" ] || continue
        /bin/launchctl bootout system "$p" >/dev/null 2>&1
        $RM -f "$p"
    done
    $RM -f "$HELPER_LINK" "$HELPER" "$SUDOERS"
    BACKUP_DIR="$USER_HOME/Documents/SwiftBar/backups"
    for tag in active source; do
        [ "$tag" = active ] && p="$PLUGIN_ACTIVE" || p="$PLUGIN_SOURCE"
        for b in "$BACKUP_DIR/security-toggle.5s.sh.$tag.pre-killswitch.bak" "$p.pre-killswitch.bak"; do
            if [ -f "$b" ]; then as_user $CP -f "$b" "$p"; as_user /bin/chmod +x "$p"; as_user $RM -f "$p.pre-killswitch.bak"; c_grn "restored $p from $b"; break; fi
        done
    done
    c_grn "Removed helper, sudoers, watchdog and sleep LaunchDaemons."
    c_ylw "State/log left in $STATE_DIR and /var/log/warp-killswitch.log."
    c_ylw "Reload the menu: open -g 'xbar://app/refreshAllPlugins'"
    exit 0
fi

# ---- preflight (warn-only, never blocks) ------------------------------------
warn=0
need() { command -v "$1" >/dev/null 2>&1 || { c_ylw "  missing: $1  ($2)"; warn=1; }; }
c_ylw "Preflight:"
need warp-cli      "cloudflare-warp"
need launchctl     "launchd"
need pfctl         "pf firewall"
need networksetup  "macOS network config"
need scutil        "system configuration"
need nc            "link check"
need curl          "captive-portal probe"
[ -f "$WARP_PLIST" ] || { c_ylw "  missing: $WARP_PLIST (Cloudflare WARP daemon)"; warn=1; }
if [ "$DO_MENU" -eq 1 ] && [ ! -f "$PLUGIN_ACTIVE" ]; then c_ylw "  xbar plugin not found at $PLUGIN_ACTIVE (will still install helper)"; warn=1; fi
if [ "$DO_MENU" -eq 1 ] && [ ! -f "$PLUGIN_SRC" ]; then die "menu plugin source not found at $PLUGIN_SRC — run this from the suite checkout, or pass --no-menu"; fi
[ -f "$HELPER_SRC" ] || die "helper source not found at $HELPER_SRC — run this from the suite checkout"
if [ "$DO_SLEEP" -eq 1 ] && [ -z "$SLEEPWATCHER" ]; then
    c_ylw "  sleepwatcher not present — not needed: the watchdog detects wake natively (wall-clock gap)."
fi
if [ "$warn" -eq 0 ]; then c_grn "  all good"; else c_ylw "  (warnings above — continuing; helper degrades gracefully)"; fi

# ---- 1. root helper ---------------------------------------------------------
/usr/bin/install -d -m 0755 -o root -g wheel /Library/PrivilegedHelperTools
root_only_chain /Library/PrivilegedHelperTools || die "/Library/PrivilegedHelperTools is not root-only — refusing to install a NOPASSWD root helper there."
/usr/bin/install -d -m 0755 -o root -g wheel "$STATE_DIR"
# The helper is its own file (components/warp-killswitch/warp-killswitch) so it can be read,
# linted and reviewed on its own; it is installed verbatim, root-owned, 0755.
/bin/bash -n "$HELPER_SRC" || die "helper source failed syntax check."
/usr/bin/install -m 0755 -o root -g wheel "$HELPER_SRC" "$HELPER"
root_only_chain "$HELPER" || die "$HELPER did not end up root-only — refusing to write a NOPASSWD rule for it."
audit_paths "$HELPER" "warp-killswitch helper" || true
c_grn "installed $HELPER"
# CLI convenience only: sudoers and the LaunchDaemons name the real path, never this link.
# A pre-4.1 install left the helper itself here; replace it with the link.
if [ -d /usr/local/bin ]; then
    [ -f "$HELPER_LINK" ] && [ ! -L "$HELPER_LINK" ] && c_ylw "  replaced the pre-4.1 helper copy at $HELPER_LINK with a link"
    $RM -f "$HELPER_LINK"; /bin/ln -s "$HELPER" "$HELPER_LINK"
fi

# ---- 2. sudoers -------------------------------------------------------------
# Pinned to the exact invocations the menu makes. Anything else (watchdog, purge,
# sleep hooks, free arguments) still needs a password. The helper's own command
# parser is the second line of defence; this rule is the first.
TMP_SUDO=$(/usr/bin/mktemp)
{
    echo '# macOS-SecureNetwork-Suite — WARP kill-switch menu helper (components/warp-killswitch/install.sh).'
    echo '# Only the exact argument lists the menu uses are passwordless; regenerated on every install.'
    printf '%s ALL=(root) NOPASSWD: %s down, %s down --keep-dns, %s up, %s heal manual, %s status, %s state, %s verify\n' \
        "$TARGET_USER" "$HELPER" "$HELPER" "$HELPER" "$HELPER" "$HELPER" "$HELPER" "$HELPER"
} > "$TMP_SUDO"
/usr/sbin/visudo -cf "$TMP_SUDO" >/dev/null || { $RM -f "$TMP_SUDO"; die "generated sudoers is invalid."; }
/usr/bin/install -m 0440 -o root -g wheel "$TMP_SUDO" "$SUDOERS"
$RM -f "$TMP_SUDO"
c_grn "installed $SUDOERS  ($TARGET_USER NOPASSWD: down | down --keep-dns | up | heal manual | status | state | verify)"

# ---- 3. watchdog LaunchDaemon -----------------------------------------------
if [ "$DO_WATCHDOG" -eq 1 ]; then
    /bin/launchctl bootout system "$WATCHDOG_PLIST" >/dev/null 2>&1
    $CAT > "$WATCHDOG_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.warp-killswitch.watchdog</string>
    <key>ProgramArguments</key><array><string>$HELPER</string><string>watchdog</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>Nice</key><integer>5</integer>
    <key>StandardOutPath</key><string>/var/log/warp-watchdog.log</string>
    <key>StandardErrorPath</key><string>/var/log/warp-watchdog.log</string>
</dict>
</plist>
EOF
    "$CHOWN" root:wheel "$WATCHDOG_PLIST"; /bin/chmod 0644 "$WATCHDOG_PLIST"
    /usr/bin/plutil -lint "$WATCHDOG_PLIST" >/dev/null || die "watchdog plist invalid"
    if /bin/launchctl bootstrap system "$WATCHDOG_PLIST" >/dev/null 2>&1; then
        c_grn "installed + started local.warp-killswitch.watchdog"
    else
        c_red "watchdog LaunchDaemon failed to bootstrap — check: sudo launchctl print system/local.warp-killswitch.watchdog"
    fi
else
    /bin/launchctl bootout system "$WATCHDOG_PLIST" >/dev/null 2>&1; $RM -f "$WATCHDOG_PLIST"
    c_ylw "watchdog skipped (--no-watchdog)"
fi

# ---- 3b. on-demand LaunchDaemons: clean re-dispatch of down/up/heal ---------
# launchd spawns these Apple-rooted, so a menu/terminal call that is subject to
# the macOS 27 enumeration blank gets a full view. RunAtLoad=false; started
# with `launchctl kickstart` by the helper itself.
for action in down up heal; do
    DP="/Library/LaunchDaemons/local.warp-killswitch.do-$action.plist"
    /bin/launchctl bootout system "$DP" >/dev/null 2>&1
    $CAT > "$DP" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.warp-killswitch.do-$action</string>
    <key>ProgramArguments</key><array><string>$HELPER</string><string>$action</string>$([ "$action" = heal ] && echo "<string>menu</string>")</array>
    <key>EnvironmentVariables</key><dict><key>WK_DISPATCHED</key><string>1</string></dict>
    <key>RunAtLoad</key><false/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>/var/log/warp-killswitch-dispatch.log</string>
    <key>StandardErrorPath</key><string>/var/log/warp-killswitch-dispatch.log</string>
</dict>
</plist>
EOF
    "$CHOWN" root:wheel "$DP"; /bin/chmod 0644 "$DP"
    /usr/bin/plutil -lint "$DP" >/dev/null || die "plist invalid: $DP"
    /bin/launchctl bootstrap system "$DP" >/dev/null 2>&1 || c_ylw "  could not bootstrap $(basename "$DP")"
done
c_grn "installed local.warp-killswitch.do-{down,up,heal} (launchd re-dispatch targets)"

# ---- 4. sleep/wake hook (sleepwatcher) --------------------------------------
if [ "$DO_SLEEP" -eq 1 ] && [ -n "$SLEEPWATCHER" ]; then
    /bin/launchctl bootout system "$SLEEP_PLIST" >/dev/null 2>&1
    $CAT > "$SLEEP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.warp-killswitch.sleepwatcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SLEEPWATCHER</string>
        <string>-V</string>
        <string>-s</string><string>$HELPER sleep-pre</string>
        <string>-w</string><string>$HELPER sleep-post</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
    "$CHOWN" root:wheel "$SLEEP_PLIST"; /bin/chmod 0644 "$SLEEP_PLIST"
    /usr/bin/plutil -lint "$SLEEP_PLIST" >/dev/null || die "sleepwatcher plist invalid"
    /bin/launchctl bootstrap system "$SLEEP_PLIST" >/dev/null 2>&1 && c_grn "installed + started local.warp-killswitch.sleepwatcher ($SLEEPWATCHER)" \
        || c_red "sleepwatcher LaunchDaemon failed to bootstrap"
elif [ "$DO_SLEEP" -eq 1 ]; then
    c_ylw "sleepwatcher hook not installed (absent, and not required) — the watchdog handles wake natively."
else
    /bin/launchctl bootout system "$SLEEP_PLIST" >/dev/null 2>&1; $RM -f "$SLEEP_PLIST"; c_ylw "sleep hook skipped (--no-sleep-hook)"
fi

# ---- 5. xbar menu plugin (both copies) --------------------------------------
# Backups live OUTSIDE the xbar plugin folder: xbar executes every executable
# file in it, so a `*.bak` left there loads as a second icon set.
BACKUP_DIR="$USER_HOME/Documents/SwiftBar/backups"
# Every write below runs as the menu owner (as_user): these paths are theirs, and root
# must never dereference a destination the user controls.
write_plugin() {
    local dest="$1" tag="$2" bak
    [ -n "$dest" ] || return 0
    as_user /bin/mkdir -p "$(dirname "$dest")" "$BACKUP_DIR"
    bak="$BACKUP_DIR/security-toggle.5s.sh.$tag.pre-killswitch.bak"
    if [ -f "$dest.pre-killswitch.bak" ]; then          # legacy v1 backup sitting in the plugin dir
        as_user $MV -f "$dest.pre-killswitch.bak" "$bak"; as_user /bin/chmod -x "$bak"
        c_ylw "moved legacy backup out of the plugin folder -> $bak"
    fi
    if [ -f "$dest" ] && ! $GREP -qF "$PLUGIN_MARK" "$dest" && [ ! -f "$bak" ]; then
        as_user $CP -a "$dest" "$bak"; as_user /bin/chmod -x "$bak"
        c_ylw "backed up $dest -> $bak"
    fi
    # The plugin names the helper by its fixed /Library/PrivilegedHelperTools path.
    as_user $CP -f "$PLUGIN_SRC" "$dest" || die "could not write $dest as $TARGET_USER"
    as_user /bin/chmod 0755 "$dest"
    /bin/bash -n "$dest" || die "plugin $dest failed syntax check."
    audit_paths "$dest" "xbar plugin ($tag)" || true
    c_grn "installed $dest"
}
if [ "$DO_MENU" -eq 1 ]; then
    { [ -e "$PLUGIN_ACTIVE" ] || [ -d "$(dirname "$PLUGIN_ACTIVE")" ]; } && write_plugin "$PLUGIN_ACTIVE" active
    { [ -e "$PLUGIN_SOURCE" ] || [ -d "$(dirname "$PLUGIN_SOURCE")" ]; } && write_plugin "$PLUGIN_SOURCE" source
    as_user /usr/bin/open -g 'xbar://app/refreshAllPlugins' >/dev/null 2>&1 || true
else
    c_ylw "menu skipped (--no-menu)"
fi

# ---- 6. self-test -----------------------------------------------------------
echo
"$HELPER" status
echo
c_grn "=== warp-killswitch v3 (macOS) installed for $TARGET_USER ==="
echo "Menu:  WARP section -> Tear Down / Rebuild / Heal now / Status"
echo "CLI:   sudo warp-killswitch {down|up|heal|status|verify|state}   (link in /usr/local/bin; asks for your password)"
echo "Logs:  /var/log/warp-killswitch.log   /var/log/warp-watchdog.log"
