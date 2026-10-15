# macOS 27 network-enumeration fix

Read this fully before changing anything here. It exists so that nobody has
to rediscover a two-hour diagnosis, or repeat two dead ends that look correct
and are not.

Origin: found and fixed 2026-08-07, macOS 27.0 build
26A5388g (Golden Gate public beta 2), Apple silicon.

---

## What you will see

One or more of:

- A launchd script fires its **startup notification every ~20–30 seconds**
  (it is not repeating a notification — it is crash-looping and restarting).
- ARP-based tooling silently reports nothing. No error, no crash.
- `netstat -an` shows no connections.
- Scripts that "worked before the upgrade" now produce empty output.

## The actual defect

**On macOS 27, a process forked by a non-Apple-signed binary reads an EMPTY
ARP table and an EMPTY Internet socket list.**

It is inherited and cannot be escaped by re-exec: calling `/bin/sh`,
`/bin/zsh`, `/bin/bash`, or `env` *from inside* a tainted process is still
tainted. The taint is established the moment a non-Apple binary forks.

Precise trigger is **forking**. `bash -c 'arp -an'` works, because bash execs a
lone simple command in place without forking. A script file, a pipeline,
`$(...)`, or process substitution all fork, and all come back empty. This is
why a quick manual test can wrongly suggest everything is fine.

### Measured scope (tainted vs clean, same machine, same moment)

| command | tainted | clean | verdict |
|---|---|---|---|
| `arp -an` | 0 | 15 | **fully blanked** |
| `netstat -an` (tcp/udp rows) | 0 | 73 | **fully blanked** |
| `netstat -rnf inet` | 211 | 226 | link-layer rows stripped |
| `ndp -an` | 15 | 19 | partially stripped |
| `lsof -nP -i` | 83 | 83 | **unaffected** |
| `ifconfig`, `scutil`, `route`, `networksetup` | same | same | unaffected |
| DNS / TCP / ICMP (actual traffic) | works | works | unaffected |

It gates **enumeration of network state**, not networking itself. `lsof` is
completely unaffected and is the correct substitute for `netstat -an`.

Root cause is **not confirmed**. No TCC or sandbox denial is logged when it
happens. Treat the workaround as a workaround.

---

## Two dead ends — do not spend time here

**1. It is not an `ifscope` problem.** The obvious first theory is that
`arp -n <ip>` cannot see entries carrying an `ifscope` qualifier, because
`arp -n <ip>` returns "no entry" while `arp -an` lists the host. That theory is
wrong. It only looks true because the test was run under Homebrew bash.
Untainted, `arp -n <ip>` works fine. Verify any `arp` behavior from **zsh or
`/bin/bash`**, never from Homebrew bash.

**2. Rebuilding or reinstalling bash does not fix it.** Homebrew `python3` is
affected identically while Apple's `/usr/bin/python3` is not — so this is not
about bash at all, it is about *any* non-Apple binary. `brew reinstall bash`
re-pours the same `arm64_tahoe` (macOS 26) bottle. A `--build-from-source`
rebuild produces another adhoc-signed non-platform binary with the same
behavior. Re-signing with `codesign -f -s -` also does nothing, so it is not
signature staleness.

**3. `#!/usr/bin/env bash` is not clean.** It resolves to Homebrew bash when
`/opt/homebrew/bin` precedes `/bin` in PATH — which it does here. Same for
`#!/usr/bin/env python3`. Check the *resolved* path, never the shebang text.

---

## The fix

An Apple-rooted LaunchAgent publishes the ARP table to a file; the tainted
scripts read that file when their own read comes back empty.

```
com.netwatch.arpcache  (LaunchAgent, StartInterval 15)
    └─ /bin/sh  ← MUST be an Apple binary, this is the whole point
         └─ arp-cache-dump  →  ~/.local/share/netwatch/arp.cache
                                        ↑
              netwatch / nettop / netcheck / probesource read this
              via arp_table(), which tries a direct read first
```

`arp_table()` tries the direct read first, so the scripts still work correctly
when run by hand from zsh, and on any machine or OS where the restriction does
not apply.

### When Apple fixes it

Nothing to do. The two halves of the fix retire differently:

- **The agent removes itself.** Each run, `arp-cache-dump` fingerprints the
  macOS build, kernel, and Homebrew `bash`/`python3` versions. When that
  changes (and once a day anyway) it re-runs `detect.sh`. After **3
  consecutive NOT AFFECTED verdicts, 10 minutes apart**, it runs
  `uninstall.sh` on itself, posts a "NetWatch" notification, and records why
  in `~/.local/share/netwatch/selfcheck.log`. Any AFFECTED verdict resets the
  count. An inconclusive one (empty ARP table) retries without counting.
- **The `arp_table()` patches in consumer scripts stay.** They prefer the
  direct read, so on a fixed system they are inert. Leave them, or remove them
  by hand.

Removing itself only when ARP is confirmed readable is deliberate. If the
agent left on a false "fixed", netwatch would go blind with no warning. That
is why `detect.sh` returns inconclusive, not NOT AFFECTED, when it cannot
measure the ARP table.

---

## Deploy

```sh
cd components/macos27-netfix
./detect.sh        # read-only; 0 = affected, 1 = not affected, 2 = inconclusive
./install.sh       # idempotent; safe to re-run
```

`install.sh` refuses to install if `detect.sh` says the machine is fine.
Self-uninstall is on by default (see above). `AUTO_UNINSTALL=0 ./install.sh`
turns it off. `./uninstall.sh` is still there for removing it early by hand.

It is Intel-aware (finds the Homebrew prefix) and derives all paths from
`$HOME`, so nothing is hardcoded to one user.

### Patching consumer scripts

`install.sh` **does not edit your scripts** — it cannot know what is on a given
machine. It prints the list of scripts that need patching. For each one:

1. Insert the helper from `lib/arp_table.bash` near the other helpers.
2. Replace every `arp -an ...` / `arp -n "$ip" ...` read with `arp_table | ...`.
3. Keep the awk column match: entries look like
   `? (192.168.0.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]`
   so `$2` is `(<ip>)` and `$4` is the MAC.

On the origin machine the patched consumers were `netwatch`, `nettop`,
`netcheck`, and `probesource` in `~/.local/bin`.

---

## Also fix: the crash loop

The empty ARP table is what *killed* netwatch, but `set -euo pipefail` is what
turned a failed lookup into a restart loop:

```bash
gateway_mac=$(arp -n "$ip" 2>/dev/null | awk '...')
```

`pipefail` propagates `arp`'s exit 1 into the assignment and `set -e`
terminates the shell — before the main loop, so the script never monitored
anything. launchd then restarted it on `KeepAlive`/`SuccessfulExit=false`,
re-firing the startup notification each time. `ThrottleInterval 30` is why the
user perceives "every 20–30 seconds".

**Harden every helper that shells out**, so a transient failure degrades
instead of killing the process:

```bash
get_gateway_ip() { route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}' || true; }
```

Note `stderr` will be **empty** in this failure mode if the failing command has
`2>/dev/null` on it. Do not conclude "no error" from an empty stderr log —
check `launchctl print gui/$UID/<label>` for `last exit code` and `runs`.

### Fail loudly, not silently

netwatch refuses an ARP cache older than 120s and raises a "NetWatch Degraded"
notification. This matters: a stale cache reports the **pre-attack** gateway
MAC, which would mask exactly the ARP spoofing the script exists to detect.
Preserve that behavior in anything you port. Same reasoning applies to
`netstat` fallbacks — report "could not look", never let it read as
"nothing found".

Two refinements, both learned the hard way (2026-10-15):

- **An empty table is still a write.** The dumper publishes whatever `arp -an`
  returns, empty included, so the cache mtime only stops moving when the
  agent itself has stopped. It used to withhold empty results, and a hotspot
  whose gateway never completes ARP froze the mtime for 16 minutes — an idle
  table read as a dead agent.
- **Rate-limit through a file, not a variable.** `arp_table()` is called
  inside `$(...)` and `| awk`, so a "warned already" shell variable set there
  never reaches the main loop; the Degraded notification fired on every 10 s
  poll. The marker is `~/.local/share/netwatch/arp_stale_notified` and repeats
  at most hourly (`ARP_STALE_REPEAT`).

---

## Unrelated macOS 27 upgrade breakage seen on the same machine

Run `./postupgrade-checks.sh` for a read-only report on these. They are
independent of the ARP issue.

**Finder window with no traffic lights that will not close.** Almost certainly
the **Finder Settings** window, which is not a "Finder window" and so ignores
the usual close paths. It survives `killall Finder` and is restored at
identical bounds. Fix:

```sh
osascript -e 'tell application "Finder" to close window "Finder Settings"'
```

Diagnose with `osascript -e 'tell application "Finder" to get {name, bounds} of every window'`
before killing Finder — the window list names the culprit.

**Duplicate menu-bar icon sets.** xbar runs *every executable file* in its
plugin directory. A backup like `myplugin.5s.sh.pre-change.bak` left `+x` in
that folder loads as a second plugin with identical icons, wired to stale code.
Move backups out of the plugin directory entirely.

**An app insists a permission is off while System Settings shows it on**
(seen with Bartender and Screen Recording). Stale TCC record whose bundle no
longer matches after the upgrade. The app's own check is the honest one:

```sh
tccutil reset ScreenCapture <bundle-id>   # then relaunch and re-approve
```

---

## Verify

```sh
./verify.sh
```

Checks the agent is loaded, the cache is fresh and non-empty, and that a
tainted process can now resolve the gateway MAC. Expected healthy output:

```
direct arp -an   : 0 lines      <- still blind, expected
arp_table        : 15 lines     <- via cache
gateway MAC      : aa:bb:...    <- resolved
```

`com.netwatch.arpcache` showing `state = not running` is **correct** — it is a
`StartInterval` job that fires briefly and exits. Judge it by cache freshness,
not by process state.

## Files

| path | purpose |
|---|---|
| `detect.sh` | read-only; is this machine affected, and what is restricted |
| `install.sh` | installs helper + LaunchAgent + self-uninstall kit; idempotent |
| `uninstall.sh` | removes all of it; the agent runs it itself once fixed |
| `verify.sh` | end-to-end health check via the tainted path |
| `postupgrade-checks.sh` | Finder / xbar / TCC checks, read-only |
| `lib/arp-cache-dump` | the `/bin/sh` publisher + self-check |
| `lib/arp_table.bash` | snippet to paste into consumer scripts |
