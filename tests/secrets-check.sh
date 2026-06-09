#!/usr/bin/env bash
# tests/secrets-check.sh — offline structural gate for constellation-secrets
#
# Does NOT require age/sops/ansible to be installed.
# Tests the script's structure, argument parsing, SIGPIPE safety, and the
# static layout of the secrets tree.
#
# Exit 0 = all checks passed.

set -uo pipefail
trap '' PIPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SECRETS_SCRIPT="${REPO_ROOT}/bin/constellation-secrets"
SECRETS_ROOT="${REPO_ROOT}/secrets"

pass=0
fail=0

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '[PASS] %s\n' "$desc"
        ((pass++))
    else
        printf '[FAIL] %s\n' "$desc"
        ((fail++))
    fi
}

check_grep() {
    local desc="$1"
    local pattern="$2"
    local file="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        printf '[PASS] %s\n' "$desc"
        ((pass++))
    else
        printf '[FAIL] %s  (pattern: %s, file: %s)\n' "$desc" "$pattern" "$file"
        ((fail++))
    fi
}

check_not_grep() {
    local desc="$1"
    local pattern="$2"
    local file="$3"
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        printf '[PASS] %s\n' "$desc"
        ((pass++))
    else
        printf '[FAIL] %s  (pattern FOUND: %s, file: %s)\n' "$desc" "$pattern" "$file"
        ((fail++))
    fi
}

echo "=== constellation-secrets offline structural gate ==="
echo

# ---------------------------------------------------------------------------
# 1. Script exists and is executable (AC1-AC8)
# ---------------------------------------------------------------------------
check "script exists" test -f "$SECRETS_SCRIPT"
check "script is executable" test -x "$SECRETS_SCRIPT"

# ---------------------------------------------------------------------------
# 2. SIGPIPE safety: trap '' PIPE appears early (AC9)
# ---------------------------------------------------------------------------
check_grep "SIGPIPE trap present" "trap '' PIPE" "$SECRETS_SCRIPT"

# ---------------------------------------------------------------------------
# 3. set -uo pipefail is present
# ---------------------------------------------------------------------------
check_grep "set -uo pipefail present" "set -uo pipefail" "$SECRETS_SCRIPT"

# ---------------------------------------------------------------------------
# 4. Subcommands exist in dispatch (AC1-AC8)
# ---------------------------------------------------------------------------
for cmd in bootstrap get audit list help; do
    check_grep "subcommand '$cmd' dispatched" "$cmd\)" "$SECRETS_SCRIPT"
done

# ---------------------------------------------------------------------------
# 5. bootstrap: canary verification before key install (AC1)
# ---------------------------------------------------------------------------
check_grep "canary verification before install" "Canary verif" "$SECRETS_SCRIPT"
check_grep "bootstrap refuses on canary fail" "Canary verification FAILED" "$SECRETS_SCRIPT"

# ---------------------------------------------------------------------------
# 6. bootstrap: idempotency check (AC2)
# ---------------------------------------------------------------------------
check_grep "bootstrap idempotency check" "no-op" "$SECRETS_SCRIPT"

# ---------------------------------------------------------------------------
# 7. get: runtime path enforced under /run/user (AC5)
# ---------------------------------------------------------------------------
check_grep "runtime path guard" "uid_run" "$SECRETS_SCRIPT"
check_grep "never writes outside runtime" "Plaintext never written" "$SECRETS_SCRIPT"

# ---------------------------------------------------------------------------
# 8. get --check exits non-zero on missing (AC6)
# ---------------------------------------------------------------------------
check_grep "check_mode missing exit 1" "check_mode" "$SECRETS_SCRIPT"

# ---------------------------------------------------------------------------
# 9. audit: plaintext leak scan patterns present (AC3, AC8)
# ---------------------------------------------------------------------------
for pattern in 'AGE-SECRET-KEY-' 'tskey' 'sk-ant'; do
    check_grep "audit scans for '$pattern'" "$pattern" "$SECRETS_SCRIPT"
done

# ---------------------------------------------------------------------------
# 10. Secrets tree structure (AC3)
# ---------------------------------------------------------------------------
check "secrets/shared/ exists" test -d "${SECRETS_ROOT}/shared"
check "secrets/laptop/ exists" test -d "${SECRETS_ROOT}/laptop"
check "secrets/cloud/ exists" test -d "${SECRETS_ROOT}/cloud"
check "canary.yaml exists" test -f "${SECRETS_ROOT}/canary.yaml"

# Required secrets present (AC3)
for f in "shared/nats.creds.yaml" "shared/WM_ANTHROPIC_API_KEY.yaml" \
         "laptop/tailscale_authkey.yaml" "cloud/tailscale_authkey.yaml"; do
    check "secret file ${f} exists" test -f "${SECRETS_ROOT}/${f}"
done

# ---------------------------------------------------------------------------
# 11. .sops.yaml present with creation rules (AC4)
# ---------------------------------------------------------------------------
check ".sops.yaml exists" test -f "${REPO_ROOT}/.sops.yaml"
check_grep ".sops.yaml has laptop rule" "secrets/laptop/" "${REPO_ROOT}/.sops.yaml"
check_grep ".sops.yaml has cloud rule" "secrets/cloud/" "${REPO_ROOT}/.sops.yaml"
check_grep ".sops.yaml has shared rule" "secrets/shared/" "${REPO_ROOT}/.sops.yaml"

# ---------------------------------------------------------------------------
# 12. Ansible secrets role present and wired (AC7)
# ---------------------------------------------------------------------------
ROLE_DIR="${REPO_ROOT}/ansible/roles/secrets"
check "ansible secrets role dir exists" test -d "$ROLE_DIR"
check "secrets role tasks/main.yml exists" test -f "${ROLE_DIR}/tasks/main.yml"
check "secrets role defaults/main.yml exists" test -f "${ROLE_DIR}/defaults/main.yml"
check "secrets role template exists" test -f "${ROLE_DIR}/templates/constellation-secrets-render.service.j2"
check_grep "service is Before= bus unit" "Before=wm-busbridge" "${ROLE_DIR}/templates/constellation-secrets-render.service.j2"
check_grep "service is Before= brain unit" "Before=wm-brain" "${ROLE_DIR}/templates/constellation-secrets-render.service.j2"

# site.yml wires secrets role before cloud/voice (AC7 ordering)
check_grep "site.yml includes secrets role" "role: secrets" "${REPO_ROOT}/ansible/site.yml"

# ---------------------------------------------------------------------------
# 13. No plaintext secrets committed in secrets tree (AC10)
# ---------------------------------------------------------------------------
echo
echo "--- Plaintext leak scan in secrets/ tree ---"
leak_found=false
for pattern in 'AGE-SECRET-KEY-' 'tskey-[a-zA-Z0-9_-]{20,}' 'sk-ant-[a-zA-Z0-9_-]{20,}'; do
    if grep -r --include='*.yaml' --include='*.yml' -l -E "$pattern" "${SECRETS_ROOT}" 2>/dev/null; then
        printf '[FAIL] Plaintext pattern "%s" found in secrets tree!\n' "$pattern"
        ((fail++))
        leak_found=true
    fi
done
if ! $leak_found; then
    printf '[PASS] No plaintext secret patterns in secrets tree\n'
    ((pass++))
fi

# ---------------------------------------------------------------------------
# 14. help subcommand: smoke-test output (AC2 delivery docs)
# ---------------------------------------------------------------------------
echo
echo "--- Smoke-testing 'help' subcommand ---"
if help_out=$("$SECRETS_SCRIPT" help 2>&1); then
    printf '[PASS] help exits 0\n'
    ((pass++))
    if printf '%s' "$help_out" | grep -q "bootstrap"; then
        printf '[PASS] help mentions bootstrap\n'
        ((pass++))
    else
        printf '[FAIL] help output missing bootstrap docs\n'
        ((fail++))
    fi
    if printf '%s' "$help_out" | grep -q "USB\|ssh\|tunnel"; then
        printf '[PASS] help documents delivery channels (USB/SSH/tunnel)\n'
        ((pass++))
    else
        printf '[FAIL] help missing delivery channel documentation\n'
        ((fail++))
    fi
else
    printf '[FAIL] help exited non-zero\n'
    ((fail++))
fi

# ---------------------------------------------------------------------------
# 15. Verify 'get' exits non-zero for missing secret (no sops needed)
# ---------------------------------------------------------------------------
echo
echo "--- Smoke-testing 'get' for nonexistent secret ---"
if ! CONSTELLATION_SECRETS_ROOT="${SECRETS_ROOT}" \
    "$SECRETS_SCRIPT" get nonexistent-secret-zzzz >/dev/null 2>&1; then
    printf '[PASS] get exits non-zero for missing secret\n'
    ((pass++))
else
    printf '[FAIL] get should exit non-zero for missing secret\n'
    ((fail++))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=== Results: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]] && exit 0 || exit 1
