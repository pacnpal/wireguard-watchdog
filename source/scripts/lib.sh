#!/bin/bash
# Pure helpers used by watchdog.sh. Sourced only; nothing runs on its own.
#
# All functions here are side-effect-free except where noted, so they can
# be unit-tested in isolation.

# conf_redirect_prone <conf-path>
#
# Returns 0 (success) if the on-disk conf would cause `wg-quick up` to
# install the `ip rule not fwmark <T> table <T>` rule that redirects every
# unmarked packet through the interface. Specifically:
#
#   - the file exists, AND
#   - at least one [Peer] AllowedIPs contains 0.0.0.0/0 or ::/0, AND
#   - the [Interface] section does NOT contain `Table = off`.
#
# Comments (`#` to EOL) are stripped before parsing. Whitespace and case
# are tolerant. Returns non-zero in every other case (file missing, file
# unreadable, restricted AllowedIPs, or Table = off present).
conf_redirect_prone() {
    local conf="$1"
    [[ -f "$conf" && -r "$conf" ]] || return 1

    awk '
        BEGIN { IGNORECASE = 1; section = ""; has_default = 0; table_off = 0 }
        { sub(/[[:space:]]*#.*$/, "") }                  # strip comments
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }      # trim
        /^$/ { next }
        /^\[[^]]+\]$/ {
            section = $0
            sub(/^\[/, "", section); sub(/\]$/, "", section)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
            section = tolower(section)
            next
        }
        /=/ {
            key = $0
            sub(/[[:space:]]*=.*$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            key = tolower(key)

            val = $0
            sub(/^[^=]*=[[:space:]]*/, "", val)

            if (section == "interface" && key == "table") {
                vlower = tolower(val)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", vlower)
                if (vlower == "off") table_off = 1
            } else if (section == "peer" && key == "allowedips") {
                n = split(val, parts, /[[:space:]]*,[[:space:]]*/)
                for (i = 1; i <= n; i++) {
                    p = parts[i]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
                    if (p == "0.0.0.0/0" || p == "::/0") has_default = 1
                }
            }
        }
        END { exit (has_default && !table_off) ? 0 : 1 }
    ' "$conf"
}

# auto_routing_active <iface>
#
# Returns 0 if wg-quick's auto-routing fwmark is currently set on the
# interface. When it is, the kernel already has the redirecting ip rule
# installed; a subsequent `wg-quick up` that re-applies it is a no-op
# from the user's routing-state perspective. When it isn't, the tunnel
# was brought up via a path that didn't add the redirect, and a hard
# bounce would newly install it -- which is the user-visible bug.
#
# `wg show <iface> fwmark` prints "off" or a hex value. Anything other
# than "off" / empty means a fwmark is set.
auto_routing_active() {
    local iface="$1" fwmark
    fwmark=$(wg show "$iface" fwmark 2>/dev/null)
    [[ -n "$fwmark" && "$fwmark" != "off" && "$fwmark" != "0" ]]
}

# routing_snapshot
#
# Emits a stable, sorted string of the host's ip rule and full routing
# table state. Used to assert that the soft bounce did not perturb host
# routing -- if pre/post snapshots ever diverge, the watchdog has
# regressed into the original bug and we want a loud log entry.
routing_snapshot() {
    {
        echo "## ip -4 rule"
        ip -4 rule show 2>/dev/null | sort
        echo "## ip -6 rule"
        ip -6 rule show 2>/dev/null | sort
        echo "## ip -4 route show table all"
        ip -4 route show table all 2>/dev/null | sort
        echo "## ip -6 route show table all"
        ip -6 route show table all 2>/dev/null | sort
    }
}
