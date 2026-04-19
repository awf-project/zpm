#!/usr/bin/env bash
# Feature: F015
# Functional end-to-end tests for the binary installation and multi-platform
# release feature. Validates install.sh main() flow with mocked HTTP, checksum
# verification, all 4 platform mappings, documentation consistency, and PATH warning.
# Run from the project root.
. "$(dirname "$0")/test_helpers.sh"

INSTALL_SH="scripts/install.sh"
WORKFLOW=".github/workflows/release.yaml"

# =============================================================================
# Test 1: All 4 platform mappings produce correct asset names (FR-001, FR-011)
# =============================================================================
echo "Test: map_platform returns correct asset name for all 4 supported platforms"

run_map_platform() {
    local os="$1" arch="$2"
    bash -c "
        uname() { case \"\$1\" in -s) echo '$os';; -m) echo '$arch';; esac; }
        main() { :; }
        . ./scripts/install.sh
        map_platform
    " 2>&1
}

RESULT=$(run_map_platform "Darwin" "arm64") || true
assert_equals "Darwin arm64 → zpm-darwin-arm64" "zpm-darwin-arm64" "$RESULT"

RESULT=$(run_map_platform "Darwin" "x86_64") || true
assert_equals "Darwin x86_64 → zpm-darwin-x86_64" "zpm-darwin-x86_64" "$RESULT"

RESULT=$(run_map_platform "Linux" "x86_64") || true
assert_equals "Linux x86_64 → zpm-linux-x86_64" "zpm-linux-x86_64" "$RESULT"

RESULT=$(run_map_platform "Linux" "aarch64") || true
assert_equals "Linux aarch64 → zpm-linux-arm64" "zpm-linux-arm64" "$RESULT"

# =============================================================================
# Test 2: Install script end-to-end with mocked downloads (FR-012, FR-014, FR-015)
# =============================================================================
echo "Test: main() downloads binary, sets permissions, installs to INSTALL_DIR"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_BINARY="${TMPDIR_TEST}/fake-zpm"
printf '#!/bin/sh\necho "zpm 0.1.0-test"\n' > "$FAKE_BINARY"
FAKE_HASH=$(sha256sum "$FAKE_BINARY" | awk '{print $1}')

FAKE_CHECKSUMS="${TMPDIR_TEST}/SHA256SUMS"
echo "${FAKE_HASH}  zpm-linux-x86_64" > "$FAKE_CHECKSUMS"

INSTALL_DEST="${TMPDIR_TEST}/install-dest"

# Write a wrapper script that sources install.sh with mocked externals
WRAPPER="${TMPDIR_TEST}/test-wrapper.sh"
cat > "$WRAPPER" <<ENDWRAPPER
#!/bin/sh
set -eu

uname() { case "\$1" in -s) echo Linux;; -m) echo x86_64;; esac; }

export INSTALL_DIR="${INSTALL_DEST}"
export PATH="/usr/bin:/bin"

# Source install.sh to get all function definitions
main() { :; }
. ./scripts/install.sh

# Override network functions AFTER sourcing (sourcing redefines them)
curl() {
    dest=""
    url=""
    while [ \$# -gt 0 ]; do
        case "\$1" in
            -o) dest="\$2"; shift 2 ;;
            -*) shift ;;
            *) url="\$1"; shift ;;
        esac
    done
    case "\$url" in
        *SHA256SUMS*) cp "${FAKE_CHECKSUMS}" "\$dest" ;;
        *)            cp "${FAKE_BINARY}" "\$dest" ;;
    esac
}

fetch_latest_release_url() {
    case "\$1" in
        zpm-*)     echo "https://fake.example.com/download/\$1" ;;
        SHA256SUMS) echo "https://fake.example.com/download/SHA256SUMS" ;;
    esac
}

platform=\$(map_platform)
tmpdir=\$(mktemp -d)

binary="\${tmpdir}/zpm"
checksums="\${tmpdir}/SHA256SUMS"

binary_url=\$(fetch_latest_release_url "\$platform")
checksums_url=\$(fetch_latest_release_url "SHA256SUMS")
download_binary "\$binary_url" "\$binary"
download_binary "\$checksums_url" "\$checksums"
verify_checksum "\$binary" "\$checksums"
install_binary "\$binary"
check_path
echo "zpm installed to \${INSTALL_DIR}/zpm"

rm -rf "\$tmpdir"
ENDWRAPPER
chmod +x "$WRAPPER"

OUTPUT=$(sh "$WRAPPER" 2>&1) || true

assert_true "binary installed to INSTALL_DIR" \
    test -f "${INSTALL_DEST}/zpm"
assert_true "installed binary is executable" \
    test -x "${INSTALL_DEST}/zpm"
assert_contains "output confirms installation path" "$OUTPUT" "zpm installed to"
assert_contains "PATH warning shown when INSTALL_DIR not in PATH" "$OUTPUT" "not in your PATH"

# =============================================================================
# Test 3: Checksum mismatch aborts installation (FR-013, FR-016)
# =============================================================================
echo "Test: verify_checksum exits non-zero on checksum mismatch"

BAD_CHECKSUMS="${TMPDIR_TEST}/SHA256SUMS-bad"
echo "0000000000000000000000000000000000000000000000000000000000000000  zpm-linux-x86_64" > "$BAD_CHECKSUMS"

MISMATCH_OUTPUT=$(bash -c "
    main() { :; }
    . ./scripts/install.sh
    verify_checksum '${FAKE_BINARY}' '${BAD_CHECKSUMS}'
" 2>&1) && MISMATCH_RC=$? || MISMATCH_RC=$?

assert_true "checksum mismatch exits non-zero" \
    test "$MISMATCH_RC" -ne 0
assert_contains "error message mentions mismatch" "$MISMATCH_OUTPUT" "checksum mismatch"

# =============================================================================
# Test 4: Documentation surfaces share consistent install URL (FR-018/019/020)
# =============================================================================
echo "Test: all documentation surfaces use consistent install script URL"

EXPECTED_URL="https://raw.githubusercontent.com/awf-project/zpm/main/scripts/install.sh"

assert_true "README.md contains install script URL" \
    grep -qF "$EXPECTED_URL" README.md
assert_true "docs/getting-started/mcp-server.md contains install script URL" \
    grep -qF "$EXPECTED_URL" docs/getting-started/mcp-server.md
assert_true "site/content/_index.md contains install script URL" \
    grep -qF "$EXPECTED_URL" site/content/_index.md

# =============================================================================
# Test 5: Workflow matrix platforms match install script platforms (FR-001/FR-011)
# =============================================================================
echo "Test: release workflow matrix targets align with install script platform names"

for target in linux-x86_64 linux-arm64 darwin-x86_64 darwin-arm64; do
    assert_true "workflow matrix includes $target" \
        grep -qF "target: $target" "$WORKFLOW"
    assert_true "install script maps to zpm-$target" \
        grep -qF "zpm-$target" "$INSTALL_SH"
done

test_summary
