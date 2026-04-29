#!/usr/bin/env bash
# Feature: zig-cli reclaim refactor (refactor/reclaim-zig-cli)
# End-to-end CLI tests covering help, version, error paths, and tool dispatch.
. "$(dirname "$0")/test_helpers.sh"

BINARY="$(cd "$(dirname "${1:-zig-out/bin/zpm}")" && pwd)/$(basename "${1:-zig-out/bin/zpm}")"

# Track every temp dir so a Ctrl-C or set -e abort doesn't leak them.
TEMP_DIRS=()
cleanup_temp_dirs() {
    for d in "${TEMP_DIRS[@]}"; do
        rm -rf "$d"
    done
}
trap cleanup_temp_dirs EXIT

# Each tool subcommand needs a .zpm/ in $PWD or it bootstrap-fails. Use a
# fresh temp dir as PWD per tool invocation. We use pushd/popd (not a `( ... )`
# subshell) so $CLI_EXIT and $CLI_OUTPUT set by capture_cli propagate back to
# the parent shell where assertions run.
make_zpm_dir() {
    local d
    d=$(mktemp -d)
    mkdir -p "$d/.zpm/data" "$d/.zpm/kb"
    TEMP_DIRS+=("$d")
    echo "$d"
}

# Run capture_cli inside a fresh .zpm/-bootstrapped dir.
# Uses pushd/popd so CLI_EXIT and CLI_OUTPUT remain visible to the caller.
# Cleanup is handled by the EXIT trap on TEMP_DIRS.
capture_cli_in_zpm_dir() {
    local dir
    dir=$(make_zpm_dir)
    pushd "$dir" >/dev/null
    capture_cli "$@"
    popd >/dev/null
}

# --- Help and version ---

echo "Test: zpm with no args prints help (zig-cli exits 1)"
capture_cli
assert_exit_code "exit 1" "$CLI_EXIT" 1
assert_contains "shows COMMANDS section" "$CLI_OUTPUT" "COMMANDS"

echo "Test: zpm --help prints help"
capture_cli --help
assert_exit_code "exit 0" "$CLI_EXIT" 0
assert_contains "shows COMMANDS section" "$CLI_OUTPUT" "COMMANDS"

echo "Test: zpm version subcommand prints version"
capture_cli version
assert_exit_code "exit 0" "$CLI_EXIT" 0
assert_contains "version line begins with 'zpm '" "$CLI_OUTPUT" "zpm "
assert_contains "version line contains $ZPM_VERSION" "$CLI_OUTPUT" "$ZPM_VERSION"

# --- Subcommand error paths (zig-cli driven; stderr is silently dropped by a
#     known zig-cli flush bug, so we only assert exit codes here, not text). ---

echo "Test: unknown subcommand"
capture_cli bogus
assert_exit_code "exit 1" "$CLI_EXIT" 1

echo "Test: tool with missing required arg"
capture_cli_in_zpm_dir remember-fact
assert_exit_code "exit 1" "$CLI_EXIT" 1

echo "Test: tool with unknown flag"
capture_cli_in_zpm_dir remember-fact --fact 'foo(bar)' --bogus baz
assert_exit_code "exit 1" "$CLI_EXIT" 1

echo "Test: tool with invalid integer value"
capture_cli_in_zpm_dir explain-why --fact 'parent(tom, bob)' --max-depth abc
assert_exit_code "exit 1" "$CLI_EXIT" 1

# --- Upgrade flag parsing ---

echo "Test: upgrade --channel nightly is rejected (enum parser)"
capture_cli upgrade --channel nightly --dry-run
assert_exit_code "exit 1" "$CLI_EXIT" 1

# --- Tool happy path with positional + flag ---

echo "Test: define-rule with positional head + --body"
capture_cli_in_zpm_dir define-rule 'grandparent(X,Z)' --body 'parent(X,Y), parent(Y,Z)'
assert_exit_code "exit 0" "$CLI_EXIT" 0

echo "Test: assume-fact with positional fact + --assumption"
capture_cli_in_zpm_dir assume-fact 'hyp_test' --assumption a
assert_exit_code "exit 0" "$CLI_EXIT" 0

echo "Test: --format json on list-assumptions"
capture_cli_in_zpm_dir list-assumptions --format json
assert_exit_code "exit 0" "$CLI_EXIT" 0
# JSON output should start with { or [
case "$CLI_OUTPUT" in
    \{*|\[*) green "  PASS: JSON output begins with { or ["; PASS=$((PASS+1)) ;;
    *) red "  FAIL: JSON output does not begin with { or [: '$CLI_OUTPUT'"; FAIL=$((FAIL+1)) ;;
esac

test_summary
