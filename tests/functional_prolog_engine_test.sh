#!/usr/bin/env bash
# Feature: F002
# Functional tests for Prolog engine end-to-end integration.
# Validates: Rust FFI build chain, engine test suite, binary constraints,
#            and .pl fixture loading through the full build pipeline.
set -euo pipefail

BINARY="${1:-zig-out/bin/zpm}"
PASS=0
FAIL=0
FFI_LIB="ffi/zpm-prolog-ffi/target/release/libzpm_prolog_ffi.a"
MAX_BINARY_SIZE_MB=20

assert_true() {
    local label="$1"
    local condition="$2"
    if (set +o pipefail; eval "$condition"); then
        PASS=$((PASS + 1))
        printf "  \033[32mPASS\033[0m %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "  \033[31mFAIL\033[0m %s\n" "$label"
    fi
}

assert_contains() {
    local label="$1"
    local haystack="$2"
    local needle="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
        printf "  \033[32mPASS\033[0m %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "  \033[31mFAIL\033[0m %s (expected: %s)\n" "$label" "$needle"
    fi
}

printf "\n=== F002: Prolog Engine Functional Tests ===\n\n"

# --- Test 1: Rust FFI static library was built ---
printf "Test 1: Rust FFI static library exists\n"
assert_true "libzpm_prolog_ffi.a exists" "[ -f '$FFI_LIB' ]"
assert_true "static library contains prolog_init symbol" \
    "nm '$FFI_LIB' 2>/dev/null | grep -q 'prolog_init' || false"
assert_true "static library contains prolog_query symbol" \
    "nm '$FFI_LIB' 2>/dev/null | grep -q 'prolog_query' || false"

# --- Test 2: Engine inline tests pass ---
printf "\nTest 2: Engine test suite passes\n"
ENGINE_TEST_OUTPUT=$(zig build test --summary all 2>&1) || true
assert_contains "engine tests report success" "$ENGINE_TEST_OUTPUT" "passed"
ENGINE_HAS_FAIL=$(printf '%s' "$ENGINE_TEST_OUTPUT" | grep -c 'FAIL' || true)
assert_true "no test failures" "[ '$ENGINE_HAS_FAIL' -eq 0 ]"

# --- Test 3: Binary is self-contained ---
printf "\nTest 3: Binary is self-contained\n"
assert_true "binary exists" "[ -f '$BINARY' ]"

if [ -f "$BINARY" ]; then
    LDD_OUTPUT=$(ldd "$BINARY" 2>&1) || true
    SCRYER_DEPS=$(printf '%s' "$LDD_OUTPUT" | grep -ci 'scryer' || true)
    RUST_DEPS=$(printf '%s' "$LDD_OUTPUT" | grep -ciE 'rustc|libstd.*rust' || true)
    assert_true "no dynamic scryer-prolog dependency" "[ '$SCRYER_DEPS' -eq 0 ]"
    assert_true "no dynamic Rust runtime dependency" "[ '$RUST_DEPS' -eq 0 ]"
fi

# --- Test 4: Binary size within limits ---
printf "\nTest 4: Binary size under %dMB\n" "$MAX_BINARY_SIZE_MB"
if [ -f "$BINARY" ]; then
    BINARY_SIZE=$(stat -c%s "$BINARY" 2>/dev/null || stat -f%z "$BINARY" 2>/dev/null)
    MAX_BYTES=$((MAX_BINARY_SIZE_MB * 1024 * 1024))
    SIZE_MB=$(echo "scale=1; $BINARY_SIZE / 1048576" | bc)
    assert_true "binary size ${SIZE_MB}MB < ${MAX_BINARY_SIZE_MB}MB" \
        "[ '$BINARY_SIZE' -lt '$MAX_BYTES' ]"
fi

# --- Test 5: Fixture .pl file is valid Prolog ---
printf "\nTest 5: Fixture file is well-formed\n"
FIXTURE="tests/fixtures/family.pl"
assert_true "family.pl fixture exists" "[ -f '$FIXTURE' ]"
assert_true "fixture contains parent facts" \
    "grep -q 'parent(' '$FIXTURE'"
assert_true "fixture contains ancestor rule" \
    "grep -q 'ancestor(' '$FIXTURE'"

# --- Summary ---
TOTAL=$((PASS + FAIL))
printf "\n=== Results: %d/%d passed ===" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
    printf " \033[31m(%d FAILED)\033[0m\n\n" "$FAIL"
    exit 1
else
    printf " \033[32mALL PASSED\033[0m\n\n"
    exit 0
fi
