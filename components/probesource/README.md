# probesource (macOS)

`probesource` is an interactive terminal (dialog/whiptail) tool for investigating
the **source** of a firewall drop, a recent probe, or an active connection. You
pick a target IP from a menu of live sources — pf / unified-log firewall history,
a netwatch drop log, current connections, or manual entry — then run passive,
active, or aggressive reconnaissance tactics against it. Results stream into
per-target and rolling master logs, a live progress gauge tracks long sweeps, and
an "identification summary" parses a log back into best-known fields (rDNS, ASN,
org, MAC/vendor, OS, open ports, SMB/SNMP/IKE, and more).

It's built for **defensive, authorized network investigation** — figuring out who
just knocked on your firewall and what they are, on networks you run.

> ### Authorized use only
> Active and aggressive tactics send packets **to the target** (nmap, masscan,
> arp-scan, hping3, nping, sslscan, SMB/SNMP/IKE probes). Only ever run these
> against hosts and networks you **own or are explicitly authorized to test**.
> Scanning third-party systems without permission may be illegal. The passive
> modes are safe; everything past them is not stealthy and not consequence-free.

## Quick start

```sh
./install.sh      # copies probesource to ~/.local/bin (per-user, no sudo)
probesource       # launch the TUI
```

- **sudo** — most active tactics need root (tcpdump, tshark, p0f, arp-scan, nmap
  SYN/OS scans, mtr, masscan, hping3, ike-scan, and `pfctl` state/table
  inspection, plus firewall history via `log show`). `probesource` caches the
  sudo credential once at startup rather than prompting per-tactic.
  `enum4linux-ng` runs unprivileged.
- **Homebrew** — the tool bootstraps its probe tools and GNU userland via
  `brew` on first launch (never as root). Install Homebrew from
  <https://brew.sh> first if you don't have it.

## Requirements

- **macOS on Apple Silicon or Apple T2 Intel** (the two supported hardware
  classes; Homebrew prefix is auto-detected at `/opt/homebrew` or `/usr/local`).
- **Homebrew** — the sole package manager used; it's how every probe tool and the
  GNU userland get installed.
- **bash >= 4** — macOS ships bash 3.2, which `probesource` needs to exceed, so
  the script **re-execs itself under Homebrew bash** (`brew install bash`). The
  installer warns if it can't find a modern bash.
- **A GNU userland shim** — `grep` (PCRE `-P`), `gnu-sed` (`\s`), `coreutils`
  (`gstat`, `timeout`, `date`), and `gawk` (IGNORECASE). `probesource` prepends
  the Homebrew `gnubin` directories to `PATH` and auto-installs any missing
  backing formula at startup, so the script's pervasive Linux-style text
  processing behaves identically.

## macOS port — what changed from Linux

The Linux original targets iproute2 / systemd / netfilter with apt/dnf/pacman.
The macOS port maps each of those onto native equivalents:

| Concern | Linux original | macOS port |
| --- | --- | --- |
| Package manager | `apt` / `dnf` / `pacman` (+ AUR, source builds) | **Homebrew** (never run as root) |
| Routing / neighbors | `ip route`, `ip neigh` | `route -n get`, `arp`, `ndp` |
| Socket / connection table | `ss -tunap` | `lsof -nP -i`, `netstat -an` |
| Firewall / kernel drop log | `journalctl -k` (UFW BLOCK / kernel) | `log show --last …` + `/var/log/appfirewall.log` |
| Connection tracking | `conntrack -L` | `pfctl -s states` |
| IP set membership | `ipset test` | pf tables — `pfctl -s Tables` / `pfctl -t <t> -T test` |
| Capture interface | `-i any` pseudo-interface | primary interface from the default route (no `any` on macOS) |
| Text processing | native `grep -P`, `sed \s`, `stat -c`, `timeout` | GNU userland shim (Homebrew grep/gnu-sed/coreutils/gawk first on `PATH`) |
| Shell | native bash 4+ | re-exec under Homebrew bash >= 4 (macOS ships 3.2) |
| OUI / MAC vendor DB | system IEEE `oui.txt` (hwdata) | downloaded cache + arp-scan/nmap databases (no system IEEE file on macOS); MAC octets zero-padded since `arp`/`ndp` drop leading zeros |

### Tools with no Homebrew formula

A few tools the Linux version installs from repos/AUR/source have no Homebrew
formula. The installer **builds two of them from their upstream GitHub repos**;
the rest are **gated and skipped cleanly** (the tactic still logs BEGIN/END so
progress accounting stays correct) rather than erroring:

- **onesixtyone** (SNMP) — **built from [trailofbits/onesixtyone](https://github.com/trailofbits/onesixtyone)**
  by `install.sh` (a one-file `cc` build). Enables the SNMP community-string tactic.
- **nbtscan** (NetBIOS) — **built from [resurrecting-open-source-projects/nbtscan](https://github.com/resurrecting-open-source-projects/nbtscan)**
  by `install.sh` (autotools; it also pulls `autoconf`/`automake`). Enables the
  NetBIOS name scan in the SMB tactic, which otherwise falls back to the built-in
  `smbutil view` plus `smbclient` (from the `samba` formula).
- **hping3** — no formula and **removed from Homebrew** (unmaintained upstream);
  the stealth-sweep and elicitor-flood tactics are skipped.
- **geoiplookup** (`geoip-bin`) — no formula, but the **GeoIP/ASN tactic has a
  built-in Team Cymru DNS fallback**, so ASN/GeoIP lookups still work for IPv4.

Source builds need `git` + the Xcode Command Line Tools (`xcode-select --install`);
if those are absent the installer skips the builds and says so. If Homebrew ships
a formula for any of these later, dropping the tool on `PATH` re-enables its
tactic automatically.

### macOS-native tactics (no Linux equivalent)

The port adds passive tactics that use macOS-only facilities:

- **`reach`** — `scutil` reachability + `dscacheutil` resolver-cache identity.
- **`bonjour`** — active Bonjour/mDNS discovery via `dns-sd` (LAN targets only).
- **`ppcap`** — `pktap` process-attributed capture: shows *which local process*
  is talking to the target (no Linux `tcpdump` equivalent).
- **`pflog`** — live pf allow/deny decisions from `pflog0` (needs `log` on your
  pf rules; skips cleanly otherwise).
- **`pfrules`** — the pf ruleset context deciding the target's fate.
- **`nettop`** — per-process live-socket snapshot for the target.

Long/relentless sweeps are wrapped in `caffeinate` so the Mac won't sleep
mid-scan, and a desktop notification (`osascript`) fires when a background scan
finishes.

## Usage overview

### Main menu

| Key | Action |
| --- | --- |
| **I** | Investigate a new target |
| **R** | Resume / view running scans (background scans keep going after you detach) |
| **L** | Browse / read past logs (view, live-tail, delete) |
| **S** | Identification summary from a saved log |
| **M** | Tail the master rolling log live |
| **U** | Update the OUI vendor database (downloads a fresh IEEE `oui.txt` into the cache) |
| **D** | Check / install probe-tool dependencies via Homebrew |
| **Q** | Quit |

### Picking a target

From **Investigate**, choose a target source: top drop sources (netwatch log),
recent firewall drops (pf / unified log, last hour), active connections (`lsof`),
or manual entry (auto-detect v4/v6, IPv4-only, or IPv6-only).

### Investigation modes

- **Single pick** — check off one or more individual tactics from the full list.
- **All passive** — recon only, **no packets sent to the target** (whois, rDNS,
  GeoIP/ASN, firewall + netwatch history, ARP/NDP + OUI vendor, live connections,
  pf state, pf table membership, tcpdump/tshark capture, p0f fingerprint).
- **All active mild** — passive plus ICMP ping, traceroute/mtr, and nmap quick.
- **Full single pass** — every passive + active + aggressive tactic once.
- **Relentless (escalating rounds 1–6)** — repeats with growing intensity: round
  1 passive, round 2 adds ping/trace/nmap, round 3 adds service enum
  (SMB/enum4linux/SNMP/IKE/SSL/OS), round 4 adds UDP/vuln/masscan/hping/nping,
  rounds 5–6 add full nmap and repeated hping3 elicitor floods across ports.

While a sweep runs you can resume the live tail, view a snapshot, watch the
progress gauge, generate an identification summary, stop the scan, or detach and
let it finish in the background.

### Where logs live

Everything is written under **`~/.local/share/probesource/`**:

- `master.log` — rolling log across every session.
- `<ip>-<timestamp>.log` — one per investigation session.
- `oui-fresh.txt` — downloaded IEEE OUI cache (menu action **U**).
- `state/` — per-scan progress state for background scans.
- `dep-install.log`, `gnu-install.log` — Homebrew bootstrap output.

## Installer

`install.sh` just drops the single self-contained `probesource` script onto your
`PATH` — the tool keeps all state under `~/.local/share/probesource` and never
references the repo at runtime. Dependency bootstrapping is done by the tool
itself on first launch (menu **D** or the startup check), not by the installer.

| Flag | Effect |
| --- | --- |
| *(none)* | Install to `~/.local/bin` (per-user, no sudo) |
| `--system` | Install to `/usr/local/bin` (all users, uses sudo) |
| `--prefix DIR` | Install into `DIR/probesource` |
| `--uninstall` | Remove an installed copy (leaves `~/.local/share/probesource` intact) |
| `-h`, `--help` | Print usage |

The installer also runs a few sanity checks — it warns if Homebrew is missing, if
no bash >= 4 is available, or if the install directory isn't on your `PATH` — and
offers to launch `probesource` once (in an interactive terminal) to check and
install probe tools.
