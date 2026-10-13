#!/bin/sh
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
# detect.sh — is this machine subject to the macOS 27 network-enumeration
# restriction? Read-only. Makes no changes.
#
# Exit 0 = AFFECTED (install the workaround)
# Exit 1 = NOT AFFECTED (do not install; if the agent is present, uninstall it)
# Exit 2 = could not determine
#
# MUST be run by an Apple-signed shell (/bin/sh). If you run this under
# Homebrew bash the "clean" baseline is tainted too and the comparison is
# meaningless.

set -u

PASS="  ok   "
FAIL="  FAIL "

echo "== macOS 27 network-enumeration check =="
echo "  host    : $(hostname)"
echo "  macOS   : $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "  arch    : $(uname -m)"
echo

# --- locate a non-Apple binary to test with -------------------------------
# Homebrew lives in /opt/homebrew on Apple silicon, /usr/local on Intel.
HB=""
for c in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$c" ] && { HB="$c"; break; }
done

if [ -z "$HB" ]; then
    echo "  No Homebrew bash found. Checking Homebrew python3 instead..."
    for c in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        [ -x "$c" ] && { HB="$c"; break; }
    done
    if [ -z "$HB" ]; then
        echo "  No non-Apple interpreter found to test with."
        echo "  If nothing here runs under Homebrew, this machine is not affected."
        exit 1
    fi
fi
echo "  test binary : $HB"
echo

# --- the measurement ------------------------------------------------------
# The taint requires a FORK. Running a script file forks; `bash -c '<one cmd>'`
# does not (bash execs in place), which is why a naive test can look clean.
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM

probe() {  # $1 = interpreter, $2 = output file
    case "$1" in
        *python3)
            "$1" -c "import subprocess,sys
def n(a):
    r=subprocess.run(a,capture_output=True)
    return len([l for l in r.stdout.decode(errors='replace').splitlines() if l.strip()])
open(sys.argv[1],'w').write('%d %d\n' % (
    n(['/usr/sbin/arp','-an']),
    len([l for l in subprocess.run(['/usr/sbin/netstat','-an'],capture_output=True).stdout.decode(errors='replace').splitlines() if l[:3] in ('tcp','udp')])))" "$2"
            ;;
        *)
            printf '#!%s\nprintf "%%s %%s\\n" "$(/usr/sbin/arp -an | grep -c .)" "$(/usr/sbin/netstat -an | grep -cE "^(tcp|udp)")" > "$1"\n' "$1" > "$TMP/p.sh"
            "$1" "$TMP/p.sh" "$2"
            ;;
    esac
}

probe "$HB" "$TMP/tainted" 2>/dev/null || true
printf '#!/bin/bash\nprintf "%%s %%s\\n" "$(/usr/sbin/arp -an | grep -c .)" "$(/usr/sbin/netstat -an | grep -cE "^(tcp|udp)")" > "$1"\n' > "$TMP/c.sh"
/bin/bash "$TMP/c.sh" "$TMP/clean" 2>/dev/null || true

[ -s "$TMP/tainted" ] && [ -s "$TMP/clean" ] || { echo "$FAIL could not measure"; exit 2; }

read -r T_ARP T_NET < "$TMP/tainted"
read -r C_ARP C_NET < "$TMP/clean"

printf "  %-22s %7s %7s\n" "command" "tainted" "clean"
printf "  %-22s %7s %7s\n" "arp -an"               "$T_ARP" "$C_ARP"
printf "  %-22s %7s %7s\n" "netstat -an (tcp/udp)" "$T_NET" "$C_NET"
echo

# --- verdict --------------------------------------------------------------
# Only meaningful if the clean baseline actually saw something. An empty clean
# ARP table just means no neighbours are cached right now -> inconclusive.
if [ "$C_ARP" -eq 0 ] && [ "$C_NET" -eq 0 ]; then
    echo "$FAIL clean baseline is empty too — inconclusive."
    echo "       Generate traffic (ping the gateway, open a browser) and re-run."
    exit 2
fi

AFFECTED=0
if [ "$C_ARP" -gt 0 ] && [ "$T_ARP" -eq 0 ]; then
    echo "$FAIL ARP table is blanked for non-Apple process trees"
    AFFECTED=1
elif [ "$C_ARP" -gt 0 ]; then
    echo "$PASS ARP table readable"
fi

if [ "$C_NET" -gt 0 ] && [ "$T_NET" -eq 0 ]; then
    echo "$FAIL netstat Internet sockets blanked for non-Apple process trees"
    AFFECTED=1
elif [ "$C_NET" -gt 0 ]; then
    echo "$PASS netstat Internet sockets readable"
fi

echo
if [ "$AFFECTED" -eq 1 ]; then
    echo "  VERDICT: AFFECTED — run ./install.sh"
    echo "  (lsof is unaffected and remains the correct substitute for netstat -an)"
    exit 0
fi

echo "  VERDICT: NOT AFFECTED — do not install."
echo "  If the workaround is already installed here, run ./uninstall.sh."
exit 1
