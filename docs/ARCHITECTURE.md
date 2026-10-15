# Architecture

```
                    ┌─────────────────────────── xbar menu: Security Toggle ───────────────────────────┐
                    │  WARP on/off · Tear Down · Rebuild · Heal · Status │ AdGuard DNS on/off │ ProtonVPN │
                    └──────────┬──────────────────────────────┬─────────────────────┬──────────────────┘
                               │ sudo (NOPASSWD)              │ sudo networksetup   │ System Events (Accessibility)
                               ▼                              ▼                     ▼
  launchd ──► warp-killswitch watchdog ──► warp-killswitch {down,up,heal}     system DNS        ProtonVPN.app
                                                                                                  Quick Connect / Disconnect
  (root)        every 10 s: raw-IP probe        │   tainted caller? re-dispatch     │
                wake = wall-clock gap > 120 s   │   via local.warp-killswitch.do-*  │
                                                ▼                                   ▼
                                  Cloudflare WARP daemon ── utun (172.16.0.2) ── AdGuard DNS
                                  pf anchor com.cloudflare.warp_svc              94.140.14.140/141
                                                                                 + DoH profiles (system,
                                                                                   Chromium, Firefox)

  Application Firewall (stealth + logging) ──► unified log ──► netwatch (LaunchAgent)
                                                                 ├─ port-scan alerts
                                                                 ├─ gateway identity: ssid|gw|mac|ll|bssid
                                                                 └─ events.log ──► nettop, netcheck, probesource

  macOS 27 only: com.netwatch.arpcache (LaunchAgent, /bin/sh, every 15 s)
                 └─ arp -an ──► ~/.local/share/netwatch/arp.cache ──► arp_table() in every bash-4 tool
                                                                     and warp-killswitch link_ok()
```

## Design rules carried through every component

- **Prove, don't assume.** Teardown verifies plain internet works and escalates
  until it does; rebuild waits for `Connected` *and* a raw-IP check, and rolls
  back to a clean disconnected state otherwise.
- **Never act on a blind view.** On macOS 27 a process forked from a
  non-Apple-signed binary (xbar, Homebrew bash, iTerm) sees an empty ARP table
  and socket list. Tools read through `arp_table()` (direct read, then a
  freshness-checked cache); `warp-killswitch` re-dispatches itself through
  launchd when its caller is tainted.
- **Stale data is worse than none.** The ARP cache is refused after 120 s and
  the refusal is reported — a stale gateway MAC would hide exactly the spoofing
  netwatch exists to catch. The publisher therefore writes even an empty table,
  so "stale" can only mean "publisher stopped", and the report is rate-limited
  through a marker file because the check runs in subshells.
- **Fail loudly.** netwatch has an `ERR` trap that logs `FATAL exit=N at line N`,
  because a silent `set -e` death under launchd `KeepAlive` became an endless
  notification loop once.
- **Absolute paths for system tools, audited at install time.** A wrong path
  behind `2>/dev/null` is an invisible no-op.
- **Time-bound everything that talks to the WARP daemon.** A wedged daemon must
  not freeze the menu or the watchdog.

## Gateway-identity detection (netwatch)

The fingerprint is `ssid|gw|mac|ll|bssid`. A change of SSID or gateway IP
re-baselines silently (you moved networks). A change of the gateway's MAC or
IPv6 link-local *on the same network* alerts. A BSSID change alone is logged
as `ROAM` and never alerts — routers band-steer between their own radios
several times a day. MACs are canonicalised (`arp` prints `0`, EUI-64 decoding
prints `00`) on both sides before comparison.

## Switching between WARP and ProtonVPN

The two cannot share the machine: when ProtonVPN's WireGuard system extension
takes the network, a merely-disconnected WARP daemon wedges with its lockdown
`pf` anchor still loaded and raw internet dies (reproduced 2026-10-13). So the
menu's ProtonVPN *Connect* first **parks** WARP — `warp-killswitch down
--keep-dns`: daemon stopped and disabled, DNS untouched, `killed` marker set so
the watchdog stands by — and records that it did so in
`~/.local/state/macos-securenetwork-suite/warp-parked-for-protonvpn`. *Disconnect*
clears the marker and runs `warp-killswitch up`. A deliberate *Tear Down* removes
the marker, so the menu can tell "parked for ProtonVPN" (⏸️) from "killed" (💀).

ProtonVPN itself is driven through its app: `scutil --nc start` on its service
is a no-op on ProtonVPN 6.x, so the plugin opens the app's window in the
background and clicks **Quick Connect** / **Disconnect** with System Events,
waits for `scutil --nc status` to report the new state, then hides the window.
This is the one place the suite needs an Accessibility grant (for xbar).
