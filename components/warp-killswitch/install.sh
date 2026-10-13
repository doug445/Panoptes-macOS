#!/bin/bash
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# warp-killswitch-macos install.sh — installer for the Cloudflare WARP
# kill-switch, self-healer and watchdog on macOS. Part of macOS-SecureNetwork-Suite;
# the suite's top-level install.sh runs this for you. The root helper is embedded
# below; the xbar menu is copied from ../menubar/security-toggle.5s.sh.
#
# WHAT IT INSTALLS (all idempotent; re-run to update)
#   /usr/local/bin/warp-killswitch                      root helper
#                                                       (down/up/heal/watchdog/purge/status/...)
#   /etc/sudoers.d/warp-killswitch                      NOPASSWD for that helper (menu owner)
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
            */sleepwatcher|/usr/local/bin/warp-cli|/usr/local/bin/warp-killswitch) continue ;;  # optional / installed by us
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

HELPER=/usr/local/bin/warp-killswitch
SUDOERS=/etc/sudoers.d/warp-killswitch
WARP_PLIST=/Library/LaunchDaemons/com.cloudflare.1dot1dot1dot1.macos.warp.daemon.plist
STATE_DIR=/var/db/warp-killswitch
WATCHDOG_PLIST=/Library/LaunchDaemons/local.warp-killswitch.watchdog.plist
SLEEP_PLIST=/Library/LaunchDaemons/local.warp-killswitch.sleepwatcher.plist
PLUGIN_MARK='# security-toggle v3 (warp-killswitch)'

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
die()   { c_red "ERROR: $*"; exit 1; }

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
PLUGIN_SRC="$(cd "$(dirname "$0")" && pwd -P)/../menubar/security-toggle.5s.sh"
# The xbar plugin lives in two synced copies (active + source-of-truth backup).
PLUGIN_ACTIVE="$USER_HOME/Library/Application Support/xbar/plugins/security-toggle.5s.sh"
PLUGIN_SOURCE="$USER_HOME/Documents/SwiftBar/security-toggle.5s.sh"

SLEEPWATCHER=""
for c in /opt/homebrew/sbin/sleepwatcher /usr/local/sbin/sleepwatcher /opt/homebrew/bin/sleepwatcher /usr/local/bin/sleepwatcher; do
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
    $RM -f "$HELPER" "$SUDOERS"
    BACKUP_DIR="$USER_HOME/Documents/SwiftBar/backups"
    for tag in active source; do
        [ "$tag" = active ] && p="$PLUGIN_ACTIVE" || p="$PLUGIN_SOURCE"
        for b in "$BACKUP_DIR/security-toggle.5s.sh.$tag.pre-killswitch.bak" "$p.pre-killswitch.bak"; do
            if [ -f "$b" ]; then $CP -f "$b" "$p"; /bin/chmod +x "$p"; $RM -f "$p.pre-killswitch.bak"; c_grn "restored $p from $b"; break; fi
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
if [ "$DO_SLEEP" -eq 1 ] && [ -z "$SLEEPWATCHER" ]; then
    c_ylw "  sleepwatcher not present — not needed: the watchdog detects wake natively (wall-clock gap)."
fi
if [ "$warn" -eq 0 ]; then c_grn "  all good"; else c_ylw "  (warnings above — continuing; helper degrades gracefully)"; fi

# ---- 1. root helper ---------------------------------------------------------
/usr/bin/install -d -m 0755 /usr/local/bin
/usr/bin/install -d -m 0755 "$STATE_DIR"
$CAT > "$HELPER" <<'HELPER_EOF'
#!/bin/bash
# warp-killswitch v3 (macOS) — Cloudflare WARP kill-switch, self-healer, watchdog.
#
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# macOS port of the warp-killswitch from Panoptes (https://github.com/doug445/Panoptes)
#
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Installed by warp-killswitch-macos install.sh. Root only. Stock bash 3.2.
#
#   down [--keep-dns] [--fast]
#          Tear WARP and its whole stack down: STOP + DISABLE the KeepAlive
#          daemon (survives reboot), flush its pf anchor(s), delete every route
#          on its utun (v4 AND v6), remove its SCDynamicStore service, drop DNS
#          to DHCP on every network service so captive portals can intercept
#          (--keep-dns leaves DNS alone), then PROVE plain internet works,
#          escalating until it does.
#   up     Restore DNS verbatim, re-enable + start the daemon, connect, and WAIT
#          for a verified working tunnel; roll back to a clean disconnected
#          state instead of leaving the lockdown firewall up.
#   heal   One-shot smart repair (what the watchdog runs). Safe any time.
#   watchdog   Run forever (LaunchDaemon): heal when the link is up but the
#          internet is dead for ~45 s, with back-off. Never acts while killed.
#   purge  Remove leftover WARP artifacts only (no DNS/daemon changes).
#   status One-screen health readout.   verify  online|offline (exit 0|1).
#   state  killed|armed.                sleep-pre / sleep-post  (sleepwatcher)
#
# Touches ONLY WARP's own artifacts (daemon, pf anchor, utun routes, SC keys)
# plus the manual DNS on the network services. ProtonVPN / the application
# firewall are never touched. Every warp-cli call is time-bounded.
set -u
export LC_ALL=C
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
CAT=/bin/cat; MV=/bin/mv; RM=/bin/rm; GREP=/usr/bin/grep

# Some binaries sit in a different directory depending on the macOS release
# (netstat is /usr/sbin on 26/Tahoe; older notes and Linux habits say /usr/bin).
# Probe absolute candidates and keep an absolute path -- never fall back to PATH
# lookup, which interactive rc files shadow. A wrong path plus 2>/dev/null is an
# invisible no-op, which is exactly how the v3 route purge silently did nothing.
_bin() { local c; for c in "$@"; do [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done; printf '%s' "$1"; }
NETSTAT=$(_bin /usr/sbin/netstat /usr/bin/netstat)

LABEL="com.cloudflare.1dot1dot1dot1.macos.warp.daemon"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
WARP_CLI="/usr/local/bin/warp-cli"; [ -x "$WARP_CLI" ] || WARP_CLI="$(command -v warp-cli || echo /usr/local/bin/warp-cli)"
PF_ANCHOR="com.cloudflare.warp_svc"
WARP_V4="172.16.0.2"            # tunnel-only mode always assigns this to the utun
STATE_DIR="/var/db/warp-killswitch"
MARKER="$STATE_DIR/killed"
LOCK_DIR="$STATE_DIR/lock.d"
RESUME_MARK="$STATE_DIR/reconnect-after-wake"
LOG="/var/log/warp-killswitch.log"
CURL=/usr/bin/curl

/usr/bin/install -d -m 0755 "$STATE_DIR" 2>/dev/null
if [ -f "$LOG" ] && [ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 2000000 ]; then $MV -f "$LOG" "$LOG.1"; fi

TAG=${TAG:-warp-killswitch}
log() {
    local msg
    msg="[$(/bin/date '+%F %T')] $TAG: $*"
    printf '%s\n' "$msg"
    printf '%s\n' "$msg" >> "$LOG" 2>/dev/null
}

# macOS has no coreutils `timeout`, and Apple keeps deprecating the bundled
# scripting runtimes, so this is plain bash 3.2: background the command, poll
# every 0.1 s, SIGKILL on expiry. Exit 124 on timeout, else the command's status.
tmo() {
    local s="$1" pid i=0 limit; shift
    limit=$(( s * 10 ))
    "$@" & pid=$!
    while /bin/kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$limit" ]; then
            /bin/kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
        fi
        /bin/sleep 0.1; i=$((i + 1))
    done
    wait "$pid"
}
WARP() { tmo 8 "$WARP_CLI" --accept-tos "$@"; }

# Desktop notification to the console user (we run as root).
notify() {
    local title="$1" body="$2" user uid
    user=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null); [ -n "$user" ] || return 0
    uid=$(/usr/bin/id -u "$user" 2>/dev/null); [ -n "$uid" ] && [ "$uid" -ge 500 ] || return 0
    body=${body//\"/\'}; title=${title//\"/\'}
    /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$user" /usr/bin/osascript \
        -e "display notification \"$body\" with title \"$title\"" >/dev/null 2>&1 &
    return 0
}

is_killed() { [ -f "$MARKER" ]; }

# strip ANSI (the CLI colours its output; BSD sed has no \x1b)
strip_ansi() { /usr/bin/sed "s/$(printf '\033')\[[0-9;]*m//g"; }
warp_status() {
    local s
    s=$(WARP status 2>/dev/null | strip_ansi | /usr/bin/sed -n 's/^Status update: *//p' | /usr/bin/head -1)
    echo "${s:-unreachable}"
}
daemon_alive() { /bin/launchctl print "system/$LABEL" 2>/dev/null | $GREP -q 'state = running'; }

# ---------------------------------------------------------------- discovery --
discover_utun() {   # the utun carrying WARP's tunnel address
    /sbin/ifconfig 2>/dev/null | /usr/bin/awk '/^utun[0-9]+:/{u=$1; sub(":","",u)} $1=="inet" && $2=="'"$WARP_V4"'"{print u; exit}'
}
pf_rules_present() {
    [ -n "$(/sbin/pfctl -a "$PF_ANCHOR" -sr 2>/dev/null)" ] && return 0
    local a
    for a in $(/sbin/pfctl -a "$PF_ANCHOR" -s Anchors 2>/dev/null); do
        [ -n "$(/sbin/pfctl -a "$a" -sr 2>/dev/null)" ] && return 0
    done
    return 1
}
sc_present() { printf 'list State:/Network/Service/CloudflareWARP\n' | /usr/sbin/scutil 2>/dev/null | $GREP -q 'subKey'; }
utun_routes() {   # utun_routes UTUN -> "family dest" lines
    local u="$1"
    [ -n "$u" ] || return 0
    "$NETSTAT" -rn -f inet  2>/dev/null | /usr/bin/awk -v i="$u" 'NF>=2 && ($NF==i || $(NF-1)==i) {print "inet " $1}'
    "$NETSTAT" -rn -f inet6 2>/dev/null | /usr/bin/awk -v i="$u" 'NF>=2 && ($NF==i || $(NF-1)==i) {print "inet6 " $1}'
}
artifacts_present() {
    pf_rules_present && return 0
    [ -n "$(discover_utun)" ] && return 0
    sc_present && return 0
    return 1
}
artifacts_desc() {
    local u n
    u=$(discover_utun)
    n=0; [ -n "$u" ] && n=$(utun_routes "$u" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    echo "pf=$(pf_rules_present && echo yes || echo no) utun=${u:-absent} routes=$n sc=$(sc_present && echo yes || echo no) daemon=$(daemon_alive && echo running || echo stopped)"
}

# ------------------------------------------------------------------- purge --
purge_pf() {
    local a
    for a in $(/sbin/pfctl -a "$PF_ANCHOR" -s Anchors 2>/dev/null); do /sbin/pfctl -a "$a" -F all >/dev/null 2>&1; done
    /sbin/pfctl -a "$PF_ANCHOR" -F all >/dev/null 2>&1
    return 0
}
purge_routes() {   # purge_routes UTUN
    local u="$1" fam dest cidr
    [ -n "$u" ] || return 0
    utun_routes "$u" | while read -r fam dest; do
        [ -n "$dest" ] || continue
        case "$dest" in
            default) /sbin/route -n delete -"$fam" default -interface "$u" >/dev/null 2>&1 ;;
            */*)     /sbin/route -n delete -"$fam" -net  "$dest" -interface "$u" >/dev/null 2>&1 ;;
            *:*)     /sbin/route -n delete -"$fam" -host "$dest" -interface "$u" >/dev/null 2>&1 ;;
            *.*.*.*) /sbin/route -n delete -"$fam" -host "$dest" -interface "$u" >/dev/null 2>&1 ;;
            *)       # netstat abbreviates classful networks: "1" is 1.0.0.0/8,
                     # "162.158" is 162.158.0.0/16. -host would mis-parse those
                     # (inet_aton reads "1" as 0.0.0.1), so rebuild the CIDR.
                     cidr=$(printf '%s' "$dest" | /usr/bin/awk -F. '{p=$0; b=NF*8; for(i=NF;i<4;i++) p=p".0"; print p"/"b}')
                     /sbin/route -n delete -"$fam" -net "$cidr" -interface "$u" >/dev/null 2>&1 ;;
        esac
    done
    /sbin/route -n delete -inet "$WARP_V4" >/dev/null 2>&1
    return 0
}
purge_sc() {
    /usr/sbin/scutil >/dev/null 2>&1 <<'SC'
remove State:/Network/Service/CloudflareWARP/DNS
remove State:/Network/Service/CloudflareWARP/IPv4
remove State:/Network/Service/CloudflareWARP/IPv6
remove State:/Network/Service/CloudflareWARP
SC
    return 0
}
# Remove everything WARP leaves in the kernel. The utun itself disappears when
# the daemon's fd closes; while the daemon is dead nothing recreates it.
purge_artifacts() {
    local u
    for _ in 1 2 3; do
        u=$(discover_utun)
        purge_pf
        purge_routes "$u"
        purge_sc
        artifacts_present || break
        /bin/sleep 1
    done
    ! artifacts_present
}

stop_daemon() {
    # bootout stops it now; disable writes a launchd override so RunAtLoad
    # cannot bring it back at boot (= systemctl stop + disable).
    /bin/launchctl kill CONT "system/$LABEL" >/dev/null 2>&1     # a frozen daemon never sees SIGTERM
    if ! tmo 15 /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1; then
        log "  ! bootout did not finish in 15s — SIGKILL"
        /bin/launchctl kill KILL "system/$LABEL" >/dev/null 2>&1
        /bin/sleep 1
    fi
    /bin/launchctl disable "system/$LABEL" >/dev/null 2>&1
    /usr/bin/pkill -9 -f "Cloudflare WARP.app/Contents/Resources/CloudflareWARP" >/dev/null 2>&1
    return 0
}

# ------------------------------------------------------------------ probes --
# Physical link: default-route interface is up and the gateway answers ARP.
# Never rely on gateway ping — many APs drop ICMP to the gateway.
LINK_DEV=""; LINK_GW=""; LINK_HOW=""
link_ok() {
    local out
    out=$(/sbin/route -n get default 2>/dev/null)
    LINK_DEV=$(printf '%s\n' "$out" | /usr/bin/awk '/interface:/{print $2; exit}')
    LINK_GW=$(printf '%s\n' "$out" | /usr/bin/awk '/gateway:/{print $2; exit}')
    [ -n "$LINK_DEV" ] || return 1
    case "$LINK_DEV" in
        utun*) : ;;   # tunnel is default: judge by the gateway below
        *) /sbin/ifconfig "$LINK_DEV" 2>/dev/null | $GREP -q 'status: active' || return 1 ;;
    esac
    [ -n "$LINK_GW" ] || return 0
    case "$LINK_GW" in *.*.*.*) ;; *) return 0 ;; esac
    /usr/bin/nc -z -G 1 "$LINK_GW" 80 >/dev/null 2>&1      # any packet forces ARP resolution
    local a
    a=$(/usr/sbin/arp -n "$LINK_GW" 2>/dev/null)
    case "$a" in
        *" at "*)      LINK_HOW=arp; case "$a" in *incomplete*) return 1 ;; esac; return 0 ;;
        *"no entry"*)  LINK_HOW=arp; [ -n "$(/usr/sbin/arp -an 2>/dev/null)" ] && return 1 ;;   # table readable, gw absent
    esac
    # ARP table came back EMPTY: the macOS 27 enumeration blank (we were forked
    # from a non-Apple binary — xbar, Homebrew bash, iTerm). Networking itself
    # still works. Use the netwatch ARP cache if it is fresh, else judge by
    # interface state — never let this read as "link down".
    local user cache age
    user=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
    cache="/Users/${user:-nobody}/.local/share/netwatch/arp.cache"
    if [ -s "$cache" ]; then
        age=$(( $(/bin/date +%s) - $(/usr/bin/stat -f%m "$cache" 2>/dev/null || echo 0) ))
        if [ "$age" -le 120 ]; then
            LINK_HOW=arpcache
            $GREP -q "($LINK_GW) at " "$cache" && return 0
            return 1
        fi
    fi
    LINK_HOW="ifstate(arp-blank)"
    return 0
}

# Raw-IP reachability, no DNS. Parallel pings then TCP 443 by address.
online_now() {
    local ip pids="" p ok=1
    for ip in 1.1.1.1 8.8.8.8 9.9.9.9; do
        /sbin/ping -c 1 -t 2 -n "$ip" >/dev/null 2>&1 & pids="$pids $!"
    done
    for p in $pids; do wait "$p" && ok=0; done
    [ "$ok" -eq 0 ] && return 0
    /usr/bin/nc -z -G 4 1.1.1.1 443 >/dev/null 2>&1 && return 0
    /usr/bin/nc -z -G 4 8.8.8.8 443 >/dev/null 2>&1 && return 0
    return 1
}
internet_or_portal() {
    online_now && return 0
    local code
    code=$($CURL -s -m 6 -o /dev/null -w '%{http_code}' http://detectportal.firefox.com/success.txt 2>/dev/null)
    case "$code" in 200|30[0-8]) return 0 ;; esac
    return 1
}
portal_detected() {
    local out code body
    out=$($CURL -s -m 6 -w '\n%{http_code}' http://detectportal.firefox.com/success.txt 2>/dev/null)
    code=${out##*$'\n'}; body=$(printf '%s' "${out%$'\n'*}" | /usr/bin/tr -d '[:space:]')
    case "$code" in
        200) [ "$body" = success ] && return 1 || return 0 ;;
        30[0-8]) return 0 ;;
    esac
    code=$($CURL -s -m 6 -o /dev/null -w '%{http_code}' http://connectivitycheck.gstatic.com/generate_204 2>/dev/null)
    [ "$code" = 204 ] && return 1
    [ -n "$code" ] && [ "$code" != 000 ] && return 0
    return 1
}
dns_ok() { tmo 8 /usr/bin/dscacheutil -q host -a name cloudflare.com 2>/dev/null | $GREP -q 'ip_address'; }
flush_dns_cache() {
    /usr/bin/dscacheutil -flushcache >/dev/null 2>&1
    /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1
}
egress_line() {
    tmo 10 $CURL -s -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | $GREP -E '^(warp|colo)=' | /usr/bin/tr '\n' ' '
}
wait_connected() {   # wait_connected SECONDS — Connected AND raw internet works
    local deadline=$(( $(/bin/date +%s) + $1 ))
    while [ "$(/bin/date +%s)" -lt "$deadline" ]; do
        [ "$(warp_status)" = Connected ] && online_now && return 0
        /bin/sleep 2
    done
    return 1
}

# --------------------------------------------------------------------- DNS --
services() { /usr/sbin/networksetup -listallnetworkservices 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/sed 's/^\*//'; }
svc_keyfile() { printf '%s/dns_%s.bak' "$STATE_DIR" "$(printf '%s' "$1" | /usr/bin/tr ' /' '__')"; }
save_dns() {   # back up every service's manual DNS once, then drop to DHCP
    local svc f cur
    services | while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        f="$(svc_keyfile "$svc")"
        [ -f "$f" ] && continue
        cur=$(/usr/sbin/networksetup -getdnsservers "$svc" 2>/dev/null)
        if printf '%s' "$cur" | $GREP -qi "aren't any"; then printf 'empty\n' > "$f"; else printf '%s\n' "$cur" > "$f"; fi
        /usr/sbin/networksetup -setdnsservers "$svc" empty >/dev/null 2>&1
    done
    : > "$STATE_DIR/dns-swapped"
}
restore_dns() {
    local svc f
    [ -f "$STATE_DIR/dns-swapped" ] || return 0
    services | while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        f="$(svc_keyfile "$svc")"
        [ -f "$f" ] || continue
        if $GREP -qi '^empty$' "$f"; then
            /usr/sbin/networksetup -setdnsservers "$svc" empty >/dev/null 2>&1
        else
            # shellcheck disable=SC2046
            /usr/sbin/networksetup -setdnsservers "$svc" $($CAT "$f") >/dev/null 2>&1
        fi
        $RM -f "$f"
    done
    $RM -f "$STATE_DIR/dns-swapped" "$STATE_DIR"/dns_*.bak
    log "  DNS restored from backup"
}

# -------------------------------------------------------------- escalation --
escalate() {
    log "  ! still offline — escalating"
    local u
    u=$(discover_utun)
    purge_pf; purge_routes "$u"; purge_sc
    internet_or_portal && { log "  + recovered: re-flushed WARP leftovers"; return 0; }
    flush_dns_cache
    if [ -n "${LINK_DEV:-}" ] || link_ok; then
        local svc
        svc=$(/usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | $GREP -B1 "Device: $LINK_DEV)" | /usr/bin/head -1 | /usr/bin/sed 's/^([0-9]*) //')
        if [ -n "$svc" ]; then
            log "  bouncing network service '$svc' ($LINK_DEV)"
            /usr/sbin/networksetup -setnetworkserviceenabled "$svc" off >/dev/null 2>&1; /bin/sleep 2
            /usr/sbin/networksetup -setnetworkserviceenabled "$svc" on  >/dev/null 2>&1
            for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
                /bin/sleep 2
                internet_or_portal && { log "  + recovered: network bounce"; return 0; }
            done
        fi
    fi
    return 1
}

# ---------------------------------------------------------------- commands --
warp_down() {
    local keep_dns=0 fast=0 a u
    for a in "$@"; do case "$a" in --keep-dns) keep_dns=1 ;; --fast) fast=1 ;; esac; done
    log "TEARDOWN begin (keep_dns=$keep_dns) status=$(warp_status) $(artifacts_desc)"
    u=$(discover_utun)                                   # discover FIRST
    [ "$fast" -eq 0 ] && WARP disconnect >/dev/null 2>&1
    stop_daemon
    log "  daemon booted out + disabled"
    if purge_artifacts; then log "  artifacts purged: clean"; else log "  ! artifacts remain: $(artifacts_desc)"; fi
    [ -n "$u" ] && purge_routes "$u"
    : > "$MARKER"
    if [ "$keep_dns" -eq 0 ]; then save_dns; log "  DNS -> DHCP on every service (captive-portal friendly)"; else log "  DNS left as configured"; fi
    flush_dns_cache
    for _ in 1 2 3 4 5; do
        if internet_or_portal; then
            log "  = ONLINE (plain internet)"
            notify "WARP torn down" "Plain internet is working.$([ "$keep_dns" -eq 0 ] && echo ' DNS is DHCP until you Rebuild.')"
            return 0
        fi
        /bin/sleep 2
    done
    if escalate; then log "  = ONLINE (after escalation)"; notify "WARP torn down" "Internet recovered after escalation."; return 0; fi
    log "  = STILL OFFLINE — link/upstream problem, not WARP"
    notify "WARP torn down - still offline" "WARP is gone but there is still no internet. Check Wi-Fi, the AP or the ISP."
    return 1
}

warp_up() {
    log "REBUILD begin status=$(warp_status)"
    restore_dns
    $RM -f "$MARKER"
    /bin/launchctl enable "system/$LABEL" >/dev/null 2>&1
    /bin/launchctl bootstrap system "$PLIST" >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        tmo 5 "$WARP_CLI" --accept-tos status >/dev/null 2>&1 && break
        /bin/sleep 1
    done
    WARP connect >/dev/null 2>&1
    if wait_connected 35; then
        flush_dns_cache
        log "  = CONNECTED, tunnel verified: $(egress_line)"
        notify "WARP rebuilt" "Tunnel up, DNS restored."
        return 0
    fi
    log "  ! no working tunnel after 35s (status=$(warp_status)) — rolling back to a clean disconnected state"
    WARP disconnect >/dev/null 2>&1; /bin/sleep 2
    artifacts_present && purge_artifacts
    flush_dns_cache
    if internet_or_portal; then notify "WARP could not connect" "Left disconnected; plain internet works. Retry from the menu."
    else notify "WARP could not connect" "And plain internet is down too - check the link."; fi
    return 1
}

# Exit codes: 0 healthy/repaired, 2 not-WARP (upstream), 3 captive portal, 4 WARP left off.
heal() {
    local why="${1:-manual}" st rc
    TAG="warp-killswitch[heal:$why]"
    if is_killed; then log "killed by user — nothing to do"; return 0; fi
    if ! link_ok; then log "link layer down (dev=${LINK_DEV:-none} gw=${LINK_GW:-none}) — not a WARP problem"; return 2; fi
    st=$(warp_status)
    if online_now; then
        if ! daemon_alive && artifacts_present; then
            log "online, but the daemon is dead and left artifacts ($(artifacts_desc)) — purging"
            purge_artifacts && log "stale artifacts purged"
        fi
        if ! dns_ok; then log "IP works but DNS fails — flushing caches"; flush_dns_cache; fi
        return 0
    fi
    if ! artifacts_present; then
        log "offline, link up, NO WARP artifacts (status=$st) — upstream/ISP problem, not WARP"; return 2
    fi
    if ! daemon_alive; then
        log "offline, daemon DEAD, artifacts remain ($(artifacts_desc)) — purging"
        purge_artifacts; flush_dns_cache
        if internet_or_portal; then log "recovered: stale artifacts purged"; notify "WARP cleaned up" "The daemon had died and left its firewall behind. Removed; internet is back."; return 0; fi
        return 2
    fi
    log "offline, link up, WARP status=$st with artifacts ($(artifacts_desc)) — soft reset"
    WARP disconnect >/dev/null 2>&1
    /bin/sleep 3
    if artifacts_present; then
        log "disconnect did NOT clear WARP's artifacts ($(artifacts_desc)) — daemon wedged; hard teardown"
        warp_down --keep-dns --fast; rc=$?
        [ "$rc" -eq 0 ] && notify "WARP was blackholing - torn down" "The daemon was wedged. WARP is OFF (survives reboot). Rebuild from the menu when you want it back."
        return $rc
    fi
    if ! internet_or_portal; then
        log "WARP removed cleanly but still offline — not WARP; reconnecting, backing off"
        WARP connect >/dev/null 2>&1; return 2
    fi
    if portal_detected; then
        log "plain internet works and a CAPTIVE PORTAL is intercepting — leaving WARP off"
        flush_dns_cache
        notify "Captive portal detected" "WARP left disconnected so you can log in. Reconnect from the menu afterwards."
        return 3
    fi
    log "plain internet works — retrying WARP connect once"
    WARP connect >/dev/null 2>&1
    if wait_connected 30; then flush_dns_cache; log "recovered: soft reset ($(egress_line))"; notify "WARP recovered" "The tunnel was dead and has been reset."; return 0; fi
    log "reconnect failed (status=$(warp_status)) — leaving WARP disconnected"
    WARP disconnect >/dev/null 2>&1; /bin/sleep 2
    artifacts_present && purge_artifacts
    flush_dns_cache
    notify "WARP could not reconnect - left OFF" "Plain internet works. Reconnect from the menu later."
    return 4
}

# Reconnect after the machine wakes. Called by the watchdog's own wake detection,
# so no third-party sleep hook (and no package manager) is required.
wake_reconnect() {
    local st
    st=$(warp_status)
    if [ "$st" = Connected ] && online_now; then log "  wake: tunnel already healthy"; return 0; fi
    log "  wake: reconnecting WARP (status=$st)"
    WARP connect >/dev/null 2>&1
    if wait_connected 30; then flush_dns_cache; log "  wake: tunnel verified up"; return 0; fi
    log "  wake: reconnect did not settle — leaving it to the normal heal path"
    return 1
}

watchdog() {
    local interval=10 need=3 fails=0 dfails=0 backoff_until=0 now rc backoff
    # A wall-clock jump far larger than our own interval means the machine was
    # asleep: that is native wake detection with no dependencies. The threshold is
    # well clear of a slow iteration (a wedged daemon can stretch one to ~40 s).
    local last_tick wake_gap=120
    last_tick=$(/bin/date +%s)
    TAG="warp-watchdog"
    log "started (interval=${interval}s, act after $need consecutive failures, wake gap ${wake_gap}s)"
    while :; do
        /bin/sleep "$interval"
        now=$(/bin/date +%s)
        if [ $(( now - last_tick )) -gt "$wake_gap" ]; then
            log "wall-clock jumped $(( now - last_tick ))s — machine woke from sleep"
            is_killed || wake_reconnect
            now=$(/bin/date +%s)
        fi
        last_tick=$now
        if is_killed; then fails=0; dfails=0; continue; fi
        if online_now; then
            fails=0
            if ! daemon_alive && artifacts_present; then
                log "daemon dead with leftovers ($(artifacts_desc)) — purging"
                "$0" purge >/dev/null 2>&1
            fi
            if dns_ok; then dfails=0; else
                dfails=$((dfails + 1))
                if [ "$dfails" -ge "$need" ]; then log "IP up but DNS failing ($dfails x) — flushing caches"; flush_dns_cache; dfails=0; fi
            fi
            continue
        fi
        link_ok || continue                     # a single missed ARP must not reset the count
        [ "$now" -lt "$backoff_until" ] && continue
        fails=$((fails + 1))
        if [ "$fails" -lt "$need" ]; then log "offline with link up ($fails/$need) $(artifacts_desc)"; continue; fi
        log "offline with link up ($fails/$need) warp=$(warp_status) $(artifacts_desc) — healing"
        fails=0
        "$0" heal watchdog; rc=$?              # heal takes the lock itself
        case "$rc" in 0) backoff=60 ;; 3) backoff=600 ;; *) backoff=300 ;; esac
        backoff_until=$(( $(/bin/date +%s) + backoff ))
        log "heal rc=$rc — next action no sooner than ${backoff}s"
    done
}

purge_cmd() {
    TAG="warp-killswitch[purge]"
    if artifacts_present; then
        log "leftovers present ($(artifacts_desc)) — purging"
        purge_artifacts && log "clean" || log "! could not fully purge: $(artifacts_desc)"
        flush_dns_cache
    fi
    return 0
}

sleep_pre() {
    TAG="warp-killswitch[sleep]"
    is_killed && return 0
    if [ "$(warp_status)" = Connected ]; then
        : > "$RESUME_MARK"
        log "sleep: disconnecting WARP cleanly"
        tmo 10 "$WARP_CLI" --accept-tos disconnect >/dev/null 2>&1
    fi
    return 0
}
sleep_post() {
    TAG="warp-killswitch[sleep]"
    [ -f "$RESUME_MARK" ] || return 0
    $RM -f "$RESUME_MARK"
    is_killed && return 0
    log "wake: reconnecting WARP"
    ( /bin/sleep 3; WARP connect >/dev/null 2>&1; /bin/sleep 6; flush_dns_cache ) >/dev/null 2>&1 &
    return 0
}

status_cmd() {
    local killed=armed dns=intact link inet d eg
    is_killed && killed=KILLED
    [ -f "$STATE_DIR/dns-swapped" ] && dns="swapped to DHCP (backup present)"
    echo "warp-killswitch status — $(/bin/hostname -s)  $(/bin/date '+%F %T')"
    echo "  killswitch : $killed   (dns: $dns)"
    echo "  daemon     : $(daemon_alive && echo running || echo stopped) / $(/bin/launchctl print-disabled system 2>/dev/null | $GREP -q "\"$LABEL\" => disabled" && echo disabled || echo enabled)"
    echo "  warp-cli   : $(warp_status)"
    if link_ok; then link="ok  dev=$LINK_DEV gw=${LINK_GW:-none} via=${LINK_HOW:-route}"; else link="DOWN dev=${LINK_DEV:-none} gw=${LINK_GW:-none} via=${LINK_HOW:-route}"; fi
    echo "  link       : $link"
    if online_now; then inet=online; else inet=OFFLINE; fi
    dns_ok && d=ok || d=FAIL
    echo "  internet   : $inet   dns: $d"
    eg=$(egress_line); echo "  egress     : ${eg:-unreachable}"
    echo "  artifacts  : $(artifacts_desc)"
    echo "  watchdog   : $(/bin/launchctl print system/local.warp-killswitch.watchdog 2>/dev/null | $GREP -q 'state = running' && echo running || echo NOT running)"
    echo "  sleep hook : $([ -f /Library/LaunchDaemons/local.warp-killswitch.sleepwatcher.plist ] && echo present || echo missing)"
    echo "  Wi-Fi DNS  : $(/usr/sbin/networksetup -getdnsservers Wi-Fi 2>/dev/null | /usr/bin/tr '\n' ' ')"
    tainted && echo "  note       : ARP/socket enumeration is BLANKED for this caller (macOS 27, non-Apple parent); down/up/heal auto-redispatch via launchd"
    echo "  last log   : $(/usr/bin/tail -n 1 "$LOG" 2>/dev/null)"
}

# macOS 27: a process forked from a non-Apple-signed binary (xbar, Homebrew
# bash, iTerm) reads an EMPTY ARP table and socket list; pf/route enumeration
# may be partial too. The watchdog is launchd-rooted and never affected, but a
# menu- or terminal-launched down/up/heal would decide from a blind view. So:
# detect the blank (gateway exists, ARP table empty) and re-dispatch the
# command through an on-demand LaunchDaemon, which launchd spawns clean.
tainted() {
    [ -n "$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/{print $2; exit}')" ] || return 1
    [ -z "$(/usr/sbin/arp -an 2>/dev/null)" ]
}
# relaunch_via_launchd ACTION -> job exit code; 200 if it could not be dispatched.
relaunch_via_launchd() {
    local label="local.warp-killswitch.do-$1" n0 rc
    /bin/launchctl print "system/$label" >/dev/null 2>&1 || return 200
    n0=$(/usr/bin/wc -l < "$LOG" 2>/dev/null | /usr/bin/tr -d ' '); [ -n "$n0" ] || n0=0
    log "caller is not Apple-rooted (ARP table blanked, macOS 27) — re-dispatching '$1' via launchd"
    /bin/launchctl kickstart "system/$label" >/dev/null 2>&1 || return 200
    /bin/sleep 2
    for _ in $(/usr/bin/seq 1 240); do
        /bin/launchctl print "system/$label" 2>/dev/null | $GREP -q 'state = running' || break
        /bin/sleep 1
    done
    /usr/bin/tail -n +$((n0 + 2)) "$LOG" 2>/dev/null
    rc=$(/bin/launchctl print "system/$label" 2>/dev/null | /usr/bin/awk '/last exit code/{print $NF; exit}')
    case "$rc" in ''|*[!0-9]*) return 0 ;; *) return "$rc" ;; esac
}

# mkdir mutex (no flock on macOS). with_lock waits up to 60s; try_lock is non-blocking.
release_lock() { $RM -rf "$LOCK_DIR"; }
with_lock() {
    for _ in $(/usr/bin/seq 1 60); do
        if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then trap release_lock EXIT; return 0; fi
        # stale lock (owner gone)?
        if [ -f "$LOCK_DIR/pid" ] && ! /bin/kill -0 "$($CAT "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then $RM -rf "$LOCK_DIR"; continue; fi
        /bin/sleep 1
    done
    log "another warp-killswitch operation is running"; exit 5
}
try_lock() { /bin/mkdir "$LOCK_DIR" 2>/dev/null || exit 0; trap release_lock EXIT; }

# Mutating commands from a tainted caller go through launchd (see above).
# WK_DISPATCHED=1 marks the launchd-side run so it cannot loop.
if [ -z "${WK_DISPATCHED:-}" ]; then
    case "${1:-}" in
        down|up|heal)
            if [ "$#" -le 2 ] && [ "${2:-}" != --keep-dns ] && [ "${2:-}" != --fast ] && tainted; then
                relaunch_via_launchd "$1"; rc=$?
                [ "$rc" -ne 200 ] && exit "$rc"
                log "launchd re-dispatch unavailable — running inline with a blind ARP view"
            fi ;;
    esac
fi
case "${1:-}" in
    down)       shift; with_lock; echo $$ > "$LOCK_DIR/pid"; warp_down "$@" ;;
    up)         with_lock; echo $$ > "$LOCK_DIR/pid"; warp_up ;;
    heal)       with_lock; echo $$ > "$LOCK_DIR/pid"; heal "${2:-manual}" ;;
    watchdog)   watchdog ;;
    purge)      try_lock; echo $$ > "$LOCK_DIR/pid"; purge_cmd ;;
    status)     status_cmd ;;
    state)      is_killed && echo killed || echo armed ;;
    verify)     if internet_or_portal; then echo online; exit 0; else echo offline; exit 1; fi ;;
    sleep-pre)  sleep_pre ;;
    sleep-post) sleep_post ;;
    *)          echo "usage: $0 {down [--keep-dns] [--fast]|up|heal|watchdog|purge|status|state|verify}" >&2; exit 2 ;;
esac
HELPER_EOF
/bin/chmod 0755 "$HELPER"; "$CHOWN" root:wheel "$HELPER"
/bin/bash -n "$HELPER" || die "helper failed syntax check."
audit_paths "$HELPER" "warp-killswitch helper" || true
c_grn "installed $HELPER"

# ---- 2. sudoers -------------------------------------------------------------
TMP_SUDO=$(/usr/bin/mktemp)
printf '# Cloudflare WARP kill-switch menu helper (warp-killswitch-macos install.sh).\n%s ALL=(root) NOPASSWD: %s\n' "$TARGET_USER" "$HELPER" > "$TMP_SUDO"
/usr/sbin/visudo -cf "$TMP_SUDO" >/dev/null || { $RM -f "$TMP_SUDO"; die "generated sudoers is invalid."; }
/usr/bin/install -m 0440 -o root -g wheel "$TMP_SUDO" "$SUDOERS"
$RM -f "$TMP_SUDO"
c_grn "installed $SUDOERS  ($TARGET_USER NOPASSWD)"

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
write_plugin() {
    local dest="$1" tag="$2" bak
    [ -n "$dest" ] || return 0
    /usr/bin/install -d -m 0755 -o "$TARGET_USER" "$(dirname "$dest")" "$BACKUP_DIR"
    bak="$BACKUP_DIR/security-toggle.5s.sh.$tag.pre-killswitch.bak"
    if [ -f "$dest.pre-killswitch.bak" ]; then          # legacy v1 backup sitting in the plugin dir
        $MV -f "$dest.pre-killswitch.bak" "$bak"; /bin/chmod -x "$bak"
        c_ylw "moved legacy backup out of the plugin folder -> $bak"
    fi
    if [ -f "$dest" ] && ! $GREP -qF "$PLUGIN_MARK" "$dest" && [ ! -f "$bak" ]; then
        $CP -a "$dest" "$bak"; /bin/chmod -x "$bak"
        c_ylw "backed up $dest -> $bak"
    fi
    $CP "$PLUGIN_SRC" "$dest"
    "$CHOWN" "$TARGET_USER" "$dest"
    /bin/chmod 0755 "$dest"
    /bin/bash -n "$dest" || die "plugin $dest failed syntax check."
    audit_paths "$dest" "xbar plugin ($tag)" || true
    c_grn "installed $dest"
}
if [ "$DO_MENU" -eq 1 ]; then
    { [ -e "$PLUGIN_ACTIVE" ] || [ -d "$(dirname "$PLUGIN_ACTIVE")" ]; } && write_plugin "$PLUGIN_ACTIVE" active
    { [ -e "$PLUGIN_SOURCE" ] || [ -d "$(dirname "$PLUGIN_SOURCE")" ]; } && write_plugin "$PLUGIN_SOURCE" source
    "$CHOWN" -R "$TARGET_USER" "$BACKUP_DIR" 2>/dev/null
    /usr/bin/sudo -u "$TARGET_USER" /usr/bin/open -g 'xbar://app/refreshAllPlugins' >/dev/null 2>&1 || true
else
    c_ylw "menu skipped (--no-menu)"
fi

# ---- 6. self-test -----------------------------------------------------------
echo
"$HELPER" status
echo
c_grn "=== warp-killswitch v3 (macOS) installed for $TARGET_USER ==="
echo "Menu:  WARP section -> Tear Down / Rebuild / Heal now / Status"
echo "CLI:   sudo $HELPER {down|up|heal|status|verify|state}"
echo "Logs:  /var/log/warp-killswitch.log   /var/log/warp-watchdog.log"
