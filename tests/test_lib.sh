#!/bin/bash
# Unit tests for source/scripts/lib.sh
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

# shellcheck source=../source/scripts/lib.sh
. "$REPO_ROOT/source/scripts/lib.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

ok()   { PASS=$((PASS+1)); printf '  \e[32mPASS\e[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \e[31mFAIL\e[0m %s\n' "$1"; }

assert_prone() {
    local name="$1" path="$2"
    if conf_redirect_prone "$path"; then ok "$name"; else fail "$name (expected prone)"; fi
}
assert_safe() {
    local name="$1" path="$2"
    if conf_redirect_prone "$path"; then fail "$name (expected safe)"; else ok "$name"; fi
}

echo "== conf_redirect_prone: prone configs =="
assert_prone "default-only conf (no Table)"        "$FIXTURES/prone_default.conf"
assert_prone "v4-only 0.0.0.0/0"                   "$FIXTURES/prone_v4_only.conf"
assert_prone "v6-only ::/0"                        "$FIXTURES/prone_v6_only.conf"
assert_prone "Table=auto explicit"                 "$FIXTURES/prone_table_auto.conf"
assert_prone "Table=12345 numeric"                 "$FIXTURES/prone_numeric_table.conf"
assert_prone "0.0.0.0/0 in one of multiple peers"  "$FIXTURES/prone_one_of_many.conf"
assert_prone "comment tricks (real line, decoys)"  "$FIXTURES/comment_tricks.conf"

echo
echo "== conf_redirect_prone: safe configs =="
assert_safe  "Table=off + 0.0.0.0/0 (full-tunnel done right)" "$FIXTURES/safe_table_off.conf"
assert_safe  "Table = OFF (whitespace + case)"                "$FIXTURES/safe_table_off_then_default.conf"
assert_safe  "restricted AllowedIPs"                          "$FIXTURES/safe_restricted.conf"
assert_safe  "comments only mention 0.0.0.0/0"                "$FIXTURES/safe_comment_only_default.conf"
assert_safe  "multiple peers, none redirecting"               "$FIXTURES/safe_multi_peer.conf"
assert_safe  "empty conf"                                     "$FIXTURES/empty.conf"

echo
echo "== conf_redirect_prone: missing/unreadable =="
if conf_redirect_prone "$FIXTURES/does_not_exist.conf"; then
    fail "missing file should not be 'prone'"
else
    ok "missing file -> not prone"
fi

# Unreadable: only meaningful when not running as root.
if [[ "$EUID" -ne 0 ]]; then
    UNREAD="$(mktemp)"
    : > "$UNREAD"; chmod 000 "$UNREAD"
    if conf_redirect_prone "$UNREAD"; then
        fail "unreadable file should not be 'prone'"
    else
        ok "unreadable file -> not prone"
    fi
    chmod 644 "$UNREAD"; rm -f "$UNREAD"
else
    echo "  skip: unreadable-file check (running as root)"
fi

echo
echo "== auto_routing_active =="
# The lib calls `wg show <iface> fwmark`. Override the wg shim per case.
WG_SHIM_DIR="$(mktemp -d)"
cat > "$WG_SHIM_DIR/wg" <<'EOF'
#!/bin/bash
[[ "$1" == "show" && "$3" == "fwmark" ]] && { echo "${WGW_FAKE_FWMARK:-off}"; exit 0; }
exit 0
EOF
chmod +x "$WG_SHIM_DIR/wg"
PATH_BACKUP="$PATH"
export PATH="$WG_SHIM_DIR:$PATH"

WGW_FAKE_FWMARK="off"  auto_routing_active wg0  && fail "fwmark=off -> active?" || ok "fwmark=off -> not active"
WGW_FAKE_FWMARK=""     auto_routing_active wg0  && fail "fwmark=empty -> active?" || ok "fwmark=empty -> not active"
WGW_FAKE_FWMARK="0"    auto_routing_active wg0  && fail "fwmark=0 -> active?" || ok "fwmark=0 -> not active"
WGW_FAKE_FWMARK="0xca6c" auto_routing_active wg0 && ok "fwmark=0xca6c -> active" || fail "fwmark=0xca6c -> active?"

export PATH="$PATH_BACKUP"
rm -rf "$WG_SHIM_DIR"

echo
echo "== routing_snapshot =="
# Just smoke-test that it produces stable, parseable output.
SNAP="$(routing_snapshot 2>/dev/null || true)"
if [[ "$SNAP" == *"## ip -4 rule"* && "$SNAP" == *"## ip -6 rule"* && \
      "$SNAP" == *"## ip -4 route show table all"* && \
      "$SNAP" == *"## ip -6 route show table all"* ]]; then
    ok "routing_snapshot includes all four sections"
else
    fail "routing_snapshot missing sections"
fi

echo
printf 'lib tests: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    printf 'failed: %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
