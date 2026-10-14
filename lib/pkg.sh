#!/bin/bash
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# lib/pkg.sh — package-manager layer shared by install.sh and components/*/install.sh.
# Sourced, never executed. Stock bash 3.2 only (install.sh re-execs under /bin/bash).
#
# POLICY: Apple Silicon is the primary platform and is never downgraded — it always uses
# Homebrew exactly as before this layer existed, whatever else is installed, and
# SECURENET_PKG is ignored there. Intel Macs (including OpenCore Legacy Patcher Macs)
# are supported in a degraded mode:
#   * MacPorts (/opt/local) — root-owned prefix, prebuilt archives for every macOS from
#     10.6 to 27. Preferred on Intel: Homebrew stopped building x86_64 bottles in
#     September 2026, so every formula compiles there.
#   * Homebrew (/usr/local) — still used on Intel if it is already installed and MacPorts
#     is not (slow: everything builds from source).
#   On Intel, SECURENET_PKG=macports|homebrew forces the choice.
#
# Interface (all set/defined after pkg_detect):
#   PKG_MGR        macports | homebrew
#   PKG_PREFIX     /opt/local | /opt/homebrew | /usr/local
#   pkg_detect                 choose the manager (no side effects)
#   pkg_bootstrap              install the chosen manager if it is missing
#   pkg_name GENERIC           this manager's package name for a generic name ("" = none)
#   pkg_installed GENERIC      0 if installed
#   pkg_install GENERIC...     install whatever is missing (prebuilt first on MacPorts)
#   pkg_bin NAME               absolute path of NAME inside the prefix ("" if absent)
#   pkg_bash4                  path of a bash >= 4 from the prefix ("" if absent)
#   pkg_root_owned PATH        0 if PATH and every parent dir are root-owned and not
#                              group/world-writable (safe target for a NOPASSWD rule)
#   app_install APP            Cloudflare WARP | xbar | ProtonVPN — cask on Homebrew,
#                              signature-verified vendor download otherwise
#
# Callers provide grn/ylw/red/fail (install.sh does); fallbacks are defined below.

type grn >/dev/null 2>&1 || grn() { printf '%s\n' "$*"; }
type ylw >/dev/null 2>&1 || ylw() { printf '%s\n' "$*"; }
type red >/dev/null 2>&1 || red() { printf '%s\n' "$*" >&2; }
type fail >/dev/null 2>&1 || fail() { red "  ✗ $*"; }

OS_VER=$(/usr/bin/sw_vers -productVersion)
OS_MAJOR=${OS_VER%%.*}
ARCH=$(/usr/bin/uname -m)

# 0 if the running macOS is at least $1 (e.g. 14.0, 13.5)
os_at_least() {
    local want_maj want_min have_min
    want_maj=${1%%.*}; want_min=${1#*.}; [ "$want_min" = "$1" ] && want_min=0
    have_min=$(printf '%s' "$OS_VER" | cut -d. -f2); have_min=${have_min:-0}
    [ "$OS_MAJOR" -gt "$want_maj" ] && return 0
    [ "$OS_MAJOR" -eq "$want_maj" ] && [ "${have_min%%[!0-9]*}" -ge "${want_min%%[!0-9]*}" ]
}

# OpenCore Legacy Patcher leaves its version in NVRAM (and a support dir) on patched Macs.
is_oclp() {
    /usr/sbin/nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:OCLP-Version >/dev/null 2>&1 && return 0
    [ -d "/Library/Application Support/Dortania" ]
}

pkg_detect() {
    if [ "$ARCH" = arm64 ]; then
        # Apple Silicon: unconditionally the original Homebrew path (see POLICY above).
        PKG_MGR=homebrew; PKG_PREFIX=/opt/homebrew
    else
        case "${SECURENET_PKG:-}" in
            macports) PKG_MGR=macports ;;
            homebrew) PKG_MGR=homebrew ;;
            "")
                if [ -x /opt/local/bin/port ]; then PKG_MGR=macports
                elif [ -x /usr/local/bin/brew ]; then PKG_MGR=homebrew
                else PKG_MGR=macports
                fi ;;
            *) red "SECURENET_PKG must be macports or homebrew"; return 1 ;;
        esac
        if [ "$PKG_MGR" = macports ]; then PKG_PREFIX=/opt/local; else PKG_PREFIX=/usr/local; fi
    fi
    if [ "$PKG_MGR" = homebrew ] && [ -x "$PKG_PREFIX/bin/brew" ]; then
        eval "$("$PKG_PREFIX/bin/brew" shellenv)"
    fi
    case ":$PATH:" in *":$PKG_PREFIX/bin:"*) ;; *) PATH="$PKG_PREFIX/bin:$PKG_PREFIX/sbin:$PATH" ;; esac
    export PATH PKG_MGR PKG_PREFIX
}

# Generic name -> per-manager package name. Empty output = not available there.
# Components extend this by defining pkg_name_extra GENERIC MGR before calling pkg_*.
pkg_name() {
    local n
    if type pkg_name_extra >/dev/null 2>&1; then
        n=$(pkg_name_extra "$1" "$PKG_MGR") && [ -n "$n" ] && { [ "$n" = - ] || printf '%s\n' "$n"; return 0; }
    fi
    case "$PKG_MGR:$1" in
        homebrew:speedtest) echo speedtest-go ;;   # Homebrew deprecated speedtest-cli
        macports:speedtest) echo speedtest-cli ;;  # MacPorts has no speedtest-go
        *) echo "$1" ;;
    esac
}

pkg_installed() {
    local n; n=$(pkg_name "$1"); [ -n "$n" ] || return 1
    case "$PKG_MGR" in
        homebrew) brew list --formula "$n" >/dev/null 2>&1 ;;
        macports) /opt/local/bin/port -q installed "$n" 2>/dev/null | grep -q '(active)' ;;
    esac
}

pkg_install() {
    local g n missing="" rc=0
    for g in "$@"; do
        pkg_installed "$g" && continue
        n=$(pkg_name "$g")
        if [ -z "$n" ]; then ylw "  $g: no $PKG_MGR package — skipped"; continue; fi
        missing="$missing $n"
    done
    [ -z "$missing" ] && return 0
    case "$PKG_MGR" in
        homebrew)
            echo "  brew install$missing"
            # shellcheck disable=SC2086  # word splitting is the package list
            brew install $missing || rc=1 ;;
        macports)
            # One port per command: a single failure must not abort the rest.
            # Prebuilt archive first (-b); build from source only if there is none.
            for n in $missing; do
                echo "  sudo port install $n"
                sudo /opt/local/bin/port -N -b install "$n" >/dev/null 2>&1 \
                    || sudo /opt/local/bin/port -N install "$n" \
                    || { fail "port install $n"; rc=1; }
            done ;;
    esac
    return $rc
}

pkg_bin() { [ -x "$PKG_PREFIX/bin/$1" ] && echo "$PKG_PREFIX/bin/$1" || { [ -x "$PKG_PREFIX/sbin/$1" ] && echo "$PKG_PREFIX/sbin/$1"; }; }

pkg_bash4() {
    local b="$PKG_PREFIX/bin/bash"
    [ -x "$b" ] && [ "$("$b" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ] 2>/dev/null && echo "$b"
}

pkg_root_owned() {
    local p="$1" owner mode
    while :; do
        [ -e "$p" ] || return 1
        owner=$(/usr/bin/stat -f %u "$p"); mode=$(/usr/bin/stat -f %Lp "$p")
        [ "$owner" = 0 ] || return 1
        case "$mode" in *[2367]?|*?[2367]) return 1 ;; esac   # group- or world-writable
        [ "$p" = / ] && return 0
        p=$(dirname "$p")
    done
}

# ---- bootstrap the manager -------------------------------------------------------

clt_installed() { /usr/bin/xcode-select -p >/dev/null 2>&1 && [ -x "$(/usr/bin/xcode-select -p)/usr/bin/clang" ]; }

clt_install() {
    clt_installed && return 0
    ylw "  installing the Xcode Command Line Tools (softwareupdate)"
    local flag=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress label
    /usr/bin/touch "$flag"
    label=$(/usr/sbin/softwareupdate -l 2>/dev/null | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | tail -1)
    if [ -n "$label" ]; then sudo /usr/sbin/softwareupdate -i "$label" --verbose; fi
    /bin/rm -f "$flag"
    clt_installed || { red "  Command Line Tools still missing — run: xcode-select --install"; return 1; }
}

macports_bootstrap() {
    [ -x /opt/local/bin/port ] && return 0
    clt_install || return 1
    local api rel url pkg tmp
    api=https://api.github.com/repos/macports/macports-base/releases/latest
    # Asset names: MacPorts-<ver>-<major>-<Name>.pkg (11+) or -10.<minor>-<Name>.pkg (older).
    case "$OS_MAJOR" in 10) rel="10.$(printf '%s' "$OS_VER" | cut -d. -f2)" ;; *) rel="$OS_MAJOR" ;; esac
    url=$(/usr/bin/curl -fsSL "$api" | /usr/bin/grep -oE "https://[^\"]*/MacPorts-[0-9.]+-${rel}-[A-Za-z]+\\.pkg" | head -1)
    [ -n "$url" ] || { red "  no MacPorts installer for macOS $OS_VER in the latest release"; return 1; }
    tmp=$(mktemp -d); pkg="$tmp/${url##*/}"
    echo "  downloading ${url##*/}"
    /usr/bin/curl -fsSL -o "$pkg" "$url" || { red "  download failed: $url"; return 1; }
    # Developer ID-signed and notarized by the MacPorts release manager — refuse anything else.
    if ! /usr/sbin/pkgutil --check-signature "$pkg" | grep -q 'Developer ID Installer: Joshua Root (QTA3A3B7F3)'; then
        red "  MacPorts installer signature is not Joshua Root (QTA3A3B7F3) — refusing"; rm -rf "$tmp"; return 1
    fi
    sudo /usr/sbin/installer -pkg "$pkg" -target / || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    sudo /opt/local/bin/port -N selfupdate
}

homebrew_bootstrap() {
    { [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ]; } && return 0
    NONINTERACTIVE=1 /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

pkg_bootstrap() {
    case "$PKG_MGR" in
        macports) macports_bootstrap || return 1 ;;
        homebrew) homebrew_bootstrap || return 1 ;;
    esac
    pkg_detect   # re-read prefix/shellenv now that it exists
}

# ---- apps (casks on Homebrew; verified vendor downloads otherwise) ----------------
# APP -> cask, Developer ID Team ID, minimum macOS of the current release
app_meta() {
    case "$1" in
        "Cloudflare WARP") echo "cloudflare-warp 68WVV388M8 14.0" ;;
        xbar)              echo "xbar N3H5B92L5N 10.13" ;;
        ProtonVPN)         echo "protonvpn J6S6Q257EK 14.0" ;;
        *) return 1 ;;
    esac
}

# Verify an .app is signed by the expected Team ID (and the signature is intact).
app_team_ok() {
    /usr/bin/codesign --verify --deep --strict "$1" 2>/dev/null \
        && /usr/bin/codesign -dv "$1" 2>&1 | grep -qx "TeamIdentifier=$2"
}

app_install() {
    local app="$1" cask team minos tmp url mnt src ver
    [ -d "/Applications/$app.app" ] && { grn "  $app.app present"; return 0; }
    read -r cask team minos <<EOF
$(app_meta "$app")
EOF
    if [ "$PKG_MGR" = homebrew ]; then
        echo "  brew install --cask $cask"; brew install --cask "$cask"; return $?
    fi
    tmp=$(mktemp -d)
    case "$app" in
        "Cloudflare WARP")
            if ! os_at_least "$minos"; then
                ylw "  Cloudflare WARP needs macOS $minos+ (this is $OS_VER) — skipped."
                ylw "    The DNS, firewall and monitoring components still protect this Mac."
                rm -rf "$tmp"; return 2
            fi
            url=https://downloads.cloudflareclient.com/v1/download/macos/ga
            /usr/bin/curl -fsSL -o "$tmp/warp.pkg" "$url" || { rm -rf "$tmp"; return 1; }
            /usr/sbin/pkgutil --check-signature "$tmp/warp.pkg" | grep -q "($team)" \
                || { red "  WARP package not signed by $team — refusing"; rm -rf "$tmp"; return 1; }
            sudo /usr/sbin/installer -pkg "$tmp/warp.pkg" -target / ;;
        xbar|ProtonVPN)
            if [ "$app" = xbar ]; then
                url=$(/usr/bin/curl -fsSL https://api.github.com/repos/matryer/xbar/releases/latest \
                      | /usr/bin/grep -oE 'https://[^"]+\.dmg' | head -1)
            else
                # Newest non-beta release whose minimumSystemVersion this macOS satisfies.
                url=$(/usr/bin/curl -fsSL https://protonvpn.com/download/macos/updates/v5/sparkle.xml | /usr/bin/awk '
                    /<item>/ {u=""; m="0"; b=0}
                    /url="/ {s=$0; sub(/.*url="/,"",s); sub(/".*/,"",s); u=s; if (s ~ /beta|alpha/) b=1}
                    /<sparkle:minimumSystemVersion>/ {s=$0; gsub(/.*<sparkle:minimumSystemVersion>|<.*/,"",s); m=s}
                    /<\/item>/ {if (u != "" && !b) print m " " u}' \
                    | while read -r ver url; do os_at_least "$ver" && { echo "$url"; break; }; done)
                if [ -z "$url" ]; then
                    ylw "  no ProtonVPN release supports macOS $OS_VER — skipped (current builds need $minos+)"
                    rm -rf "$tmp"; return 2
                fi
            fi
            [ -n "$url" ] || { red "  could not find a $app download"; rm -rf "$tmp"; return 1; }
            echo "  downloading ${url##*/}"
            /usr/bin/curl -fsSL -o "$tmp/app.dmg" "$url" || { rm -rf "$tmp"; return 1; }
            mnt=$(/usr/bin/hdiutil attach -nobrowse -readonly "$tmp/app.dmg" | /usr/bin/awk -F'\t' '/\/Volumes\//{print $NF; exit}')
            src=$(/usr/bin/find "$mnt" -maxdepth 2 -name "$app.app" -print -quit)
            if [ -n "$src" ] && app_team_ok "$src" "$team"; then
                sudo /usr/bin/ditto "$src" "/Applications/$app.app"
            else
                red "  $app in the download is missing or not signed by $team — refusing"
            fi
            /usr/bin/hdiutil detach -quiet "$mnt" ;;
    esac
    rm -rf "$tmp"
    [ -d "/Applications/$app.app" ] && app_team_ok "/Applications/$app.app" "$team" \
        && grn "  $app installed ($(/usr/bin/defaults read "/Applications/$app.app/Contents/Info" CFBundleShortVersionString 2>/dev/null))"
}
