#!/bin/bash
# macOS-SecureNetwork-Suite — https://github.com/doug445/macOS-SecureNetwork-Suite
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# lib/common.sh — helpers shared by install.sh, lib/pkg.sh and the component installers.
# Sourced, never executed. Stock bash 3.2 only. Safe to source more than once.
#
#   red/grn/ylw MSG   coloured line        hdr MSG   section banner
#   die MSG           red ERROR + exit 1   have CMD  0 if CMD is on PATH
#   root_only_chain PATH
#       0 if PATH is not a symlink and PATH plus every directory above it is root-owned
#       and neither group- nor world-writable. This is the test anything root runs without
#       a password (a sudoers target, a LaunchDaemon program, the kill-switch helper and
#       its directory) must pass: a user who can write any link in the chain can replace
#       the file and run their own code as root.

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
hdr() { printf '\n\033[1;36m══ %s ══\033[0m\n' "$*"; }
die() { red "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

root_only_chain() {
    local p="$1" mode
    [ -e "$p" ] || return 1
    [ -L "$p" ] && return 1
    while :; do
        [ "$(/usr/bin/stat -f %u "$p")" = 0 ] || return 1
        mode=$(/usr/bin/stat -f %Lp "$p")
        case "$mode" in *[2367]?|*?[2367]) return 1 ;; esac   # group- or world-writable
        [ "$p" = / ] && return 0
        p=$(/usr/bin/dirname "$p")
    done
}
