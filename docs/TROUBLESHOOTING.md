# Troubleshooting

## WARP says "Registration Missing" after an update

Cloudflare's auto-updater (`com.cloudflare.warp.updater`) reinstalls the app
and recreates `/Library/Application Support/Cloudflare/warp.db`, which deletes
the registration and resets the mode to `Warp`. The GUI drops into an
onboarding picker — ignore it. Fix from the CLI, or just re-run
`./install.sh --only warp`:

```sh
warp-cli --accept-tos registration new
warp-cli --accept-tos mode tunnel_only
warp-cli --accept-tos tunnel protocol set MASQUE
warp-cli --accept-tos connect
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep '^warp='   # warp=on
```

DNS servers survive the update. Post-quantum shows `Disabled` while
unregistered and returns to `Enabled (network policy)` on its own.

## The internet is dead but Wi-Fi is connected

Usually WARP's lockdown firewall staying up while its tunnel is dead (after
sleep, a network change, a captive portal, or a wedged daemon). The watchdog
heals this on its own within about 2–3 minutes. To act now: menu › **Heal now**,
or **Last Resort: Tear Down** (DNS goes to DHCP so a captive portal can
intercept; **Rebuild** restores everything). CLI: `sudo warp-killswitch status|heal|down|up`.
Logs: `/var/log/warp-killswitch.log`, `/var/log/warp-watchdog.log`.

## ECH not working in a Chromium browser

With a system DNS profile installed, Chromium detects "enterprise-managed DNS"
and silently disables its own DoH (`secure_dns_mode: 0` despite the setting),
so it never fetches the HTTPS records that carry ECH keys. The Chromium DoH
policy profile overrides that. Check `chrome://policy` for
`DnsOverHttpsMode = secure`. Safari has no ECH implementation as of Safari 26.

## A tool reports an empty ARP table / netstat shows nothing (macOS 27)

Run `components/macos27-netfix/detect.sh` from `/bin/sh` (not Homebrew bash).
If AFFECTED, `./install.sh --only netfix`, then `components/macos27-netfix/verify.sh`.
`lsof` is unaffected and is the substitute for `netstat -an`.
Never test `arp` behaviour from Homebrew bash — it is blind there.

## netwatch notification every ~30 seconds

It is crash-looping, not repeating: launchd `KeepAlive` restarts it on
`ThrottleInterval`. Look for `FATAL exit=… at line …` in
`~/.local/share/netwatch/events.log`, and
`launchctl print gui/$(id -u)/com.netwatch` for `last exit code` / `runs`.

## Two copies of the menu-bar icons

xbar executes every executable file in its plugin folder, so a `*.bak` left
there loads as a second plugin wired to old code. Keep backups outside the
folder (the installer uses `~/Documents/SwiftBar/backups/`).
`components/macos27-netfix/postupgrade-checks.sh` finds these.
