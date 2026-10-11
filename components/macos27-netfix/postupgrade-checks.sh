#!/bin/sh
# postupgrade-checks.sh — read-only report on the other macOS 27 upgrade
# breakage seen alongside the ARP issue. Changes nothing; prints the fix for
# anything it finds so you can decide.

set -u

echo "== macOS 27 post-upgrade checks (read-only) =="
echo

# --- 1. Finder window with no traffic lights that will not close ----------
# Usually the "Finder Settings" window: not a "Finder window", so it ignores
# the usual close paths, and it survives `killall Finder` at identical bounds.
echo "-- Finder windows --"
# Distinguish "query failed" from "zero windows" — an empty result is the
# healthy case and must not be reported as an error.
wins=$(osascript -e 'tell application "Finder" to get name of every window' 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "  (could not query Finder)"
elif [ -z "$wins" ]; then
    echo "  open: none"
else
    echo "  open: $wins"
    case "$wins" in
        *Settings*|*Preferences*)
            echo "  FOUND a Finder Settings/Preferences window."
            echo "  This is the usual cause of 'no red/yellow/green, will not close'."
            echo "  Fix:"
            echo "    osascript -e 'tell application \"Finder\" to close window \"Finder Settings\"'"
            ;;
        *) echo "  no stuck settings window detected" ;;
    esac
fi
echo

# --- 2. duplicate menu-bar icons -----------------------------------------
# xbar/SwiftBar execute EVERY executable file in the plugin dir. An executable
# backup left there loads as a second plugin with identical icons, wired to
# stale code — so its menu actions run the old script.
echo "-- menu bar plugin dirs --"
# SwiftBar's plugin dir is user-configurable, so ask it rather than guessing.
SB_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
for d in "$HOME/Library/Application Support/xbar/plugins" \
         "$HOME/.bitbar" \
         ${SB_DIR:+"$SB_DIR"} \
         "$HOME/Documents/SwiftBar/Plugins" \
         "$HOME/Library/Application Support/SwiftBar/Plugins"; do
    [ -d "$d" ] || continue

    # Whether the owning app is actually present decides if a stray plugin is
    # producing icons right now or is just dormant clutter. Say which.
    case "$d" in
        *SwiftBar*) app="SwiftBar" ;;
        *) app="xbar" ;;
    esac
    state="not installed"
    if [ -d "/Applications/$app.app" ]; then
        pgrep -x "$app" >/dev/null 2>&1 && state="running" || state="installed, not running"
    fi

    echo "  $d  [$app: $state]"
    dupes=0   # an active duplicate that needs fixing
    seen=0    # any backup at all, active or dormant
    for f in "$d"/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        case "$(basename "$f")" in
            *.bak|*.bak.*|*.old|*.orig|*~|*.disabled|*.pre-*)
                seen=1
                if [ "$state" = "not installed" ]; then
                    echo "    dormant backup (no $app to load it): $(basename "$f")"
                else
                    echo "    DUPLICATE SOURCE (executable backup): $(basename "$f")"
                    dupes=1
                fi ;;
        esac
    done
    [ "$dupes" -eq 1 ] && {
        echo "    This loads as a SECOND plugin with identical icons, wired to stale"
        echo "    code — its menu actions run the OLD script. Move it out of the dir"
        echo "    (chmod -x is not enough if the name still matches the pattern):"
        echo "      mkdir -p \"$d/../plugin-backups\" && mv <file> \"$d/../plugin-backups/\""
    }
    [ "$seen" -eq 0 ] && echo "    no executable backups"
done
echo

# --- 3. stale TCC grants --------------------------------------------------
# After a major upgrade an app's bundle/signature may no longer match its TCC
# record. System Settings shows the permission ON while the app reports it OFF.
# The app's own check is the honest one.
echo "-- apps commonly hit by stale TCC records --"
for app in "Bartender 6:com.surteesstudios.Bartender" \
           "Bartender 5:com.surteesstudios.Bartender" \
           "BetterTouchTool:com.hegenberg.BetterTouchTool" \
           "Hammerspoon:org.hammerspoon.Hammerspoon" \
           "Raycast:com.raycast.macos"; do
    name="${app%%:*}"; bid="${app##*:}"
    [ -d "/Applications/$name.app" ] || continue
    running=no; pgrep -x "$name" >/dev/null 2>&1 && running=yes
    echo "  $name (installed, running=$running) -> $bid"
done
echo "  If one insists a permission is off while System Settings shows it on,"
echo "  reset the record and re-approve (this REVOKES it until you re-grant):"
echo "    tccutil reset ScreenCapture <bundle-id>"
echo "    tccutil reset Accessibility <bundle-id>"
echo "  then quit and relaunch the app, and approve the prompt."
echo

# --- 4. launchd jobs in a restart loop ------------------------------------
# A job re-firing a startup notification is usually crash-looping, not
# repeating a notification. stderr may be EMPTY if the failing command has
# 2>/dev/null on it, so judge by exit code and run count instead.
echo "-- user LaunchAgents with a nonzero last exit --"
any=0
for p in "$HOME/Library/LaunchAgents"/*.plist; do
    [ -f "$p" ] || continue
    lbl=$(basename "$p" .plist)
    info=$(launchctl print "gui/$(id -u)/$lbl" 2>/dev/null) || continue
    # Take everything after "= ", not $NF: the value can be "(never exited)",
    # whose last field is "exited)" and would read as a nonzero exit.
    ec=$(echo "$info" | sed -n 's/.*last exit code = //p' | head -1)
    runs=$(echo "$info" | sed -n 's/.*[^_]runs = //p' | head -1)
    case "$ec" in
        ''|0)      ;;   # healthy
        *never*)   ;;   # "(never exited)" — running or not yet run
        *) echo "  $lbl: last exit=$ec runs=${runs:-?}"; any=1 ;;
    esac
done
[ "$any" -eq 0 ] && echo "  none"
echo "  A high 'runs' count with a nonzero exit = restart loop. Common cause:"
echo "  'set -euo pipefail' plus a command that now fails, e.g. an ARP lookup."
echo
echo "Done. Nothing was changed."
