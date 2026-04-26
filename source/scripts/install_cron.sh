#!/bin/bash
# Generate /boot/config/plugins/wg-watchdog/wg-watchdog.cron from cfg, then
# trigger update_cron so the active crontab picks it up.

set -u
export PATH="/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin"

PLUGIN_DIR="/boot/config/plugins/wg-watchdog"
CFG="$PLUGIN_DIR/wg-watchdog.cfg"
CRON="$PLUGIN_DIR/wg-watchdog.cron"
SCRIPT="/usr/local/emhttp/plugins/wg-watchdog/scripts/watchdog.sh"

SERVICE_ENABLED="no"
INTERVAL="60"
[[ -f "$CFG" ]] && . "$CFG"

mkdir -p "$PLUGIN_DIR"

if [[ "$SERVICE_ENABLED" != "yes" ]]; then
    rm -f "$CRON"
    /usr/local/sbin/update_cron 2>/dev/null
    echo "wg-watchdog: disabled, cron removed"
    exit 0
fi

# Sanitize INTERVAL: integer, min 20.
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]]; then INTERVAL=60; fi
(( INTERVAL < 20 )) && INTERVAL=20

if (( INTERVAL >= 60 )); then
    if (( INTERVAL % 60 == 0 )); then
        MIN=$((INTERVAL / 60))
        if (( MIN == 1 )); then
            CRONLINE="* * * * * $SCRIPT >/dev/null 2>&1"
        else
            CRONLINE="*/$MIN * * * * $SCRIPT >/dev/null 2>&1"
        fi
    else
        # Non-divisor of 60: fall back to per-minute (close enough).
        CRONLINE="* * * * * $SCRIPT >/dev/null 2>&1"
    fi
    {
        echo "# wg-watchdog (auto-generated, interval=${INTERVAL}s)"
        echo "$CRONLINE"
    } > "$CRON"
else
    PER_MINUTE=$((60 / INTERVAL))
    {
        echo "# wg-watchdog (auto-generated, sub-minute interval=${INTERVAL}s)"
        echo "* * * * * $SCRIPT >/dev/null 2>&1"
        for ((i = 1; i < PER_MINUTE; i++)); do
            DELAY=$((i * INTERVAL))
            echo "* * * * * sleep $DELAY && $SCRIPT >/dev/null 2>&1"
        done
    } > "$CRON"
fi

/usr/local/sbin/update_cron 2>/dev/null
echo "wg-watchdog: cron installed (interval=${INTERVAL}s)"
