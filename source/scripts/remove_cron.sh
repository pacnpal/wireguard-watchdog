#!/bin/bash
# Remove the persisted cron file and re-sync /etc/cron.d/.
set -u
export PATH="/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin"

rm -f /boot/config/plugins/wg-watchdog/wg-watchdog.cron
/usr/local/sbin/update_cron 2>/dev/null
echo "wg-watchdog: cron removed"
