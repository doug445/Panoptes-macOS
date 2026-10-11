# warp-killswitch v3 (macOS) — never blackhole again

Cloudflare WARP kill-switch, **self-healing watchdog** and xbar menu for macOS.
Port of the Linux v3 (`warp-killswitch/`), same decision logic, macOS plumbing.
Written 2026‑09‑09 from the Linux tests; **exercised on a Mac 2026‑09‑10** —
6 of 7 tests pass, four bugs found and fixed, one test still unverified. See
*Testing* below.

## Why a plain disconnect is not enough

The WARP daemon `com.cloudflare.1dot1dot1dot1.macos.warp.daemon` is a
LaunchDaemon with `KeepAlive` + `RunAtLoad`, and WARP is *Always On*. Worse,
WARP's own lockdown firewall (pf anchor `com.cloudflare.warp_svc`) stays up
while the tunnel is dead: stuck *Connecting* after sleep, after a Wi‑Fi
change, at a captive portal, or after the daemon wedges. Everything but the
LAN is dead until something intervenes. v1 only offered a manual teardown that
did not verify anything.

## What v3 does

| Piece | What it does |
|---|---|
| `warp-killswitch down` | discover the utun first; disconnect (time‑bounded); `launchctl bootout` + `disable` (survives reboot; SIGCONT first, SIGKILL fallback); flush the pf anchor and sub‑anchors; delete **every** route on the utun (v4 and v6 — measured at 471 here: 198 + 273); remove `State:/Network/Service/CloudflareWARP`; DNS → DHCP on **every** network service (`--keep-dns` leaves it); flush mDNSResponder; then **prove** plain internet works, escalating (re‑flush → bounce the network service). |
| `warp-killswitch up` | restore DNS verbatim; `enable` + `bootstrap`; connect; **wait for Connected and a raw‑IP check**; roll back to a clean disconnected state if the tunnel never comes. |
| `warp-killswitch heal` | the decision procedure (below), on demand. |
| `local.warp-killswitch.watchdog` | LaunchDaemon running `warp-killswitch watchdog`: every 10 s probe raw IP (parallel pings, then TCP 443 by address, no DNS); after 3 failures with the link up, `heal`. Never acts while killed. **Measured end-to-end latency on a wedged daemon: ~137 s**, not the 45 s the interval suggests — each iteration also pays `tmo 8` against the unresponsive daemon and two `netstat` route dumps for `artifacts_desc`. |
| wake handling | **Built into the watchdog, no dependencies:** a wall-clock jump > 120 s between iterations means the machine slept, so it reconnects and verifies. A stale tunnel after wake is the most common way the Mac tunnel dies. |
| `local.warp-killswitch.sleepwatcher` | *Optional legacy path.* Wired up only if `sleepwatcher` already exists on the machine; it adds a clean disconnect **before** sleep. Not required and not recommended to install — nothing here needs a package manager. |
| xbar `security-toggle.5s.sh` | existing WARP / AdGuard / ProtonVPN toggles, plus *Tear Down*, *Rebuild* (while killed), *Heal now*, *Status* (dialog), and a watchdog indicator. `warp-cli` calls are time‑bounded so a wedged daemon cannot freeze the menu. |

Link test uses `route get default` + `ifconfig status: active` + gateway
**ARP** (`nc -z -G 1` to force resolution, then `arp -n`). Gateway ping is
never used: many APs drop it.

**macOS 27 note.** A process forked from a non-Apple-signed binary (xbar,
Homebrew bash, iTerm, kitty) reads an *empty* ARP table (see
`components/macos27-netfix`). Networking itself is unaffected, so the raw-IP
probes are fine; only the ARP link test is. `link_ok` detects a blanked table,
uses `~/.local/share/netwatch/arp.cache` (the macos27-netfix LaunchAgent) when
it is under 120 s old, and otherwise judges the link by interface state.
`status` shows which method was used (`via=arp|arpcache|ifstate(arp-blank)`).
The watchdog runs from launchd → `/bin/bash`, so it is never tainted, and
`down`/`up`/`heal` **re-dispatch themselves through launchd** (on-demand
`local.warp-killswitch.do-*` LaunchDaemons, started with `launchctl kickstart`)
whenever the caller is tainted, then wait and echo the job's log — so the menu
and any terminal get the same clean view the watchdog has. The
timeout wrapper is pure bash (no perl). Plugin backups go to
`~/Documents/SwiftBar/backups/`, never into the xbar plugin folder.

## How `heal` decides

1. Killed by you → do nothing.
2. Physical link down → not WARP, do nothing.
3. Raw IP works → healthy; purge leftovers if the daemon is dead; flush DNS
   caches if IP works but lookups fail.
4. Offline, **no WARP artifacts** (pf rules, utun with `172.16.0.2`, SC keys)
   → upstream/ISP, back off 5 min.
5. Offline, **daemon dead, artifacts remain** → purge them.
6. Offline, daemon alive, artifacts present → clean `disconnect`:
   - artifacts survive → daemon wedged → `down --keep-dns --fast`, WARP stays
     off until you Rebuild;
   - still offline → not WARP → reconnect, back off;
   - online and a **captive portal** is intercepting → leave WARP off, tell
     you to log in;
   - online → retry `connect` once, wait ≤ 30 s; failure → leave WARP off.

Every path ends with a notification stating the verified outcome.

## Install

```sh
sudo bash components/warp-killswitch/install.sh   # or just run the suite installer
```

No package manager, and no third-party binary, is required — wake handling is native
(see the table above). The installer also **audits every absolute binary path** in the
scripts it generates against the machine it is installing to, and prints any that do not
exist; treat a red line there as a bug to fix, not a warning to skip.

Options: `--user NAME` (menu owner, default `$SUDO_USER` / console user),
`--no-menu`, `--no-watchdog`, `--no-sleep-hook`, `--uninstall` (rebuilds WARP
if killed, removes helper, sudoers, both LaunchDaemons, restores the plugin
backups). Idempotent.

Installs: `/usr/local/bin/warp-killswitch`, `/etc/sudoers.d/warp-killswitch`,
`/Library/LaunchDaemons/local.warp-killswitch.{watchdog,sleepwatcher}.plist`,
the three on-demand `local.warp-killswitch.do-{down,up,heal}.plist` re-dispatch targets,
both xbar plugin copies (originals → `~/Documents/SwiftBar/backups/`, once,
non-executable). State in
`/var/db/warp-killswitch/` (`killed` marker, DNS backups, mutex). Logs in
`/var/log/warp-killswitch.log` and `/var/log/warp-watchdog.log`.

## CLI

```sh
sudo warp-killswitch status
sudo warp-killswitch heal
sudo warp-killswitch down [--keep-dns]
sudo warp-killswitch up
sudo warp-killswitch verify
tail -f /var/log/warp-killswitch.log
```

## Testing — results of the first macOS run (2026‑09‑10)

Run in order. Verdicts are from an actual run on MacBookPro16,1 / macOS Tahoe 26.7,
WARP in tunnel-only mode over MASQUE.

1. **PASS** — `sudo warp-killswitch status`: every line sensible, `watchdog: running`.
2. **PASS (18/18 assertions)** — `sudo warp-killswitch down` → `verify` online, `state`
   killed, DNS DHCP on all six services, `pfctl -a com.cloudflare.warp_svc -sr` empty,
   no utun with `172.16.0.2`, 0 utun routes left, daemon booted out *and* `=> disabled`,
   default route back on `en0`, `curl -o/dev/null http://captive.apple.com` = 200
   → `sudo warp-killswitch up` → Connected, DNS restored byte-identical, `warp=on`.
   Timing: `down` 3 s, `up` 6 s.
3. **PASS** — Crash: `sudo kill -9 $(pgrep -f 'Resources/CloudflareWARP')`. launchd
   restarted it inside ~9 s and WARP returned to Connected on its own; raw-IP probes
   never failed, so the watchdog correctly logged **nothing**. Internet never dropped.
4. **PASS (7/7)** — Freeze: `sudo kill -STOP <pid>`. The decision path ran exactly as
   designed: `offline with link up (1/3→3/3)` → soft reset → *disconnect did NOT clear
   WARP's artifacts — daemon wedged* → `down --keep-dns --fast` → online, notification,
   WARP off and disabled, **DNS provably untouched** (no `dns-swapped` marker, resolvers
   unchanged). Then `sudo kill -CONT <pid>; sudo warp-killswitch up` → Connected.
   **Detection took 137 s, not ~60 s** — see the watchdog row above. Budget ≥ 3 min.
5. **UNVERIFIED** — Dead tunnel. The obvious recipe does not work; three separate
   traps, all now known:
   - A bare anchor is **never evaluated**. macOS's main ruleset references only
     `anchor "com.apple/*"` and `anchor "com.cloudflare.warp_svc"`, so
     `pfctl -a ks_test -f -` loads rules that pf never consults. Nest under
     `com.apple/`, and confirm with `pfctl -a com.apple -s Anchors`.
   - Get the endpoint from `warp-cli tunnel stats`; do not assume a range.
     It was `162.159.198.2` here, which `162.159.192.0/22` does not even contain.
   - **Existing pf state bypasses a newly loaded block.** WARP's UDP flow to the edge
     is a long-lived `keep state` entry, so the rule only applies to new packets.
     Flush it or nothing happens.

   The working form:

   ```sh
   ep=$(warp-cli --accept-tos tunnel stats | awk -F': ' '/Endpoints/{print $2}' | cut -d, -f1)
   printf 'block drop out quick inet proto udp from any to %s\n' "$ep" \
     | sudo pfctl -a com.apple/ks_test -f -
   sudo pfctl -k 0.0.0.0/0 -k "$ep"          # without this the block does nothing
   # cleanup:
   sudo pfctl -a com.apple/ks_test -F all
   ```

   Even so this only broke the tunnel briefly: WARP re-handshaked and recovered before
   the watchdog reached 3/3 (it logged one `1/3` and correctly declined to act on a
   single failure). A persistent *stuck Connecting* state could not be induced this
   way, so heal's captive-portal and reconnect-retry branches remain untested.
6. **PASS** — `sudo warp-killswitch sleep-pre` → Disconnected + resume mark set;
   `sudo warp-killswitch sleep-post` → Connected in ~8 s, mark cleared. Also verified
   `sleep-pre` is a no-op while killed.
   The **native wake path** was tested separately by `SIGSTOP`-ing the watchdog for 35 s to
   force a real wall-clock gap in its loop (threshold temporarily lowered to 20 s): it logged
   `wall-clock jumped 36s — machine woke from sleep` and then `wake: tunnel already healthy`,
   correctly taking no action on a healthy tunnel. A real close‑lid / open‑lid cycle is still
   worth doing by hand.
7. **PASS** — Menu: renders correctly, `watchdog: active`, both plugin copies byte-identical,
   the pre-killswitch backup sits in `~/Documents/SwiftBar/backups/` (the plugin dir holds
   exactly one executable, so xbar shows one icon set), and `Heal now` through the
   NOPASSWD sudoers rule works when run as the menu owner. The `Status` dialog was not
   clicked through.

### Four bugs this run found (all fixed in `install.sh`)

Every one was silent, because each call site redirects to `/dev/null`.

1. **`netstat` is `/usr/sbin/netstat` on macOS**, not `/usr/bin/netstat` — hardcoded wrong
   in `utun_routes()`. Likewise `chown` is `/usr/sbin/chown`; `/usr/bin/chown` does not exist.
2. **`awk '$NF==i || $(NF-1)==i'` aborts fatally** on `netstat`'s blank header line
   (record 2, `NF=0` → `$-1`), so it emitted nothing even once the path was right.
   Guard with `NF>=2 &&`.
3. **`netstat` abbreviates classful networks** — it prints `1` for 1.0.0.0/8 and
   `162.158` for 162.158.0.0/16. Feeding those to `route delete -host` mis-parses them
   through `inet_aton` (`1`→0.0.0.1, `162.158`→162.0.0.158), so 10 of 471 routes
   survived a teardown. Rebuild the CIDR from the octet count instead.

Bugs 1 and 2 together meant the route purge enumerated **nothing at all** — 0 routes
instead of 471 — and `artifacts_desc` permanently reported `routes=0`. What masks it in
everyday use: when the daemon dies the utun is destroyed and the kernel drops its routes
anyway, so the deletion loop mainly earns its keep on the wedged-daemon path, where the
interface persists.

### Portability: Apple Silicon and other macOS releases

**Everything above was measured on one machine: MacBookPro16,1, Intel, macOS 26.7
(25G227).** Nothing here was tested on Apple Silicon or on macOS 27, so the fixes are
written to not depend on what that one box happened to look like:

- The binaries the fixes point at are **universal**, at identical paths — `lipo -archs`
  reports `x86_64 arm64e` for `/usr/sbin/netstat`, `/usr/sbin/chown`, `/usr/bin/awk`,
  `/sbin/route`, `/sbin/pfctl` and `/usr/sbin/arp`. macOS's filesystem layout is
  arch-independent, so these resolve the same on arm64.
- `netstat` is nevertheless resolved through a **`_bin` probe** (`/usr/sbin` then
  `/usr/bin`), and `chown` likewise in the installer, so a release that moves either one
  still works. The probe only ever yields an absolute path — it never falls back to a
  `PATH` lookup, which interactive rc files shadow.
- `install.sh` now runs an **install-time path audit** over the generated helper and both
  plugin copies: every hardcoded absolute binary path is checked for existence on the
  machine being installed to, and a missing one is reported in red. This is the guard that
  would have caught both original path bugs immediately, on any arch or release, instead of
  them hiding behind `2>/dev/null` for a version and a half.
- **No Homebrew anywhere.** The one third-party dependency (`sleepwatcher`, for the
  sleep/wake hook) is gone: wake detection now lives in the watchdog itself as a wall-clock
  gap check, so there is nothing to install and nothing that breaks if Homebrew stops
  shipping for a given arch or release. `PATH` in both scripts stays on system directories
  only. The plugin also gained the `warp-cli` fallback the helper already had — though
  `warp-cli` is arch-neutral regardless: `/usr/local/bin/warp-cli` is a symlink into
  `/Applications/Cloudflare WARP.app`, and that binary is universal (`x86_64 arm64`).
- Still unverified on Apple Silicon / macOS 27, and worth re-checking there: whether
  `netstat -rn` abbreviates classful networks the same way (bug 3's fix assumes N octets
  means an N×8 prefix), and whether the macOS 27 enumeration blank also empties
  `netstat -rn` for a tainted caller — if it does, `utun_routes` returns nothing again for
  menu/terminal callers, and the launchd re-dispatch is what saves it, not these fixes.

### What turned out NOT to need adjustment

Both formats the previous draft flagged as risky are fine on Tahoe 26.7: `pfctl -s Anchors`
(its "No ALTQ support" chatter goes to **stderr**, so `pf_rules_present`'s `2>/dev/null` is
correct), and `launchctl print system/<label>` does report `state = running`. The macOS 27
ARP-blank taint also did not reproduce from a Homebrew/agent bash — `arp -an` read fine and
`tainted` returned false — but note `~/.local/share/netwatch/arp.cache` does not exist on
this machine, so if it ever does blank, `link_ok` falls straight through to
`ifstate(arp-blank)` rather than the cache.

Also worth knowing: `tmo N` really takes about **1.3 × N** (it forks `/bin/sleep 0.1` each
iteration), so `tmo 8` ≈ 10 s and the 15 s `bootout` bound ≈ 19 s.

## Lessons carried over from Linux (2026‑09‑09)

- The blackhole is WARP's own DROP firewall with a dead tunnel; a clean
  `disconnect` removes it, so remediation must start with a *time‑bounded*
  disconnect and only escalate if artifacts survive.
- `up` that fires `connect` and hopes can itself blackhole the box.
- Never use gateway ping as the link test.
- Distinguish "not WARP" (artifacts gone, still offline) from "WARP wedged"
  (artifacts survive a disconnect) before doing anything destructive.
- Menu and watchdog need a mutex; a probe body of `success\n` is not `success`.

## Lessons added by the macOS run (2026‑09‑10)

- Absolute paths are only as good as their spelling: `netstat` and `chown` live in
  `/usr/sbin`, not `/usr/bin`. A wrong path plus `2>/dev/null` is an invisible no-op —
  audit every hardcoded binary against the filesystem, don't eyeball it.
- `$(NF-1)` is a loaded gun in `awk`: any short or blank line makes it fatal and kills
  the whole stream, not just that record. Guard the field count first.
- Never feed a `netstat` destination straight back to `route`: the two disagree about
  notation, and `inet_aton` silently reinterprets abbreviated forms.
- A pf rule in an unreferenced anchor is inert, and a pf rule of any kind cannot touch
  a flow that already has a `keep state` entry. Both make a firewall test look like it
  passed when it never ran.
- Fault-injection tests need their own verification step: assert the fault actually
  happened before asserting the response to it.
- Don't let a single test machine set the assumptions. Verify that a path is universal
  (`lipo -archs`) rather than that it exists, probe for the ones that might move, and make
  the installer assert its own assumptions on the machine it is installing to.
