# Changelog

All notable changes to macOS-SecureNetwork-Suite are recorded here.
This project follows [Semantic Versioning](https://semver.org/).

## [3.1.0] — 2026-10-16

### Changed

- **Intel is now MacPorts-exclusive.** On Intel (x86_64) the suite uses MacPorts
  and ignores any Homebrew that is installed, rather than falling back to an
  existing `/usr/local` Homebrew. Because MacPorts (`/opt/local`) and Homebrew
  (`/usr/local`) coexist, the suite bootstraps MacPorts alongside your Homebrew
  without disturbing it. Apple Silicon is unaffected — it still uses Homebrew,
  unchanged. (`lib/pkg.sh` `pkg_detect`.)

### Added

- **probesource builds `ike-scan` and `hping3` from upstream on MacPorts/Intel.**
  Both ports fail to build on the current Apple clang toolchain (C23), so
  `components/probesource/install.sh` now builds them from source: ike-scan with
  `-std=gnu17` against MacPorts `openssl3`; hping3 `--no-tcl` with the Makefile
  lib path repointed to `/opt/local`. Gated to MacPorts — on Homebrew (Apple
  Silicon and Intel) ike-scan stays a formula and hping3 stays skipped.

### Deprecated

- **`SECURENET_PKG=homebrew` on Intel.** Retained as an explicit escape hatch to
  force the old Homebrew-Intel path, but it now prints a deprecation warning and
  will be removed when Homebrew ends Intel support (~Sept 2027). Homebrew moved
  Intel to Tier 3 in Sept 2026 (no new x86_64 bottles).

## [3.0.1] — 2026-10-15

### Fixed

- **netwatch "Degraded" notification storm.** The ARP-cache staleness guard
  runs inside `$(...)`/`| awk` subshells, so its "already warned" variable
  never reached the main loop and the notification repeated on every 10 s
  poll. The rate limit now lives in a marker file
  (`~/.local/share/netwatch/arp_stale_notified`) and repeats at most hourly;
  recovery is logged as `INFO arp cache fresh again`.
- **Idle ARP table read as a dead publisher.** `arp-cache-dump` withheld empty
  results, so on a hotspot whose gateway never completes ARP the cache mtime
  froze and tripped the 120 s limit with the agent running fine. It now
  publishes an empty table; only a failed `arp(8)` leaves the cache untouched.
- **Gateway-identity false alerts on a vanished MAC.** An ARP entry expiring or
  sitting `(incomplete)` produced `gateway MAC aa:bb -> none` and `none -> aa:bb`
  alerts on consecutive polls. An unknown MAC on the same network now keeps the
  baseline; a MAC first learned after baseline is logged, not alerted.

## [3.0.0] — 2026-10-13

Intel and OpenCore Legacy Patcher support. Apple Silicon behaviour is unchanged:
it still installs through Homebrew, with the same tools, apps and paths.

### Breaking

- **Intel Macs default to MacPorts.** Homebrew stopped building x86_64 bottles
  in September 2026, so on Intel every formula compiled from source. A new
  package layer (`lib/pkg.sh`) installs MacPorts from its signed release when
  neither manager is present, prefers MacPorts when both are, and still uses an
  existing Homebrew when MacPorts is absent. `SECURENET_PKG=macports|homebrew`
  forces the choice on Intel; it is ignored on Apple Silicon.
- **The kill-switch helper moves out of a user-writable `/usr/local/bin`.** The
  helper runs as root through a NOPASSWD rule and four LaunchDaemons, and a
  user who can write its directory can replace it. When Homebrew on Intel keeps
  `/usr/local/bin` user-writable, the helper now installs to
  `/Library/PrivilegedHelperTools/warp-killswitch` (sudoers, daemons and menu
  follow; `/usr/local/bin` gets a link). When nothing needs `/usr/local/bin`
  writable, it is returned to `root:wheel`. Apple Silicon is unaffected:
  `/usr/local/bin` is already root-owned there.

### Added

- **OpenCore Legacy Patcher and macOS 11–13 support (degraded mode).** DNS, the
  DoH profiles, Firefox/Chromium ECH, the firewall, netwatch, netcheck, nettop,
  probesource, checkdns and the menu work on Intel Macs from macOS 11. Current
  Cloudflare WARP and ProtonVPN releases need macOS 14: WARP is skipped with an
  explanation below that, and ProtonVPN installs the newest release whose
  minimum macOS the Mac meets, if any.
- **`netcheck` PLATFORM INTEGRITY section**: whether this macOS still gets
  Apple security updates, OCLP detection and version, SIP, the sealed system
  volume, AMFI boot-args, T2 Secure Boot level, Gatekeeper and FileVault — the
  protections OCLP trades away, stated plainly.
- **Apps without Homebrew**: Cloudflare WARP, xbar and ProtonVPN download from
  their vendors and install only when the signature matches the vendor Team ID.
- **arp-scan NOPASSWD rule on MacPorts**, pinned to the exact invocations
  netcheck and nettop use, added only when the binary and its whole directory
  chain are root-owned. Homebrew machines keep prompting, as before.
- **Transparent layout changes for updaters.** The installer records the layout
  it installed (CPU, package manager, prefix). When it changes — typically an
  Intel Mac's home folder migrated to Apple Silicon — `git pull && ./install.sh`
  says so, re-runs every layout-dependent component (sudoers, kill-switch and
  menu, netwatch, netcheck, probesource) even under `--only`, and ends with an
  audit that fails if any installed file still names the old layout's paths
  (e.g. a `/opt/local/bin/bash` shebang, the pinned MacPorts `arp-scan` rule, or
  the Intel-era helper in `/Library/PrivilegedHelperTools`).
- README: a prominent notice that **Homebrew dropped Intel Macs in September
  2026** and why the suite moved Intel to MacPorts; a *Migrating an Intel Mac
  off Homebrew* guide; the *Intel and OpenCore Legacy Patcher Macs* section,
  with a plain caution that OCLP trades away protections the suite cannot
  restore (also shown by `netcheck` on OCLP Macs); OCLP entries in
  TROUBLESHOOTING; an *Updating* section.

### Changed

- **Second DNS fallback is now `1.1.1.2`** (Cloudflare's malware-blocking
  resolver, still DNSSEC-validating) on every platform, in the installer and
  the menu. `FALLBACK2=1.1.1.1` in `dns.conf` restores the unfiltered one.

### Fixed

- **checkdns mDNS and DNS-SD checks always reported "inconclusive"**: they
  called a `_tmo` helper that was never defined. It now exists (perl alarm;
  macOS has no `timeout`).
- **checkdns ECH handshake could never pass**: it ran `curl --ech hard` without
  `--doh-url` (curl only obtains ECH keys over DoH) against `cloudflare.com`,
  which publishes no ECH key. It now finds an ECH-capable curl, fetches keys
  over the configured DoH resolver and reads tls-ech.dev's verdict; the DNS
  check uses `crypto.cloudflare.com`. The unverified "macOS 13+ libnetwork
  supports ECH" claim is replaced by the accurate per-client note.
- **netwatch identity tracking on macOS 14.4+/15**: `ipconfig getsummary`
  prints `<redacted>` for SSID/BSSID without verbose mode; that string was
  taken as a real value, so every network looked the same and the
  `networksetup` fallback never ran. It is now treated as unknown.
- **netcheck private-MAC check** told macOS 11–14 users to enable a setting
  that only exists from macOS 15; it now says it is unavailable there.
- **LAN scans and `localip` assumed Wi-Fi/`en0`**: they now use the
  default-route interface (skipping VPN `utun`s), which matters on Intel
  iMacs and minis where `en0` is Ethernet.
- **Menu Accessibility link** opened nothing on macOS 11–12 (Ventura pane ID);
  approval paths in installer messages are worded per macOS version.
- **zsh functions broken by a `route` alias**: zsh expands aliases inside
  function bodies at definition time, and the suite's own aliases file defines
  `alias route='netstat -rn'` — so `checkdns`' default-interface lookup and
  `localip` ran `netstat -rn -n get default` in any shell where that alias
  already existed. They now call `/sbin/route`.
- **`speedtest` alias** assumed speedtest-go's `--unix`; it now detects
  speedtest-go or speedtest-cli (MacPorts) and uses the right flags.
- MacPorts paths added where only Homebrew's were probed: netwatch LaunchAgent
  `PATH`, the macOS 27 netfix interpreter lists, sleepwatcher, OUI vendor
  databases.

## [2.2.1] — 2026-10-13

### Fixed

- **README** restored after the 2.2.0 edit garbled it, and the rendered-profile
  and `dns.conf` rows moved into the *What gets installed where* table (they
  had sat above the title since 2.1.0). The 2.2.0 tag still carries the
  garbled README; use this one.

### Changed

- The "Registration Missing" entries in the README and troubleshooting doc
  now say they apply only to WARP builds before the 2026.8 series. Current
  builds keep the registration across updates and relaunch showing
  *Connected*, so the `warp-cli` re-registration is no longer needed there.

## [2.2.0] — 2026-10-13

### Added

- **`DOH_URL` / `DOH_BOOTSTRAP` overrides** in `dns.conf`. The Chromium DoH
  policy profile and the Firefox `user.js` are now templates
  (`chrome-doh-policy.mobileconfig.in`, `user.js.in`) rendered with the DoH
  target, so a machine with an AdGuard DNS account can point its browsers at
  the account resolver (`https://d.adguard-dns.com/dns-query/<device-id>`)
  instead of the public one. Without that, the AdGuard dashboard reports the
  Mac as "not connected" because its check runs in the browser.

### Changed

- The installer re-queues the Chromium policy profile when its installed DoH
  target differs from the rendered one, and rewrites the marked block in an
  existing Firefox `user.js` when it differs; a `user.js` that had its own
  `network.trr.uri` before the suite is still left alone.
- Firefox's default DoH target is now the same public resolver as Chromium's
  (`https://dns.adguard-dns.com/dns-query`) instead of the unfiltered IP URL.

## [2.1.0] — 2026-10-13

### Added

- **Per-machine overrides** in `~/.config/macos-securenetwork-suite/dns.conf`,
  sourced by both the installer and the menu-bar plugin. Set
  `FALLBACK2=1.1.1.2` there to use Cloudflare's malware-blocking resolver as
  the second fallback; re-running the installer keeps it.

## [2.0.2] — 2026-10-13

### Changed

- **The AdGuard DoH profile is a template.** `AdGuard-DoH.mobileconfig.in`
  takes its profile identifier and organization from the login name at
  install time (`com.<user>.dns.adguard-doh`), rendered to
  `~/.config/macos-securenetwork-suite/`, instead of carrying one person's
  name in the repository.

## [2.0.1] — 2026-10-13

### Fixed

- **Re-running the installer queued an AdGuard DoH profile that could not be
  approved** — Device Management failed with *"The 'VPN Service' payload could
  not be installed. The VPN service could not be created"* (mdmclient error
  -319). A DNS-settings payload is only valid at device level and the profile
  did not say so, so it was installed for the user and NetworkExtension
  refused it (*"profile must be scoped to system"*). The profile now carries
  `PayloadScope = System`; Device Management asks for an administrator
  password when you approve it. It also has its own UUIDs instead of sharing
  placeholders with the Chromium policy profile.
- **The installer never saw the Chromium DoH policy as installed** and queued
  it on every run: it only looked at device-level profiles and that one is a
  user profile. It now checks both lists, from a fresh temp file, because
  `profiles show -output` silently writes nothing to a file that already
  exists.
- **An existing encrypted-DNS profile is respected.** macOS keeps only one
  DNS-settings profile active, so installing the suite's profile on a Mac that
  already had one (an AdGuard DNS account profile, for example) silently
  disabled the other. The installer now skips its own profile when a device
  profile already provides DoH or DoT, and names it.

## [2.0.0] — 2026-10-13

A major version because the menu's behaviour changed in ways you will notice:
ProtonVPN now parks the WARP stack instead of sharing the machine with it, and
Rebuild re-applies the AdGuard DNS policy instead of restoring whatever DNS
happened to be set before the teardown.

### Fixed

- **The ProtonVPN items in the menu did nothing.** ProtonVPN 6.x registers its
  VPN service with the system, but `scutil --nc start` on it returns 0 and the
  connection never leaves *Disconnected* — the WireGuard system extension only
  connects when the app itself asks. The menu now drives the app: it opens the
  window in the background and clicks its **Quick Connect** / **Disconnect**
  button through System Events, waits for the service to report the new state,
  and hides the window again. This needs xbar in *System Settings › Privacy &
  Security › Accessibility*; without it the menu brings the app to the front,
  says what to click, and offers a one-click way to open that settings pane.
- **Connecting ProtonVPN with WARP merely disconnected blackholed the Mac.**
  Reproduced 2026-10-13: ProtonVPN came up fine, but afterwards the WARP daemon
  stopped answering its control socket while its lockdown firewall stayed up,
  and raw internet died until a manual Tear Down. ProtonVPN *Connect* therefore
  **parks** WARP first (`warp-killswitch down --keep-dns`: daemon stopped and
  disabled, DNS untouched, watchdog standing by) and *Disconnect* rebuilds it.
  The title shows 🟣 while ProtonVPN is up; a parked-but-idle WARP shows as
  ⏸️ with a *Rebuild WARP now* item, distinct from a deliberate 💀 teardown.
- **Rebuild appeared to leave the icons stale.** It restored DNS *verbatim* from
  the teardown backup — and if AdGuard had been toggled off before the
  teardown, it came back off. The menu's Rebuild now applies the suite's DNS
  policy (AdGuard + Quad9 + Cloudflare) after the helper's restore. The helper's
  own `up` is unchanged and still restores verbatim for CLI use.
- **Actions now wait for the verified end state** (tunnel address present,
  DNS servers set, VPN service status) and then explicitly ask xbar to re-run
  the plugin, so a refresh can never show the moment before the change.
  `warp_status` matches the exact tunnel address rather than any string
  containing `172.16.0.2`; `proton_status` reads the service's status directly
  instead of grepping the service list.
- `checkdns` depended on coreutils `timeout`, which a stock Mac does not have;
  it now bounds `dns-sd` itself. Its ECH probe also misread a stock `curl`
  (no `--ech` option at all) as "ECH hard mode failed".
- `alias route='netstat -rn'` shadowed the real `route`, so `route -n get
  default` broke in an interactive shell. It is `routes` now.
- `install.sh` ran the kill-switch installer with whatever `bash` was first on
  `PATH` — Homebrew's on most Macs, which on macOS 27 reads an empty ARP table
  and blinds the installer's self-test. It re-executes itself under
  `/bin/bash` and calls the component installers with `/bin/bash` explicitly.
- Homebrew has deprecated `speedtest-cli` (disabled 2027-01-18). The `deps`
  component installs `speedtest-go` instead; the `speedtest` alias uses it.

### Added

- **The macOS 27 ARP-cache agent retires itself once Apple fixes the defect.**
  `arp-cache-dump` fingerprints the macOS build, kernel and Homebrew
  interpreters, re-runs `detect.sh` when any of them change (and daily), and
  after three consecutive NOT AFFECTED verdicts ten minutes apart runs
  `uninstall.sh` on itself, posts a notification and records why in
  `~/.local/share/netwatch/selfcheck.log`. `detect.sh` reports *inconclusive*
  rather than NOT AFFECTED when the ARP table could not be measured, so the
  agent cannot retire on a false "fixed". `AUTO_UNINSTALL=0` opts out.
  Tested here by driving the confirmation counter: the agent removed its own
  LaunchAgent, helper and cache from inside the launchd job.

### Changed

- **One copy of the menu.** `components/menubar/security-toggle.5s.sh` is the
  only source; the kill-switch installer copies it to both xbar locations
  instead of carrying a second, embedded copy that drifted.
- **README rewritten** in the shape of [Panoptes](https://github.com/doug445/Panoptes):
  badges, why the suite exists, what ECH is and what macOS can and cannot do
  about it, a menu-bar section with a screenshot and a table of every title
  state, captive-portal procedure, how it compares, FAQ, caveats.
- `CHANGELOG.md`, a `lint` GitHub Actions workflow (shellcheck at warning
  level over every bash/sh tool including the helper embedded in the
  kill-switch installer, zsh syntax, XML well-formedness of the profiles and
  launchd template, SPDX header check) and SPDX MIT headers on every tool.
- Code audit: shellcheck clean at warning level across the tree (unused
  variables removed or surfaced — the identification summary now prints the
  HTTP banner and netwatch hit count it already parsed; intentional word
  splitting carries an inline directive with its reason).

## [1.0.0] — 2026-10-11

Initial import of the macOS secure-network stack: AdGuard DNS, DoH profiles,
Firefox `user.js`, Cloudflare WARP with the v3 kill-switch / watchdog, the xbar
Security Toggle menu, netwatch, netcheck, nettop, probesource, checkdns, the
macOS 27 ARP-cache workaround, and one installer with dependency bootstrap.
