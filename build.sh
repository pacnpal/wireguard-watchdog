#!/usr/bin/env bash
# build.sh -- produce wg-watchdog.plg + wg-watchdog-<version>-noarch-1.txz
#
# Required tools: bash, GNU tar, xz, md5sum, sha256sum, sed.
# Optional: install Slackware's `makepkg` if you want the canonical packager,
# but plain tar+xz produces a byte-identical .txz for our needs.
#
# Usage:
#   ./build.sh              # version = today's YYYY.MM.DD
#   VERSION=2026.05.01 ./build.sh

set -euo pipefail

PLUGIN="wg-watchdog"
VERSION="${VERSION:-$(date '+%Y.%m.%d')}"
ARCH="noarch"
BUILD="1"

PKG_BASENAME="${PLUGIN}-${VERSION}-${ARCH}-${BUILD}"
PKG_FILE="${PKG_BASENAME}.txz"

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO_ROOT/source"
DIST="$REPO_ROOT/dist"
PLG_TEMPLATE="$REPO_ROOT/wg-watchdog.plg.in"
PLG_OUT="$DIST/${PLUGIN}.plg"
PKG_PATH="$DIST/${PKG_FILE}"

[[ -d "$SRC"          ]] || { echo "missing $SRC" >&2; exit 1; }
[[ -f "$PLG_TEMPLATE" ]] || { echo "missing $PLG_TEMPLATE" >&2; exit 1; }

mkdir -p "$DIST"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Mirror the on-disk layout the package will install to.
INSTALL_DIR="$STAGE/usr/local/emhttp/plugins/$PLUGIN"
mkdir -p "$INSTALL_DIR"
cp -a "$SRC/." "$INSTALL_DIR/"

# Permissions: scripts and event hooks must be executable.
find "$INSTALL_DIR/scripts" "$INSTALL_DIR/event" -type f -exec chmod 0755 {} +
find "$INSTALL_DIR" -type f \( -name '*.page' -o -name '*.php' -o -name '*.cfg' \) \
    -exec chmod 0644 {} +

# Slackware metadata.
mkdir -p "$STAGE/install"
cat > "$STAGE/install/slack-desc" <<'EOF'
       |-----handy-ruler------------------------------------------------------|
wg-watchdog: wg-watchdog (WireGuard tunnel watchdog for Unraid)
wg-watchdog:
wg-watchdog: Pings a peer through a WireGuard tunnel interface on a schedule
wg-watchdog: and bounces the tunnel via wg-quick if the peer becomes
wg-watchdog: unreachable. Configurable from Tools -> User Utilities -> WireGuard Watchdog.
wg-watchdog:
wg-watchdog: Requires Unraid's built-in WireGuard support and a configured tunnel.
wg-watchdog:
wg-watchdog:
wg-watchdog:
wg-watchdog:
EOF

# Build a deterministic tar.xz with root-owned files.
( cd "$STAGE" && \
    tar --owner=root --group=root --sort=name -cJf "$PKG_PATH" . )

MD5=$(md5sum  "$PKG_PATH" | awk '{print $1}')
SHA=$(sha256sum "$PKG_PATH" | awk '{print $1}')
SIZE=$(stat -c %s "$PKG_PATH")

# Render the .plg from template.
sed \
    -e "s|@@VERSION@@|${VERSION}|g" \
    -e "s|@@MD5@@|${MD5}|g" \
    -e "s|@@PKG@@|${PKG_FILE}|g" \
    "$PLG_TEMPLATE" > "$PLG_OUT"

cat <<EOF

Built artifacts in $DIST:
  $(basename "$PKG_PATH")   ${SIZE} bytes
    md5    = $MD5
    sha256 = $SHA
  $(basename "$PLG_OUT")

Next: create a GitHub release tagged "${VERSION}" and upload ${PKG_FILE}.
Then commit dist/${PLUGIN}.plg to the repo (or upload it to the same release)
so users can install from its raw URL.
EOF
