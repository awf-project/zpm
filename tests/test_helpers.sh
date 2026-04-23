#!/usr/bin/env bash
# Shared test harness for ZPM bash test suites.
# Source this file at the top of each test script:
#   . "$(dirname "$0")/test_helpers.sh"

set -euo pipefail

PASS=0
FAIL=0

# Read the canonical project version from build.zig.zon so tests track the
# single source of truth instead of hardcoding a literal.
ZPM_VERSION="$(awk -F '"' '/^\s*\.version = /{print $2; exit}' "$(dirname "$0")/../build.zig.zon")"

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

# Transport helpers — require $BINARY and $TIMEOUT to be set by the sourcing script.

send_mcp_persist() {
    local input="$1" dir="$2"
    mkdir -p "$dir/.zpm/data" "$dir/.zpm/kb"
    (cd "$dir" && printf '%s' "$input" | timeout "$TIMEOUT" "$BINARY" serve 2>/dev/null || true)
}

send_mcp() {
    local tmpdir
    tmpdir=$(mktemp -d)
    send_mcp_persist "$1" "$tmpdir"
    rm -rf "$tmpdir"
}

# Run `$BINARY $@`, capture combined stdout+stderr into $CLI_OUTPUT, exit code into $CLI_EXIT.
capture_cli() {
    CLI_EXIT=0
    CLI_OUTPUT=$("$BINARY" "$@" 2>&1) || CLI_EXIT=$?
}

# Same as capture_cli, but captures only stderr into $CLI_STDERR; stdout is discarded.
capture_cli_stderr() {
    CLI_EXIT=0
    CLI_STDERR=$("$BINARY" "$@" 2>&1 >/dev/null) || CLI_EXIT=$?
}

# Run both CLI and MCP transports for a scenario and invoke shared assertions.
# Arguments:
#   $1 label          — scenario name, printed before assertions run.
#   $2 cli_chain      — a single string of `&&`-joined CLI tool invocations, each the
#                       argv *without* the $BINARY prefix. Example:
#                         "assume-fact 'x' --assumption a && list-assumptions"
#                       Each segment runs as a fresh $BINARY process in a shared temp dir,
#                       so every post-write invocation triggers WAL replay — this is how
#                       the CLI side exercises the write→restart→read cycle.
#   $3 mcp_input      — JSON-RPC frames piped into a single `$BINARY serve` spawn.
#   $4 assertion_fn   — name of a function called with (output, transport); transport is
#                       "CLI" or "MCP" so the assertion body can branch on transport-
#                       specific markers (e.g. `"isError":false` only exists in MCP).
#   $5 mcp_read       — optional second JSON-RPC batch piped into a *second* `serve`
#                       spawn against the same temp dir. Used for MCP replay round-trip
#                       (write → close → fresh server → read); has no CLI equivalent
#                       because CLI already multi-process-restarts on every invocation.
#
# Output from write + optional read phases is concatenated before assertions, so the
# assertion function sees the full end-to-end transcript for either transport.
run_dual_transport_scenario() {
    local label="${1:?label required}"
    local cli_chain="${2:?cli chain required}"
    local mcp_input="${3:?mcp input required}"
    local assertion_fn="${4:?assertion function required}"
    local mcp_read="${5:-}"

    echo "  → $label"

    local cli_dir cli_output
    cli_dir=$(mktemp -d)
    mkdir -p "$cli_dir/.zpm/data" "$cli_dir/.zpm/kb"
    # Prefix each &&-separated segment with $BINARY so the chain runs as a series of
    # fresh CLI processes sharing the temp $PWD/.zpm/ directory. The `\&\&` escapes
    # the `&` in the replacement — unescaped it would expand to the matched text.
    #
    # Escape unquoted parentheses in Prolog fact args (role(a,b), path(x,y), etc.)
    # so bash does not parse them as subshell syntax when re-evaluating the chain.
    # Single-quoted args (like 'hello dual' or 'sess1_*') retain their quoting
    # because the backslash inside single quotes is literal, and bash's quote state
    # tracking still handles them correctly after the substitution.
    local escaped="${cli_chain//(/\\(}"
    escaped="${escaped//)/\\)}"
    local cli_cmd="$BINARY ${escaped//&&/\&\& $BINARY}"
    cli_output=$(cd "$cli_dir" && timeout "$TIMEOUT" bash -c "$cli_cmd" 2>&1) || true
    rm -rf "$cli_dir"

    local mcp_dir mcp_output
    mcp_dir=$(mktemp -d)
    mcp_output=$(send_mcp_persist "$mcp_input" "$mcp_dir")
    if [ -n "$mcp_read" ]; then
        mcp_output="${mcp_output}"$'\n'"$(send_mcp_persist "$mcp_read" "$mcp_dir")"
    fi
    rm -rf "$mcp_dir"

    "$assertion_fn" "$cli_output" "CLI"
    "$assertion_fn" "$mcp_output" "MCP"
}
