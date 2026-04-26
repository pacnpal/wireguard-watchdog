# WireGuard Watchdog (Unraid plugin)

A self-contained Unraid plugin that pings a peer through a WireGuard
tunnel interface on a schedule, and bounces the tunnel via `wg-quick
down/up` when the peer becomes unreachable. All settings (interface,
peer IP, interval, enable/disable, verbose logging) are configured from
**Settings → WG Watchdog**.

> Requires the Unraid built-in WireGuard plugin and at least one
> configured tunnel (`wg0`, `wg1`, …).

---

## Install

1. Open the Unraid web UI → **Plugins** tab → **Install Plugin**.
2. Paste the `.plg` URL:
   ```
   https://raw.githubusercontent.com/pacnpal/wireguard-watchdog/main/wg-watchdog.plg
   ```
3. Click **Install**. The plugin downloads its `.txz` from the matching
   GitHub release and installs to `/usr/local/emhttp/plugins/wg-watchdog/`.
4. Open **Settings → WG Watchdog**, fill in the form, set **Enabled =
   yes**, click **Apply**.

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
- **Apply** — validates the form, writes
  `/boot/config/plugins/wg-watchdog/wg-watchdog.cfg`, regenerates
  `wg-watchdog.cron`, and runs `update_cron`.
- **Test Now** — runs `watchdog.sh --test` once and shows the output
  inline. Honours your settings but ignores the Enabled toggle.
- **View Log** — tails the last 200 lines of the configured log file.

> _Screenshot placeholder: Settings → WG Watchdog page._

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
tool the built-in WireGuard plugin uses. The two coexist cleanly.

## Build & release

### Automated (recommended)

GitHub Actions handles everything. From the repo's **Actions** tab →
**Build and Release** → **Run workflow**:

- Leave the version blank to use today's UTC date, or enter a specific
  `YYYY.MM.DD`.
- The workflow builds the `.txz` + `.plg`, commits the updated
  `wg-watchdog.plg` to `main`, creates the matching GitHub release, and
  uploads both artifacts.

Workflow file: [.github/workflows/release.yml](.github/workflows/release.yml).

### Local build

Required tools: `bash`, `tar` (GNU), `xz`, `md5sum`, `sha256sum`, `sed`.

```bash
./build.sh                 # version = today's YYYY.MM.DD
VERSION=2026.05.01 ./build.sh
```

Produces in `dist/`:
- `wg-watchdog-<version>-noarch-1.txz` — the Slackware package.
- `wg-watchdog.plg` — the manifest with the `.txz`'s md5 baked in.

To release manually: create a GitHub release tagged `<version>`,
upload the `.txz`, then commit `dist/wg-watchdog.plg` to `main` as
`wg-watchdog.plg` at repo root.

The `.plg` references the `.txz` at:
```
https://github.com/pacnpal/wireguard-watchdog/releases/download/<version>/wg-watchdog-<version>-noarch-1.txz
```

If you fork, grep-replace `pacnpal/wireguard-watchdog` in
`wg-watchdog.plg.in` and this README before releasing.

## Test plan

Tested target: Unraid 7.2.x in a VM, with the Unraid WireGuard plugin
installed and a `wg0` tunnel configured against a reachable peer.

1. **Install**
   - Build with `./build.sh`. Push to a test branch + create a release.
   - Paste the .plg URL into Plugins → Install Plugin.
   - Verify install log ends with the "wg-watchdog … installed" banner.
   - Verify **Settings → WG Watchdog** appears.

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

## Repo layout

```
wireguard-watchdog/
├── README.md
├── build.sh
├── wg-watchdog.plg              # generated; updated by the release workflow
├── wg-watchdog.plg.in           # template, build.sh fills @@VERSION@@/@@MD5@@/@@PKG@@
├── .github/workflows/release.yml
├── source/                      # everything below installs to /usr/local/emhttp/plugins/wg-watchdog/
│   ├── default.cfg
│   ├── wg-watchdog.page
│   ├── include/
│   │   ├── apply.php
│   │   ├── test.php
│   │   └── log.php
│   ├── scripts/
│   │   ├── watchdog.sh
│   │   ├── install_cron.sh
│   │   └── remove_cron.sh
│   └── event/
│       ├── started
│       └── stopping
└── dist/                        # produced by build.sh; not checked in
    ├── wg-watchdog-<version>-noarch-1.txz
    └── wg-watchdog.plg
```

## Notes

- `Menu="NetworkServices"` slots the page under **Settings → Network
  Services**. The original brief said "Menu: Settings"; on Unraid 7.x
  the Settings panel is partitioned into named sub-menus, and
  NetworkServices is the natural fit for a WireGuard helper. Edit
  `source/wg-watchdog.page` if you'd rather slot it elsewhere
  (`OtherSettings`, `UserPreferences`, etc.).
- The watchdog uses `wg-quick down/up`, never `ip link` or direct
  `wg`-cli mutations, so it can't desync the Unraid WireGuard plugin's
  own state.
