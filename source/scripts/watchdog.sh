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

# Verbose if cfg says so OR if we're in test mode (test should always be loud).
LOUD="no"
[[ "$VERBOSE" == "yes" || "$TEST_MODE" == "yes" ]] && LOUD="yes"

log() {
    local ts msg="$1"
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ "$TEST_MODE" == "yes" ]]; then
        echo "[$ts] $msg"
    else
        echo "[$ts] $msg" >> "$LOG_FILE"
    fi
}

# Log each non-empty line of stdin with a 2-space indent and optional prefix.
log_each() {
    local prefix="${1:-}"
    while IFS= read -r line; do
        [[ -n "$line" ]] && log "  ${prefix}${line}"
    done
}

if [[ "$TEST_MODE" != "yes" && "$SERVICE_ENABLED" != "yes" ]]; then
    exit 0
fi

exec 9>"$LOCK" || { log "ERROR: cannot open lockfile $LOCK"; exit 1; }
if ! flock -n 9; then
    [[ "$LOUD" == "yes" ]] && log "skipped: previous run still in progress"
    exit 0
fi

[[ "$LOUD" == "yes" ]] && log "check start: interface=$INTERFACE peer=$PEER_IP pid=$$"

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    log "FAIL: interface $INTERFACE does not exist"
    if [[ "$LOUD" == "yes" ]]; then
        log "  available wg interfaces:"
        ip -br link show type wireguard 2>/dev/null | log_each "    " || \
            log "    (none — is WireGuard configured under Settings -> VPN Manager?)"
    fi
    exit 1
fi

# Run the ping, capture stdout+stderr for verbose detail.
PING_OUT=$(ping -c 2 -W 3 -I "$INTERFACE" "$PEER_IP" 2>&1)
PING_RC=$?

if [[ $PING_RC -eq 0 ]]; then
    if [[ "$LOUD" == "yes" ]]; then
        # Pull the "X packets transmitted..." and rtt summary lines.
        STATS=$(printf '%s\n' "$PING_OUT" \
                | grep -E 'packets transmitted|rtt|round-trip' \
                | tr '\n' ' | ' \
                | sed -e 's/[[:space:]]\+/ /g' -e 's/ | $//')
        log "OK: $PEER_IP reachable via $INTERFACE -- $STATS"
    fi
    if [[ "$TEST_MODE" == "yes" ]]; then
        log "--- wg show $INTERFACE ---"
        wg show "$INTERFACE" 2>&1 | log_each
        log "--- ip -4 addr show $INTERFACE ---"
        ip -4 addr show "$INTERFACE" 2>&1 | log_each
    fi
    exit 0
fi

# Failure path
if [[ "$LOUD" == "yes" ]]; then
    log "ping output (rc=$PING_RC):"
    printf '%s\n' "$PING_OUT" | log_each "ping: "
fi
log "FAIL: $PEER_IP unreachable via $INTERFACE -- bouncing tunnel"

DOWN_OUT=$(wg-quick down "$INTERFACE" 2>&1)
DOWN_RC=$?
if [[ $DOWN_RC -eq 0 ]]; then
    log "wg-quick down $INTERFACE: ok"
else
    log "wg-quick down $INTERFACE: failed (rc=$DOWN_RC, continuing)"
fi
[[ "$LOUD" == "yes" ]] && printf '%s\n' "$DOWN_OUT" | log_each "down: "

sleep 2

UP_OUT=$(wg-quick up "$INTERFACE" 2>&1)
UP_RC=$?
if [[ $UP_RC -eq 0 ]]; then
    log "wg-quick up $INTERFACE: ok"
else
    log "wg-quick up $INTERFACE: failed (rc=$UP_RC)"
fi
[[ "$LOUD" == "yes" ]] && printf '%s\n' "$UP_OUT" | log_each "up: "

[[ $UP_RC -eq 0 ]] || exit 1
