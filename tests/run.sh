#!/bin/bash
# Run all watchdog tests. Exit non-zero on any failure.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILED=0
for t in "$TESTS_DIR/test_lib.sh" "$TESTS_DIR/test_watchdog_e2e.sh"; do
    echo
    echo "==================================================================="
    echo "  $t"
    echo "==================================================================="
    bash "$t" || FAILED=1
done

echo
if [[ $FAILED -eq 0 ]]; then
    echo "ALL GREEN."
else
    echo "SOME TESTS FAILED."
    exit 1
fi
