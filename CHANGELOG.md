# Changelog

All notable changes to macOS-SecureNetwork-Suite are recorded here.
This project follows [Semantic Versioning](https://semver.org/).

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
