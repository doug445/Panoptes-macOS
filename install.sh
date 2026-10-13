#!/bin/bash
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# macOS-SecureNetwork-Suite — install.sh
#
# One installer for the whole stack: dependencies (Homebrew, Cloudflare WARP,
# xbar, ProtonVPN, CLI tools, probesource's probe toolset), then every
# component. Idempotent — re-run any time to repair or update.
#
# Run as your normal user (NOT with sudo). It asks for your password once and
# keeps sudo alive for the root-owned steps; Homebrew must never run as root.
#
# USAGE
#   ./install.sh                     everything
#   ./install.sh --only warp,dns     just those components
#   ./install.sh --skip probesource  everything except those
#   ./install.sh --no-deps           skip dependency installation
#   ./install.sh --list              list components and exit
#   ./uninstall.sh                   reverse it
#
# COMPONENTS (run in this order)
#   deps         Homebrew (+ Xcode CLT), formulae, casks, probesource probe tools
#   firewall     Application Firewall on + stealth mode + logging (netwatch input)
#   dns          AdGuard DNS (no-log/no-ECS) + Quad9/Cloudflare fallback
#   sudoers      NOPASSWD rules for the menu's DNS toggle and netcheck
#   warp         WARP registration, tunnel_only mode, MASQUE, connect
#   killswitch   warp-killswitch helper + watchdog + xbar menu (security-toggle)
#   netfix       macOS 27 ARP-cache workaround (installs only if detect.sh says so)
#   netwatch     netwatch LaunchAgent + nettop
#   netcheck     netcheck one-shot report
#   probesource  probesource TUI
#   shell        checkdns + network aliases/functions for zsh
#   profiles     AdGuard DoH + Chromium DoH policy profiles (need your approval)
#   firefox      DoH/ECH/HTTPS-only/TLS user.js for every Firefox profile
set -u
export LC_ALL=C

# Run under Apple's bash whatever invoked us. `bash install.sh` resolves to Homebrew's
# bash on most Macs, and on macOS 27 everything forked from a non-Apple binary sees an
# empty ARP table — netfix's detect.sh would then measure a tainted baseline and the
# killswitch self-test would be blind. Re-exec once; the guard variable stops a loop.
if [ "${BASH:-}" != /bin/bash ] && [ -z "${SECURENET_REEXEC:-}" ] && [ -x /bin/bash ]; then
    SECURENET_REEXEC=1 exec /bin/bash "$0" "$@"
fi

HERE="$(cd "$(dirname "$0")" && pwd -P)"
C="$HERE/components"
ALL="deps firewall dns sudoers warp killswitch netfix netwatch netcheck probesource shell profiles firefox"

ADGUARD_DNS="94.140.14.140 94.140.14.141"
FALLBACK1="9.9.9.9"; FALLBACK2="1.1.1.1"
DOH_URL="https://dns.adguard-dns.com/dns-query"   # DoH target for Chromium (policy) and Firefox (TRR)
DOH_BOOTSTRAP="94.140.14.14"                       # its IP, for Firefox bootstrap
# per-machine overrides, also read by the menu-bar plugin, e.g. FALLBACK2=1.1.1.2 or an
# AdGuard DNS account resolver: DOH_URL=https://d.adguard-dns.com/dns-query/<device-id> DOH_BOOTSTRAP=94.140.14.49
DNS_CONF="$HOME/.config/macos-securenetwork-suite/dns.conf"
# shellcheck source=/dev/null
[ -f "$DNS_CONF" ] && . "$DNS_CONF"
FALLBACK_DNS="$FALLBACK1 $FALLBACK2"
render() { sed -e "s|@USER@|$USER|g" -e "s|@DOH_URL@|$DOH_URL|g" -e "s|@DOH_BOOTSTRAP@|$DOH_BOOTSTRAP|g" "$1"; }   # fill a .in template

FORMULAE="bash nmap arp-scan watch speedtest-go"
# Casks are skipped when their app is already in /Applications — brew refuses
# to adopt an app it did not install itself.
CASKS="cloudflare-warp xbar protonvpn"

SHELL_DIR="$HOME/.config/macos-securenetwork-suite"
BIN="$HOME/.local/bin"
STAMP="$(date +%Y%m%d-%H%M%S)"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
hdr() { printf '\n\033[1;36m══ %s ══\033[0m\n' "$*"; }
die() { red "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- args -------------------------------------------------------------------
ONLY=""; SKIP=""; NO_DEPS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --only)    ONLY=$(echo "${2:-}" | tr ',' ' '); shift ;;
        --skip)    SKIP=$(echo "${2:-}" | tr ',' ' '); shift ;;
        --no-deps) NO_DEPS=1 ;;
        --list)    echo "$ALL" | tr ' ' '\n'; exit 0 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "unknown arg: $1 (try --help)" ;;
    esac
    shift
done
[ "$NO_DEPS" -eq 1 ] && SKIP="$SKIP deps"
for c in $ONLY $SKIP; do case " $ALL " in *" $c "*) ;; *) die "unknown component: $c" ;; esac; done
want() {
    case " $SKIP " in *" $1 "*) return 1 ;; esac
    [ -z "$ONLY" ] && return 0
    case " $ONLY " in *" $1 "*) return 0 ;; esac
    return 1
}

# ---- preflight --------------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "macOS only."
[ "$(id -u)" -ne 0 ] || die "run as your normal user, not root (Homebrew refuses root)."
case "$(uname -m)" in arm64) BREW_PREFIX=/opt/homebrew ;; *) BREW_PREFIX=/usr/local ;; esac
hdr "macOS-SecureNetwork-Suite"
echo "  macOS $(sw_vers -productVersion) ($(uname -m)), user $USER, Homebrew prefix $BREW_PREFIX"
echo "  components: $(for c in $ALL; do want "$c" && printf '%s ' "$c"; done)"

# One password prompt, then keep the timestamp fresh for the whole run.
sudo -v || die "sudo is required."
( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT

FAILED=""
fail() { red "  ✗ $*"; FAILED="$FAILED\n  - $*"; }

brew_env() {
    [ -x "$BREW_PREFIX/bin/brew" ] && eval "$("$BREW_PREFIX/bin/brew" shellenv)"
    have brew
}

# Copy SRC to DEST, keeping a dated backup if DEST exists and differs.
put() {
    local src="$1" dest="$2" mode="${3:-755}"
    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
        cp -p "$dest" "$dest.bak.$STAMP" && ylw "  backed up $dest -> $dest.bak.$STAMP"
    fi
    cp "$src" "$dest" && chmod "$mode" "$dest"
}

# Bash-4 scripts are shipped with an Apple-silicon shebang; point it at this
# machine's Homebrew bash.
put_bash4() {
    local tmp
    tmp=$(mktemp)
    sed "1s|^#!/opt/homebrew/bin/bash|#!$BREW_PREFIX/bin/bash|" "$1" > "$tmp"
    put "$tmp" "$2" 755
    rm -f "$tmp"
}

# ---- deps -------------------------------------------------------------------
if want deps; then
    hdr "Dependencies"
    if ! brew_env; then
        ylw "  Homebrew not found — installing (also installs the Xcode Command Line Tools)"
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
            || die "Homebrew install failed."
        brew_env || die "Homebrew installed but brew is not on PATH."
    fi
    grn "  Homebrew: $(brew --version | head -1)"

    missing=""
    for f in $FORMULAE; do brew list --formula "$f" >/dev/null 2>&1 || missing="$missing $f"; done
    if [ -n "$missing" ]; then
        echo "  brew install$missing"
        brew install $missing || fail "brew install$missing"
    else
        grn "  formulae present: $FORMULAE"
    fi

    for cask in $CASKS; do
        case "$cask" in
            cloudflare-warp) app="Cloudflare WARP" ;;
            xbar)            app="xbar" ;;
            protonvpn)       app="ProtonVPN" ;;
        esac
        if [ -d "/Applications/$app.app" ]; then
            grn "  $app.app present"
        else
            echo "  brew install --cask $cask"
            brew install --cask "$cask" || fail "brew install --cask $cask"
        fi
    done

    if want probesource; then
        echo "  probesource probe toolset (nmap, tshark, p0f, masscan, ... + GNU userland)"
        bash "$C/probesource/install.sh" --deps-only </dev/null || fail "probesource dependencies"
    fi
else
    brew_env >/dev/null 2>&1 || true
fi

# ---- firewall ---------------------------------------------------------------
if want firewall; then
    hdr "Application Firewall"
    ALF=/usr/libexec/ApplicationFirewall/socketfilterfw
    sudo "$ALF" --setglobalstate on  >/dev/null
    sudo "$ALF" --setstealthmode on  >/dev/null
    sudo "$ALF" --setloggingmode on  >/dev/null
    "$ALF" --getglobalstate | sed 's/^/  /'
    "$ALF" --getstealthmode | sed 's/^/  /'
fi

# ---- dns --------------------------------------------------------------------
if want dns; then
    hdr "AdGuard DNS"
    # Same services the menu toggles; every other service keeps DHCP DNS.
    networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' | while IFS= read -r svc; do
        case "$svc" in
            Wi-Fi|"iPhone USB")
                sudo networksetup -setdnsservers "$svc" $ADGUARD_DNS $FALLBACK_DNS \
                    && grn "  $svc -> $(networksetup -getdnsservers "$svc" | tr '\n' ' ')" ;;
        esac
    done
    sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
fi

# ---- sudoers ----------------------------------------------------------------
if want sudoers; then
    hdr "sudoers rules"
    for name in securenet-dns securenet-netcheck; do
        tmp=$(mktemp)
        sed "s|@USER@|$USER|g" "$C/sudoers/$name.in" > "$tmp"
        if sudo /usr/sbin/visudo -cf "$tmp" >/dev/null; then
            sudo /usr/bin/install -m 0440 -o root -g wheel "$tmp" "/etc/sudoers.d/$name" \
                && grn "  /etc/sudoers.d/$name"
        else
            fail "generated /etc/sudoers.d/$name failed visudo — not installed"
        fi
        rm -f "$tmp"
    done
fi

# ---- warp -------------------------------------------------------------------
if want warp; then
    hdr "Cloudflare WARP"
    WARP=/usr/local/bin/warp-cli
    if [ ! -x "$WARP" ]; then
        fail "warp-cli not found (install the cloudflare-warp cask: run with the deps component)"
    else
        # Wait for the daemon a fresh install starts.
        for _ in 1 2 3 4 5 6 7 8 9 10; do "$WARP" --accept-tos status >/dev/null 2>&1 && break; sleep 2; done
        # WARP auto-updates delete the registration and reset the mode — this
        # is the same repair, and a no-op when it is already right.
        if "$WARP" --accept-tos registration show >/dev/null 2>&1; then
            grn "  registration present"
        else
            ylw "  no registration — creating a free consumer registration"
            "$WARP" --accept-tos registration new || fail "warp-cli registration new"
        fi
        "$WARP" --accept-tos mode tunnel_only            >/dev/null || fail "warp-cli mode tunnel_only"
        "$WARP" --accept-tos tunnel protocol set MASQUE  >/dev/null || fail "warp-cli tunnel protocol set MASQUE"
        if scutil --nc list 2>/dev/null | grep -i proton | grep -q Connected; then
            ylw "  ProtonVPN is connected — leaving WARP disconnected (they cannot run together)"
        else
            "$WARP" --accept-tos connect >/dev/null
            sleep 4
            trace=$(curl -s -m 8 https://www.cloudflare.com/cdn-cgi/trace | grep '^warp=')
            [ "$trace" = "warp=on" ] && grn "  connected: $trace" || ylw "  connect issued; trace says: ${trace:-unreachable}"
        fi
    fi
fi

# ---- killswitch (+ xbar menu) -------------------------------------------------
if want killswitch; then
    hdr "warp-killswitch + xbar menu"
    # The killswitch installer writes the menu plugin only where the folders exist.
    mkdir -p "$HOME/Library/Application Support/xbar/plugins" "$HOME/Documents/SwiftBar"
    # Apple's bash, never Homebrew's: on macOS 27 a Homebrew-rooted process reads an
    # empty ARP table, which would blind the installer's self-test (see netfix).
    sudo /bin/bash "$C/warp-killswitch/install.sh" --user "$USER" || fail "warp-killswitch install"
    [ -d /Applications/xbar.app ] && { pgrep -x xbar >/dev/null || open -g -a xbar; }
fi

# ---- netfix -----------------------------------------------------------------
if want netfix; then
    hdr "macOS 27 ARP-cache workaround"
    # Installs only when detect.sh measures the defect on this machine.
    /bin/sh "$C/macos27-netfix/install.sh" || fail "macos27-netfix install (see output above)"
fi

# ---- netwatch ---------------------------------------------------------------
if want netwatch; then
    hdr "netwatch"
    [ -x "$BREW_PREFIX/bin/bash" ] || fail "Homebrew bash missing — netwatch needs bash >= 4"
    put_bash4 "$C/netwatch/netwatch" "$BIN/netwatch"
    put_bash4 "$C/netwatch/nettop"   "$BIN/nettop"
    mkdir -p "$HOME/.local/share/netwatch" "$HOME/Library/LaunchAgents"
    PL="$HOME/Library/LaunchAgents/com.netwatch.plist"
    tmp=$(mktemp)
    sed -e "s|@BASH@|$BREW_PREFIX/bin/bash|" -e "s|@HOME@|$HOME|g" "$C/netwatch/com.netwatch.plist.in" > "$tmp"
    plutil -lint "$tmp" >/dev/null || fail "generated com.netwatch.plist is invalid"
    put "$tmp" "$PL" 644; rm -f "$tmp"
    launchctl bootout "gui/$(id -u)/com.netwatch" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$PL" && grn "  com.netwatch loaded" || fail "launchctl bootstrap com.netwatch"
    grn "  $BIN/netwatch, $BIN/nettop"
fi

# ---- netcheck ---------------------------------------------------------------
if want netcheck; then
    hdr "netcheck"
    put_bash4 "$C/netcheck/netcheck" "$BIN/netcheck" && grn "  $BIN/netcheck"
fi

# ---- probesource ------------------------------------------------------------
if want probesource; then
    hdr "probesource"
    bash "$C/probesource/install.sh" --no-deps </dev/null || fail "probesource install"
fi

# ---- shell ------------------------------------------------------------------
if want shell; then
    hdr "zsh: checkdns + network aliases"
    put "$C/checkdns/checkdns.zsh"        "$SHELL_DIR/checkdns.zsh" 644
    put "$C/checkdns/network-aliases.zsh" "$SHELL_DIR/network-aliases.zsh" 644
    MARK="# >>> macOS-SecureNetwork-Suite >>>"
    if grep -qF "$MARK" "$HOME/.zshrc" 2>/dev/null; then
        grn "  ~/.zshrc already sources the suite"
    elif grep -q '^checkdns()' "$HOME/.zshrc" 2>/dev/null; then
        ylw "  ~/.zshrc already defines checkdns() itself — not adding a second copy."
        ylw "  (files are in $SHELL_DIR if you want to switch to sourcing them)"
    else
        {
            echo ""
            echo "$MARK"
            echo "for _f in \"$SHELL_DIR\"/*.zsh(N); do source \"\$_f\"; done; unset _f"
            echo "# <<< macOS-SecureNetwork-Suite <<<"
        } >> "$HOME/.zshrc"
        grn "  added source block to ~/.zshrc (open a new shell)"
    fi
    case ":$PATH:" in *":$BIN:"*) ;; *) ylw "  NOTE: $BIN is not on PATH — add: export PATH=\"$BIN:\$PATH\"" ;; esac
fi

# ---- profiles ---------------------------------------------------------------
if want profiles; then
    hdr "DoH configuration profiles"
    # `profiles show` without sudo lists this user's profiles, with sudo the
    # device-level ones. A DNS-settings payload is only valid at device level
    # (mdmclient: "profile must be scoped to system"), so AdGuard-DoH carries
    # PayloadScope=System and Device Management asks for an admin password.
    # The paths must not exist yet: `profiles show -output` silently writes
    # nothing to a file that already exists.
    prof_tmp=$(mktemp -d); usr_plist="$prof_tmp/user.plist"; sys_plist="$prof_tmp/system.plist"
    /usr/bin/profiles show -type configuration -output "$usr_plist" >/dev/null 2>&1 || :
    sudo /usr/bin/profiles show -type configuration -output "$sys_plist" >/dev/null 2>&1 || :
    installed_ids=$(cat "$usr_plist" "$sys_plist" 2>/dev/null | grep -A1 -F '<key>ProfileIdentifier</key>' | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p')
    # name of an installed device profile that already sets encrypted DNS (DoH/DoT)
    encrypted_dns_profile() {
        i=0
        while name=$(/usr/libexec/PlistBuddy -c "Print :_computerlevel:$i:ProfileDisplayName" "$sys_plist" 2>/dev/null); do
            j=0
            while ptype=$(/usr/libexec/PlistBuddy -c "Print :_computerlevel:$i:ProfileItems:$j:PayloadType" "$sys_plist" 2>/dev/null); do
                if [ "$ptype" = com.apple.dnsSettings.managed ]; then
                    case "$(/usr/libexec/PlistBuddy -c "Print :_computerlevel:$i:ProfileItems:$j:PayloadContent:DNSSettings:DNSProtocol" "$sys_plist" 2>/dev/null)" in
                        HTTPS|TLS) printf '%s\n' "$name"; return 0 ;;
                    esac
                fi
                j=$((j + 1))
            done
            i=$((i + 1))
        done
        return 1
    }
    # both profiles are templates (login name, DoH target) rendered next to the shell files
    render_dir="$HOME/.config/macos-securenetwork-suite"; mkdir -p "$render_dir"
    for p in AdGuard-DoH chrome-doh-policy; do
        f="$render_dir/$p.mobileconfig"
        render "$C/profiles/$p.mobileconfig.in" > "$f"
        id=$(/usr/libexec/PlistBuddy -c 'Print :PayloadIdentifier' "$f")
        if printf '%s\n' "$installed_ids" | grep -qxF "$id"; then
            if [ "$p" = chrome-doh-policy ] && ! grep -qF "<string>$DOH_URL</string>" "$usr_plist"; then
                open "$f"
                ylw "  $p installed but its DoH target changed — re-approve it in System Settings › General › Device Management"
            else
                grn "  $p installed ($id)"
            fi
        elif [ "$p" = AdGuard-DoH ] && other=$(encrypted_dns_profile); then
            grn "  $p not needed — encrypted DNS is already set by the device profile \"$other\""
            echo "    (to switch to AdGuard public DoH, remove that profile and open $f)"
        else
            open "$f"
            ylw "  $p queued — approve it in System Settings › General › Device Management"
            [ "$p" = AdGuard-DoH ] && echo "    (device-level profile: Device Management asks for an administrator password)"
        fi
    done
    rm -rf "$prof_tmp"
fi

# ---- firefox ----------------------------------------------------------------
if want firefox; then
    hdr "Firefox user.js"
    FF="$HOME/Library/Application Support/Firefox/Profiles"
    if [ ! -d "$FF" ]; then
        ylw "  no Firefox profiles — skipped"
    else
        FMARK="// >>> macOS-SecureNetwork-Suite >>>"; FEND="// <<< macOS-SecureNetwork-Suite <<<"
        ff_tmp=$(mktemp -d); render "$C/firefox/user.js.in" > "$ff_tmp/block"
        for prof in "$FF"/*/; do
            uj="${prof}user.js"
            if grep -qF "$FMARK" "$uj" 2>/dev/null; then
                awk -v s="$FMARK" -v e="$FEND" '$0==s{f=1;next} $0==e{f=0} f' "$uj" > "$ff_tmp/current"
                if cmp -s "$ff_tmp/current" "$ff_tmp/block"; then
                    grn "  $(basename "$prof"): already configured"
                else
                    # replace the marked block in place (DoH target or prefs changed)
                    awk -v s="$FMARK" -v e="$FEND" -v blk="$ff_tmp/block" '
                        $0==s { print; while ((getline l < blk) > 0) print l; f=1; next }
                        $0==e { f=0 }
                        !f' "$uj" > "$ff_tmp/new" && /bin/cp -f "$ff_tmp/new" "$uj"
                    grn "  $(basename "$prof"): user.js block updated (restart Firefox)"
                fi
            elif grep -qF 'network.trr.uri' "$uj" 2>/dev/null; then
                ylw "  $(basename "$prof"): has its own DoH settings — left alone"
            else
                { echo "$FMARK"; cat "$ff_tmp/block"; echo "$FEND"; } >> "$uj"
                grn "  $(basename "$prof"): user.js updated (restart Firefox)"
            fi
        done
        rm -rf "$ff_tmp"
    fi
fi

# ---- summary ----------------------------------------------------------------
hdr "Verify"
[ -x /usr/local/bin/warp-killswitch ] && sudo /usr/local/bin/warp-killswitch status 2>/dev/null | sed 's/^/  /'
[ -f "$HOME/Library/LaunchAgents/com.netwatch.arpcache.plist" ] && /bin/sh "$C/macos27-netfix/verify.sh" | sed 's/^/  /'
echo
if [ -n "$FAILED" ]; then
    red "Finished with problems:"; printf '%b\n' "$FAILED"; exit 1
fi
grn "macOS-SecureNetwork-Suite installed."
echo "  Menu bar: xbar › Security Toggle     CLI: netcheck · checkdns · nettop · probesource"
