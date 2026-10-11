# macOS-SecureNetwork-Suite

A complete, self-healing private-network stack for macOS: encrypted, filtered
DNS; a Cloudflare WARP tunnel that can never blackhole the machine; a menu-bar
control panel; and a set of monitors and diagnostics that watch the network for
probes, ARP spoofing and evil twins; ProtonVPN optional if WARP is not selected.

One installer sets up everything, **including its dependencies**.

```sh
git clone https://github.com/doug445/macOS-SecureNetwork-Suite.git
cd macOS-SecureNetwork-Suite
./install.sh            # as your normal user — it asks for sudo once
```

## What's in it

| Layer | Component | What it does |
|---|---|---|
| DNS | `dns` | AdGuard DNS privacy servers (`94.140.14.140/.141` — no logging, no ECS) with Quad9 and Cloudflare as fallbacks, on Wi-Fi and iPhone USB |
| DNS | `profiles` | **AdGuard DoH** system profile (encrypted DNS + HTTPS records for ECH in Safari/WebKit) and a **Chromium DoH policy** that forces secure DoH in Chrome, Brave, Edge, Vivaldi and Opera — without it they detect "managed DNS", silently turn DoH off, and lose ECH |
| DNS | `firefox` | `user.js` for every Firefox profile: DoH to AdGuard, ECH, HTTPS-only, TLS 1.2+, OCSP required |
| Tunnel | `warp` | Cloudflare WARP in `tunnel_only` mode over MASQUE; recreates the registration if a WARP auto-update wiped it |
| Tunnel | `killswitch` | **warp-killswitch**: verified teardown/rebuild, a root watchdog that detects a dead tunnel or a wedged daemon and repairs it, wake-from-sleep reconnect, captive-portal handling. Details: [components/warp-killswitch](components/warp-killswitch/README.md) |
| Menu bar | `killswitch` | **Security Toggle** xbar plugin: WARP / AdGuard DNS / ProtonVPN toggles with mutual exclusion, Tear Down, Rebuild, Heal now, Status, watchdog indicator |
| Monitor | `netwatch` | LaunchAgent watching the Application Firewall's stealth-mode drops: port-scan alerts, gateway-identity (ARP spoofing / evil twin) detection, network-change notices. `nettop` summarises its log by source |
| Monitor | `firewall` | Application Firewall on, stealth mode, logging (netwatch's input) |
| Report | `netcheck` | One-shot security report: firewall, listening ports, WARP + exit check, DNS, ARP table, recent drops with vendor/rDNS, MAC randomisation, addresses |
| Report | `shell` | `checkdns` (mDNS, resolvers, DNSSEC, DoT, DoH, ECH, VPN + DNS-leak, smoke test) plus network aliases and functions for zsh |
| Investigate | `probesource` | TUI to investigate the source of a drop or connection with passive → aggressive tactics. [Details](components/probesource/README.md) |
| Fix | `netfix` | macOS 27 workaround: processes forked from non-Apple binaries read an **empty ARP table**. An Apple-rooted agent publishes it to a cache the tools read. Installs only if `detect.sh` measures the defect. [Details](components/macos27-netfix/README.md) |

## Dependencies — installed automatically

The `deps` component installs whatever is missing:

- **Homebrew** (official installer, non-interactive; it brings the Xcode Command Line Tools)
- **Formulae:** `bash` (netwatch/netcheck need bash ≥ 4), `nmap`, `arp-scan`, `watch`, `speedtest-cli`
- **Casks:** `cloudflare-warp`, `xbar`, `protonvpn` — skipped if the app is already in `/Applications`
- **probesource probe toolset:** GNU userland (`grep`, `gnu-sed`, `coreutils`, `gawk`), `dialog`, `wireshark`, `p0f`, `mtr`, `masscan`, `sslscan`, `ike-scan`, `samba`, `pipx` + `enum4linux-ng`, and `onesixtyone` / `nbtscan` built from source

Skip with `--no-deps`. Homebrew is never run as root.

## Installer options

```sh
./install.sh --list                       # component names
./install.sh --only warp,killswitch       # just these
./install.sh --skip probesource,firefox   # all but these
./install.sh --no-deps                    # don't install dependencies
./uninstall.sh
```

Everything is idempotent; re-running repairs drift. Files the installer
replaces are backed up as `*.bak.<timestamp>` first.

**One step needs you:** macOS will not install configuration profiles silently
— approve them in *System Settings › General › Device Management*. (ProtonVPN
needs nothing: the menu looks its service up in `scutil --nc list`, and launches
the app if it isn't running.)

## What gets installed where

| Path | From |
|---|---|
| `/usr/local/bin/warp-killswitch` | killswitch |
| `/Library/LaunchDaemons/local.warp-killswitch.{watchdog,do-down,do-up,do-heal}.plist` | killswitch |
| `/etc/sudoers.d/warp-killswitch`, `securenet-dns`, `securenet-netcheck` | killswitch, sudoers |
| `~/Library/Application Support/xbar/plugins/security-toggle.5s.sh` (+ source copy in `~/Documents/SwiftBar/`) | killswitch |
| `~/Library/LaunchAgents/com.netwatch.plist`, `com.netwatch.arpcache.plist` | netwatch, netfix |
| `~/.local/bin/{netwatch,nettop,netcheck,probesource,arp-cache-dump}` | netwatch, netcheck, probesource, netfix |
| `~/.config/macos-securenetwork-suite/*.zsh` + a marked block in `~/.zshrc` | shell |
| State / logs: `/var/db/warp-killswitch/`, `/var/log/warp-*.log`, `~/.local/share/{netwatch,probesource}/` | |

## Security notes

- The NOPASSWD sudoers rules cover **Apple binaries only** (`networksetup -setdnsservers`,
  `killall -HUP mDNSResponder`, `profiles show`) plus the root-owned
  `warp-killswitch` helper. `arp-scan` is deliberately excluded: it sits in the
  user-writable Homebrew prefix and can write files, so a NOPASSWD rule for it
  would be a root escalation. `netcheck`/`nettop` prompt for it instead.
- `probesource`'s active and aggressive tactics send packets to the target.
  Use them only on hosts and networks you own or are authorised to test.

## Docs

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the pieces fit together
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — WARP updates, ECH, the macOS 27 ARP blank, crash loops

## License

MIT — see [LICENSE](LICENSE).
