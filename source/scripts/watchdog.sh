#!/bin/bash
# WireGuard Watchdog: ping a peer through the tunnel; bounce on failure.
#
# Usage:
#   watchdog.sh           normal scheduled run, honours SERVICE_ENABLED
#   watchdog.sh --test    one-shot diagnostic, ignores SERVICE_ENABLED, prints to stdout

set -u
export PATH="/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin"

CFG="/boot/config/plugins/wg-watchdog/wg-watchdog.cfg"
LOCK="/var/lock/wg-watchdog.lock"

SERVICE_ENABLED="no"
INTERFACE="wg0"
PEER_IP="10.99.0.1"
INTERVAL="60"
VERBOSE="no"
LOG_FILE="/var/log/wg-watchdog.log"

[[ -f "$CFG" ]] && . "$CFG"

TEST_MODE="no"
[[ "${1:-}" == "--test" ]] && TEST_MODE="yes"

log() {
    local ts msg="$1"
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ "$TEST_MODE" == "yes" ]]; then
        echo "[$ts] $msg"
    else
        echo "[$ts] $msg" >> "$LOG_FILE"
    fi
}

if [[ "$TEST_MODE" != "yes" && "$SERVICE_ENABLED" != "yes" ]]; then
    exit 0
fi

exec 9>"$LOCK" || { log "ERROR: cannot open lockfile $LOCK"; exit 1; }
if ! flock -n 9; then
    [[ "$VERBOSE" == "yes" || "$TEST_MODE" == "yes" ]] && log "skipped: previous run still in progress"
    exit 0
fi

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    log "FAIL: interface $INTERFACE does not exist"
    exit 1
fi

if ping -c 2 -W 3 -I "$INTERFACE" "$PEER_IP" >/dev/null 2>&1; then
    if [[ "$VERBOSE" == "yes" || "$TEST_MODE" == "yes" ]]; then
        log "OK: $PEER_IP reachable via $INTERFACE"
    fi
    exit 0
fi

log "FAIL: $PEER_IP unreachable via $INTERFACE -- bouncing tunnel"

if wg-quick down "$INTERFACE" >/dev/null 2>&1; then
    log "wg-quick down $INTERFACE: ok"
else
    log "wg-quick down $INTERFACE: failed (continuing)"
fi

sleep 2

if wg-quick up "$INTERFACE" >/dev/null 2>&1; then
    log "wg-quick up $INTERFACE: ok"
else
    log "wg-quick up $INTERFACE: failed"
    exit 1
fi
