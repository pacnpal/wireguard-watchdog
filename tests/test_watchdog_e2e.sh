#!/bin/bash
# Integration tests for source/scripts/watchdog.sh
#
# Each test:
#   1. Builds an isolated sandbox dir with mock wg/wg-quick/ip/ping
#      binaries on PATH plus a fake /etc/wireguard pointing at a fixture.
#   2. Runs watchdog.sh in --test mode under the sandbox.
#   3. Asserts on watchdog stdout (the --test log) and the mocks' call logs.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
WATCHDOG="$REPO_ROOT/source/scripts/watchdog.sh"
FIXTURES="$TESTS_DIR/fixtures"

PASS=0
FAIL=0
FAILED_NAMES=()
SANDBOXES=()

cleanup() { for d in "${SANDBOXES[@]}"; do [[ -n "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  \e[32mPASS\e[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \e[31mFAIL\e[0m %s\n  %s\n' "$1" "${2:-}"; }

# --- mock writer ---
write_mocks() {
    local dir="$1"
    mkdir -p "$dir/bin" "$dir/calls" "$dir/state"

    cat > "$dir/bin/wg" <<'MOCK'
#!/bin/bash
echo "$*" >> "$WGW_TEST_DIR/calls/wg"
case "$1 $2" in
    "show interfaces")
        if [[ -f "$WGW_TEST_DIR/state/iface_up" ]]; then
            cat "$WGW_TEST_DIR/state/iface_up"
        fi
        ;;
    "show wg0")
        if [[ "$3" == "fwmark" ]]; then
            cat "$WGW_TEST_DIR/state/fwmark" 2>/dev/null || echo "off"
        elif [[ "$3" == "peers" ]]; then
            cat "$WGW_TEST_DIR/state/peers" 2>/dev/null
        else
            echo "interface: wg0"
        fi
        ;;
    "showconf wg0")
        rc="${WGW_SHOWCONF_RC:-0}"
        if [[ "$rc" == "0" ]]; then
            echo "[Interface]"
            echo "ListenPort = 51820"
            while IFS= read -r pk; do
                [[ -n "$pk" ]] || continue
                echo
                echo "[Peer]"
                echo "PublicKey = $pk"
                echo "AllowedIPs = 0.0.0.0/0"
            done < "$WGW_TEST_DIR/state/peers"
        fi
        exit "$rc"
        ;;
    "set wg0")
        if [[ "$3" == "peer" && "$5" == "remove" ]]; then
            rc="${WGW_PEER_REMOVE_RC:-0}"
            if [[ "$rc" == "0" ]]; then
                pk="$4"
                if [[ -f "$WGW_TEST_DIR/state/peers" ]]; then
                    grep -v "^$pk\$" "$WGW_TEST_DIR/state/peers" \
                        > "$WGW_TEST_DIR/state/peers.tmp" || true
                    mv "$WGW_TEST_DIR/state/peers.tmp" "$WGW_TEST_DIR/state/peers"
                fi
            fi
            exit "$rc"
        fi
        ;;
    "syncconf wg0")
        # Distinguish the soft-path sync (call #1) from the rollback
        # sync (call #2, only fires when #1 fails). WGW_SYNC_RC governs
        # the first; WGW_ROLLBACK_RC governs the second (default 0).
        cnt_file="$WGW_TEST_DIR/state/syncconf_count"
        cnt=$(( $(cat "$cnt_file" 2>/dev/null || echo 0) + 1 ))
        echo "$cnt" > "$cnt_file"
        if [[ "$cnt" == "1" ]]; then
            rc="${WGW_SYNC_RC:-0}"
        else
            rc="${WGW_ROLLBACK_RC:-0}"
        fi
        if [[ "$rc" == "0" && -f "$WGW_TEST_DIR/state/peers_canonical" ]]; then
            cp "$WGW_TEST_DIR/state/peers_canonical" "$WGW_TEST_DIR/state/peers"
        fi
        exit "$rc"
        ;;
esac
exit 0
MOCK

    cat > "$dir/bin/wg-quick" <<'MOCK'
#!/bin/bash
echo "$*" >> "$WGW_TEST_DIR/calls/wg-quick"
case "$1" in
    strip)
        rc="${WGW_STRIP_RC:-0}"
        if [[ "$rc" == "0" ]]; then
            cat "$ETC_WIREGUARD/$2.conf"
        else
            echo "wg-quick: strip failed (mock)" >&2
        fi
        exit "$rc"
        ;;
    down)
        echo "[#] ip link delete dev $2" >&2
        rm -f "$WGW_TEST_DIR/state/iface_up"
        rm -f "$WGW_TEST_DIR/state/fwmark"
        exit "${WGW_DOWN_RC:-0}"
        ;;
    up)
        rc="${WGW_UP_RC:-0}"
        if [[ "$rc" == "0" ]]; then
            echo "$2" > "$WGW_TEST_DIR/state/iface_up"
            if grep -qiE '^[[:space:]]*AllowedIPs[[:space:]]*=.*(0\.0\.0\.0/0|::/0)' \
                  "$ETC_WIREGUARD/$2.conf" \
               && ! grep -qiE '^[[:space:]]*Table[[:space:]]*=[[:space:]]*off([[:space:]]*($|#))?' \
                       "$ETC_WIREGUARD/$2.conf"; then
                echo "0xca6c" > "$WGW_TEST_DIR/state/fwmark"
                echo "not from all fwmark 0xca6c lookup 51820" \
                    >> "$WGW_TEST_DIR/state/ip_rule_v4_added"
            fi
        fi
        exit "$rc"
        ;;
esac
exit 0
MOCK

    cat > "$dir/bin/ip" <<'MOCK'
#!/bin/bash
echo "$*" >> "$WGW_TEST_DIR/calls/ip"
case "$*" in
    "link show "*)
        iface="${3:-wg0}"
        if [[ -f "$WGW_TEST_DIR/state/iface_up" ]] \
           && grep -q "^$iface\$" "$WGW_TEST_DIR/state/iface_up"; then
            exit 0
        fi
        echo "Device \"$iface\" does not exist." >&2
        exit 1
        ;;
    "-br link show type wireguard")
        if [[ -f "$WGW_TEST_DIR/state/iface_up" ]]; then
            while read -r i; do echo "$i UNKNOWN"; done < "$WGW_TEST_DIR/state/iface_up"
        fi
        exit 0
        ;;
    "-4 addr show "*) echo "    inet 10.0.0.2/24 scope global"; exit 0 ;;
    "-4 rule show")
        echo "0:      from all lookup local"
        cat "$WGW_TEST_DIR/state/ip_rule_v4_added" 2>/dev/null || true
        echo "32766:  from all lookup main"
        echo "32767:  from all lookup default"
        exit 0
        ;;
    "-6 rule show")
        echo "0:      from all lookup local"
        echo "32766:  from all lookup main"
        exit 0
        ;;
    "-4 route show table all"|"-6 route show table all")
        # Stable, sorted output.
        echo "default via 192.168.1.1"
        exit 0
        ;;
esac
exit 0
MOCK

    cat > "$dir/bin/ping" <<'MOCK'
#!/bin/bash
echo "$*" >> "$WGW_TEST_DIR/calls/ping"
rc="${WGW_PING_RC:-0}"
if [[ "$rc" == "0" ]]; then
    cat <<EOF
PING 10.99.0.1 (10.99.0.1) 56(84) bytes of data.
64 bytes from 10.99.0.1: icmp_seq=1 ttl=64 time=1.00 ms
64 bytes from 10.99.0.1: icmp_seq=2 ttl=64 time=1.10 ms

--- 10.99.0.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
rtt min/avg/max/mdev = 1.000/1.050/1.100/0.050 ms
EOF
else
    cat <<EOF
PING 10.99.0.1 (10.99.0.1) 56(84) bytes of data.
From 10.0.0.1 icmp_seq=1 Destination Host Unreachable

--- 10.99.0.1 ping statistics ---
2 packets transmitted, 0 received, +2 errors, 100% packet loss, time 1002ms
EOF
fi
exit "$rc"
MOCK

    chmod +x "$dir/bin"/*
}

# --- per-test setup ---
setup_sandbox() {
    local conf_fixture="$1"
    local sandbox
    sandbox="$(mktemp -d)"
    write_mocks "$sandbox"

    mkdir -p "$sandbox/etc/wireguard"
    cp "$conf_fixture" "$sandbox/etc/wireguard/wg0.conf"

    # Fake "interface up" + canonical peers extracted from the conf.
    echo "wg0" > "$sandbox/state/iface_up"
    grep -A1 '^\[Peer\]' "$conf_fixture" | grep '^PublicKey' \
        | sed 's/^PublicKey *= *//' > "$sandbox/state/peers_canonical"
    cp "$sandbox/state/peers_canonical" "$sandbox/state/peers"

    SANDBOXES+=("$sandbox")
    echo "$sandbox"
}

# Run watchdog in a sandbox; collect stdout + return code.
run_watchdog() {
    local sandbox="$1"; shift
    (
        export WGW_TEST_DIR="$sandbox"
        export ETC_WIREGUARD="$sandbox/etc/wireguard"
        export PATH="$sandbox/bin:$PATH"
        # Defaults applied unless caller exports overrides before calling.
        : "${WGW_PING_RC:=0}" "${WGW_STRIP_RC:=0}" "${WGW_SYNC_RC:=0}"
        : "${WGW_DOWN_RC:=0}" "${WGW_UP_RC:=0}" "${WGW_PEER_REMOVE_RC:=0}"
        export WGW_PING_RC WGW_STRIP_RC WGW_SYNC_RC \
               WGW_DOWN_RC WGW_UP_RC WGW_PEER_REMOVE_RC
        bash "$WATCHDOG" --test 2>&1
    )
}

calls() { cat "$1/calls/$2" 2>/dev/null; }

# --- assertions ---
assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    [[ "$haystack" == *"$needle"* ]] && ok "$name" || \
        fail "$name" "expected substring: $needle"$'\n'"got:"$'\n'"$haystack"
}
assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    [[ "$haystack" != *"$needle"* ]] && ok "$name" || \
        fail "$name" "did not expect substring: $needle"$'\n'"got:"$'\n'"$haystack"
}
assert_no_call() {
    local name="$1" sandbox="$2" mock="$3" needle="$4"
    local c; c="$(calls "$sandbox" "$mock")"
    if [[ -z "$c" || "$c" != *"$needle"* ]]; then ok "$name"
    else fail "$name" "did not expect $mock call matching: $needle"$'\n'"got: $c"; fi
}
assert_call() {
    local name="$1" sandbox="$2" mock="$3" needle="$4"
    local c; c="$(calls "$sandbox" "$mock")"
    if [[ "$c" == *"$needle"* ]]; then ok "$name"
    else fail "$name" "expected $mock call matching: $needle"$'\n'"got: $c"; fi
}

# ---------- Test cases ----------

run_case() { echo; echo "== $1 =="; }

run_case "T1: healthy ping -> exit 0, no bounce"
sb="$(setup_sandbox "$FIXTURES/safe_restricted.conf")"
out="$(run_watchdog "$sb")"; rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || fail "exit 0" "rc=$rc"
assert_contains   "logs OK reachable" "$out" "OK: 10.99.0.1 reachable via wg0"
assert_no_call    "no wg-quick down/up" "$sb" "wg-quick" "down"
assert_no_call    "no wg-quick up"      "$sb" "wg-quick" "up"
assert_no_call    "no wg syncconf"      "$sb" "wg" "syncconf"

run_case "T2: ping fails, soft path succeeds -> exit 0, NO hard bounce, ip rule unchanged"
sb="$(setup_sandbox "$FIXTURES/prone_default.conf")"
out="$(WGW_PING_RC=1 run_watchdog "$sb")"; rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || fail "exit 0" "rc=$rc"
assert_contains   "logs FAIL/bouncing"   "$out" "bouncing tunnel"
assert_contains   "logs sync ok"         "$out" "wg syncconf wg0: ok"
assert_call       "wg syncconf called"   "$sb" "wg" "syncconf wg0"
assert_no_call    "no wg-quick down"     "$sb" "wg-quick" "down wg0"
assert_no_call    "no wg-quick up"       "$sb" "wg-quick" "up wg0"
# Critical: no auto-routing rule was added on the live host.
[[ ! -s "$sb/state/ip_rule_v4_added" ]] && ok "no fwmark rule appeared" || \
    fail "no fwmark rule appeared" "ip_rule_v4_added: $(cat "$sb/state/ip_rule_v4_added")"

run_case "T3: ping fails, sync fails, conf is SAFE -> hard bounce executes"
sb="$(setup_sandbox "$FIXTURES/safe_table_off.conf")"
out="$(WGW_PING_RC=1 WGW_SYNC_RC=1 run_watchdog "$sb")"; rc=$?
[[ $rc -eq 0 ]] && ok "exit 0 (after hard bounce)" || fail "exit 0" "rc=$rc"
assert_contains "logs sync failed"     "$out" "wg syncconf wg0: failed"
assert_contains "logs evaluating hard" "$out" "evaluating hard fallback"
assert_contains "logs wg-quick up ok"  "$out" "wg-quick up wg0: ok"
assert_call     "wg-quick down wg0"    "$sb" "wg-quick" "down wg0"
assert_call     "wg-quick up wg0"      "$sb" "wg-quick" "up wg0"

run_case "T4: ping fails, sync fails, conf is PRONE & no fwmark -> hard bounce REFUSED, peers ROLLED BACK"
sb="$(setup_sandbox "$FIXTURES/prone_default.conf")"
echo "off" > "$sb/state/fwmark"
peers_before="$(cat "$sb/state/peers")"
out="$(WGW_PING_RC=1 WGW_SYNC_RC=1 run_watchdog "$sb")"; rc=$?
[[ $rc -eq 1 ]] && ok "exit 1 (refusal)" || fail "exit 1" "rc=$rc"
assert_contains "logs REFUSING"     "$out" "REFUSING hard bounce"
assert_contains "logs rollback"     "$out" "rollback restored pre-bounce peer set"
assert_no_call  "wg-quick down NOT called" "$sb" "wg-quick" "down wg0"
assert_no_call  "wg-quick up NOT called"   "$sb" "wg-quick" "up wg0"
[[ ! -s "$sb/state/ip_rule_v4_added" ]] && ok "no redirect rule installed" || \
    fail "no redirect rule installed" "ip_rule_v4_added populated"
peers_after="$(cat "$sb/state/peers")"
[[ "$peers_before" == "$peers_after" ]] && ok "peers preserved via rollback" || \
    fail "peers preserved via rollback" "before:$peers_before / after:$peers_after"

run_case "T5: ping fails, sync fails, conf is PRONE but fwmark already active -> hard bounce ALLOWED (user opted in)"
sb="$(setup_sandbox "$FIXTURES/prone_default.conf")"
echo "0xca6c" > "$sb/state/fwmark"
out="$(WGW_PING_RC=1 WGW_SYNC_RC=1 run_watchdog "$sb")"; rc=$?
[[ $rc -eq 0 ]] && ok "exit 0 (after hard bounce)" || fail "exit 0" "rc=$rc"
assert_not_contains "no REFUSING log" "$out" "REFUSING hard bounce"
assert_call         "wg-quick up wg0" "$sb" "wg-quick" "up wg0"

run_case "T6: ping fails, strip fails, conf is PRONE & no fwmark -> hard bounce REFUSED"
sb="$(setup_sandbox "$FIXTURES/prone_default.conf")"
echo "off" > "$sb/state/fwmark"
out="$(WGW_PING_RC=1 WGW_STRIP_RC=2 run_watchdog "$sb")"; rc=$?
[[ $rc -eq 1 ]] && ok "exit 1 (refusal)" || fail "exit 1" "rc=$rc"
assert_contains "logs strip failed" "$out" "wg-quick strip wg0: failed"
assert_contains "logs REFUSING"     "$out" "REFUSING hard bounce"
assert_no_call  "wg-quick up NOT called" "$sb" "wg-quick" "up wg0"
# Critical: peers NOT removed because strip failed first.
[[ "$(cat "$sb/state/peers")" != "" ]] && ok "peers preserved (strip-first ordering)" || \
    fail "peers preserved" "peers were wiped"

run_case "T7: ping fails, peer removal fails, sync still ok -> exit 0 (sync is source of truth)"
sb="$(setup_sandbox "$FIXTURES/prone_default.conf")"
out="$(WGW_PING_RC=1 WGW_PEER_REMOVE_RC=1 run_watchdog "$sb")"; rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || fail "exit 0" "rc=$rc"
assert_contains "logs partial peer note" "$out" "some peers failed to pre-remove"
assert_no_call  "no hard bounce" "$sb" "wg-quick" "up wg0"

run_case "T8: missing conf -> early exit, no bounce"
sb="$(setup_sandbox "$FIXTURES/safe_restricted.conf")"
rm "$sb/etc/wireguard/wg0.conf"
out="$(run_watchdog "$sb")"; rc=$?
[[ $rc -eq 1 ]] && ok "exit 1" || fail "exit 1" "rc=$rc"
assert_contains "logs not configured" "$out" "is not configured under Settings"
assert_no_call  "no ping called"      "$sb" "ping"     ""
assert_no_call  "no wg-quick"         "$sb" "wg-quick" ""

run_case "T9: interface absent -> early exit, no bounce"
sb="$(setup_sandbox "$FIXTURES/safe_restricted.conf")"
rm "$sb/state/iface_up"
out="$(run_watchdog "$sb")"; rc=$?
[[ $rc -eq 1 ]] && ok "exit 1" || fail "exit 1" "rc=$rc"
assert_contains "logs configured but not active" "$out" "configured but not active"
assert_no_call  "no wg-quick"                    "$sb" "wg-quick" ""

run_case "T10: regression for the original report -- prone conf, soft path succeeds, host routing UNCHANGED"
sb="$(setup_sandbox "$FIXTURES/prone_default.conf")"
echo "off" > "$sb/state/fwmark"  # Tunnel was brought up some other way
before_ip_rule="$(env WGW_TEST_DIR="$sb" PATH="$sb/bin:$PATH" ip -4 rule show)"
out="$(WGW_PING_RC=1 run_watchdog "$sb")"; rc=$?
after_ip_rule="$(env WGW_TEST_DIR="$sb" PATH="$sb/bin:$PATH" ip -4 rule show)"
[[ $rc -eq 0 ]] && ok "exit 0 (soft path succeeded)" || fail "exit 0" "rc=$rc"
[[ "$before_ip_rule" == "$after_ip_rule" ]] && ok "ip rule UNCHANGED across bounce (the bug fix invariant)" || \
    fail "ip rule changed" $'before:\n'"$before_ip_rule"$'\nafter:\n'"$after_ip_rule"
assert_no_call "wg-quick up NEVER called" "$sb" "wg-quick" "up wg0"

echo
printf 'e2e tests: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    printf 'failed:\n'
    for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
    exit 1
fi
