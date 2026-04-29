# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this is

`wg-watchdog` is an **Unraid plugin** (Slackware `.txz` payload + `.plg`
descriptor) that pings a peer through a WireGuard tunnel on a cron schedule
and bounces the tunnel when the peer goes silent. It runs on top of Unraid's
built-in WireGuard support — it does not ship `wg`/`wg-quick`, only invokes
them.

Target: Unraid 6.12+ (tested on 7.2.x). License: MIT. Public releases are
attached to GitHub Releases by `.github/workflows/release.yml`; the `.plg`
that users paste into the Plugins tab lives at `plugin/wg-watchdog.plg`.

## Repo layout

```
wireguard-watchdog/
├── README.md              # user-facing docs (install, config, troubleshooting, test plan)
├── LICENSE                # MIT
├── build.sh               # local build only — workflow builds public assets
├── wg-watchdog.plg.in     # template; build.sh fills @@VERSION@@ / @@MD5@@ / @@PKG@@
├── plugin/
│   └── wg-watchdog.plg    # rendered .plg committed to main by the release workflow
├── .github/
│   ├── ISSUE_TEMPLATE/{bug_report,feature_request}.yml
│   └── workflows/{lint,release}.yml
├── assets/                # logos (svg + rasterised PNGs from render-png.py)
├── source/                # gets staged into /usr/local/emhttp/plugins/wg-watchdog/
│   ├── default.cfg        # seeded to /boot/config/plugins/wg-watchdog/wg-watchdog.cfg on first install
│   ├── wg-watchdog.page   # Unraid PHP/markdown UI page (Tools → User Utilities)
│   ├── wg-watchdog.png    # plugin icon (copy of assets/logo-128.png)
│   ├── include/{test,log,clear}.php   # AJAX endpoints invoked by the page
│   ├── scripts/
│   │   ├── watchdog.sh           # the only thing scheduled by cron
│   │   ├── lib.sh                # pure helpers, sourced by watchdog.sh
│   │   ├── install_cron.sh       # cfg → /boot/.../wg-watchdog.cron + update_cron
│   │   └── remove_cron.sh
│   └── event/{started,stopping}  # Unraid array event hooks
├── tests/
│   ├── run.sh                    # entry point — runs both suites
│   ├── test_lib.sh               # unit tests for lib.sh helpers
│   ├── test_watchdog_e2e.sh      # integration tests (mock wg/wg-quick/ip/ping)
│   └── fixtures/                 # *.conf samples (prone_* and safe_*)
└── dist/                  # build output (gitignored)
```

`source/` is the install image. Anything under it lands at
`/usr/local/emhttp/plugins/wg-watchdog/` on the Unraid host. Persistent state
(user config, generated cron) lives at `/boot/config/plugins/wg-watchdog/`.

## Recovery model (the thing that matters)

`scripts/watchdog.sh` is the heart of the project. Two-tier recovery:

1. **Soft bounce** (default path): `wg-quick strip` → validate non-empty →
   snapshot the live conf via `wg showconf` for rollback → remove every live
   peer (`wg set <iface> peer <key> remove`) → re-apply the stripped conf with
   `wg syncconf <iface> /dev/stdin`. This resets per-peer crypto state without
   touching ip rules, routes, or iptables. If `wg syncconf` fails after peers
   were removed, the script attempts a **rollback** by piping the saved
   pre-bounce conf back through `wg syncconf`.

2. **Hard bounce** (last resort, only if soft path didn't recover):
   `wg-quick down` → `sleep 2` → `wg-quick up`. **Gated** by a
   redirect-prone-conf check before it runs.

### The "redirect-prone" gate (why it exists)

`wg-quick up` of a conf with `AllowedIPs = 0.0.0.0/0` (or `::/0`) and no
`Table = off` installs `ip rule not fwmark <T> table <T>`, which silently
redirects every unmarked host packet through the tunnel — including any
container running `--network host`. The watchdog **refuses the hard bounce**
when:

  - the conf is redirect-prone (0/0 in any peer's AllowedIPs and no
    `Table = off` in `[Interface]`), AND
  - `wg show <iface> fwmark` is `off`/`0`/empty (auto-routing not currently
    active — i.e., the tunnel was brought up some other way).

That combination is the original bug report: a hard bounce there would
*newly install* the redirect on a host that didn't have it. Fixed by
preferring `wg syncconf` (which never adds the rule) and refusing the hard
fallback in the dangerous case. See `lib.sh::conf_redirect_prone` and
`lib.sh::auto_routing_active`.

### Strip-first ordering (why peers don't get wiped)

The soft path validates `wg-quick strip` output is non-empty *before*
removing live peers. If strip fails, the live interface is untouched and
control falls through to the hard-bounce gate. We never produce an
"interface up, peers wiped" half-state.

### `routing_snapshot` self-check

After a successful soft bounce, the script diffs `ip rule` + `ip route show
table all` (v4 + v6) against the pre-bounce snapshot and logs `WARN: routing
state changed` if they differ. That diff would mean the soft path regressed
into the original bug — make sure any change to the soft-bounce sequence
keeps this invariant.

## Configuration & state

Config keys (in `source/default.cfg`, mirrored in `wg-watchdog.page` defaults
and `watchdog.sh` defaults — keep all three in sync):

| Key | Default | Notes |
|---|---|---|
| `SERVICE_ENABLED` | `no` | Master toggle. `no` removes cron. |
| `INTERFACE` | `wg0` | wg interface name |
| `PEER_IP` | `10.99.0.1` | IP reachable through the tunnel |
| `INTERVAL` | `60` | seconds; min 20; install_cron.sh sanitises |
| `VERBOSE` | `no` | If `yes`, log every successful ping too |
| `LOG_FILE` | `/var/log/wg-watchdog.log` | display-only in UI |

Files on the live host:

- `/boot/config/plugins/wg-watchdog/wg-watchdog.cfg` — user settings
  (persisted across reboots; written by Unraid's `/update.php` from the form)
- `/boot/config/plugins/wg-watchdog/wg-watchdog.cron` — generated by
  `install_cron.sh`; Unraid persists this and `update_cron` materialises it
  to `/etc/cron.d/wg-watchdog`
- `/var/lock/wg-watchdog.lock` — `flock`'d so overlapping cron firings can't
  trample each other
- `/var/log/wg-watchdog.log` — preserved on uninstall

Sub-minute intervals (< 60s) are emitted as multiple per-minute cron lines
with `sleep` offsets — see `install_cron.sh` for the exact shape.

## Development workflow

### Tests

```sh
bash tests/run.sh
```

Runs `test_lib.sh` (pure-function tests for `lib.sh`) and
`test_watchdog_e2e.sh` (full integration tests that build a sandbox per case
with mock `wg`/`wg-quick`/`ip`/`ping` binaries on `PATH` and a fake
`/etc/wireguard`). The e2e harness drives behavior via env vars:
`WGW_PING_RC`, `WGW_STRIP_RC`, `WGW_SYNC_RC`, `WGW_DOWN_RC`, `WGW_UP_RC`,
`WGW_PEER_REMOVE_RC`, `WGW_SHOWCONF_RC`, `WGW_ROLLBACK_RC`. The watchdog
itself recognises `WGW_TEST_DIR` and `ETC_WIREGUARD` overrides specifically
for this harness — don't repurpose them in production code paths.

`watchdog.sh --test` is a one-shot diagnostic mode used by the **Test Now**
button (`include/test.php`). It ignores `SERVICE_ENABLED`, prints to stdout
instead of the log, and is verbose by default.

### Local build

```sh
./build.sh                    # version = today's UTC date (YYYY.MM.DD)
VERSION=2026.05.01 ./build.sh # explicit version
```

Stages `source/` into a tmpdir mirroring `/usr/local/emhttp/plugins/wg-watchdog/`,
chmods scripts/event hooks to 0755 and `.page`/`.php`/`.cfg` to 0644, writes
`install/slack-desc`, builds a deterministic `tar -cJf` (root-owned, sorted),
then renders `wg-watchdog.plg.in` → `dist/wg-watchdog.plg` substituting
`@@VERSION@@`/`@@MD5@@`/`@@PKG@@`. Output goes to `dist/` (gitignored).
**Do not commit `dist/`.**

`./build.sh` is for local smoke testing only — public release assets are
built and attached by the workflow.

### Release

Manual: GitHub Actions → **Build and Release** → Run workflow. Optionally
supply `version: YYYY.MM.DD` (defaults to UTC today). The workflow:

1. Runs `./build.sh` with the chosen version.
2. Validates the `.plg` (`xmllint`) and that its declared MD5 matches the
   built `.txz`.
3. Copies `dist/wg-watchdog.plg` → `plugin/wg-watchdog.plg` and commits to
   `main` (`release: <version> [skip ci]`).
4. Creates the GitHub release tagged `<version>` and uploads both
   `wg-watchdog-<version>-noarch-1.txz` and `wg-watchdog.plg` as assets,
   `--clobber` enabled.

End users install by pasting the raw `plugin/wg-watchdog.plg` URL on `main`
into Unraid's **Plugins → Install Plugin**; the `.plg` then downloads the
matching `.txz` from the release. **Never hand-edit `plugin/wg-watchdog.plg`** —
it's a build artifact regenerated each release.

### CI (lint workflow)

Runs on push to `main` and PRs (skips README/LICENSE/assets-only changes).
Steps:

- `bash -n` syntax-check on every shell script in `source/scripts`,
  `source/event`, `tests/`, plus `build.sh`
- `shellcheck -s bash -S warning` (informational, non-blocking)
- `bash tests/run.sh`
- `php -l` on every `source/include/*.php`
- Build smoke test with `VERSION=9999.99.99`
- `xmllint --noout` on the generated `.plg`
- Verify the `.plg`'s declared MD5 matches the built `.txz`

If you change `default.cfg` keys, mirror the change in
`source/wg-watchdog.page` (form defaults), `source/scripts/watchdog.sh`
(fallback defaults near the top), and `source/scripts/install_cron.sh` if
the key affects scheduling.

## Conventions

- **Bash scripts** use `set -u` (not `set -e` — failure paths are handled
  explicitly so `wg-quick down` returning non-zero doesn't abort the hard
  bounce). Restore `PATH` at the top of cron-invoked scripts; the test
  harness keeps its own `PATH` (mock binaries first) when `WGW_TEST_DIR` is
  set, so don't unconditionally overwrite `PATH`.
- **`lib.sh` is sourced only.** Helpers must stay side-effect-free so
  `test_lib.sh` can exercise them in isolation.
- **awk in `conf_redirect_prone`** must stay portable to mawk/busybox awk —
  don't rely on `IGNORECASE` (it's gawk-only); compare against `tolower(...)`
  values explicitly.
- **PHP endpoints** validate the log path with a strict regex
  (`^/[A-Za-z0-9_./-]+$`) before passing to `escapeshellarg`. Don't loosen
  that regex without a reason.
- **`.page` form** posts to Unraid's `/update.php` with
  `csrf_token`, `#file=wg-watchdog/wg-watchdog.cfg` and
  `#command=plugins/wg-watchdog/scripts/install_cron.sh`. Unraid handles the
  cfg write and then runs the command.
- **No new dependencies.** Use only what's on a stock Unraid box: bash, awk,
  sed, grep, flock, tar, xz, md5sum, sha256sum, ip, wg, wg-quick, ping, php.
- **Versioning is `YYYY.MM.DD`.** No semver. Older `.txz` files in
  `/boot/config/plugins/wg-watchdog/` are auto-cleaned by the `.plg`
  pre-install step.
- **Markdown style** in README/CLAUDE.md uses ASCII punctuation (`--`, `->`)
  rather than `—`/`→` in code/log examples; prose can use unicode.

## Branching

Develop on the assigned feature branch. Don't push to `main` directly; the
release workflow is the only thing that pushes to `main` (commits the
rendered `.plg` and tags the release).

## What not to touch without thinking

- The strip-first / sync-then-fallback ordering in `watchdog.sh`.
- The redirect-prone gate (`conf_redirect_prone` + `auto_routing_active`)
  and its tests in `test_lib.sh` and `test_watchdog_e2e.sh` (T4, T5, T6).
- The `routing_snapshot` invariant assertion after a successful soft bounce.
- The `wg-quick strip` stdout/stderr separation (merging them would corrupt
  the conf piped to `wg syncconf`); same for `wg showconf` used for the
  rollback config.
