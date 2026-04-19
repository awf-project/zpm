#!/usr/bin/env bash
# Shared test harness for ZPM bash test suites.
# Source this file at the top of each test script:
#   . "$(dirname "$0")/test_helpers.sh"

set -euo pipefail

PASS=0
FAIL=0

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

assert_true() {
    local label="$1"; shift
    if "$@" 2>/dev/null; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label"
        FAIL=$((FAIL + 1))
    fi
}

assert_false() {
    local label="$1"; shift
    if "$@" 2>/dev/null; then
        red "  FAIL: $label — expected false but got true"
        FAIL=$((FAIL + 1))
    else
        green "  PASS: $label"
        PASS=$((PASS + 1))
    fi
}

assert_equals() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label — expected: '$expected', got: '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label — expected output to contain: '$needle'"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        red "  FAIL: $label — output contains forbidden string: $needle"
        FAIL=$((FAIL + 1))
    else
        green "  PASS: $label"
        PASS=$((PASS + 1))
    fi
}

assert_exit_code() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" -eq "$expected" ]; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label — expected exit code $expected, got $actual"
        FAIL=$((FAIL + 1))
    fi
}

test_summary() {
    echo ""
    TOTAL=$((PASS + FAIL))
    if [ "$FAIL" -eq 0 ]; then
        green "All $TOTAL assertions passed."
    else
        red "$FAIL of $TOTAL assertions failed."
        exit 1
    fi
}
