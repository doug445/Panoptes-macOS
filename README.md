# macOS-SecureNetwork-Suite — private DNS, a WARP kill-switch and network intrusion detection for macOS

[![lint](https://github.com/doug445/macOS-SecureNetwork-Suite/actions/workflows/lint.yml/badge.svg)](https://github.com/doug445/macOS-SecureNetwork-Suite/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Apple Silicon macOS 14–27 | Intel and OCLP macOS 11+](https://img.shields.io/badge/platform-Apple%20Silicon%2014%E2%80%9327%20%7C%20Intel%20%2B%20OCLP%2011%2B-lightgrey.svg)](#requirements)
[![Shell: bash 3.2 + zsh](https://img.shields.io/badge/shell-bash%203.2%20%2B%20zsh-4EAA25.svg)](#notes-and-caveats)
[![DNS: AdGuard DoH | Quad9 | Cloudflare](https://img.shields.io/badge/DNS-AdGuard%20DoH%20%7C%20Quad9%20%7C%20Cloudflare-blue.svg)](#dns--encrypted-filtered-leak-free)
[![Tunnel: Cloudflare WARP + ProtonVPN](https://img.shields.io/badge/tunnel-Cloudflare%20WARP%20%2B%20ProtonVPN-F38020.svg)](#the-menu-bar-toggle)

**A macOS network security suite: encrypted, filtered DNS (AdGuard over DoH with
DNSSEC fallbacks), Encrypted Client Hello in every browser that can do it, a
Cloudflare WARP tunnel with a verified kill-switch and self-healing watchdog, a
one-icon menu-bar control panel for WARP / AdGuard DNS / ProtonVPN, and
monitors that watch the Application Firewall for port scans, ARP spoofing and
evil-twin access points.** One installer sets it all up, including its
dependencies. Apple Silicon Macs on macOS 14–27 get everything; Intel Macs,
including OpenCore Legacy Patcher Macs on macOS 11 and later, get a reduced
but supported set ([details](#intel-and-opencore-legacy-patcher-macs)).

It is the macOS counterpart of [Panoptes](https://github.com/doug445/Panoptes),
the Linux suite — same ideas, rebuilt on `networksetup`, `scutil`, `pf`, launchd
and the unified log instead of systemd-resolved, NetworkManager and nftables.

> [!WARNING]
> ## Homebrew has dropped Intel Macs — this suite uses MacPorts there
>
> **As of September 2026, Homebrew no longer supports Intel (x86_64) Macs**
> (announced August 2025). It no longer builds bottles for Intel, so every
> formula compiles from source — a routine `brew upgrade` can run for hours
> (LLVM alone took over an hour on an i9 MacBook Pro), and some formulae fail
> to build at all. Pinning formulae to dodge the builds dead-ends quickly:
> `brew upgrade` then refuses to update anything that depends on a pinned one.
> Homebrew's own warning on an Intel Mac reads:
>
> > *We do not provide support for this platform (as-of September 2026,
> > announced August 2025). Apple have dropped Intel x86_64 support in macOS
> > Golden Gate (27). GitHub Actions are dropping macOS Intel x86_64 runners in
> > 2027. … Homebrew no longer builds bottles for this configuration. Existing
> > bottles may still work, but updated formulae may build from source.*
>
> **So from 3.0.0 the suite installs [MacPorts](https://www.macports.org) on
> Intel Macs** — including OpenCore Legacy Patcher Macs — instead of Homebrew.
> MacPorts still publishes **prebuilt** packages for every macOS from 10.6 to
> 27 on Intel, installs into a root-owned prefix (`/opt/local`), and coexists
> with Homebrew if you have both. If your Intel Mac already has Homebrew and not
> MacPorts, the suite keeps using Homebrew, but expect long compiles; see
> [migrating an Intel Mac off Homebrew](#migrating-an-intel-mac-off-homebrew).
>
> **Apple Silicon is unaffected and unchanged**: it keeps using Homebrew,
> exactly as before.

Built and used daily on an Apple Silicon MacBook Pro running **macOS 27**;
exercised on Intel under macOS 26 with MacPorts. Nothing in it is tied to one
machine: the package manager and its prefix, the Wi-Fi interface, the ProtonVPN
service ID and the user are all read at run time.

**Guides:** [WARP connected but no internet](https://doug445.github.io/macOS-SecureNetwork-Suite/cloudflare-warp-connected-no-internet-mac/) ·
[Chrome ECH not working on macOS](https://doug445.github.io/macOS-SecureNetwork-Suite/chrome-ech-not-working-macos/) ·
[macOS 27: `arp -an` is empty](https://doug445.github.io/macOS-SecureNetwork-Suite/macos-27-arp-table-empty/) ·
[Homebrew dropped Intel Macs: moving to MacPorts](https://doug445.github.io/macOS-SecureNetwork-Suite/homebrew-intel-mac-macports/)

---

## Why this exists

Most network trouble on a Mac that runs a VPN is not the VPN. It is one of four
things wearing the VPN's clothes:

- **A DNS leak you cannot see.** macOS lets DHCP, a configuration profile, a VPN
  and `networksetup` all set resolvers, and `scutil --dns` is the only place
  that tells you which one is winning. The menu shows it in one glyph.
- **Cloudflare WARP's lockdown firewall with a dead tunnel.** WARP's daemon is a
  `KeepAlive` LaunchDaemon that will not stay disconnected, and when its tunnel
  dies — after sleep, a Wi-Fi change, a captive portal, a wedged daemon — its
  `pf` anchor keeps blocking everything but the LAN. The machine looks online
  and is not. `warp-killswitch` exists because this happened enough times to
  deserve a watchdog, a verified teardown and a verified rebuild.
- **Two tunnels on one Mac.** ProtonVPN's WireGuard extension and WARP's daemon
  cannot share the network; put them up together and WARP wedges. The menu
  parks one before raising the other.
- **A gateway that is not your gateway.** ARP spoofing and evil-twin access
  points change the layer-2 identity of the router while its IP stays the
  same. `netwatch` fingerprints the gateway and alerts when that identity
  changes on the same network — and ignores the band-steering roams that
  happen several times a day.

And one thing that is unique to this year's macOS: **on macOS 27 a process
forked from a non-Apple-signed binary reads an empty ARP table and an empty
socket list.** Every tool run by a Homebrew or MacPorts bash that reads `arp -an` silently sees
nothing. `components/macos27-netfix` measures that, works around it with an
Apple-rooted LaunchAgent, and every tool here reads through it.

## What Encrypted Client Hello is, and what macOS can do about it

HTTPS encrypts what you send. It does not encrypt **which site you are talking
to**: the first packet of a TLS handshake carries the hostname in the clear
(SNI), and that single field is how most network-level filtering and logging
works. Encrypting DNS alone does not close it — the name leaks a few
milliseconds later on every connection. **ECH** encrypts that ClientHello to a
key the site publishes in its DNS `HTTPS` record, so an observer sees only the
CDN in front.

On a Mac the practical problems are specific:

| | What the suite does |
|---|---|
| **The DNS half is not optional** — a browser must fetch the `HTTPS` record over encrypted DNS or there is no key to use | The **AdGuard DoH profile** sets system-wide DNS-over-HTTPS; `checkdns` verifies the resolver passes `HTTPS`/SVCB records. |
| **Chromium silently turns its own DoH off** when it sees a system DNS profile ("managed DNS"), so Chrome, Brave, Edge, Vivaldi and Opera never discover ECH keys | The **Chromium DoH policy profile** forces `DnsOverHttpsMode=secure` as enterprise policy for all five, which overrides that detection. Verify at `chrome://policy`. |
| **Firefox** needs ECH and TRR (DoH) switched on together | `user.js` for every profile: ECH, HTTPS DNS records, DoH to AdGuard, HTTPS-only mode, TLS 1.2 minimum, OCSP required. |
| **Safari cannot do ECH.** WebKit has no implementation as of Safari 26 | Nothing can; the suite says so rather than pretending. Use another browser for anything you want hidden from the path. |
| **Stock `curl` cannot test ECH** — no released OpenSSL implements it, and even an ECH-capable curl only gets keys over DoH (`--doh-url`) | `checkdns` looks for an ECH-capable curl (also in `~/.local/opt/curl-ech`), runs a real `--ech hard` handshake with keys fetched over your DoH resolver, and reads the verdict from [tls-ech.dev](https://tls-ech.dev). With only stock curl it says so instead of reporting a false failure. |

Verify any of it at [tls-ech.dev](https://tls-ech.dev) or [defo.ie/ech-check.php](https://defo.ie/ech-check.php).

---

## Quick start

```sh
git clone https://github.com/doug445/macOS-SecureNetwork-Suite.git
cd macOS-SecureNetwork-Suite
./install.sh            # as your normal user — it asks for sudo once
```

Then:

```sh
checkdns              # mDNS, resolvers, DNSSEC, DoT, DoH, ECH, VPN + DNS-leak check, smoke test
netcheck              # firewall, listening ports, WARP exit check, DNS, ARP table, recent drops
sudo warp-killswitch status   # the WARP stack: daemon, tunnel, link, egress, artifacts, watchdog
```

The menu-bar icon is **xbar › Security Toggle**. Two things need you: macOS
will not install configuration profiles silently, so approve the two DoH
profiles in *System Settings › General › Device Management*; and the ProtonVPN
items click the ProtonVPN app for you, which needs **xbar** turned on in
*System Settings › Privacy & Security › Accessibility* (the menu tells you if
it is not).

---

## The tools

### DNS — encrypted, filtered, leak-free

| Component | What it does |
|---|---|
| **`dns`** | Sets AdGuard DNS privacy servers (`94.140.14.140` / `.141` — no logging, no EDNS Client Subnet) with Quad9 and Cloudflare's malware-blocking `1.1.1.2` as DNSSEC-validating fallbacks, on Wi-Fi and iPhone USB. The menu toggles the same two services. |
| **`profiles`** | **AdGuard DoH** system profile (DNS-over-HTTPS for every app, and the `HTTPS` records ECH needs in Safari/WebKit) and the **Chromium DoH policy** that stops Chrome, Brave, Edge, Vivaldi and Opera from turning DoH off. Approve both once in *Device Management* (the DoH one is device-level, so it asks for an administrator password). Skipped when a device profile already provides encrypted DNS — macOS keeps only one active. |
| **`firefox`** | `user.js` appended to every Firefox profile: ECH, DoH to AdGuard, HTTPS-only, TLS 1.2+, OCSP required. Idempotent; marked with a block comment so it is never added twice. |
| **`checkdns`** | One-screen DNS and privacy status for zsh: mDNSResponder health, every live resolver, DNSSEC validation (AD flag and a deliberately broken domain), DoT and DoH detection, ECH at both layers (`HTTPS` record and a real `--ech hard` handshake when curl can), active tunnels with a **DNS-leak check** on full-tunnel VPNs, and a resolution smoke test. |

### Tunnel — Cloudflare WARP that can never blackhole the machine

| Component | What it does |
|---|---|
| **`warp`** | Registers Cloudflare WARP (free consumer registration), sets `tunnel_only` mode over MASQUE, connects, and verifies `warp=on` at the edge. WARP auto-updates delete the registration and reset the mode; re-running `./install.sh --only warp` is the repair. |
| **`killswitch`** — `warp-killswitch` | **Tear Down**: disconnect (time-bounded), stop *and disable* the `KeepAlive` daemon so it stays down across reboot, flush the `pf` anchor, delete every route on the utun (v4 and v6), remove its SCDynamicStore keys, drop DNS to DHCP on every service so a **captive portal** can intercept, then **prove** plain internet works and escalate until it does. **Rebuild**: restore DNS verbatim, re-enable, connect, wait for *Connected* **and** a raw-IP check, and roll back to a clean disconnected state if the tunnel never comes. **Heal**: the decision procedure below, on demand. [Details](components/warp-killswitch/README.md) |
| **watchdog** | A root LaunchDaemon: every 10 s a raw-IP probe (parallel pings, then TCP 443 by address — no DNS). Link up but internet dead for three probes → `heal`. Detects wake-from-sleep by a wall-clock jump and reconnects. Never acts while WARP is torn down or parked. |
| **macOS 27 re-dispatch** | A menu- or terminal-launched `down`/`up`/`heal` whose caller is subject to the ARP blank re-dispatches itself through an on-demand LaunchDaemon, so it decides from the same clean view the watchdog has. |

**How `heal` decides.** Torn down by you → nothing. Link down → not WARP.
Raw IP works → healthy (purge leftovers of a dead daemon; flush caches if DNS
alone fails). Offline with **no WARP artifacts** → upstream problem, back off.
Offline, **daemon dead, artifacts remain** → purge them. Offline with a live
daemon → clean disconnect; if the artifacts survive the daemon is wedged →
hard teardown (DNS kept); if plain internet works and a **captive portal** is
intercepting → leave WARP off and say so; otherwise retry once and leave WARP
off on failure. Every path ends with a notification stating the verified
outcome.

### The menu-bar toggle

`security-toggle.5s.sh` is an [xbar](https://xbarapp.com) plugin that puts the
three switches, the kill-switch and the watchdog in one menu-bar item and
refreshes every five seconds.

![The macOS desktop with the Security Toggle menu open in the menu bar: the title shows a shield and a blue dot for WARP connected with AdGuard DNS, and the menu lists the Cloudflare WARP section with Disconnect, Last Resort: Tear Down, Heal now and Status, the AdGuard DNS section with Disable, and the ProtonVPN section with Connect](docs/images/menu-bar.png)

The title is two glyphs: the **left one is the tunnel**, the **right one is
DNS**. Green means on, grey means fallback, red means you asked for it.

| Title | Tunnel | DNS | Meaning |
|---|---|---|---|
| 🛡️🔵 | Cloudflare WARP connected (tunnel-only) | AdGuard | The normal state. |
| 🛡️⚫ | WARP connected | Quad9 + Cloudflare fallback, or DHCP | You disabled AdGuard, or a captive-portal teardown restored a non-AdGuard backup. |
| 🟣🔵 | ProtonVPN connected — **WARP is parked** | AdGuard | ProtonVPN from the menu. WARP's daemon is stopped and disabled until you disconnect. |
| 🟣⚫ | ProtonVPN connected, WARP parked | fallback | Same, with AdGuard off. |
| 💀🔴 | **Torn down** by *Last Resort* | DHCP | Captive-portal ready. *Rebuild WARP + AdGuard DNS* brings everything back. |
| 🔓🔵 | No tunnel (WARP disconnected, daemon alive) | AdGuard | Plain internet with filtered, encrypted DNS. |
| 🔓⚫ | No tunnel | fallback | Nothing protecting you but the firewall. |

Inside the menu, a WARP that was parked for ProtonVPN but is not covered by a
ProtonVPN connection (the app was quit, or it dropped) shows as ⏸️ with a
*Rebuild WARP now* item, distinct from a deliberate 💀 teardown.

| Section | Item | What it does |
|---|---|---|
| **Cloudflare WARP** | ▶️ Connect / ⏹️ Disconnect | `warp-cli connect` / `disconnect`, time-bounded so a wedged daemon cannot freeze the menu; waits for the tunnel address to appear or go. Refused while ProtonVPN is connected. |
| | 🔴 Last Resort: Tear Down | `warp-killswitch down`: the full verified teardown above. DNS goes to DHCP so a captive portal can intercept. |
| | 🟢 Rebuild WARP + AdGuard DNS | `warp-killswitch up`, then the suite's DNS policy on top of the verbatim restore — so the stack comes back as *WARP + AdGuard* even if AdGuard had been off before the teardown. Refused while ProtonVPN is connected. |
| | 🩺 Heal now | `warp-killswitch heal` — the decision procedure, now. |
| | ℹ️ Status | A dialog with the helper's one-screen readout: daemon, tunnel, link (and *how* the link was judged on macOS 27), raw internet, DNS, egress colo, artifacts, watchdog. |
| | watchdog: active / standing by / NOT running | Whether the LaunchDaemon is running. *Standing by* while WARP is down is correct. |
| **AdGuard DNS** | ▶️ Enable / ⏹️ Disable | `networksetup -setdnsservers` on Wi-Fi and iPhone USB (NOPASSWD, Apple binary only), then a cache flush. Disable leaves Quad9 + Cloudflare, never DHCP. |
| **ProtonVPN** | ▶️ Connect (parks WARP first) | Parks the WARP stack (`warp-killswitch down --keep-dns`: daemon stopped, DNS untouched, watchdog standing by), opens the ProtonVPN window in the background, clicks **Quick Connect**, waits for the service to report *Connected*, hides the window. |
| | ⏹️ Disconnect → rebuild WARP | Clicks **Disconnect**, waits for *Disconnected*, and — if the menu had parked WARP — rebuilds it. |
| | ⚠️ xbar needs Accessibility | Appears only after a click failed for lack of permission; opens the Accessibility pane. The app was already brought to the front with a notification saying what to click. |

> [!IMPORTANT]
> **ProtonVPN cannot be started from outside its app.** ProtonVPN 6.x registers a
> VPN service with the system, but `scutil --nc start` on it returns 0 and the
> connection never leaves *Disconnected*: its WireGuard system extension only
> connects when the app asks. The menu therefore drives the app's own buttons
> through System Events, which is why xbar needs **Accessibility**. There is no
> URL scheme, AppleScript dictionary or Shortcuts action to use instead.
>
> **Why park WARP rather than just disconnect it.** With WARP merely
> disconnected, ProtonVPN came up fine — and afterwards the WARP daemon stopped
> answering its control socket with its lockdown firewall still up. Raw internet
> died until a manual Tear Down. A stopped daemon has nothing to wedge.

### Monitoring and investigation

| Component | What it does |
|---|---|
| **`firewall`** | Application Firewall on, **stealth mode**, logging — the input everything below reads. |
| **`netwatch`** | A LaunchAgent that streams the unified log for *Stealth Mode connection attempt* drops and raises native notifications: **port-scan alerts** (N probes from one source in a window, broadcast/discovery noise filtered), **gateway-identity detection** (fingerprint `ssid|gw|mac|ll|bssid`; a MAC or IPv6 link-local change on the *same* network alerts, a BSSID-only change is logged as a roam, a new SSID re-baselines), network-change notices, periodic summaries. Fails loudly: an `ERR` trap logs `FATAL exit=N at line N` so a crash loop under launchd `KeepAlive` is never silent again. |
| **`nettop`** | Summarises the netwatch drop log by source with MAC, vendor (`arp-scan` or the ARP table) and reverse DNS. |
| **`netcheck`** | One-shot security report: firewall state, **platform integrity** (macOS still patched by Apple, SIP, sealed system volume, AMFI, T2 Secure Boot, Gatekeeper, FileVault, OpenCore Legacy Patcher detection), listening TCP/UDP ports (localhost-only vs exposed), WARP status and an **exit check** (`warp=on` at the edge), split-tunnel exclusions, live resolvers and the Wi-Fi DNS override, encrypted-DNS profile, ARP table with the gateway marked, recent drops, top drop sources with vendor and rDNS, **MAC randomisation** state, every interface's addresses, public IPv4/IPv6. |
| **`probesource`** | **The centrepiece.** Investigate any address — a firewall drop, a probe, a live connection. Pick it from the netwatch log, the unified-log firewall history, the live `lsof` table, or type one in. Passive tactics never send a packet to the target (whois, rDNS, GeoIP/ASN, drop and netwatch history, ARP/NDP + OUI vendor, live sockets, `pf` state and table membership, a short capture, a `p0f` fingerprint listener, plus macOS-only `scutil` reachability, Bonjour, process-attributed `pktap` capture, `pflog`, pf rules, per-process `nettop`). Active and aggressive tactics escalate through ping, traceroute, nmap, SMB/SNMP/IKE/SSL enumeration, masscan and nping across six relentless rounds. [Details](components/probesource/README.md) |
| **`netfix`** | The **macOS 27 ARP blank** workaround: `detect.sh` measures whether a Homebrew- or MacPorts-rooted process sees an empty ARP table on this machine; if so, an Apple-rooted (`/bin/sh`) LaunchAgent publishes the table every 15 s and every tool reads it through `arp_table()` — direct read first, cache only when the direct read is empty and the cache is under 120 s old. A stale cache would hide exactly the spoofing netwatch exists to catch, so staleness is refused and reported. The agent **retires itself** once a macOS or Homebrew update makes the ARP table readable again (three confirmed verdicts, ten minutes apart). [Details](components/macos27-netfix/README.md) |
| **`shell`** | `checkdns` and a set of network aliases and functions for zsh (`myip`, `localip`, `ports`, `scan*`, `routes`, `netinfo`, `port_check`, `resolve`, …). |

---

## Intel and OpenCore Legacy Patcher Macs

Apple Silicon is the primary platform and is never traded down for the others:
it always installs through Homebrew, exactly as before. Intel Macs are
supported in a **degraded mode**, and so are Macs running a newer macOS than
Apple supports through [OpenCore Legacy Patcher](https://dortania.github.io/OpenCore-Legacy-Patcher/)
(OCLP). An older Mac is often the one that needs this most, so the suite
installs everything that can work there and tells you plainly about the rest.

| | Apple Silicon | Intel, macOS 14+ | Intel / OCLP, macOS 11–13 |
|---|---|---|---|
| Package manager | Homebrew | MacPorts (or an existing Homebrew) | MacPorts |
| DNS, DoH profiles, Firefox/Chromium ECH, firewall | ✓ | ✓ | ✓ |
| netwatch, netcheck, nettop, probesource, checkdns | ✓ | ✓ | ✓ |
| Cloudflare WARP + kill-switch | ✓ | ✓ | — current WARP needs macOS 14 |
| ProtonVPN | ✓ | ✓ | newest release that supports the OS, if any |
| xbar menu | ✓ | ✓ | ✓ (AdGuard toggle; tunnel items need WARP) |

**Why MacPorts on Intel.** Homebrew stopped building Intel (x86_64) bottles in
September 2026, so on Intel every formula compiles from source, and Homebrew
does not support older macOS releases at all. MacPorts ships prebuilt packages
for every macOS from 10.6 to 27, installs into a root-owned prefix, and is
installed by the suite from its signed release (Developer ID `QTA3A3B7F3`) if
missing. If Homebrew is already there and MacPorts is not, the suite uses it.
Force either with `SECURENET_PKG=macports|homebrew ./install.sh` (Intel only).

**Apps without Homebrew.** Cloudflare WARP, xbar and ProtonVPN are downloaded
from their vendors and installed only if the signature matches the vendor's
Team ID (`68WVV388M8`, `N3H5B92L5N`, `J6S6Q257EK`). ProtonVPN's update feed is
read to pick the newest release whose minimum macOS this Mac meets.

### Migrating an Intel Mac off Homebrew

You do not have to remove Homebrew to use the suite: install MacPorts and the
installer switches to it. To leave Homebrew entirely, as the suite's own Intel
test machine did:

1. Install MacPorts (or run `./install.sh --only deps`, which installs the
   signed release for your macOS), then `sudo port selfupdate`.
2. Install the MacPorts equivalent of each formula you use, prebuilt only:
   `sudo port -b install <name>` (`-b` fails instead of compiling). Names
   mostly match; common differences: `gnu-sed`→`gsed`, `wireshark`→`wireshark4`,
   `samba`→`samba4`, `imagemagick`→`ImageMagick7`, `sevenzip`→`7zip`,
   `bind`→`bind9`, `python@3.13`→`python313`, `qt`→`qt6`. MacPorts installs GNU
   tools with a `g` prefix (`gtimeout`, `gsed`); `/opt/local/libexec/gnubin`
   has the unprefixed names.
3. Before uninstalling Homebrew, find what still depends on it — things
   `brew uses` cannot see: programs you built that link
   `/usr/local/opt/*` or `/usr/local/Cellar/*` (`otool -L`), Python virtualenvs
   built on Homebrew's Python (`pyvenv.cfg`), scripts with `#!/usr/local/bin/bash`
   shebangs, and LaunchAgents or sudoers rules naming `/usr/local/bin` tools.
4. Run Homebrew's official uninstaller (`--dry-run` first). Afterwards, return
   `/usr/local` to `root:wheel` — Homebrew left it owned by your user, and any
   root daemon or NOPASSWD rule running code from there is then a root
   escalation. The suite's installer does this for `/usr/local/bin` itself.
5. Put `/opt/local/bin` ahead of `/usr/local/bin` on your `PATH`.

**What an OCLP Mac gives up.** OCLP gets a new macOS onto unsupported hardware
by switching off protections Apple relies on, and `netcheck` lists them under
**PLATFORM INTEGRITY** so you can see your actual posture:

- **SIP** partially or fully disabled, so root-level malware can modify the system.
- **Sealed system volume** broken by root patches, so system tampering is no longer detected.
- **AMFI** (code-signing enforcement) often disabled via boot-args.
- **Secure Boot** reduced or absent.
- **Security updates:** a release Apple no longer patches.

> [!CAUTION]
> **A gentle reminder: running OCLP is a poor trade for a machine you depend on.**
> It buys a newer macOS by switching off the protections that make macOS
> secure in the first place — and this suite cannot put them back. A
> network-security suite on top of a disabled SIP and AMFI is a locked front
> door with the back wall removed. If the Mac matters, the sensible options are
> a Mac Apple still supports, staying on the last macOS release Apple shipped
> for your model for as long as it gets updates, or Linux on the same hardware,
> which supports it properly.

If you run OCLP anyway, the suite still helps where it can: encrypted, filtered
DNS, the firewall in stealth mode and netwatch watching the gateway matter more
on such a machine, not less. Re-run OCLP's root patches after every macOS
update, keep FileVault and Gatekeeper on (both work under OCLP), and avoid apps
that ask you to weaken anything further.

## Captive portals: hotel, airport and public Wi-Fi

**A hardened stack cannot log in to a captive portal.** This is the single most
common way the suite will appear to have broken your internet, and it is worth
reading before you travel rather than from a hotel lobby.

| Layer | Why the portal fails |
|---|---|
| **Cloudflare WARP** | The tunnel carries your traffic straight past the portal, which never sees a request to redirect. You get a dead connection, not a login page. **WARP must come down first.** |
| **AdGuard DNS / DoH profile** | The portal hijacks plain DNS to force you to its page. It cannot touch an encrypted query or a fixed resolver, so the redirect never happens. |
| **Private Wi-Fi Address (rotating)** | Every reconnect can look like a new client, so the authorisation you just completed stops applying. Set that network's address to *Fixed* if logins keep expiring. |

### The order that works

From the menu: **🔴 Last Resort: Tear Down**. That is the whole procedure —
WARP is stopped and disabled, its firewall and routes are gone, DNS is DHCP on
every service, and the helper has *verified* plain internet (or a portal
redirect) works before it tells you so. Open `http://captive.apple.com` and log
in. Once the portal has actually let you onto the internet — check, do not
assume — **🟢 Rebuild WARP + AdGuard DNS**.

**Reconnect WARP only after the portal has authorised you.** Bringing the
tunnel up first puts you back where you started.

From a terminal the same two steps are:

```sh
sudo warp-killswitch down    # ... log in at the portal ...
sudo warp-killswitch up      # only once you are actually online
```

`heal` (and the watchdog) also recognise a portal on their own: if plain
internet works and the probe is being redirected, WARP is left off and a
notification tells you to log in.

---

## How it compares

| | This suite | `networksetup` / `scutil` | Little Snitch / LuLu | Wireshark |
|---|---|---|---|---|
| Shows which resolver is *actually* answering, and whether it validates DNSSEC and passes ECH keys | **yes** | shows state, not the chain | no | manually |
| Forces DoH + ECH in Chromium despite the managed-DNS trap | **yes** | no | no | no |
| Survives WARP's lockdown firewall with a dead tunnel | **yes** — verified teardown, rebuild, watchdog | no | no | no |
| Switches between WARP and ProtonVPN safely | **yes** | no | no | no |
| Detects ARP spoofing / evil twins, ignores band-steering roams | **yes** | no | no | manually |
| Investigates an unknown source IP | **yes**, 20+ tactics | no | shows the connection | packet-level only |
| Works around the macOS 27 ARP blank | **yes** | n/a | n/a | n/a |
| Learning curve | one installer, one menu | low | low | steep |

It is not a firewall and not an IDS. It is the layer between "something is
wrong with my network" and "I know exactly what and why".

---

## Updating

```sh
git pull && ./install.sh
```

Every installed piece is regenerated from the repo, so an update is the same
command whatever changed. That includes moving to a different Mac: if the
installer finds the layout changed since its last run — most often an Intel
Mac's home folder migrated to Apple Silicon, which switches MacPorts for
Homebrew — it says so, regenerates every layout-dependent component (even under
`--only`), and finishes with an audit that fails if anything installed still
points at the old layout.

## Installation

```sh
./install.sh                              # everything, including dependencies
./install.sh --list                       # component names
./install.sh --only warp,killswitch       # just these
./install.sh --skip probesource,firefox   # all but these
./install.sh --no-deps                    # don't install dependencies
./uninstall.sh                            # reverse it
```

Run it as your normal user: it asks for sudo once and keeps it alive; Homebrew
is never run as root (MacPorts, being root-owned, is driven through sudo). Everything is idempotent — re-running repairs drift, and
files the installer replaces are backed up as `*.bak.<timestamp>` first. It
re-executes itself under Apple's `/bin/bash` whatever shell invoked it, because
on macOS 27 an installer rooted in a non-Apple bash would measure a blind ARP baseline.

### Requirements

- **Apple Silicon:** macOS 14 or later — everything.
- **Intel, including OpenCore Legacy Patcher Macs:** macOS 11 or later —
  degraded mode, see [above](#intel-and-opencore-legacy-patcher-macs).

The macOS 27 workaround installs only where `detect.sh` measures the defect.

### Dependencies — installed automatically

The `deps` component installs whatever is missing:

- **Package manager:** Homebrew on Apple Silicon (official installer, non-interactive); MacPorts on Intel (signed release for the running macOS) unless Homebrew is already installed. Either brings the Xcode Command Line Tools.
- **Tools:** `bash` (netwatch, nettop, netcheck and probesource need bash ≥ 4; the menu and the kill-switch run on the stock bash 3.2), `nmap`, `arp-scan`, `watch`, and a speed test — `speedtest-go` on Homebrew (Homebrew deprecated `speedtest-cli`), `speedtest-cli` on MacPorts (no `speedtest-go` port)
- **Apps:** Cloudflare WARP, xbar, ProtonVPN — Homebrew casks, or vendor downloads checked against the vendor's Team ID; skipped if the app is already in `/Applications` or does not support the running macOS
- **probesource probe toolset:** GNU userland (`grep`, `gnu-sed`, `coreutils`, `gawk`), `dialog`, `wireshark`, `p0f`, `mtr`, `masscan`, `sslscan`, `ike-scan`, `samba`, `pipx` + `enum4linux-ng`, and `onesixtyone` / `nbtscan` built from source

Skip with `--no-deps`. **AdGuard needs no installation** — it is a public
resolver, not software. Only WARP and ProtonVPN run local daemons.

### What gets installed where

| Path | From |
|---|---|
| `/usr/local/bin/warp-killswitch` — or `/Library/PrivilegedHelperTools/warp-killswitch` (+ a link in `/usr/local/bin`) when Homebrew on Intel has made `/usr/local/bin` user-writable | killswitch |
| `/Library/LaunchDaemons/local.warp-killswitch.{watchdog,do-down,do-up,do-heal}.plist` | killswitch |
| `/etc/sudoers.d/warp-killswitch`, `securenet-dns`, `securenet-netcheck` | killswitch, sudoers |
| `~/Library/Application Support/xbar/plugins/security-toggle.5s.sh` (+ reference copy in `~/Documents/SwiftBar/`) | killswitch, from `components/menubar/` |
| `~/Library/LaunchAgents/com.netwatch.plist`, `com.netwatch.arpcache.plist` | netwatch, netfix |
| `~/.local/bin/{netwatch,nettop,netcheck,probesource,arp-cache-dump}` | netwatch, netcheck, probesource, netfix |
| `~/.config/macos-securenetwork-suite/*.zsh` + a marked block in `~/.zshrc` | shell |
| `~/.config/macos-securenetwork-suite/AdGuard-DoH.mobileconfig`, `chrome-doh-policy.mobileconfig` (rendered from the templates with your login name and DoH target) | profiles |
| `~/.config/macos-securenetwork-suite/dns.conf` — optional per-machine overrides, read by the installer and the menu. `FALLBACK2=1.1.1.1` swaps the second fallback for Cloudflare's unfiltered resolver (the default is the malware-blocking `1.1.1.2`); `DOH_URL=https://d.adguard-dns.com/dns-query/<device-id>` plus `DOH_BOOTSTRAP=94.140.14.49` point the Chromium policy and Firefox at an AdGuard DNS account resolver instead of the public one | you |
| State / logs: `/var/db/warp-killswitch/`, `/var/log/warp-*.log`, `~/.local/share/{netwatch,probesource}/`, `~/.local/state/macos-securenetwork-suite/` | |

---

## FAQ

### How do I check for a DNS leak on macOS?

`checkdns`. It lists every live resolver from `scutil --dns` (not what a config
file claims), and when a full-tunnel VPN owns the default route it flags any
public resolver still visible as a possible leak. Tunnel-only WARP and
split-tunnel setups preserve system DNS by design, and it says so instead of
crying leak.

### How do I know DNSSEC, DoH or ECH is actually working?

`checkdns` tests each at the layer where it can fail: DNSSEC by the AD flag and
by a deliberately broken domain that must *not* resolve; DoH by the installed
profile and `scutil`'s resolver options; ECH by whether the `HTTPS` record for
`crypto.cloudflare.com` (which publishes an ECH key; `cloudflare.com` does not)
reaches you, and — if an ECH-capable curl is installed — by a real `--ech hard`
handshake against [tls-ech.dev](https://tls-ech.dev) with keys fetched over
your DoH resolver. Browser-side, check tls-ech.dev or
[crypto.cloudflare.com/cdn-cgi/trace](https://crypto.cloudflare.com/cdn-cgi/trace)
(`sni=encrypted`). [defo.ie](https://defo.ie/ech-check.php) is a test server
whose published keys sometimes lag its server's (Oct 2026: DNS listed keys the
server had retired), so a failure there alone is not conclusive.

### Why doesn't Chrome use ECH even though "Use secure DNS" is on?

Because a system DNS configuration profile makes Chromium think DNS is
enterprise-managed, and it silently disables its own DoH — without which it
never fetches the record carrying the ECH key. The `profiles` component
installs a policy profile that sets `DnsOverHttpsMode=secure` for Chrome,
Brave, Edge, Vivaldi and Opera. Check `chrome://policy`.

### Does Safari support ECH?

No. WebKit has no implementation as of Safari 26, and no setting changes that.

### WARP says "Registration Missing" after an update. Now what?

Only on WARP builds before the 2026.8 series. Current builds keep the
registration across updates and simply relaunch showing *Connected*. On an
older build the updater reinstalled the app and recreated its database, which
deleted the registration and reset the mode; ignore the onboarding picker in
the GUI and run `./install.sh --only warp` — it recreates the free consumer
registration, sets `tunnel_only` and MASQUE, and verifies `warp=on`.

### Wi-Fi is connected but there is no internet. Is it WARP?

Usually. Menu › **ℹ️ Status** tells you: artifacts present with the daemon
*Unable* or stuck *Connecting* is the lockdown firewall with a dead tunnel. The
watchdog heals that on its own within two to three minutes; **🩺 Heal now**
does it now; **🔴 Last Resort: Tear Down** always gets you plain internet. If
Status shows no artifacts and still no internet, it is the link or the ISP.

### Why does the ProtonVPN item click the app instead of just connecting?

Because nothing else works: ProtonVPN 6.x ignores `scutil --nc start` on its
own service, exposes no URL scheme, AppleScript dictionary or Shortcuts action,
and its WireGuard extension connects only when the app asks. The menu presses
**Quick Connect** / **Disconnect** in the app's window through System Events,
which is why xbar needs Accessibility. If it cannot, it brings the app to the
front and tells you what to click.

### Why does connecting ProtonVPN turn WARP's icon into ⏸️ / 🟣 and stop the daemon?

Because a merely-disconnected WARP daemon wedges when ProtonVPN's extension
takes the network, and leaves its lockdown firewall up with no tunnel — the
Mac goes dark. Parking (daemon stopped and disabled, DNS untouched) has
nothing to wedge. Disconnecting ProtonVPN from the menu rebuilds WARP.

### Something is probing my machine. How do I find out who?

`probesource`. Pick the address from the netwatch log, the firewall history or
the live socket table and run the passive tactics — nothing is sent to the
target until you choose an active mode. `nettop` gives the one-line version:
every drop source with MAC, vendor and reverse DNS.

### A tool reports an empty ARP table, or `netstat` shows nothing (macOS 27)

Run `components/macos27-netfix/detect.sh` from `/bin/sh` (not Homebrew's or MacPorts' bash).
If it reports AFFECTED, `./install.sh --only netfix`, then `verify.sh`. `lsof`
is unaffected and is the substitute for `netstat -an`. Never test `arp`
behaviour from a Homebrew or MacPorts bash — it is blind there.

### The AdGuard DNS dashboard says this Mac is "not connected"

The dashboard checks from inside the browser, and by default the suite points
Chromium (policy profile) and Firefox (`user.js`) at AdGuard's **public** DoH
resolver, not at your account's device URL, so the check never sees your
device ID even though every other app on the Mac resolves through it. Put
your account resolver in `~/.config/macos-securenetwork-suite/dns.conf`:

```sh
DOH_URL=https://d.adguard-dns.com/dns-query/<device-id>
DOH_BOOTSTRAP=94.140.14.49
```

then run `./install.sh --only profiles,firefox`, re-approve the Chromium
policy profile in Device Management and restart Firefox. A Firefox profile
that already had its own `network.trr.uri` before the suite is left alone;
edit it by hand.

### Is any of this safe to run on a machine I need right now?

`checkdns`, `netcheck`, `nettop`, `probesource`'s passive modes,
`warp-killswitch status|verify|state` and every `detect.sh` / `verify.sh` make
**no changes at all**. Tear Down, Rebuild, Heal and the toggles write — and each
verifies its result and tells you what it found.

---

## Notes and caveats

- **Resolver choices are opinionated.** AdGuard's no-log privacy servers with
  Quad9 and Cloudflare behind them, on Wi-Fi and iPhone USB. Change the
  addresses at the top of `install.sh` and the menu plugin to suit.
- **Two bash dialects on purpose.** The menu and the kill-switch helper are
  stock bash 3.2 with absolute paths and no package manager anywhere, because they
  must work when Homebrew or MacPorts is broken and because on macOS 27 only an
  Apple-rooted process sees the ARP table. netwatch, nettop, netcheck and
  probesource use bash 4 features and run under the package manager's bash — through the
  `arp_table()` cache when they have to.
- **Absolute paths are audited at install time.** The kill-switch installer
  checks every hardcoded binary path in the helper and the menu against the
  machine it installs to, because a wrong path behind `2>/dev/null` is an
  invisible no-op. Treat a red line there as a bug.
- **The NOPASSWD sudoers rules cover Apple binaries only** (`networksetup
  -setdnsservers`, `killall -HUP mDNSResponder`, `profiles show`) plus the
  root-owned `warp-killswitch` helper. Anything root runs without a password
  must sit in a directory chain only root can write — otherwise a user can swap
  the file — so the installer keeps the helper out of a user-writable
  `/usr/local/bin` (Homebrew on Intel) and returns `/usr/local/bin` to root when
  nothing needs it writable. `arp-scan` is excluded on Homebrew: its prefix is
  user-writable, and with free arguments it can write files as root (`-W`). With
  MacPorts' root-owned prefix the installer adds a rule pinned to the exact
  invocations `netcheck` and `nettop` use; anything else still prompts.
- **`probesource`'s active and aggressive tactics send packets to the target.**
  Use them only on hosts and networks you own or are authorised to test.
- **Lint is clean and enforced.** CI fails on any `shellcheck` warning across
  every bash and sh tool, including the helper embedded in the kill-switch
  installer. Where word splitting is deliberate the line carries an inline
  `shellcheck disable=SC2046` stating why.

## Docs

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the pieces fit together
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — WARP updates, ECH, ProtonVPN and Accessibility, the macOS 27 ARP blank, crash loops
- [components/warp-killswitch/README.md](components/warp-killswitch/README.md) — the kill-switch, its test results and lessons
- [components/probesource/README.md](components/probesource/README.md) · [components/macos27-netfix/README.md](components/macos27-netfix/README.md)
- [CHANGELOG.md](CHANGELOG.md)

## Contributing

Issues and pull requests welcome. Run this before opening a PR — it is what CI
runs:

```sh
shellcheck -S warning install.sh uninstall.sh lib/pkg.sh components/*/*.sh components/netwatch/netwatch \
  components/netwatch/nettop components/netcheck/netcheck components/probesource/probesource \
  components/menubar/security-toggle.5s.sh
zsh -n components/checkdns/*.zsh
```

Found a security issue? Please do not open a public issue — email
spilled-bowline0j@icloud.com.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 William MacKinnon.
