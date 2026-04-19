#!/usr/bin/env bash
# Feature: F002 / T004 + F015 / T003
# Verifies that build.zig invokes `cargo build --release` and links libzpm_prolog_ffi into
# the Zig executable. Run after `zig build` to assert the complete build chain.
# F015/T003 regression: validates cross-platform conditionals preserve FFI on Linux.
. "$(dirname "$0")/test_helpers.sh"

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

# --- F015 Regression: cross-platform conditionals preserve Linux FFI build ---

# --- Test 5: linkFfi with conditional patch_step still produces working binary ---
echo "Regression F015: linkFfi patch_step conditional does not break Linux build"
assert_true "zpm binary exists after linkFfi refactor" test -f "zig-out/bin/zpm"
assert_true "binary is not zero bytes after linkFfi refactor" test -s "zig-out/bin/zpm"

# --- Test 6: on Linux, gcc_s is resolved (binary links successfully) ---
echo "Regression F015: binary resolves gcc_s on Linux"
if command -v ldd >/dev/null 2>&1; then
    LDD_OUT=$(ldd zig-out/bin/zpm 2>/dev/null) || LDD_OUT=""
    assert_true "ldd reports no unresolved symbols for zpm binary" \
        bash -c '! echo "$1" | grep -qF "not found"' -- "$LDD_OUT"
else
    green "  SKIP: ldd not available on this platform"
fi

# --- Test 7: on Linux, patch_ffi objcopy step ran (GLIBC max version is patched) ---
echo "Regression F015: objcopy patch ran — GLIBC_2.38 symbol version is absent"
if command -v nm >/dev/null 2>&1; then
    NM_OUT=$(nm -D zig-out/bin/zpm 2>/dev/null) || NM_OUT=""
    assert_true "GLIBC_2.38 is not referenced in binary (objcopy patch applied)" \
        bash -c '! echo "$1" | grep -qF "GLIBC_2.38"' -- "$NM_OUT"
else
    green "  SKIP: nm not available on this platform"
fi

# --- Test 8: FFI C-ABI symbols are reachable from the binary ---
echo "Regression F015: binary-level FFI symbols survive cross-platform linkFfi refactor"
BIN="zig-out/bin/zpm"
if test -f "$BIN" && command -v nm >/dev/null 2>&1; then
    ( set +o pipefail; nm "$BIN" 2>/dev/null | grep -qF "prolog_init" ) \
        && { green "  PASS: prolog_init reachable from binary"; PASS=$((PASS + 1)); } \
        || { red "  FAIL: prolog_init not found in binary"; FAIL=$((FAIL + 1)); }
else
    green "  SKIP: binary or nm not available"
fi

test_summary
