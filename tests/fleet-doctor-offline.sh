#!/usr/bin/env bash
# tests/fleet-doctor-offline.sh — offline test harness for constellation-doctor.
#
# Injects per-layer results via DOCTOR_PROBE_* env vars (no network required).
# Verifies: verdict, first_broken_layer, exit code, JSON output, --layer flag.
#
# Exit 0 = all checks passed.

trap '' PIPE
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCTOR="${REPO_ROOT}/bin/constellation-doctor"

pass=0
fail=0

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '[PASS] %s\n' "$desc"
        ((pass++))
    else
        printf '[FAIL] %s  (cmd: %s)\n' "$desc" "$*"
        ((fail++))
    fi
}

check_output() {
    local desc="$1"
    local expected="$2"
    shift 2
    local out
    out=$("$@" 2>&1) || true
    if echo "$out" | grep -qF -- "$expected"; then
        printf '[PASS] %s\n' "$desc"
        ((pass++))
    else
        printf '[FAIL] %s\n' "$desc"
        printf '       expected to contain: %s\n' "$expected"
        printf '       got: %s\n' "$out"
        ((fail++))
    fi
}

check_exit() {
    local desc="$1"
    local expected_exit="$2"
    shift 2
    local actual_exit
    "$@" >/dev/null 2>&1; actual_exit=$?
    if [[ "$actual_exit" -eq "$expected_exit" ]]; then
        printf '[PASS] %s (exit=%d)\n' "$desc" "$actual_exit"
        ((pass++))
    else
        printf '[FAIL] %s (expected exit=%d, got=%d)\n' "$desc" "$expected_exit" "$actual_exit"
        ((fail++))
    fi
}

# ---------------------------------------------------------------------------
# AC1: --help lists six probed layers and flags
# ---------------------------------------------------------------------------
printf '\n=== AC1: --help ===\n'
check_output "--help mentions mesh"    "mesh"     "$DOCTOR" --help
check_output "--help mentions bus"     "bus"      "$DOCTOR" --help
check_output "--help mentions secrets" "secrets"  "$DOCTOR" --help
check_output "--help mentions brain"   "brain"    "$DOCTOR" --help
check_output "--help mentions dispatch" "dispatch" "$DOCTOR" --help
check_output "--help mentions hub"     "hub"      "$DOCTOR" --help
check_output "--help mentions --json"  "--json"   "$DOCTOR" --help
check_output "--help mentions --live"  "--live"   "$DOCTOR" --help
check_output "--help mentions --layer" "--layer"  "$DOCTOR" --help
check_exit   "--help exits 0"          0          "$DOCTOR" --help

# ---------------------------------------------------------------------------
# AC2: structural-only run (no --live) exits deterministically
# ---------------------------------------------------------------------------
printf '\n=== AC2: structural-only (all SKIP injected) ===\n'
env \
    DOCTOR_PROBE_MESH=SKIP \
    DOCTOR_PROBE_BUS=SKIP \
    DOCTOR_PROBE_SECRETS=SKIP \
    DOCTOR_PROBE_BRAIN=SKIP \
    DOCTOR_PROBE_DISPATCH=SKIP \
    DOCTOR_PROBE_HUB=SKIP \
    "$DOCTOR" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 ]]; then
    printf '[PASS] all-SKIP exits 0 (HEALTHY)\n'
    ((pass++))
else
    printf '[FAIL] all-SKIP should exit 0, got %d\n' "$rc"
    ((fail++))
fi

# ---------------------------------------------------------------------------
# AC3 + AC4: first_broken_layer localizes correctly
# ---------------------------------------------------------------------------
printf '\n=== AC3+AC4: first broken layer localization ===\n'

# All OK → HEALTHY, exit 0
check_exit "all-OK exits 0" 0 env \
    DOCTOR_PROBE_MESH=OK \
    DOCTOR_PROBE_BUS=OK \
    DOCTOR_PROBE_SECRETS=OK \
    DOCTOR_PROBE_BRAIN=OK \
    DOCTOR_PROBE_DISPATCH=OK \
    DOCTOR_PROBE_HUB=OK \
    "$DOCTOR"

# mesh FAIL → first broken = mesh, overall DOWN, exit 2
check_exit "mesh-FAIL exits 2" 2 env \
    DOCTOR_PROBE_MESH=FAIL \
    DOCTOR_PROBE_MESH_MSG="tailscale down" \
    DOCTOR_PROBE_BUS=OK \
    DOCTOR_PROBE_SECRETS=OK \
    DOCTOR_PROBE_BRAIN=OK \
    DOCTOR_PROBE_DISPATCH=OK \
    DOCTOR_PROBE_HUB=OK \
    "$DOCTOR"

check_output "mesh-FAIL headline says MESH" "MESH" env \
    DOCTOR_PROBE_MESH=FAIL \
    DOCTOR_PROBE_MESH_MSG="tailscale down" \
    DOCTOR_PROBE_BUS=OK \
    DOCTOR_PROBE_SECRETS=OK \
    DOCTOR_PROBE_BRAIN=OK \
    DOCTOR_PROBE_DISPATCH=OK \
    DOCTOR_PROBE_HUB=OK \
    "$DOCTOR"

# bus FAIL (mesh OK) → first broken = bus
check_output "bus-FAIL headline says BUS" "BUS" env \
    DOCTOR_PROBE_MESH=OK \
    DOCTOR_PROBE_BUS=FAIL \
    DOCTOR_PROBE_BUS_MSG="KV registry empty" \
    DOCTOR_PROBE_SECRETS=OK \
    DOCTOR_PROBE_BRAIN=OK \
    DOCTOR_PROBE_DISPATCH=OK \
    DOCTOR_PROBE_HUB=OK \
    "$DOCTOR"

# secrets FAIL (mesh+bus OK) → first broken = secrets
check_output "secrets-FAIL headline says SECRETS" "SECRETS" env \
    DOCTOR_PROBE_MESH=OK \
    DOCTOR_PROBE_BUS=OK \
    DOCTOR_PROBE_SECRETS=FAIL \
    DOCTOR_PROBE_SECRETS_MSG="structural check failed" \
    DOCTOR_PROBE_BRAIN=OK \
    DOCTOR_PROBE_DISPATCH=OK \
    DOCTOR_PROBE_HUB=OK \
    "$DOCTOR"

# hub FAIL (all else OK) → first broken = hub
check_output "hub-FAIL headline says HUB" "HUB" env \
    DOCTOR_PROBE_MESH=OK \
    DOCTOR_PROBE_BUS=OK \
    DOCTOR_PROBE_SECRETS=OK \
    DOCTOR_PROBE_BRAIN=OK \
    DOCTOR_PROBE_DISPATCH=OK \
    DOCTOR_PROBE_HUB=FAIL \
    DOCTOR_PROBE_HUB_MSG="hub DOWN" \
    "$DOCTOR"

# mesh WARN → DEGRADED, exit 1
check_exit "mesh-WARN exits 1" 1 env \
    DOCTOR_PROBE_MESH=WARN \
    DOCTOR_PROBE_MESH_MSG="no peers visible" \
    DOCTOR_PROBE_BUS=OK \
    DOCTOR_PROBE_SECRETS=OK \
    DOCTOR_PROBE_BRAIN=OK \
    DOCTOR_PROBE_DISPATCH=OK \
    DOCTOR_PROBE_HUB=OK \
    "$DOCTOR"

# bus FAIL takes precedence over later hub FAIL: first broken = bus, exit 2
check_output "bus+hub FAIL: first broken is BUS" "BUS" env \
    DOCTOR_PROBE_MESH=OK \
    DOCTOR_PROBE_BUS=FAIL \
    DOCTOR_PROBE_BUS_MSG="registry empty" \
    DOCTOR_PROBE_SECRETS=OK \
    DOCTOR_PROBE_BRAIN=OK \
    DOCTOR_PROBE_DISPATCH=OK \
    DOCTOR_PROBE_HUB=FAIL \
    DOCTOR_PROBE_HUB_MSG="hub DOWN" \
    "$DOCTOR"

# ---------------------------------------------------------------------------
# AC5: --layer runs only one layer
# ---------------------------------------------------------------------------
printf '\n=== AC5: --layer single-probe ===\n'

# --layer bus with bus=OK, exit 0
check_exit "--layer bus OK exits 0" 0 env \
    DOCTOR_PROBE_BUS=OK \
    DOCTOR_PROBE_BUS_MSG="ok" \
    "$DOCTOR" --layer bus

# --layer bus with bus=FAIL, exit 2
check_exit "--layer bus FAIL exits 2" 2 env \
    DOCTOR_PROBE_BUS=FAIL \
    DOCTOR_PROBE_BUS_MSG="registry empty" \
    "$DOCTOR" --layer bus

# --layer secrets with secrets=WARN, exit 1
check_exit "--layer secrets WARN exits 1" 1 env \
    DOCTOR_PROBE_SECRETS=WARN \
    DOCTOR_PROBE_SECRETS_MSG="something off" \
    "$DOCTOR" --layer secrets

# --layer output only shows that layer
check_output "--layer hub shows hub line" "hub" env \
    DOCTOR_PROBE_HUB=OK \
    DOCTOR_PROBE_HUB_MSG="hub up" \
    "$DOCTOR" --layer hub

# ---------------------------------------------------------------------------
# AC6: --json output is valid and contains required fields
# ---------------------------------------------------------------------------
printf '\n=== AC6: --json output ===\n'

json_out=$(env \
    DOCTOR_PROBE_MESH=OK \
    DOCTOR_PROBE_BUS=FAIL \
    DOCTOR_PROBE_BUS_MSG="registry empty" \
    DOCTOR_PROBE_SECRETS=OK \
    DOCTOR_PROBE_BRAIN=SKIP \
    DOCTOR_PROBE_DISPATCH=SKIP \
    DOCTOR_PROBE_HUB=OK \
    "$DOCTOR" --json 2>/dev/null) || true

# JSON parses with python
if echo "$json_out" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    printf '[PASS] --json output is valid JSON\n'
    ((pass++))
else
    printf '[FAIL] --json output is not valid JSON: %s\n' "$json_out"
    ((fail++))
fi

# Contains "overall"
if echo "$json_out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'overall' in d" 2>/dev/null; then
    printf '[PASS] JSON contains "overall"\n'
    ((pass++))
else
    printf '[FAIL] JSON missing "overall"\n'
    ((fail++))
fi

# Contains "first_broken_layer"
if echo "$json_out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'first_broken_layer' in d" 2>/dev/null; then
    printf '[PASS] JSON contains "first_broken_layer"\n'
    ((pass++))
else
    printf '[FAIL] JSON missing "first_broken_layer"\n'
    ((fail++))
fi

# Contains "layers" array
if echo "$json_out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d['layers'], list)" 2>/dev/null; then
    printf '[PASS] JSON "layers" is an array\n'
    ((pass++))
else
    printf '[FAIL] JSON "layers" is not an array\n'
    ((fail++))
fi

# overall=DOWN, first_broken_layer=bus (mesh OK, bus FAIL)
if echo "$json_out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['overall']=='DOWN'" 2>/dev/null; then
    printf '[PASS] JSON overall=DOWN when bus FAIL\n'
    ((pass++))
else
    printf '[FAIL] JSON overall should be DOWN when bus FAIL, got: %s\n' "$json_out"
    ((fail++))
fi

if echo "$json_out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['first_broken_layer']=='bus'" 2>/dev/null; then
    printf '[PASS] JSON first_broken_layer=bus\n'
    ((pass++))
else
    printf '[FAIL] JSON first_broken_layer should be bus, got: %s\n' "$json_out"
    ((fail++))
fi

# Per-layer array has each layer entry with "layer" and "result" keys
if echo "$json_out" | python3 -c "
import sys,json
d=json.load(sys.stdin)
layers = {e['layer']: e for e in d['layers']}
assert 'mesh' in layers
assert 'bus' in layers
assert layers['mesh']['result'] == 'OK'
assert layers['bus']['result'] == 'FAIL'
" 2>/dev/null; then
    printf '[PASS] JSON layers array has correct per-layer entries\n'
    ((pass++))
else
    printf '[FAIL] JSON layers array structure incorrect\n'
    ((fail++))
fi

# ---------------------------------------------------------------------------
# AC7: SIGPIPE-safe (head -1 does not produce error)
# ---------------------------------------------------------------------------
printf '\n=== AC7: SIGPIPE safety ===\n'
sigpipe_out=$(env \
    DOCTOR_PROBE_MESH=OK \
    DOCTOR_PROBE_BUS=OK \
    DOCTOR_PROBE_SECRETS=OK \
    DOCTOR_PROBE_BRAIN=OK \
    DOCTOR_PROBE_DISPATCH=OK \
    DOCTOR_PROBE_HUB=OK \
    "$DOCTOR" 2>&1 | head -1) || true

if echo "$sigpipe_out" | grep -qi "pipe\|panic\|broken"; then
    printf '[FAIL] SIGPIPE safety: got pipe/panic/broken in output: %s\n' "$sigpipe_out"
    ((fail++))
else
    printf '[PASS] SIGPIPE-safe (no panic on head -1)\n'
    ((pass++))
fi

# ---------------------------------------------------------------------------
# AC8 additional: all-OK exits HEALTHY, all-FAIL exits DOWN
# ---------------------------------------------------------------------------
printf '\n=== AC8 additional: exit code table ===\n'

check_exit "all-FAIL exits 2 (DOWN)" 2 env \
    DOCTOR_PROBE_MESH=FAIL \
    DOCTOR_PROBE_BUS=FAIL \
    DOCTOR_PROBE_SECRETS=FAIL \
    DOCTOR_PROBE_BRAIN=FAIL \
    DOCTOR_PROBE_DISPATCH=FAIL \
    DOCTOR_PROBE_HUB=FAIL \
    "$DOCTOR"

check_exit "all-WARN exits 1 (DEGRADED)" 1 env \
    DOCTOR_PROBE_MESH=WARN \
    DOCTOR_PROBE_BUS=WARN \
    DOCTOR_PROBE_SECRETS=WARN \
    DOCTOR_PROBE_BRAIN=WARN \
    DOCTOR_PROBE_DISPATCH=WARN \
    DOCTOR_PROBE_HUB=WARN \
    "$DOCTOR"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n=== Summary ===\n'
printf 'PASS: %d  FAIL: %d\n' "$pass" "$fail"

[[ $fail -eq 0 ]] && exit 0 || exit 1
