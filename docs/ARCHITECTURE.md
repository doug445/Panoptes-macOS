# Architecture

```
                    ┌─────────────────────────── xbar menu: Security Toggle ───────────────────────────┐
                    │  WARP on/off · Tear Down · Rebuild · Heal · Status │ AdGuard DNS on/off │ ProtonVPN │
                    └──────────┬──────────────────────────────┬─────────────────────┬──────────────────┘
                               │ sudo (NOPASSWD)              │ sudo networksetup   │ scutil --nc
                               ▼                              ▼                     ▼
  launchd ──► warp-killswitch watchdog ──► warp-killswitch {down,up,heal}     system DNS        ProtonVPN
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
  netwatch exists to catch.
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
