#!/usr/bin/env bash
# install.sh (macOS) — install the probesource probe driver onto this Mac and
# bootstrap the dependencies it needs.
#
# probesource is a single self-contained bash script: it keeps all state under
# ~/.local/share/probesource and never references this repo at runtime, so
# "installing" just means dropping the one file onto your PATH. This wrapper
# does that idempotently (locating probesource next to itself, so it works from
# the repo or a USB copy) and can also install probesource's Homebrew-backed
# dependencies, arch-aware for Apple Silicon and Apple T2 Intel Macs.
#
# Usage:
#   ./install.sh              # install to ~/.local/bin (per-user, no sudo)
#   ./install.sh --system     # install to /usr/local/bin (all users, sudo)
#   ./install.sh --prefix DIR # install into DIR/<binary>
#   ./install.sh --uninstall  # remove a previously installed copy
#   ./install.sh --deps-only  # install/bootstrap dependencies only (no copy)
#   ./install.sh --no-deps    # copy the script only, skip dependency install
#
# Platform detection: reads `uname -m` (arm64 = Apple Silicon → Homebrew under
# /opt/homebrew; x86_64 = Intel → /usr/local) and separately checks for the
# Apple T2 security chip. Dependencies are installed via Homebrew as the normal
# user — never as root. Homebrew itself can be bootstrapped if missing.
#
# Dependencies installed (all via Homebrew unless noted):
#   bash>=4, grep, gnu-sed, coreutils, gawk (GNU userland the parser needs),
#   dialog, nmap, arp-scan, wireshark (tshark), p0f, mtr, masscan, sslscan,
#   ike-scan, samba (smbclient), pipx, and enum4linux-ng (via pipx from git).
# whois/dig/tcpdump/traceroute/curl are base-system and are not installed.
# onesixtyone + nbtscan have no brew formula but are built from their upstream
# GitHub repos (needs git + Xcode Command Line Tools; nbtscan also pulls
# autoconf/automake). hping3 (unmaintained, removed from Homebrew) and
# geoiplookup (covered by a Team Cymru DNS fallback) stay skipped by the tool.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/probesource"
BIN=probesource

DEST_DIR="$HOME/.local/bin"
USE_SUDO=0
DO_UNINSTALL=0
DO_COPY=1        # copy the probesource script onto PATH
DO_DEPS=auto     # auto: prompt when interactive; 1: force; 0: skip

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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

# ── platform / architecture detection ────────────────────────────────────────
# arm64  → Apple Silicon, Homebrew prefix /opt/homebrew
# x86_64 → Intel, Homebrew prefix /usr/local (T2 Macs are Intel with the Apple
#          T2 security chip; plain pre-T2 Intel Macs use the same prefix).
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  BREW_PREFIX=/opt/homebrew ;;
    x86_64) BREW_PREFIX=/usr/local ;;
    *)      BREW_PREFIX=/usr/local ;;   # unknown; assume Intel layout
esac

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
    echo "Homebrew prefix:   $BREW_PREFIX"
    [[ "$PLATFORM" == intel ]] && \
        echo "Note: pre-T2 Intel Mac — proceeding with the /usr/local Homebrew prefix."
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
    echo "(Homebrew formulae installed for probesource were left intact.)"
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
gnu_grep_ok() {
    [[ -x "$BREW_PREFIX/opt/grep/libexec/gnubin/grep" ]] && return 0
    command -v ggrep >/dev/null 2>&1 && return 0
    grep --version 2>/dev/null | grep -qi 'gnu grep'
}

# Ensure Homebrew's bin dir is on PATH for the rest of this script, using the
# arch-correct prefix. brew is never invoked under sudo.
ensure_brew_on_path() {
    if [[ -x "$BREW_PREFIX/bin/brew" ]]; then
        eval "$("$BREW_PREFIX/bin/brew" shellenv)" 2>/dev/null || \
            export PATH="$BREW_PREFIX/bin:$PATH"
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
    echo "Homebrew was not found at $BREW_PREFIX (needed to install probe tools)."
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

# brew wrapper — never run as root. If we happen to be root (e.g. --system via
# sudo), we cannot safely invoke brew, so callers must gate on this.
brewsafe() {
    if [[ "$(id -u)" == 0 ]]; then
        echo "Refusing to run 'brew $*' as root — skipping." >&2
        return 1
    fi
    brew "$@"
}

# Homebrew formulae backing each probe command probesource may use. A command
# with an empty value is base-system or has no formula and is skipped.
#   base system (do NOT install): whois dig tcpdump traceroute curl
#   no brew formula (skipped by the tool): nbtscan onesixtyone hping3 geoiplookup
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

# Ordered list of (command -> formula) we try to satisfy. enum4linux-ng is
# handled separately via pipx (no brew formula / not on PyPI as a stable name).
DEP_CMDS=(bash grep gsed gstat gawk dialog nmap arp-scan tshark p0f mtr \
          masscan sslscan ike-scan smbclient pipx)

# No Homebrew formula. onesixtyone + nbtscan we build from their upstream GitHub
# repos (both validated building on Apple Silicon); hping3 is unmaintained and
# was removed from Homebrew, and geoiplookup is covered by the tool's Team Cymru
# DNS fallback — those two stay skipped.
SRC_BUILD=(onesixtyone nbtscan)
NO_BUILD=(hping3 geoiplookup)

# Where built-from-source binaries land: prefer the Homebrew bin (alongside the
# other probe tools, always on probesource's PATH) when writable, else ~/.local/bin.
build_dest() {
    if [[ -w "$BREW_PREFIX/bin" ]]; then printf '%s' "$BREW_PREFIX/bin"
    else printf '%s' "$HOME/.local/bin"; fi
}

# Build a no-formula tool from upstream git and install the binary onto PATH.
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
            have autoreconf || brewsafe install autoconf automake >/dev/null 2>&1 || true
            if git clone --depth 1 https://github.com/resurrecting-open-source-projects/nbtscan.git "$tmp/s" >/dev/null 2>&1 \
               && ( cd "$tmp/s" && ./autogen.sh >/dev/null 2>&1 && ./configure >/dev/null 2>&1 && make >/dev/null 2>&1 ); then
                bin="$tmp/s/nbtscan"; [[ -x "$bin" ]] || bin="$tmp/s/src/nbtscan"
                [[ -x "$bin" ]] && cp -f "$bin" "$dest/nbtscan" && chmod 755 "$dest/nbtscan" && rc=0
            fi ;;
    esac
    rm -rf "$tmp"
    return $rc
}

# Decide whether a given command is already satisfied. Most use command -v; the
# GNU userland ones need the *GNU* build specifically, and bash needs >= 4.
dep_present() {
    case "$1" in
        bash)  [[ -x "$BREW_PREFIX/bin/bash" ]] && \
                   "$BREW_PREFIX/bin/bash" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null ;;
        grep)  gnu_grep_ok ;;
        gsed)  have gsed ;;
        gstat) have gstat ;;
        gawk)  have gawk ;;
        *)     have "$1" ;;
    esac
}

# Install every missing dependency via Homebrew (as the user), then enum4linux-ng
# via pipx. Prints a clear summary of installed / already-present / unavailable.
install_deps() {
    if ! ensure_brew_on_path; then
        if ! bootstrap_homebrew; then
            echo
            echo "Cannot install dependencies without Homebrew. Skipping dep install."
            echo "probesource will still run, but probe tools will be missing until"
            echo "Homebrew is installed and you re-run: $0 --deps-only"
            return 1
        fi
    fi

    local -a present=() to_install_cmds=() to_install_fmla=()
    local c fmla
    for c in "${DEP_CMDS[@]}"; do
        if dep_present "$c"; then
            present+=("$c")
        else
            fmla="${DEP_PKG[$c]}"
            to_install_cmds+=("$c")
            to_install_fmla+=("$fmla")
        fi
    done

    # enum4linux-ng: present if the command resolves (installed via pipx).
    local want_e4l=0
    have enum4linux-ng && present+=("enum4linux-ng") || want_e4l=1

    # Build-from-source tools that are missing (onesixtyone, nbtscan).
    local -a src_missing=()
    local t
    for t in "${SRC_BUILD[@]}"; do
        if have "$t"; then present+=("$t"); else src_missing+=("$t"); fi
    done

    # Dedupe the formula list (nmap backs nmap+nping, etc. — not an issue here,
    # but wireshark/samba are single-formula multi-tool).
    local -a uniq_fmla=()
    if ((${#to_install_fmla[@]})); then
        mapfile -t uniq_fmla < <(printf '%s\n' "${to_install_fmla[@]}" | awk 'NF && !seen[$0]++')
    fi

    echo
    echo "Dependency status:"
    printf '  already present: %s\n' "${present[*]:-（none）}"
    if ((${#to_install_cmds[@]})); then
        printf '  to install:      %s\n' "${to_install_cmds[*]}"
        printf '  brew formulae:   %s\n' "${uniq_fmla[*]}"
    else
        echo "  to install:      （none — all Homebrew deps satisfied）"
    fi
    (( want_e4l )) && echo "  via pipx:        enum4linux-ng (git+https://github.com/cddmp/enum4linux-ng.git)"
    (( ${#src_missing[@]} )) && printf '  built from git:  %s\n' "${src_missing[*]}"
    printf '  no brew formula: %s (skipped by the tool)\n' "${NO_BUILD[*]}"

    if (( ${#uniq_fmla[@]} == 0 && want_e4l == 0 && ${#src_missing[@]} == 0 )); then
        echo
        echo "All installable dependencies are already present. Nothing to do."
        return 0
    fi

    # Confirm the big install when interactive and not forced by --deps-only.
    if [[ "$INTERACTIVE" == 1 && "$DO_DEPS" != 1 ]]; then
        local ans
        echo
        read -r -p "Install the above now (Homebrew + source builds)? [Y/n] " ans
        case "$ans" in
            [Nn]*) echo "Skipping dependency install."; return 0 ;;
        esac
    fi

    # Install brew formulae (as the normal user).
    if ((${#uniq_fmla[@]})); then
        echo
        echo "brew install ${uniq_fmla[*]}"
        brewsafe install "${uniq_fmla[@]}" || \
            echo "Some formulae may have failed — see brew output above." >&2
    fi

    # enum4linux-ng via pipx from upstream git.
    if (( want_e4l )); then
        if ! have pipx; then brewsafe install pipx >/dev/null 2>&1 || true; fi
        if have pipx; then
            echo
            echo "pipx install enum4linux-ng (from git)…"
            pipx install "git+https://github.com/cddmp/enum4linux-ng.git" || \
                echo "enum4linux-ng install via pipx failed (non-fatal)." >&2
            pipx ensurepath >/dev/null 2>&1 || true
        else
            echo "pipx unavailable — skipping enum4linux-ng." >&2
        fi
    fi

    # Build the no-formula-but-buildable tools from upstream git.
    if ((${#src_missing[@]})); then
        if have git && { have cc || have clang || have gcc; }; then
            echo
            echo "Building from source (no Homebrew formula): ${src_missing[*]}"
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
    echo "Reminder — no brew formula and left to the tool's graceful skip: ${NO_BUILD[*]}"
    echo "  (hping3 is unmaintained / removed from Homebrew; geoiplookup uses the DNS fallback.)"
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
