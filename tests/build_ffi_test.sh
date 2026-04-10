#!/usr/bin/env bash
# Feature: F002 / T004
# Verifies that build.zig invokes `cargo build --release` and links libzpm_prolog_ffi into
# the Zig executable. Run after `zig build` to assert the complete build chain.
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

lib_has_symbol() {
    ( set +o pipefail; nm "$1" 2>/dev/null | grep -qF " T $2" )
}

# --- Test 1: zig build invokes cargo and completes without errors ---
echo "Test: zig build runs cargo and links Rust static library"
zig build --summary all 2>&1 && BUILD_RC=0 || BUILD_RC=$?
assert_true "zig build exits with code 0" test "$BUILD_RC" -eq 0
assert_true "zpm binary produced at zig-out/bin/zpm" test -f "zig-out/bin/zpm"

# --- Test 2: cargo produced the release static library ---
echo "Test: cargo build --release produced libzpm_prolog_ffi.a"
assert_true "libzpm_prolog_ffi.a exists at release path" \
    test -f "ffi/zpm-prolog-ffi/target/release/libzpm_prolog_ffi.a"

# --- Test 3: static library exports required C-ABI symbols ---
echo "Test: libzpm_prolog_ffi.a exports required C-ABI symbols"
LIB="ffi/zpm-prolog-ffi/target/release/libzpm_prolog_ffi.a"
if test -f "$LIB"; then
    assert_true "prolog_init exported by static lib"    lib_has_symbol "$LIB" "prolog_init"
    assert_true "prolog_query exported by static lib"   lib_has_symbol "$LIB" "prolog_query"
    assert_true "prolog_assert exported by static lib"  lib_has_symbol "$LIB" "prolog_assert"
    assert_true "prolog_free_string exported by static lib" lib_has_symbol "$LIB" "prolog_free_string"
else
    FAIL=$((FAIL + 4))
    red "  FAIL: static library missing — skipping symbol checks"
fi

# --- Test 4: binary is executable ---
echo "Test: zpm binary is executable"
assert_true "binary has execute permission" test -x "zig-out/bin/zpm"

# --- Summary ---
echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    green "All $TOTAL assertions passed."
else
    red "$FAIL of $TOTAL assertions failed."
    exit 1
fi
