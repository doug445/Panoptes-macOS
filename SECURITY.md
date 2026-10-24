# Security

This suite installs a passwordless root helper, sudoers rules, LaunchDaemons, a
network extension (LuLu), a root daemon (BlockBlock) and a monitor that reads
the wire. Software like that has to be able to say, plainly, what it lets happen
without a password and what it does not. This file is that statement. The
project's standing policy is that every major release gets a full, independent,
line-by-line security audit before it ships; the most recent is the 4.1 audit by
**Claude Fable 5.1, Anthropic's most capable model**, recorded in full at the
end of the [README](README.md#full-security-audit-41--claude-fable-51).

## Reporting

Please do not open a public issue for a vulnerability. Email
**spilled-bowline0j@icloud.com** with what you found and how to reproduce it.
You will get an acknowledgement, a fix in the open, and credit in the changelog
if you want it.

## What runs as root

| Component | Runs as root how | Passwordless from your login? |
|---|---|---|
| `warp-killswitch` helper, `/Library/PrivilegedHelperTools/warp-killswitch` | LaunchDaemons (watchdog, three on-demand re-dispatch jobs); `sudo` from the menu | Only `down`, `down --keep-dns`, `up`, `heal manual`, `status`, `state`, `verify` — exact argument lists, nothing else |
| `networksetup -setdnsservers` | `sudo` from the menu's AdGuard toggle | Only the two server lists the menu sets (AdGuard on / fallback off), on `Wi-Fi` and `iPhone USB`, rendered from `dns.conf` at install time |
| `killall -HUP mDNSResponder` | `sudo` from the menu | Yes (flushes the DNS cache; nothing else) |
| `profiles show -type configuration` | `sudo` from `netcheck` | Yes (read-only) |
| `arp-scan` | `sudo` from `netcheck`/`nettop` | **MacPorts only**, where the binary and its whole directory chain are root-owned and not a symlink; pinned to `--interface=en<N> --localnet --ignoredups`. Never on Homebrew (user-writable prefix; `-W` writes files as root) |
| LuLu network extension, BlockBlock daemon | Their own installers, approved by you in System Settings | Not via the suite |

Everything else — netwatch, nettop, netcheck, probesource, the menu plugin, the
macOS 27 ARP-cache agent — runs as you. probesource's privileged tactics use
`sudo -n` and prompt through the normal sudo path.

## Rules the code is held to

- **No wildcard in a NOPASSWD rule.** CI renders every sudoers template and
  the kill-switch helper rule, runs `visudo -c` on them, and fails on `*` or `?`.
- **A passwordless root binary sits only in a root-only directory chain.** The
  installer refuses to install the helper if `/Library/PrivilegedHelperTools`
  is not root-only; `warp-killswitch status` re-checks its own path so drift is
  visible. A NOPASSWD `arp-scan` rule is written only after the same check and
  never for a symlink.
- **Root never writes into a user's home.** Files under `~/Library` and
  `~/Documents` are written as the owning user (`sudo -u`), so a planted symlink
  can at most overwrite what that user could already overwrite.
- **Text is never spliced into AppleScript source.** Every `osascript`
  notification or dialog receives its text as arguments (`on run argv`). CI
  greps for the old pattern. This matters because the Wi-Fi SSID — chosen by
  whoever runs the access point — ends up in netwatch's notifications.
- **Untrusted data is matched, not executed.** The ARP cache the root helper
  reads from the user's home is `grep`ped for one gateway line; SSIDs are
  stripped of the fingerprint separator and control characters; probesource's
  scan-state files are parsed as key=value, not `source`d; `dns.conf` values are
  validated as addresses and URL-safe `https://` URLs before they reach sudoers,
  XML or `user.js`.
- **Absolute paths for system tools, audited at install time.** A wrong path
  behind `2>/dev/null` is an invisible no-op.
- **Every teardown, rebuild and manual heal is logged with who asked**
  (`caller=<sudo user> via=<parent process>`) in `/var/log/warp-killswitch.log`.
- **Vendor downloads are signature-checked** against the publisher's Developer
  ID Team ID (Cloudflare `68WVV388M8`, xbar `N3H5B92L5N`, Proton `J6S6Q257EK`,
  Objective-See `VBG97UB4TA`, MacPorts `QTA3A3B7F3`) before anything is run or
  installed; a mismatch is refused.
- **Lint is enforced.** `shellcheck -S warning` over every bash and sh tool,
  including the helper extracted from its installer; `bash -n`/`sh -n`; `zsh -n`;
  `xmllint` on every plist and profile; SPDX headers everywhere.

## Accepted trade-offs (known, documented, deliberate)

- **A process running as you can tear WARP down without a password**, because
  the menu has to. The helper verifies plain internet afterwards, posts a
  desktop notification saying so, and logs the caller. The watchdog never acts
  while torn down, so a silent re-enable is not possible either. If you want the
  menu's kill-switch items to prompt, remove `/etc/sudoers.d/warp-killswitch`
  and re-run with `--skip killswitch`.
- **Homebrew is bootstrapped with Homebrew's own `curl | bash` installer**
  when it is absent on Apple Silicon. That is Homebrew's only supported method.
  MacPorts, WARP, xbar, ProtonVPN and the Objective-See tools are downloaded
  and signature-verified instead.
- **probesource interpolates the target IP into `bash -c` strings** for its
  tactics. The IP is validated at the single point of entry (strict IPv4 /
  IPv6 character classes) before any tactic runs, so no shell metacharacter can
  reach those strings; a refactor to argument passing is on the list for the
  next audit.
- **The root helper reads a file from the console user's home** (the macOS 27
  ARP cache) to judge link state when its own view is blanked. It is read only,
  `grep`ped for one fixed pattern, and refused when older than two minutes.
- **The watchdog's stdout log (`/var/log/warp-watchdog.log`) is not rotated.**
  It only receives lines when something is wrong; the helper's own log is
  rotated at 2 MB.
- **`uninstall.sh` leaves DNS settings, the firewall, WARP, the package manager
  and the Objective-See tools in place.** Removing them could cut you off or is
  yours to decide; the script says what it left.

## Dependencies and CVE status

The repository vendors nothing: no manifests, lock files, libraries, binaries or
archives, so there is no component for a CVE to attach to and nothing for
Dependabot to scan. Everything the installer puts on a Mac is fetched at install
time at its current upstream version — Apple tools, Homebrew/MacPorts packages,
and vendor apps refused unless signed by the publisher's Developer ID Team ID
(see the table above). Security fixes for those reach you through `brew upgrade`
/ `port upgrade` and the apps' own updaters, not through this repository. GitHub
Actions are pinned to commit SHAs. The 4.1 full security audit by Claude Fable 5.1
included a CVE scrub and declared the suite free as of 2026-10-24; the
weaknesses it found and fixed are catalogued by CWE in the README brief.

Two HEAD-tracking fetches are deliberate and worth knowing about: Homebrew's own
`curl | bash` bootstrap (its only supported method), and probesource's source
builds of onesixtyone, nbtscan, hping3, ike-scan and enum4linux-ng from their
upstream `git` HEAD when no package exists. Both trade pinning for immediacy of
fixes; both run as you, never as root.

## Verifying your own install

```sh
sudo cat /etc/sudoers.d/panoptes-dns /etc/sudoers.d/warp-killswitch   # no '*' anywhere
ls -l /Library/PrivilegedHelperTools/warp-killswitch /usr/local/bin/warp-killswitch   # file + link
sudo warp-killswitch status | grep -E 'helper|watchdog'
sudo -l | grep -E 'networksetup|warp-killswitch'                      # what sudo thinks you may run
```
