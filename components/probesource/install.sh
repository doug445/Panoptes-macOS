#!/usr/bin/env bash
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# install.sh (macOS) — install the probesource probe driver onto this Mac and
# bootstrap the dependencies it needs.
#
# probesource is a single self-contained bash script: it keeps all state under
# ~/.local/share/probesource and never references this repo at runtime, so
# "installing" just means dropping the one file onto your PATH. This wrapper
# does that idempotently (locating probesource next to itself, so it works from
# the repo or a USB copy) and can also install probesource's dependencies
# through the suite's package layer (lib/pkg.sh).
#
# Usage:
#   ./install.sh              # install to ~/.local/bin (per-user, no sudo)
#   ./install.sh --system     # install to /usr/local/bin (all users, sudo)
#   ./install.sh --prefix DIR # install into DIR/<binary>
#   ./install.sh --uninstall  # remove a previously installed copy
#   ./install.sh --deps-only  # install/bootstrap dependencies only (no copy)
#   ./install.sh --no-deps    # copy the script only, skip dependency install
#
# Package manager (lib/pkg.sh): Apple Silicon always uses Homebrew under
# /opt/homebrew, run as the normal user — never as root. Intel and OpenCore
# Legacy Patcher Macs use MacPorts (/opt/local, installs via sudo) exclusively —
# any installed Homebrew is ignored (the two coexist). SECURENET_PKG=homebrew
# forces the deprecated Homebrew-Intel path (it warns); the chosen manager can
# be bootstrapped if missing.
#
# Dependencies installed (Homebrew formula / MacPorts port where different):
#   bash>=4, grep, gnu-sed/gsed, coreutils, gawk (GNU userland the parser needs),
#   dialog, nmap, arp-scan, wireshark/wireshark4 (tshark), p0f, mtr, masscan,
#   sslscan, ike-scan, samba/samba4 (smbclient), pipx, and enum4linux-ng (via
#   pipx from git). MacPorts also supplies nbtscan.
# whois/dig/tcpdump/traceroute/curl are base-system and are not installed.
# onesixtyone (both managers) and nbtscan (Homebrew) have no package and are
# built from their upstream GitHub repos (needs git + Xcode Command Line Tools;
# nbtscan also pulls autoconf/automake).
#
# MacPorts (Intel) only: ike-scan and hping3 are built from upstream too,
# because their ports do not build on a current Apple clang toolchain (see
# build_from_source() for the fixes). This is gated to MacPorts — on Homebrew
# (Apple Silicon and the Intel /usr/local prefix) behaviour is unchanged:
# ike-scan installs from its working formula and hping3 stays skipped.
# hping3 (Homebrew only) and geoiplookup (covered by a Team Cymru DNS fallback)
# are left to the tool's graceful skip.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/probesource"
BIN=probesource

DEST_DIR="$HOME/.local/bin"
USE_SUDO=0
DO_UNINSTALL=0
DO_COPY=1        # copy the probesource script onto PATH
DO_DEPS=auto     # auto: prompt when interactive; 1: force; 0: skip

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --system)    DEST_DIR=/usr/local/bin; USE_SUDO=1 ;;
        --prefix)    DEST_DIR="${2:?--prefix needs a directory}"; shift ;;
        --uninstall) DO_UNINSTALL=1 ;;
        --deps-only) DO_COPY=0; DO_DEPS=1 ;;
        --no-deps)   DO_DEPS=0 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# Interactive only when both stdin and stdout are TTYs. Non-interactive contexts
# skip every prompt (and skip the default dep install) but still copy the script.
INTERACTIVE=0
[[ -t 0 && -t 1 ]] && INTERACTIVE=1

# ── platform / architecture / package manager detection ─────────────────────
# lib/pkg.sh picks the manager: arm64 → Homebrew, prefix /opt/homebrew (always);
# x86_64 (T2, pre-T2 and OCLP Intel Macs) → MacPorts at /opt/local exclusively
# (bootstrapped if absent; any Homebrew is ignored). A copy of this directory without the suite's lib/
# can still install the script itself; dependency install then reports why not.
ARCH="$(uname -m)"
PKG_MGR=none
PKG_PREFIX=/usr/local; [[ "$ARCH" == arm64 ]] && PKG_PREFIX=/opt/homebrew
PKG_LIB="$SRC_DIR/../../lib/pkg.sh"
if [[ -r "$PKG_LIB" ]]; then
    PKG_LIB="$(cd "$(dirname "$PKG_LIB")" && pwd)/pkg.sh"
    # shellcheck source=../../lib/pkg.sh
    . "$PKG_LIB"
    pkg_detect || exit 2
else
    PKG_LIB=""
fi

# Per-manager package names for the generic names used below (pkg_name hook).
# Empty output = same name as the generic; "-" = not packaged on that manager.
pkg_name_extra() {
    case "$2:$1" in
        macports:gnu-sed)   echo gsed ;;
        macports:wireshark) echo wireshark4 ;;
        macports:samba)     echo samba4 ;;
        homebrew:nbtscan)   echo - ;;     # no formula — built from git instead
        *:onesixtyone)      echo - ;;     # no formula/port — built from git
        *:hping3|*:geoiplookup) echo - ;; # left to the tool's graceful skip
    esac
}

# Human label for the manager, and its word for a package.
if [[ "$PKG_MGR" == macports ]]; then
    MGR_LABEL=MacPorts; PKG_WORD=port
else
    MGR_LABEL=Homebrew; PKG_WORD=formula
fi

# Detect an Apple T2 security chip (only present on 2018-2020 Intel Macs).
has_t2() {
    if /usr/sbin/ioreg -rc AppleT2Controller 2>/dev/null | grep -q .; then
        return 0
    fi
    system_profiler SPiBridgeDataType 2>/dev/null | grep -q 'Apple T2' && return 0
    return 1
}

PLATFORM="other"
if [[ "$ARCH" == arm64 ]]; then
    PLATFORM="apple-silicon"
elif has_t2; then
    PLATFORM="t2-intel"
else
    PLATFORM="intel"
fi

report_platform() {
    echo "Architecture:      $ARCH"
    case "$PLATFORM" in
        apple-silicon) echo "Platform detected: Apple Silicon" ;;
        t2-intel)      echo "Platform detected: Apple T2 Intel Mac" ;;
        intel)         echo "Platform detected: Intel Mac (no Apple T2 chip)" ;;
        *)             echo "Platform detected: unknown ($ARCH)" ;;
    esac
    if [[ "$PKG_MGR" == macports ]]; then
        echo "MacPorts prefix:   $PKG_PREFIX"
        [[ "$PLATFORM" == intel ]] && \
            echo "Note: pre-T2 Intel Mac — proceeding with MacPorts at /opt/local."
    else
        echo "Homebrew prefix:   $PKG_PREFIX"
        [[ "$PLATFORM" == intel ]] && \
            echo "Note: pre-T2 Intel Mac — proceeding with the /usr/local Homebrew prefix."
    fi
    if [[ "$ARCH" != arm64 ]] && type is_oclp >/dev/null 2>&1 && is_oclp; then
        echo "Note: OpenCore Legacy Patcher Mac — some probe tools may be unavailable."
    fi
    [[ -n "$PKG_LIB" ]] || echo "Note: lib/pkg.sh not found next to this copy — dependency install unavailable."
}

DEST="$DEST_DIR/$BIN"
# Use sudo automatically when the target dir isn't writable by us.
[[ "$USE_SUDO" == 1 || ( -e "$DEST_DIR" && ! -w "$DEST_DIR" ) ]] && USE_SUDO=1
run() { if [[ "$USE_SUDO" == 1 ]]; then sudo "$@"; else "$@"; fi; }

# ── uninstall short-circuit ──────────────────────────────────────────────────
if [[ "$DO_UNINSTALL" == 1 ]]; then
    if [[ -e "$DEST" ]]; then
        run rm -f "$DEST" && echo "Removed $DEST"
    else
        echo "Nothing to remove at $DEST"
    fi
    echo "(State under ~/.local/share/probesource was left intact.)"
    if [[ "$PKG_MGR" == macports ]]; then
        echo "(MacPorts ports installed for probesource were left intact.)"
    else
        echo "(Homebrew formulae installed for probesource were left intact.)"
    fi
    exit 0
fi

# ── copy the probesource script onto PATH ────────────────────────────────────
if [[ "$DO_COPY" == 1 ]]; then
    [[ -r "$SRC" ]] || { echo "Cannot find probesource at: $SRC" >&2; exit 1; }
    # macOS has no coreutils `install(1)` with -D by default; do it by hand so
    # this works on a stock Mac (no Homebrew coreutils required just to install).
    run mkdir -p "$DEST_DIR" || { echo "Could not create $DEST_DIR" >&2; exit 1; }
    run cp -f "$SRC" "$DEST"  || { echo "Install failed." >&2; exit 1; }
    run chmod 755 "$DEST"
    echo "Installed: $DEST"

    # PATH sanity check — warn (don't edit shell rc files behind the user's back).
    case ":$PATH:" in
        *":$DEST_DIR:"*) ;;
        *) echo
           echo "NOTE: $DEST_DIR is not on your PATH. Add this to your shell rc:"
           echo "    export PATH=\"$DEST_DIR:\$PATH\"" ;;
    esac
fi

# ── dependency bootstrapping (Homebrew, arch-aware, never as root) ────────────
echo
echo "── Platform ─────────────────────────────────────────────"
report_platform
echo "─────────────────────────────────────────────────────────"

have() { command -v "$1" >/dev/null 2>&1; }

# Is GNU grep available the way probesource consumes it? The Homebrew `grep`
# formula installs as `ggrep`; its unprefixed `grep` lives only in the formula's
# gnubin dir, which probesource prepends to PATH at startup. So the login shell's
# bare `grep` may still be BSD even when the formula is installed — check the
# gnubin symlink / `ggrep` / the bare grep, in that order. (BSD grep has no -P.)
# MacPorts' grep port is likewise `ggrep` plus /opt/local/libexec/gnubin/grep.
gnu_grep_ok() {
    [[ -x "$PKG_PREFIX/opt/grep/libexec/gnubin/grep" ]] && return 0
    [[ "$PKG_MGR" == macports && -x "$PKG_PREFIX/libexec/gnubin/grep" ]] && return 0
    command -v ggrep >/dev/null 2>&1 && return 0
    grep --version 2>/dev/null | grep -qi 'gnu grep'
}

# Ensure Homebrew's bin dir is on PATH for the rest of this script, using the
# arch-correct prefix. brew is never invoked under sudo.
ensure_brew_on_path() {
    if [[ -x "$PKG_PREFIX/bin/brew" ]]; then
        eval "$("$PKG_PREFIX/bin/brew" shellenv)" 2>/dev/null || \
            export PATH="$PKG_PREFIX/bin:$PATH"
        return 0
    fi
    have brew && return 0
    return 1
}

# Offer to bootstrap Homebrew via the official installer. Returns 0 if brew is
# available afterward.
bootstrap_homebrew() {
    if ensure_brew_on_path; then return 0; fi
    echo
    echo "Homebrew was not found at $PKG_PREFIX (needed to install probe tools)."
    if [[ "$INTERACTIVE" != 1 ]]; then
        echo "Non-interactive: skipping Homebrew install. Install it from https://brew.sh,"
        echo "then re-run: $0 --deps-only"
        return 1
    fi
    local ans
    read -r -p "Install Homebrew now via the official bootstrap? [Y/n] " ans
    case "$ans" in
        [Nn]*) echo "Skipping Homebrew install."; return 1 ;;
    esac
    if [[ "$(id -u)" == 0 ]]; then
        echo "Refusing to install Homebrew as root. Re-run as your normal user." >&2
        return 1
    fi
    echo "Running the official Homebrew installer…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || { echo "Homebrew install failed." >&2; return 1; }
    ensure_brew_on_path
}

# Offer to bootstrap MacPorts (signature-verified installer from lib/pkg.sh).
# Returns 0 if /opt/local/bin/port is available afterward.
bootstrap_macports() {
    [[ -x /opt/local/bin/port ]] && return 0
    echo
    echo "MacPorts was not found at /opt/local (needed to install probe tools)."
    if [[ "$INTERACTIVE" != 1 ]]; then
        echo "Non-interactive: skipping MacPorts install. Install it from"
        echo "https://www.macports.org/install.php, then re-run: $0 --deps-only"
        return 1
    fi
    local ans
    read -r -p "Install MacPorts now (signed installer, uses sudo)? [Y/n] " ans
    case "$ans" in
        [Nn]*) echo "Skipping MacPorts install."; return 1 ;;
    esac
    pkg_bootstrap || { echo "MacPorts install failed." >&2; return 1; }
    [[ -x /opt/local/bin/port ]]
}

# Make the selected package manager usable (bootstrapping it if missing).
ensure_pkg_mgr() {
    case "$PKG_MGR" in
        homebrew) ensure_brew_on_path || bootstrap_homebrew ;;
        macports) bootstrap_macports ;;
        *)        return 1 ;;
    esac
}

# Install generic package names through lib/pkg.sh. Homebrew is never run as
# root (if we happen to be root, e.g. --system via sudo, we refuse and skip);
# MacPorts installs go through sudo inside pkg_install.
pm_install() {
    if [[ "$PKG_MGR" == homebrew && "$(id -u)" == 0 ]]; then
        local g names=()
        for g in "$@"; do names+=("$(pkg_name "$g")"); done
        echo "Refusing to run 'brew install ${names[*]}' as root — skipping." >&2
        return 1
    fi
    pkg_install "$@"
}

# Generic package backing each probe command probesource may use (generic =
# Homebrew formula name; pkg_name maps it per manager). A command whose package
# is "not available" is skipped.
#   base system (do NOT install): whois dig tcpdump traceroute curl
#   no package: hping3 (source-built on MacPorts; skipped on Homebrew),
#               geoiplookup (always skipped — covered by the DNS fallback)
declare -A DEP_PKG=(
    [bash]="bash"
    [grep]="grep"
    [gsed]="gnu-sed"
    [gstat]="coreutils"
    [gawk]="gawk"
    [dialog]="dialog"
    [nmap]="nmap"
    [arp-scan]="arp-scan"
    [tshark]="wireshark"
    [p0f]="p0f"
    [mtr]="mtr"
    [masscan]="masscan"
    [sslscan]="sslscan"
    [ike-scan]="ike-scan"
    [smbclient]="samba"
    [pipx]="pipx"
)

# Ordered list of (command -> package) we try to satisfy. enum4linux-ng is
# handled separately via pipx (no formula/port / not on PyPI as a stable name).
DEP_CMDS=(bash grep gsed gstat gawk dialog nmap arp-scan tshark p0f mtr \
          masscan sslscan ike-scan smbclient pipx)

# No package. onesixtyone (and nbtscan on Homebrew) we build from their upstream
# GitHub repos (both validated building on Apple Silicon); MacPorts packages
# nbtscan, so there it is an ordinary dependency. hping3 has no Homebrew formula
# and geoiplookup is covered by the tool's Team Cymru DNS fallback — those stay
# skipped on Homebrew.
SRC_BUILD=(onesixtyone nbtscan)
NO_BUILD=(hping3 geoiplookup)
if [[ "$PKG_MGR" == macports ]]; then
    DEP_PKG[nbtscan]="nbtscan"
    DEP_CMDS+=(nbtscan)
    SRC_BUILD=(onesixtyone)
    # Intel/MacPorts: the ike-scan and hping3 ports do not build on the current
    # Apple clang toolchain, so build both from upstream with the fixes instead.
    # (Homebrew is untouched: ike-scan stays a formula, hping3 stays skipped.)
    # Drop ike-scan from the port list and move it + hping3 to the source build;
    # hping3 leaves NO_BUILD so only geoiplookup remains a graceful skip.
    unset 'DEP_PKG[ike-scan]'
    _f=(); for _c in "${DEP_CMDS[@]}"; do [[ "$_c" == ike-scan ]] || _f+=("$_c"); done
    DEP_CMDS=("${_f[@]}"); unset _f _c
    SRC_BUILD+=(ike-scan hping3)
    NO_BUILD=(geoiplookup)
fi

# Where built-from-source binaries land: prefer the Homebrew bin (alongside the
# other probe tools, always on probesource's PATH) when writable, else
# ~/.local/bin. Never the root-owned MacPorts prefix.
build_dest() {
    if [[ "$PKG_MGR" == homebrew && -w "$PKG_PREFIX/bin" ]]; then printf '%s' "$PKG_PREFIX/bin"
    else printf '%s' "$HOME/.local/bin"; fi
}

# Build a no-package tool from upstream git and install the binary onto PATH.
# Returns 0 only on a fully successful build+install. Needs git + a C toolchain
# (Xcode Command Line Tools); nbtscan additionally needs autoconf/automake.
build_from_source() {
    local tool="$1" dest tmp rc=1 bin
    dest="$(build_dest)"; mkdir -p "$dest"
    tmp="$(mktemp -d)" || return 1
    case "$tool" in
        onesixtyone)
            if git clone --depth 1 https://github.com/trailofbits/onesixtyone.git "$tmp/s" >/dev/null 2>&1 \
               && ( cd "$tmp/s" && { make >/dev/null 2>&1 || cc -o onesixtyone onesixtyone.c >/dev/null 2>&1; } && [[ -x onesixtyone ]] ); then
                cp -f "$tmp/s/onesixtyone" "$dest/onesixtyone" && chmod 755 "$dest/onesixtyone" && rc=0
            fi ;;
        nbtscan)
            have autoreconf || pm_install autoconf automake >/dev/null 2>&1 || true
            if git clone --depth 1 https://github.com/resurrecting-open-source-projects/nbtscan.git "$tmp/s" >/dev/null 2>&1 \
               && ( cd "$tmp/s" && ./autogen.sh >/dev/null 2>&1 && ./configure >/dev/null 2>&1 && make >/dev/null 2>&1 ); then
                bin="$tmp/s/nbtscan"; [[ -x "$bin" ]] || bin="$tmp/s/src/nbtscan"
                [[ -x "$bin" ]] && cp -f "$bin" "$dest/nbtscan" && chmod 755 "$dest/nbtscan" && rc=0
            fi ;;
        hping3)
            # MacPorts-only (gated via SRC_BUILD). Homebrew removed the formula and
            # the MacPorts port is a 2005 snapshot that no longer builds. Build
            # antirez's upstream: --no-tcl (probesource uses only CLI flags), pcap.h
            # from the macOS SDK and libpcap from the system — so the one fix needed
            # is repointing the Makefile's hardcoded -L/usr/local/lib (a Homebrew
            # ghost dir on a MacPorts box) at /opt/local. Installs hping/hping2 too.
            if git clone --depth 1 https://github.com/antirez/hping.git "$tmp/s" >/dev/null 2>&1 \
               && ( cd "$tmp/s" && ./configure --no-tcl >/dev/null 2>&1; \
                    sed -i '' 's#-L/usr/local/lib#-L/opt/local/lib#g' Makefile && \
                    make >/dev/null 2>&1 && [[ -x hping3 ]] ); then
                cp -f "$tmp/s/hping3" "$dest/hping3" && chmod 755 "$dest/hping3" \
                    && ln -sf hping3 "$dest/hping" && ln -sf hping3 "$dest/hping2" && rc=0
            fi ;;
        ike-scan)
            # MacPorts-only (gated via SRC_BUILD). The port and an unpatched build
            # both fail on Apple clang (C23): the bundled getopt.h's K&R
            # `extern int getopt ();` is read as getopt(void) and clashes with the
            # SDK declaration. Build under -std=gnu17 (appended, so it beats the
            # -std=gnu23 configure bakes in) against MacPorts openssl3, and
            # `make install` into ~/.local so the backoff/vendor-id data files land
            # beside the binary (ike-scan looks for them via a compiled-in path).
            local oss=/opt/local/libexec/openssl3 prefix
            prefix="$(cd "$dest/.." && pwd)"
            have autoreconf || pm_install autoconf automake libtool >/dev/null 2>&1 || true
            [[ -d "$oss" ]] || pm_install openssl3 >/dev/null 2>&1 || true
            if git clone --depth 1 https://github.com/royhills/ike-scan.git "$tmp/s" >/dev/null 2>&1 \
               && ( cd "$tmp/s" && autoreconf --install >/dev/null 2>&1 && \
                    ./configure --prefix="$prefix" --with-openssl="$oss" \
                        CPPFLAGS="-I$oss/include" LDFLAGS="-L$oss/lib" >/dev/null 2>&1 && \
                    make -j"$(sysctl -n hw.ncpu)" CFLAGS="-std=gnu17 -g -O2" >/dev/null 2>&1 && \
                    make install >/dev/null 2>&1 ) && [[ -x "$prefix/bin/ike-scan" ]]; then
                # make install places it at $prefix/bin (== $dest on MacPorts); copy
                # across only if a --prefix elsewhere ever made them differ.
                [[ "$prefix/bin/ike-scan" -ef "$dest/ike-scan" ]] || \
                    { cp -f "$prefix/bin/ike-scan" "$dest/ike-scan" && chmod 755 "$dest/ike-scan"; }
                rc=0
            fi ;;
    esac
    rm -rf "$tmp"
    return $rc
}

# Decide whether a given command is already satisfied. Most use command -v; the
# GNU userland ones need the *GNU* build specifically, and bash needs >= 4.
dep_present() {
    case "$1" in
        bash)  [[ -n "$(pkg_bash4)" ]] ;;
        grep)  gnu_grep_ok ;;
        gsed)  have gsed ;;
        gstat) have gstat ;;
        gawk)  have gawk ;;
        *)     have "$1" ;;
    esac
}

# The pipx of the active manager (prefix bin), else — on Homebrew only, as
# before — whatever pipx is on PATH.
pipx_bin() {
    local p; p="$(pkg_bin pipx)"
    [[ -z "$p" && "$PKG_MGR" == homebrew ]] && p="$(command -v pipx 2>/dev/null)"
    printf '%s' "$p"
}

# Install every missing dependency via the package manager, then enum4linux-ng
# via pipx. Prints a clear summary of installed / already-present / unavailable.
install_deps() {
    if [[ -z "$PKG_LIB" ]]; then
        echo
        echo "Cannot install dependencies: lib/pkg.sh from macOS-SecureNetwork-Suite"
        echo "was not found next to this installer. Run it from the suite checkout."
        return 1
    fi
    if ! ensure_pkg_mgr; then
        echo
        echo "Cannot install dependencies without $MGR_LABEL. Skipping dep install."
        echo "probesource will still run, but probe tools will be missing until"
        echo "$MGR_LABEL is installed and you re-run: $0 --deps-only"
        return 1
    fi

    local -a present=() to_install_cmds=() to_install_pkg=()
    local c pkg
    for c in "${DEP_CMDS[@]}"; do
        if dep_present "$c"; then
            present+=("$c")
        else
            pkg="${DEP_PKG[$c]}"
            to_install_cmds+=("$c")
            to_install_pkg+=("$pkg")
        fi
    done

    # enum4linux-ng: present if the command resolves (installed via pipx).
    local want_e4l=0
    have enum4linux-ng && present+=("enum4linux-ng") || want_e4l=1

    # Build-from-source tools that are missing (onesixtyone, nbtscan on Homebrew).
    local -a src_missing=()
    local t
    for t in "${SRC_BUILD[@]}"; do
        if have "$t"; then present+=("$t"); else src_missing+=("$t"); fi
    done

    # Dedupe the generic package list (wireshark/samba are single-package
    # multi-tool), and resolve this manager's names for display.
    local -a uniq_pkg=() mgr_names=()
    if ((${#to_install_pkg[@]})); then
        mapfile -t uniq_pkg < <(printf '%s\n' "${to_install_pkg[@]}" | awk 'NF && !seen[$0]++')
        for pkg in "${uniq_pkg[@]}"; do mgr_names+=("$(pkg_name "$pkg")"); done
    fi

    echo
    echo "Dependency status:"
    printf '  already present: %s\n' "${present[*]:-（none）}"
    if ((${#to_install_cmds[@]})); then
        printf '  to install:      %s\n' "${to_install_cmds[*]}"
        if [[ "$PKG_MGR" == macports ]]; then
            printf '  MacPorts ports:  %s\n' "${mgr_names[*]}"
        else
            printf '  brew formulae:   %s\n' "${mgr_names[*]}"
        fi
    else
        echo "  to install:      （none — all $MGR_LABEL deps satisfied）"
    fi
    (( want_e4l )) && echo "  via pipx:        enum4linux-ng (git+https://github.com/cddmp/enum4linux-ng.git)"
    (( ${#src_missing[@]} )) && printf '  built from git:  %s\n' "${src_missing[*]}"
    if [[ "$PKG_MGR" == macports ]]; then
        printf '  not installed:   %s (skipped by the tool)\n' "${NO_BUILD[*]}"
    else
        printf '  no brew formula: %s (skipped by the tool)\n' "${NO_BUILD[*]}"
    fi

    if (( ${#uniq_pkg[@]} == 0 && want_e4l == 0 && ${#src_missing[@]} == 0 )); then
        echo
        echo "All installable dependencies are already present. Nothing to do."
        return 0
    fi

    # Confirm the big install when interactive and not forced by --deps-only.
    if [[ "$INTERACTIVE" == 1 && "$DO_DEPS" != 1 ]]; then
        local ans
        echo
        read -r -p "Install the above now ($MGR_LABEL + source builds)? [Y/n] " ans
        case "$ans" in
            [Nn]*) echo "Skipping dependency install."; return 0 ;;
        esac
    fi

    # Install packages (brew as the normal user; port via sudo).
    if ((${#uniq_pkg[@]})); then
        echo
        if [[ "$PKG_MGR" == macports ]]; then
            pm_install "${uniq_pkg[@]}" || \
                echo "Some ports may have failed — see port output above." >&2
        else
            pm_install "${uniq_pkg[@]}" || \
                echo "Some formulae may have failed — see brew output above." >&2
        fi
    fi

    # enum4linux-ng via the active manager's pipx from upstream git.
    if (( want_e4l )); then
        local px; px="$(pipx_bin)"
        if [[ -z "$px" ]]; then pm_install pipx >/dev/null 2>&1 || true; px="$(pipx_bin)"; fi
        if [[ -n "$px" ]]; then
            echo
            echo "pipx install enum4linux-ng (from git)…"
            "$px" install "git+https://github.com/cddmp/enum4linux-ng.git" || \
                echo "enum4linux-ng install via pipx failed (non-fatal)." >&2
            "$px" ensurepath >/dev/null 2>&1 || true
        else
            echo "pipx unavailable — skipping enum4linux-ng." >&2
        fi
    fi

    # Build the no-package-but-buildable tools from upstream git.
    if ((${#src_missing[@]})); then
        if have git && { have cc || have clang || have gcc; }; then
            echo
            echo "Building from source (no $MGR_LABEL $PKG_WORD): ${src_missing[*]}"
            for t in "${src_missing[@]}"; do
                printf '  %-12s ' "$t"
                if build_from_source "$t"; then
                    echo "built → $(build_dest)/$t"
                else
                    echo "build failed (left for the tool to skip)"
                fi
            done
        else
            echo
            echo "Skipping source builds of ${src_missing[*]} — need git + a C compiler."
            echo "Install the Xcode Command Line Tools first:  xcode-select --install"
        fi
    fi

    # Post-install summary of what is now satisfied vs still missing.
    local -a still=()
    for c in "${DEP_CMDS[@]}"; do dep_present "$c" || still+=("$c"); done
    have enum4linux-ng || still+=("enum4linux-ng")
    for t in "${SRC_BUILD[@]}"; do have "$t" || still+=("$t"); done
    echo
    if (( ${#still[@]} == 0 )); then
        echo "All installable dependencies are now present."
    else
        echo "Still missing (may need a new shell for PATH, or a manual retry):"
        echo "  ${still[*]}"
    fi
    if [[ "$PKG_MGR" == macports ]]; then
        echo "Reminder — not installed and left to the tool's graceful skip: ${NO_BUILD[*]}"
        echo "  (geoiplookup uses probesource's Team Cymru DNS fallback.)"
    else
        echo "Reminder — no brew formula and left to the tool's graceful skip: ${NO_BUILD[*]}"
        echo "  (hping3 has no Homebrew formula; geoiplookup uses the DNS fallback.)"
    fi
}

# Decide whether to run the dependency install this invocation.
RUN_DEPS=0
case "$DO_DEPS" in
    1) RUN_DEPS=1 ;;
    0) RUN_DEPS=0 ;;
    auto)
        if [[ "$INTERACTIVE" == 1 ]]; then
            RUN_DEPS=1   # install_deps still prompts [Y/n] before the big install
        else
            RUN_DEPS=0   # non-interactive: copy only, skip deps
            echo
            echo "Non-interactive run — skipping dependency install."
            echo "Run '$0 --deps-only' later to install probe tools."
        fi ;;
esac

[[ "$RUN_DEPS" == 1 ]] && install_deps

# ── offer to launch ──────────────────────────────────────────────────────────
if [[ "$DO_COPY" == 1 ]]; then
    if [[ "$INTERACTIVE" == 1 ]] && command -v "$BIN" >/dev/null 2>&1; then
        echo
        read -r -p "Launch probesource now? [y/N] " ans
        [[ "$ans" == [Yy]* ]] && exec "$BIN"
    fi
    echo
    echo "Done. Run: $BIN"
else
    echo
    echo "Done (dependencies only — probesource script not copied)."
fi
