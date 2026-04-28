#!/bin/bash
# WireGuard Watchdog: ping a peer through the tunnel; bounce on failure.
#
# Usage:
#   watchdog.sh           normal scheduled run, honours SERVICE_ENABLED
#   watchdog.sh --test    one-shot diagnostic, ignores SERVICE_ENABLED, prints to stdout
#
# Recovery model:
#   1. Soft bounce (default path): `wg-quick strip` -> validate -> remove
#      live peers -> `wg syncconf`. Resets per-peer crypto state without
#      touching ip rules / routes / iptables.
#   2. Hard bounce (last resort): `wg-quick down/up`. This rebuilds the
#      conf's auto-routing, which on a redirect-prone conf installs the
#      `ip rule not fwmark <T> table <T>` rule that hijacks every unmarked
#      host packet (including any Docker container with --network host).
#      The hard path is REFUSED if the conf is redirect-prone AND the
#      auto-routing fwmark is not currently set on the interface -- a
#      hard bounce there would silently break host networking.

set -u
# Cron runs with a stripped PATH; restore the standard one so wg, wg-quick,
# ip, ping, etc. are findable. The test harness sets WGW_TEST_DIR and gets
# to keep its own PATH (with mock binaries first).
if [[ -z "${WGW_TEST_DIR:-}" ]]; then
    export PATH="/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

CFG="/boot/config/plugins/wg-watchdog/wg-watchdog.cfg"
LOCK="/var/lock/wg-watchdog.lock"
# Override only used by the integration test harness; defaults match Unraid.
ETC_WIREGUARD="${ETC_WIREGUARD:-/etc/wireguard}"

SERVICE_ENABLED="no"
INTERFACE="wg0"
PEER_IP="10.99.0.1"
INTERVAL="60"
VERBOSE="no"
LOG_FILE="/var/log/wg-watchdog.log"

# shellcheck source=/dev/null
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

CONF_PATH="$ETC_WIREGUARD/$INTERFACE.conf"

# Distinguish "tunnel not configured" from "tunnel configured but down":
# Unraid's VPN Manager creates /etc/wireguard/<iface>.conf when you add a
# tunnel, so its absence means the user has not set this tunnel up at all.
if [[ ! -f "$CONF_PATH" ]]; then
    log "FAIL: $INTERFACE is not configured under Settings -> VPN Manager (no $CONF_PATH)"
    if [[ "$LOUD" == "yes" ]]; then
        log "  configured tunnels:"
        # `cmd | log_each || log "(none)"` doesn't work: the pipeline's
        # exit status is log_each's, which is always 0. Capture first.
        CONF_LIST=$(ls "$ETC_WIREGUARD"/*.conf 2>/dev/null)
        if [[ -n "$CONF_LIST" ]]; then
            printf '%s\n' "$CONF_LIST" | log_each "    "
        else
            log "    (none)"
        fi
    fi
    exit 1
fi

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    log "FAIL: interface $INTERFACE does not exist (configured but not active -- start it under Settings -> VPN Manager)"
    if [[ "$LOUD" == "yes" ]]; then
        log "  active wg interfaces:"
        ACTIVE_IFACES=$(wg show interfaces 2>/dev/null)
        if [[ -n "$ACTIVE_IFACES" ]]; then
            printf '%s\n' "$ACTIVE_IFACES" | tr ' ' '\n' | log_each "    "
        else
            log "    (none)"
        fi
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

# ---- Failure path ----
if [[ "$LOUD" == "yes" ]]; then
    log "ping output (rc=$PING_RC):"
    printf '%s\n' "$PING_OUT" | log_each "ping: "
fi
log "FAIL: $PEER_IP unreachable via $INTERFACE -- bouncing tunnel"

# Snapshot routing state so we can assert the soft path didn't disturb it.
ROUTING_BEFORE=$(routing_snapshot)

# ---- Soft bounce ----
# Validate the on-disk conf BEFORE touching the live interface. If we
# remove peers first and then discover the conf is unreadable or empty,
# the interface is left up with no peers and the hard fallback (which
# reads the same broken conf) likely also fails.
SOFT_OK=no
STRIPPED_CONF=$(wg-quick strip "$INTERFACE" 2>&1)
STRIP_RC=$?
if [[ $STRIP_RC -ne 0 || -z "$STRIPPED_CONF" ]]; then
    log "wg-quick strip $INTERFACE: failed (rc=$STRIP_RC) -- skipping soft bounce"
    [[ "$LOUD" == "yes" ]] && printf '%s\n' "$STRIPPED_CONF" | log_each "strip: "
else
    # Capture the live interface's full conf for rollback. If we remove
    # peers and then syncconf fails AND the hard fallback is refused
    # (prone conf, no fwmark), we'd otherwise leave the interface up
    # with no peers -- a worse half-state than we started in.
    PRE_CONF=$(wg showconf "$INTERFACE" 2>&1)
    PRE_CONF_RC=$?
    if [[ $PRE_CONF_RC -ne 0 || -z "$PRE_CONF" ]]; then
        log "wg showconf $INTERFACE: failed (rc=$PRE_CONF_RC) -- skipping soft bounce (no rollback state)"
        [[ "$LOUD" == "yes" ]] && printf '%s\n' "$PRE_CONF" | log_each "showconf: "
    else
        PEERS=$(wg show "$INTERFACE" peers 2>/dev/null)
        REMOVE_RC=0
        for pk in $PEERS; do
            if ! wg set "$INTERFACE" peer "$pk" remove 2>/dev/null; then
                REMOVE_RC=1
            fi
        done

        SYNC_OUT=$(printf '%s\n' "$STRIPPED_CONF" | wg syncconf "$INTERFACE" /dev/stdin 2>&1)
        SYNC_RC=$?

        if [[ $SYNC_RC -eq 0 ]]; then
            SOFT_OK=yes
            if [[ $REMOVE_RC -eq 0 ]]; then
                log "wg syncconf $INTERFACE: ok (peer state reset; routes preserved)"
            else
                log "wg syncconf $INTERFACE: ok (sync succeeded; some peers failed to pre-remove, routes preserved)"
            fi
            [[ "$LOUD" == "yes" && -n "$SYNC_OUT" ]] && \
                printf '%s\n' "$SYNC_OUT" | log_each "sync: "
        else
            log "wg syncconf $INTERFACE: failed (rc=$SYNC_RC)"
            [[ "$LOUD" == "yes" ]] && printf '%s\n' "$SYNC_OUT" | log_each "sync: "

            # Best-effort rollback to pre-soft-bounce peer state, so a
            # subsequent hard-bounce refusal doesn't leave us with no peers.
            ROLLBACK_OUT=$(printf '%s\n' "$PRE_CONF" | wg syncconf "$INTERFACE" /dev/stdin 2>&1)
            ROLLBACK_RC=$?
            if [[ $ROLLBACK_RC -eq 0 ]]; then
                log "wg syncconf $INTERFACE: rollback restored pre-bounce peer set"
            else
                log "wg syncconf $INTERFACE: rollback failed (rc=$ROLLBACK_RC) -- interface may be peerless"
            fi
            [[ "$LOUD" == "yes" && -n "$ROLLBACK_OUT" ]] && \
                printf '%s\n' "$ROLLBACK_OUT" | log_each "rollback: "
        fi
    fi
fi

# Self-check: if the soft path ran successfully it MUST NOT have changed
# routing. If it did, that's the original-bug regression and we want a
# loud entry in the log.
if [[ "$SOFT_OK" == "yes" ]]; then
    ROUTING_AFTER=$(routing_snapshot)
    if [[ "$ROUTING_BEFORE" != "$ROUTING_AFTER" ]]; then
        log "WARN: routing state changed across soft bounce -- investigate (this is the bug the soft path is meant to avoid)"
        if [[ "$LOUD" == "yes" ]]; then
            log "  diff (before vs after):"
            diff <(printf '%s\n' "$ROUTING_BEFORE") <(printf '%s\n' "$ROUTING_AFTER") \
                2>/dev/null | log_each "    "
        fi
    fi
    exit 0
fi

# ---- Hard bounce gate ----
# Refuse the hard fallback when it would NEWLY install wg-quick's auto-
# routing (the redirect-everything-not-fwmarked rule). Specifically:
#   - the conf is redirect-prone (0/0 AllowedIPs without Table=off), AND
#   - the live interface does NOT currently have an auto-routing fwmark.
# That combination is exactly the report: tunnel was brought up some
# other way (custom script, container, manual setconf), so the redirect
# rule is not in place; a wg-quick up would add it.
log "soft bounce did not recover; evaluating hard fallback"
if conf_redirect_prone "$CONF_PATH" && ! auto_routing_active "$INTERFACE"; then
    log "REFUSING hard bounce: $CONF_PATH has AllowedIPs=0.0.0.0/0 (or ::/0) without 'Table = off',"
    log "  and the live interface has no auto-routing fwmark set. A wg-quick up here would install"
    log "  'ip rule not fwmark <T> table <T>' and silently redirect every unmarked host packet"
    log "  through $INTERFACE -- including any Docker container running with --network host."
    log "  To opt in: add 'Table = off' to [Interface] in $CONF_PATH and manage routes via"
    log "  PostUp/PostDown, or bring $INTERFACE up once via 'wg-quick up' yourself so the auto-"
    log "  routing is already in place when the watchdog runs."
    exit 1
fi

# ---- Hard bounce ----
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
