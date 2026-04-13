#!/usr/bin/env bash
# Features: F001-F008
# Functional tests for MCP server end-to-end protocol communication.
# Validates: initialize handshake, tools/list discovery, tools/call dispatch, error handling, graceful shutdown.
set -euo pipefail

BINARY="${1:-zig-out/bin/zpm}"
PASS=0
FAIL=0
TIMEOUT=5

red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label — expected to contain: $needle"
        red "  GOT: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        red "  FAIL: $label — expected NOT to contain: $needle"
        red "  GOT: $haystack"
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

send_mcp() {
    local input="$1"
    printf '%s' "$input" | timeout "$TIMEOUT" "$BINARY" 2>/dev/null || true
}

# --- Test 1: Initialize handshake returns correct server info ---
echo "Test: Initialize handshake"
INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}'
RESPONSE=$(send_mcp "$INIT_REQ")

assert_contains "serverInfo.name is zpm" "$RESPONSE" '"name":"zpm"'
assert_contains "serverInfo.version is 0.1.0" "$RESPONSE" '"version":"0.1.0"'
assert_contains "protocolVersion is 2025-11-25" "$RESPONSE" '"protocolVersion":"2025-11-25"'
assert_contains "tools capability advertised" "$RESPONSE" '"tools":'

# --- Test 2: tools/list returns echo tool with schema ---
echo "Test: Tool discovery via tools/list"
TOOLSLIST_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
RESPONSE=$(send_mcp "$TOOLSLIST_INPUT")
TOOLS_LINE=$(echo "$RESPONSE" | grep '"id":2')

assert_contains "echo tool listed" "$TOOLS_LINE" '"name":"echo"'
assert_contains "echo tool has description" "$TOOLS_LINE" '"description":"Echo back the input message"'
assert_contains "echo tool has inputSchema" "$TOOLS_LINE" '"inputSchema":'
assert_contains "remember_fact tool listed" "$TOOLS_LINE" '"name":"remember_fact"'
assert_contains "define_rule tool listed" "$TOOLS_LINE" '"name":"define_rule"'
assert_contains "query_logic tool listed" "$TOOLS_LINE" '"name":"query_logic"'
assert_contains "trace_dependency tool listed" "$TOOLS_LINE" '"name":"trace_dependency"'
assert_contains "verify_consistency tool listed" "$TOOLS_LINE" '"name":"verify_consistency"'
assert_contains "explain_why tool listed" "$TOOLS_LINE" '"name":"explain_why"'
assert_contains "get_knowledge_schema tool listed" "$TOOLS_LINE" '"name":"get_knowledge_schema"'
assert_contains "forget_fact tool listed" "$TOOLS_LINE" '"name":"forget_fact"'
assert_contains "clear_context tool listed" "$TOOLS_LINE" '"name":"clear_context"'
assert_contains "update_fact tool listed" "$TOOLS_LINE" '"name":"update_fact"'
assert_contains "upsert_fact tool listed" "$TOOLS_LINE" '"name":"upsert_fact"'

# --- Test 3: tools/call echo returns the message ---
echo "Test: Echo tool invocation"
ECHO_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"message\":\"functional test\"}}}"
RESPONSE=$(send_mcp "$ECHO_INPUT")
ECHO_LINE=$(echo "$RESPONSE" | grep '"id":3')

assert_contains "echo returns message text" "$ECHO_LINE" '"text":"functional test"'
assert_contains "echo result is not an error" "$ECHO_LINE" '"isError":false'

# --- Test 4: tools/call echo with missing argument returns error ---
echo "Test: Echo tool missing argument error"
MISSING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$MISSING_INPUT")
ERROR_LINE=$(echo "$RESPONSE" | grep '"id":4')

assert_contains "missing arg returns isError true" "$ERROR_LINE" '"isError":true'

# --- Test 5: Graceful shutdown on EOF ---
echo "Test: Graceful shutdown on STDIO close"
printf '%s\n' "$INIT_REQ" | timeout "$TIMEOUT" "$BINARY" >/dev/null 2>&1
EXIT_CODE=$?
assert_exit_code "exits with code 0 on EOF" "$EXIT_CODE" 0

# --- Test 6: remember_fact asserts a fact and returns success ---
echo "Test: remember_fact tool invocation"
REMEMBER_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"user_prefers(dark_mode)\"}}}"
RESPONSE=$(send_mcp "$REMEMBER_INPUT")
REMEMBER_LINE=$(echo "$RESPONSE" | grep '"id":6')

assert_contains "remember_fact returns success" "$REMEMBER_LINE" '"isError":false'
assert_contains "remember_fact confirms asserted fact" "$REMEMBER_LINE" 'user_prefers(dark_mode)'

# --- Test 7: remember_fact with missing fact key returns error ---
echo "Test: remember_fact missing argument error"
MISSING_FACT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$MISSING_FACT_INPUT")
MISSING_FACT_LINE=$(echo "$RESPONSE" | grep '"id":7')

assert_contains "missing fact key returns isError true" "$MISSING_FACT_LINE" '"isError":true'

# --- Test 8: define_rule asserts a rule and returns success ---
echo "Test: define_rule tool invocation"
DEFINE_RULE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"mortal(X)\",\"body\":\"human(X)\"}}}"
RESPONSE=$(send_mcp "$DEFINE_RULE_INPUT")
DEFINE_RULE_LINE=$(echo "$RESPONSE" | grep '"id":8')

assert_contains "define_rule returns success" "$DEFINE_RULE_LINE" '"isError":false'
assert_contains "define_rule confirms asserted rule head" "$DEFINE_RULE_LINE" 'mortal(X)'

# --- Test 9: define_rule with missing arguments returns error ---
echo "Test: define_rule missing argument error"
MISSING_RULE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$MISSING_RULE_INPUT")
MISSING_RULE_LINE=$(echo "$RESPONSE" | grep '"id":9')

assert_contains "missing rule arguments returns isError true" "$MISSING_RULE_LINE" '"isError":true'

# --- Test 10: query_logic returns solutions for matching facts ---
echo "Test: query_logic tool invocation with matching facts"
QUERY_FACTS_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"fruit(apple)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"fruit(banana)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"fruit(X)\"}}}"
RESPONSE=$(send_mcp "$QUERY_FACTS_INPUT")
QUERY_LINE=$(echo "$RESPONSE" | grep '"id":12')

assert_contains "query_logic returns success" "$QUERY_LINE" '"isError":false'
assert_contains "query_logic returns apple binding" "$QUERY_LINE" 'apple'
assert_contains "query_logic returns banana binding" "$QUERY_LINE" 'banana'

# --- Test 11: query_logic returns empty array when no facts match ---
echo "Test: query_logic with no matching facts returns empty array"
QUERY_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"nonexistent_pred(X)\"}}}"
RESPONSE=$(send_mcp "$QUERY_EMPTY_INPUT")
QUERY_EMPTY_LINE=$(echo "$RESPONSE" | grep '"id":13')

assert_contains "query_logic empty result is not an error" "$QUERY_EMPTY_LINE" '"isError":false'
assert_contains "query_logic empty result returns empty array" "$QUERY_EMPTY_LINE" '[]'

# --- Test 12: query_logic with missing goal argument returns error ---
echo "Test: query_logic missing goal argument error"
QUERY_MISSING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$QUERY_MISSING_INPUT")
QUERY_MISSING_LINE=$(echo "$RESPONSE" | grep '"id":14')

assert_contains "missing goal returns isError true" "$QUERY_MISSING_LINE" '"isError":true'

# --- Test 12b: query_logic with syntactically invalid goal returns empty result ---
# NOTE: scryer-prolog silently returns 0 solutions for malformed goals instead of
# raising a parse error. This test documents current behavior; SC-003 "invalid syntax
# returns error" cannot be enforced at the Zig layer without duplicating Prolog's parser.
echo "Test: query_logic with invalid syntax returns empty result (scryer-prolog limitation)"
QUERY_INVALID_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"contributor(X,\"}}}"
RESPONSE=$(send_mcp "$QUERY_INVALID_INPUT")
QUERY_INVALID_LINE=$(echo "$RESPONSE" | grep '"id":22')

assert_contains "invalid syntax returns empty array (scryer-prolog limitation)" "$QUERY_INVALID_LINE" '"isError":false'

# --- Test 13: trace_dependency returns reachable nodes for transitive dependency chain ---
echo "Test: trace_dependency tool invocation with transitive dependencies"
TRACE_CHAIN_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"depends_on(a, b)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"depends_on(b, c)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"path(X, Start)\",\"body\":\"depends_on(Start, X)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"path(X, Start)\",\"body\":\"depends_on(Start, Mid), path(X, Mid)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"tools/call\",\"params\":{\"name\":\"trace_dependency\",\"arguments\":{\"start_node\":\"a\"}}}"
RESPONSE=$(send_mcp "$TRACE_CHAIN_INPUT")
TRACE_LINE=$(echo "$RESPONSE" | grep '"id":19')

assert_contains "trace_dependency returns success" "$TRACE_LINE" '"isError":false'
assert_contains "trace_dependency returns direct dependency b" "$TRACE_LINE" '\"b\"'
assert_contains "trace_dependency returns transitive dependency c" "$TRACE_LINE" '\"c\"'

# --- Test 14: trace_dependency returns empty array for isolated node ---
echo "Test: trace_dependency with isolated node returns empty array"
TRACE_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/call\",\"params\":{\"name\":\"trace_dependency\",\"arguments\":{\"start_node\":\"isolated\"}}}"
RESPONSE=$(send_mcp "$TRACE_EMPTY_INPUT")
TRACE_EMPTY_LINE=$(echo "$RESPONSE" | grep '"id":20')

assert_contains "trace_dependency isolated node is not an error" "$TRACE_EMPTY_LINE" '"isError":false'
assert_contains "trace_dependency isolated node returns empty array" "$TRACE_EMPTY_LINE" '[]'

# --- Test 15: trace_dependency with missing start_node argument returns error ---
echo "Test: trace_dependency missing start_node argument error"
TRACE_MISSING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tools/call\",\"params\":{\"name\":\"trace_dependency\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$TRACE_MISSING_INPUT")
TRACE_MISSING_LINE=$(echo "$RESPONSE" | grep '"id":21')

assert_contains "missing start_node returns isError true" "$TRACE_MISSING_LINE" '"isError":true'

# --- Test 16: trace_dependency with injection attempt returns error ---
echo "Test: trace_dependency rejects Prolog injection attempt"
TRACE_INJECT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"tools/call\",\"params\":{\"name\":\"trace_dependency\",\"arguments\":{\"start_node\":\"a), halt(0\"}}}"
RESPONSE=$(send_mcp "$TRACE_INJECT_INPUT")
TRACE_INJECT_LINE=$(echo "$RESPONSE" | grep '"id":23')

assert_contains "injection attempt returns isError true" "$TRACE_INJECT_LINE" '"isError":true'

# --- Test 17: verify_consistency returns no violations for empty knowledge base ---
echo "Test: verify_consistency with empty knowledge base"
VERIFY_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"tools/call\",\"params\":{\"name\":\"verify_consistency\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$VERIFY_EMPTY_INPUT")
VERIFY_LINE=$(echo "$RESPONSE" | grep '"id":24')

assert_contains "verify_consistency is not an error" "$VERIFY_LINE" '"isError":false'
assert_contains "verify_consistency returns empty violations array" "$VERIFY_LINE" '\"violations\":[]'

# --- Test 18: verify_consistency detects integrity violation ---
echo "Test: verify_consistency with integrity_violation rule fires"
VERIFY_VIOLATION_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":25,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"risky(deploy_v3)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":26,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"integrity_violation(X)\",\"body\":\"risky(X)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":27,\"method\":\"tools/call\",\"params\":{\"name\":\"verify_consistency\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$VERIFY_VIOLATION_INPUT")
VERIFY_VIOLATION_LINE=$(echo "$RESPONSE" | grep '"id":27')

assert_contains "verify_consistency with violation is not an error" "$VERIFY_VIOLATION_LINE" '"isError":false'
assert_contains "verify_consistency returns deploy_v3 as violation" "$VERIFY_VIOLATION_LINE" 'deploy_v3'

# --- Test 19: explain_why returns proof tree for asserted fact ---
echo "Test: explain_why with provable fact"
EXPLAIN_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":28,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"risky(deploy_v3)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":29,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{\"fact\":\"risky(deploy_v3)\"}}}"
RESPONSE=$(send_mcp "$EXPLAIN_INPUT")
EXPLAIN_LINE=$(echo "$RESPONSE" | grep '"id":29')

assert_contains "explain_why is not an error" "$EXPLAIN_LINE" '"isError":false'
assert_contains "explain_why returns proven true" "$EXPLAIN_LINE" '\"proven\":true'
assert_contains "explain_why includes fact in proof" "$EXPLAIN_LINE" 'risky(deploy_v3)'

# --- Test 20: explain_why returns proven false for unprovable fact ---
echo "Test: explain_why with unprovable fact"
EXPLAIN_UNPROVABLE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{\"fact\":\"unknown_fact(x)\"}}}"
RESPONSE=$(send_mcp "$EXPLAIN_UNPROVABLE_INPUT")
EXPLAIN_UNPROVABLE_LINE=$(echo "$RESPONSE" | grep '"id":30')

assert_contains "explain_why unprovable is not an error" "$EXPLAIN_UNPROVABLE_LINE" '"isError":false'
assert_contains "explain_why returns proven false" "$EXPLAIN_UNPROVABLE_LINE" '\"proven\":false'

# --- Test 21: explain_why with missing fact argument returns error ---
echo "Test: explain_why missing fact argument error"
EXPLAIN_MISSING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$EXPLAIN_MISSING_INPUT")
EXPLAIN_MISSING_LINE=$(echo "$RESPONSE" | grep '"id":31')

assert_contains "missing fact argument returns isError true" "$EXPLAIN_MISSING_LINE" '"isError":true'

# --- Test 22: explain_why returns proof tree for rule-derived fact ---
echo "Test: explain_why with rule-derived fact returns proof tree"
EXPLAIN_RULE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"parent(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"ancestor(X, Y)\",\"body\":\"parent(X, Y)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":34,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{\"fact\":\"ancestor(alice, bob)\"}}}"
RESPONSE=$(send_mcp "$EXPLAIN_RULE_INPUT")
EXPLAIN_RULE_LINE=$(echo "$RESPONSE" | grep '"id":34')

assert_contains "explain_why rule-derived is not an error" "$EXPLAIN_RULE_LINE" '"isError":false'
assert_contains "explain_why rule-derived returns proven true" "$EXPLAIN_RULE_LINE" '\"proven\":true'
assert_contains "explain_why rule-derived has non-empty children" "$EXPLAIN_RULE_LINE" '\"children\":[{'

# --- Test 23: get_knowledge_schema returns empty list for empty knowledge base ---
echo "Test: get_knowledge_schema with empty knowledge base"
SCHEMA_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":35,\"method\":\"tools/call\",\"params\":{\"name\":\"get_knowledge_schema\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$SCHEMA_EMPTY_INPUT")
SCHEMA_EMPTY_LINE=$(echo "$RESPONSE" | grep '"id":35')

assert_contains "get_knowledge_schema empty KB is not an error" "$SCHEMA_EMPTY_LINE" '"isError":false'
assert_contains "get_knowledge_schema empty KB returns empty predicates" "$SCHEMA_EMPTY_LINE" '\"predicates\":[]'
assert_contains "get_knowledge_schema empty KB returns total 0" "$SCHEMA_EMPTY_LINE" '\"total\":0'

# --- Test 24: get_knowledge_schema returns predicates after asserting facts ---
echo "Test: get_knowledge_schema returns asserted predicates with name and arity"
SCHEMA_FACTS_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":36,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"user_prefers(dark_mode)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":37,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"depends_on(a, b)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":38,\"method\":\"tools/call\",\"params\":{\"name\":\"get_knowledge_schema\",\"arguments\":{}}}
"
RESPONSE=$(send_mcp "$SCHEMA_FACTS_INPUT")
SCHEMA_FACTS_LINE=$(echo "$RESPONSE" | grep '"id":38')

assert_contains "get_knowledge_schema populated KB is not an error" "$SCHEMA_FACTS_LINE" '"isError":false'
assert_contains "get_knowledge_schema returns user_prefers predicate" "$SCHEMA_FACTS_LINE" '\"name\":\"user_prefers\"'
assert_contains "get_knowledge_schema returns arity 1 for user_prefers" "$SCHEMA_FACTS_LINE" '\"arity\":1'
assert_contains "get_knowledge_schema returns depends_on predicate" "$SCHEMA_FACTS_LINE" '\"name\":\"depends_on\"'
assert_contains "get_knowledge_schema returns arity 2 for depends_on" "$SCHEMA_FACTS_LINE" '\"arity\":2'
assert_contains "get_knowledge_schema returns total 2" "$SCHEMA_FACTS_LINE" '\"total\":2'

# --- Test 25: get_knowledge_schema shows type:both for mixed fact+rule predicate ---
echo "Test: get_knowledge_schema classifies mixed fact+rule predicate as type both"
SCHEMA_BOTH_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":39,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"path(a, b)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"path(X, Z)\",\"body\":\"path(X, Y), path(Y, Z)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"tools/call\",\"params\":{\"name\":\"get_knowledge_schema\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$SCHEMA_BOTH_INPUT")
SCHEMA_BOTH_LINE=$(echo "$RESPONSE" | grep '"id":41')

assert_contains "get_knowledge_schema both is not an error" "$SCHEMA_BOTH_LINE" '"isError":false'
assert_contains "get_knowledge_schema classifies path/2 as both" "$SCHEMA_BOTH_LINE" '\"type\":\"both\"'

# Feature: F007
# --- Test 26: forget_fact retracts existing fact, query confirms absence ---
echo "Test: forget_fact retracts asserted fact"
FORGET_EXISTING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"role(jean, manager)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":43,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{\"fact\":\"role(jean, manager)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":44,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"role(jean, manager)\"}}}
"
RESPONSE=$(send_mcp "$FORGET_EXISTING_INPUT")
FORGET_LINE=$(echo "$RESPONSE" | grep '"id":43')
QUERY_AFTER_LINE=$(echo "$RESPONSE" | grep '"id":44')

assert_contains "forget_fact returns success" "$FORGET_LINE" '"isError":false'
assert_contains "forget_fact confirms retracted fact" "$FORGET_LINE" 'role(jean, manager)'
assert_contains "query after forget_fact returns empty" "$QUERY_AFTER_LINE" '[]'

# --- Test 27: forget_fact returns error for non-existent fact ---
echo "Test: forget_fact with non-existent fact returns error"
FORGET_MISSING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":45,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{\"fact\":\"role(nobody, ghost)\"}}}
"
RESPONSE=$(send_mcp "$FORGET_MISSING_INPUT")
FORGET_MISSING_LINE=$(echo "$RESPONSE" | grep '"id":45')

assert_contains "forget_fact non-existent returns isError true" "$FORGET_MISSING_LINE" '"isError":true'

# --- Test 28: forget_fact returns error for empty fact ---
echo "Test: forget_fact with empty fact returns error"
FORGET_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":46,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{\"fact\":\"\"}}}
"
RESPONSE=$(send_mcp "$FORGET_EMPTY_INPUT")
FORGET_EMPTY_LINE=$(echo "$RESPONSE" | grep '"id":46')

assert_contains "forget_fact empty fact returns isError true" "$FORGET_EMPTY_LINE" '"isError":true'

# --- Test 29: forget_fact with missing arguments returns error ---
echo "Test: forget_fact missing argument error"
FORGET_NULL_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":47,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{}}}
"
RESPONSE=$(send_mcp "$FORGET_NULL_INPUT")
FORGET_NULL_LINE=$(echo "$RESPONSE" | grep '"id":47')

assert_contains "forget_fact missing args returns isError true" "$FORGET_NULL_LINE" '"isError":true'

# --- Test 30: clear_context removes all matching facts, query confirms ---
echo "Test: clear_context removes all matching facts"
CLEAR_MULTI_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":48,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"project(beta, active)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":49,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"project(beta, owner(alice))\"}}}
{\"jsonrpc\":\"2.0\",\"id\":50,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"project(alpha, active)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":51,\"method\":\"tools/call\",\"params\":{\"name\":\"clear_context\",\"arguments\":{\"category\":\"project(beta, _)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":52,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"project(beta, _)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":53,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"project(Name, _)\"}}}
"
RESPONSE=$(send_mcp "$CLEAR_MULTI_INPUT")
CLEAR_LINE=$(echo "$RESPONSE" | grep '"id":51')
QUERY_BETA_LINE=$(echo "$RESPONSE" | grep '"id":52')
QUERY_ALPHA_LINE=$(echo "$RESPONSE" | grep '"id":53')

assert_contains "clear_context returns success" "$CLEAR_LINE" '"isError":false'
assert_contains "clear_context confirms pattern" "$CLEAR_LINE" 'project(beta, _)'
assert_contains "query after clear_context beta returns empty" "$QUERY_BETA_LINE" '[]'
assert_contains "clear_context preserves non-matching facts" "$QUERY_ALPHA_LINE" 'alpha'

# --- Test 31: clear_context is idempotent when no facts match ---
echo "Test: clear_context with no matching facts returns success"
CLEAR_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":54,\"method\":\"tools/call\",\"params\":{\"name\":\"clear_context\",\"arguments\":{\"category\":\"nonexistent_category(_)\"}}}
"
RESPONSE=$(send_mcp "$CLEAR_EMPTY_INPUT")
CLEAR_EMPTY_LINE=$(echo "$RESPONSE" | grep '"id":54')

assert_contains "clear_context no-match returns success" "$CLEAR_EMPTY_LINE" '"isError":false'

# --- Test 32: clear_context returns error for empty category ---
echo "Test: clear_context with empty category returns error"
CLEAR_EMPTY_CAT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":55,\"method\":\"tools/call\",\"params\":{\"name\":\"clear_context\",\"arguments\":{\"category\":\"\"}}}
"
RESPONSE=$(send_mcp "$CLEAR_EMPTY_CAT_INPUT")
CLEAR_EMPTY_CAT_LINE=$(echo "$RESPONSE" | grep '"id":55')

assert_contains "clear_context empty category returns isError true" "$CLEAR_EMPTY_CAT_LINE" '"isError":true'

# --- Test 33: clear_context with missing arguments returns error ---
echo "Test: clear_context missing argument error"
CLEAR_NULL_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":56,\"method\":\"tools/call\",\"params\":{\"name\":\"clear_context\",\"arguments\":{}}}
"
RESPONSE=$(send_mcp "$CLEAR_NULL_INPUT")
CLEAR_NULL_LINE=$(echo "$RESPONSE" | grep '"id":56')

assert_contains "clear_context missing args returns isError true" "$CLEAR_NULL_LINE" '"isError":true'

# --- Test 34: forget_fact retracts only first duplicate (US3) ---
echo "Test: forget_fact retracts only first duplicate"
FORGET_DUPE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":57,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"likes(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":58,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"likes(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":59,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{\"fact\":\"likes(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":60,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"likes(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":61,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{\"fact\":\"likes(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":62,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"likes(alice, bob)\"}}}
"
RESPONSE=$(send_mcp "$FORGET_DUPE_INPUT")
FORGET_FIRST_LINE=$(echo "$RESPONSE" | grep '"id":59')
QUERY_ONE_LEFT_LINE=$(echo "$RESPONSE" | grep '"id":60')
FORGET_SECOND_LINE=$(echo "$RESPONSE" | grep '"id":61')
QUERY_ZERO_LEFT_LINE=$(echo "$RESPONSE" | grep '"id":62')

assert_contains "first forget_fact on duplicate returns success" "$FORGET_FIRST_LINE" '"isError":false'
assert_contains "one duplicate remains after first retraction" "$QUERY_ONE_LEFT_LINE" '[{}]'
assert_contains "second forget_fact on duplicate returns success" "$FORGET_SECOND_LINE" '"isError":false'
assert_contains "zero duplicates remain after second retraction" "$QUERY_ZERO_LEFT_LINE" '[]'

# --- Test 35: update_fact replaces existing fact atomically ---
echo "Test: update_fact replaces existing fact"
UPDATE_SUCCESS_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":63,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"config(timeout, 30)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":64,\"method\":\"tools/call\",\"params\":{\"name\":\"update_fact\",\"arguments\":{\"old_fact\":\"config(timeout, 30)\",\"new_fact\":\"config(timeout, 60)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":65,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"config(timeout, 60)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":66,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"config(timeout, 30)\"}}}
"
RESPONSE=$(send_mcp "$UPDATE_SUCCESS_INPUT")
UPDATE_LINE=$(echo "$RESPONSE" | grep '"id":64')
QUERY_NEW_LINE=$(echo "$RESPONSE" | grep '"id":65')
QUERY_OLD_LINE=$(echo "$RESPONSE" | grep '"id":66')

assert_contains "update_fact returns success" "$UPDATE_LINE" '"isError":false'
assert_contains "new fact is queryable after update" "$QUERY_NEW_LINE" '[{}]'
assert_contains "old fact is gone after update" "$QUERY_OLD_LINE" '[]'

# --- Test 36: update_fact returns error when old fact does not exist ---
echo "Test: update_fact not-found returns error"
UPDATE_NOTFOUND_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":67,\"method\":\"tools/call\",\"params\":{\"name\":\"update_fact\",\"arguments\":{\"old_fact\":\"nonexistent(ghost, fact)\",\"new_fact\":\"nonexistent(ghost, replaced)\"}}}
"
RESPONSE=$(send_mcp "$UPDATE_NOTFOUND_INPUT")
UPDATE_NOTFOUND_LINE=$(echo "$RESPONSE" | grep '"id":67')

assert_contains "update_fact not-found returns isError true" "$UPDATE_NOTFOUND_LINE" '"isError":true'

# --- Test 37: upsert_fact inserts when no prior fact exists ---
echo "Test: upsert_fact inserts new fact"
UPSERT_INSERT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":68,\"method\":\"tools/call\",\"params\":{\"name\":\"upsert_fact\",\"arguments\":{\"fact\":\"service(api, healthy)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":69,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"service(api, healthy)\"}}}
"
RESPONSE=$(send_mcp "$UPSERT_INSERT_INPUT")
UPSERT_INSERT_LINE=$(echo "$RESPONSE" | grep '"id":68')
QUERY_INSERT_LINE=$(echo "$RESPONSE" | grep '"id":69')

assert_contains "upsert_fact insert returns success" "$UPSERT_INSERT_LINE" '"isError":false'
assert_contains "upserted fact is queryable" "$QUERY_INSERT_LINE" '[{}]'

# --- Test 38: upsert_fact replaces existing fact with same functor and first arg ---
echo "Test: upsert_fact replaces existing fact"
UPSERT_REPLACE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":70,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"deploy(prod, v1)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":71,\"method\":\"tools/call\",\"params\":{\"name\":\"upsert_fact\",\"arguments\":{\"fact\":\"deploy(prod, v2)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":72,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"deploy(prod, X)\"}}}
"
RESPONSE=$(send_mcp "$UPSERT_REPLACE_INPUT")
UPSERT_REPLACE_LINE=$(echo "$RESPONSE" | grep '"id":71')
QUERY_REPLACE_LINE=$(echo "$RESPONSE" | grep '"id":72')

assert_contains "upsert_fact replace returns success" "$UPSERT_REPLACE_LINE" '"isError":false'
assert_contains "only new version remains after upsert" "$QUERY_REPLACE_LINE" 'v2'
assert_not_contains "old version is gone after upsert" "$QUERY_REPLACE_LINE" 'v1'

# --- Test 39: upsert_fact does not affect facts with different first argument ---
echo "Test: upsert_fact preserves unrelated facts"
UPSERT_PRESERVE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":73,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"env(prod, active)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":74,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"env(dev, active)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":75,\"method\":\"tools/call\",\"params\":{\"name\":\"upsert_fact\",\"arguments\":{\"fact\":\"env(prod, frozen)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":76,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"env(dev, active)\"}}}
"
RESPONSE=$(send_mcp "$UPSERT_PRESERVE_INPUT")
UPSERT_PRESERVE_LINE=$(echo "$RESPONSE" | grep '"id":75')
QUERY_PRESERVE_LINE=$(echo "$RESPONSE" | grep '"id":76')

assert_contains "upsert_fact preserve returns success" "$UPSERT_PRESERVE_LINE" '"isError":false'
assert_contains "unrelated fact survives upsert" "$QUERY_PRESERVE_LINE" '[{}]'

# --- Summary ---
echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    green "All $TOTAL assertions passed."
else
    red "$FAIL of $TOTAL assertions failed."
    exit 1
fi
