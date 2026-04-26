<div align="center">

<img src="assets/logo.png" alt="WireGuard Watchdog logo" width="160" height="160">

# WireGuard Watchdog

**An Unraid plugin that keeps your WireGuard tunnel healthy.**
Pings a peer through the tunnel on a schedule; bounces the tunnel via
`wg-quick down/up` the moment the peer goes silent.

[![Latest release](https://img.shields.io/github/v/release/pacnpal/wireguard-watchdog?label=release&color=88171a)](https://github.com/pacnpal/wireguard-watchdog/releases/latest)
[![License: MIT](https://img.shields.io/github/license/pacnpal/wireguard-watchdog?color=blue)](LICENSE)
[![Unraid 6.12+](https://img.shields.io/badge/Unraid-6.12%2B-f15a2c)](https://unraid.net/)
[![Lint](https://img.shields.io/github/actions/workflow/status/pacnpal/wireguard-watchdog/lint.yml?branch=main&label=lint)](https://github.com/pacnpal/wireguard-watchdog/actions/workflows/lint.yml)
[![Release workflow](https://img.shields.io/github/actions/workflow/status/pacnpal/wireguard-watchdog/release.yml?label=release%20build)](https://github.com/pacnpal/wireguard-watchdog/actions/workflows/release.yml)
[![Downloads](https://img.shields.io/github/downloads/pacnpal/wireguard-watchdog/total?color=2ee4a3)](https://github.com/pacnpal/wireguard-watchdog/releases)

</div>

> [!IMPORTANT]
> Requires Unraid's built-in **WireGuard** support (Settings → VPN
> Manager) and at least one configured tunnel (`wg0`, `wg1`, …). The
> watchdog never touches `wg0` directly — it only invokes `wg-quick`,
> the same tool Unraid uses internally — so the two coexist cleanly.

## Why?

WireGuard is silent when it fails. A peer going down or a NAT mapping
expiring leaves the tunnel "up" from the local side — `wg show` looks
fine, but no traffic flows. The fix is always the same: bounce the
tunnel. This plugin automates that bounce, gated behind a real
liveness check (a ping through the interface, not just a check that
the daemon exists).

Use it if you:
- run a site-to-site tunnel and want unattended recovery from the
  remote side rebooting or losing internet briefly,
- depend on the tunnel for critical traffic (Docker containers, VMs)
  and don't want to babysit it,
- want a quick visual confirmation in the UI that the tunnel is
  reachable right now.

## Install

1. Open the Unraid web UI → **Plugins** tab → **Install Plugin**.
2. Paste the `.plg` URL:
   ```
   https://github.com/pacnpal/wireguard-watchdog/releases/latest/download/wg-watchdog.plg
   ```
3. Click **Install**. The plugin downloads its `.txz` from the matching
   GitHub release and installs to `/usr/local/emhttp/plugins/wg-watchdog/`.
4. Open **Tools → User Utilities → WireGuard Watchdog**, fill in the
   form, set **Enabled = yes**, click **Apply**.

The plugin defaults to `Enabled=no` on first install. Nothing runs until
you explicitly enable it.

## Configuration

| Field             | Default                       | Notes |
|-------------------|-------------------------------|-------|
| Enabled           | `no`                          | Master toggle. `no` removes the cron entry. |
| Tunnel interface  | `wg0`                         | Must be a configured WireGuard interface. |
| Peer IP to ping   | `10.99.0.1`                   | Reachable through the tunnel. |
| Check interval    | `60` seconds (min `20`)       | Below 60s: cron uses per-minute lines with `sleep` offsets. |
| Verbose logging   | `no`                          | If `yes`, each successful ping is logged too. |
| Log file          | `/var/log/wg-watchdog.log`    | Read-only display in the UI. |

**Buttons:**
- **Apply** — posts the form to Unraid's `/update.php`, which writes
  `/boot/config/plugins/wg-watchdog/wg-watchdog.cfg` and runs
  `scripts/install_cron.sh` (regenerates the cron file and calls
  `update_cron`).
- **Test Now** — runs `watchdog.sh --test` once and shows the output
  inline. Honours your settings but ignores the Enabled toggle.
- **View Log** — tails the last 200 lines of the configured log file.
- **Clear Log** — truncates the log file (with confirmation prompt).

> _Screenshot placeholder: Tools → User Utilities → WireGuard Watchdog._

## How it works

- `scripts/watchdog.sh` is the only thing scheduled. It:
  1. Sources `/boot/config/plugins/wg-watchdog/wg-watchdog.cfg`.
  2. Holds an exclusive `flock` on `/var/lock/wg-watchdog.lock` so
     overlapping cron firings can't trample each other.
  3. Runs `ping -c 2 -W 3 -I $INTERFACE $PEER_IP`.
  4. On failure: `wg-quick down $INTERFACE` → `sleep 2` → `wg-quick up
     $INTERFACE`, logging each step.
- `scripts/install_cron.sh` reads the cfg and writes
  `/boot/config/plugins/wg-watchdog/wg-watchdog.cron`, then calls
  `/usr/local/sbin/update_cron`. Unraid persists cron files from
  `/boot/config/plugins/*/...cron` across reboots.
- `event/started` re-syncs cron when the array starts.
- `event/stopping` removes the active cron entry so no checks fire
  during shutdown.

The plugin **never touches `wg0` directly** — only `wg-quick`, the same
tool Unraid's built-in WireGuard uses. The two coexist cleanly.

## Build & release

Releases are cut from the **Actions** tab → **Build and Release** →
**Run workflow** ([release.yml](.github/workflows/release.yml)).

`./build.sh` is for local testing only — the workflow builds and
attaches the public release assets.

## Test plan

Tested target: Unraid 7.2.x in a VM with a `wg0` tunnel configured in
**Settings → VPN Manager** against a reachable peer.

1. **Install**
   - Build with `./build.sh`. Push to a test branch + create a release.
   - Paste the .plg URL into Plugins → Install Plugin.
   - Verify install log ends with the "wg-watchdog … installed" banner.
   - Verify **Tools → User Utilities → WireGuard Watchdog** appears.

2. **Defaults**
   - Open the page. Confirm `Enabled = no`, `INTERFACE = wg0`,
     `PEER_IP = 10.99.0.1`, `INTERVAL = 60`, log path shown.
   - Confirm `/boot/config/plugins/wg-watchdog/wg-watchdog.cfg` exists.
   - Confirm no cron file at `/etc/cron.d/wg-watchdog` (disabled state).

3. **Apply / cron install**
   - Set `Enabled = yes`, `PEER_IP` to the actual peer's tunnel IP,
     `INTERVAL = 60`, click **Apply**.
   - Confirm `/boot/config/plugins/wg-watchdog/wg-watchdog.cron` was
     written and `/etc/cron.d/wg-watchdog` was created by `update_cron`.

4. **Test Now (happy path)**
   - Click **Test Now**.
   - Expect output containing `OK: <peer> reachable via wg0`.

5. **Failure simulation**
   - From SSH: `wg-quick down wg0` to break the tunnel.
   - Wait one cron interval (or click **Test Now** to force).
   - Expect log entry `FAIL: ... unreachable via wg0 -- bouncing tunnel`,
     followed by `wg-quick down wg0: ok` (or "failed (continuing)" since
     the interface is already down) and `wg-quick up wg0: ok`.
   - Verify `wg show wg0` reports the interface back up and a fresh
     handshake.

6. **Lock contention**
   - Set `INTERVAL = 20`, click **Apply**.
   - Tail the log; with verbose enabled, confirm only one run executes
     at a time even with overlapping firings.

7. **Persistence**
   - Reboot the server.
   - After array start, confirm `/etc/cron.d/wg-watchdog` is back
     (regenerated by `event/started`).
   - Confirm log contains an `event: started` entry.

8. **Disable**
   - Set `Enabled = no`, **Apply**.
   - Confirm both `/boot/config/.../wg-watchdog.cron` and
     `/etc/cron.d/wg-watchdog` are gone.

9. **Uninstall**
   - Remove the plugin from the Plugins tab.
   - Confirm `/boot/config/plugins/wg-watchdog/` and
     `/usr/local/emhttp/plugins/wg-watchdog/` are gone.
   - Confirm `/var/log/wg-watchdog.log` is **preserved**.

## Troubleshooting

| Symptom | Likely cause | Where to look |
|---|---|---|
| **Test Now** prints `FAIL: interface wg0 does not exist` | Wrong interface name, or the tunnel isn't started. | Settings → VPN Manager. Run `wg show` in the terminal. |
| Test passes, but cron never fires | Service disabled, or `update_cron` wasn't called after Apply. | `cat /etc/cron.d/wg-watchdog` should exist; `cat /boot/config/plugins/wg-watchdog/wg-watchdog.cfg` should show `SERVICE_ENABLED="yes"`. |
| Bounces happen but tunnel stays down | The peer is genuinely unreachable, or `wg-quick up` is failing. | Tail `/var/log/wg-watchdog.log` for `wg-quick up wg0: failed`; run it manually to see the error. |
| Log says `skipped: previous run still in progress` repeatedly | A check is taking longer than the interval (DNS hangs, network stalls). | Lengthen the interval, or set `VERBOSE="no"` to suppress these messages. |
| Log file fills the flash drive | Verbose left on for months. | Set Verbose=no, or rotate by truncating: `: > /var/log/wg-watchdog.log`. |
| **View Log** says "log file not yet created" | First boot or just installed; nothing's run yet. | Click **Test Now** once. |

For anything else, file an issue with the contents of
`/boot/config/plugins/wg-watchdog/wg-watchdog.cfg` and the last ~50
lines of `/var/log/wg-watchdog.log`.

## Repo layout

```
wireguard-watchdog/
├── README.md
├── LICENSE
├── build.sh
├── wg-watchdog.plg.in           # template; build.sh fills @@VERSION@@/@@MD5@@/@@PKG@@
├── .github/
│   ├── ISSUE_TEMPLATE/{bug_report,feature_request}.yml
│   └── workflows/{release,lint}.yml
├── assets/
│   ├── logo.svg                 # source vector
│   ├── logo{,-128,-512}.png     # rasterised by render-png.py
│   └── render-png.py
├── source/                      # installs to /usr/local/emhttp/plugins/wg-watchdog/
│   ├── default.cfg
│   ├── wg-watchdog.page
│   ├── include/{test,log,clear}.php
│   ├── scripts/{watchdog,install_cron,remove_cron}.sh
│   └── event/{started,stopping}
└── dist/                        # produced by build.sh; not checked in
    ├── wg-watchdog-<version>-noarch-1.txz
    └── wg-watchdog.plg
```

## Notes

- The watchdog uses `wg-quick down/up`, never `ip link` or direct
  `wg`-cli mutations, so it can't desync Unraid's built-in tunnel
  management.

## License

[MIT](LICENSE).
