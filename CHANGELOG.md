# Changelog

All notable changes to macOS-SecureNetwork-Suite are recorded here.
This project follows [Semantic Versioning](https://semver.org/).

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
