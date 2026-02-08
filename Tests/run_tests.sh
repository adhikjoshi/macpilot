#!/bin/bash
# MacPilot integration tests
# Run: bash Tests/run_tests.sh

set -u

MP="${MACPILOT_BIN:-$(pwd)/.build/release/macpilot}"
PASS=0
FAIL=0

assert_contains() {
    local test_name="$1" output="$2" expected="$3"
    if echo "$output" | grep -q "$expected"; then
        echo "✅ $test_name"
        ((PASS++))
    else
        echo "❌ $test_name — expected '$expected' in output"
        ((FAIL++))
    fi
}

echo "=== MacPilot Integration Tests ==="
echo "Binary: $MP"
echo ""

if [ ! -x "$MP" ]; then
    echo "❌ Binary not found or not executable at: $MP"
    exit 1
fi

out=$($MP --version 2>&1)
assert_contains "version" "$out" "0.5.0"

out=$($MP ax-check --json 2>&1)
assert_contains "ax-check returns JSON" "$out" '"status" : "ok"'
assert_contains "ax-check has trusted field" "$out" '"trusted"'

out=$($MP wait window "__definitely_not_a_window__" --timeout 0.2 --json 2>&1) || true
assert_contains "wait window timeout response" "$out" "Timeout waiting for window"

out=$($MP window focus --app "__not_running__" --json 2>&1) || true
assert_contains "window focus graceful missing app" "$out" "App not running"

out=$($MP run --json 2>&1) || true
assert_contains "run bundle guidance" "$out" "build-app.sh"

out=$($MP app launch "__not_a_real_app__" --json 2>&1) || true
assert_contains "app launch json parsing" "$out" "\"status\""

out=$($MP app frontmost --json 2>&1) || true
assert_contains "app frontmost json parsing" "$out" "\"status\""

out=$($MP chrome list-tabs --json 2>&1) || true
assert_contains "chrome list-tabs json parsing" "$out" "\"status\""

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
