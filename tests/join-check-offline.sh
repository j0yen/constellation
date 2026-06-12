#!/usr/bin/env bash
# join-check-offline.sh — offline unit tests for constellation-join-check verdict logic.
#
# Exercises pass/fail/skip combinations via --inject-* flags without any live
# network, NATS server, tailscale, or age key required.
#
# Exit 0 = all assertions passed; exit 1 = at least one assertion failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/../bin/constellation-join-check"

if [[ ! -x "$BIN" ]]; then
    echo "FAIL: $BIN not found or not executable" >&2
    exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0

assert_exit() {
    local desc="$1" expected_exit="$2"
    shift 2
    local actual_exit=0
    "$BIN" "$@" &>/dev/null || actual_exit=$?
    if [[ "$actual_exit" -eq "$expected_exit" ]]; then
        echo "PASS: $desc (exit $actual_exit)"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        echo "FAIL: $desc — expected exit $expected_exit, got $actual_exit"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

assert_output_contains() {
    local desc="$1" pattern="$2"
    shift 2
    local out
    out=$("$BIN" "$@" 2>&1 || true)
    if echo "$out" | grep -q "$pattern"; then
        echo "PASS: $desc (found '$pattern')"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        echo "FAIL: $desc — pattern '$pattern' not found in output:"
        echo "$out" | sed 's/^/  /'
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

assert_output_not_contains() {
    local desc="$1" pattern="$2"
    shift 2
    local out
    out=$("$BIN" "$@" 2>&1 || true)
    if ! echo "$out" | grep -q "$pattern"; then
        echo "PASS: $desc (no '$pattern' in output)"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        echo "FAIL: $desc — pattern '$pattern' unexpectedly found in output:"
        echo "$out" | sed 's/^/  /'
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

assert_json_field() {
    local desc="$1" field="$2" expected="$3"
    shift 3
    local out actual
    out=$("$BIN" --json "$@" 2>&1 || true)
    if ! echo "$out" | python3 -c "import json,sys; json.load(sys.stdin)" &>/dev/null; then
        echo "FAIL: $desc — --json output is not valid JSON"
        echo "$out" | sed 's/^/  /'
        FAIL_COUNT=$((FAIL_COUNT+1))
        return
    fi
    actual=$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$field',''))")
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS: $desc (field '$field' = '$expected')"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        echo "FAIL: $desc — field '$field': expected '$expected', got '$actual'"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

echo "====== constellation join-check offline tests ======"
echo ""

# ---------------------------------------------------------------------------
# AC1: --help documents the four checks and flags
# ---------------------------------------------------------------------------
echo "--- AC1: --help output ---"
assert_output_contains "help: mesh check mentioned" "mesh" --help
assert_output_contains "help: bus check mentioned" "bus" --help
assert_output_contains "help: secrets check mentioned" "secrets" --help
assert_output_contains "help: brain check mentioned" "brain" --help
assert_output_contains "help: --json flag mentioned" "\-\-json" --help
assert_output_contains "help: --timeout flag mentioned" "\-\-timeout" --help
assert_exit "help exits 0" 0 --help

# ---------------------------------------------------------------------------
# AC2: All pass → exit 0, "JOIN OK" in output
# ---------------------------------------------------------------------------
echo ""
echo "--- AC2: all-pass scenario ---"
assert_exit "all pass: exit 0" 0 \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain pass

assert_output_contains "all pass: JOIN OK" "JOIN OK" \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain pass

assert_output_contains "all pass: PASS mesh" "PASS.*mesh" \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain pass

# ---------------------------------------------------------------------------
# AC2: mesh SKIP (single-node), others pass → exit 0
# ---------------------------------------------------------------------------
echo ""
echo "--- AC2: single-node mode (mesh SKIP, rest pass) ---"
assert_exit "single-node: exit 0" 0 \
    --inject-mesh skip \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain pass

assert_output_contains "single-node: SKIP mesh shown" "SKIP.*mesh" \
    --inject-mesh skip \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain pass

assert_output_contains "single-node: JOIN OK" "JOIN OK" \
    --inject-mesh skip \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain pass

# ---------------------------------------------------------------------------
# AC3: bus fail → non-zero, verdict localizes to bus
# ---------------------------------------------------------------------------
echo ""
echo "--- AC3: bus fail ---"
assert_exit "bus fail: exit 1" 1 \
    --inject-mesh pass \
    --inject-bus fail \
    --inject-secrets pass \
    --inject-brain pass

assert_output_contains "bus fail: FAIL bus shown" "FAIL.*bus" \
    --inject-mesh pass \
    --inject-bus fail \
    --inject-secrets pass \
    --inject-brain pass

assert_output_contains "bus fail: verdict localizes bus" "bus" \
    --inject-mesh pass \
    --inject-bus fail \
    --inject-secrets pass \
    --inject-brain pass

assert_output_contains "bus fail: JOIN INCOMPLETE" "JOIN INCOMPLETE" \
    --inject-mesh pass \
    --inject-bus fail \
    --inject-secrets pass \
    --inject-brain pass

# ---------------------------------------------------------------------------
# AC4: secrets fail → non-zero, verdict localizes to secrets, remediation hint
# ---------------------------------------------------------------------------
echo ""
echo "--- AC4: secrets fail ---"
assert_exit "secrets fail: exit 1" 1 \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets fail \
    --inject-brain pass

assert_output_contains "secrets fail: FAIL secrets" "FAIL.*secrets" \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets fail \
    --inject-brain pass

assert_output_contains "secrets fail: remediation hint" "constellation-secrets bootstrap" \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets fail \
    --inject-brain pass

assert_output_contains "secrets fail: localized verdict" "secrets" \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets fail \
    --inject-brain pass

# ---------------------------------------------------------------------------
# AC5: timeout flag accepted, command exits quickly (inject forces fast path)
# ---------------------------------------------------------------------------
echo ""
echo "--- AC5: --timeout flag accepted ---"
assert_exit "timeout flag: exit 0 with all-pass injections" 0 \
    --timeout 1 \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain pass

# ---------------------------------------------------------------------------
# AC6: --json output structure
# ---------------------------------------------------------------------------
echo ""
echo "--- AC6: --json output ---"
assert_json_field "json all-pass: localized_layer=none" "localized_layer" "none" \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain pass

assert_json_field "json secrets-fail: localized_layer=secrets" "localized_layer" "secrets" \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets fail \
    --inject-brain pass

assert_json_field "json bus-fail: exit_code=1" "exit_code" "1" \
    --inject-mesh pass \
    --inject-bus fail \
    --inject-secrets pass \
    --inject-brain pass

assert_json_field "json all-pass: exit_code=0" "exit_code" "0" \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain pass

# Verify JSON validity + has 'checks' array with 4 entries
json_checks_test() {
    local out
    out=$("$BIN" --json \
        --inject-mesh pass \
        --inject-bus skip \
        --inject-secrets pass \
        --inject-brain pass 2>&1 || true)
    if ! echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'checks' in d, 'no checks key'
assert len(d['checks'])==4, f'expected 4 checks, got {len(d[\"checks\"])}'
assert 'verdict' in d, 'no verdict key'
assert 'localized_layer' in d, 'no localized_layer key'
print('ok')
" &>/dev/null; then
        echo "FAIL: --json: checks array missing or malformed"
        echo "$out" | sed 's/^/  /'
        FAIL_COUNT=$((FAIL_COUNT+1))
    else
        echo "PASS: --json has checks[4], verdict, localized_layer"
        PASS_COUNT=$((PASS_COUNT+1))
    fi
}
json_checks_test

# ---------------------------------------------------------------------------
# AC7: brain fail → non-zero, localized to brain
# ---------------------------------------------------------------------------
echo ""
echo "--- brain fail localization ---"
assert_exit "brain fail: exit 1" 1 \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain fail

assert_output_contains "brain fail: JOIN INCOMPLETE" "JOIN INCOMPLETE" \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain fail

assert_output_contains "brain fail: localized to brain" "brain" \
    --inject-mesh pass \
    --inject-bus pass \
    --inject-secrets pass \
    --inject-brain fail

# ---------------------------------------------------------------------------
# Multiple failures: all fail → exit 1, first layer localized
# ---------------------------------------------------------------------------
echo ""
echo "--- multiple failures ---"
assert_exit "all fail: exit 1" 1 \
    --inject-mesh fail \
    --inject-bus fail \
    --inject-secrets fail \
    --inject-brain fail

assert_output_contains "all fail: JOIN INCOMPLETE" "JOIN INCOMPLETE" \
    --inject-mesh fail \
    --inject-bus fail \
    --inject-secrets fail \
    --inject-brain fail

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "====== Results: $PASS_COUNT passed, $FAIL_COUNT failed ======"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
