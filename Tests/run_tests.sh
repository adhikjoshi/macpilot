#!/bin/bash
# MacPilot integration tests
# Run: bash Tests/run_tests.sh

MP="/Users/admin/clawd/tools/macpilot/MacPilot.app/Contents/MacOS/MacPilot"
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

assert_exit_code() {
    local test_name="$1" expected="$2" actual="$3"
    if [ "$actual" -eq "$expected" ]; then
        echo "✅ $test_name"
        ((PASS++))
    else
        echo "❌ $test_name — expected exit code $expected, got $actual"
        ((FAIL++))
    fi
}

echo "=== MacPilot Integration Tests ==="
echo ""

# Test: version
out=$($MP --version 2>&1)
assert_contains "version" "$out" "0.3.0"

# Test: ax-check
out=$($MP ax-check --json 2>&1)
assert_contains "ax-check returns JSON" "$out" '"status" : "ok"'
assert_contains "ax-check has trusted field" "$out" '"trusted"'

# Test: screenshot
tmpfile="/tmp/macpilot_test_screenshot.png"
rm -f "$tmpfile"
out=$($MP screenshot --output "$tmpfile" --json 2>&1)
assert_contains "screenshot JSON" "$out" '"status" : "ok"'
if [ -f "$tmpfile" ] && [ "$(stat -f%z "$tmpfile")" -gt 1000 ]; then
    echo "✅ screenshot file created and >1KB"
    ((PASS++))
else
    echo "❌ screenshot file missing or too small"
    ((FAIL++))
fi
rm -f "$tmpfile"

# Test: app list
out=$($MP app list --json 2>&1)
assert_contains "app list has Finder" "$out" "Finder"

# Test: space list
out=$($MP space list --json 2>&1)
assert_contains "space list has current" "$out" '"current" : true'

# Test: clipboard
rand=$((RANDOM))
$MP clipboard set "test_$rand" --json > /dev/null 2>&1
out=$($MP clipboard get --json 2>&1)
assert_contains "clipboard roundtrip" "$out" "test_$rand"

# Test: chain with sleep actions
out=$($MP chain "sleep:10" "sleep:10" --delay 10 --json 2>&1)
assert_contains "chain executes" "$out" '"status" : "ok"'
assert_contains "chain action count" "$out" "2 actions"

# Test: safety - block system process quit
out=$($MP app quit WindowServer --json 2>&1) || true
assert_contains "safety blocks WindowServer quit" "$out" "REFUSED"

# Test: safety - block dangerous shell
out=$($MP shell run "rm -rf /System/test" --json 2>&1) || true
assert_contains "safety blocks rm system" "$out" "REFUSED"

# Test: safety - block TCC access
out=$($MP shell run "sqlite3 /private/var/db/TCC/TCC.db .tables" --json 2>&1) || true
assert_contains "safety blocks TCC" "$out" "REFUSED"

# Test: window list --all-spaces
out=$($MP window list --all-spaces --json 2>&1)
assert_contains "window list returns data" "$out" '"app"'

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
